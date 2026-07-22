import SwiftUI

// Detail sheet shown when tapping a detected bird. Loads a Wikipedia summary
// in the app's language (falling back to English) plus a link to the full
// article in that same language.
struct BirdDetailView: View {
    let detection: BirdDetection

    @Environment(\.dismiss) private var dismiss
    @State private var article: WikipediaArticle?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header

                    if isLoading {
                        ProgressView()
                            .padding(.top, 24)
                    } else if let extract = article?.extract, !extract.isEmpty {
                        Text(extract)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("No description available.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    SongPlayButton(scientificName: detection.scientificName)

                    if let url = articleURL {
                        Link(destination: url) {
                            Label("Read on Wikipedia", systemImage: "safari.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.accentColor.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(20)
            }
            .navigationTitle(detection.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    // MARK: - Header (image + names + confidence)

    private var header: some View {
        VStack(spacing: 10) {
            Group {
                if let urlString = imageURLString, let url = URL(string: urlString) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image): image.resizable().scaledToFill()
                        default: placeholder
                        }
                    }
                } else {
                    placeholder
                }
            }
            .frame(width: 160, height: 160)
            .clipShape(Circle())
            .overlay(Circle().stroke(.secondary.opacity(0.15), lineWidth: 4))

            Text(detection.scientificName)
                .font(.subheadline)
                .italic()
                .foregroundStyle(.secondary)

            Label("\(Int(detection.confidence * 100))%", systemImage: "checkmark.seal.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(birdConfidenceColor(detection.confidence))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(birdConfidenceColor(detection.confidence).opacity(0.12))
                .clipShape(Capsule())
        }
    }

    private var placeholder: some View {
        Image(systemName: "bird.fill")
            .font(.system(size: 60))
            .foregroundStyle(Color.accentColor)
    }

    // Prefer the detection's already-loaded thumbnail, fall back to the
    // article's lead image.
    private var imageURLString: String? { detection.imageURL ?? article?.imageURL }

    private var articleURL: URL? { article?.articleURL }

    private func load() async {
        article = await WikipediaImageService.shared.article(for: detection.scientificName)
        isLoading = false
    }
}
