import Foundation

// Looks up a recording of a species' song on xeno-canto.
//
// The xeno-canto API v3 requires a personal API key (free for any registered
// member with a verified email). We don't ship one: each user pastes their own
// in Settings, which is also what xeno-canto asks for — a key embedded in a
// distributed app is trivially extractable and gets abused.
//
// Audio files themselves need no key, so the URL we return streams directly.
//
// Recordings are Creative Commons licensed: `Recording` carries the recordist
// and licence so the UI can credit them, which those licences require.
actor XenoCantoService {
    static let shared = XenoCantoService()

    struct Recording: Equatable, Sendable {
        let id: String
        let audioURL: URL
        let recordist: String
        let licenseURL: URL?
        let country: String?
        let length: String?

        var pageURL: URL? { URL(string: "https://xeno-canto.org/\(id)") }
    }

    enum LookupError: LocalizedError {
        case noKey
        case notFound
        case unauthorized
        case network(String)

        var errorDescription: String? {
            switch self {
            case .noKey:
                NSLocalizedString("Add your xeno-canto key in Settings to hear songs", comment: "")
            case .notFound:
                NSLocalizedString("No recording found for this species", comment: "")
            case .unauthorized:
                NSLocalizedString("The xeno-canto key was rejected", comment: "")
            case .network(let message):
                message
            }
        }
    }

    static let apiKeyDefaultsKey = "xenocanto_api_key"

    private var cache: [String: Recording] = [:]

    static var hasKey: Bool { !storedKey.isEmpty }

    private static var storedKey: String {
        (UserDefaults.standard.string(forKey: apiKeyDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // A key bundled in DeveloperKeys.plist, if present. That file is gitignored
    // and only exists in local development builds — see `BirdAppApp.init`.
    // Returns nil in any build shipped to users, and the app is fine with that.
    static var bundledDeveloperKey: String? {
        guard let path = Bundle.main.path(forResource: "DeveloperKeys", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path),
              let key = dict[apiKeyDefaultsKey] as? String,
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return key
    }

    // Returns a song recording for a binomial like "Turdus merula".
    func recording(for scientificName: String) async throws -> Recording {
        if let cached = cache[scientificName] { return cached }

        let key = Self.storedKey
        guard !key.isEmpty else { throw LookupError.noKey }

        let parts = scientificName.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { throw LookupError.notFound }
        let genus = parts[0], species = parts[1]

        // Best first: a high-quality song. Then relax, because plenty of species
        // only have calls or unrated recordings.
        let queries = [
            "gen:\"\(genus)\" sp:\"\(species)\" type:song q:A",
            "gen:\"\(genus)\" sp:\"\(species)\" type:song",
            "gen:\"\(genus)\" sp:\"\(species)\""
        ]

        for query in queries {
            if let found = try await search(query: query, key: key) {
                cache[scientificName] = found
                return found
            }
        }
        throw LookupError.notFound
    }

    // MARK: - Private

    private func search(query: String, key: String) async throws -> Recording? {
        var components = URLComponents(string: "https://xeno-canto.org/api/3/recordings")!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "key", value: key)
        ]
        guard let url = components.url else { return nil }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch {
            throw LookupError.network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 { throw LookupError.unauthorized }
            guard http.statusCode == 200 else {
                throw LookupError.network("xeno-canto HTTP \(http.statusCode)")
            }
        }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              !payload.recordings.isEmpty else { return nil }

        // Prefer something short enough to listen to on the spot, and pick at
        // random among those so tapping again gives a different bird.
        var usable = payload.recordings.filter { $0.audioURL != nil }
        guard !usable.isEmpty else { return nil }
        // Favour mp3: a fair share of uploads are raw WAV, where half a minute
        // of song costs several megabytes of the user's data plan.
        let compressed = usable.filter { $0.isCompressed }
        if !compressed.isEmpty { usable = compressed }
        let short = usable.filter { $0.seconds ?? 999 <= 90 }
        let pool = Array((short.isEmpty ? usable : short).prefix(20))

        guard let pick = pool.randomElement(), let audioURL = pick.audioURL else { return nil }
        return Recording(id: pick.id,
                         audioURL: audioURL,
                         recordist: pick.rec ?? "xeno-canto",
                         licenseURL: pick.lic.flatMap { URL(string: $0.hasPrefix("//") ? "https:\($0)" : $0) },
                         country: pick.cnt,
                         length: pick.length)
    }

    private struct Payload: Decodable {
        let recordings: [Entry]
    }

    private struct Entry: Decodable {
        let id: String
        let file: String
        let fileName: String?
        let rec: String?
        let lic: String?
        let cnt: String?
        let length: String?      // "1:10"

        enum CodingKeys: String, CodingKey {
            case id, file, rec, lic, cnt, length
            case fileName = "file-name"
        }

        var isCompressed: Bool {
            (fileName ?? "").lowercased().hasSuffix(".mp3")
        }

        var audioURL: URL? {
            guard !file.isEmpty else { return nil }
            return URL(string: file.hasPrefix("//") ? "https:\(file)" : file)
        }

        // "1:10" → 70. Nil when unparseable.
        var seconds: Int? {
            guard let length else { return nil }
            let parts = length.split(separator: ":").compactMap { Int($0) }
            guard !parts.isEmpty else { return nil }
            return parts.reduce(0) { $0 * 60 + $1 }
        }
    }
}
