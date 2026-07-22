import SwiftUI

struct SettingsView: View {
    @AppStorage("confidence_threshold") private var threshold: Double = 0.35
    @AppStorage("detection_sensitivity") private var sensitivity: Double = 1.3
    @AppStorage("temporal_smoothing") private var temporalSmoothing: Bool = false
    @AppStorage("location_filter_influence") private var locationInfluence: Double = 0.7
    @AppStorage("high_pass_filter") private var highPassFilter: Bool = false
    @AppStorage("high_pass_cutoff") private var highPassCutoff: Double = 200
    @AppStorage("signal_gate") private var signalGate: Bool = false
    @AppStorage("clip_gate") private var clipGate: Bool = true
    @AppStorage("unprocessed_audio") private var unprocessedAudio: Bool = true
    @AppStorage("detection_display_seconds") private var displaySeconds: Double = 8
    @AppStorage(XenoCantoService.apiKeyDefaultsKey) private var xenoCantoKey: String = ""
    var modelManager: ModelManager

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Model Status
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: modelManager.isModelReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .font(.title2)
                            .foregroundStyle(modelManager.isModelReady ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(modelManager.isModelReady ? "Model loaded" : "Mock mode")
                                .font(.headline)
                            Text(modelManager.statusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("BirdNET Model")
                } footer: {
                    if !modelManager.isModelReady {
                        Text("Add BirdNET.mlmodel to the Xcode project to enable real identification. The model updates with each new version of the app.")
                    }
                }

                // MARK: Detection
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Confidence Threshold")
                            Spacer()
                            Text("\(Int(threshold * 100))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $threshold, in: 0.3...0.95, step: 0.05)
                    }
                    .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Sensitivity")
                            Spacer()
                            Text(String(format: "%.2f", sensitivity))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $sensitivity, in: 0.5...1.5, step: 0.05)
                    }
                    .padding(.vertical, 4)

                    Toggle("Temporal Smoothing", isOn: $temporalSmoothing)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Keep Result On Screen")
                            Spacer()
                            Text("\(Int(displaySeconds))s")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $displaySeconds, in: 3...30, step: 1)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Detection")
                } footer: {
                    Text("Sensitivity makes the model more or less eager to call a detection. Temporal smoothing requires a species to persist across several overlapping windows, reducing flickering false positives. Keep result on screen sets how long a detection stays visible before it clears while listening continues.")
                }

                // MARK: Audio
                Section {
                    Toggle("Unprocessed Audio", isOn: $unprocessedAudio)
                    Toggle("Skip Silence & Low Signal", isOn: $signalGate)
                    Toggle("Skip Clipped Audio", isOn: $clipGate)
                    Toggle("High-Pass Filter", isOn: $highPassFilter)
                    if highPassFilter {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Cutoff")
                                Spacer()
                                Text("\(Int(highPassCutoff)) Hz")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Slider(value: $highPassCutoff, in: 100...1000, step: 50)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Audio")
                } footer: {
                    Text("Unprocessed audio disables the system's automatic gain, noise suppression and echo cancellation, which distort bird song. The high-pass filter attenuates low-frequency noise (traffic, wind, mains hum) below the cutoff. Turn any of these off if detection gets worse in your environment.")
                }

                // MARK: Location
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Location & Season Filter")
                            Spacer()
                            Text(locationInfluence == 0
                                 ? NSLocalizedString("Off", comment: "")
                                 : "\(Int(locationInfluence * 100))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $locationInfluence, in: 0...1, step: 0.1)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Location")
                } footer: {
                    Text("Weights detections toward species expected in your region at this time of year, instead of excluding the rest outright. Higher = stronger preference for local birds; 0% disables it. Needs location access.")
                }

                // MARK: Bird song playback
                Section {
                    HStack {
                        Text("API key")
                        Spacer()
                        SecureField("xeno-canto", text: $xenoCantoKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 190)
                    }
                    Link("Get a free key at xeno-canto.org",
                         destination: URL(string: "https://xeno-canto.org")!)
                } header: {
                    Text("Bird Songs")
                } footer: {
                    Text("To play a species' song the app looks it up on xeno-canto, which needs a personal API key. Registering is free: create an account, confirm your email and copy the key from your account page. Recordings belong to their recordists and are credited when played.")
                }

                // MARK: About
                Section("About") {
                    LabeledContent { Text("6,000+ worldwide") } label: { Text("Species Coverage") }
                    LabeledContent { Text("On-device · offline") } label: { Text("Inference") }
                    Link("BirdNET Project", destination: URL(string: "https://birdnet.cornell.edu")!)
                    Link("whoBIRD (Android)", destination: URL(string: "https://github.com/woheller69/whoBIRD")!)
                    Link("xeno-canto (bird song archive)", destination: URL(string: "https://xeno-canto.org")!)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
