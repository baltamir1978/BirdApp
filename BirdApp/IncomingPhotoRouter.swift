import Observation
import UIKit

// A photo that arrived from outside the app — shared from Photos (or Safari,
// Messages, WhatsApp) through the BirdShare extension, which parks the original
// file in the App Group and opens `birdapp://photo?id=…`.
//
// From here on it is an ordinary photo: `PhotoView` hands it to the framing
// screen and the rest of the pipeline runs unchanged.
@Observable
@MainActor
final class IncomingPhotoRouter {

    struct Item: Identifiable, Equatable {
        let id = UUID()
        let image: UIImage
        let metadata: PhotoMetadata

        // Identity is enough: two shares of the same picture are two events.
        static func == (lhs: Item, rhs: Item) -> Bool { lhs.id == rhs.id }
    }

    private(set) var pending: Item?

    // How recent an unclaimed photo has to be for the safety net below to pick
    // it up. Long enough to cover a failed hand-off, short enough that a photo
    // shared and forgotten this morning doesn't ambush the next launch.
    private static let claimWindow: TimeInterval = 5 * 60

    /// Handles a `birdapp://` URL. Returns whether it was ours, so the caller
    /// knows to switch to the Photo tab — true even if the file has already been
    /// claimed, which happens when the app was cold-launched and the safety net
    /// below got there first.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard let name = SharedPhotoInbox.fileName(from: url) else { return false }
        if pending == nil, let data = SharedPhotoInbox.take(name) {
            adopt(data)
        }
        return true
    }

    /// Safety net for the case where the share extension could not open the app:
    /// the photo is still in the inbox, so claim it when the user gets here on
    /// their own. Returns whether anything was waiting.
    @discardableResult
    func claimPending() -> Bool {
        guard pending == nil,
              let name = SharedPhotoInbox.pending(newerThan: Self.claimWindow).first,
              let data = SharedPhotoInbox.take(name) else { return false }
        adopt(data)
        SharedPhotoInbox.purgeStale()
        return pending != nil
    }

    func clear() {
        pending = nil
    }

    // The EXIF is read from the bytes as they arrived: `UIImage` drops it, and
    // for a photo the location filter should score the bird against where and
    // when the shot was taken, not where the phone is now.
    private func adopt(_ data: Data) {
        guard let image = UIImage(data: data) else { return }
        pending = Item(image: image, metadata: PhotoMetadata(data: data))
    }
}
