import Foundation
import Observation

/// Tracks the calendar day of the most recently *closed-out* Nightly
/// Review — set the moment the Today→Tomorrow handoff actually runs (see
/// `NightlyReviewView.advance()`), not just when the sheet is dismissed.
/// `ScheduleReviewViewModel.autoPlaceEligibleTasks` checks this so that
/// once tonight's review has closed today out, the live auto-place walk
/// stops treating today's remaining free hours as fair game for a
/// brand-new task — "today is over" the moment the nightly ritual has
/// actually run, not just at midnight. Persisted in UserDefaults (like
/// `NightlyReviewSettings`) so it survives the app being backgrounded or
/// force-quit before midnight actually arrives.
@Observable
final class NightlyReviewCompletionState {
    static let shared = NightlyReviewCompletionState()

    private let key = "com.jimbo.NoteForLater.lastClosedReviewDay"

    private(set) var lastClosedReviewDay: Date? {
        didSet {
            if let lastClosedReviewDay {
                UserDefaults.standard.set(lastClosedReviewDay, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    private init() {
        lastClosedReviewDay = UserDefaults.standard.object(forKey: key) as? Date
    }

    /// Call right when a day's review actually closes it out (the
    /// Today→Tomorrow handoff), not when "Done" is tapped — a user who
    /// lingers on the Tomorrow step before dismissing has still, as far
    /// as that day's schedule is concerned, already closed it.
    func markReviewed(day: Date) {
        lastClosedReviewDay = Calendar.current.startOfDay(for: day)
    }

    func isClosed(day: Date) -> Bool {
        guard let lastClosedReviewDay else { return false }
        return Calendar.current.isDate(lastClosedReviewDay, inSameDayAs: day)
    }
}
