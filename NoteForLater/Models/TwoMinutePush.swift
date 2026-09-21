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
        calendar: Calendar = .current,
        context: ModelContext
    ) -> OccurrenceStatus {
        let next = task.cycleCompletion(in: context)
        if next == .missed {
            apply(to: task, planDate: planDate, calendar: calendar)
        } else {
            undo(for: task)
        }
        return next
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
    static func apply(to task: TaskItem, planDate: Date, calendar: Calendar = .current) {
        if !task.hasOutstandingTwoMinutePush {
            task.startDateBeforePush = task.startDate
            task.startDatePickedBeforePush = task.startDatePicked
            task.hasOutstandingTwoMinutePush = true
        }
        task.setStartDate(calendar.startOfDay(for: planDate), calendar: calendar)
    }

    /// Restores whatever the task had before it was pushed — including
    /// having had nothing, which clears rather than leaving the pushed date
    /// stranded. Changing your mind has to leave no trace.
    ///
    /// A no-op when no push is outstanding, so it is safe to call on every
    /// non-missed transition without the caller checking first.
    static func undo(for task: TaskItem) {
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
