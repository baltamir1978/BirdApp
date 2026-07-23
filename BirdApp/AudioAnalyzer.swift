import AVFoundation
import CoreLocation
import Observation

@Observable
class AudioAnalyzer {
    // What the recognition pipeline is currently doing, for the live UI indicator.
    enum Phase: Equatable {
        case idle                                   // not listening
        case listening                              // listening, no qualifying sound yet
        case analyzing                              // a window is going through the model
        case thinking(name: String, confidence: Double)  // best guess, below threshold
    }

    private(set) var isListening = false
    private(set) var audioLevel: Float = 0.0
    private(set) var phase: Phase = .idle
    var errorMessage: String?

    // Coalesce rapid phase events: an idle window shouldn't immediately wipe a
    // "thinking" hint that's only a window old, or the label would flicker.
    private var lastThinkingAt: Date = .distantPast

    // Emits the ranked candidate list (best first) for one detection event.
    var onDetections: (([BirdDetection]) -> Void)?

    // Injected by ContentView so each detection is tagged with the current GPS fix
    var locationProvider: (() -> CLLocationCoordinate2D?)?

    private let engine = AVAudioEngine()
    private let birdNet = BirdNETAnalyzer()
    private let analysisQueue = DispatchQueue(label: "bird.analysis", qos: .userInitiated)
    private let targetSampleRate: Double = 48_000

    // Interruption handling (phone calls, Siri, another audio app) so background
    // listening survives them instead of dying silently.
    private var interruptionObserver: NSObjectProtocol?
    private var wasListeningBeforeInterruption = false
    // Auto-stop timer for background listening, so a forgotten session doesn't
    // drain the battery all night.
    private var backgroundStopWorkItem: DispatchWorkItem?

    init() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                self?.handleInterruption(note)
            }
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }

    // MARK: - Configuration

    func configure(modelPath: String?, labelsPath: String?, localizedLabelsPath: String? = nil, weightsPath: String? = nil) {
        birdNet.locationProvider = locationProvider
        birdNet.setup(modelPath: modelPath, labelsPath: labelsPath,
                      localizedLabelsPath: localizedLabelsPath, weightsPath: weightsPath)
        birdNet.onDetections = { [weak self] candidates in
            guard let self else { return }
            let coord = self.locationProvider?()
            let detections = candidates.map { c -> BirdDetection in
                var d = BirdDetection(commonName: c.common,
                                      scientificName: c.scientific,
                                      confidence: c.confidence,
                                      coordinate: coord)
                d.localizedName = c.localized   // native common name from the localized labels
                return d
            }
            DispatchQueue.main.async {
                self.phase = .listening   // a confirmed result; the card takes over the UI
                self.onDetections?(detections)
            }
        }

        // Live pipeline feedback (all delivered on the analysis queue).
        birdNet.onAnalyzing = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.isListening else { return }
                self.phase = .analyzing
            }
        }
        birdNet.onThinking = { [weak self] name, confidence in
            DispatchQueue.main.async {
                guard let self, self.isListening else { return }
                self.lastThinkingAt = Date()
                self.phase = .thinking(name: name, confidence: confidence)
            }
        }
        birdNet.onIdleWindow = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.isListening else { return }
                // Don't clobber a very recent "thinking" hint with a single quiet
                // window — only fall back to plain listening once it's gone stale.
                if Date().timeIntervalSince(self.lastThinkingAt) > 2.5 {
                    self.phase = .listening
                }
            }
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
        cancelBackgroundStop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        isListening = false
        audioLevel = 0
        phase = .idle
    }

    // MARK: - Background listening

    // Called when the app is backgrounded while listening and the user has opted
    // in: keep the engine running but arm an auto-stop so it can't run forever.
    func scheduleBackgroundStop(after seconds: TimeInterval) {
        cancelBackgroundStop()
        let item = DispatchWorkItem { [weak self] in self?.stopListening() }
        backgroundStopWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    func cancelBackgroundStop() {
        backgroundStopWorkItem?.cancel()
        backgroundStopWorkItem = nil
    }

    // MARK: - Interruptions

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            // Something took the audio session (a call, Siri, another app).
            if isListening {
                wasListeningBeforeInterruption = true
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
                isListening = false
                phase = .idle
            }
        case .ended:
            // Resume only if the system says we may and we were listening before.
            let opts = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
            if wasListeningBeforeInterruption, opts.contains(.shouldResume) {
                wasListeningBeforeInterruption = false
                startEngine()
            }
        @unknown default:
            break
        }
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
            phase = .listening
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
