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
                TaskCompletionRecord.self, RecurringTaskLog.self, TaskMissRecord.self,
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
    func test_missedPushesToThePlannedDay() throws {
        let planDate = day(2026, 1, 6)
        let task = makeTask()

        XCTAssertEqual(TwoMinutePush.cycle(task, planDate: planDate, context: context), .complete)
        XCTAssertNil(task.startDate, "completing doesn't push")

        XCTAssertEqual(TwoMinutePush.cycle(task, planDate: planDate, context: context), .missed)

        XCTAssertEqual(task.startDate.map { calendar.startOfDay(for: $0) }, day(2026, 1, 6))
        XCTAssertTrue(task.startDatePicked, "the card shows it — a startDate it doesn't display is invisible state")
    }

    /// Off tonight's list, on tomorrow's. This is the whole point, asserted
    /// through the predicate both real call sites actually use.
    func test_pushedTaskIsIneligibleTonight_andEligibleTomorrow() throws {
        let planDate = day(2026, 1, 6)
        let task = makeTask()
        _ = TwoMinutePush.cycle(task, planDate: planDate, context: context)
        _ = TwoMinutePush.cycle(task, planDate: planDate, context: context)

        XCTAssertFalse(task.isEligibleToStart(on: day(2026, 1, 5)), "gone from tonight")
        XCTAssertTrue(task.isEligibleToStart(on: planDate), "on the day being planned")
    }

    /// **Lands on the day being planned, not on a day computed from the
    /// miss.**
    ///
    /// REVERSAL: this used to assert `reviewDate + 1`, computed inside the
    /// push. Catching up several days late then put a miss on the day after
    /// the day it was missed — still in the past, and invisible. The caller
    /// passes the day it is actually planning, so the task lands where the
    /// screen says it will.
    func test_landsOnTheDayBeingPlanned_notRelativeToTheMiss() throws {
        let planDate = day(2025, 3, 11)
        let task = makeTask()
        _ = TwoMinutePush.cycle(task, planDate: planDate, context: context)
        _ = TwoMinutePush.cycle(task, planDate: planDate, context: context)

        XCTAssertEqual(task.startDate.map { calendar.startOfDay(for: $0) }, day(2025, 3, 11))
    }

    // MARK: - Undo

    /// Changing your mind must leave no trace. A task with no prior start
    /// date goes back to having none, rather than keeping the pushed one.
    func test_cyclingPastMissed_clearsThePushEntirely() throws {
        let planDate = day(2026, 1, 6)
        let task = makeTask()
        _ = TwoMinutePush.cycle(task, planDate: planDate, context: context)   // complete
        _ = TwoMinutePush.cycle(task, planDate: planDate, context: context)   // missed
        XCTAssertNotNil(task.startDate)

        XCTAssertEqual(TwoMinutePush.cycle(task, planDate: planDate, context: context), .none)

        XCTAssertNil(task.startDate, "no prior date, so the push clears rather than lingering")
        XCTAssertFalse(task.startDatePicked)
    }

    /// A task that already had a start date gets *that* back, not nil.
    func test_undoRestoresAPriorStartDate() throws {
        let planDate = day(2026, 1, 6)
        let prior = day(2025, 12, 1)
        let task = makeTask()
        task.setStartDate(prior)
        _ = TwoMinutePush.cycle(task, planDate: planDate, context: context)
        _ = TwoMinutePush.cycle(task, planDate: planDate, context: context)
        XCTAssertEqual(task.startDate.map { calendar.startOfDay(for: $0) }, day(2026, 1, 6))

        _ = TwoMinutePush.cycle(task, planDate: planDate, context: context)   // back to .none

        XCTAssertEqual(task.startDate.map { calendar.startOfDay(for: $0) }, prior)
    }

    /// Round the loop twice: the restore must be the *original* date, not
    /// the pushed one captured on the second pass.
    func test_twoFullCycles_restoreTheOriginalDate_notThePushedOne() throws {
        let planDate = day(2026, 1, 6)
        let prior = day(2025, 12, 1)
        let task = makeTask()
        task.setStartDate(prior)

        for _ in 0..<3 { _ = TwoMinutePush.cycle(task, planDate: planDate, context: context) }   // none→complete→missed→none
        for _ in 0..<3 { _ = TwoMinutePush.cycle(task, planDate: planDate, context: context) }   // and again

        XCTAssertEqual(task.startDate.map { calendar.startOfDay(for: $0) }, prior)
    }


    // MARK: - One day only, on the calendar
    //
    // **All new.** Sabotage found the calendar's display rule at zero
    // coverage: day-scoping the filter changed nothing in 637 tests, so
    // which days a 2-Minute task appeared on was entirely unasserted.

    /// A task with no start date sits on its creation day — and, crucially,
    /// **not** on every day after it. The old filter was
    /// `isEligibleToStart`, a lower bound, so a task with no start date
    /// appeared on every day scrolled to in both directions.
    func test_displayDay_withNoStartDate_isTheCreationDay() throws {
        let task = makeTask()
        task.createdAt = day(2026, 1, 5).addingTimeInterval(9 * 3600)

        XCTAssertEqual(task.twoMinuteDisplayDay(), day(2026, 1, 5))
        XCTAssertNotEqual(task.twoMinuteDisplayDay(), day(2026, 1, 6), "not tomorrow as well")
    }

    /// A "Can Start By" the user set wins over the creation day — the task
    /// sits where they said it could start, not where it was typed.
    func test_displayDay_withAStartDate_isThatDay() throws {
        let task = makeTask()
        task.createdAt = day(2026, 1, 5)
        task.setStartDate(day(2026, 1, 20))

        XCTAssertEqual(task.twoMinuteDisplayDay(), day(2026, 1, 20))
    }

    /// A push **moves** the day rather than widening a range. This is the
    /// property that makes marking missed on the calendar safe: the row
    /// leaves the day you are looking at because it went somewhere else.
    func test_pushMovesTheDisplayDay_ratherThanOpeningARange() throws {
        let task = makeTask()
        task.createdAt = day(2026, 1, 5)
        XCTAssertEqual(task.twoMinuteDisplayDay(), day(2026, 1, 5))

        TwoMinutePush.apply(to: task, planDate: day(2026, 1, 9))

        XCTAssertEqual(task.twoMinuteDisplayDay(), day(2026, 1, 9), "it moved")
        XCTAssertNotEqual(task.twoMinuteDisplayDay(), day(2026, 1, 5), "and left where it was")
        XCTAssertNotEqual(task.twoMinuteDisplayDay(), day(2026, 1, 10), "and did not spread forward")
    }

    /// Undo puts the display day back too — not just the stored date. The
    /// row returns to the day it came from.
    func test_undoRestoresTheDisplayDay() throws {
        let planDate = day(2026, 1, 9)
        let task = makeTask()
        task.createdAt = day(2026, 1, 5)

        for _ in 0..<2 { _ = TwoMinutePush.cycle(task, planDate: planDate, context: context) }   // -> missed
        XCTAssertEqual(task.twoMinuteDisplayDay(), planDate)

        _ = TwoMinutePush.cycle(task, planDate: planDate, context: context)   // -> none

        XCTAssertEqual(task.twoMinuteDisplayDay(), day(2026, 1, 5), "back on its creation day")
    }

    /// **The list, not just the rule.**
    ///
    /// Added because sabotage caught the gap: reverting the calendar's
    /// filter to the old lower bound left every `twoMinuteDisplayDay` test
    /// green. The rule was asserted; that the list applied it was not.
    func test_visibleList_showsEachTaskOnItsOwnDayOnly() throws {
        let onFifth = makeTask(title: "Created the 5th")
        onFifth.createdAt = day(2026, 1, 5)
        let pushed = makeTask(title: "Pushed to the 9th")
        pushed.createdAt = day(2026, 1, 5)
        TwoMinutePush.apply(to: pushed, planDate: day(2026, 1, 9))
        let all = [onFifth, pushed]

        let fifth = TaskItem.twoMinuteTasksVisible(on: day(2026, 1, 5), from: all)
        XCTAssertEqual(fifth.map(\.title), ["Created the 5th"], "the pushed one has left this day")

        let ninth = TaskItem.twoMinuteTasksVisible(on: day(2026, 1, 9), from: all)
        XCTAssertEqual(ninth.map(\.title), ["Pushed to the 9th"], "and arrived on that one")

        XCTAssertTrue(
            TaskItem.twoMinuteTasksVisible(on: day(2026, 1, 7), from: all).isEmpty,
            "a day between the two shows neither — the old lower bound showed both"
        )
        XCTAssertTrue(
            TaskItem.twoMinuteTasksVisible(on: day(2026, 1, 20), from: all).isEmpty,
            "and scrolling far ahead is clean, which is the whole point"
        )
    }

    /// A completed task stays on its day, faded rather than gone — same as a
    /// completed calendar block.
    func test_visibleList_keepsCompletedTasks() throws {
        let task = makeTask()
        task.createdAt = day(2026, 1, 5)
        task.status = .complete

        XCTAssertEqual(TaskItem.twoMinuteTasksVisible(on: day(2026, 1, 5), from: [task]).count, 1)
    }

    /// **Nightly Review is deliberately NOT day-scoped**, and that is what
    /// stops day-scoping the calendar from stranding an old task on a day
    /// nobody will scroll back to.
    ///
    /// The review's 2-Minute step filters on `isEligibleToStart`, so a task
    /// created weeks ago and never actioned still surfaces there. Same split
    /// the recurring work settled on: the calendar shows what is planned,
    /// the review shows what is owed.
    func test_anOldUntouchedTaskStillSurfacesInReview_thoughNotOnTodaysCalendar() throws {
        let task = makeTask()
        task.createdAt = day(2025, 6, 1)
        let today = day(2026, 1, 5)

        XCTAssertNotEqual(task.twoMinuteDisplayDay(), today, "off today's calendar — it belongs to its own day")
        XCTAssertTrue(
            task.isEligibleToStart(on: today),
            "but still eligible, which is the predicate Nightly Review's 2-Minute step uses — the review is the catch-all"
        )
    }

    // MARK: - The undo survives leaving the screen

    /// **The bug the persistent fields exist for.**
    ///
    /// `TwoMinutePushState` kept prior start dates in an in-memory
    /// `[UUID: Date?]` on `NightlyReviewView`, justified in its own comment
    /// on the grounds that a 2-Minute push is "a single `startDate` write
    /// with no persistent object behind it." That reasoning was wrong: the
    /// *write* is persistent, so the information needed to reverse it has to
    /// be too. Leaving the review destroyed the map, and cycling off
    /// `.missed` afterwards silently did nothing — the pushed date stayed
    /// forever.
    ///
    /// There is no view in this test at all, which is the point: the undo
    /// now depends on nothing but the task itself.
    func test_undoWorksAfterTheScreenIsGone() throws {
        let planDate = day(2026, 1, 6)
        let prior = day(2025, 12, 1)
        let task = makeTask()
        task.setStartDate(prior)

        // A push made "last session".
        _ = TwoMinutePush.cycle(task, planDate: planDate, context: context)   // complete
        _ = TwoMinutePush.cycle(task, planDate: planDate, context: context)   // missed
        XCTAssertEqual(task.startDate.map { calendar.startOfDay(for: $0) }, planDate)

        // Nothing carries over between sessions but the task's own fields —
        // no state object is reconstructed here, deliberately.
        _ = TwoMinutePush.cycle(task, planDate: planDate, context: context)   // -> none

        XCTAssertEqual(
            task.startDate.map { calendar.startOfDay(for: $0) }, prior,
            "the prior date must come back from the task, not from a view that no longer exists"
        )
        XCTAssertFalse(task.hasOutstandingTwoMinutePush)
    }

    /// A task that had no start date gets none back — `nil` is a real prior
    /// value, which is why the marker is a separate flag rather than
    /// `startDateBeforePush != nil`.
    func test_undoRestoresHavingHadNoStartDate() throws {
        let planDate = day(2026, 1, 6)
        let task = makeTask()
        XCTAssertNil(task.startDate)

        _ = TwoMinutePush.cycle(task, planDate: planDate, context: context)
        _ = TwoMinutePush.cycle(task, planDate: planDate, context: context)   // missed
        XCTAssertNotNil(task.startDate)

        _ = TwoMinutePush.cycle(task, planDate: planDate, context: context)   // -> none

        XCTAssertNil(task.startDate, "no prior date means clear, not keep the pushed one")
        XCTAssertFalse(task.startDatePicked, "and the card must not show a picked state for a value never chosen")
    }

    /// Completing a pushed task undoes it too — the gate is "not landing on
    /// `.missed`", not "was `.none`". Same rule the recurring push needed.
    func test_completingAfterMissing_undoesThePush() throws {
        let planDate = day(2026, 1, 6)
        let task = makeTask()
        for _ in 0..<2 { _ = TwoMinutePush.cycle(task, planDate: planDate, context: context) }   // -> missed
        XCTAssertTrue(task.hasOutstandingTwoMinutePush)

        _ = TwoMinutePush.cycle(task, planDate: planDate, context: context)   // -> none
        XCTAssertEqual(TwoMinutePush.cycle(task, planDate: planDate, context: context), .complete)

        XCTAssertNil(task.startDate, "a completed task carries no leftover push")
        XCTAssertFalse(task.hasOutstandingTwoMinutePush)
    }

    // MARK: - The expired-push sweep

    /// **REVERSAL: the marker is `hasOutstandingTwoMinutePush`, not
    /// `.missed`.**
    ///
    /// The sweep used to infer "we set this date" from `status == .missed`,
    /// which was the only state that could reach a push. Its own comment
    /// recorded the hole that left — completing and then un-completing
    /// collapses `.missed` to `.none`, stranding the date — and judged it
    /// not worth a stored field. The field now exists for the undo, so
    /// these fixtures set the real marker and the hole closes for free.
    func test_clearsAPushedDateOnceItHasPassed() throws {
        let task = makeTask()
        TwoMinutePush.apply(to: task, planDate: day(2026, 1, 6))
        XCTAssertTrue(task.hasOutstandingTwoMinutePush)

        TwoMinutePush.clearExpiredPushes(on: [task], asOf: day(2026, 1, 8))

        XCTAssertNil(task.startDate)
        XCTAssertFalse(task.hasOutstandingTwoMinutePush, "nothing left to reverse once the day has passed")
        XCTAssertNil(task.startDateBeforePush, "a stale capture would restore a long-dead date if cycled again")
    }

    /// The hole the old `.missed` gate left, now closed: a pushed task
    /// whose status has been collapsed back to `.none` still gets swept,
    /// because the marker no longer rides on the status.
    func test_clearsAPushedDate_evenWhenTheStatusIsNoLongerMissed() throws {
        let task = makeTask()
        TwoMinutePush.apply(to: task, planDate: day(2026, 1, 6))
        task.status = .none   // complete-then-uncomplete collapses it

        TwoMinutePush.clearExpiredPushes(on: [task], asOf: day(2026, 1, 8))

        XCTAssertNil(task.startDate, "the old `.missed` gate stranded this date permanently")
    }

    /// Today is not past — a task pushed to today is doing its job.
    func test_leavesTodaysPushAlone() throws {
        let task = makeTask()
        TwoMinutePush.apply(to: task, planDate: day(2026, 1, 6))

        TwoMinutePush.clearExpiredPushes(on: [task], asOf: day(2026, 1, 6))

        XCTAssertNotNil(task.startDate)
        XCTAssertTrue(task.hasOutstandingTwoMinutePush, "still outstanding — it has not had its day yet")
    }

    /// **The over-reach guard.** `startDate` is the user's own "Can Start
    /// By" field. A past one on a task we did *not* push must survive —
    /// clearing every past start date would destroy real input, which is
    /// the same mistake the derived-reset guard exists to prevent.
    ///
    /// Stronger than it was: the task is deliberately left at `.missed` too,
    /// so this now proves the sweep keys on the push marker rather than on
    /// the status. Under the old gate this fixture would have been cleared.
    func test_leavesAUserSetPastStartDateAlone() throws {
        let userSet = makeTask(title: "User set this")
        userSet.setStartDate(day(2025, 6, 1))
        userSet.status = .missed
        XCTAssertFalse(userSet.hasOutstandingTwoMinutePush, "never pushed by us")

        TwoMinutePush.clearExpiredPushes(on: [userSet], asOf: day(2026, 1, 8))

        XCTAssertEqual(userSet.startDate.map { calendar.startOfDay(for: $0) }, day(2025, 6, 1),
                       "not ours to clear — the push marker is what says we set it")
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

/// The durable record of a 2-Minute miss — see `TaskMissRecord`.
///
/// All new: this model did not exist, so there is nothing here that was
/// updated rather than written.
final class TaskMissRecordTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: TaskItem.self, ScheduledBlock.self, Shelf.self, Tag.self,
                TaskCompletionRecord.self, RecurringTaskLog.self, TaskMissRecord.self,
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

    /// Both days are normalised to start-of-day, so a record created from a
    /// mid-afternoon `.now` still matches a day-granular lookup.
    func test_daysAreNormalisedToStartOfDay() {
        let task = makeTask()
        let afternoon = day(2026, 1, 5).addingTimeInterval(15 * 3600)
        let record = TaskMissRecord(taskID: task.id, title: task.title, missedDay: afternoon, pushedToDay: afternoon.addingTimeInterval(86400))

        XCTAssertEqual(record.missedDay, day(2026, 1, 5))
        XCTAssertEqual(record.pushedToDay, day(2026, 1, 6))
    }

    /// The title is copied rather than read through `taskID`, so the row
    /// still renders after the task is deleted.
    func test_titleSurvivesTheTaskBeingDeleted() throws {
        let task = makeTask(title: "Take the bins out")
        let record = TaskMissRecord(taskID: task.id, title: task.title, missedDay: day(2026, 1, 5), pushedToDay: day(2026, 1, 6))
        context.insert(record)
        context.delete(task)

        XCTAssertEqual(record.title, "Take the bins out", "a copied title is what makes the record renderable on its own")
    }

    /// The day lookup is bounded to one calendar day in both directions —
    /// a record on the day before or after must not be picked up.
    func test_recordsOn_isBoundedToTheSingleDay() throws {
        let task = makeTask()
        for d in [4, 5, 6] {
            context.insert(TaskMissRecord(taskID: task.id, title: task.title, missedDay: day(2026, 1, d), pushedToDay: day(2026, 1, d + 1)))
        }

        let fifth = TaskMissRecord.records(on: day(2026, 1, 5), in: context)
        XCTAssertEqual(fifth.count, 1)
        XCTAssertEqual(fifth.first?.missedDay, day(2026, 1, 5))
    }

    /// A day with no misses is empty rather than returning everything —
    /// the predicate failing open would put every past miss on every day.
    func test_recordsOn_emptyDayIsEmpty() throws {
        let task = makeTask()
        context.insert(TaskMissRecord(taskID: task.id, title: task.title, missedDay: day(2026, 1, 5), pushedToDay: day(2026, 1, 6)))

        XCTAssertTrue(TaskMissRecord.records(on: day(2026, 1, 9), in: context).isEmpty)
    }

    /// Lookup by task finds the outstanding record, and nothing for a task
    /// that was never missed.
    func test_recordForTask() throws {
        let missed = makeTask(title: "Missed")
        let untouched = makeTask(title: "Untouched")
        context.insert(TaskMissRecord(taskID: missed.id, title: missed.title, missedDay: day(2026, 1, 5), pushedToDay: day(2026, 1, 6)))

        XCTAssertNotNil(TaskMissRecord.record(for: missed, in: context))
        XCTAssertNil(TaskMissRecord.record(for: untouched, in: context))
    }

    /// The record keeps its own `missedDay` — nothing advances it. Unlike
    /// `PushedRecurringOccurrence.currentDate`, which used to walk forward
    /// day by day, a miss belongs to the day it happened on.
    func test_missedDayNeverMoves() throws {
        let task = makeTask()
        let record = TaskMissRecord(taskID: task.id, title: task.title, missedDay: day(2026, 1, 5), pushedToDay: day(2026, 1, 6))
        context.insert(record)

        // Whatever else happens to the task, the record stays on its day.
        task.setStartDate(day(2026, 2, 20))
        task.status = .complete

        XCTAssertEqual(TaskMissRecord.records(on: day(2026, 1, 5), in: context).count, 1, "still on the day it happened")
    }
}
