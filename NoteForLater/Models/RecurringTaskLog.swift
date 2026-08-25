import Foundation
import SwiftData

/// Per-day completion for a recurring `TaskItem` shown as a plain
/// AM/Midday/PM check-off item (see `TaskItem.recurrenceTimeMode`) —
/// exists for the same reason `HabitLog` does: an occurrence like this
/// never gets a `ScheduledBlock`, so there's no block-level
/// `isCompleted` to toggle. Simpler than `HabitLog` in one respect — a
/// recurring task has exactly one occurrence per day, never
/// `timesPerDay`-many, so this tracks a single `isCompleted` rather than
/// three occurrence-index arrays.
///
/// `taskID` is a copied `TaskItem.id`, not a `@Relationship` — same
/// "survive the original being edited or deleted" reasoning
/// `TaskCompletionRecord.taskID` already uses, rather than `HabitLog`'s
/// own relationship to `Habit` (a recurring task, unlike a habit, can be
/// deleted outright, and this log shouldn't become an orphaned crash
/// waiting to happen if that occurs).
@Model
final class RecurringTaskLog {
    var id: UUID
    var taskID: UUID
    var date: Date
    var isCompleted: Bool
    /// Same reason `HabitLog.lastModified` exists — reconciling duplicate
    /// same-day logs (a real, possible outcome of two near-simultaneous
    /// taps under SwiftData's own pending-insert timing) needs a way to
    /// tell which of two logs for the same day is the newer one.
    var lastModified: Date = Date.distantPast

    init(taskID: UUID, date: Date, isCompleted: Bool = false) {
        self.id = UUID()
        self.taskID = taskID
        self.date = Calendar.current.startOfDay(for: date)
        self.isCompleted = isCompleted
        self.lastModified = Date()
    }

    /// Every `RecurringTaskLog` for `taskID` on `day` — found by
    /// **fetch**, which (unlike a relationship traversal) sees a pending,
    /// not-yet-saved insert made earlier in this same transaction. See
    /// `Habit.logOrCreate`'s own doc comment for the full story of why
    /// that distinction is load-bearing here too.
    static func sameDayLogs(taskID: UUID, day: Date, context: ModelContext, calendar: Calendar = .current) -> [RecurringTaskLog] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        let descriptor = FetchDescriptor<RecurringTaskLog>(
            predicate: #Predicate { $0.taskID == taskID && $0.date >= start && $0.date < end }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// The safe read for a write decision (deciding which direction to
    /// toggle) — always resolves duplicates to the most recently written
    /// log via `lastModified`, same as `Habit.log(on:context:)`.
    static func log(taskID: UUID, on date: Date, context: ModelContext, calendar: Calendar = .current) -> RecurringTaskLog? {
        sameDayLogs(taskID: taskID, day: date, context: context, calendar: calendar)
            .max(by: { $0.lastModified < $1.lastModified })
    }

    static func logOrCreate(taskID: UUID, on date: Date, context: ModelContext, calendar: Calendar = .current) -> RecurringTaskLog {
        let day = calendar.startOfDay(for: date)
        if let existing = log(taskID: taskID, on: day, context: context, calendar: calendar) {
            return existing
        }
        let newLog = RecurringTaskLog(taskID: taskID, date: day)
        context.insert(newLog)
        return newLog
    }
}
