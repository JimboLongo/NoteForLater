import XCTest
import SwiftData
@testable import NoteForLater

/// Marking a 2-minute task missed pushes it one day — off tonight's list,
/// back on tomorrow's — using `startDate` + `isEligibleToStart`, the
/// mechanism both places that show these tasks already filter on.
final class TwoMinutePushTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: TaskItem.self, ScheduledBlock.self, Shelf.self, Tag.self,
                TaskCompletionRecord.self, RecurringTaskLog.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    private var calendar: Calendar { .current }
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func makeTask(title: String = "Water the plant") -> TaskItem {
        let shelf = Shelf(name: "2-Minute Tasks")
        shelf.isTwoMinuteTasks = true
        context.insert(shelf)
        let task = TaskItem(title: title, shelf: shelf)
        context.insert(task)
        return task
    }

    // MARK: - The push

    /// Two taps reach `.missed` (`.none → .complete → .missed`), and that
    /// is what pushes.
    func test_missedPushesToTheDayAfterTheReviewDate() throws {
        let reviewDate = day(2026, 1, 5)
        let task = makeTask()
        var state = TwoMinutePushState()

        XCTAssertEqual(state.cycle(task, reviewDate: reviewDate, context: context), .complete)
        XCTAssertNil(task.startDate, "completing doesn't push")

        XCTAssertEqual(state.cycle(task, reviewDate: reviewDate, context: context), .missed)

        XCTAssertEqual(task.startDate.map { calendar.startOfDay(for: $0) }, day(2026, 1, 6))
        XCTAssertTrue(task.startDatePicked, "the card shows it — a startDate it doesn't display is invisible state")
    }

    /// Off tonight's list, on tomorrow's. This is the whole point, asserted
    /// through the predicate both real call sites actually use.
    func test_pushedTaskIsIneligibleTonight_andEligibleTomorrow() throws {
        let reviewDate = day(2026, 1, 5)
        let task = makeTask()
        var state = TwoMinutePushState()
        _ = state.cycle(task, reviewDate: reviewDate, context: context)
        _ = state.cycle(task, reviewDate: reviewDate, context: context)

        XCTAssertFalse(task.isEligibleToStart(on: reviewDate), "gone from tonight")
        XCTAssertTrue(task.isEligibleToStart(on: day(2026, 1, 6)), "back tomorrow")
    }

    /// Pushes relative to the day being *reviewed*, not to `.now` — Choose
    /// Day can run the review for yesterday, and a task missed in that
    /// review belongs on the day after the one being reviewed.
    func test_pushesRelativeToReviewDate_notToNow() throws {
        let reviewDate = day(2025, 3, 10)
        let task = makeTask()
        var state = TwoMinutePushState()
        _ = state.cycle(task, reviewDate: reviewDate, context: context)
        _ = state.cycle(task, reviewDate: reviewDate, context: context)

        XCTAssertEqual(task.startDate.map { calendar.startOfDay(for: $0) }, day(2025, 3, 11))
    }

    // MARK: - Undo

    /// Changing your mind must leave no trace. A task with no prior start
    /// date goes back to having none, rather than keeping the pushed one.
    func test_cyclingPastMissed_clearsThePushEntirely() throws {
        let reviewDate = day(2026, 1, 5)
        let task = makeTask()
        var state = TwoMinutePushState()
        _ = state.cycle(task, reviewDate: reviewDate, context: context)   // complete
        _ = state.cycle(task, reviewDate: reviewDate, context: context)   // missed
        XCTAssertNotNil(task.startDate)

        XCTAssertEqual(state.cycle(task, reviewDate: reviewDate, context: context), .none)

        XCTAssertNil(task.startDate, "no prior date, so the push clears rather than lingering")
        XCTAssertFalse(task.startDatePicked)
        XCTAssertTrue(state.isEmpty)
    }

    /// A task that already had a start date gets *that* back, not nil.
    func test_undoRestoresAPriorStartDate() throws {
        let reviewDate = day(2026, 1, 5)
        let prior = day(2025, 12, 1)
        let task = makeTask()
        task.setStartDate(prior)
        var state = TwoMinutePushState()
        _ = state.cycle(task, reviewDate: reviewDate, context: context)
        _ = state.cycle(task, reviewDate: reviewDate, context: context)
        XCTAssertEqual(task.startDate.map { calendar.startOfDay(for: $0) }, day(2026, 1, 6))

        _ = state.cycle(task, reviewDate: reviewDate, context: context)   // back to .none

        XCTAssertEqual(task.startDate.map { calendar.startOfDay(for: $0) }, prior)
    }

    /// Round the loop twice: the restore must be the *original* date, not
    /// the pushed one captured on the second pass.
    func test_twoFullCycles_restoreTheOriginalDate_notThePushedOne() throws {
        let reviewDate = day(2026, 1, 5)
        let prior = day(2025, 12, 1)
        let task = makeTask()
        task.setStartDate(prior)
        var state = TwoMinutePushState()

        for _ in 0..<3 { _ = state.cycle(task, reviewDate: reviewDate, context: context) }   // none→complete→missed→none
        for _ in 0..<3 { _ = state.cycle(task, reviewDate: reviewDate, context: context) }   // and again

        XCTAssertEqual(task.startDate.map { calendar.startOfDay(for: $0) }, prior)
    }

    /// Completing after missing is the common correction — the push has to
    /// come off, not just the status change.
    func test_completingAfterMissing_undoesThePush() throws {
        let reviewDate = day(2026, 1, 5)
        let task = makeTask()
        var state = TwoMinutePushState()
        _ = state.cycle(task, reviewDate: reviewDate, context: context)
        _ = state.cycle(task, reviewDate: reviewDate, context: context)   // missed
        _ = state.cycle(task, reviewDate: reviewDate, context: context)   // none
        XCTAssertEqual(state.cycle(task, reviewDate: reviewDate, context: context), .complete)

        XCTAssertNil(task.startDate, "a completed task carries no leftover push")
    }

    // MARK: - The expired-push sweep

    func test_clearsAPushedDateOnceItHasPassed() throws {
        let task = makeTask()
        task.status = .missed
        task.setStartDate(day(2026, 1, 6))

        TwoMinutePushState.clearExpiredPushes(on: [task], asOf: day(2026, 1, 8))

        XCTAssertNil(task.startDate)
        XCTAssertEqual(task.status, .missed, "the sweep clears the date, not the decision")
    }

    /// Today is not past — a task pushed to today is doing its job.
    func test_leavesTodaysPushAlone() throws {
        let task = makeTask()
        task.status = .missed
        task.setStartDate(day(2026, 1, 6))

        TwoMinutePushState.clearExpiredPushes(on: [task], asOf: day(2026, 1, 6))

        XCTAssertNotNil(task.startDate)
    }

    /// **The over-reach guard.** `startDate` is the user's own "Can Start
    /// By" field. A past one on a task we did *not* push must survive —
    /// clearing every past start date would destroy real input, which is
    /// the same mistake the derived-reset guard exists to prevent.
    func test_leavesAUserSetPastStartDateAlone_whenNotMissed() throws {
        let userSet = makeTask(title: "User set this")
        userSet.setStartDate(day(2025, 6, 1))
        XCTAssertEqual(userSet.status, .none)

        TwoMinutePushState.clearExpiredPushes(on: [userSet], asOf: day(2026, 1, 8))

        XCTAssertEqual(userSet.startDate.map { calendar.startOfDay(for: $0) }, day(2025, 6, 1),
                       "not ours to clear — .missed is what marks a push")
    }
}

/// The 2-Minute step's engagement floor.
final class TwoMinuteEngagementTimerTests: XCTestCase {
    private typealias Timer = TwoMinuteEngagementTimer

    /// Two minutes per unresolved task, capped at four. Missed counts in
    /// full — it is a decision, not a completion, so it buys no time off.
    func test_budgetIsTwoMinutesPerUnresolvedTask_cappedAtFour() async {
        XCTAssertEqual(Timer.budget(missed: 0, unanswered: 0), 0)
        XCTAssertEqual(Timer.budget(missed: 0, unanswered: 1), 120)
        XCTAssertEqual(Timer.budget(missed: 1, unanswered: 0), 120, "missed is worth the same as unanswered")
        XCTAssertEqual(Timer.budget(missed: 1, unanswered: 1), 240, "one of each is the full four minutes")
        XCTAssertEqual(Timer.budget(missed: 3, unanswered: 4), 240, "capped")
    }

    /// Everything complete means **no timer at all**, not one reading 0:00 —
    /// true from the very first frame, before any tick.
    func test_allCompleteMeansNoTimerAtAll() async {
        let timer = Timer()
        XCTAssertTrue(timer.canProceed(missed: 0, unanswered: 0))
        XCTAssertEqual(timer.remaining(missed: 0, unanswered: 0), 0)
    }

    /// The budget is live: completing a task shortens the wait immediately.
    func test_completingOneDropsTheWaitByTwoMinutes() async {
        let timer = Timer()
        for _ in 0..<60 { timer.tick() }   // a minute in

        XCTAssertEqual(timer.remaining(missed: 1, unanswered: 1), 180, "4:00 budget, 1:00 spent")
        XCTAssertEqual(timer.remaining(missed: 1, unanswered: 0), 60, "one completed → 2:00 budget, 1:00 spent")
    }

    /// And switching one back from complete adds it again — the budget is
    /// recomputed, not decremented, so it moves in both directions.
    func test_unCompletingOneAddsTheTimeBack() async {
        let timer = Timer()
        for _ in 0..<60 { timer.tick() }
        XCTAssertEqual(timer.remaining(missed: 0, unanswered: 1), 60)
        XCTAssertEqual(timer.remaining(missed: 0, unanswered: 2), 180, "back up when one returns to unanswered")
    }

    /// **Dropping to zero mid-countdown proceeds immediately** — remaining
    /// time is not still owed. The floor exists to sit with unresolved
    /// work; with none left there is nothing to sit with, and making
    /// someone wait it out would punish finishing.
    func test_finishingEverythingMidCountdownProceedsImmediately() async {
        let timer = Timer()
        for _ in 0..<10 { timer.tick() }   // 3:50 still owed on a 4:00 budget
        XCTAssertFalse(timer.canProceed(missed: 1, unanswered: 1))

        XCTAssertTrue(timer.canProceed(missed: 0, unanswered: 0), "everything completed → straight through")
    }

    /// One budget per session: `elapsed` accumulates, so leaving and
    /// returning resumes rather than restarting. Matches
    /// `InboxEngagementTimer`, where restarting would make stepping back a
    /// way to reset the floor.
    func test_elapsedAccumulatesAcrossVisits() async {
        let timer = Timer()
        for _ in 0..<90 { timer.tick() }
        XCTAssertEqual(timer.remaining(missed: 1, unanswered: 1), 150)

        // A second visit continues from where it left off.
        for _ in 0..<60 { timer.tick() }
        XCTAssertEqual(timer.remaining(missed: 1, unanswered: 1), 90)
    }

    func test_waitingOutTheBudgetUnlocksIt() async {
        let timer = Timer()
        XCTAssertFalse(timer.canProceed(missed: 1, unanswered: 0))
        for _ in 0..<120 { timer.tick() }
        XCTAssertTrue(timer.canProceed(missed: 1, unanswered: 0))
    }
}
