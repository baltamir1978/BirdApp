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

    private(set) var phase: Phase = .idle
    private(set) var candidates: [BirdDetection] = []
    // The square crop actually fed to the model — shown in the UI so the user can
    // see what was analysed (and reframe if it grabbed the wrong thing).
    private(set) var analysedImage: UIImage?

    var locationProvider: (() -> CLLocationCoordinate2D?)?

    private var visionModel: VNCoreMLModel?
    private var locationFilter: LocationFilter?

    // Parallel to the model's class labels; nil where a species has no BirdNET
    // counterpart (mostly subspecies and a few exotics).
    private var birdNETIndex: [String: Int] = [:]      // scientific (lowercased) → BirdNET row
    private var commonNames: [String] = []             // English, by BirdNET row
    private var localizedNames: [String] = []          // device language, by BirdNET row

    private let backgroundLabel = "__background__"
    private let maxCandidates = 3

    var isReady: Bool { visionModel != nil }

    // MARK: - Setup

    func configure(modelPath: String?,
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

        guard let modelPath else { return }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let ml = try MLModel(contentsOf: URL(fileURLWithPath: modelPath), configuration: config)
            visionModel = try VNCoreMLModel(for: ml)
        } catch {
            print("[PhotoIdentifier] CoreML load failed: \(error)")
        }
    }

    // MARK: - Identification

    func identify(_ image: UIImage) async {
        guard let visionModel else {
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

        let orientation = Self.cgOrientation(image.imageOrientation)
        let coordinate = locationProvider?()

        // Vision work is not cheap — keep it off the main actor.
        let outcome = await Task.detached(priority: .userInitiated) { [maxCandidates, backgroundLabel] in
            let cropped = Self.cropToSubject(cgImage, orientation: orientation)
            let request = VNCoreMLRequest(model: visionModel)
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
            let ranked = observations
                .sorted { $0.confidence > $1.confidence }
                .prefix(maxCandidates + 1)
                .map { (identifier: $0.identifier, confidence: Double($0.confidence)) }
            let isBackground = ranked.first?.identifier == backgroundLabel
            return Outcome(error: nil,
                           crop: cropped,
                           ranked: ranked.filter { $0.identifier != backgroundLabel },
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

        results.sort { $0.confidence > $1.confidence }

        // Drop the tail: with 965 classes the runners-up are usually well under
        // 1 %, and listing them as "other possibilities · 0 %" reads as a bug.
        // The best guess always survives here; `identify` decides if it is too
        // weak to show at all.
        let alternatives = results.dropFirst().filter { $0.confidence >= Self.minimumAlternative }
        return Array(([results.first].compactMap { $0 } + alternatives).prefix(maxCandidates))
    }

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
