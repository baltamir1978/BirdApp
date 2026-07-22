import Foundation
import CoreLocation

// How a bird was identified. Optional on `BirdDetection` so history saved before
// photo identification existed still decodes — a missing value means audio.
enum DetectionSource: String, Codable {
    case audio
    case photo
}

struct BirdDetection: Identifiable, Codable {
    let id: UUID
    let commonName: String
    let scientificName: String
    var confidence: Double
    let date: Date
    let latitude: Double?
    let longitude: Double?
    var imageURL: String?
    var localizedName: String?  // Common name in device language, fetched from Wikipedia
    var source: DetectionSource?

    var displayName: String {
        if let name = localizedName,
           !name.isEmpty,
           name.lowercased() != scientificName.lowercased() {
            return name
        }
        return commonName
    }

    init(
        commonName: String,
        scientificName: String,
        confidence: Double,
        date: Date = .now,
        coordinate: CLLocationCoordinate2D? = nil,
        imageURL: String? = nil,
        source: DetectionSource = .audio
    ) {
        self.id = UUID()
        self.commonName = commonName
        self.scientificName = scientificName
        self.confidence = confidence
        self.date = date
        self.latitude = coordinate?.latitude
        self.longitude = coordinate?.longitude
        self.imageURL = imageURL
        self.source = source
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let lat = latitude, let lon = longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}
