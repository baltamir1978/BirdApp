import CoreLocation
import Observation

@Observable
@MainActor
final class LocationManager: NSObject {
    // The last fix we were handed. Nil until Core Location delivers one, which
    // takes a few seconds after launch — hence the fallback in `location`.
    private(set) var lastFix: CLLocation?
    private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    // What callers should use. Falls back to the system's cached position so a
    // photo identified seconds after launch still gets a location filter instead
    // of silently running unfiltered.
    var location: CLLocation? { lastFix ?? manager.location }

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        authorizationStatus = manager.authorizationStatus
    }

    func start() {
        switch authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
    }
}

extension LocationManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor [weak self] in self?.lastFix = loc }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.authorizationStatus = status
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                manager.startUpdatingLocation()
            }
        }
    }
}
