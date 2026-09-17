import Foundation

/// The 2-Minute step's floor: you can proceed once everything is complete,
/// or once you've waited out the time the unresolved ones are worth.
///
/// **The budget is live, not a countdown from a fixed start.** Two minutes
/// per task that is missed *or* unanswered, capped at four:
///
///     budget = min(4 min, 2 min × (missed + unanswered))
///
/// Marking one complete drops it by two minutes; switching one back from
/// complete adds two back. One missed + one unanswered = the full four.
///
/// **Missed counts in full.** It is a decision, not a completion — you said
/// you aren't doing this now, which is exactly the case the floor exists
/// for. Only actually finishing something buys time off.
///
/// Sibling of `InboxEngagementTimer`, and deliberately shaped the same way:
/// a plain object holding `elapsed`, ticked once a second by an
/// `.onReceive` on the step's own view. That is what gives both of them
/// "leave and come back and it resumes, it doesn't reset" — the
/// subscription is torn down with the view, so wall-clock time passing
/// off-screen never reaches the timer.
@Observable
final class TwoMinuteEngagementTimer {
    static let perUnresolvedTask: TimeInterval = 120
    static let cap: TimeInterval = 240

    /// Seconds actually spent on the step this session. One budget per
    /// review, matching `InboxEngagementTimer` — restarting it on revisit
    /// would make stepping back a way to reset the floor.
    private(set) var elapsed: TimeInterval = 0

    init(elapsed: TimeInterval = 0) {
        self.elapsed = elapsed
    }

    func tick(by interval: TimeInterval = 1) {
        elapsed += interval
    }

    /// What the current state of the list is worth.
    static func budget(missed: Int, unanswered: Int) -> TimeInterval {
        min(cap, perUnresolvedTask * TimeInterval(missed + unanswered))
    }

    /// Time still to wait. **Recomputed against a live budget**, so
    /// completing a task shortens the wait immediately rather than only
    /// affecting the next visit.
    func remaining(missed: Int, unanswered: Int) -> TimeInterval {
        max(0, Self.budget(missed: missed, unanswered: unanswered) - elapsed)
    }

    /// Whether the step may be left.
    ///
    /// **Everything complete means no timer at all** — not a timer that
    /// happens to read zero. The budget is zero, so this is true from the
    /// first frame and no countdown is ever shown.
    ///
    /// And when the count drops to zero mid-countdown, this flips to true
    /// immediately: the floor exists to make you sit with *unresolved*
    /// work, so with none left there is nothing to sit with. Making
    /// someone wait out time they've already earned back would punish
    /// finishing.
    func canProceed(missed: Int, unanswered: Int) -> Bool {
        remaining(missed: missed, unanswered: unanswered) <= 0
    }
}
