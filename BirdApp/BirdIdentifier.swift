import Foundation

// Placeholder identifier — swap in BirdNET Core ML inference here.
// Steps to integrate the real model:
//   1. Convert BirdNET TFLite → Core ML with coremltools (see BirdNET-Analyzer repo)
//   2. Add the .mlpackage to the Xcode project
//   3. Compute a mel spectrogram from `samples` at 48 kHz
//   4. Run model prediction and map the top result to a BirdDetection
class BirdIdentifier {

    private let knownBirds: [(common: String, scientific: String)] = [
        ("American Robin", "Turdus migratorius"),
        ("Northern Cardinal", "Cardinalis cardinalis"),
        ("Black-capped Chickadee", "Poecile atricapillus"),
        ("House Sparrow", "Passer domesticus"),
        ("Common Blackbird", "Turdus merula"),
        ("Eurasian Blue Tit", "Cyanistes caeruleus"),
        ("Song Sparrow", "Melospiza melodia"),
        ("White-throated Sparrow", "Zonotrichia albicollis"),
        ("European Robin", "Erithacus rubecula"),
        ("Great Tit", "Parus major"),
    ]

    func identify(samples: [Float], completion: @escaping (BirdDetection?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let threshold = UserDefaults.standard.double(forKey: "confidence_threshold")
            let effectiveThreshold = threshold == 0 ? 0.7 : threshold

            // Simulate model latency
            Thread.sleep(forTimeInterval: 0.1)

            let confidence = Double.random(in: 0.5...0.99)
            guard confidence >= effectiveThreshold, let bird = knownBirds.randomElement() else {
                completion(nil)
                return
            }
            completion(BirdDetection(commonName: bird.common, scientificName: bird.scientific, confidence: confidence))
        }
    }
}
