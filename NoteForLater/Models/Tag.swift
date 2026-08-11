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
    /// Gates the actual geofence, independent of `hasLocation` — lets a
    /// tag keep its place attached (for reference, or to turn notify back
    /// on later) without `LocationMonitoringService.syncRegions` actively
    /// monitoring for it. Defaults to on, matching every located tag's
    /// behavior before this toggle existed.
    var notifyWhenNear: Bool = true
    /// Set from the tag's own screen (`LocationTagPickerView`'s "Reviewed"
    /// button) — decided whether it needs a location or not. An
    /// unreviewed tag shows up at the end of Task Attribute Review (see
    /// `TaskReviewQueueSheet`) until it's dealt with one way or the other.
    var isReviewed: Bool = false

    init(name: String, hasLocation: Bool = false, latitude: Double = 0, longitude: Double = 0, radiusMeters: Double = 400, addressLabel: String = "", notifyWhenNear: Bool = true, isReviewed: Bool = false) {
        self.id = UUID()
        self.name = name
        self.hasLocation = hasLocation
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
        self.addressLabel = addressLabel
        self.notifyWhenNear = notifyWhenNear
        self.isReviewed = isReviewed
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Stored in meters (what `CLCircularRegion` geofencing needs), shown
    /// in miles with an estimated *driving* time — this is a proximity
    /// geofence around places you'd drive to, not a walking radius.
    var radiusDescription: String {
        let miles = radiusMeters / Tag.metersPerMile
        let minutes = max(1, Int((miles / Tag.averageDrivingMph * 60).rounded()))
        return String(format: "%.1f mi · ~%d min drive", miles, minutes)
    }

    static let metersPerMile: Double = 1609.34
    /// Rough average for city/suburban driving, used only to turn a
    /// geofence radius into an approximate drive-time estimate.
    static let averageDrivingMph: Double = 30
}
