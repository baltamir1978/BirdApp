import Foundation
import Observation

@Observable
class DetectionStore {
    private(set) var detections: [BirdDetection] = []
    private(set) var latestDetection: BirdDetection?

    private let storageKey = "bird_detections"

    init() {
        load()
    }

    func add(_ detection: BirdDetection) {
        detections.insert(detection, at: 0)
        latestDetection = detection
        save()
    }

    func clear() {
        detections = []
        latestDetection = nil
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(detections) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode([BirdDetection].self, from: data) else { return }
        detections = saved
    }
}
