import XCTest
@testable import NoteForLater

/// Coverage for the Nightly Review Inbox step's 2-minute minimum-engagement
/// floor: `InboxEngagementTimer` (the countdown itself) and
/// `AttributeReviewSession.nextWrapQueue`/`queueCandidates` (the
/// wrap-around decision `TaskReviewQueueSheet.advance()` defers to).
///
/// `TaskReviewQueueSheet`/`NightlyReviewView` themselves aren't
/// unit-testable here — `advance()` is `private`, and both need a live
/// SwiftUI environment — so these tests exercise the pulled-out, pure
/// logic those views call, same as `RecurringTaskReviewTests` and
/// `NightlyReviewAutoSkipTests` already do for their own features.
///
/// Every test that touches `InboxEngagementTimer` (a class, therefore
/// implicitly `@MainActor`-isolated under this project's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` setting) is `async`, per
/// `SchedulingEngineTests`'s own documented reason: XCTest's synchronous
/// path supplies no enclosing `Task`, which trips a Swift runtime bug in
/// isolated-deinit teardown on release. See that file's `§8` section
/// comment for the full writeup — not re-derived here.
final class InboxEngagementTests: XCTestCase {
    private func makeTask(title: String, shelf: Shelf? = nil) -> TaskItem {
        TaskItem(title: title, shelf: shelf, estimatedMinutes: 15)
    }

    // MARK: - InboxEngagementTimer itself

    func test_timer_startsUnexpired_ticksDownToExpired_andClampsAtZero() async {
        let timer = InboxEngagementTimer()
        XCTAssertEqual(timer.remaining, InboxEngagementTimer.initialDuration)
        XCTAssertFalse(timer.isExpired)

        timer.tick(by: InboxEngagementTimer.initialDuration - 1)
        XCTAssertFalse(timer.isExpired, "one second left is still not expired")

        timer.tick(by: 1)
        XCTAssertTrue(timer.isExpired)
        XCTAssertEqual(timer.remaining, 0)

        // Ticking past zero must clamp, not go negative — the toolbar
        // label formats this directly.
        timer.tick(by: 10)
        XCTAssertEqual(timer.remaining, 0)
    }

    /// Directly exercises the same expression the "Skip Remaining"
    /// button's `.disabled` modifier reads (`!engagementTimer.isExpired`)
    /// — gated (disabled) with time left, ungated the instant it hits
    /// zero.
    func test_timer_gatesSkipRemaining_untilExpiry() async {
        let timer = InboxEngagementTimer(remaining: 5)
        XCTAssertTrue(!timer.isExpired, "Skip Remaining must still be disabled with 5 seconds left")
        timer.tick(by: 5)
        XCTAssertTrue(timer.isExpired, "Skip Remaining must be enabled the instant the floor is reached")
    }

    // MARK: - AttributeReviewSession.nextWrapQueue — the wrap-around decision

    /// Two still-unresolved items, plenty of time left: both must come
    /// back for another pass, not just the one the sheet happened to
    /// finish on.
    ///
    /// Verified fail-then-pass: with `nextWrapQueue` temporarily changed
    /// to `return nil` unconditionally (reproducing "reaching the end of
    /// the queue always finishes," the exact pre-fix behavior this
    /// requirement replaces), this test failed — `result` came back
    /// `nil` instead of both tasks. Restored and rerun: green. Both via
    /// `xcodebuild test`.
    func test_nextWrapQueue_wrapsUnresolvedItems_whileTimeRemains() async {
        let taskA = makeTask(title: "A") // no shelf — unsorted, still unresolved
        let taskB = makeTask(title: "B")
        let timer = InboxEngagementTimer(remaining: 90)

        let result = AttributeReviewSession.nextWrapQueue(initialQueue: [taskA, taskB], engagementTimer: timer)

        XCTAssertEqual(result?.count, 2)
        XCTAssertEqual(Set(result?.map(\.id) ?? []), Set([taskA.id, taskB.id]))
    }

    /// Same starting pair, but `taskA` got a shelf assigned since the
    /// session began (exactly what picking "Move" on its card does) —
    /// re-evaluated live via `queueCandidates`, it no longer qualifies, so
    /// it must not come back around. No separately-tracked skip-set to
    /// get out of sync with this.
    func test_nextWrapQueue_excludesItemResolvedSinceSessionStart() async {
        let shelf = Shelf(name: "Errands")
        let taskA = makeTask(title: "A", shelf: shelf) // now has a shelf and isn't missing attributes
        taskA.nextStep = "Call the office"
        taskA.dueDateDecided = true
        taskA.durationDecided = true
        taskA.isDivisibleDecided = true
        taskA.priority = .low
        let taskB = makeTask(title: "B") // still unsorted — still unresolved
        let timer = InboxEngagementTimer(remaining: 90)

        let result = AttributeReviewSession.nextWrapQueue(initialQueue: [taskA, taskB], engagementTimer: timer)

        XCTAssertEqual(result?.map(\.id), [taskB.id], "taskA was fixed since the session started and must not be re-queued")
    }

    /// Timer's already expired — normal end-of-queue behavior returns,
    /// no more wrap-around, even though real work is still unresolved.
    func test_nextWrapQueue_returnsNil_onceTimerExpired() async {
        let taskA = makeTask(title: "A")
        let timer = InboxEngagementTimer(remaining: 0)
        XCTAssertTrue(timer.isExpired)

        let result = AttributeReviewSession.nextWrapQueue(initialQueue: [taskA], engagementTimer: timer)

        XCTAssertNil(result)
    }

    /// The floor is on engagement, not a punishment for finishing early —
    /// once everything's genuinely resolved, proceed immediately
    /// regardless of how much time is left.
    func test_nextWrapQueue_returnsNil_whenEverythingResolved_regardlessOfTimeRemaining() async {
        let shelf = Shelf(name: "Errands")
        let taskA = makeTask(title: "A", shelf: shelf)
        taskA.nextStep = "Call the office"
        taskA.dueDateDecided = true
        taskA.durationDecided = true
        taskA.isDivisibleDecided = true
        taskA.priority = .low
        // Plenty of time left — if this were gated on the timer alone,
        // it would wrongly wrap.
        let timer = InboxEngagementTimer(remaining: 100)

        let result = AttributeReviewSession.nextWrapQueue(initialQueue: [taskA], engagementTimer: timer)

        XCTAssertNil(result)
    }

    // MARK: - Timer resumes rather than resets across a Cancel / "Review Again"

    /// Simulates `NightlyReviewView`'s actual shape: one persistent
    /// `InboxEngagementTimer` handed to a fresh `AttributeReviewSession`
    /// every time `startAttributeReviewSession()` reruns (Cancel, then
    /// "Review Again" rebuilds the queue with a new session `id`). Time
    /// spent before the cancel must still be spent after reopening — not
    /// reset back to the full 2:00.
    ///
    /// Verified fail-then-pass: with `AttributeReviewSession.init`
    /// temporarily changed to ignore its `engagementTimer` parameter and
    /// construct a fresh `InboxEngagementTimer()` internally instead
    /// (reproducing the exact mistake this requirement guards against —
    /// a session rebuild that hands out a brand-new timer rather than
    /// reusing the persistent one), this test failed: `session2`'s
    /// `remaining` came back `120` instead of `75`. Restored the real
    /// pass-through and reran: green. Both via `xcodebuild test`.
    func test_engagementTimer_resumesAcrossSessionRebuild_ratherThanResetting() async {
        let sharedTimer = InboxEngagementTimer()
        let session1 = AttributeReviewSession(queue: [], engagementTimer: sharedTimer)
        XCTAssertEqual(session1.engagementTimer.remaining, 120)

        // Time passes while session1's sheet is open (some of it spent,
        // as if the user reviewed for 45s before tapping Cancel).
        sharedTimer.tick(by: 45)
        XCTAssertEqual(sharedTimer.remaining, 75)

        // "Review Again" — NightlyReviewView rebuilds a fresh session
        // (new `id`, possibly a different queue), but must still hand it
        // the *same* timer instance.
        let session2 = AttributeReviewSession(queue: [], engagementTimer: sharedTimer)

        XCTAssertEqual(session2.engagementTimer.remaining, 75, "must resume with the time already spent, not reset to the full 2:00")
        XCTAssertTrue(session1.engagementTimer === session2.engagementTimer, "both sessions must share the identical timer instance, not independent copies")
    }
}
