import SwiftUI

struct ListenView: View {
    var analyzer: AudioAnalyzer
    var store: DetectionStore
    var modelManager: ModelManager

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                // Model status banner
                if !modelManager.isModelReady {
                    ModelStatusBanner(message: modelManager.statusMessage)
                }

                Spacer()

                AudioWaveView(level: analyzer.audioLevel)
                    .frame(height: 100)
                    .padding(.horizontal)

                Group {
                    if !store.latestCandidates.isEmpty {
                        DetectionResults(candidates: store.latestCandidates)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        Text(analyzer.isListening ? "Listening for birds…" : "Tap the button to start")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .animation(.spring(response: 0.4), value: store.latestCandidates.first?.id)

                Spacer()

                MicButton(isListening: analyzer.isListening) {
                    if analyzer.isListening { analyzer.stopListening() }
                    else { analyzer.startListening() }
                }
                .padding(.bottom, 32)

                if let error = analyzer.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            .navigationTitle("Birds")
        }
    }
}

// MARK: - ModelStatusBanner

struct ModelStatusBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Mock mode — \(message)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.1))
        .clipShape(Capsule())
        .padding(.horizontal)
    }
}

// MARK: - MicButton

struct MicButton: View {
    let isListening: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isListening ? Color.red : Color.accentColor)
                    .frame(width: 80, height: 80)
                    .shadow(color: (isListening ? Color.red : Color.accentColor).opacity(0.4),
                            radius: isListening ? 16 : 6)
                Image(systemName: isListening ? "stop.fill" : "mic.fill")
                    .font(.title)
                    .foregroundStyle(.white)
            }
        }
        .animation(.spring(response: 0.3), value: isListening)
    }
}

// MARK: - AudioWaveView

struct AudioWaveView: View {
    let level: Float
    private let barCount = 36

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor.opacity(0.75))
                    .frame(width: 5, height: barHeight(for: i))
                    .animation(.spring(response: 0.12, dampingFraction: 0.6), value: level)
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let normalized = CGFloat(min(level * 20, 1.0))
        let envelope = sin(.pi * Double(index) / Double(barCount - 1))
        return 8 + 72 * normalized * CGFloat(envelope)
    }
}

// MARK: - DetectionCard

struct DetectionCard: View {
    let detection: BirdDetection

    var body: some View {
        VStack(spacing: 10) {
            // Bird image from Wikipedia or fallback icon
            Group {
                if let urlString = detection.imageURL, let url = URL(string: urlString) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            birdPlaceholder
                        }
                    }
                } else {
                    birdPlaceholder
                }
            }
            .frame(width: 120, height: 120)
            .clipShape(Circle())
            .overlay {
                ZStack {
                    Circle().stroke(.secondary.opacity(0.15), lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: detection.confidence)
                        .stroke(confidenceColor,
                                style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .padding(-5)
                .animation(.easeOut(duration: 0.5), value: detection.confidence)
            }

            Text(detection.displayName)
                .font(.title2.bold())

            Text(detection.scientificName)
                .font(.subheadline)
                .italic()
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Label("\(Int(detection.confidence * 100))%", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(confidenceColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(confidenceColor.opacity(0.12))
                    .clipShape(Capsule())

                if detection.coordinate != nil {
                    Label("GPS", systemImage: "location.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .padding(.horizontal)
    }

    private var birdPlaceholder: some View {
        Image(systemName: "bird.fill")
            .font(.system(size: 48))
            .foregroundStyle(Color.accentColor)
    }

    private var confidenceColor: Color { birdConfidenceColor(detection.confidence) }
}

// MARK: - DetectionResults (multi-candidate)

// Shows the ranked candidates: the top one as a full card, the second with a
// thumbnail, and any further candidates by name only.
struct DetectionResults: View {
    let candidates: [BirdDetection]

    var body: some View {
        VStack(spacing: 12) {
            if let top = candidates.first {
                DetectionCard(detection: top)
            }
            if candidates.count > 1 {
                VStack(spacing: 6) {
                    Text("Other possibilities")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)
                    ForEach(Array(candidates.dropFirst().enumerated()), id: \.element.id) { index, c in
                        CandidateRow(detection: c, showImage: index == 0) // index 0 here = 2nd overall
                    }
                }
            }
        }
    }
}

struct CandidateRow: View {
    let detection: BirdDetection
    let showImage: Bool

    var body: some View {
        HStack(spacing: 12) {
            if showImage {
                Group {
                    if let urlString = detection.imageURL, let url = URL(string: urlString) {
                        AsyncImage(url: url) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFill()
                            } else {
                                Image(systemName: "bird.fill").foregroundStyle(Color.accentColor)
                            }
                        }
                    } else {
                        Image(systemName: "bird.fill").foregroundStyle(Color.accentColor)
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(Circle())
            } else {
                Image(systemName: "bird")
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(detection.displayName).font(.subheadline.weight(.medium))
                Text(detection.scientificName).font(.caption2).italic().foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(Int(detection.confidence * 100))%")
                .font(.caption.weight(.semibold))
                .foregroundStyle(birdConfidenceColor(detection.confidence))
                .monospacedDigit()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 24)
    }
}

// whoBIRD-style confidence tiers.
func birdConfidenceColor(_ c: Double) -> Color {
    if c >= 0.8  { return .green }
    if c >= 0.65 { return .yellow }
    if c >= 0.5  { return .orange }
    return .red
}
