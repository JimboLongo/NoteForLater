import Observation

/// Set when the Nightly Review notification is tapped (see AppDelegate),
/// or when "Start Nightly Review Now" is tapped in Settings — either way,
/// ContentView observes this to present NightlyReviewView. Mirrors
/// QuickActionService's `pendingQuickAdd` pattern.
@Observable
final class NightlyReviewLaunchState {
    static let shared = NightlyReviewLaunchState()
    var pendingReview = false
    private init() {}
}
