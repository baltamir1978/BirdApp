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
                    if let detection = store.latestDetection {
                        DetectionCard(detection: detection)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        Text(analyzer.isListening ? "Listening for birds…" : "Tap the button to start")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .animation(.spring(response: 0.4), value: store.latestDetection?.id)

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
            .overlay(Circle().stroke(Color.accentColor.opacity(0.3), lineWidth: 2))

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

    private var confidenceColor: Color {
        detection.confidence >= 0.85 ? .green : detection.confidence >= 0.7 ? .orange : .red
    }
}
