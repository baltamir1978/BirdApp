import Foundation
import Observation

// Locates the BirdNET model and labels file bundled with the app.
//
// Supported model formats (in order of preference):
//   1. BirdNET_Classifier.mlmodelc  — compiled CoreML (fastest; generate with extract_birdnet.py)
//   2. BirdNET_Classifier.mlpackage — CoreML package (auto-compiled on first launch)
//
// Labels file: BirdNET_GLOBAL_6K_V2.4_Labels.txt  (or BirdNET_Labels.txt / BirdNET.txt)
//
// Future model updates ship with new app versions — no runtime download needed.

@Observable
@MainActor
final class ModelManager {
    private(set) var isModelReady = false
    private(set) var statusMessage = NSLocalizedString("Initializing…", comment: "")

    private(set) var modelPath: String?
    private(set) var photoModelPath: String?        // AIY Birds V1, para identificar por foto
    // Iberian photo classifier (Create ML, ~390 species). Optional: when it is
    // not bundled the app simply keeps using the worldwide model everywhere.
    private(set) var iberianPhotoModelPath: String?
    private(set) var labelsPath: String?
    private(set) var localizedLabelsPath: String?   // Common names in the device language, if bundled
    private(set) var weightsPath: String?

    init() {
        locate()
    }

    // MARK: - Private

    private func locate() {
        // CoreML compiled bundle (.mlmodelc is a directory — use Bundle.url)
        if let url = Bundle.main.url(forResource: "BirdNET_Classifier",
                                     withExtension: "mlmodelc") {
            modelPath = url.path
        } else if let url = Bundle.main.url(forResource: "BirdNET_Classifier",
                                            withExtension: "mlpackage") {
            modelPath = url.path
        }

        if let url = Bundle.main.url(forResource: "BirdPhoto_Classifier", withExtension: "mlmodelc")
                  ?? Bundle.main.url(forResource: "BirdPhoto_Classifier", withExtension: "mlpackage") {
            photoModelPath = url.path
        }

        if let url = Bundle.main.url(forResource: "BirdPhoto_Iberian", withExtension: "mlmodelc")
                  ?? Bundle.main.url(forResource: "BirdPhoto_Iberian", withExtension: "mlpackage") {
            iberianPhotoModelPath = url.path
        }

        labelsPath = Bundle.main.path(forResource: "BirdNET_GLOBAL_6K_V2.4_Labels", ofType: "txt")
                  ?? Bundle.main.path(forResource: "BirdNET_Labels",                 ofType: "txt")
                  ?? Bundle.main.path(forResource: "BirdNET",                        ofType: "txt")

        localizedLabelsPath = Self.localizedLabels()

        weightsPath = Bundle.main.path(forResource: "meta_weights", ofType: "bin")

        if modelPath != nil {
            isModelReady = true
            let count = speciesCount()
            statusMessage = String(format: NSLocalizedString("BirdNET v2.4 · %@ species", comment: ""),
                                   count)
        } else {
            statusMessage = NSLocalizedString("Add BirdNET_Classifier.mlmodelc to the project",
                                              comment: "")
        }
    }

    // Picks the bundled common-name labels matching the device language, if any.
    // Files are named BirdNET_GLOBAL_6K_V2.4_Labels_<suffix>.txt (37 locales from
    // whoBIRD, same species order as the model). Returns nil for English/unknown,
    // where the base labels' English common names are used instead.
    private static func localizedLabels() -> String? {
        let pref = Locale.preferredLanguages.first ?? "en"
        let parts = pref.replacingOccurrences(of: "-", with: "_").split(separator: "_")
        let lang = parts.first.map { String($0).lowercased() } ?? "en"
        let region = parts.count > 1 ? String(parts[1]).lowercased() : nil

        guard lang != "en" || region == "gb" else { return nil }  // base labels are English

        // Try, in order: regional variant, English-UK special case, bare language.
        var candidates: [String] = []
        if let region { candidates.append("\(lang)_\(region.uppercased())") }   // e.g. pt_BR, pt_PT
        if lang == "en", region == "gb" { candidates.append("en_uk") }
        candidates.append(lang)                                                 // e.g. es, de, fr

        for suffix in candidates {
            if let p = Bundle.main.path(forResource: "BirdNET_GLOBAL_6K_V2.4_Labels_\(suffix)", ofType: "txt") {
                return p
            }
        }
        return nil
    }

    private func speciesCount() -> String {
        guard let path = labelsPath,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return "6,000+" }
        return "\(text.split(separator: "\n").filter { !$0.isEmpty }.count)"
    }
}
