// Train the Iberian photo classifier with Create ML.
//
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
//     xcrun swift Tools/train_iberian.swift [dataset] [output.mlmodel]
//
// Transfer learning on Vision's scenePrint feature extractor: the heavy lifting
// is done by a feature extractor that already ships inside iOS, so what we train
// and bundle is only the classifier head — a few MB instead of tens, and minutes
// of training instead of a night on a GPU.
//
// The dataset is one directory per species (see Tools/inat_download.py); the
// directory name is the label, so `Turdus_merula` arrives at run time as the
// class identifier and PhotoIdentifier maps it back onto BirdNET's taxonomy.

import CreateML
import Foundation

let arguments = CommandLine.arguments
let datasetPath = arguments.count > 1 ? arguments[1] : "Tools/dataset"
let outputPath = arguments.count > 2 ? arguments[2] : "Tools/BirdPhoto_Iberian.mlmodel"

let dataset = URL(fileURLWithPath: datasetPath)
let output = URL(fileURLWithPath: outputPath)

let classes = (try? FileManager.default.contentsOfDirectory(at: dataset,
                                                            includingPropertiesForKeys: [.isDirectoryKey])
    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) ?? []
guard !classes.isEmpty else {
    print("No class directories under \(dataset.path) — run Tools/inat_download.py first")
    exit(1)
}
let photos = classes.reduce(0) { total, folder in
    total + ((try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.count ?? 0)
}
print("Training on \(classes.count) species, \(photos) photos")

// A bird facing left is the same species facing right, so horizontal flip is the
// one augmentation worth having. It is optional because Vision's pixel-buffer
// pool falls over on a set this size when it has to synthesise the flipped
// copies too ("Failed to create CVPixelBufferPool. Width = 0, Height = 0").
let augmentation: MLImageClassifier.ImageAugmentationOptions =
    CommandLine.arguments.contains("--no-flip") ? [] : [.flip]

let parameters = MLImageClassifier.ModelParameters(
    validation: .split(strategy: .automatic),
    maxIterations: 40,
    augmentation: augmentation,
    algorithm: .transferLearning(featureExtractor: .scenePrint(revision: 2),
                                 classifier: .logisticRegressor))

let started = Date()
let classifier: MLImageClassifier
do {
    classifier = try MLImageClassifier(trainingData: .labeledDirectories(at: dataset),
                                       parameters: parameters)
} catch {
    print("Training failed: \(error)")
    exit(1)
}

let minutes = Int(Date().timeIntervalSince(started) / 60)
let training = (1 - classifier.trainingMetrics.classificationError) * 100
let validation = (1 - classifier.validationMetrics.classificationError) * 100
print(String(format: "\nDone in %d min — training %.1f%%, validation %.1f%%",
             minutes, training, validation))

// Per-class recall, worst first: which species the model cannot tell apart is
// far more actionable than a single headline accuracy.
let confusion = classifier.validationMetrics.confusion
print("\nWorst classes by validation recall:")
// Note: cells are MLDataValue, so they need .stringValue/.intValue — a plain
// `as? String` cast compiles with a warning and silently matches nothing.
var recalls: [(String, Double, Int)] = []
for label in Set(confusion.rows.compactMap { $0["True Label"]?.stringValue }) {
    let forLabel = confusion.rows.filter { $0["True Label"]?.stringValue == label }
    let total = forLabel.reduce(0) { $0 + ($1["Count"]?.intValue ?? 0) }
    let right = forLabel.filter { $0["Predicted"]?.stringValue == label }
        .reduce(0) { $0 + ($1["Count"]?.intValue ?? 0) }
    if total > 0 { recalls.append((label, Double(right) / Double(total), total)) }
}
for (label, recall, total) in recalls.sorted(by: { $0.1 < $1.1 }).prefix(20) {
    print(String(format: "  %-32@ %5.1f%%  (n=%d)", label as NSString, recall * 100, total))
}

let metadata = MLModelMetadata(
    author: "BirdApp",
    shortDescription: "Iberian bird photo classifier — \(classes.count) species, "
                    + "trained on Creative Commons iNaturalist photos",
    version: "1.0")

do {
    try classifier.write(to: output, metadata: metadata)
    print("\nWrote \(output.path)")
} catch {
    print("Could not write the model: \(error)")
    exit(1)
}

// The label list the app needs to map classes onto BirdNET rows.
let labels = classes.map { $0.lastPathComponent.replacingOccurrences(of: "_", with: " ") }.sorted()
let labelsURL = output.deletingPathExtension().appendingPathExtension("labels.txt")
try? labels.joined(separator: "\n").write(to: labelsURL, atomically: true, encoding: .utf8)
print("Wrote \(labelsURL.path)")
