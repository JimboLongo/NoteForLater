import Foundation
import Observation

/// How much advance notice to give before an approved scheduled block
/// (task or habit) starts. Persisted in UserDefaults, same as
/// NightlyReviewSettings — a single global preference, not per-record
/// data. Doesn't trigger the actual reschedule itself (unlike
/// NightlyReviewSettings, which needs no outside data to rebuild its one
/// fixed daily notification) — `UpcomingBlockNotificationService.reschedule`
/// needs the current block list, so ContentView's own `.onChange` of both
/// this settings object and its `allBlocks` query is what actually kicks
/// that off.
@Observable
final class UpcomingReminderSettings {
    static let shared = UpcomingReminderSettings()

    private let enabledKey = "com.jimbo.NoteForLater.upcomingReminderEnabled"
    private let leadMinutesKey = "com.jimbo.NoteForLater.upcomingReminderLeadMinutes"

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: enabledKey) }
    }

    /// One of `UpcomingReminderSettings.leadOptions`. Defaults to 15 minutes.
    var leadMinutes: Int {
        didSet { UserDefaults.standard.set(leadMinutes, forKey: leadMinutesKey) }
    }

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
        let storedLead = UserDefaults.standard.object(forKey: leadMinutesKey) as? Int
        leadMinutes = storedLead ?? 15
    }

    static let leadOptions = [5, 10, 15, 30, 60]

    static func leadLabel(for minutes: Int) -> String {
        minutes == 60 ? "1 hour" : "\(minutes) minutes"
    }
}
