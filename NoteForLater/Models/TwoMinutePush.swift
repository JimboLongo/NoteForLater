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
/// `startDatePicked` is set too, so the card shows "Can Start By: tomorrow".
/// That is deliberate: a `startDate` the card doesn't display is exactly the
/// kind of invisible state that has bitten this codebase before. Visible and
/// slightly surprising beats correct and invisible.
struct TwoMinutePushState {
    /// Prior `startDate` per pushed task — the *presence* of a key means
    /// "we pushed this one", and the value (which may be `nil`) is what to
    /// put back. `[UUID: Date?]` rather than two collections so those two
    /// facts can't disagree.
    private var priorStartDates: [UUID: Date?] = [:]

    var isEmpty: Bool { priorStartDates.isEmpty }

    /// Cycles the task and applies or undoes the push, whichever the new
    /// status calls for.
    ///
    /// The cycle is `.none → .complete → .missed → .none`
    /// (`OccurrenceStatus.cycledExcludingExcused`), so a single tap can
    /// leave `.missed` in either direction — this handles both rather than
    /// only the forward one.
    @discardableResult
    mutating func cycle(_ task: TaskItem, reviewDate: Date, calendar: Calendar = .current, context: ModelContext) -> OccurrenceStatus {
        let next = task.cycleCompletion(in: context)
        if next == .missed {
            apply(to: task, reviewDate: reviewDate, calendar: calendar)
        } else {
            undo(for: task)
        }
        return next
    }

    /// Pushes to the day after `reviewDate` — not after `.now`. The review
    /// can be run for yesterday (Choose Day's "Plan Today"), and a task
    /// missed in *that* review belongs on the day after the one being
    /// reviewed, not on the day after whenever the user happens to be
    /// sitting there.
    private mutating func apply(to task: TaskItem, reviewDate: Date, calendar: Calendar) {
        // Only capture on the first push — a task cycled round the loop
        // twice must restore its *original* date, not the pushed one.
        if priorStartDates.index(forKey: task.id) == nil {
            priorStartDates[task.id] = task.startDate
        }
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: reviewDate)) else { return }
        task.setStartDate(tomorrow, calendar: calendar)
    }

    /// Restores whatever the task had before it was pushed — including
    /// having had nothing, which clears rather than leaving the pushed date
    /// stranded. Changing your mind has to leave no trace.
    private mutating func undo(for task: TaskItem) {
        guard let prior = priorStartDates.removeValue(forKey: task.id) else { return }
        if let prior {
            task.setStartDate(prior)
        } else {
            task.clearStartDate()
        }
    }

    /// Clears a pushed start date that has already come and gone.
    ///
    /// Run on entering the step. Without it a task missed on Monday still
    /// reads "Can Start By: Tuesday" on Wednesday — inert (a past start date
    /// never hides anything) but clutter on the card.
    ///
    /// **Gated on `.missed` as well as the date being past**, because
    /// `startDate` is the user's own "Can Start By" field and clearing every
    /// past one would destroy real input. `.missed` is only reachable from
    /// three-state-aware code, and for a 2-minute task that means this step
    /// — so it is a usable marker for "we set this" without a new field.
    ///
    /// ⚠️ Its one hole, accepted as cosmetic: marking the task complete and
    /// then not-complete collapses `.missed` to `.none` (a bare
    /// `isCompleted = false` cannot express three states — see
    /// `TaskItem.isCompleted`), so the date loses its marker and lingers.
    /// Narrow, harmless, and not worth a stored field to close.
    static func clearExpiredPushes(on tasks: [TaskItem], asOf date: Date, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: date)
        for task in tasks where task.status == .missed {
            guard let startDate = task.startDate, calendar.startOfDay(for: startDate) < today else { continue }
            task.clearStartDate()
        }
    }
}
