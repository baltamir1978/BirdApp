import Accelerate
import CoreLocation
import Foundation

// Implements the BirdNET v2.4 meta-model location filter.
//
// The meta-model predicts which species are plausible at a given
// latitude / longitude / week-of-year, using a small MLP:
//
//   [sin(lat·freq), sin(lon·freq), sin(week·freq)]  →  [144]
//   linear(144→256) + ReLU
//   linear(256→512) + ReLU
//   linear(512→1024) + ReLU
//   linear(1024→6522) — compare logit to threshold (avoids sigmoid)
//
// Weights are pre-extracted from the TFLite float16 model and stored
// in meta_weights.bin (28 MB, bundled with the app).
final class LocationFilter {

    // sigmoid(x) > 0.03  ⟺  x > log(0.03/0.97)
    private static let logitThreshold: Float = log(0.03 / (1.0 - 0.03))

    private let freq: [Float]   // [48]
    private let W1: [Float]     // [256 × 144], row-major
    private let b1: [Float]     // [256]
    private let W2: [Float]     // [512 × 256]
    private let b2: [Float]     // [512]
    private let W3: [Float]     // [1024 × 512]
    private let b3: [Float]     // [1024]
    private let W4: [Float]     // [6522 × 1024]
    private let b4: [Float]     // [6522]

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
            let f  = read(48),
            let w1 = read(256 * 144),  let b1_ = read(256),
            let w2 = read(512 * 256),  let b2_ = read(512),
            let w3 = read(1024 * 512), let b3_ = read(1024),
            let w4 = read(6522 * 1024), let b4_ = read(6522)
        else { return nil }

        freq = f
        W1 = w1; b1 = b1_
        W2 = w2; b2 = b2_
        W3 = w3; b3 = b3_
        W4 = w4; b4 = b4_
    }

    // Returns a Bool mask [6522]: true = species is plausible at this location/date.
    func allowedMask(lat: Double, lon: Double, date: Date) -> [Bool] {
        let latN = Float(lat / 90.0)
        let lonN = Float(lon / 180.0)
        let wkN  = weekNorm(from: date)

        var features = [Float](repeating: 0, count: 144)
        for i in 0..<48 {
            features[i]      = sin(latN * freq[i])
            features[i + 48] = sin(lonN * freq[i])
            features[i + 96] = sin(wkN  * freq[i])
        }

        var h1 = linear(W1, b1, rows: 256,  cols: 144,  input: features)
        relu(&h1)
        var h2 = linear(W2, b2, rows: 512,  cols: 256,  input: h1)
        relu(&h2)
        var h3 = linear(W3, b3, rows: 1024, cols: 512,  input: h2)
        relu(&h3)
        let logits = linear(W4, b4, rows: 6522, cols: 1024, input: h3)

        return logits.map { $0 > Self.logitThreshold }
    }

    // MARK: - Math

    // Computes y = W · x + b using vDSP (W is row-major [M × N]).
    private func linear(_ W: [Float], _ b: [Float], rows M: Int, cols N: Int, input x: [Float]) -> [Float] {
        var y = [Float](repeating: 0, count: M)
        W.withUnsafeBufferPointer { wp in
            x.withUnsafeBufferPointer { xp in
                y.withUnsafeMutableBufferPointer { yp in
                    vDSP_mmul(wp.baseAddress!, 1,
                              xp.baseAddress!, 1,
                              yp.baseAddress!, 1,
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

    private func weekNorm(from date: Date) -> Float {
        let doy = Float(Calendar.current.ordinality(of: .day, in: .year, for: date) ?? 1)
        let week = max(1.0, min(48.0, doy / 365.0 * 48.0))
        return week / 48.0
    }
}
