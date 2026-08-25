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
/// recurrence itself has since "ended."
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
