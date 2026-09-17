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

    /// One forward step: **the departing step's exit effects, then the
    /// walk.** Ordering is the whole point — the exit effects have to see
    /// the step being left, before anything moves.
    ///
    /// Extracted from `NightlyReviewView.advance()` because the call to
    /// `runExitEffects` was invisible to every test. Deleting that single
    /// line — so the Nightly Review's whole commit batch never fired, and
    /// nothing got closed out — was caught by **nothing** (verified by
    /// sabotage: 0 failures out of 567). The batch itself had already been
    /// extracted and characterized; this is the wiring that *invokes* it,
    /// which is the same rule-asserted / consumer-unasserted split that let
    /// `CardRow`'s hidden rows keep rendering.
    ///
    /// `advance` rather than a returned plan, deliberately: a value
    /// describing what *should* happen can't express that the exit effects
    /// ran first. Performing the sequence here lets a test pass recording
    /// closures and assert the order itself.
    static func advance<Step: Hashable>(
        from current: Step,
        next: (Step) -> Step,
        isEligible: (Step) -> Bool,
        isEmpty: (Step) -> Bool,
        onExit: (Step) -> Void,
        onEnter: (Step) -> Void,
        maxSteps: Int
    ) -> (landed: Step, skipped: [Step]) {
        onExit(current)
        return walkForward(
            from: next(current),
            next: next,
            isEligible: isEligible,
            isEmpty: isEmpty,
            onEnter: onEnter,
            maxSteps: maxSteps
        )
    }
}
