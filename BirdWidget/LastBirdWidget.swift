import WidgetKit
import SwiftUI
import AppIntents

// Medium widget: the last identified bird (photo + name + confidence) plus a
// Listen / Stop toggle.
struct LastBirdWidget: Widget {
    let kind = "BirdLastWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BirdProvider()) { entry in
            LastBirdWidgetView(entry: entry)
        }
        .configurationDisplayName("Last Bird")
        .description("Shows the last identified bird, and lets you start or stop listening.")
        .supportedFamilies([.systemMedium])
    }
}

struct LastBirdWidgetView: View {
    var entry: BirdEntry

    private var hasBird: Bool { !(entry.snapshot?.scientific.isEmpty ?? true) }

    var body: some View {
        let listening = entry.snapshot?.isListening ?? false
        HStack(spacing: 14) {
            photo
            VStack(alignment: .leading, spacing: 3) {
                if hasBird, let snap = entry.snapshot {
                    Text(snap.name)
                        .font(.headline)
                        .lineLimit(2)
                    Text(snap.scientific)
                        .font(.caption).italic()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text("\(Int(snap.confidence * 100))%")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(birdGreen)
                        Text(snap.date, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .monospacedDigit()
                } else {
                    Text("No birds yet")
                        .font(.subheadline.weight(.medium))
                    Text("Tap Listen to start identifying.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                toggleButton(listening: listening)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(birdGreen.opacity(0.10), for: .widget)
    }

    @ViewBuilder
    private var photo: some View {
        ZStack {
            if let data = entry.image, let ui = UIImage(data: data) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                birdGreen.opacity(0.18)
                Image(systemName: "bird.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(birdGreen)
            }
        }
        .frame(width: 92, height: 92)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func toggleButton(listening: Bool) -> some View {
        if listening {
            Button(intent: StopListeningIntent()) {
                Label("Stop", systemImage: "stop.fill")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.red.opacity(0.15), in: Capsule())
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        } else {
            Button(intent: StartListeningIntent()) {
                Label("Listen", systemImage: "mic.fill")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(birdGreen.opacity(0.18), in: Capsule())
                    .foregroundStyle(birdGreen)
            }
            .buttonStyle(.plain)
        }
    }
}
