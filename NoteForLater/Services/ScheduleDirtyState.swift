import Observation

/// Set whenever something happens that could invalidate what's already
/// on the calendar — a task's own attributes changing, a shelf's rules
/// changing, a schedule's own window changing — so `ScheduleReviewView`
/// knows the next time it's about to do its routine live top-up
/// (`autoPlaceEligibleTasks`, purely additive — see its own doc comment)
/// that this pass instead needs to escalate to a real `regenerateFromNow`
/// first: only a full clear-and-rewalk can move a task that's already
/// sitting on a day it's no longer eligible for, and the purely-additive
/// top-up alone would leave that stale placement exactly where it is
/// forever. Mirrors `InboxSearchState`/`NightlyReviewLaunchState`'s
/// pattern: a single piece of cross-view state that doesn't belong on
/// any one view's own model data.
///
/// Deliberately a flag, not a queue of exactly what changed — the flush
/// always runs the same full `regenerateFromNow` walk regardless of
/// which trigger set it, so there's nothing more specific worth
/// recording. See spec §6 (docs/NoteForLater-Scheduling-Spec.md).
@Observable
final class ScheduleDirtyState {
    static let shared = ScheduleDirtyState()
    var isDirty = false
    private init() {}
}
