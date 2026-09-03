import XCTest
@testable import NoteForLater

/// Coverage for `StepAutoSkip.walkForward` — the generalized "skip empty
/// Nightly Review steps" algorithm `NightlyReviewView.advance()`/`back()`
/// both call — plus a direct check of the real `NightlyReviewView.Step
/// .autoSkipEligible` set, which is what actually keeps `.today`/
/// `.tomorrow`/`.chooseDay` from ever being auto-skipped.
///
/// `NightlyReviewView` itself isn't unit-testable here: its `@Query`
/// properties need a live SwiftUI environment, and `advance()`/`back()`
/// are `private`. `StepAutoSkip.walkForward` is the actual shared
/// sequencing logic (both call sites use it verbatim), and
/// `NightlyReviewView.Step` was loosened from `private` to internal
/// specifically so its real `autoSkipEligible` set could be exercised
/// directly rather than only through a stand-in — see that type's own
/// doc comment.
final class NightlyReviewAutoSkipTests: XCTestCase {
    /// A minimal 5-step stand-in — mirrors the shape of
    /// `NightlyReviewView.Step` (an `Int`-backed, `CaseIterable` sequence)
    /// without depending on it, so these tests exercise `StepAutoSkip`
    /// itself, not any particular concrete step list.
    private enum MockStep: Int, CaseIterable, Hashable {
        case s0, s1, s2, s3, s4
    }

    private func mockNext(_ step: MockStep) -> MockStep {
        MockStep(rawValue: step.rawValue + 1) ?? .s4
    }

    // MARK: - Two adjacent empty steps skipped in one call

    /// s1 and s2 are both eligible-and-empty, back to back; s3 is
    /// eligible but not empty. A single `walkForward` call starting at s1
    /// must skip *both* s1 and s2, landing on s3 — not stop after the
    /// first one the way the old single-`if` code did (see
    /// `advance()`'s doc comment for the concrete pre-fix shape: `next =
    /// Step(rawValue: next.rawValue + 1)`, exactly one hop, no loop).
    ///
    /// Verified fail-then-pass, not just asserted: with `walkForward`'s
    /// loop temporarily changed to `break` right after appending the
    /// first skip (reproducing that exact one-hop-only shape), this test
    /// failed — `landed` came back `s2`, `skipped` came back `[s1]`.
    /// Restoring the real loop and rerunning flipped it green. Both runs
    /// via `xcodebuild test`.
    func test_walkForward_skipsTwoAdjacentEmptySteps() {
        let isEligible: (MockStep) -> Bool = { [.s1, .s2, .s3].contains($0) }
        let isEmpty: (MockStep) -> Bool = { $0 == .s1 || $0 == .s2 }

        let result = StepAutoSkip.walkForward(
            from: .s1,
            next: mockNext,
            isEligible: isEligible,
            isEmpty: isEmpty,
            onEnter: { _ in },
            maxSteps: MockStep.allCases.count
        )

        XCTAssertEqual(result.landed, .s3)
        XCTAssertEqual(result.skipped, [.s1, .s2])
    }

    // MARK: - A skipped step's entry side effects still run

    /// Same eligible-and-empty s1/s2, not-empty s3 shape as above.
    /// `onEnter` must fire for every step the walk actually passes
    /// through — s1 and s2 (both skipped) *and* s3 (where it lands) — in
    /// that order. This is the property that matters for
    /// `NightlyReviewView`: `runEntryEffects(for:)` is what `onEnter`
    /// really is there, and it's what commits staged toggles, starts the
    /// Inbox review session, and runs the recurring-occurrence push —
    /// none of that may be silently dropped just because a step ends up
    /// skipped.
    ///
    /// Verified fail-then-pass: with the real `onEnter(candidate)` call
    /// moved out of the loop to fire exactly once, after the loop, on
    /// only the final `candidate` (reproducing "jump straight to the
    /// destination, drop the intermediate entry work" — requirement 2's
    /// named risk), this test failed: `entered` came back `[.s3]` instead
    /// of `[.s1, .s2, .s3]`. Restored and rerun: green. Both via
    /// `xcodebuild test`.
    func test_walkForward_runsOnEnterForEverySkippedStep() {
        let isEligible: (MockStep) -> Bool = { [.s1, .s2, .s3].contains($0) }
        let isEmpty: (MockStep) -> Bool = { $0 == .s1 || $0 == .s2 }
        var entered: [MockStep] = []

        let result = StepAutoSkip.walkForward(
            from: .s1,
            next: mockNext,
            isEligible: isEligible,
            isEmpty: isEmpty,
            onEnter: { entered.append($0) },
            maxSteps: MockStep.allCases.count
        )

        XCTAssertEqual(entered, [.s1, .s2, .s3])
        XCTAssertEqual(result.landed, .s3)
    }

    // MARK: - The cap can never run past the end of the step list

    /// Every step reports empty and eligible — an adversarial input that
    /// would spin forever without `maxSteps`. Must stop exactly at the
    /// cap, landing on the last step it reached, not loop indefinitely or
    /// walk off the end of `next`'s range.
    func test_walkForward_capsAtMaxSteps() {
        let result = StepAutoSkip.walkForward(
            from: .s0,
            next: mockNext,
            isEligible: { _ in true },
            isEmpty: { _ in true },
            onEnter: { _ in },
            maxSteps: MockStep.allCases.count
        )
        XCTAssertEqual(result.skipped.count, MockStep.allCases.count)
    }

    // MARK: - .today / .tomorrow never auto-skip, even when reported empty

    /// Uses the *real* `NightlyReviewView.Step` and its real
    /// `autoSkipEligible` set — only `isEmpty` is faked (returns `true`
    /// unconditionally, an adversarial "everything looks empty" input).
    /// Starting at `.twoMinuteTasks`, the walk should skip
    /// `.twoMinuteTasks` (eligible + reported empty) and then stop dead
    /// at `.today`, because `.today` is not a member of
    /// `autoSkipEligible` — regardless of what `isEmpty` claims about it.
    func test_realStep_todayNeverAutoSkippedEvenWhenReportedEmpty() {
        let result = StepAutoSkip.walkForward(
            from: NightlyReviewView.Step.twoMinuteTasks,
            next: { NightlyReviewView.Step(rawValue: $0.rawValue + 1) ?? .tomorrow },
            isEligible: { NightlyReviewView.Step.autoSkipEligible.contains($0) },
            isEmpty: { _ in true },
            onEnter: { _ in },
            maxSteps: NightlyReviewView.Step.allCases.count
        )

        XCTAssertEqual(result.landed, .today)
        XCTAssertEqual(result.skipped, [.twoMinuteTasks])
    }

    /// Same shape, starting at `.inbox` so every remaining eligible step
    /// (`.inbox`, `.atRisk`, `.meals`) reports empty and gets skipped —
    /// the walk must still stop dead at `.tomorrow`, never past it,
    /// because `.tomorrow` is likewise excluded from `autoSkipEligible`.
    func test_realStep_tomorrowNeverAutoSkippedEvenWhenReportedEmpty() {
        let result = StepAutoSkip.walkForward(
            from: NightlyReviewView.Step.inbox,
            next: { NightlyReviewView.Step(rawValue: $0.rawValue + 1) ?? .tomorrow },
            isEligible: { NightlyReviewView.Step.autoSkipEligible.contains($0) },
            isEmpty: { _ in true },
            onEnter: { _ in },
            maxSteps: NightlyReviewView.Step.allCases.count
        )

        XCTAssertEqual(result.landed, .tomorrow)
        XCTAssertEqual(result.skipped, [.inbox, .atRisk, .meals])
    }

    /// `.chooseDay` is never reached as a forward "next" candidate in
    /// practice (advance() always starts from `step.rawValue + 1`, and
    /// `.chooseDay` is rawValue 0), but `back()` floors there — confirm it
    /// isn't eligible either, so a backward walk can't skip past it.
    func test_realStep_chooseDayNotEligible() {
        XCTAssertFalse(NightlyReviewView.Step.autoSkipEligible.contains(.chooseDay))
    }
}
