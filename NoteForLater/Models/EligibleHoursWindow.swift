import Foundation
import SwiftData

/// A global window of time during which the AI Scheduler is allowed to
/// assign anything at all, regardless of which shelf's rule it's pulling
/// from — a top-level guardrail on top of each shelf's own pull windows.
/// No windows configured (the default) means no restriction: every hour is
/// eligible, same as before this existed.
@Model
final class EligibleHoursWindow {
    var id: UUID
    /// Calendar weekday numbering: 1 = Sunday ... 7 = Saturday.
    var daysOfWeek: [Int] = [2, 3, 4, 5, 6]
    var startHour: Int = 8
    var startMinute: Int = 0
    var endHour: Int = 21
    var endMinute: Int = 0
    var isEnabled: Bool = true
    var sortOrder: Int = 0

    init(
        daysOfWeek: [Int] = [2, 3, 4, 5, 6],
        startHour: Int = 8,
        startMinute: Int = 0,
        endHour: Int = 21,
        endMinute: Int = 0,
        isEnabled: Bool = true,
        sortOrder: Int = 0
    ) {
        self.id = UUID()
        self.daysOfWeek = daysOfWeek
        self.startHour = startHour
        self.startMinute = startMinute
        self.endHour = endHour
        self.endMinute = endMinute
        self.isEnabled = isEnabled
        self.sortOrder = sortOrder
    }

    var summary: String {
        SchedulingRule.dayAndTimeText(
            daysOfWeek: daysOfWeek,
            startHour: startHour, startMinute: startMinute,
            endHour: endHour, endMinute: endMinute
        )
    }
}
