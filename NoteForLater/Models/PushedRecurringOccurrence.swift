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

extension PushedRecurringOccurrence {
    /// True once a real, already-complete representation exists for
    /// `occurrence.currentDate` — a Specific Time block someone checked
    /// off on the calendar, or (AM/Midday/PM) a completed
    /// `RecurringTaskLog` for that day. Checked *before* trying to push
    /// further, so completing the pushed instance through its normal,
    /// already-existing "mark complete" UI is all it takes to resolve the
    /// chain — nothing else needs to know a push was ever in progress.
    static func isAlreadyResolved(_ occurrence: PushedRecurringOccurrence, task: TaskItem, calendar: Calendar, context: ModelContext) -> Bool {
        if task.recurrenceTimeMode == .specific {
            return (task.scheduledBlocks ?? []).contains {
                calendar.isDate($0.date, inSameDayAs: occurrence.currentDate) && $0.isCompleted
            }
        }
        return RecurringTaskLog.log(taskID: task.id, on: occurrence.currentDate, context: context, calendar: calendar)?.isCompleted ?? false
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
    /// preventing a duplicate once a Specific Time block is later inserted
    /// for that same day. Otherwise relocates the Specific Time placeholder
    /// block (a no-op for AM/Midday/PM — see `relocatePlaceholderBlock`)
    /// and advances `occurrence.currentDate`. Returns whether the
    /// occurrence was resolved, so a calling loop knows to stop.
    @discardableResult
    static func advanceOneHop(_ occurrence: PushedRecurringOccurrence, task: TaskItem, from cursor: Date, to next: Date, calendar: Calendar, context: ModelContext) -> Bool {
        if task.hasRecurringOccurrence(on: next, calendar: calendar) {
            removePlaceholderBlock(for: task, on: cursor, calendar: calendar, context: context)
            context.delete(occurrence)
            return true
        }
        relocatePlaceholderBlock(for: task, from: cursor, to: next, calendar: calendar, context: context)
        occurrence.currentDate = next
        return false
    }

    /// Moves the Specific Time placeholder `ScheduledBlock` for a pushed
    /// occurrence from `oldDate` to `newDate` — or creates it fresh at
    /// `newDate` if none exists yet, which is exactly the case on the very
    /// first push (`clearIncompletePastBlocks` already deleted the
    /// original incomplete block before this ever runs). Either way there
    /// is only ever one block tracking the chain, never one left behind
    /// at every day it passed through. No-op for AM/Midday/PM tasks —
    /// those have no `ScheduledBlock` at all; `DayTimelineGridView` reads
    /// `PushedRecurringOccurrence.currentDate` directly instead.
    ///
    /// Routed through `RippleSchedulingService` (fresh at depth 0 for
    /// each hop — a multi-day catch-up walk is a series of independent
    /// placements, not one long recursion chain) rather than just
    /// setting the date/time directly, so a recurring task's push gets
    /// the same lock-respecting, bump-don't-overflow treatment an
    /// ordinary task's does (see `ScheduleReviewViewModel
    /// .guaranteePlacement`) instead of silently landing on top of
    /// whatever else is already on `newDate`.
    private static func relocatePlaceholderBlock(for task: TaskItem, from oldDate: Date, to newDate: Date, calendar: Calendar, context: ModelContext) {
        guard task.recurrenceTimeMode == .specific else { return }
        guard let start = task.recurringOccurrenceTime(on: newDate, calendar: calendar) else { return }
        let minutes = task.estimatedMinutes > 0 ? task.estimatedMinutes : 30
        let end = start.addingTimeInterval(TimeInterval(minutes * 60))
        let block: ScheduledBlock
        if let existing = (task.scheduledBlocks ?? []).first(where: { calendar.isDate($0.date, inSameDayAs: oldDate) }) {
            existing.date = calendar.startOfDay(for: newDate)
            existing.startTime = start
            existing.endTime = end
            block = existing
        } else {
            block = ScheduledBlock(date: newDate, startTime: start, endTime: end, task: task, isEstimatedDuration: task.estimatedMinutes <= 0)
            context.insert(block)
        }
        RippleSchedulingService.insertWithRipple(block, context: context)
    }

    /// Deletes the Specific Time placeholder block left at `date` once the
    /// chain resolves onto a real recurrence day — the genuine occurrence
    /// for that day is created separately by `AISchedulingService
    /// .placeHabitsAndRecurringTasks`, so the placeholder must go rather
    /// than sit there as a duplicate.
    private static func removePlaceholderBlock(for task: TaskItem, on date: Date, calendar: Calendar, context: ModelContext) {
        guard task.recurrenceTimeMode == .specific else { return }
        if let existing = (task.scheduledBlocks ?? []).first(where: { calendar.isDate($0.date, inSameDayAs: date) }) {
            context.delete(existing)
        }
    }
}
