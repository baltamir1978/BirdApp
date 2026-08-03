import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit
import Vision

// Framing step shown between picking a photo and classifying it.
//
// The classifier only ever sees a square crop, and until now that crop was
// chosen for us by saliency — which happily locks onto a flower, a fence post
// or the dog. Here the user gets the last word:
//
//   · tap a subject   — Vision segments the foreground objects (the same
//                       machinery behind "lift subject from background"), so
//                       one tap on the bird snaps the crop onto it;
//   · drag a box      — free-hand rectangle for everything else, movable and
//                       resizable by its corners;
//   · "Auto"          — keep the old behaviour and let saliency decide.
//
// The rectangle handed back is normalised (0…1) against the *upright* image,
// so `PhotoView` must pass an image already redrawn in `.up` orientation.
struct PhotoFramingView: View {
    let image: UIImage
    var onCancel: () -> Void
    var onConfirm: (CGRect?) -> Void          // nil → automatic framing

    @State private var subjects: [DetectedSubject] = []
    @State private var selection: CGRect?     // normalised, top-left origin
    @State private var highlight: UIImage?    // mask of the tapped subject
    @State private var isDetecting = true
    @State private var drag: DragMode?
    @State private var selectionBeforeDrag: CGRect?

    private enum DragMode {
        case draw(CGPoint)                    // anchor corner, in view space
        case move(CGRect, CGPoint)            // rect at gesture start + anchor
        case resize(Corner, CGRect)
    }

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let frame = Self.imageFrame(for: image.size, in: geo.size)
                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)

                    // Sticker-style glow over the subject the user just tapped.
                    if let highlight {
                        Color.accentColor.opacity(0.35)
                            .frame(width: frame.width, height: frame.height)
                            .mask {
                                Image(uiImage: highlight)
                                    .resizable()
                                    .frame(width: frame.width, height: frame.height)
                            }
                            .position(x: frame.midX, y: frame.midY)
                            .allowsHitTesting(false)
                    }

                    dimming(in: frame)
                    subjectHints(in: frame)
                    if let selection {
                        selectionOverlay(Self.viewRect(selection, in: frame))
                    }
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(in: frame))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.black)
            .ignoresSafeArea(edges: .bottom)
            .safeAreaInset(edge: .top) { hint }
            .safeAreaInset(edge: .bottom) { actions }
            .navigationTitle("Frame the bird")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Identify") { onConfirm(selection) }
                        .fontWeight(.semibold)
                }
            }
        }
        .task {
            subjects = await SubjectDetector.subjects(in: image)
            isDetecting = false
            // A single obvious subject is almost always the bird — pre-select it
            // so the common case needs no interaction at all.
            if selection == nil, subjects.count == 1, let only = subjects.first {
                select(only)
            }
        }
    }

    // MARK: - Chrome

    private var hint: some View {
        Group {
            if isDetecting {
                Label("Looking for the subject…", systemImage: "sparkles")
            } else if selection == nil {
                Label(subjects.isEmpty
                      ? "Drag a box around the bird"
                      : "Tap the bird, or drag a box around it",
                      systemImage: subjects.isEmpty ? "rectangle.dashed" : "hand.tap")
            } else {
                Label("Drag to move, corners to resize", systemImage: "arrow.up.left.and.arrow.down.right")
            }
        }
        .font(.footnote)
        .foregroundStyle(.white.opacity(0.85))
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.5))
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                selection = nil
                highlight = nil
                onConfirm(nil)
            } label: {
                Label("Whole photo", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                onConfirm(selection)
            } label: {
                Label("Identify", systemImage: "bird")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
        .tint(.accentColor)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.black.opacity(0.5))
    }

    // MARK: - Overlays

    // Everything outside the selection goes dark, so the crop reads at a glance.
    private func dimming(in frame: CGRect) -> some View {
        Path { path in
            path.addRect(frame)
            if let selection { path.addRect(Self.viewRect(selection, in: frame)) }
        }
        .fill(Color.black.opacity(selection == nil ? 0.15 : 0.55), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    // Faint outlines for the subjects Vision found, as an invitation to tap them.
    @ViewBuilder
    private func subjectHints(in frame: CGRect) -> some View {
        if selection == nil {
            ForEach(subjects) { subject in
                let rect = Self.viewRect(subject.box, in: frame)
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor.opacity(0.9),
                                  style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
            }
        }
    }

    private func selectionOverlay(_ rect: CGRect) -> some View {
        ZStack {
            Rectangle()
                .strokeBorder(Color.white, lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            ForEach(Array(Corner.allCases.enumerated()), id: \.offset) { _, corner in
                let point = Self.point(of: corner, in: rect)
                Circle()
                    .fill(.white)
                    .frame(width: 16, height: 16)
                    .shadow(radius: 2)
                    .position(x: point.x, y: point.y)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Gestures

    private func dragGesture(in frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if drag == nil {
                    selectionBeforeDrag = selection
                    drag = beginDrag(at: value.startLocation, in: frame)
                }
                update(with: value.location, in: frame)
            }
            .onEnded { value in
                let moved = hypot(value.translation.width, value.translation.height)
                if moved < 10 {
                    // Treat it as a tap: undo the sliver we started drawing and
                    // snap to whichever subject sits under the finger.
                    selection = selectionBeforeDrag
                    tap(at: value.location, in: frame)
                } else if let selection, selection.width < 0.03 || selection.height < 0.03 {
                    self.selection = selectionBeforeDrag   // accidental scrub
                }
                drag = nil
                selectionBeforeDrag = nil
            }
    }

    private func beginDrag(at point: CGPoint, in frame: CGRect) -> DragMode {
        if let selection {
            let rect = Self.viewRect(selection, in: frame)
            for corner in Corner.allCases
            where hypot(Self.point(of: corner, in: rect).x - point.x,
                        Self.point(of: corner, in: rect).y - point.y) < 36 {
                return .resize(corner, selection)
            }
            if rect.insetBy(dx: -8, dy: -8).contains(point) {
                return .move(selection, point)
            }
        }
        return .draw(point)
    }

    private func update(with point: CGPoint, in frame: CGRect) {
        switch drag {
        case .draw(let anchor):
            let a = Self.normalise(anchor, in: frame)
            let b = Self.normalise(point, in: frame)
            selection = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                               width: abs(a.x - b.x), height: abs(a.y - b.y))
            highlight = nil

        case .move(let original, let anchor):
            let dx = (point.x - anchor.x) / frame.width
            let dy = (point.y - anchor.y) / frame.height
            selection = CGRect(x: min(max(0, original.minX + dx), 1 - original.width),
                               y: min(max(0, original.minY + dy), 1 - original.height),
                               width: original.width, height: original.height)

        case .resize(let corner, let original):
            let p = Self.normalise(point, in: frame)
            var minX = original.minX, maxX = original.maxX
            var minY = original.minY, maxY = original.maxY
            switch corner {
            case .topLeft:     minX = p.x; minY = p.y
            case .topRight:    maxX = p.x; minY = p.y
            case .bottomLeft:  minX = p.x; maxY = p.y
            case .bottomRight: maxX = p.x; maxY = p.y
            }
            selection = CGRect(x: min(minX, maxX), y: min(minY, maxY),
                               width: abs(maxX - minX), height: abs(maxY - minY))

        case nil:
            break
        }
    }

    private func tap(at point: CGPoint, in frame: CGRect) {
        let p = Self.normalise(point, in: frame)
        // Smallest subject containing the touch — with a bird perched on a
        // branch, the tighter box is the one the user meant.
        guard let hit = subjects
            .filter({ $0.box.contains(p) })
            .min(by: { $0.box.width * $0.box.height < $1.box.width * $1.box.height })
        else { return }
        select(hit)
    }

    private func select(_ subject: DetectedSubject) {
        withAnimation(.easeOut(duration: 0.2)) {
            selection = Self.padded(subject.box)
        }
        highlight = subject.mask
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: - Geometry

    private static func imageFrame(for imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (container.width - size.width) / 2,
                      y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private static func normalise(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        return CGPoint(x: min(max(0, (point.x - frame.minX) / frame.width), 1),
                       y: min(max(0, (point.y - frame.minY) / frame.height), 1))
    }

    private static func viewRect(_ normalised: CGRect, in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + normalised.minX * frame.width,
               y: frame.minY + normalised.minY * frame.height,
               width: normalised.width * frame.width,
               height: normalised.height * frame.height)
    }

    private static func point(of corner: Corner, in rect: CGRect) -> CGPoint {
        switch corner {
        case .topLeft:     CGPoint(x: rect.minX, y: rect.minY)
        case .topRight:    CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft:  CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    // A little breathing room around a segmented subject: the mask hugs the
    // silhouette, and the classifier was trained on photos, not cut-outs.
    private static func padded(_ box: CGRect) -> CGRect {
        let dx = box.width * 0.12, dy = box.height * 0.12
        return box.insetBy(dx: -dx, dy: -dy)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}

// MARK: - Subject detection

struct DetectedSubject: Identifiable {
    let id: Int
    let box: CGRect        // normalised, top-left origin
    let mask: UIImage?     // alpha silhouette covering the whole frame
}

// Wraps Vision's foreground-instance segmentation — the same request behind
// iOS's "lift subject from background" — and reduces each instance to a
// bounding box plus an alpha mask the UI can paint.
// `nonisolated` as a whole: pure image processing that runs off the main actor,
// which the project would otherwise default it to.
nonisolated enum SubjectDetector {

    // Segmentation runs on a downscaled copy: the masks come back at the size of
    // whatever we hand in, and a 12 MP original would cost far more time and
    // memory than the extra precision is worth for a tap target.
    private static let workingSide: CGFloat = 1024
    private static let maxSubjects = 4

    static func subjects(in image: UIImage, limit: Int = maxSubjects) async -> [DetectedSubject] {
        guard let cgImage = image.cgImage else { return [] }
        return await Task.detached(priority: .userInitiated) {
            detect(in: cgImage, limit: limit)
        }.value
    }

    private static func detect(in original: CGImage, limit: Int) -> [DetectedSubject] {
        let context = CIContext(options: [.useSoftwareRenderer: false])
        let source = downscaled(original, context: context) ?? original

        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: source, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first as? VNInstanceMaskObservation
        else { return [] }

        var found: [DetectedSubject] = []
        for instance in observation.allInstances.prefix(limit) {
            guard let buffer = try? observation.generateScaledMaskForImage(
                    forInstances: IndexSet(integer: instance), from: handler),
                  let box = boundingBox(of: buffer)
            else { continue }
            // Specks are noise, and a mask covering the whole frame is the
            // segmenter shrugging — neither makes a useful tap target.
            guard box.width * box.height > 0.004, box.width * box.height < 0.95 else { continue }
            found.append(DetectedSubject(id: instance, box: box, mask: maskImage(buffer, context: context)))
        }
        return found.sorted { $0.box.width * $0.box.height > $1.box.width * $1.box.height }
    }

    private static func downscaled(_ image: CGImage, context: CIContext) -> CGImage? {
        let side = CGFloat(max(image.width, image.height))
        guard side > workingSide else { return nil }
        let scale = workingSide / side
        let scaled = CIImage(cgImage: image).transformed(by: .init(scaleX: scale, y: scale))
        return context.createCGImage(scaled, from: scaled.extent)
    }

    // Tight box around the non-zero pixels of a mask. Sampled on a stride: a
    // couple of pixels of slack at the edges is invisible once padded, and it
    // keeps the scan cheap even on the full-size mask.
    private static func boundingBox(of buffer: CVPixelBuffer) -> CGRect? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let isFloat = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float
        let step = max(1, min(width, height) / 256)

        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in Swift.stride(from: 0, to: height, by: step) {
            let row = base.advanced(by: y * stride)
            for x in Swift.stride(from: 0, to: width, by: step) {
                let on: Bool = isFloat
                    ? row.load(fromByteOffset: x * MemoryLayout<Float>.size, as: Float.self) > 0.5
                    : row.load(fromByteOffset: x, as: UInt8.self) > 127
                guard on else { continue }
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        let w = CGFloat(width), h = CGFloat(height)
        return CGRect(x: CGFloat(minX) / w, y: CGFloat(minY) / h,
                      width: CGFloat(maxX - minX + 1) / w,
                      height: CGFloat(maxY - minY + 1) / h)
    }

    // The mask arrives as luminance; SwiftUI's `.mask` reads alpha, so convert.
    private static func maskImage(_ buffer: CVPixelBuffer, context: CIContext) -> UIImage? {
        let filter = CIFilter.maskToAlpha()
        filter.inputImage = CIImage(cvPixelBuffer: buffer)
        guard let output = filter.outputImage,
              let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
