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
    var commonName: String
    var scientificName: String
    var confidence: Double
    let date: Date
    let latitude: Double?
    let longitude: Double?
    var imageURL: String?
    var localizedName: String?  // Common name in device language, fetched from Wikipedia
    var source: DetectionSource?
    // Runners-up close enough that the call was not clear cut, kept so the user
    // can settle it themselves. Optional so history saved before this decodes.
    var alternatives: [Alternative]?

    // A candidate the model nearly picked. Deliberately not a nested
    // `BirdDetection`: an alternative has no identity, date or place of its own —
    // it is the same sighting under a different name.
    struct Alternative: Codable, Identifiable, Hashable {
        var id: String { scientificName }
        var commonName: String
        var scientificName: String
        var confidence: Double
        var localizedName: String?
        var imageURL: String?

        var displayName: String {
            if let name = localizedName, !name.isEmpty,
               name.lowercased() != scientificName.lowercased() { return name }
            return commonName
        }
    }

    // How close a runner-up has to be before we ask. Two species this near each
    // other are a coin-flip for the model — cheaper to ask than to guess wrong,
    // which is exactly what happens with look-alikes like the nuthatches.
    static let tiebreakRatio = 0.65

    var needsTiebreak: Bool { !(alternatives ?? []).isEmpty }

    // The user says it was one of the runners-up. The former winner keeps its own
    // score and steps down to an alternative, so the choice can be undone.
    mutating func choose(_ alternative: Alternative) {
        guard alternative.scientificName != scientificName else { return }
        let previous = Alternative(commonName: commonName,
                                   scientificName: scientificName,
                                   confidence: confidence,
                                   localizedName: localizedName,
                                   imageURL: imageURL)
        var rest = (alternatives ?? []).filter { $0.scientificName != alternative.scientificName }
        rest.append(previous)
        commonName = alternative.commonName
        scientificName = alternative.scientificName
        confidence = alternative.confidence
        localizedName = alternative.localizedName
        imageURL = alternative.imageURL
        alternatives = rest.sorted { $0.confidence > $1.confidence }
    }

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

extension Array where Element == BirdDetection {
    // The winner, carrying whichever runners-up were close enough to be worth a
    // second opinion. Used by both the photo and the audio path so "too close to
    // call" means the same thing everywhere.
    func topCarryingCloseCalls() -> BirdDetection? {
        guard var top = first, top.confidence > 0 else { return first }
        let close = dropFirst()
            .filter { $0.confidence >= top.confidence * BirdDetection.tiebreakRatio }
            .map {
                BirdDetection.Alternative(commonName: $0.commonName,
                                          scientificName: $0.scientificName,
                                          confidence: $0.confidence,
                                          localizedName: $0.localizedName,
                                          imageURL: $0.imageURL)
            }
        top.alternatives = close.isEmpty ? nil : close
        return top
    }
}
