import Foundation
import SwiftData

/// A single time block on the proposed (or approved) daily schedule.
/// Generated nightly by AISchedulingService for the following day, then
/// reviewed/edited by the user in ScheduleReviewView before it's "live".
@Model
final class ScheduledBlock {
    var id: UUID
    var date: Date          // calendar day this block belongs to
    var startTime: Date
    var endTime: Date
    var approvalStatusRaw: String

    /// The Google Calendar event this block was pushed to, if it has been
    /// approved at least once. Re-approving after an edit updates this same
    /// event instead of creating a duplicate.
    var googleEventID: String?
    var isCompleted: Bool = false
    /// Locked from the calendar grid's lock icon — excluded from the
    /// ripple-reflow when another block is dragged past it (see
    /// `ScheduleReviewViewModel.moveEntry`'s `unlockedOrder`) and preserved
    /// as-is by `regenerateFromNow` instead of being cleared and re-placed.
    var isLocked: Bool = false
    /// True when this block's duration was guessed rather than taken from
    /// the task's own (unset) `estimatedMinutes` — see
    /// `AISchedulingService.guessedMinutes`. Shown with a "~" in front of
    /// the duration on the timeline so it reads as an estimate, not a
    /// commitment the user actually made.
    var isEstimatedDuration: Bool = false

    var task: TaskItem?
    /// The habit this block was generated for, if it came from the Habit
    /// Tracker's "Eligible to be Scheduled?" toggle rather than a shelf
    /// task. A block has at most one of `task`/`habit`/`mealSelection` set.
    var habit: Habit?
    /// The meal picked during Nightly Review's Meals step, if this is that
    /// block — inserted directly at selection time (not by
    /// `AISchedulingService`'s packer, the same way a recurring task's
    /// fixed-time pass bypasses it too), always at 5pm, always
    /// `isLocked`. See `MealSelection`'s own doc comment for why this is a
    /// separate model rather than a `TaskItem`.
    var mealSelection: MealSelection?
    /// Which of the habit's `timesPerDay` occurrences this block is for
    /// (0-based — "BrushTeeth.1" is index 0, "BrushTeeth.2" is index 1),
    /// meaningless when `habit` is nil. Lets completing this one calendar
    /// event mark only its own occurrence circle instead of the whole
    /// day's habit log.
    var habitOccurrenceIndex: Int = 0

    init(date: Date, startTime: Date, endTime: Date, task: TaskItem?, habit: Habit? = nil, habitOccurrenceIndex: Int = 0, approvalStatus: ApprovalStatus = .proposed, isEstimatedDuration: Bool = false) {
        self.id = UUID()
        self.date = date
        self.startTime = startTime
        self.endTime = endTime
        self.task = task
        self.habit = habit
        self.habitOccurrenceIndex = habitOccurrenceIndex
        self.approvalStatusRaw = approvalStatus.rawValue
        self.isEstimatedDuration = isEstimatedDuration
    }

    var approvalStatus: ApprovalStatus {
        get { ApprovalStatus(rawValue: approvalStatusRaw) ?? .proposed }
        set { approvalStatusRaw = newValue.rawValue }
    }

    var durationMinutes: Int {
        Int(endTime.timeIntervalSince(startTime) / 60)
    }

    /// What to show for this block regardless of source.
    var displayTitle: String {
        task?.title ?? habit?.name ?? mealSelection.map { "Dinner: \($0.recipeTitle)" } ?? "Open slot"
    }
}
