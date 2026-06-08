import WidgetKit
import SwiftUI

@main
struct BirdWidgetBundle: WidgetBundle {
    var body: some Widget {
        ListenWidget()
        LastBirdWidget()
    }
}

// App green, hardcoded here so the widget target doesn't need the app's asset catalog.
let birdGreen = Color(red: 0.30, green: 0.69, blue: 0.31)

// MARK: - Shared timeline

struct BirdEntry: TimelineEntry {
    let date: Date
    let snapshot: BirdSnapshot?
    let image: Data?
}

struct BirdProvider: TimelineProvider {
    func placeholder(in context: Context) -> BirdEntry {
        BirdEntry(date: Date(),
                  snapshot: BirdSnapshot(name: "Common Blackbird", scientific: "Turdus merula",
                                         confidence: 0.92, imageURL: nil, date: Date(), isListening: true),
                  image: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (BirdEntry) -> Void) {
        Task { completion(await makeEntry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BirdEntry>) -> Void) {
        Task { completion(Timeline(entries: [await makeEntry()], policy: .never)) }
    }

    private func makeEntry() async -> BirdEntry {
        let snap = BirdWidgetData.load()
        return BirdEntry(date: Date(), snapshot: snap, image: await loadImageData(snap?.imageURL))
    }
}

// Widgets can't lazily load remote images — fetch the bytes in the provider.
func loadImageData(_ urlString: String?) async -> Data? {
    guard let urlString, let url = URL(string: urlString) else { return nil }
    return try? await URLSession.shared.data(from: url).0
}
