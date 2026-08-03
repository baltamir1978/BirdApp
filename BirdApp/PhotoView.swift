import PhotosUI
import SwiftUI

// Identify a bird from a photo: pick one from the library or take it with the
// camera, then run it through `PhotoIdentifier`. Results are rendered with the
// same cards as the Listen tab and land in the same history.
struct PhotoView: View {
    var identifier: PhotoIdentifier
    var store: DetectionStore

    @State private var pickerItem: PhotosPickerItem?
    @State private var sourceImage: UIImage?
    @State private var showCamera = false
    @State private var framing: FramingRequest?
    @State private var selectedBird: BirdDetection?
    @State private var loadError: String?

    // A photo waiting for the user to say where the bird is. Wrapped because
    // `sheet(item:)` needs identity and two shots of the same bird are not the
    // same photo.
    private struct FramingRequest: Identifiable {
        let id = UUID()
        let image: UIImage
        // Carried alongside the pixels: where and when the shot was taken, so the
        // location filter scores the bird against the right place and season.
        var metadata = PhotoMetadata()
    }

    // Kept so re-cropping from the result card reuses the original photo's
    // location instead of quietly falling back to the current one.
    @State private var sourceMetadata = PhotoMetadata()

    // The history entry this photo produced. Held on to so a tiebreak correction
    // can be written back to it, and so the song button follows the correction.
    @State private var saved: BirdDetection?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    if let sourceImage {
                        preview(sourceImage)
                    } else {
                        emptyState
                    }

                    resultSection

                    if let loadError {
                        Text(loadError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
                .padding(.vertical, 24)
            }
            // Pinned so picking a photo is always one tap away — the result can
            // be taller than the screen and would otherwise push it out of view.
            .safeAreaInset(edge: .bottom) {
                pickerButtons
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                    .background(.bar)
            }
            .navigationTitle("Photo")
            .sheet(item: $selectedBird) { BirdDetailView(detection: $0) }
            .sheet(isPresented: $showCamera) {
                CameraPicker { image in
                    showCamera = false
                    guard let image else { return }
                    present(image)
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(item: $framing) { request in
                PhotoFramingView(image: request.image) {
                    framing = nil
                } onConfirm: { region in
                    framing = nil
                    analyse(request.image, region: region, metadata: request.metadata)
                }
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task { await load(item) }
            }
        }
    }

    // MARK: - Sections

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
            Text("Identify a bird from a photo")
                .font(.headline)
            Text("Works best when the bird fills a good part of the frame.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 40)
    }

    private func preview(_ image: UIImage) -> some View {
        VStack(spacing: 8) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 200)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal)

            // What the model actually looked at, once we know it — plus which
            // classifier ran, so an odd result is at least explicable. Tapping
            // it goes back to the framing screen: a wrong crop is the single
            // most common reason for a wrong answer, and re-cropping beats
            // taking the photo again.
            if let crop = identifier.analysedImage {
                Button {
                    framing = FramingRequest(image: image, metadata: sourceMetadata)
                } label: {
                    HStack(spacing: 8) {
                        Image(uiImage: crop)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(identifier.usedManualRegion ? "Selected area" : "Analysed area")
                            if identifier.hasIberianModel {
                                Text(identifier.usedIberianModel ? "Iberian model" : "Worldwide model")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .font(.caption)
                        Label("Adjust", systemImage: "crop")
                            .font(.caption)
                            .labelStyle(.titleAndIcon)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        switch identifier.phase {
        case .idle:
            EmptyView()

        case .working:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Analyzing photo…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

        case .done:
            VStack(spacing: 12) {
                DetectionResults(candidates: identifier.candidates, selectedBird: $selectedBird)

                // Two look-alikes within a few points of each other: ask instead
                // of quietly keeping whichever the model preferred.
                if let saved, saved.needsTiebreak {
                    SpeciesTiebreaker(detection: saved) { alternative in
                        self.saved = store.choose(alternative, for: saved)
                    }
                }
                // Say it out loud when a recent song is what tipped the ranking,
                // rather than silently reordering behind the user's back.
                if let hint = identifier.fusionHint {
                    Label(String(format: NSLocalizedString("Its song was heard %@", comment: ""),
                                 Self.relative.localizedString(for: hint.heardAt, relativeTo: .now)),
                          systemImage: "waveform.badge.mic")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                // The song follows the user's choice, not the model's ranking.
                if let scientificName = saved?.scientificName ?? identifier.candidates.first?.scientificName {
                    SongPlayButton(scientificName: scientificName)
                        .padding(.horizontal)
                }
            }

        case .noBird:
            Label("No bird recognised in this photo", systemImage: "questionmark.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    private var pickerButtons: some View {
        HStack(spacing: 12) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    showCamera = true
                } label: {
                    Label("Camera", systemImage: "camera.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                Label("Choose photo", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
        .padding(.horizontal)
    }

    // MARK: - Flow

    private static let relative = RelativeDateTimeFormatter()

    private func load(_ item: PhotosPickerItem) async {
        loadError = nil
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                loadError = NSLocalizedString("Could not read the photo", comment: "")
                return
            }
            // Read the EXIF from the original bytes: `UIImage` drops it, and by
            // the framing screen the photo has been redrawn and it is gone.
            present(image, metadata: PhotoMetadata(data: data))
        } catch {
            loadError = error.localizedDescription
        }
        pickerItem = nil
    }

    // Every photo — camera or library — stops at the framing screen first.
    // The image is redrawn upright there and then, so the rectangle that comes
    // back lines up with the pixels the classifier will see.
    private func present(_ image: UIImage, metadata: PhotoMetadata = PhotoMetadata()) {
        loadError = nil
        sourceMetadata = metadata
        framing = FramingRequest(image: image.uprighted(), metadata: metadata)
    }

    private func analyse(_ image: UIImage, region: CGRect?, metadata: PhotoMetadata) {
        loadError = nil
        identifier.reset()
        sourceImage = image
        saved = nil
        Task {
            await identifier.identify(image, region: region, metadata: metadata)
            // `identify` already enriched the candidates with a Wikipedia photo;
            // only the best one goes to history, as with an audio detection —
            // carrying any runner-up close enough for the user to overrule it.
            if identifier.phase == .done, let top = identifier.candidates.topCarryingCloseCalls() {
                store.add(top)
                saved = top
            }
        }
    }
}

// MARK: - Orientation

extension UIImage {
    // Redraw with the EXIF orientation baked into the pixels. Photos from the
    // camera are usually `.right`, and without this every rectangle the user
    // drags would be rotated by the time it reached `CGImage.cropping`.
    func uprighted() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

// MARK: - CameraPicker

// Minimal UIImagePickerController wrapper — SwiftUI has no native camera capture.
struct CameraPicker: UIViewControllerRepresentable {
    let onPick: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPick: (UIImage?) -> Void
        init(onPick: @escaping (UIImage?) -> Void) { self.onPick = onPick }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onPick(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onPick(nil)
        }
    }
}
