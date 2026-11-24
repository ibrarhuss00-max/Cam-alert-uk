import Foundation
import CoreLocation

/// GPS for driving. Keeps running in the background (needs the "location" background mode),
/// which is what lets alerts continue when the phone is locked or CarPlay is in front.
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    var onLocation: ((CLLocation) -> Void)?
    var onAuthChange: ((CLAuthorizationStatus) -> Void)?

    private let manager = CLLocationManager()
    private var askedForAlways = false

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
    }

    func start() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            begin()
        default:
            onAuthChange?(manager.authorizationStatus)
        }
    }

    private func begin() {
        manager.startUpdatingLocation()
        if manager.authorizationStatus == .authorizedWhenInUse && !askedForAlways {
            // "Always" lets alerts keep working when CarPlay starts the app with the phone locked.
            askedForAlways = true
            manager.requestAlwaysAuthorization()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthChange?(manager.authorizationStatus)
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            begin()
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 100 else { return }
        onLocation?(loc)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient errors (no fix yet) are normal; updates continue.
    }
}
