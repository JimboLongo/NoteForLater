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
    /// See `TaskItem.legacyIsCompleted`'s doc comment — identical
    /// reasoning and mechanism, applied here so a historically-completed
    /// block doesn't silently read back as never-completed once
    /// `statusRaw` takes over. Read once by `NoteForLaterApp
    /// .migrateIncompleteBlocksAndMealsToThreeStateIfNeeded`.
    @Attribute(originalName: "isCompleted")
    var legacyIsCompleted: Bool = false
    /// See `TaskItem.hasMigratedThreeState`'s doc comment — identical
    /// reasoning and mechanism, applied here so a second migration
    /// invocation skips an already-migrated block instead of
    /// re-deriving (and potentially reclassifying) its `status`.
    var hasMigratedThreeState: Bool = false
    /// Backing storage for `status` — see `OccurrenceStatus`'s own doc
    /// comment. Defaults to `.none`'s raw value so a pre-migration row
    /// (no `statusRaw` column at all yet) reads as untouched until
    /// `migrateIncompleteBlocksAndMealsToThreeStateIfNeeded` seeds it from
    /// `legacyIsCompleted` — matching the old `isCompleted: Bool`'s own
    /// default of `false` in the meantime.
    var statusRaw: String = OccurrenceStatus.none.rawValue
    /// This block's three-state completion. For a habit- or recurring-
    /// task-backed block, this stays exactly what it's always been — a
    /// *mirror* of `HabitLog`/`RecurringTaskLog`, never the source of
    /// truth (see `TaskItem.cycleRecurringOccurrence`'s own doc comment).
    /// For an ordinary task block or a meal block, this now *is* the
    /// source of truth — `.missed` is real and meaningful here in a way
    /// a plain `Bool` never could express. Never writes `.excused` — see
    /// `OccurrenceStatus.cycledExcludingExcused`.
    var status: OccurrenceStatus {
        get { OccurrenceStatus(rawValue: statusRaw) ?? .none }
        set { statusRaw = newValue.rawValue }
    }
    /// `statusRaw` is the only real storage — this and `status` are both
    /// just views onto it, so there's nothing to keep in sync and
    /// nothing that can drift out of sync. Stays fully settable so every
    /// existing call site (`block.isCompleted.toggle()`,
    /// `block.isCompleted = false`, the general scheduling/ripple
    /// machinery's `!$0.isCompleted` reads, ...) keeps compiling and
    /// working unchanged — none of them need to know a third state
    /// exists, and "not complete" is exactly what they already meant by
    /// `!isCompleted` (`.missed` reads as not-complete here too).
    ///
    /// The one deliberate, load-bearing consequence: **setting `false`
    /// always lands on `.none`, never preserves `.missed`.** See
    /// `TaskItem.isCompleted`'s own doc comment for the full reasoning —
    /// identical here.
    var isCompleted: Bool {
        get { status == .complete }
        set { status = newValue ? .complete : .none }
    }
    /// Set the first (and only ever) time this block's own task gets a
    /// fresh placement guaranteed for it because *this* block landed on
    /// `.missed` (`ScheduleReviewViewModel.cycleBlockCompletion`/
    /// `.resolveMissedPastBlocks`). Deliberately its own flag rather than
    /// inferring "already handled" from `task.isScheduled`: that reads
    /// `true` for this exact block's own original (now-missed) placement
    /// too, until something explicitly frees it — checking it instead
    /// would either never trigger a replacement at all (the task already
    /// reads as scheduled, from the very placement that just got marked
    /// missed) or double-trigger one (re-cycling the same stale block
    /// Missed → None → Missed again within a session, after the first
    /// replacement already set `isScheduled` back to `true` on its own).
    /// This block is never deleted (see the three-state redesign's own
    /// reversal), so there's no later moment this needs to be reset —
    /// once true, this specific missed instance is permanently resolved.
    var hasGuaranteedReplacement: Bool = false
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
