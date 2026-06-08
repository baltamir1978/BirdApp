import WidgetKit
import SwiftUI
import AppIntents

// Small widget: a single tap opens the app and starts identifying birds.
struct ListenWidget: Widget {
    let kind = "BirdListenWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BirdProvider()) { entry in
            ListenWidgetView(entry: entry)
        }
        .configurationDisplayName("Identify a Bird")
        .description("Tap to start listening and identify the birds around you.")
        .supportedFamilies([.systemSmall])
    }
}

struct ListenWidgetView: View {
    var entry: BirdEntry

    var body: some View {
        let listening = entry.snapshot?.isListening ?? false
        Button(intent: StartListeningIntent()) {
            VStack(spacing: 8) {
                Image(systemName: "bird.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(birdGreen)
                Text(listening ? "Listening…" : "Identify a Bird")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .containerBackground(birdGreen.opacity(0.10), for: .widget)
    }
}
