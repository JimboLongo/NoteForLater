import Foundation
import Observation

/// Tracks which synced calendar events the user has manually flipped away
/// from their default lock state. Events genuinely external to the app
/// (never pushed by it) default to locked; app-originated events never go
/// through this store at all (see ScheduleReviewView's timelineRows — a
/// pushed-and-synced-back block is recognized by ID/title and shown only as
/// its proposed-block row, not a separate calendar-event row). Locked
/// events can still be edited (title/time/notes) from their detail sheet,
/// but they're excluded from the Schedule tab's drag-to-reorder. Keyed by
/// Google's event ID, persisted in UserDefaults since calendar events
/// themselves aren't stored locally.
@Observable
final class LockedEventsStore {
    static let shared = LockedEventsStore()

    private let defaultsKey = "com.jimbo.NoteForLater.lockOverrideEventIDs"
    private(set) var overriddenIDs: Set<String>

    private init() {
        overriddenIDs = Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
    }

    /// Synced calendar events default to locked. Toggling flips away from
    /// that default and remembers the override so it survives future syncs.
    func isLocked(_ eventID: String, defaultLocked: Bool = true) -> Bool {
        overriddenIDs.contains(eventID) ? !defaultLocked : defaultLocked
    }

    func toggle(_ eventID: String) {
        if overriddenIDs.contains(eventID) {
            overriddenIDs.remove(eventID)
        } else {
            overriddenIDs.insert(eventID)
        }
        UserDefaults.standard.set(Array(overriddenIDs), forKey: defaultsKey)
    }
}
