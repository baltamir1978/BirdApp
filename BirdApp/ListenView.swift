import SwiftUI

struct ListenView: View {
    var analyzer: AudioAnalyzer
    var store: DetectionStore
    var modelManager: ModelManager

    // Owned here (not in DetectionResults) so the detail sheet survives the
    // live results being auto-cleared during a quiet spell while reading.
    @State private var selectedBird: BirdDetection?

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                // Model status banner
                if !modelManager.isModelReady {
                    ModelStatusBanner(message: modelManager.statusMessage)
                }

                Spacer()

                BirdWaveView(level: analyzer.audioLevel, isListening: analyzer.isListening)
                    .frame(height: 100)
                    .padding(.horizontal)

                Group {
                    if !store.latestCandidates.isEmpty {
                        DetectionResults(candidates: store.latestCandidates,
                                         selectedBird: $selectedBird)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        AnalysisStatusView(phase: analyzer.phase)
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
            .sheet(item: $selectedBird) { bird in
                BirdDetailView(detection: bird)
            }
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

// MARK: - BirdWaveView

// A side-profile bird silhouette that fills with green from the bottom up as the
// audio level rises, and gently scales up on louder song, with sound ripples
// emanating behind it. Replaces the old VU bar meter.
struct BirdWaveView: View {
    let level: Float
    let isListening: Bool

    private let symbol = "bird.fill"   // SF Symbol — a side-on songbird

    var body: some View {
        // Map raw RMS to [0,1]. Unprocessed (.measurement) capture has no AGC so
        // raw RMS is small — the sqrt curve keeps quiet song visible.
        let amp = CGFloat(min(sqrt(max(level, 0)) * 4, 1.0))
        // How far the green fill has risen inside the silhouette (always a little
        // so the bird never fully disappears).
        let fillFraction = isListening ? 0.18 + amp * 0.82 : 0.12

        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate

            GeometryReader { geo in
                let h = geo.size.height
                let birdW = h * 1.3

                ZStack {
                    // Sound ripples — only when there's real signal.
                    if amp > 0.05 {
                        ForEach(0..<3, id: \.self) { ring in
                            let progress = ((t * 0.9 + Double(ring) / 3).truncatingRemainder(dividingBy: 1))
                            Circle()
                                .stroke(Color.accentColor.opacity((1 - progress) * Double(amp) * 0.5),
                                        lineWidth: 2)
                                .frame(width: h * (0.5 + progress * 1.6),
                                       height: h * (0.5 + progress * 1.6))
                        }
                    }

                    ZStack {
                        // Faint full silhouette so the bird's outline is always read.
                        Image(systemName: symbol)
                            .resizable()
                            .scaledToFit()
                            .frame(width: birdW, height: h)
                            .foregroundStyle(Color.accentColor.opacity(0.18))

                        // Green fill rising from the bottom, clipped to the bird shape.
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Rectangle()
                                .fill(LinearGradient(
                                    colors: [Color.accentColor, Color.accentColor.opacity(0.65)],
                                    startPoint: .bottom, endPoint: .top))
                                .frame(height: h * min(fillFraction, 1))
                        }
                        .frame(width: birdW, height: h)
                        .mask(
                            Image(systemName: symbol)
                                .resizable()
                                .scaledToFit()
                                .frame(width: birdW, height: h)
                        )
                    }
                    .frame(width: birdW, height: h)
                    .scaleEffect(1 + amp * 0.12, anchor: .center)
                    .shadow(color: .accentColor.opacity(0.25 + Double(amp) * 0.4),
                            radius: 4 + amp * 8)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: amp)
                }
                .frame(width: geo.size.width, height: h)
            }
        }
    }
}

// MARK: - AnalysisStatusView

// Shows what the recognition pipeline is doing before a result is confirmed:
// idle → listening → analyzing → narrowing in on a best guess.
struct AnalysisStatusView: View {
    let phase: AudioAnalyzer.Phase

    var body: some View {
        Group {
            switch phase {
            case .idle:
                Text("Tap the button to start")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

            case .listening:
                Label {
                    Text("Listening for birds…")
                } icon: {
                    Image(systemName: "ear")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

            case .analyzing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Analyzing sound…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

            case .thinking(let name, let confidence):
                VStack(spacing: 4) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Possible:")
                            .foregroundStyle(.secondary)
                        Text(name)                                   // bird name (data)
                            .fontWeight(.medium)
                        Text(verbatim: "\(Int(confidence * 100))%")  // number, not localized
                            .foregroundStyle(birdConfidenceColor(confidence))
                            .monospacedDigit()
                    }
                    .font(.subheadline)
                    Text("Listening to confirm…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: phase)
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

    // Tapping any candidate opens its detail sheet (info + Wikipedia link). The
    // selection is owned by ListenView so the sheet outlives the auto-clear.
    @Binding var selectedBird: BirdDetection?

    var body: some View {
        VStack(spacing: 12) {
            if let top = candidates.first {
                DetectionCard(detection: top)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedBird = top }
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
                            .contentShape(Rectangle())
                            .onTapGesture { selectedBird = c }
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
