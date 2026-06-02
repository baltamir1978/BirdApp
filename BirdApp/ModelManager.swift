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
    private(set) var labelsPath: String?
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

        labelsPath = Bundle.main.path(forResource: "BirdNET_GLOBAL_6K_V2.4_Labels", ofType: "txt")
                  ?? Bundle.main.path(forResource: "BirdNET_Labels",                 ofType: "txt")
                  ?? Bundle.main.path(forResource: "BirdNET",                        ofType: "txt")

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

    private func speciesCount() -> String {
        guard let path = labelsPath,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return "6,000+" }
        return "\(text.split(separator: "\n").filter { !$0.isEmpty }.count)"
    }
}
