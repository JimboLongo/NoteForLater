import Foundation
import SwiftData
import CoreLocation

/// Ties a tag name (e.g. "costco") to a real-world place. Any task or inbox
/// item carrying that tag becomes part of the proximity notification for
/// this location — come within `radiusMeters` and you'll get a reminder
/// listing what's tagged here.
@Model
final class LocationTag {
    var id: UUID
    var name: String
    var latitude: Double = 0
    var longitude: Double = 0
    /// ~400m defaults to roughly a 5-minute walk.
    var radiusMeters: Double = 400
    var addressLabel: String = ""

    init(name: String, latitude: Double, longitude: Double, radiusMeters: Double = 400, addressLabel: String = "") {
        self.id = UUID()
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
        self.addressLabel = addressLabel
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var radiusDescription: String {
        let minutes = max(1, Int(radiusMeters / 80)) // ~80m/min average walking pace
        return "\(Int(radiusMeters))m · ~\(minutes) min walk"
    }
}
