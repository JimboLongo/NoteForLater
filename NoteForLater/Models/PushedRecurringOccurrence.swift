import Foundation
import SwiftData

/// Tracks a recurring `TaskItem` occurrence left incomplete at the end of
/// Nightly Review — rather than just vanishing (today's behavior:
/// `ScheduleReviewViewModel.clearIncompletePastBlocks` deletes any
/// incomplete past block, recurring task or not, with nothing else
/// stepping in to replace it), it's pushed forward one day at a time
/// until it lines up with the task's own next real recurrence, at which
/// point this record resolves itself (deleted) and the normal recurrence
/// pattern takes back over — `AISchedulingService
/// .placeHabitsAndRecurringTasks`'s own "already exists" guard is what
/// then stops a duplicate, ordinary occurrence from also being created
/// for that same day. Never checks `recurrenceEndDate` — an
/// already-missed occurrence keeps pushing regardless of whether the
/// recurrence itself has since "ended." That default *is* overridable
/// per-task, though: `TaskItem.isPushable` (`true` by default) is
/// checked upstream, before a record like this ever gets created —
/// `ScheduleReviewViewModel.pushRecurringOccurrenceIfNeeded` and
/// `.carriedForwardRecurringTaskIDs` both no-op for a task with
/// `isPushable == false`, so "keeps pushing regardless of `recurrenceEndDate`"
/// only describes a record that was allowed to exist in the first place.
///
/// `taskID` is a copied `TaskItem.id`, not a `@Relationship` — same
/// "survive the original being edited or deleted" reasoning
/// `TaskCompletionRecord.taskID`/`RecurringTaskLog.taskID` already use.
@Model
final class PushedRecurringOccurrence {
    var id: UUID
    var taskID: UUID
    /// The day this was first missed — kept purely for reference (e.g. a
    /// future "originally due" label); the push-forward walk itself only
    /// ever reads/writes `currentDate`.
    var originalDate: Date
    /// Where the chain currently sits — advances one day at a time each
    /// time the app-launch catch-up routine
    /// (`NoteForLaterApp.processPushedRecurringOccurrencesIfNeeded`)
    /// finds it still unresolved.
    var currentDate: Date
    var isCompleted: Bool = false

    init(taskID: UUID, originalDate: Date, currentDate: Date? = nil) {
        self.id = UUID()
        self.taskID = taskID
        self.originalDate = Calendar.current.startOfDay(for: originalDate)
        self.currentDate = Calendar.current.startOfDay(for: currentDate ?? originalDate)
        self.isCompleted = false
    }
}

extension PushedRecurringOccurrence {
    /// True once a completed `RecurringTaskLog` exists for
    /// `occurrence.currentDate`.
    ///
    /// There used to be a second source here: a Specific Time block checked
    /// off on the calendar. A recurring task has no block any more, and
    /// `RecurringTaskLog` is its single source of truth regardless of mode
    /// (see `TaskItem.cycleRecurringOccurrence`). Checked *before* trying to push
    /// further, so completing the pushed instance through its normal,
    /// already-existing "mark complete" UI is all it takes to resolve the
    /// chain — nothing else needs to know a push was ever in progress.
    static func isAlreadyResolved(_ occurrence: PushedRecurringOccurrence, task: TaskItem, calendar: Calendar, context: ModelContext) -> Bool {
        RecurringTaskLog.log(taskID: task.id, on: occurrence.currentDate, context: context, calendar: calendar)?.isCompleted ?? false
    }

    /// Advances `occurrence` forward by exactly one day, from `cursor`
    /// (its own current position) to `next` — the extracted body of what
    /// used to be one iteration of `NoteForLaterApp.advanceOneDay`'s
    /// catch-up loop, now shared so a fresh miss detected by tonight's
    /// Nightly Review can get this same one-day hop immediately (see
    /// `NightlyReviewView`'s today→tomorrow `Task`, alongside
    /// `ScheduleReviewViewModel.guaranteePlacement`) instead of only ever
    /// happening at the next app launch. `advanceOneDay` itself becomes a
    /// loop that calls this once per day it needs to catch up — the two
    /// call sites share one implementation rather than risking two that
    /// drift apart.
    ///
    /// Resolves (deletes) `occurrence` outright if `next` is itself a real
    /// recurrence day for `task` — the ordinary recurrence pattern takes
    /// over from there, with `AISchedulingService
    /// .placeHabitsAndRecurringTasks`'s own "already exists" check
    /// preventing a duplicate. Otherwise advances `occurrence.currentDate`.
    /// Returns whether the occurrence was resolved, so a calling loop knows
    /// to stop.
    ///
    /// This used to relocate a Specific Time placeholder `ScheduledBlock`
    /// alongside the date advance, and delete it on resolve. A recurring
    /// task can no longer be Specific Time (see `HabitOccurrenceTimeMode
    /// .taskSelectableCases`), so it has no block to move — the push is
    /// purely a date advance now, and completion lives in
    /// `RecurringTaskLog` for every recurring task.
    @discardableResult
    static func advanceOneHop(_ occurrence: PushedRecurringOccurrence, task: TaskItem, from cursor: Date, to next: Date, calendar: Calendar, context: ModelContext) -> Bool {
        if task.hasRecurringOccurrence(on: next, calendar: calendar) {
            context.delete(occurrence)
            return true
        }
        occurrence.currentDate = next
        return false
    }

}
