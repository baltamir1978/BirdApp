import UIKit
import UniformTypeIdentifiers

/// The "BirdApp" entry in the Photos share sheet.
///
/// Deliberately a bridge and not a classifier: it copies the shared photo into
/// the App Group and opens the app on it. Everything that makes a result worth
/// having — the framing screen, the location filter, audio↔photo fusion, the
/// tiebreaker, history, the song — already lives in the app and none of it has
/// to be duplicated (nor does the 13 MB model, nor the 37 label tables).
///
/// The UI is a spinner that is normally on screen for a fraction of a second.
final class ShareViewController: UIViewController {

    private let spinner = UIActivityIndicatorView(style: .large)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await handleSharedPhoto() }
    }

    // MARK: - Flow

    private func handleSharedPhoto() async {
        guard let provider = imageProvider() else {
            return fail(with: SharedPhotoInbox.InboxError.notAnImage)
        }

        do {
            let (data, ext) = try await loadImageData(from: provider)
            SharedPhotoInbox.purgeStale()
            let url = try SharedPhotoInbox.write(data, fileExtension: ext)
            await open(url)
        } catch {
            fail(with: error)
        }
    }

    /// The first attachment that is actually an image. Sharing from Photos can
    /// carry several representations of the same item, and other apps add plain
    /// text or a URL alongside the picture.
    private func imageProvider() -> NSItemProvider? {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        for item in items {
            for provider in item.attachments ?? [] where provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                return provider
            }
        }
        return nil
    }

    /// Loads the photo as raw bytes, keeping the file format it arrived in.
    ///
    /// `loadDataRepresentation` on the *concrete* type (public.heic, public.jpeg)
    /// hands back the original file with its EXIF intact; asking for `.image`
    /// can get a transcoded copy. The GPS block in there is what lets the app
    /// score a photo from last month's trip against the right place and season.
    private func loadImageData(from provider: NSItemProvider) async throws -> (Data, String) {
        let offered = provider.registeredTypeIdentifiers.compactMap(UTType.init)
        // A concrete format if one is on offer; the generic `public.image` only
        // as a fallback, since asking for it invites a transcode.
        let type = offered.first { $0.conforms(to: .image) && $0 != .image }
            ?? offered.first { $0.conforms(to: .image) }
            ?? .jpeg
        let ext = type.preferredFilenameExtension ?? "jpg"

        let data: Data = try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? SharedPhotoInbox.InboxError.notAnImage)
                }
            }
        }
        return (data, ext)
    }

    /// Hands over to the app. If the system refuses, the photo is already in the
    /// inbox — the app picks it up on its own next launch, so say that rather
    /// than losing the shot silently.
    private func open(_ url: URL) async {
        guard await openApp(url) else {
            return present(message: NSLocalizedString("Open BirdApp to identify this photo.", comment: ""))
        }
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// Launches `birdapp://…`.
    ///
    /// Through the application the view is hosted in, reached by walking the
    /// responder chain, and *not* `extensionContext.open`: that one only ever
    /// worked from a Today widget, and from a share extension it just answers
    /// `false` — which is why this used to stop at "open the app yourself".
    /// `UIApplication.open(_:options:completionHandler:)` is public API and,
    /// unlike `UIApplication.shared`, is not marked unavailable to extensions;
    /// only the singleton accessor is, hence the walk.
    ///
    /// `extensionContext.open` stays as a fallback for the case where no
    /// application turns up in the chain.
    private func openApp(_ url: URL) async -> Bool {
        if let application = hostApplication() {
            return await withCheckedContinuation { continuation in
                application.open(url, options: [:]) { continuation.resume(returning: $0) }
            }
        }
        guard let context = extensionContext else { return false }
        return await withCheckedContinuation { continuation in
            context.open(url) { continuation.resume(returning: $0) }
        }
    }

    private func hostApplication() -> UIApplication? {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication { return application }
            responder = current.next
        }
        return nil
    }

    // MARK: - Errors

    private func fail(with error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        present(message: message)
    }

    private func present(message: String) {
        spinner.stopAnimating()
        let alert = UIAlertController(title: "BirdApp", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default) { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil)
        })
        present(alert, animated: true)
    }
}
