import Accelerate
import AVFoundation
import CoreML
import CoreLocation

// Real-time inference using a CoreML classifier + Swift mel spectrogram.
// Falls back to the mock identifier when no model is present.
//
// Pipeline:
//   raw audio (48 kHz mono) → signal gates → high-pass → MelSpectrogramExtractor
//                           → CoreML classifier → soft location filter
//                           → temporal smoothing → top-N candidates
//
// Model inputs:  mel_spec_1 [1, 96, 511, 1] + mel_spec_2 [1, 96, 511, 1]
// Model output:  classifierOutput [1, N]  — raw logits per species (apply sigmoid)
final class BirdNETAnalyzer: NSObject {

    typealias Candidate = (common: String, scientific: String, confidence: Double)

    // Emits the ranked list of candidates above threshold (best first).
    var onDetections: (([Candidate]) -> Void)?
    var locationProvider: (() -> CLLocationCoordinate2D?)?
    private(set) var usingRealModel = false

    private var classifier: MLModel?
    private var labels: [String] = []
    private var locationFilter: LocationFilter?
    private let melExtractor = MelSpectrogramExtractor()

    private var accumulator: [Float] = []
    private let windowSize = 144_000          // 3 s × 48 000 Hz
    private let hopSize    = 38_400           // 0.8 s slide → ~73 % overlap (whoBIRD-style)
    private let maxCandidates = 5
    private let smoothingWindows = 3
    private var smoothingHistory: [[Float]] = []
    private let mockIdentifier = BirdIdentifier()

    // MARK: - Setup

    func setup(modelPath: String?, labelsPath: String?, weightsPath: String? = nil) {
        classifier = nil
        usingRealModel = false
        accumulator = []
        smoothingHistory = []
        labels = []
        locationFilter = nil

        if let path = labelsPath,
           let content = try? String(contentsOfFile: path, encoding: .utf8) {
            labels = content.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        }

        if let path = weightsPath {
            locationFilter = LocationFilter(weightsPath: path)
        }

        guard let path = modelPath else { return }

        do {
            let url = URL(fileURLWithPath: path)
            let config = MLModelConfiguration()
            config.computeUnits = .all
            classifier = try MLModel(contentsOf: url, configuration: config)
            usingRealModel = true
        } catch {
            print("[BirdNETAnalyzer] CoreML load failed: \(error)")
        }
    }

    // MARK: - Analysis

    func analyze(buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        accumulator.append(contentsOf: samples)

        while accumulator.count >= windowSize {
            let window = Array(accumulator.prefix(windowSize))
            accumulator = Array(accumulator.dropFirst(hopSize))   // dense overlap

            if usingRealModel {
                runInference(on: window)
            } else {
                mockIdentifier.identify(samples: window) { [weak self] detection in
                    guard let d = detection else { return }
                    self?.onDetections?([(d.commonName, d.scientificName, d.confidence)])
                }
            }
        }
    }

    // MARK: - CoreML Inference

    private func runInference(on samples: [Float]) {
        guard let model = classifier else { return }

        let d = UserDefaults.standard

        // Signal-quality gates (run on raw audio, before the expensive model).
        if d.bool(forKey: "clip_gate"), Self.isClipped(samples) { return }
        if d.bool(forKey: "signal_gate"), !Self.hasBirdSignal(samples) { return }

        // Optional high-pass — removes low-frequency noise (traffic, wind, hum)
        // before BirdNET's per-window min-max normalisation.
        let processed: [Float]
        if d.bool(forKey: "high_pass_filter") {
            let cutoff = d.double(forKey: "high_pass_cutoff")
            processed = Self.highPassFiltered(samples, cutoff: Float(cutoff > 0 ? cutoff : 200))
        } else {
            processed = samples
        }

        guard let (spec1, spec2) = melExtractor.extract(from: processed) else {
            print("[BirdNETAnalyzer] Mel spectrogram extraction failed")
            return
        }

        do {
            let input = try MLDictionaryFeatureProvider(dictionary: [
                "mel_spec_1": MLFeatureValue(multiArray: spec1),
                "mel_spec_2": MLFeatureValue(multiArray: spec2)
            ])
            let output = try model.prediction(from: input)
            if let probs = output.featureValue(for: "classifierOutput")?.multiArrayValue {
                process(probs: probs)
            }
        } catch {
            print("[BirdNETAnalyzer] Inference error: \(error)")
        }
    }

    // Combine acoustic + sensitivity + soft location filter + temporal smoothing,
    // then emit the top candidates above threshold.
    private func process(probs: MLMultiArray) {
        let d = UserDefaults.standard
        let count = probs.count

        // Sensitivity scales the sigmoid slope (BirdNET-Analyzer style): higher = more eager.
        let sStored = d.double(forKey: "detection_sensitivity")
        let sensitivity = Float(sStored > 0 ? sStored : 1.0)

        // whoBIRD-style soft location/season filter.
        let influence = Float(d.double(forKey: "location_filter_influence"))
        var metaScores: [Float]? = nil
        if influence > 0, let filter = locationFilter, let coord = locationProvider?() {
            filter.update(lat: coord.latitude, lon: coord.longitude, date: Date())
            if filter.metaScores.count == count { metaScores = filter.metaScores }
        }

        var combined = [Float](repeating: 0, count: count)
        for i in 0..<count {
            var p = 1 / (1 + exp(-sensitivity * probs[i].floatValue))
            if let metaScores {
                p *= (1 - influence) + influence * metaScores[i]
            }
            combined[i] = p
        }

        // Temporal smoothing: average the last N overlapping windows so a one-off
        // spike can't trigger a detection (consensus), and confidence is steadier.
        let scores: [Float]
        if d.bool(forKey: "temporal_smoothing") {
            smoothingHistory.append(combined)
            if smoothingHistory.count > smoothingWindows { smoothingHistory.removeFirst() }
            scores = Self.average(smoothingHistory, count: count)
        } else {
            smoothingHistory.removeAll()
            scores = combined
        }

        let stored = d.double(forKey: "confidence_threshold")
        let threshold = Float(stored > 0 ? stored : 0.5)

        let ranked = scores.indices.sorted { scores[$0] > scores[$1] }.prefix(maxCandidates)
        let candidates: [Candidate] = ranked.compactMap { i in
            guard scores[i] >= threshold else { return nil }
            let label = i < labels.count ? labels[i] : "Unknown_Unknown"
            let parts = label.split(separator: "_", maxSplits: 1).map(String.init)
            return (common: parts.count > 1 ? parts[1] : label,
                    scientific: parts.first ?? label,
                    confidence: Double(scores[i]))
        }

        guard !candidates.isEmpty else { return }
        onDetections?(candidates)
    }

    private static func average(_ history: [[Float]], count: Int) -> [Float] {
        guard history.count > 1 else { return history.last ?? [] }
        var acc = [Float](repeating: 0, count: count)
        for v in history { vDSP_vadd(acc, 1, v, 1, &acc, 1, vDSP_Length(count)) }
        var divisor = Float(history.count)
        vDSP_vsdiv(acc, 1, &divisor, &acc, 1, vDSP_Length(count))
        return acc
    }

    // MARK: - Signal-quality gates

    // Skip windows with significant digital clipping (saturated mic input).
    private static func isClipped(_ x: [Float]) -> Bool {
        var clipped = 0
        for v in x where abs(v) >= 0.99 { clipped += 1 }
        return Float(clipped) / Float(x.count) > 0.005   // > 0.5 % of samples
    }

    // Require real signal in the bird band (~>1.5 kHz), rejecting silence and
    // low-frequency-only noise (traffic, wind) where no bird is singing.
    private static func hasBirdSignal(_ x: [Float]) -> Bool {
        var meanSq: Float = 0
        vDSP_measqv(x, 1, &meanSq, vDSP_Length(x.count))
        let rms = sqrt(meanSq)
        // Low floor: with `.measurement` (unprocessed) capture there is no AGC,
        // so genuine bird song sits near the noise floor in absolute terms. The
        // bird-band ratio below — not this absolute level — is the real filter.
        if rms < 0.0005 { return false }                 // near-silence only

        let hp = highPassFiltered(x, cutoff: 1500)
        var hpMeanSq: Float = 0
        vDSP_measqv(hp, 1, &hpMeanSq, vDSP_Length(hp.count))
        let hpRms = sqrt(hpMeanSq)
        return hpRms / rms > 0.1                          // bird-band energy fraction
    }

    // MARK: - High-Pass Filter

    // Second-order RBJ high-pass biquad (Butterworth, Q = 0.707).
    private static func highPassFiltered(_ x: [Float],
                                         cutoff: Float = 200,
                                         sampleRate: Float = 48_000) -> [Float] {
        let w0 = 2 * Float.pi * cutoff / sampleRate
        let cosw0 = cos(w0), sinw0 = sin(w0)
        let q: Float = 0.7071
        let alpha = sinw0 / (2 * q)
        let a0 = 1 + alpha

        let b0 = ((1 + cosw0) / 2) / a0
        let b1 = (-(1 + cosw0))   / a0
        let b2 = ((1 + cosw0) / 2) / a0
        let a1 = (-2 * cosw0)     / a0
        let a2 = (1 - alpha)      / a0

        var y = [Float](repeating: 0, count: x.count)
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
        for n in 0..<x.count {
            let xn = x[n]
            let yn = b0 * xn + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            y[n] = yn
            x2 = x1; x1 = xn
            y2 = y1; y1 = yn
        }
        return y
    }
}
