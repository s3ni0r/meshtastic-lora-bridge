import Foundation
import CoreLocation
import Observation

/// The phone's own GPS location, used to show distance to the tracked Dronetag.
@Observable
final class PhoneLocation: NSObject, CLLocationManagerDelegate {
    var coordinate: CLLocationCoordinate2D?

    @ObservationIgnored private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    /// Great-circle distance (metres) from the phone to `coord`, or nil if either is unknown.
    func distance(to coord: CLLocationCoordinate2D?) -> Double? {
        guard let me = coordinate, let c = coord else { return nil }
        return CLLocation(latitude: me.latitude, longitude: me.longitude)
            .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        if let l = locs.last { coordinate = l.coordinate }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        switch m.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: m.startUpdatingLocation()
        default: break
        }
    }
}
