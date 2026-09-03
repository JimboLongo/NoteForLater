import Foundation

/// A minimum-engagement countdown for Nightly Review's Inbox step — "so I
/// can't blow through it in five seconds every night." One budget per
/// Nightly Review *session*, not per sheet presentation: `NightlyReviewView`
/// owns exactly one instance for the whole session (see its
/// `inboxEngagementTimer` property) and hands that same instance to every
/// `AttributeReviewSession` it builds, however many times
/// `startAttributeReviewSession()` reconstructs the queue — a reference
/// type specifically so Cancel-then-"Review Again" resumes the remaining
/// time instead of resetting it. Nothing about this type itself does that
/// resuming; it's just state that outlives any one sheet presentation
/// because its *owner* (`NightlyReviewView`) does.
///
/// Deliberately a plain, synchronously-tickable counter rather than a
/// self-scheduling `Timer` — `tick(by:)` just decrements and clamps, so
/// it's directly unit-testable with synchronous calls instead of waiting
/// on real wall-clock seconds. `TaskReviewQueueSheet` is what actually
/// drives it once a second, via `.onReceive` in its own view body — which
/// also gives the "pause while the sheet is dismissed" behavior for free:
/// nothing calls `tick(by:)` while no view is on screen to receive it, so
/// Cancelling genuinely pauses the clock rather than letting it keep
/// running against the wall clock in the background.
@Observable
final class InboxEngagementTimer {
    static let initialDuration: TimeInterval = 120

    private(set) var remaining: TimeInterval

    init(remaining: TimeInterval = InboxEngagementTimer.initialDuration) {
        self.remaining = remaining
    }

    var isExpired: Bool { remaining <= 0 }

    func tick(by interval: TimeInterval = 1) {
        remaining = max(0, remaining - interval)
    }
}
