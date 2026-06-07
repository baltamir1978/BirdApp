import CoreLocation
import SwiftUI

struct ContentView: View {
    @State private var analyzer = AudioAnalyzer()
    @State private var store = DetectionStore()
    @State private var locationManager = LocationManager()
    @State private var modelManager = ModelManager()

    @AppStorage("onboarding_done") private var onboardingDone = false
    @State private var showOnboarding = false

    var body: some View {
        TabView {
            ListenView(analyzer: analyzer, store: store, modelManager: modelManager)
                .tabItem { Label("Listen", systemImage: "mic.fill") }

            HistoryView(store: store)
                .tabItem { Label("History", systemImage: "clock.fill") }

            SettingsView(modelManager: modelManager)
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .onAppear {
            configure()
            if onboardingDone {
                startCapture()
            } else {
                showOnboarding = true
            }
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView {
                onboardingDone = true
                showOnboarding = false
                startCapture()
            }
        }
    }

    // Wire up the analyzer (no permission prompts here).
    private func configure() {
        analyzer.locationProvider = { [locationManager] in
            locationManager.location?.coordinate
        }
        analyzer.configure(modelPath: modelManager.modelPath,
                           labelsPath: modelManager.labelsPath,
                           weightsPath: modelManager.weightsPath)

        analyzer.onDetections = { [store] detections in
            Task { @MainActor in
                var enriched = detections
                // Only the top 2 candidates get a photo + localized name; the
                // rest are shown by name only.
                for i in enriched.indices where i < 2 {
                    let info = await WikipediaImageService.shared.info(for: enriched[i].scientificName)
                    enriched[i].imageURL = info.imageURL
                    enriched[i].localizedName = info.localizedName
                }
                store.setCandidates(enriched)
            }
        }
    }

    // Trigger the microphone + location permission prompts and start listening.
    private func startCapture() {
        locationManager.start()
        analyzer.startListening()
    }
}

#Preview {
    ContentView()
}
