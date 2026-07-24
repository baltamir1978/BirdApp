import CoreLocation
import CoreML
import Observation
import UIKit
import Vision

// Identifies a bird from a still photo, mirroring the audio pipeline:
//
//   foto → recorte por saliencia (Vision) → BirdPhoto_Classifier (CoreML)
//        → mapeo a la taxonomía de BirdNET → filtro suave de ubicación
//        → top-N candidatos
//
// The model is Google's AIY Birds V1 (MobileNetV2 trained on iNaturalist), 964
// species + a `__background__` class, converted to CoreML by
// `Tools/convert_photo_model.py`. Its labels are scientific names, so every
// result is re-mapped onto the BirdNET label list already bundled for audio —
// that gives us the localized common name and the LocationFilter index for free.
@Observable
@MainActor
final class PhotoIdentifier {

    enum Phase: Equatable {
        case idle
        case working
        case done
        case noBird              // the model's `__background__` class won
        case failed(String)
    }

    // Set when the winning candidate owes its place to having been heard singing
    // a moment ago, so the UI can say so instead of silently reordering.
    struct FusionHint: Equatable {
        let scientificName: String
        let heardAt: Date
    }

    private(set) var phase: Phase = .idle
    private(set) var candidates: [BirdDetection] = []
    // The square crop actually fed to the model — shown in the UI so the user can
    // see what was analysed (and reframe if it grabbed the wrong thing).
    private(set) var analysedImage: UIImage?
    private(set) var fusionHint: FusionHint?
    // Which classifier produced the current result, for the UI to disclose.
    private(set) var usedIberianModel = false
    // True when the crop came from the user's own framing rather than saliency.
    private(set) var usedManualRegion = false

    var locationProvider: (() -> CLLocationCoordinate2D?)?

    // Audio↔photo fusion: which species the microphone picked up recently
    // (lowercased scientific name → when it was last heard). A bird that was
    // singing here a minute ago is a much better bet than a visually similar
    // species from another continent, and both signals live in this same process.
    var recentlyHeardProvider: (() -> [String: Date])?

    private var visionModel: VNCoreMLModel?          // AIY Birds V1, worldwide
    private var iberianModel: VNCoreMLModel?         // Create ML, ~390 Iberian species
    private var locationFilter: LocationFilter?

    // Parallel to the model's class labels; nil where a species has no BirdNET
    // counterpart (mostly subspecies and a few exotics).
    private var birdNETIndex: [String: Int] = [:]      // scientific (lowercased) → BirdNET row
    private var commonNames: [String] = []             // English, by BirdNET row
    private var localizedNames: [String] = []          // device language, by BirdNET row

    private let backgroundLabel = "__background__"
    private let maxCandidates = 3

    var isReady: Bool { visionModel != nil || iberianModel != nil }
    var hasIberianModel: Bool { iberianModel != nil }

    // MARK: - Setup

    func configure(modelPath: String?,
                   iberianModelPath: String? = nil,
                   labelsPath: String?,
                   localizedLabelsPath: String?,
                   weightsPath: String?) {
        // BirdNET label table: "Scientific_Common" per row, index == meta-model class.
        if let labelsPath,
           let content = try? String(contentsOfFile: labelsPath, encoding: .utf8) {
            let rows = content.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            commonNames = rows.map { row in
                let parts = row.split(separator: "_", maxSplits: 1)
                return parts.count > 1 ? String(parts[1]) : row
            }
            for (i, row) in rows.enumerated() {
                let sci = String(row.split(separator: "_", maxSplits: 1).first ?? "")
                birdNETIndex[sci.lowercased()] = i
            }
        }

        if let localizedLabelsPath,
           let content = try? String(contentsOfFile: localizedLabelsPath, encoding: .utf8) {
            let names = content.split(separator: "\n").map { line -> String in
                let parts = line.split(separator: "_", maxSplits: 1)
                return parts.count > 1 ? String(parts[1]) : String(line)
            }
            localizedNames = names.count == commonNames.count ? names : []
        }

        if let weightsPath {
            locationFilter = LocationFilter(weightsPath: weightsPath)
        }

        visionModel = Self.loadModel(at: modelPath)
        iberianModel = Self.loadModel(at: iberianModelPath)
    }

    private static func loadModel(at path: String?) -> VNCoreMLModel? {
        guard let path else { return nil }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let ml = try MLModel(contentsOf: URL(fileURLWithPath: path), configuration: config)
            return try VNCoreMLModel(for: ml)
        } catch {
            print("[PhotoIdentifier] CoreML load failed for \(path): \(error)")
            return nil
        }
    }

    // MARK: - Model choice

    // Which classifier to run. The Iberian one knows ~390 species in far more
    // depth; the worldwide one knows 964 and is the only sensible choice abroad.
    enum ModelChoice: String {
        case automatic, iberian, worldwide
    }

    static let modelPreferenceKey = "photo_model_preference"

    // Rough bounding box over Iberia and the Balearics. Deliberately coarse: the
    // avifauna does not change at the border, so a few kilometres of southern
    // France or northern Morocco picking the Iberian model is the right answer
    // anyway. Without a fix we stay worldwide, which is the safe default.
    private static func isIberian(_ coordinate: CLLocationCoordinate2D?) -> Bool {
        guard let coordinate else { return false }
        return (35.9...44.4).contains(coordinate.latitude)
            && (-9.8...4.4).contains(coordinate.longitude)
    }

    private func model(for coordinate: CLLocationCoordinate2D?) -> (VNCoreMLModel, Bool)? {
        let preference = ModelChoice(
            rawValue: UserDefaults.standard.string(forKey: Self.modelPreferenceKey) ?? "") ?? .automatic

        switch preference {
        case .iberian:
            if let iberianModel { return (iberianModel, true) }
        case .worldwide:
            break
        case .automatic:
            if let iberianModel, Self.isIberian(coordinate) { return (iberianModel, true) }
        }
        // Fall back to the worldwide model — also the path taken when the Iberian
        // model was never bundled. If only the Iberian one is present, use it
        // rather than refusing to identify anything.
        if let visionModel { return (visionModel, false) }
        return iberianModel.map { ($0, true) }
    }

    // MARK: - Identification

    // `region` is the area the user framed, normalised (0…1) against the upright
    // image with a top-left origin. When nil we fall back to automatic saliency
    // framing, which is also what the "Whole photo" button asks for.
    func identify(_ image: UIImage, region: CGRect? = nil) async {
        let coordinate = locationProvider?()
        guard let (activeModel, iberian) = model(for: coordinate) else {
            phase = .failed(NSLocalizedString("Photo model not available", comment: ""))
            return
        }
        guard let cgImage = image.cgImage ?? CIContext().createCGImage(
                CIImage(image: image) ?? CIImage(), from: CGRect(origin: .zero, size: image.size)) else {
            phase = .failed(NSLocalizedString("Could not read the photo", comment: ""))
            return
        }

        phase = .working
        candidates = []
        fusionHint = nil
        usedIberianModel = iberian
        usedManualRegion = region != nil

        let orientation = Self.cgOrientation(image.imageOrientation)

        // Vision work is not cheap — keep it off the main actor.
        let outcome = await Task.detached(priority: .userInitiated) { [backgroundLabel] in
            let cropped = region.map { Self.crop(cgImage, to: $0) }
                ?? Self.cropToSubject(cgImage, orientation: orientation)
            let request = VNCoreMLRequest(model: activeModel)
            request.imageCropAndScaleOption = .centerCrop

            let handler = VNImageRequestHandler(cgImage: cropped, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return Outcome(error: error.localizedDescription)
            }
            guard let observations = request.results as? [VNClassificationObservation] else {
                return Outcome(error: nil, crop: cropped)
            }
            // Keep a deeper slice than we will ever show: the location filter and
            // the audio prior re-rank this pool, and a species the user just heard
            // is worth rescuing from 8th place. Trimmed back to `maxCandidates`
            // once the re-ranking is done.
            let ranked = observations
                .sorted { $0.confidence > $1.confidence }
                .prefix(Self.rerankPool)
                .map { (identifier: $0.identifier, confidence: Double($0.confidence)) }
            let isBackground = ranked.first?.identifier == backgroundLabel
            // Underscores are stripped only after `__background__` has been
            // filtered out — normalising first would mangle it into "  background  "
            // and the "no bird here" answer would never fire. The Iberian model's
            // classes are directory names ("Turdus_merula"); AIY uses spaces.
            return Outcome(error: nil,
                           crop: cropped,
                           ranked: ranked
                               .filter { $0.identifier != backgroundLabel }
                               .map { (identifier: $0.identifier.replacingOccurrences(of: "_", with: " "),
                                       confidence: $0.confidence) },
                           background: isBackground)
        }.value

        analysedImage = outcome.crop.map { UIImage(cgImage: $0) }

        if let error = outcome.error {
            phase = .failed(error)
            return
        }
        guard !outcome.background, !outcome.ranked.isEmpty else {
            phase = .noBird
            return
        }

        candidates = build(from: outcome.ranked, coordinate: coordinate)
        guard let best = candidates.first, best.confidence >= Self.minimumTop else {
            candidates = []
            phase = .noBird
            return
        }
        phase = .done
        await enrich()
    }

    // Same enrichment the audio path does in ContentView: a Wikipedia photo for
    // the top candidates, plus a localized name if the bundled labels had none.
    private func enrich() async {
        for i in candidates.indices where i < 2 {
            let info = await WikipediaImageService.shared.info(for: candidates[i].scientificName)
            guard i < candidates.count else { return }   // reset() may have run meanwhile
            candidates[i].imageURL = info.imageURL
            if candidates[i].localizedName?.isEmpty ?? true {
                candidates[i].localizedName = info.localizedName
            }
        }
    }

    func reset() {
        phase = .idle
        candidates = []
        analysedImage = nil
        fusionHint = nil
        usedManualRegion = false
    }

    private struct Outcome: Sendable {
        var error: String?
        var crop: CGImage?
        var ranked: [(identifier: String, confidence: Double)] = []
        var background = false
    }

    // MARK: - Scoring

    // Turn raw model classes into BirdDetections, applying the same soft
    // location/season filter the audio path uses (whoBIRD style), then re-rank.
    private func build(from ranked: [(identifier: String, confidence: Double)],
                       coordinate: CLLocationCoordinate2D?) -> [BirdDetection] {
        let influence = Float(UserDefaults.standard.double(forKey: "location_filter_influence"))
        var metaScores: [Float]?
        if influence > 0, let filter = locationFilter, let coordinate {
            filter.update(lat: coordinate.latitude, lon: coordinate.longitude, date: Date())
            if !filter.metaScores.isEmpty { metaScores = filter.metaScores }
        }

        var results: [BirdDetection] = ranked.map { entry in
            let scientific = entry.identifier
            let row = birdNETIndex[scientific.lowercased()]
                   ?? birdNETIndex[Self.binomial(scientific).lowercased()]   // trinomios → especie padre

            var confidence = entry.confidence
            if let metaScores, let row, row < metaScores.count {
                confidence *= Double((1 - influence) + influence * metaScores[row])
            }

            var detection = BirdDetection(
                commonName: row.map { commonNames[$0] } ?? scientific,
                scientificName: row.map { _ in Self.binomial(scientific) } ?? scientific,
                confidence: confidence,
                coordinate: coordinate,
                source: .photo)
            if let row, row < localizedNames.count {
                detection.localizedName = localizedNames[row]
            }
            return detection
        }

        let boosted = applyAudioPrior(to: &results)
        results.sort { $0.confidence > $1.confidence }

        // Only flag the fusion when it actually decided the answer.
        if let top = results.first, let heardAt = boosted[top.scientificName.lowercased()] {
            fusionHint = FusionHint(scientificName: top.scientificName, heardAt: heardAt)
        }

        // Drop the tail: with 965 classes the runners-up are usually well under
        // 1 %, and listing them as "other possibilities · 0 %" reads as a bug.
        // The best guess always survives here; `identify` decides if it is too
        // weak to show at all.
        let alternatives = results.dropFirst().filter { $0.confidence >= Self.minimumAlternative }
        return Array(([results.first].compactMap { $0 } + alternatives).prefix(maxCandidates))
    }

    // Raise the prior of candidates the microphone heard recently, weighted by how
    // long ago (full strength just now, fading to nothing at `fusionWindow`).
    //
    // The scores are renormalised afterwards so the pool keeps the same total
    // belief it had: the prior *redistributes* confidence between candidates
    // rather than manufacturing it, which keeps the percentages on screen honest.
    // Returns the species that were boosted, so the caller can explain the result.
    @discardableResult
    private func applyAudioPrior(to results: inout [BirdDetection]) -> [String: Date] {
        guard UserDefaults.standard.bool(forKey: Self.fusionDefaultsKey),
              let heard = recentlyHeardProvider?(), !heard.isEmpty,
              results.count > 1                      // nothing to out-rank
        else { return [:] }

        let now = Date()
        let before = results.reduce(0) { $0 + $1.confidence }
        var boosted: [String: Date] = [:]

        for i in results.indices {
            let key = results[i].scientificName.lowercased()
            guard let heardAt = heard[key] else { continue }
            let age = now.timeIntervalSince(heardAt)
            guard age >= 0, age < Self.fusionWindow else { continue }
            results[i].confidence *= 1 + Self.fusionBoost * (1 - age / Self.fusionWindow)
            boosted[key] = heardAt
        }

        let after = results.reduce(0) { $0 + $1.confidence }
        guard !boosted.isEmpty, after > 0 else { return [:] }
        for i in results.indices { results[i].confidence *= before / after }
        return boosted
    }

    static let fusionDefaultsKey = "audio_photo_fusion"
    // How long a song keeps vouching for a species, matched to the history
    // de-duplication window so one sighting is one event across both tabs.
    static let fusionWindow: TimeInterval = 600
    // Strength at age zero: a species heard seconds ago doubles its score.
    private static let fusionBoost = 1.0
    private static let rerankPool = 10

    // Confidence floors: below `minimumTop` we claim nothing rather than show a
    // near-random species; alternatives need more than noise to be worth listing.
    private static let minimumTop = 0.05
    private static let minimumAlternative = 0.05

    // "Anas platyrhynchos diazi" → "Anas platyrhynchos" (BirdNET has no subspecies).
    private static func binomial(_ scientific: String) -> String {
        scientific.split(separator: " ").prefix(2).joined(separator: " ")
    }

    // MARK: - Framing

    // The classifier looks at the whole frame, so a bird that fills 5 % of a
    // landscape shot gets drowned out. Vision's objectness saliency finds the
    // subject; we crop to a padded square around it before classifying.
    // Falls back to the original image when nothing salient is found.
    nonisolated private static func cropToSubject(_ image: CGImage,
                                                  orientation: CGImagePropertyOrientation) -> CGImage {
        let request = VNGenerateObjectnessBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first as? VNSaliencyImageObservation,
              let object = observation.salientObjects?.max(by: { $0.confidence < $1.confidence })
        else { return image }

        let width = CGFloat(image.width), height = CGFloat(image.height)
        let box = object.boundingBox                     // normalizado, origen abajo-izquierda
        var rect = CGRect(x: box.minX * width,
                          y: (1 - box.maxY) * height,    // Vision → coordenadas CGImage
                          width: box.width * width,
                          height: box.height * height)

        // Padded square: keeps some habitat context and avoids the aspect-ratio
        // squash that `.centerCrop` would otherwise apply to a thin bounding box.
        let side = max(rect.width, rect.height) * 1.3
        rect = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))

        // Ignore useless crops (tiny specks or "the whole picture is salient").
        guard rect.width > 64, rect.height > 64,
              rect.width * rect.height < width * height * 0.95,
              let cropped = image.cropping(to: rect)
        else { return image }
        return cropped
    }

    // The user's own framing. Grown to a square around its centre for the same
    // reason `cropToSubject` does it: `.centerCrop` would otherwise shave the
    // long side of a rectangle off, cutting the tail or the beak the user was
    // careful to include.
    nonisolated private static func crop(_ image: CGImage, to region: CGRect) -> CGImage {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let rect = CGRect(x: region.minX * width, y: region.minY * height,
                          width: region.width * width, height: region.height * height)
        let side = max(rect.width, rect.height)
        let square = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))

        guard square.width > 16, square.height > 16,
              let cropped = image.cropping(to: square.integral) else { return image }
        return cropped
    }

    nonisolated private static func cgOrientation(_ o: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch o {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}
