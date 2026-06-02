import Accelerate
import CoreML
import Foundation

// Computes the two log-mel spectrograms expected by the BirdNET v2.4 CoreML classifier.
//
// Parameters confirmed from TFLite model inspection:
//   Sample rate : 48 000 Hz
//   Hop length  : 278 samples  (144 000 / 278 ≈ 511 frames, center=False)
//   FFT 1 / Mel 1 : window 2048, filterbank [96 × 1025]
//   FFT 2 / Mel 2 : window 1024, filterbank [96 × 513]
//   Mel bins    : 96
//   Frames      : 511
//   Log scale   : log(mel + 1e-10)
//
// Filterbank source (in order of preference):
//   1. filterbank1.bin / filterbank2.bin bundled with the app
//      (extracted from BirdNET TFLite via extract_birdnet.py --filterbanks-only)
//   2. Computed HTK mel-scale filterbank (mathematically equivalent fallback)
struct MelSpectrogramExtractor {

    private let hopLength: Int  = 278
    private let numMelBins: Int = 96
    private let numFrames: Int  = 511

    private let fftSetup2048: FFTSetup?
    private let fftSetup1024: FFTSetup?
    private let filterbank2048: [Float]   // flat [96 × 1025]
    private let filterbank1024: [Float]   // flat [96 × 513]

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
        guard let s1 = computeLogMel(samples: samples, fftSize: 2048,
                                     setup: fftSetup2048, filterbank: filterbank2048),
              let s2 = computeLogMel(samples: samples, fftSize: 1024,
                                     setup: fftSetup1024, filterbank: filterbank1024)
        else { return nil }
        return (s1, s2)
    }

    // MARK: - Log-Mel Spectrogram

    private func computeLogMel(samples: [Float],
                               fftSize: Int,
                               setup: FFTSetup?,
                               filterbank: [Float]) -> MLMultiArray? {
        guard let setup else { return nil }

        let numSpecBins = fftSize / 2 + 1
        let shape: [NSNumber] = [1, NSNumber(value: numMelBins), NSNumber(value: numFrames), 1]
        guard let output = try? MLMultiArray(shape: shape, dataType: .float32) else { return nil }
        let outPtr = output.dataPointer.bindMemory(to: Float.self,
                                                   capacity: numMelBins * numFrames)

        var hann = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hann, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        var windowed  = [Float](repeating: 0, count: fftSize)
        var realBuf   = [Float](repeating: 0, count: fftSize / 2)
        var imagBuf   = [Float](repeating: 0, count: fftSize / 2)
        var powerBuf  = [Float](repeating: 0, count: numSpecBins)
        var melBuf    = [Float](repeating: 0, count: numMelBins)

        let log2n = vDSP_Length(log2(Float(fftSize)))
        let scale = 1.0 / Float(fftSize)

        for frameIdx in 0..<numFrames {
            let start = frameIdx * hopLength

            // Hann-windowed frame
            vDSP_vmul(Array(samples[start..<start + fftSize]), 1,
                      hann, 1, &windowed, 1, vDSP_Length(fftSize))

            // Pack real → split complex (even→real, odd→imag)
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

            // One-sided power spectrum  |FFT[k]|²  (scaled)
            powerBuf[0]              = (realBuf[0] * scale) * (realBuf[0] * scale)
            powerBuf[numSpecBins-1]  = (imagBuf[0] * scale) * (imagBuf[0] * scale)
            for k in 1..<numSpecBins-1 {
                let r = realBuf[k] * scale; let i = imagBuf[k] * scale
                powerBuf[k] = r*r + i*i
            }

            // Mel filterbank: matrix-vector multiply  (96 × numSpecBins) · power
            // filterbank is stored row-major: filterbank[mel * numSpecBins + k]
            vDSP_mmul(filterbank, 1,
                      powerBuf, 1,
                      &melBuf, 1,
                      vDSP_Length(numMelBins), 1, vDSP_Length(numSpecBins))

            // log(mel + ε)
            for mel in 0..<numMelBins {
                outPtr[mel * numFrames + frameIdx] = log(max(melBuf[mel], 1e-10))
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
