import Foundation
import SwiftData

/// Which of the user's Google calendars should count as "busy" when the AI
/// Scheduler looks for open slots. Populated from the calendar list after
/// signing in (Settings > Scheduler); toggled per-calendar there.
@Model
final class CalendarSubscription {
    var id: UUID
    var calendarID: String   // Google's calendar ID, e.g. "primary" or an email address
    var name: String
    var isEnabled: Bool

    init(calendarID: String, name: String, isEnabled: Bool = true) {
        self.id = UUID()
        self.calendarID = calendarID
        self.name = name
        self.isEnabled = isEnabled
    }
}
