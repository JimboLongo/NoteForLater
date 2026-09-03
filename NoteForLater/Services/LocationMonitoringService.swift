import Foundation
import CoreLocation
import UserNotifications
import SwiftData

/// Geofences every Tag that has a location attached and fires a local
/// notification listing what's tagged there when you come within its
/// radius. iOS caps monitored regions at 20 per app, so only the first 20
/// located tags are watched.
@Observable
final class LocationMonitoringService: NSObject {
    static let shared = LocationMonitoringService()

    private let locationManager = CLLocationManager()
    private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    /// Set once at launch (see NoteForLaterApp) so region-entry callbacks
    /// can look up which tasks/inbox items carry the triggered tag.
    var modelContainer: ModelContainer?

    /// Last time each tag (by region identifier) actually fired a
    /// notification. `syncRegions` re-runs on every tag edit and re-checks
    /// state for every monitored region via `requestState`, so without this
    /// sitting inside a region would re-notify on every resync.
    private var lastNotified: [String: Date] = [:]
    private let renotifyInterval: TimeInterval = 60 * 60

    private override init() {
        super.init()
        locationManager.delegate = self
        authorizationStatus = locationManager.authorizationStatus
    }

    /// Requests both "Always" location access (region monitoring needs it
    /// to fire reliably when the app isn't running) and notification
    /// permission, so proximity reminders can actually be delivered.
    func requestAuthorization() {
        locationManager.requestAlwaysAuthorization()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Re-syncs monitored regions to match `tags` — stops monitoring
    /// anything removed/changed, starts monitoring the rest. Only tags
    /// with `hasLocation == true` *and* `notifyWhenNear == true` end up
    /// actually monitored — a location can be kept on a tag with proximity
    /// notifications switched off.
    func syncRegions(with tags: [Tag]) {
        for region in locationManager.monitoredRegions {
            locationManager.stopMonitoring(for: region)
        }
        for tag in tags.filter({ $0.hasLocation && $0.notifyWhenNear }).prefix(20) {
            let region = CLCircularRegion(center: tag.coordinate, radius: tag.radiusMeters, identifier: tag.name)
            region.notifyOnEntry = true
            region.notifyOnExit = false
            locationManager.startMonitoring(for: region)
            // CoreLocation only calls didEnterRegion on a *new* boundary
            // crossing — if we're already inside when monitoring starts
            // (app launch, tag edit while nearby), didEnterRegion never
            // fires. requestState's didDetermineState callback catches
            // that "already inside" case.
            locationManager.requestState(for: region)
        }
    }
}

extension LocationMonitoringService: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        notifyForTag(named: region.identifier)
    }

    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard state == .inside else { return }
        notifyForTag(named: region.identifier)
    }

    private func notifyForTag(named tagName: String) {
        if let last = lastNotified[tagName], Date().timeIntervalSince(last) < renotifyInterval { return }

        guard let modelContainer else { return }
        let context = ModelContext(modelContainer)
        guard let tasks = try? context.fetch(FetchDescriptor<TaskItem>()) else { return }

        let matching = tasks.filter { !$0.isCompleted && $0.tags.contains(tagName) }
        guard !matching.isEmpty else { return }

        lastNotified[tagName] = Date()

        let content = UNMutableNotificationContent()
        content.title = "Near \(tagName)"
        content.body = matching.count == 1
            ? matching[0].title
            : "\(matching.count) tasks: \(matching.prefix(3).map(\.title).joined(separator: ", "))"
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
