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
    /// Set by `ScheduleReviewViewModel.insertBlock`/`moveExistingBlock` —
    /// the empty-slot picker's own placement paths — never by the
    /// scheduler. Exists specifically so a task placed by hand into a
    /// slot it isn't rule-eligible for ("an intentional override of its
    /// eligible-schedule constraint" — see the empty-slot picker's own
    /// design doc) actually survives: without it, the very next
    /// `autoPlaceEligibleTasks` pass (which runs on essentially every
    /// Calendar appear) sweeps an unlocked/unapproved/incomplete block
    /// whose task isn't eligible for whichever rule covers its slot,
    /// exactly what a deliberately-ineligible manual placement looks
    /// like. Every such sweep must check this flag — see
    /// `ScheduleReviewViewModel.trimOverflowingRuleBlocks`,
    /// `.clearIncompletePastBlocks`, and the locked/completed carry-over
    /// check inside `performAutoPlaceEligibleTasks`'s own day walk for
    /// the three that currently do. Deliberately not reused for an
    /// eligible manual placement's own protection — one was never at risk
    /// from these sweeps in the first place, so this only ever matters
    /// for the ineligible case, but is set unconditionally by both
    /// placement paths rather than threading an extra "was this
    /// eligible" bit through them just to skip setting it in the case
    /// where it wouldn't have mattered anyway.
    var manuallyPlaced: Bool = false

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
