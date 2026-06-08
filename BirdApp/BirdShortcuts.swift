import AppIntents

// Registers the spoken Siri phrases for the app. The intent types live in the
// Shared group (BirdIntents.swift) so the widget extension can use them too.
// Every phrase must contain \(.applicationName).
struct BirdAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartListeningIntent(),
            phrases: [
                "Identify a bird with \(.applicationName)",
                "Start listening with \(.applicationName)",
                "What bird is this with \(.applicationName)",
                "Listen for birds with \(.applicationName)"
            ],
            shortTitle: "Identify a Bird",
            systemImageName: "bird.fill"
        )
    }
}
