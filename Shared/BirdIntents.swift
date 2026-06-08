import AppIntents
import Foundation

// Compiled into BOTH the app and the widget extension so widget buttons and Siri
// can share the same intent types.

extension Notification.Name {
    static let startBirdListening = Notification.Name("BirdApp.startBirdListening")
    static let stopBirdListening  = Notification.Name("BirdApp.stopBirdListening")
}

// Cross-process (Darwin) signal so a "Stop" tapped in the widget can reach the
// running app, which lives in a different process from the widget extension.
let birdStopDarwinName = "Altamirano.BirdApp.stopListening" as CFString

/// Siri / widget / Shortcuts: open the app and start identifying birds. The mic
/// can't run reliably from a cold background intent, so this opens the app; the
/// running app starts listening on the `.startBirdListening` signal.
struct StartListeningIntent: AppIntent {
    static var title: LocalizedStringResource = "Identify a Bird"
    static var description = IntentDescription("Open the app and start listening to identify the birds around you.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .startBirdListening, object: nil)
        return .result()
    }
}

/// Widget "Stop" — runs without opening the app. Updates the shared state (so the
/// widget reflects it immediately) and pings the app to stop if it's running.
struct StopListeningIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Listening"
    static var description = IntentDescription("Stop identifying birds.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        BirdWidgetData.setListening(false)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(birdStopDarwinName),
            nil, nil, true)
        return .result()
    }
}
