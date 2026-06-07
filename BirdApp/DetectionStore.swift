import Foundation
import Observation

@Observable
class DetectionStore {
    private(set) var detections: [BirdDetection] = []
    private(set) var latestDetection: BirdDetection?
    // Ranked candidates for the most recent detection event (best first),
    // shown live in ListenView. Only the top one is persisted to history.
    private(set) var latestCandidates: [BirdDetection] = []

    private let storageKey = "bird_detections"

    // Auto-clears the live candidates after a period of no new detections, so a
    // stale result doesn't linger on screen while listening continues.
    private var clearTask: Task<Void, Never>?

    init() {
        load()
    }

    func add(_ detection: BirdDetection) {
        detections.insert(detection, at: 0)
        latestDetection = detection
        save()
    }

    func setCandidates(_ candidates: [BirdDetection]) {
        latestCandidates = candidates
        if let top = candidates.first {
            detections.insert(top, at: 0)
            latestDetection = top
            save()
        }
        scheduleAutoClear()
    }

    // Schedule clearing the live candidates after the configured display time.
    // A new detection resets the timer (cancels the pending clear). History is
    // untouched — only the on-screen ListenView result is dismissed.
    private func scheduleAutoClear() {
        clearTask?.cancel()
        let registered = UserDefaults.standard.double(forKey: "detection_display_seconds")
        let seconds = registered > 0 ? registered : 8
        clearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.latestCandidates = []
        }
    }

    // Delete one detection.
    func remove(_ detection: BirdDetection) {
        detections.removeAll { $0.id == detection.id }
        if latestDetection?.id == detection.id { latestDetection = detections.first }
        save()
    }

    // Delete every detection on the same calendar day.
    func removeDay(_ day: Date) {
        let cal = Calendar.current
        detections.removeAll { cal.isDate($0.date, inSameDayAs: day) }
        if let latest = latestDetection, cal.isDate(latest.date, inSameDayAs: day) {
            latestDetection = detections.first
        }
        save()
    }

    func clear() {
        detections = []
        latestDetection = nil
        latestCandidates = []
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
