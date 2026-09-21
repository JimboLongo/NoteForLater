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
    /// The day this sits on — the day that was being planned when the miss
    /// was marked. Set once at creation and never advanced; see this type's
    /// own doc comment for the walk that used to move it.
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
    /// Which tasks a set of push records places on `day`.
    ///
    /// **No `isCompleted` filter, deliberately.** A resolved record still
    /// placed the occurrence on that day, and the row then reads
    /// `.complete` from `RecurringTaskLog` — which is the history the day
    /// should keep. Filtering resolved records out here made a completed
    /// pushed row disappear rather than show as done.
    ///
    /// `static` and free of any view so the *list* is testable: the same
    /// rule expressed inline in `DayTimelineGridView` went uncovered, and
    /// reverting it to the old filter failed nothing.
    static func taskIDs(on day: Date, from records: [PushedRecurringOccurrence], calendar: Calendar = .current) -> Set<UUID> {
        Set(records
            .filter { calendar.isDate($0.currentDate, inSameDayAs: day) }
            .map(\.taskID))
    }

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


}
