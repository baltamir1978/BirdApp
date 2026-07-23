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
    @AppStorage("background_listening") private var backgroundListening: Bool = false
    @AppStorage("background_listening_minutes") private var backgroundMinutes: Double = 30
    @AppStorage(PhotoIdentifier.fusionDefaultsKey) private var audioPhotoFusion: Bool = true
    @AppStorage(PhotoIdentifier.modelPreferenceKey) private var photoModel: String =
        PhotoIdentifier.ModelChoice.automatic.rawValue
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

                // MARK: Background listening
                Section {
                    Toggle("Keep Listening in Background", isOn: $backgroundListening)
                    if backgroundListening {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Auto-stop After")
                                Spacer()
                                Text("\(Int(backgroundMinutes)) min")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Slider(value: $backgroundMinutes, in: 5...120, step: 5)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Background")
                } footer: {
                    Text("Keeps identifying birds while the app is in the background or the screen is locked. The microphone stays active (iOS shows an orange dot) and it uses more battery, so listening stops automatically after the time set here.")
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

                // MARK: Photo
                Section {
                    Toggle("Use Recent Songs", isOn: $audioPhotoFusion)
                    // Only worth offering when both classifiers are on board.
                    if modelManager.iberianPhotoModelPath != nil {
                        Picker("Photo Model", selection: $photoModel) {
                            Text("Automatic").tag(PhotoIdentifier.ModelChoice.automatic.rawValue)
                            Text("Iberian").tag(PhotoIdentifier.ModelChoice.iberian.rawValue)
                            Text("Worldwide").tag(PhotoIdentifier.ModelChoice.worldwide.rawValue)
                        }
                    }
                } header: {
                    Text("Photo")
                } footer: {
                    Text("When identifying a photo, favour species heard through the microphone in the last few minutes. Useful when two species look alike but only one is singing around you.\n\nThe Iberian model knows local birds far better but only those; automatic picks it when you are in Iberia and falls back to the worldwide one elsewhere.")
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
