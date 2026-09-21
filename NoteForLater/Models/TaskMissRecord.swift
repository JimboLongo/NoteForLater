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
    // REMOVED: `pushedToDay`, which stored where the task was pushed to.
    // Its stated purpose was letting the undo tell a stale record from a
    // live one — but the undo never read it, and neither did anything else.
    // It was written on every push and read by nothing outside the tests
    // that asserted it had been written.
    //
    // Deleting it also resolves the two rows in the live store where the
    // same-day-push bug had left `pushedToDay == missedDay`: a field that
    // does not exist cannot hold a wrong value, so no migration pass over
    // personal data was needed to fix them.

    init(taskID: UUID, title: String, missedDay: Date, calendar: Calendar = .current) {
        self.id = UUID()
        self.taskID = taskID
        self.title = title
        self.missedDay = calendar.startOfDay(for: missedDay)
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
        // Total order — `missedDay` is identical for every record on this
        // day, so it decides nothing here and the fetch's own order is
        // unspecified. `id` breaks the tie so the list cannot shuffle
        // between renders. See `TaskItem.twoMinuteRows`.
        return all.sorted { ($0.missedDay, $0.id.uuidString) < ($1.missedDay, $1.id.uuidString) }
    }

    /// The miss records Nightly Review should still offer, oldest first.
    ///
    /// **Backlog only, and only while still actionable.** Two filters, each
    /// for its own reason:
    ///
    /// - **Before `reviewDate`.** A miss made during *this* review is
    ///   already represented by the task's own row further down the list —
    ///   offering both would be the same task twice, one of them as a
    ///   "last chance" for something you just decided a second ago.
    /// - **Task not complete.** The review shows what is owed; a completed
    ///   task owes nothing. This is the half that makes the calendar and
    ///   the review disagree *correctly*: the calendar keeps the row as
    ///   history, the review drops it. Both are true at once.
    ///
    /// A record whose task has been deleted is dropped too — there is
    /// nothing left to complete.
    static func actionableRecords(
        before reviewDate: Date,
        tasks: [TaskItem],
        in context: ModelContext,
        calendar: Calendar = .current
    ) -> [(record: TaskMissRecord, task: TaskItem)] {
        let reviewDay = calendar.startOfDay(for: reviewDate)
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let all = (try? context.fetch(FetchDescriptor<TaskMissRecord>())) ?? []
        return all
            .filter { $0.missedDay < reviewDay }
            .compactMap { record in
                guard let task = byID[record.taskID], !task.isCompleted else { return nil }
                return (record, task)
            }
            .sorted { ($0.record.missedDay, $0.record.id.uuidString) < ($1.record.missedDay, $1.record.id.uuidString) }
    }

    /// Every outstanding record for `task`, **oldest miss first** — the
    /// chain of misses, in the order they happened.
    ///
    /// REVERSAL: there used to be at most one of these per task, so a single
    /// lookup sufficed. Each miss is its own event now (see
    /// `TwoMinutePush.apply`), so a task missed on consecutive days carries
    /// one record per day and the *order* matters: the earliest is the one
    /// holding the pre-chain state.
    static func records(for task: TaskItem, in context: ModelContext) -> [TaskMissRecord] {
        let taskID = task.id
        let all = (try? context.fetch(FetchDescriptor<TaskMissRecord>(
            predicate: #Predicate { $0.taskID == taskID }
        ))) ?? []
        return all.sorted { ($0.missedDay, $0.id.uuidString) < ($1.missedDay, $1.id.uuidString) }
    }

    /// The **earliest** outstanding record for `task`, if any — the one that
    /// started the chain.
    ///
    /// Non-nil is also the answer to "is a push chain still open", which is
    /// what `TwoMinutePush` asks it for. Deliberately the earliest rather
    /// than an arbitrary `.first` off the fetch: an undo restores the state
    /// captured before *any* of the chain, so which record that is has to be
    /// deterministic.
    static func record(for task: TaskItem, in context: ModelContext) -> TaskMissRecord? {
        records(for: task, in: context).first
    }

    /// The record for `task` on one specific day, if it has one.
    ///
    /// The per-day uniqueness `TwoMinutePush.apply` enforces: a row cycled
    /// back to `.missed` without an intervening undo must not stack a second
    /// row on the day it is already recorded as missed on.
    static func record(
        for task: TaskItem,
        on day: Date,
        in context: ModelContext,
        calendar: Calendar = .current
    ) -> TaskMissRecord? {
        let target = calendar.startOfDay(for: day)
        return records(for: task, in: context).first { $0.missedDay == target }
    }
}
