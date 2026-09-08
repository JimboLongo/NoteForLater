import XCTest
@testable import NoteForLater

/// Coverage for `ChooseDayPlanning` — the pure logic behind Nightly
/// Review's "Which day are you planning?" step. `NightlyReviewView.
/// chooseDayStep` itself isn't unit-testable (private, needs a live
/// SwiftUI/SwiftData environment), so this exercises the pulled-out
/// decisions the same way `StepAutoSkipTests`/`InboxEngagementTests` do
/// for their own features.
final class ChooseDayPlanningTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: - Picking Today / Tomorrow sets the right reviewDate

    /// "Plan Today" sets `reviewDate` to *yesterday* — reviewDate + 1
    /// (planDate) then lands on today, which is what "planning today"
    /// means under the new framing.
    func test_reviewDateForPlanningToday_setsYesterday() {
        let now = date(2026, 9, 6, hour: 20) // any time of day — the button itself isn't time-gated
        let result = ChooseDayPlanning.reviewDate(forPlanning: .today, now: now, calendar: calendar)
        XCTAssertEqual(result, calendar.startOfDay(for: date(2026, 9, 5)))
    }

    /// "Plan Tomorrow" sets `reviewDate` to *today*.
    func test_reviewDateForPlanningTomorrow_setsToday() {
        let now = date(2026, 9, 6, hour: 9)
        let result = ChooseDayPlanning.reviewDate(forPlanning: .tomorrow, now: now, calendar: calendar)
        XCTAssertEqual(result, calendar.startOfDay(for: date(2026, 9, 6)))
    }

    // MARK: - The gate removal

    /// Planning today must always be selectable, regardless of whether
    /// there's anything left over from before today — disabling it on an
    /// empty backlog used to read as "you can't plan today because
    /// yesterday was clean," which is backwards.
    ///
    /// Verified fail-then-pass: with `isPlanTodayOptionDisabled`
    /// temporarily reverted to `!hasAnythingToReviewBeforeToday` (the
    /// exact pre-fix gate), this test failed for the `false` case —
    /// asserting not-disabled came back disabled. Restored to always
    /// `false` and reran: green, both cases. Both via `xcodebuild test`.
    func test_isPlanTodayOptionDisabled_alwaysFalse_regardlessOfBacklog() {
        XCTAssertFalse(ChooseDayPlanning.isPlanTodayOptionDisabled(hasAnythingToReviewBeforeToday: false), "must be selectable when yesterday has nothing to review")
        XCTAssertFalse(ChooseDayPlanning.isPlanTodayOptionDisabled(hasAnythingToReviewBeforeToday: true), "must also be selectable when there IS a backlog")
    }

    // MARK: - Default nudge is time-of-day aware

    func test_defaultPlanningChoice_beforeNoon_isToday() {
        let earlyMorning = date(2026, 9, 6, hour: 7, minute: 30)
        XCTAssertEqual(ChooseDayPlanning.defaultPlanningChoice(now: earlyMorning, calendar: calendar), .today)
    }

    func test_defaultPlanningChoice_atOrAfterNoon_isTomorrow() {
        let noon = date(2026, 9, 6, hour: 12)
        let evening = date(2026, 9, 6, hour: 21)
        XCTAssertEqual(ChooseDayPlanning.defaultPlanningChoice(now: noon, calendar: calendar), .tomorrow)
        XCTAssertEqual(ChooseDayPlanning.defaultPlanningChoice(now: evening, calendar: calendar), .tomorrow)
    }

    // MARK: - The planned-day label renders correctly in both modes

    /// Planning Today: `reviewDate` = yesterday, so `planDate` (reviewDate
    /// + 1) is real-today — the label must say "Today", not "Tomorrow".
    func test_planRelativeDayLabel_whenPlanningToday_readsToday() {
        let now = date(2026, 9, 6, hour: 20)
        let planDate = date(2026, 9, 6) // reviewDate (Sep 5) + 1 day
        XCTAssertEqual(ChooseDayPlanning.planRelativeDayLabel(planDate: planDate, now: now, calendar: calendar), "Today")
    }

    /// Planning Tomorrow: `reviewDate` = today, so `planDate` is
    /// real-tomorrow — the label must say "Tomorrow".
    func test_planRelativeDayLabel_whenPlanningTomorrow_readsTomorrow() {
        let now = date(2026, 9, 6, hour: 20)
        let planDate = date(2026, 9, 7) // reviewDate (Sep 6) + 1 day
        XCTAssertEqual(ChooseDayPlanning.planRelativeDayLabel(planDate: planDate, now: now, calendar: calendar), "Tomorrow")
    }
}
