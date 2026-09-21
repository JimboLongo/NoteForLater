import Foundation
import SwiftData

/// Marking a 2-minute task **missed** in the Nightly Review pushes it one
/// day: off tonight's list, back on tomorrow's.
///
/// **What "one day" can mean here, given these tasks have no block and no
/// date of their own.** They surface in exactly two places, and both already
/// filter on `TaskItem.isEligibleToStart`:
/// - the Nightly Review step (`!isCompleted && isEligibleToStart(on: reviewDate)`)
/// - the day screen's checklist (`DayTimelineGridView.twoMinuteTasksSection`)
///
/// So setting `startDate` to tomorrow hides it from both today and returns
/// it tomorrow, with no new field and no migration. `PushedRecurringOccurrence`
/// is the wrong tool — it is recurrence-specific machinery keyed to an
/// occurrence date these tasks don't have.
///
/// **Worth being precise about what the push actually buys.** An unanswered
/// task reappears tomorrow anyway: the filter is `!isCompleted && eligible`,
/// and neither changes by doing nothing. What the push does is take it off
/// *tonight's* list — which matters because the step's timer counts
/// unresolved work, and because "missed" should mean a decision was made
/// rather than a row left alone.
///
/// `startDatePicked` is set too, so the card shows "Can Start By" for the
/// day it moved to.
/// That is deliberate: a `startDate` the card doesn't display is exactly the
/// kind of invisible state that has bitten this codebase before. Visible and
/// slightly surprising beats correct and invisible.
enum TwoMinutePush {

    /// **The one entry point both surfaces call** — Nightly Review's
    /// 2-Minute step and the day calendar's checklist.
    ///
    /// Cycles the task and reconciles its push in the same call: landing on
    /// `.missed` moves it to `planDate`, leaving `.missed` puts back
    /// whatever was there before.
    ///
    /// **Shared before the second surface exists, deliberately.** The
    /// recurring push had `if next == .missed { push }` written
    /// independently in two views, and only one grew the matching `else` —
    /// cycling back to incomplete on the calendar left the push in place
    /// while the identical gesture in Nightly Review undid it. Building one
    /// owner first is what stops that recurring here: there is no `else` for
    /// a caller to forget.
    ///
    /// The cycle is `.none → .complete → .missed → .none`
    /// (`OccurrenceStatus.cycledExcludingExcused`), so `.missed` can be left
    /// in either direction and both undo.
    @discardableResult
    static func cycle(
        _ task: TaskItem,
        planDate: Date,
        missedOn missedDay: Date,
        calendar: Calendar = .current,
        context: ModelContext
    ) -> OccurrenceStatus {
        let next = task.cycleCompletion(in: context)
        if next == .missed {
            apply(to: task, planDate: planDate, missedOn: missedDay, calendar: calendar, context: context)
        } else {
            clearPushBookkeeping(task)
        }
        return next
    }

    /// Drops the undo capture without touching the record or the start date.
    ///
    /// **Completing is not undoing**, and this is where that distinction
    /// lives now. Cycling a pushed task to `.complete` on the day it landed
    /// means you did it — the miss on the original day still happened, so
    /// the record stays and `startDate` stays. All that is no longer needed
    /// is the captured prior state, because there is nothing left to
    /// reverse.
    ///
    /// Without this the capture would go stale: a task completed after a
    /// push, then later cycled to missed again, would skip re-capturing
    /// (`apply` only captures when no push is outstanding) and restore a
    /// start date from two pushes ago.
    private static func clearPushBookkeeping(_ task: TaskItem) {
        task.hasOutstandingTwoMinutePush = false
        task.startDateBeforePush = nil
        task.startDatePickedBeforePush = false
    }

    /// Completes the task a miss record stands for — Nightly Review's "one
    /// last chance to actually do it".
    ///
    /// **Completes the task rather than dismissing the record.** Dismissing
    /// would be a second, weaker "ignore" alongside the existing cycle, and
    /// the point of showing a miss in the review is that it can still be
    /// done.
    ///
    /// **The record survives**, deliberately. It says "on this day, it was
    /// missed", which stays true — you did miss it Monday and do it Tuesday.
    /// Same semantics as `TaskCompletionRecord`: history is not rewritten by
    /// what happened later. The calendar keeps showing it; Nightly Review
    /// stops offering it, because a completed task is no longer owed.
    ///
    /// **`startDate` is deliberately left alone.** Completion already
    /// removes the task from every "what is owed" filter (`!isCompleted`),
    /// so the pushed instance stops being pending without a second
    /// mechanism. Restoring the start date as well would drag the
    /// now-completed task back to the original day, putting *two* rows for
    /// one task on it — the record and the completed task.
    static func completeFromRecord(_ record: TaskMissRecord, task: TaskItem, context: ModelContext) {
        task.setCompleted(true, in: context)
        task.hasOutstandingTwoMinutePush = false
        task.startDateBeforePush = nil
        task.startDatePickedBeforePush = false
    }

    /// Moves the task to **the day being planned**, not mechanically to the
    /// day after the miss.
    ///
    /// REVERSAL: this used to compute `reviewDate + 1` itself. Catching up
    /// several days late then meant a miss landed the day after the day it
    /// was missed — still in the past, and invisible. The caller now passes
    /// the day it is actually planning, so the task lands where the screen
    /// says it will.
    ///
    /// Captures the prior state only on the *first* push, so a task cycled
    /// round the loop twice restores its original date rather than the
    /// pushed one.
    static func apply(
        to task: TaskItem,
        planDate: Date,
        missedOn missedDay: Date,
        calendar: Calendar = .current,
        context: ModelContext
    ) {
        if !task.hasOutstandingTwoMinutePush {
            task.startDateBeforePush = task.startDate
            task.startDatePickedBeforePush = task.startDatePicked
            task.hasOutstandingTwoMinutePush = true
        }
        task.setStartDate(calendar.startOfDay(for: planDate), calendar: calendar)
        // **Back to `.none`.** The miss is carried by the record on the
        // original day now; the task's own status describes the row on the
        // *pushed* day, which is work still to do. Leaving it `.missed`
        // would draw both days as missed.
        //
        // A consequence worth stating: `.missed` is no longer a resting
        // state for a 2-Minute task. It exists for the duration of this one
        // call and is immediately converted into a record plus a move. The
        // visible cycle on a live row is therefore
        // `.none → .complete → (pushed away)`, and the third state lives on
        // the other day as history rather than on this row.
        task.status = .none
        // The half that stays behind — see `TaskMissRecord`. At most one
        // outstanding record per task: cycling missed twice without an
        // intervening undo keeps the first, so the record names the day the
        // miss actually happened rather than the last day it was re-tapped.
        guard TaskMissRecord.record(for: task, in: context) == nil else { return }
        context.insert(TaskMissRecord(
            taskID: task.id,
            title: task.title,
            missedDay: missedDay,
            pushedToDay: planDate,
            calendar: calendar
        ))
    }

    /// Restores whatever the task had before it was pushed — including
    /// having had nothing, which clears rather than leaving the pushed date
    /// stranded. Changing your mind has to leave no trace.
    ///
    /// **An explicit action now, not a status transition.** It used to fire
    /// whenever a cycle left `.missed`. Once a push resets the task to
    /// `.none` (see `apply`), that transition can never happen again — and
    /// more importantly it could no longer tell "I completed it" from "I
    /// changed my mind", since both arrive at a non-missed status. The only
    /// caller is the miss row's own tap on the calendar, which is
    /// unambiguous: that row *is* the push, and tapping it puts it back.
    ///
    /// A no-op when no push is outstanding, so a caller need not check.
    static func undo(for task: TaskItem, context: ModelContext) {
        // The record goes with the push, always — even if the bookkeeping
        // below has already been cleared by something else, an undo must not
        // leave a miss row standing for a push that no longer exists.
        if let record = TaskMissRecord.record(for: task, in: context) {
            context.delete(record)
        }
        guard task.hasOutstandingTwoMinutePush else { return }
        if let prior = task.startDateBeforePush {
            task.setStartDate(prior)
            task.startDatePicked = task.startDatePickedBeforePush
        } else {
            task.clearStartDate()
        }
        task.hasOutstandingTwoMinutePush = false
        task.startDateBeforePush = nil
        task.startDatePickedBeforePush = false
    }

    /// Clears a pushed start date that has already come and gone.
    ///
    /// Run on entering the step. Without it a task missed on Monday still
    /// reads "Can Start By: Tuesday" on Wednesday — inert (a past start date
    /// never hides anything) but clutter on the card.
    ///
    /// **Gated on `hasOutstandingTwoMinutePush`**, because `startDate` is
    /// the user's own "Can Start By" field and clearing every past one would
    /// destroy real input.
    ///
    /// REVERSAL: this used to gate on `status == .missed`, inferring "we set
    /// this" from the only state that could reach the push. Its own comment
    /// recorded the hole that left — marking the task complete and then
    /// not-complete collapses `.missed` to `.none` (a bare
    /// `isCompleted = false` cannot express three states), so the date lost
    /// its marker and lingered — and judged it "not worth a stored field to
    /// close." The field now exists for the undo, so the hole closes for
    /// free rather than on its own merits.
    ///
    /// Clears the undo state too: once the pushed day has passed there is
    /// nothing left to reverse, and a stale capture would otherwise restore
    /// a long-dead prior date if the task were cycled again.
    static func clearExpiredPushes(on tasks: [TaskItem], asOf date: Date, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: date)
        for task in tasks where task.hasOutstandingTwoMinutePush {
            guard let startDate = task.startDate, calendar.startOfDay(for: startDate) < today else { continue }
            task.clearStartDate()
            task.hasOutstandingTwoMinutePush = false
            task.startDateBeforePush = nil
            task.startDatePickedBeforePush = false
        }
    }
}
