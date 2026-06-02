import CoreLocation
import SwiftUI

struct ContentView: View {
    @State private var analyzer = AudioAnalyzer()
    @State private var store = DetectionStore()
    @State private var locationManager = LocationManager()
    @State private var modelManager = ModelManager()

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
            locationManager.start()

            analyzer.locationProvider = { [locationManager] in
                locationManager.location?.coordinate
            }
            analyzer.configure(modelPath: modelManager.modelPath,
                               labelsPath: modelManager.labelsPath,
                               weightsPath: modelManager.weightsPath)

            analyzer.onDetection = { [store] detection in
                Task { @MainActor in
                    var det = detection
                    let info = await WikipediaImageService.shared.info(for: det.scientificName)
                    det.imageURL = info.imageURL
                    det.localizedName = info.localizedName
                    store.add(det)
                }
            }

            analyzer.startListening()
        }
    }
}

#Preview {
    ContentView()
}
