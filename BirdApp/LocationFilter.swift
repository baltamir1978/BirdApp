import Accelerate
import CoreLocation
import Foundation

// BirdNET v2.4 location/season meta-model + whoBIRD-style soft filtering.
//
// The meta-model is a small MLP that predicts how likely each species is at a
// given latitude / longitude / week-of-year:
//
//   [lat, lon, week]
//      → Fourier embedding (144)        ← reverse-engineered from MNET_CONVERT,
//                                          verified corr 0.9997 vs the TFLite model
//      → linear(144→256)  + ReLU
//      → linear(256→512)  + ReLU
//      → linear(512→1024) + ReLU
//      → linear(1024→6522) → sigmoid    = per-species occurrence probability
//
// Embedding (per scalar input, normalised to `n`):
//   emb[i] = √2 · sin(2π·n + i·π/48),  i = 0..47
//   lat_n = (lat + 90)/180   lon_n = (lon + 180)/360   week_n = week/48
//
// Weights (W1..b4) are in meta_weights.bin (the leading 48-float block is the
// old, unused freq vector — kept only to preserve byte offsets).
//
// Soft filtering follows whoBIRD: the raw probability is mapped to a stepped
// score, blended 50/50 with the annual maximum (helps migratory birds), and
// later combined multiplicatively with the acoustic confidence.
final class LocationFilter {

    private let W1: [Float], b1: [Float]   // [256×144]
    private let W2: [Float], b2: [Float]   // [512×256]
    private let W3: [Float], b3: [Float]   // [1024×512]
    private let W4: [Float], b4: [Float]   // [6522×1024]
    private let numClasses = 6522

    // Cached per-species scores in [0,1] for the current location/week.
    private(set) var metaScores: [Float] = []
    private var cacheKey: String?

    init?(weightsPath: String) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: weightsPath),
                                   options: .mappedIfSafe) else { return nil }
        guard data.count > 8,
              data[0] == 0x42, data[1] == 0x4D, data[2] == 0x45, data[3] == 0x54
        else { return nil }

        var offset = 8
        func read(_ count: Int) -> [Float]? {
            let bytes = count * MemoryLayout<Float>.size
            guard offset + bytes <= data.count else { return nil }
            defer { offset += bytes }
            return data[offset..<(offset + bytes)].withUnsafeBytes {
                Array($0.bindMemory(to: Float.self))
            }
        }

        guard
            let _  = read(48),                                       // unused freq block
            let w1 = read(256 * 144),  let b1_ = read(256),
            let w2 = read(512 * 256),  let b2_ = read(512),
            let w3 = read(1024 * 512), let b3_ = read(1024),
            let w4 = read(6522 * 1024), let b4_ = read(6522)
        else { return nil }

        W1 = w1; b1 = b1_; W2 = w2; b2 = b2_
        W3 = w3; b3 = b3_; W4 = w4; b4 = b4_
    }

    // Recompute the cached per-species scores for this location/date.
    // Cheap to call repeatedly: it no-ops unless the rounded location or week changed.
    func update(lat: Double, lon: Double, date: Date) {
        let week = Self.weekOfYear(date)
        let key = "\(Int((lat * 100).rounded()))_\(Int((lon * 100).rounded()))_\(week)"
        guard key != cacheKey else { return }
        cacheKey = key

        let current = probabilities(lat: lat, lon: lon, week: week)

        // Annual maximum per species (whoBIRD "extended" mode).
        var annualMax = [Float](repeating: 0, count: numClasses)
        for w in 1...48 {
            let p = probabilities(lat: lat, lon: lon, week: w)
            vDSP_vmax(p, 1, annualMax, 1, &annualMax, 1, vDSP_Length(numClasses))
        }

        var scores = [Float](repeating: 0, count: numClasses)
        for i in 0..<numClasses {
            scores[i] = 0.5 * Self.step(current[i]) + 0.5 * Self.step(annualMax[i])
        }
        metaScores = scores
    }

    // MARK: - Meta-model

    private func probabilities(lat: Double, lon: Double, week: Int) -> [Float] {
        var features = embedding(lat: lat, lon: lon, week: week)
        var h1 = linear(W1, b1, rows: 256,  cols: 144,  input: features); relu(&h1)
        var h2 = linear(W2, b2, rows: 512,  cols: 256,  input: h1);       relu(&h2)
        var h3 = linear(W3, b3, rows: 1024, cols: 512,  input: h2);       relu(&h3)
        var logits = linear(W4, b4, rows: numClasses, cols: 1024, input: h3)
        // sigmoid in place
        for i in 0..<logits.count { logits[i] = 1 / (1 + exp(-logits[i])) }
        features.removeAll()
        return logits
    }

    // emb[i] = √2 · sin(2π·n + i·π/48) for each of lat/lon/week.
    private func embedding(lat: Double, lon: Double, week: Int) -> [Float] {
        let latN  = Float((lat + 90) / 180)
        let lonN  = Float((lon + 180) / 360)
        let weekN = Float(week) / 48
        let twoPi = 2 * Float.pi
        let step  = Float.pi / 48
        let sqrt2 = Float(2).squareRoot()

        var f = [Float](repeating: 0, count: 144)
        for i in 0..<48 {
            let phase = Float(i) * step
            f[i]      = sqrt2 * sin(latN  * twoPi + phase)
            f[i + 48] = sqrt2 * sin(lonN  * twoPi + phase)
            f[i + 96] = sqrt2 * sin(weekN * twoPi + phase)
        }
        return f
    }

    // whoBIRD stepped score: very-likely → 1, likely → 0.8, possible → 0.5, else 0.
    private static func step(_ p: Float) -> Float {
        if p >= 0.01  { return 1.0 }
        if p >= 0.008 { return 0.8 }
        if p >= 0.001 { return 0.5 }
        return 0.0
    }

    private static func weekOfYear(_ date: Date) -> Int {
        let cal = Calendar.current
        let doy = cal.ordinality(of: .day, in: .year, for: date) ?? 1
        let daysInYear = cal.range(of: .day, in: .year, for: date)?.count ?? 365
        let week = Int((Double(doy) / Double(daysInYear) * 48).rounded(.up))
        return max(1, min(48, week))
    }

    // MARK: - Math

    private func linear(_ W: [Float], _ b: [Float], rows M: Int, cols N: Int, input x: [Float]) -> [Float] {
        var y = [Float](repeating: 0, count: M)
        W.withUnsafeBufferPointer { wp in
            x.withUnsafeBufferPointer { xp in
                y.withUnsafeMutableBufferPointer { yp in
                    vDSP_mmul(wp.baseAddress!, 1, xp.baseAddress!, 1, yp.baseAddress!, 1,
                              vDSP_Length(M), 1, vDSP_Length(N))
                }
            }
        }
        vDSP_vadd(y, 1, b, 1, &y, 1, vDSP_Length(M))
        return y
    }

    private func relu(_ x: inout [Float]) {
        var zero: Float = 0
        vDSP_vthr(x, 1, &zero, &x, 1, vDSP_Length(x.count))
    }
}
