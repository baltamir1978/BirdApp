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

    // History de-duplication: while the same species keeps being detected, collapse
    // it into a single history entry instead of one per ~0.8 s analysis window. A new
    // entry for that species is only started once this much time has passed since the
    // previous one (matches the user's "added once per ~10 minutes" expectation).
    private let dedupWindow: TimeInterval = 600   // 10 minutes

    // Auto-clears the live candidates after a period of no new detections, so a
    // stale result doesn't linger on screen while listening continues.
    private var clearTask: Task<Void, Never>?

    init() {
        load()
    }

    func add(_ detection: BirdDetection) {
        latestDetection = detection
        record(detection)
    }

    func setCandidates(_ candidates: [BirdDetection]) {
        latestCandidates = candidates
        if let top = candidates.first {
            latestDetection = top
            record(top)
        }
        scheduleAutoClear()
    }

    // Insert into history, collapsing a continuing run of the same species into one
    // entry. If that species was already logged within `dedupWindow`, just keep the
    // best confidence on the existing entry instead of adding a duplicate.
    private func record(_ detection: BirdDetection) {
        if let idx = detections.firstIndex(where: {
            $0.scientificName == detection.scientificName &&
            detection.date.timeIntervalSince($0.date) < dedupWindow
        }) {
            if detection.confidence > detections[idx].confidence {
                detections[idx].confidence = detection.confidence
            }
        } else {
            detections.insert(detection, at: 0)
        }
        save()
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
