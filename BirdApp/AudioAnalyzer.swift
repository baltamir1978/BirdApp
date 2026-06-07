import AVFoundation
import CoreLocation
import Observation

@Observable
class AudioAnalyzer {
    private(set) var isListening = false
    private(set) var audioLevel: Float = 0.0
    var errorMessage: String?

    // Emits the ranked candidate list (best first) for one detection event.
    var onDetections: (([BirdDetection]) -> Void)?

    // Injected by ContentView so each detection is tagged with the current GPS fix
    var locationProvider: (() -> CLLocationCoordinate2D?)?

    private let engine = AVAudioEngine()
    private let birdNet = BirdNETAnalyzer()
    private let analysisQueue = DispatchQueue(label: "bird.analysis", qos: .userInitiated)
    private let targetSampleRate: Double = 48_000

    // MARK: - Configuration

    func configure(modelPath: String?, labelsPath: String?, weightsPath: String? = nil) {
        birdNet.locationProvider = locationProvider
        birdNet.setup(modelPath: modelPath, labelsPath: labelsPath, weightsPath: weightsPath)
        birdNet.onDetections = { [weak self] candidates in
            guard let self else { return }
            let coord = self.locationProvider?()
            let detections = candidates.map { c in
                BirdDetection(commonName: c.common,
                              scientificName: c.scientific,
                              confidence: c.confidence,
                              coordinate: coord)
            }
            DispatchQueue.main.async { self.onDetections?(detections) }
        }
    }

    // MARK: - Lifecycle

    func startListening() {
        guard !isListening else { return }
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                if granted { self?.startEngine() }
                else { self?.errorMessage = NSLocalizedString("Microphone access denied. Enable it in Settings.", comment: "") }
            }
        }
    }

    func stopListening() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        isListening = false
        audioLevel = 0
    }

    // MARK: - Engine

    private func startEngine() {
        let session = AVAudioSession.sharedInstance()
        do {
            // Unprocessed input (.measurement) disables the system's voice DSP
            // (AGC, noise suppression, echo cancellation) that would distort
            // bird song — equivalent to whoBIRD's UNPROCESSED audio source.
            let unprocessed = UserDefaults.standard.bool(forKey: "unprocessed_audio")
            try session.setCategory(.record, mode: unprocessed ? .measurement : .default)
            try session.setPreferredSampleRate(targetSampleRate)
            try session.setActive(true)
            // Prefer the built-in mic over Bluetooth/accessory inputs.
            if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(builtIn)
            }
            // `.measurement` mode disables the system AGC, which on iPhone leaves
            // the raw input level very low — quiet bird song then falls under the
            // signal gate and is never classified. Push hardware gain to max where
            // the device allows it to compensate.
            if session.isInputGainSettable {
                try? session.setInputGain(1.0)
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(standardFormatWithSampleRate: targetSampleRate, channels: 1) else { return }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handleBuffer(buffer, inputFormat: inputFormat, targetFormat: targetFormat)
        }

        do {
            try engine.start()
            isListening = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            inputNode.removeTap(onBus: 0)
        }
    }

    // MARK: - Buffer Processing

    private func handleBuffer(_ buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat, targetFormat: AVAudioFormat) {
        let buf: AVAudioPCMBuffer?
        if inputFormat.sampleRate == targetSampleRate && inputFormat.channelCount == 1 {
            buf = buffer
        } else {
            buf = convert(buffer: buffer, from: inputFormat, to: targetFormat)
        }
        guard let converted = buf else { return }

        // Update VU meter
        if let data = converted.floatChannelData?[0] {
            let count = Int(converted.frameLength)
            let rms = sqrt(UnsafeBufferPointer(start: data, count: count).map { $0 * $0 }.reduce(0, +) / Float(max(count, 1)))
            DispatchQueue.main.async { [weak self] in self?.audioLevel = rms }
        }

        analysisQueue.async { [weak self] in
            self?.birdNet.analyze(buffer: converted)
        }
    }

    private func convert(buffer: AVAudioPCMBuffer, from src: AVAudioFormat, to dst: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: src, to: dst) else { return nil }
        let ratio = dst.sampleRate / src.sampleRate
        let outFrames = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio))
        guard let out = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: outFrames) else { return nil }
        var provided = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if !provided { provided = true; status.pointee = .haveData; return buffer }
            status.pointee = .noDataNow; return nil
        }
        return error == nil ? out : nil
    }
}
