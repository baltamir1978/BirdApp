import SwiftUI

struct SettingsView: View {
    @AppStorage("confidence_threshold") private var threshold: Double = 0.7
    @AppStorage("use_location_filter") private var useLocationFilter: Bool = false
    @AppStorage("high_pass_filter") private var highPassFilter: Bool = true
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
                Section("Detection") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Confidence Threshold")
                            Spacer()
                            Text("\(Int(threshold * 100))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $threshold, in: 0.5...0.95, step: 0.05)
                    }
                    .padding(.vertical, 4)

                    Toggle("High-Pass Filter", isOn: $highPassFilter)
                }

                // MARK: Location
                Section {
                    Toggle("Filter by Location & Season", isOn: $useLocationFilter)
                } header: {
                    Text("Location")
                } footer: {
                    Text("Narrows detections to species expected in your region at this time of year.")
                }

                // MARK: About
                Section("About") {
                    LabeledContent { Text("6,000+ worldwide") } label: { Text("Species Coverage") }
                    LabeledContent { Text("On-device · offline") } label: { Text("Inference") }
                    Link("BirdNET Project", destination: URL(string: "https://birdnet.cornell.edu")!)
                    Link("whoBIRD (Android)", destination: URL(string: "https://github.com/woheller69/whoBIRD")!)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
