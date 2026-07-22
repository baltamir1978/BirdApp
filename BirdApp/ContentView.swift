import CoreLocation
import SwiftUI

struct ContentView: View {
    @State private var analyzer = AudioAnalyzer()
    @State private var store = DetectionStore()
    @State private var locationManager = LocationManager()
    @State private var modelManager = ModelManager()
    @State private var photoIdentifier = PhotoIdentifier()

    @AppStorage("onboarding_done") private var onboardingDone = false
    @State private var showOnboarding = false
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            ListenView(analyzer: analyzer, store: store, modelManager: modelManager)
                .tabItem { Label("Listen", systemImage: "mic.fill") }
                .tag(0)

            PhotoView(identifier: photoIdentifier, store: store)
                .tabItem { Label("Photo", systemImage: "camera.fill") }
                .tag(1)

            HistoryView(store: store)
                .tabItem { Label("History", systemImage: "clock.fill") }
                .tag(2)

            SettingsView(modelManager: modelManager)
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(3)
        }
        .onAppear {
            configure()
            if onboardingDone {
                startCapture()
            } else {
                showOnboarding = true
            }
        }
        // Siri / Shortcuts asked us to start identifying — jump to Listen and
        // start the mic (the app may already be foregrounded and stopped).
        .onReceive(NotificationCenter.default.publisher(for: .startBirdListening)) { _ in
            guard onboardingDone else { return }
            selectedTab = 0
            startCapture()
        }
        // Widget "Stop" reached us via a Darwin signal re-posted as this notification.
        .onReceive(NotificationCenter.default.publisher(for: .stopBirdListening)) { _ in
            analyzer.stopListening()
        }
        // Keep the widgets' listening indicator in sync with the live state.
        .onChange(of: analyzer.isListening) { _, listening in
            BirdWidgetData.setListening(listening)
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
                           localizedLabelsPath: modelManager.localizedLabelsPath,
                           weightsPath: modelManager.weightsPath)

        photoIdentifier.locationProvider = { [locationManager] in
            locationManager.location?.coordinate
        }
        photoIdentifier.configure(modelPath: modelManager.photoModelPath,
                                  labelsPath: modelManager.labelsPath,
                                  localizedLabelsPath: modelManager.localizedLabelsPath,
                                  weightsPath: modelManager.weightsPath)

        analyzer.onDetections = { [store] detections in
            Task { @MainActor in
                var enriched = detections
                // The native common name already comes from the bundled localized
                // labels. Only the top 2 candidates fetch a Wikipedia photo (and a
                // name only as a fallback if the labels lacked one).
                for i in enriched.indices where i < 2 {
                    let info = await WikipediaImageService.shared.info(for: enriched[i].scientificName)
                    enriched[i].imageURL = info.imageURL
                    if enriched[i].localizedName?.isEmpty ?? true {
                        enriched[i].localizedName = info.localizedName
                    }
                }
                store.setCandidates(enriched)

                // Mirror the top result to the App Group so the widgets update.
                if let top = enriched.first {
                    BirdWidgetData.save(BirdSnapshot(
                        name: top.displayName,
                        scientific: top.scientificName,
                        confidence: top.confidence,
                        imageURL: top.imageURL,
                        date: top.date,
                        isListening: analyzer.isListening))
                }
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
