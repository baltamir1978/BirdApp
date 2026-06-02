import SwiftUI
import MapKit

struct HistoryView: View {
    var store: DetectionStore

    var body: some View {
        NavigationStack {
            Group {
                if store.detections.isEmpty {
                    ContentUnavailableView(
                        "No Detections Yet",
                        systemImage: "bird",
                        description: Text("Identified birds will appear here")
                    )
                } else {
                    List(store.detections) { detection in
                        NavigationLink(destination: DetectionDetailView(detection: detection)) {
                            DetectionRow(detection: detection)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("History")
            .toolbar {
                if !store.detections.isEmpty {
                    Button("Clear", role: .destructive) { store.clear() }
                }
            }
        }
    }
}

// MARK: - DetectionRow

struct DetectionRow: View {
    let detection: BirdDetection

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail
            Group {
                if let urlString = detection.imageURL, let url = URL(string: urlString) {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            Color.secondary.opacity(0.15)
                                .overlay(Image(systemName: "bird.fill").foregroundStyle(Color.accentColor))
                        }
                    }
                } else {
                    Color.secondary.opacity(0.15)
                        .overlay(Image(systemName: "bird.fill").foregroundStyle(Color.accentColor))
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(detection.displayName).font(.headline)
                Text(detection.scientificName)
                    .font(.caption).italic().foregroundStyle(.secondary)
                if detection.coordinate != nil {
                    Label("GPS tagged", systemImage: "location.fill")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int(detection.confidence * 100))%")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(confidenceColor(for: detection.confidence))
                Text(detection.date, style: .relative)
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func confidenceColor(for confidence: Double) -> Color {
        confidence >= 0.85 ? .green : confidence >= 0.7 ? .orange : .red
    }
}

// MARK: - DetectionDetailView

struct DetectionDetailView: View {
    let detection: BirdDetection

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Bird image
                Group {
                    if let urlString = detection.imageURL, let url = URL(string: urlString) {
                        AsyncImage(url: url) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFill()
                            } else { placeholder }
                        }
                    } else { placeholder }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 280)
                .clipped()

                VStack(spacing: 6) {
                    Text(detection.displayName).font(.title.bold())
                    Text(detection.scientificName).font(.title3).italic().foregroundStyle(.secondary)
                }

                // Metadata grid
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    MetaCell(icon: "checkmark.seal.fill",
                             label: "Confidence",
                             value: "\(Int(detection.confidence * 100))%",
                             color: detection.confidence >= 0.85 ? .green : .orange)
                    MetaCell(icon: "clock.fill",
                             label: "Time",
                             value: detection.date.formatted(date: .omitted, time: .shortened))
                    MetaCell(icon: "calendar",
                             label: "Date",
                             value: detection.date.formatted(date: .abbreviated, time: .omitted))
                    if let coord = detection.coordinate {
                        MetaCell(icon: "location.fill",
                                 label: "Location",
                                 value: String(format: "%.4f, %.4f", coord.latitude, coord.longitude),
                                 color: .blue)
                    }
                }
                .padding(.horizontal)

                // Map if location available
                if let coord = detection.coordinate {
                    Map(position: .constant(.region(MKCoordinateRegion(
                        center: coord,
                        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                    )))) {
                        Marker(detection.displayName, coordinate: coord)
                    }
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal)
                }
            }
        }
        .navigationTitle(detection.commonName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var placeholder: some View {
        Color.secondary.opacity(0.1)
            .overlay(Image(systemName: "bird.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor.opacity(0.5)))
    }
}

// MARK: - MetaCell

struct MetaCell: View {
    let icon: String
    let label: LocalizedStringKey
    let value: String
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
