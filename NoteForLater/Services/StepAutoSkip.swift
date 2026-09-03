import Foundation

/// Generic forward-or-backward "walk past empty steps" algorithm, pulled
/// out of `NightlyReviewView.advance()`/`back()` so the actual
/// eligibility/skip *sequencing* is unit-testable without a live
/// `NightlyReviewView` (SwiftData store, staged toggle state, sheets, and
/// so on). The view supplies its real `Step` type and closures; tests use
/// their own minimal stand-in step type — this knows nothing about
/// Nightly Review specifically.
enum StepAutoSkip {
    /// Walks forward from `start`, calling `onEnter` for **every** step it
    /// passes through — including one it goes on to skip. That ordering is
    /// load-bearing: `NightlyReviewView.advance()` hangs real work (staged
    /// toggle commits, starting the Inbox review session, the recurring-
    /// occurrence push) off "entering" a step, and none of that may be
    /// silently dropped just because the step itself turns out to have
    /// nothing to show. `onEnter` always runs *before* `isEmpty` is
    /// consulted for that same step, so a step whose contents are computed
    /// as part of entering it (`.twoMinuteTasks`, `.inbox`) is judged by
    /// its just-computed state, never a stale one.
    ///
    /// Continues past a step only when `isEligible(step) && isEmpty(step)`
    /// both hold once `onEnter` has run; stops the moment either is false,
    /// or after `maxSteps` iterations — a defensive cap (normal operation
    /// never approaches it) so a future miscount in `next`/`isEligible`
    /// can never spin this past the real step list.
    static func walkForward<Step: Hashable>(
        from start: Step,
        next: (Step) -> Step,
        isEligible: (Step) -> Bool,
        isEmpty: (Step) -> Bool,
        onEnter: (Step) -> Void,
        maxSteps: Int
    ) -> (landed: Step, skipped: [Step]) {
        var candidate = start
        var skipped: [Step] = []
        var iterations = 0
        while iterations < maxSteps {
            iterations += 1
            onEnter(candidate)
            guard isEligible(candidate), isEmpty(candidate) else { break }
            skipped.append(candidate)
            candidate = next(candidate)
        }
        return (candidate, skipped)
    }
}
