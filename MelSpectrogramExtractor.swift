import Accelerate
import CoreML
import Foundation

// Computes the two spectrograms expected by the BirdNET v2.4 CoreML classifier.
//
// IMPORTANT: this is NOT a standard log-mel spectrogram. The exact transform was
// reverse-engineered from the BirdNET TFLite graph (model/MEL_SPEC1, MEL_SPEC2)
// and verified to reproduce the model's internal tensors with corr = 1.0:
//
//   1. Min-max normalise the whole 3 s window to [-1, 1]:
//          n = (x - min) / (max - min + 1e-6) * 2 - 1
//   2. Frame the signal and apply a *periodic* Hann window:
//          w[i] = 0.5 - 0.5·cos(2π·i / N)
//          SPEC1: N = 2048, hop = 278     SPEC2: N = 1024, hop = 280
//   3. rfft, then keep the REAL PART only (BirdNET casts the complex spectrum
//      to float — it does not take magnitude or power).
//   4. Mel filterbank matrix-multiply (signed result):
//          m = filterbank · realPart
//   5. Square, then raise to a fractional power (no log!):
//          out = (m²) ^ exp        SPEC1 exp = 0.229524…   SPEC2 exp = 0.190527…
//   6. Reverse the mel-frequency axis (BirdNET's ReverseV2).
//
// Filterbanks are loaded from filterbank1.bin / filterbank2.bin (the exact
// matrices extracted from the BirdNET model, verified byte-identical).
struct MelSpectrogramExtractor {

    private let numMelBins: Int = 96
    private let numFrames: Int  = 511

    private let fftSetup2048: FFTSetup?
    private let fftSetup1024: FFTSetup?
    private let filterbank2048: [Float]   // flat [96 × 1025]
    private let filterbank1024: [Float]   // flat [96 × 513]

    // Fractional-power exponents (BirdNET MEL_SPEC*/truediv_1, used as Pow_1 exponent)
    private let exp2048: Float = 0.229524090886116
    private let exp1024: Float = 0.190527305006981

    init() {
        fftSetup2048 = vDSP_create_fftsetup(11, FFTRadix(FFT_RADIX2))
        fftSetup1024 = vDSP_create_fftsetup(10, FFTRadix(FFT_RADIX2))

        filterbank2048 = MelSpectrogramExtractor.loadFilterbank(
            name: "filterbank1", rows: 96, cols: 1025,
            fftSize: 2048, sampleRate: 48_000)

        filterbank1024 = MelSpectrogramExtractor.loadFilterbank(
            name: "filterbank2", rows: 96, cols: 513,
            fftSize: 1024, sampleRate: 48_000)
    }

    // Returns (spec1, spec2) shaped [1, 96, 511, 1] or nil on failure.
    func extract(from samples: [Float]) -> (MLMultiArray, MLMultiArray)? {
        guard samples.count >= 144_000 else { return nil }

        // Step 1 — min-max normalise the window to [-1, 1] (shared by both specs).
        var lo: Float = 0, hi: Float = 0
        vDSP_minv(samples, 1, &lo, vDSP_Length(samples.count))
        vDSP_maxv(samples, 1, &hi, vDSP_Length(samples.count))
        let range = (hi - lo) + 1e-6
        var norm = [Float](repeating: 0, count: samples.count)
        var negLo = -lo
        vDSP_vsadd(samples, 1, &negLo, &norm, 1, vDSP_Length(samples.count)) // x - lo
        var invRange = 2.0 / range
        vDSP_vsmul(norm, 1, &invRange, &norm, 1, vDSP_Length(samples.count))  // *2/range
        var minusOne: Float = -1
        vDSP_vsadd(norm, 1, &minusOne, &norm, 1, vDSP_Length(samples.count))  // -1

        guard let s1 = computeSpec(samples: norm, fftSize: 2048, hop: 278,
                                   setup: fftSetup2048, filterbank: filterbank2048, exp: exp2048),
              let s2 = computeSpec(samples: norm, fftSize: 1024, hop: 280,
                                   setup: fftSetup1024, filterbank: filterbank1024, exp: exp1024)
        else { return nil }
        return (s1, s2)
    }

    // MARK: - Spectrogram

    private func computeSpec(samples: [Float],
                             fftSize: Int,
                             hop: Int,
                             setup: FFTSetup?,
                             filterbank: [Float],
                             exp: Float) -> MLMultiArray? {
        guard let setup else { return nil }

        let numSpecBins = fftSize / 2 + 1
        let shape: [NSNumber] = [1, NSNumber(value: numMelBins), NSNumber(value: numFrames), 1]
        guard let output = try? MLMultiArray(shape: shape, dataType: .float32) else { return nil }
        let outPtr = output.dataPointer.bindMemory(to: Float.self,
                                                   capacity: numMelBins * numFrames)

        // Periodic Hann window: 0.5 - 0.5·cos(2π·i / N)  (matches tf.signal, periodic=True)
        var hann = [Float](repeating: 0, count: fftSize)
        let twoPiOverN = 2.0 * Float.pi / Float(fftSize)
        for i in 0..<fftSize { hann[i] = 0.5 - 0.5 * cos(twoPiOverN * Float(i)) }

        var windowed = [Float](repeating: 0, count: fftSize)
        var realBuf  = [Float](repeating: 0, count: fftSize / 2)
        var imagBuf  = [Float](repeating: 0, count: fftSize / 2)
        var realPart = [Float](repeating: 0, count: numSpecBins) // real part of rfft, scaled
        var melBuf   = [Float](repeating: 0, count: numMelBins)

        let log2n = vDSP_Length(log2(Float(fftSize)))
        let halfScale: Float = 0.5   // vDSP_fft_zrip output is 2× the mathematical FFT

        for frameIdx in 0..<numFrames {
            let start = frameIdx * hop

            // Hann-windowed frame
            vDSP_vmul(Array(samples[start..<start + fftSize]), 1,
                      hann, 1, &windowed, 1, vDSP_Length(fftSize))

            // Pack real → split complex, forward FFT
            windowed.withUnsafeMutableBufferPointer { srcPtr in
                realBuf.withUnsafeMutableBufferPointer { rp in
                    imagBuf.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!,
                                                    imagp: ip.baseAddress!)
                        srcPtr.baseAddress!
                            .withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) {
                                vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2))
                            }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    }
                }
            }

            // Real part of the one-sided spectrum (×0.5 to match the true FFT).
            // Packed layout: realBuf[0] = DC, imagBuf[0] = Nyquist.
            realPart[0]             = realBuf[0] * halfScale
            realPart[numSpecBins-1] = imagBuf[0] * halfScale
            for k in 1..<numSpecBins-1 {
                realPart[k] = realBuf[k] * halfScale
            }

            // Mel filterbank: (96 × numSpecBins) · realPart  (signed)
            vDSP_mmul(filterbank, 1,
                      realPart, 1,
                      &melBuf, 1,
                      vDSP_Length(numMelBins), 1, vDSP_Length(numSpecBins))

            // out = (m²) ^ exp, written with the mel axis reversed.
            for mel in 0..<numMelBins {
                let v = melBuf[mel] * melBuf[mel]
                let out = powf(v, exp)
                outPtr[(numMelBins - 1 - mel) * numFrames + frameIdx] = out
            }
        }

        return output
    }

    // MARK: - Filterbank Loading

    private static func loadFilterbank(name: String, rows: Int, cols: Int,
                                       fftSize: Int, sampleRate: Float) -> [Float] {
        if let url = Bundle.main.url(forResource: name, withExtension: "bin"),
           let data = try? Data(contentsOf: url) {
            let expected = rows * cols * MemoryLayout<Float>.size
            if data.count == expected {
                return data.withUnsafeBytes { ptr in
                    Array(ptr.bindMemory(to: Float.self))
                }
            }
        }
        // Fallback: compute HTK mel filterbank (matches tf.signal.linear_to_mel_weight_matrix)
        return computeHTKFilterbank(fftSize: fftSize, sampleRate: sampleRate,
                                    numMelBins: rows, numSpecBins: cols)
    }

    private static func computeHTKFilterbank(fftSize: Int, sampleRate: Float,
                                             numMelBins: Int, numSpecBins: Int) -> [Float] {
        func hzToMel(_ hz: Float) -> Float { 2595 * log10(1 + hz / 700) }
        func melToHz(_ mel: Float) -> Float { 700 * (pow(10, mel / 2595) - 1) }

        let melMin = hzToMel(0)
        let melMax = hzToMel(sampleRate / 2)
        let melPoints = (0..<numMelBins + 2).map { i -> Float in
            melMin + Float(i) * (melMax - melMin) / Float(numMelBins + 1)
        }
        let hzPoints = melPoints.map(melToHz)
        let freqBins = (0..<numSpecBins).map { Float($0) * sampleRate / Float(fftSize) }

        var fb = [Float](repeating: 0, count: numMelBins * numSpecBins)
        for m in 0..<numMelBins {
            let lo = hzPoints[m]; let center = hzPoints[m+1]; let hi = hzPoints[m+2]
            for k in 0..<numSpecBins {
                let f = freqBins[k]
                if f >= lo && f <= center      { fb[m * numSpecBins + k] = (f - lo) / (center - lo) }
                else if f > center && f <= hi  { fb[m * numSpecBins + k] = (hi - f) / (hi - center) }
            }
        }
        return fb
    }
}
