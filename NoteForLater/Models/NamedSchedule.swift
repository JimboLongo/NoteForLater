import Foundation
import SwiftData

/// A reusable day/time window — e.g. "Work" (Mon–Fri 9–5), "After Work"
/// (Mon–Fri 6–9pm) — defined once from the Schedules tab and then referenced
/// by any shelf's SchedulingRules, instead of redefining the same window
/// per shelf. A rule that references one just adds its own fill strategy
/// (fill to fit / max duration / max task count) on top.
@Model
final class NamedSchedule {
    var id: UUID
    var name: String
    /// Calendar weekday numbering: 1 = Sunday ... 7 = Saturday.
    var daysOfWeek: [Int] = [2, 3, 4, 5, 6]
    var startHour: Int = 9
    var startMinute: Int = 0
    var endHour: Int = 17
    var endMinute: Int = 0
    var sortOrder: Int = 0

    init(
        name: String = "New Schedule",
        daysOfWeek: [Int] = [2, 3, 4, 5, 6],
        startHour: Int = 9,
        startMinute: Int = 0,
        endHour: Int = 17,
        endMinute: Int = 0,
        sortOrder: Int = 0
    ) {
        self.id = UUID()
        self.name = name
        self.daysOfWeek = daysOfWeek
        self.startHour = startHour
        self.startMinute = startMinute
        self.endHour = endHour
        self.endMinute = endMinute
        self.sortOrder = sortOrder
    }

    var dayAndTimeText: String {
        SchedulingRule.dayAndTimeText(
            daysOfWeek: daysOfWeek,
            startHour: startHour, startMinute: startMinute,
            endHour: endHour, endMinute: endMinute
        )
    }
}
