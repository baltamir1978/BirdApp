import SwiftUI
import MapKit
import CoreLocation

struct HistoryView: View {
    var store: DetectionStore

    @State private var dayPendingDeletion: Date?
    @State private var showClearConfirm = false

    private var uniqueSpeciesCount: Int {
        Set(store.detections.map(\.scientificName)).count
    }

    // Detections grouped by calendar day, newest day first.
    private var groups: [(day: Date, items: [BirdDetection])] {
        let cal = Calendar.current
        return Dictionary(grouping: store.detections) { cal.startOfDay(for: $0.date) }
            .map { (day: $0.key, items: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.day > $1.day }
    }

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
                    List {
                        Section {
                            HStack(spacing: 12) {
                                StatBox(value: "\(store.detections.count)", label: "Detections")
                                StatBox(value: "\(uniqueSpeciesCount)", label: "Species")
                            }
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowBackground(Color.clear)
                        }
                        ForEach(groups, id: \.day) { group in
                            Section {
                                ForEach(group.items) { detection in
                                    NavigationLink(destination: DetectionDetailView(detection: detection)) {
                                        DetectionRow(detection: detection)
                                    }
                                }
                                .onDelete { offsets in
                                    offsets.map { group.items[$0] }.forEach(store.remove)
                                }
                            } header: {
                                HStack {
                                    Text(Self.dayLabel(group.day))
                                    Spacer()
                                    Text("\(group.items.count)")
                                        .foregroundStyle(.secondary)
                                    Button {
                                        dayPendingDeletion = group.day
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                    .tint(.red)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("History")
            .toolbar {
                if !store.detections.isEmpty {
                    ToolbarItem(placement: .topBarLeading) { EditButton() }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Delete All", role: .destructive) { showClearConfirm = true }
                    }
                }
            }
            .confirmationDialog("Delete all detections?",
                                isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("Delete All", role: .destructive) { store.clear() }
                Button("Cancel", role: .cancel) { }
            }
            .confirmationDialog("Delete this day?",
                                isPresented: Binding(get: { dayPendingDeletion != nil },
                                                     set: { if !$0 { dayPendingDeletion = nil } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let day = dayPendingDeletion { store.removeDay(day) }
                    dayPendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { dayPendingDeletion = nil }
            }
        }
    }

    // "Today" / "Yesterday" / full date.
    static func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return NSLocalizedString("Today", comment: "") }
        if cal.isDateInYesterday(day) { return NSLocalizedString("Yesterday", comment: "") }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

// MARK: - StatBox

struct StatBox: View {
    let value: String
    let label: LocalizedStringKey

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title2.bold().monospacedDigit())
                .foregroundStyle(Color.accentColor)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 14))
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
                    .foregroundStyle(birdConfidenceColor(detection.confidence))
                Text(detection.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - DetectionDetailView

struct DetectionDetailView: View {
    let detection: BirdDetection
    @State private var placeName: String?

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
                                 value: placeName ?? String(format: "%.4f, %.4f", coord.latitude, coord.longitude),
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
        .task {
            guard let coord = detection.coordinate else { return }
            let location = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            if #available(iOS 26.0, *) {
                guard let request = MKReverseGeocodingRequest(location: location) else { return }
                let items = try? await withCheckedThrowingContinuation { (cont: CheckedContinuation<[MKMapItem], Error>) in
                    request.getMapItems { items, error in
                        if let error { cont.resume(throwing: error) }
                        else { cont.resume(returning: items ?? []) }
                    }
                }
                if let reps = items?.first?.addressRepresentations {
                    placeName = reps.cityWithContext ?? reps.cityName
                }
            } else {
                if let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first {
                    placeName = [placemark.locality, placemark.administrativeArea, placemark.country]
                        .compactMap { $0 }.joined(separator: ", ")
                }
            }
        }
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
