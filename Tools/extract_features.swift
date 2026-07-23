// Extract VisionFeaturePrint.Scene feature vectors for every training image.
//
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
//     xcrun swift Tools/extract_features.swift <vfp_scene.mlmodel> <dataset> <out.bin> [maxPerClass]
//
// Why this exists: MLImageClassifier's own training pipeline runs out of pixel
// buffers on a set this size in a headless process (CVPixelBufferPool 0×0). So
// we split its two internal stages — feature extraction and the classifier head
// — and do the extraction ourselves, one image at a time, with the exact same
// VisionFeaturePrint.Scene stage the final pipeline will use. The classifier is
// then trained on these 768-float vectors, which is cheap and never touches an
// image buffer again.
//
// Output format (little-endian): for each image, a UInt32 label index, then 768
// Float32 values. Labels, in index order, go to <out>.labels.txt.

import CoreML
import Foundation
import Vision
import AppKit

setvbuf(stdout, nil, _IONBF, 0)          // live progress when stdout is not a TTY

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
    print("usage: extract_features <vfp_scene.mlmodel> <dataset> <out.bin> [maxPerClass]")
    exit(1)
}
let modelURL = URL(fileURLWithPath: arguments[1])
let datasetURL = URL(fileURLWithPath: arguments[2])
let outURL = URL(fileURLWithPath: arguments[3])
let maxPerClass = arguments.count > 4 ? Int(arguments[4]) ?? .max : .max

let compiled = try MLModel.compileModel(at: modelURL)
let model = try VNCoreMLModel(for: try MLModel(contentsOf: compiled))

let classes = (try FileManager.default.contentsOfDirectory(at: datasetURL, includingPropertiesForKeys: nil))
    .filter { $0.hasDirectoryPath }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

FileManager.default.createFile(atPath: outURL.path, contents: nil)
let handle = try FileHandle(forWritingTo: outURL)
var labels: [String] = []
var written = 0

// One feature print per image. Vision is happy to be driven serially here; the
// whole point is to avoid the concurrent buffer storm that breaks Create ML.
func featurePrint(_ url: URL) -> [Float]? {
    guard let image = NSImage(contentsOf: url) else { return nil }
    var rect = NSRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
    guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
    let request = VNCoreMLRequest(model: model)
    request.imageCropAndScaleOption = .centerCrop
    do {
        try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
    } catch {
        return nil
    }
    guard let obs = request.results?.first as? VNCoreMLFeatureValueObservation,
          let array = obs.featureValue.multiArrayValue else { return nil }
    return (0..<array.count).map { Float(truncating: array[$0]) }
}

for (labelIndex, folder) in classes.enumerated() {
    labels.append(folder.lastPathComponent)
    let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "jpg" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .prefix(maxPerClass)

    var kept = 0
    for file in files {
        guard let vector = featurePrint(file), vector.count == 768 else { continue }
        var buffer = Data()
        var index = UInt32(labelIndex).littleEndian
        withUnsafeBytes(of: &index) { buffer.append(contentsOf: $0) }
        for var value in vector {
            withUnsafeBytes(of: &value) { buffer.append(contentsOf: $0) }
        }
        handle.write(buffer)
        kept += 1
        written += 1
    }
    if labelIndex % 25 == 0 || labelIndex == classes.count - 1 {
        print("[\(labelIndex + 1)/\(classes.count)] \(folder.lastPathComponent): \(kept)  (total \(written))")
    }
}

try handle.close()
try labels.joined(separator: "\n").write(to: outURL.appendingPathExtension("labels.txt"),
                                         atomically: true, encoding: .utf8)
print("wrote \(written) vectors, \(labels.count) classes → \(outURL.path)")
