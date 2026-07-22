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
    @State private var selectedBird: BirdDetection?
    @State private var loadError: String?

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
                    analyse(image)
                }
                .ignoresSafeArea()
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

            // What the model actually looked at, once we know it.
            if let crop = identifier.analysedImage {
                HStack(spacing: 8) {
                    Image(uiImage: crop)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text("Analysed area")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                if let top = identifier.candidates.first {
                    SongPlayButton(scientificName: top.scientificName)
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

    private func load(_ item: PhotosPickerItem) async {
        loadError = nil
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                loadError = NSLocalizedString("Could not read the photo", comment: "")
                return
            }
            analyse(image)
        } catch {
            loadError = error.localizedDescription
        }
        pickerItem = nil
    }

    private func analyse(_ image: UIImage) {
        loadError = nil
        identifier.reset()
        sourceImage = image
        Task {
            await identifier.identify(image)
            // `identify` already enriched the candidates with a Wikipedia photo;
            // only the best one goes to history, as with an audio detection.
            if identifier.phase == .done, let top = identifier.candidates.first {
                store.add(top)
            }
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
