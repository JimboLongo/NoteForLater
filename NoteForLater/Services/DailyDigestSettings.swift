import Foundation
import Observation

/// Up to three times a day when a single "here's what's still open today"
/// local notification fires (see `DailyDigestNotificationService`), listing
/// every not-yet-complete habit occurrence and scheduled task for the day
/// instead of a separate reminder per habit/task. Persisted in
/// UserDefaults, same as NightlyReviewSettings — a single global
/// preference, not per-record data. Doesn't trigger the actual reschedule
/// itself — building the digest needs the current habit/block lists, so
/// ContentView's own `.onChange` of this settings object (and of those
/// queries) is what actually kicks that off, same reasoning as
/// `UpcomingReminderSettings` used to document.
@Observable
final class DailyDigestSettings {
    static let shared = DailyDigestSettings()

    private let enabledKey = "com.jimbo.NoteForLater.dailyDigestEnabled"
    private let minutesKey = "com.jimbo.NoteForLater.dailyDigestMinutes"

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: enabledKey) }
    }

    /// Always exactly `slotCount` entries, minutes-since-midnight each.
    /// Defaults to 9:00 AM, 1:00 PM, 6:00 PM.
    private(set) var minutesOfDay: [Int] {
        didSet { UserDefaults.standard.set(minutesOfDay, forKey: minutesKey) }
    }

    static let slotCount = 3

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
        let stored = UserDefaults.standard.array(forKey: minutesKey) as? [Int]
        minutesOfDay = stored?.count == Self.slotCount ? stored! : [540, 780, 1080]
    }

    /// Convenience for a `DatePicker(displayedComponents: .hourAndMinute)` binding at `index`.
    func time(at index: Int) -> Date {
        var components = DateComponents()
        components.hour = minutesOfDay[index] / 60
        components.minute = minutesOfDay[index] % 60
        return Calendar.current.date(from: components) ?? .now
    }

    func setTime(_ date: Date, at index: Int) {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        minutesOfDay[index] = (components.hour ?? 9) * 60 + (components.minute ?? 0)
    }
}
