import Foundation
import SwiftData

/// Per-day status for a recurring `TaskItem` — the task counterpart to
/// `HabitLog`, and (since a Nightly Review upgrade unified both time
/// modes onto this single store) now the source of truth for a
/// Specific-Time occurrence's completion too, not just the untimed
/// AM/Midday/PM modes it originally covered. Simpler than `HabitLog` in
/// one respect — a recurring task has exactly one occurrence per day,
/// never `timesPerDay`-many, so this tracks a single `status` rather
/// than three occurrence-index arrays.
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
    /// Backing storage for `status` — see `OccurrenceStatus`'s own doc
    /// comment for why this is a raw string, not the enum directly.
    /// Defaults to `.none`'s raw value so a pre-migration row (which had
    /// no `statusRaw` column at all) reads as untouched, matching the old
    /// `isCompleted: Bool`'s own default of `false`.
    var statusRaw: String = OccurrenceStatus.none.rawValue
    /// Same reason `HabitLog.lastModified` exists — reconciling duplicate
    /// same-day logs (a real, possible outcome of two near-simultaneous
    /// taps under SwiftData's own pending-insert timing) needs a way to
    /// tell which of two logs for the same day is the newer one.
    var lastModified: Date = Date.distantPast

    /// `complete -> missed -> none`, cycled by `TaskItem
    /// .cycleRecurringOccurrence` — deliberately never `.excused`; that
    /// state exists on the shared `OccurrenceStatus` enum only because
    /// habits use it, not because a recurring task's cycle admits it.
    /// Nothing ever writes `.excused` here.
    var status: OccurrenceStatus {
        get { OccurrenceStatus(rawValue: statusRaw) ?? .none }
        set { statusRaw = newValue.rawValue }
    }

    /// Convenience read for every call site that only ever needed a
    /// binary "is this genuinely done" — `.missed` reads `false` here,
    /// same as `.none`, which is correct for all of them; none currently
    /// need to tell "untouched" apart from "missed." **Get-only,
    /// deliberately**: a setter here would let `log.isCompleted = false`
    /// silently collapse an explicit `.missed` back to `.none` — every
    /// write goes through `status` instead, which is why
    /// `DayTimelineGridView.toggleRecurringTaskOccurrence` (the one
    /// remaining external write site) sets `.status`, not this.
    var isCompleted: Bool { status == .complete }

    init(taskID: UUID, date: Date, status: OccurrenceStatus = .none) {
        self.id = UUID()
        self.taskID = taskID
        self.date = Calendar.current.startOfDay(for: date)
        self.statusRaw = status.rawValue
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
