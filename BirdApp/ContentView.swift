import CoreLocation
import SwiftUI

struct ContentView: View {
    @State private var analyzer = AudioAnalyzer()
    @State private var store = DetectionStore()
    @State private var locationManager = LocationManager()
    @State private var modelManager = ModelManager()
    @State private var photoIdentifier = PhotoIdentifier()
    @State private var incomingPhoto = IncomingPhotoRouter()

    @AppStorage("onboarding_done") private var onboardingDone = false
    @AppStorage("background_listening") private var backgroundListening = false
    @AppStorage("background_listening_minutes") private var backgroundMinutes = 30.0
    @Environment(\.scenePhase) private var scenePhase
    @State private var showOnboarding = false
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            ListenView(analyzer: analyzer, store: store, modelManager: modelManager)
                .tabItem { Label("Listen", systemImage: "mic.fill") }
                .tag(0)

            PhotoView(identifier: photoIdentifier, store: store, incoming: incomingPhoto)
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
        // A photo shared from Photos: the extension parked it in the App Group
        // and opened us on it. Jump to the Photo tab, which picks it up.
        .onOpenURL { url in
            if incomingPhoto.handle(url) { selectedTab = 1 }
        }
        // Widget "Stop" reached us via a Darwin signal re-posted as this notification.
        .onReceive(NotificationCenter.default.publisher(for: .stopBirdListening)) { _ in
            analyzer.stopListening()
        }
        // Background listening policy: on minimising, keep the mic alive only if
        // the user opted in and we're actually listening — and arm an auto-stop so
        // a forgotten session can't drain the battery. Otherwise stop, as before.
        // Returning to the foreground cancels any pending auto-stop.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                if backgroundListening, analyzer.isListening {
                    analyzer.scheduleBackgroundStop(after: backgroundMinutes * 60)
                } else {
                    analyzer.stopListening()
                }
            case .active:
                analyzer.cancelBackgroundStop()
                // Safety net: if the share extension failed to open us, the
                // photo is still sitting in the App Group. Claim it now rather
                // than lose the shot.
                if incomingPhoto.claimPending() { selectedTab = 1 }
            default:
                break
            }
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
        // Audio↔photo fusion: hand the photo classifier whatever the microphone
        // heard in the last few minutes. History is the source of truth here — it
        // survives switching tabs, which is exactly the flow (hear it, find it,
        // photograph it). A nil `source` is an audio entry saved before the photo
        // tab existed.
        photoIdentifier.recentlyHeardProvider = { [store] in
            let cutoff = Date().addingTimeInterval(-PhotoIdentifier.fusionWindow)
            var heard: [String: Date] = [:]
            for detection in store.detections where detection.source != .photo && detection.date > cutoff {
                let key = detection.scientificName.lowercased()
                if let seen = heard[key], seen >= detection.date { continue }
                heard[key] = detection.date
            }
            return heard
        }
        photoIdentifier.configure(modelPath: modelManager.photoModelPath,
                                  iberianModelPath: modelManager.iberianPhotoModelPath,
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
