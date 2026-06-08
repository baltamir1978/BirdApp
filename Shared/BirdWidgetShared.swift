import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// The last detection + listening state, shared between the app and its widget
/// through an App Group. The app writes it; the widget reads it.
struct BirdSnapshot: Codable {
    var name: String          // localized / common name shown to the user
    var scientific: String
    var confidence: Double
    var imageURL: String?
    var date: Date
    var isListening: Bool
}

enum BirdWidgetData {
    static let suiteName = "group.Altamirano.BirdApp"
    static let snapshotKey = "widget_last_bird"

    static var defaults: UserDefaults? { UserDefaults(suiteName: suiteName) }

    static func save(_ snapshot: BirdSnapshot?) {
        guard let d = defaults else { return }
        if let snapshot, let data = try? JSONEncoder().encode(snapshot) {
            d.set(data, forKey: snapshotKey)
        } else {
            d.removeObject(forKey: snapshotKey)
        }
        reload()
    }

    static func load() -> BirdSnapshot? {
        guard let d = defaults, let data = d.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(BirdSnapshot.self, from: data)
    }

    /// Flip just the listening flag without losing the last detected bird.
    static func setListening(_ on: Bool) {
        var snap = load() ?? BirdSnapshot(name: "", scientific: "", confidence: 0,
                                          imageURL: nil, date: Date(), isListening: on)
        snap.isListening = on
        save(snap)
    }

    static func reload() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
