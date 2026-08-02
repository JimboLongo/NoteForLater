import Foundation
import SwiftData
import CoreLocation

/// The app-wide "box of tags": every tag name ever attached to a task or
/// inbox item lives here once, whether or not it carries a location. Tagging
/// a task with an existing name reuses this entry; tagging with a new name
/// creates one. `hasLocation` gates whether the location fields mean anything
/// — a tag can exist in the box with no place attached yet.
@Model
final class Tag {
    var id: UUID
    var name: String
    var hasLocation: Bool = false
    var latitude: Double = 0
    var longitude: Double = 0
    var radiusMeters: Double = 400
    var addressLabel: String = ""

    init(name: String, hasLocation: Bool = false, latitude: Double = 0, longitude: Double = 0, radiusMeters: Double = 400, addressLabel: String = "") {
        self.id = UUID()
        self.name = name
        self.hasLocation = hasLocation
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
