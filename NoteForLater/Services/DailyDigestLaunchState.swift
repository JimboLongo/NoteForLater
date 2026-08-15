import Observation

/// Set when a Daily Digest notification is tapped (see AppDelegate) —
/// ContentView observes this to present DailyDigestCheckInView. Mirrors
/// NightlyReviewLaunchState's pattern.
@Observable
final class DailyDigestLaunchState {
    static let shared = DailyDigestLaunchState()
    var pendingCheckIn = false
    private init() {}
}
