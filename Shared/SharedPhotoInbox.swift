import Foundation

/// Photos handed to BirdApp from outside it — the Photos share sheet, Safari,
/// Messages. The share extension drops the *original bytes* in the App Group
/// container and opens the app, which picks them up and runs its normal photo
/// flow (framing screen, classifier, history).
///
/// A file rather than `UserDefaults`: a 4 MB HEIC has no business in a plist,
/// and the bytes have to survive untouched — `PhotoMetadata` reads the EXIF/GPS
/// block, and the location filter scores the bird against where and when the
/// *photo* was taken, not where the phone is now. Re-encoding through `UIImage`
/// would throw that away.
///
/// `nonisolated` because the app target defaults every unannotated type to the
/// main actor and this is plain file I/O called from both processes.
nonisolated enum SharedPhotoInbox {
    static let appGroup = "group.Altamirano.BirdApp"
    static let urlScheme = "birdapp"
    static let photoHost = "photo"

    /// How long an unclaimed photo stays around. It is only ever unclaimed if
    /// opening the app failed, so this is a leak guard, not a feature.
    static let maxAge: TimeInterval = 24 * 60 * 60

    private static let folderName = "IncomingPhotos"

    static var folderURL: URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        return container.appendingPathComponent(folderName, isDirectory: true)
    }

    enum InboxError: LocalizedError {
        case noContainer
        case notAnImage

        var errorDescription: String? {
            switch self {
            case .noContainer: return NSLocalizedString("BirdApp is not set up to receive photos.", comment: "")
            case .notAnImage: return NSLocalizedString("That is not a photo BirdApp can read.", comment: "")
            }
        }
    }

    // MARK: - Writing (share extension side)

    /// Stores the photo and returns the URL that opens the app on it.
    @discardableResult
    static func write(_ data: Data, fileExtension: String) throws -> URL {
        guard let folder = folderURL else { throw InboxError.noContainer }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let name = "\(UUID().uuidString).\(fileExtension.isEmpty ? "jpg" : fileExtension)"
        try data.write(to: folder.appendingPathComponent(name), options: .atomic)

        var components = URLComponents()
        components.scheme = urlScheme
        components.host = photoHost
        components.queryItems = [URLQueryItem(name: "id", value: name)]
        guard let url = components.url else { throw InboxError.noContainer }
        return url
    }

    // MARK: - Reading (app side)

    /// The file name carried by a `birdapp://photo?id=…` URL, if that is what
    /// this URL is. Rejects anything with a path separator: the id indexes our
    /// own folder and must not be able to point outside it.
    static func fileName(from url: URL) -> String? {
        guard url.scheme?.lowercased() == urlScheme, url.host?.lowercased() == photoHost,
              let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                  .queryItems?.first(where: { $0.name == "id" })?.value,
              !id.isEmpty, !id.contains("/"), !id.contains(".."),
              id == (id as NSString).lastPathComponent
        else { return nil }
        return id
    }

    /// Reads a photo and deletes it — claiming it is a one-shot.
    static func take(_ name: String) -> Data? {
        guard let url = folderURL?.appendingPathComponent(name),
              let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return data
    }

    /// Photos still waiting, newest first. Used as a safety net: if opening the
    /// app from the share sheet ever fails, the shot is still picked up the next
    /// time the user comes back — `newerThan` keeps that from resurfacing
    /// something they shared and forgot about hours ago.
    static func pending(newerThan age: TimeInterval = maxAge) -> [String] {
        guard let folder = folderURL,
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: folder,
                  includingPropertiesForKeys: [.contentModificationDateKey],
                  options: .skipsHiddenFiles)
        else { return [] }

        let cutoff = Date().addingTimeInterval(-age)
        return entries
            .compactMap { url -> (String, Date)? in
                guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate, date > cutoff else { return nil }
                return (url.lastPathComponent, date)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Drops anything left behind by a failed hand-off.
    static func purgeStale() {
        guard let folder = folderURL,
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: folder,
                  includingPropertiesForKeys: [.contentModificationDateKey],
                  options: .skipsHiddenFiles)
        else { return }

        let cutoff = Date().addingTimeInterval(-maxAge)
        for url in entries {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            if date <= cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }
}
