import Foundation
import SwiftData

/// A record that a 2-Minute task was missed on a particular day.
///
/// **Why this exists at all.** Marking a 2-Minute task missed moves it —
/// the push is a `startDate` write, and a task has exactly one of those, so
/// the row leaves the day it was missed on. That is correct for the *work*
/// (it is owed on the day being planned now) and wrong for the *history*:
/// the day it was missed on ends up showing nothing, as though it never
/// carried the task at all.
///
/// This is the half that stays behind. The live `TaskItem` moves to the
/// planned day; this sits on the original day reading as missed. Two rows,
/// one live and one inert, rather than one row that teleports.
///
/// **Deliberately not per-day status on the task.** The alternative was a
/// `RecurringTaskLog` equivalent — status per task per day — so both rows
/// could be independently live. A 2-Minute task happens *once*, so that
/// would invent a per-day axis for something with no per-day existence, and
/// leave completion expressible in three places (`task.status`, the per-day
/// log, and `TaskCompletionRecord`) that can disagree. One source of truth
/// for "is this done" is `task.status`; this record only says "on this day,
/// it was missed."
///
/// **Scoped to 2-Minute tasks, and that is not an oversight.** An ordinary
/// task block already carries its own miss: a past incomplete
/// `ScheduledBlock` is retained rather than deleted overnight (see
/// `ScheduleReviewViewModel.clearBlocksBeforeToday`) and *is* the record.
/// Writing one of these from the block path too would give a single miss
/// two representations that can disagree — the retained block and this —
/// which is the failure this codebase keeps producing. A 2-Minute task has
/// no block, which is exactly why it needs this and a block does not.
///
/// `taskID` is a copied `TaskItem.id` rather than a `@Relationship`, same
/// "survive the original being edited or deleted" reasoning
/// `TaskCompletionRecord.taskID` and `RecurringTaskLog.taskID` already use.
/// `title` is copied for the same reason: the row has to render after the
/// task is gone.
@Model
final class TaskMissRecord {
    var id: UUID
    /// The originating `TaskItem.id`. Used to find the record for undo, and
    /// to ask whether its task has since been completed — which is what
    /// decides whether Nightly Review still offers it.
    var taskID: UUID
    /// Copied, not read through `taskID`, so the row still renders if the
    /// task is deleted.
    var title: String
    /// The day the miss happened — start of day. This is the day the row
    /// appears on, and it never moves: unlike
    /// `PushedRecurringOccurrence.currentDate`, there is no walk that
    /// advances it. A miss belongs to the day it happened on.
    var missedDay: Date
    /// Where the task was pushed to. Kept so the undo can tell a stale
    /// record (whose push has since been changed by something else) from a
    /// live one, rather than assuming the task's current `startDate` is
    /// still the one this record created.
    var pushedToDay: Date

    init(taskID: UUID, title: String, missedDay: Date, pushedToDay: Date, calendar: Calendar = .current) {
        self.id = UUID()
        self.taskID = taskID
        self.title = title
        self.missedDay = calendar.startOfDay(for: missedDay)
        self.pushedToDay = calendar.startOfDay(for: pushedToDay)
    }
}

extension TaskMissRecord {
    /// Every miss record for `day`, oldest task first.
    ///
    /// `static` and free of any view so the *list* is testable rather than
    /// only the per-record rule — three separate times this session a rule
    /// was covered while the call site that applied it was not.
    static func records(on day: Date, in context: ModelContext, calendar: Calendar = .current) -> [TaskMissRecord] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        let all = (try? context.fetch(FetchDescriptor<TaskMissRecord>(
            predicate: #Predicate { $0.missedDay >= start && $0.missedDay < end }
        ))) ?? []
        return all.sorted { $0.missedDay < $1.missedDay }
    }

    /// The outstanding record for `task`, if any.
    ///
    /// At most one exists at a time: a task cycled missed twice without an
    /// intervening undo keeps its first record rather than piling up, the
    /// same "already pushed" shape `pushRecurringOccurrenceIfNeeded` uses.
    static func record(for task: TaskItem, in context: ModelContext) -> TaskMissRecord? {
        let taskID = task.id
        return (try? context.fetch(FetchDescriptor<TaskMissRecord>(
            predicate: #Predicate { $0.taskID == taskID }
        )))?.first
    }
}
