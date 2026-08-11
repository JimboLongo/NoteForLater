import Foundation
import Observation

/// When to run the Nightly Review — go through today's schedule, sort the
/// Inbox, and approve tomorrow's plan. Persisted in UserDefaults (like
/// LockedEventsStore) since it's a single global preference, not
/// per-record data.
@Observable
final class NightlyReviewSettings {
    static let shared = NightlyReviewSettings()

    private let enabledKey = "com.jimbo.NoteForLater.nightlyReviewEnabled"
    private let minutesKey = "com.jimbo.NoteForLater.nightlyReviewMinutes"

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: enabledKey)
            NightlyReviewNotificationService.shared.reschedule(isEnabled: isEnabled, minutesOfDay: minutesOfDay)
        }
    }

    /// Minutes since midnight. Defaults to 8:00 PM.
    var minutesOfDay: Int {
        didSet {
            UserDefaults.standard.set(minutesOfDay, forKey: minutesKey)
            NightlyReviewNotificationService.shared.reschedule(isEnabled: isEnabled, minutesOfDay: minutesOfDay)
        }
    }

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
        minutesOfDay = (UserDefaults.standard.object(forKey: minutesKey) as? Int) ?? 1200
    }

    /// Convenience for a `DatePicker(displayedComponents: .hourAndMinute)` binding.
    var time: Date {
        get {
            var components = DateComponents()
            components.hour = minutesOfDay / 60
            components.minute = minutesOfDay % 60
            return Calendar.current.date(from: components) ?? .now
        }
        set {
            let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            minutesOfDay = (components.hour ?? 20) * 60 + (components.minute ?? 0)
        }
    }
}
