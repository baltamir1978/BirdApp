import SwiftUI

// "These two look alike — which one was it?"
//
// The classifiers are at their weakest between species that differ by a detail
// no model reliably sees at photo distance (the nuthatches, the redstarts, the
// green woodpeckers). When the runner-up is within `BirdDetection.tiebreakRatio`
// of the winner the honest thing is to ask rather than to pick, so this puts the
// close calls side by side and lets the user settle it.
//
// Deliberately not shown for a clear win: an app that second-guesses every
// confident answer teaches the user to ignore it.
struct SpeciesTiebreaker: View {
    let detection: BirdDetection
    let onChoose: (BirdDetection.Alternative) -> Void

    @State private var justChanged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("These species look alike. Which one was it?",
                  systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                row(name: detection.displayName,
                    scientific: detection.scientificName,
                    confidence: detection.confidence,
                    imageURL: detection.imageURL,
                    isCurrent: true) {}

                ForEach(detection.alternatives ?? []) { alternative in
                    row(name: alternative.displayName,
                        scientific: alternative.scientificName,
                        confidence: alternative.confidence,
                        imageURL: alternative.imageURL,
                        isCurrent: false) {
                        withAnimation { justChanged = true }
                        onChoose(alternative)
                    }
                }
            }

            if justChanged {
                Label("Saved with your choice", systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }

    // One species: thumbnail, name and the model's score. The current pick is
    // marked rather than hidden, so the user can see what they are changing from
    // — and change back, since the previous winner becomes an alternative.
    private func row(name: String,
                     scientific: String,
                     confidence: Double,
                     imageURL: String?,
                     isCurrent: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                thumbnail(imageURL)

                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.subheadline)
                        .fontWeight(isCurrent ? .semibold : .regular)
                    Text(scientific)
                        .font(.caption2)
                        .italic()
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                Text("\(Int(confidence * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
    }

    @ViewBuilder
    private func thumbnail(_ imageURL: String?) -> some View {
        // Only the top two candidates get a Wikipedia photo, so a third option
        // falls back to a placeholder rather than an empty gap.
        if let imageURL, let url = URL(string: imageURL) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.secondary.opacity(0.15)
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 40, height: 40)
                .overlay(Image(systemName: "bird").font(.caption).foregroundStyle(.secondary))
        }
    }
}
