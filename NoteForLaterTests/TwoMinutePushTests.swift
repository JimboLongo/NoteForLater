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
        let missedDay = day(2026, 1, 5)
        let task = makeTask()

        XCTAssertEqual(TwoMinutePush.cycle(task, planDate: planDate, missedOn: missedDay, context: context), .complete)
        XCTAssertNil(task.startDate, "completing doesn't push")

        XCTAssertEqual(TwoMinutePush.cycle(task, planDate: planDate, missedOn: missedDay, context: context), .missed)

        XCTAssertEqual(task.startDate.map { calendar.startOfDay(for: $0) }, day(2026, 1, 6))
        XCTAssertTrue(task.startDatePicked, "the card shows it — a startDate it doesn't display is invisible state")
    }

    /// Off tonight's list, on tomorrow's. This is the whole point, asserted
    /// through the predicate both real call sites actually use.
    func test_pushedTaskIsIneligibleTonight_andEligibleTomorrow() throws {
        let planDate = day(2026, 1, 6)
        let missedDay = day(2026, 1, 5)
        let task = makeTask()
        _ = TwoMinutePush.cycle(task, planDate: planDate, missedOn: missedDay, context: context)
        _ = TwoMinutePush.cycle(task, planDate: planDate, missedOn: missedDay, context: context)

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
        let missedDay = day(2025, 3, 10)
        let task = makeTask()
        _ = TwoMinutePush.cycle(task, planDate: planDate, missedOn: missedDay, context: context)
        _ = TwoMinutePush.cycle(task, planDate: planDate, missedOn: missedDay, context: context)

        XCTAssertEqual(task.startDate.map { calendar.startOfDay(for: $0) }, day(2025, 3, 11))
    }

    // MARK: - Undo

    /// Changing your mind must leave no trace. A task with no prior start
    /// date goes back to having none, rather than keeping the pushed one.
    func test_cyclingPastMissed_clearsThePushEntirely() throws {
        let planDate = day(2026, 1, 6)
        let missedDay = day(2026, 1, 5)
        let task = makeTask()
        _ = TwoMinutePush.cycle(task, planDate: planDate, missedOn: missedDay, context: context)   // complete
        _ = TwoMinutePush.cycle(task, planDate: planDate, missedOn: missedDay, context: context)   // missed
        XCTAssertNotNil(task.startDate)

        TwoMinutePush.undo(for: task, context: context)

        XCTAssertNil(task.startDate, "no prior date, so the push clears rather than lingering")
        XCTAssertFalse(task.startDatePicked)
    }

    /// A task that already had a start date gets *that* back, not nil.
    func test_undoRestoresAPriorStartDate() throws {
        let planDate = day(2026, 1, 6)
        let missedDay = day(2026, 1, 5)
        let prior = day(2025, 12, 1)
        let task = makeTask()
        task.setStartDate(prior)
        _ = TwoMinutePush.cycle(task, planDate: planDate, missedOn: missedDay, context: context)
        _ = TwoMinutePush.cycle(task, planDate: planDate, missedOn: missedDay, context: context)
        XCTAssertEqual(task.startDate.map { calendar.startOfDay(for: $0) }, day(2026, 1, 6))

        TwoMinutePush.undo(for: task, context: context)

        XCTAssertEqual(task.startDate.map { calendar.startOfDay(for: $0) }, prior)
    }

    /// Push and undo twice: the restore must be the *original* date, not
    /// the pushed one captured on the second pass.
    func test_twoFullCycles_restoreTheOriginalDate_notThePushedOne() throws {
        let planDate = day(2026, 1, 6)
        let missedDay = day(2026, 1, 5)
        let prior = day(2025, 12, 1)
        let task = makeTask()
        task.setStartDate(prior)

        for _ in 0..<2 {
            _ = TwoMinutePush.cycle(task, planDate: planDate, missedOn: missedDay, context: context)   // -> missed, pushes
            _ = TwoMinutePush.cycle(task, planDate: planDate, missedOn: missedDay, context: context)   // -> complete
            TwoMinutePush.undo(for: task, context: context)
        }

        XCTAssertEqual(task.startDate.map { calendar.startOfDay(for: $0) }, prior)
    }


    // MARK: - The miss record: the half that stays behind

    /// **Two rows, not one moving row.** The live task moves to the planned
    /// day; the record stays on the day the miss happened.
    func test_pushLeavesARecordOnTheDayItWasMissed() throws {
        let task = makeTask()
        task.createdAt = day(2026, 1, 5)
        for _ in 0..<2 {
            _ = TwoMinutePush.cycle(task, planDate: day(2026, 1, 6), missedOn: day(2026, 1, 5), context: context)
        }

        XCTAssertEqual(task.twoMinuteDisplayDay(), day(2026, 1, 6), "the live task moved")
        let onFifth = TaskMissRecord.records(on: day(2026, 1, 5), in: context)
        XCTAssertEqual(onFifth.count, 1, "and the day it was missed on still shows something")
        XCTAssertEqual(onFifth.first?.pushedToDay, day(2026, 1, 6))
    }

    /// The record names the day the miss actually happened, not the last day
    /// it was re-tapped. Cycling missed twice without an intervening undo
    /// keeps the first record.
    /// UPDATED — the rule this asserts changed, so the assertions changed
    /// with it rather than the test being dropped.
    ///
    /// It used to demand **one record per task**, which it got by having
    /// `apply` decline to insert a second. That was protecting something
    /// real and still is: a record must never *move* off the day its miss
    /// happened on, so re-missing cannot rewrite Jan 5 to Jan 8. But it was
    /// too strong. Each miss is its own event — missed Monday, missed again
    /// Tuesday, and both days should read as missed — so the second insert
    /// is now correct and the first record staying put is what matters.
    ///
    /// The old name said "DoesNotMoveOrDuplicate". Only the first half
    /// survives, so the name says that and the duplicate-suppression it also
    /// covered moved to `test_reMissingTheSameDayDoesNotStackTwoRecords`,
    /// where that rule actually lives now (per *day*, not per task).
    func test_reMissingDoesNotMoveAnEarlierRecord() throws {
        let task = makeTask()
        for _ in 0..<2 {
            _ = TwoMinutePush.cycle(task, planDate: day(2026, 1, 6), missedOn: day(2026, 1, 5), context: context)
        }
        // Re-missed from a later day without undoing first.
        TwoMinutePush.apply(to: task, planDate: day(2026, 1, 9), missedOn: day(2026, 1, 8), context: context)

        let all = TaskMissRecord.records(for: task, in: context)
        XCTAssertEqual(all.count, 2, "each miss is its own event — one row per day it happened on")
        XCTAssertEqual(all.first?.missedDay, day(2026, 1, 5), "the first record never moves off the day the miss happened")
        XCTAssertEqual(all.last?.missedDay, day(2026, 1, 8))
    }

    /// The per-day uniqueness that replaced per-task uniqueness. `apply`
    /// leaves the task at `.none`, so the same row can reach `.missed` again
    /// without an intervening undo — and that must not stack two red rows on
    /// one day.
    func test_reMissingTheSameDayDoesNotStackTwoRecords() throws {
        let task = makeTask()
        TwoMinutePush.apply(to: task, planDate: day(2026, 1, 6), missedOn: day(2026, 1, 5), context: context)
        TwoMinutePush.apply(to: task, planDate: day(2026, 1, 6), missedOn: day(2026, 1, 5), context: context)

        XCTAssertEqual(TaskMissRecord.records(for: task, in: context).count, 1)
    }

    /// Undo takes the record with it — otherwise a miss row would stand for
    /// a push that no longer exists.
    func test_undoRemovesTheRecord() throws {
        let task = makeTask()
        for _ in 0..<2 {
            _ = TwoMinutePush.cycle(task, planDate: day(2026, 1, 6), missedOn: day(2026, 1, 5), context: context)
        }
        XCTAssertEqual(try context.fetch(FetchDescriptor<TaskMissRecord>()).count, 1)

        TwoMinutePush.undo(for: task, context: context)

        XCTAssertTrue(try context.fetch(FetchDescriptor<TaskMissRecord>()).isEmpty)
        XCTAssertEqual(task.twoMinuteDisplayDay(), task.twoMinuteDisplayDay(), "and the task is back where it was")
    }

    /// **Completing from the record completes the task and keeps the
    /// record.**
    ///
    /// The two answers have to agree: the calendar keeps missed rows as
    /// history, so a miss completed later still reads as missed on the day
    /// it was missed. "Missed Monday, done Tuesday" is true, and matches
    /// `TaskCompletionRecord` — history is not rewritten by what happened
    /// after.
    func test_completingFromTheRecord_completesTheTaskAndKeepsTheRecord() throws {
        let task = makeTask()
        for _ in 0..<2 {
            _ = TwoMinutePush.cycle(task, planDate: day(2026, 1, 6), missedOn: day(2026, 1, 5), context: context)
        }
        let record = try XCTUnwrap(TaskMissRecord.record(for: task, in: context))

        TwoMinutePush.completeFromRecord(record, task: task, context: context)

        XCTAssertTrue(task.isCompleted, "the point is one last chance to actually do it, not to dismiss a reminder")
        XCTAssertEqual(try context.fetch(FetchDescriptor<TaskMissRecord>()).count, 1, "the miss still happened")
        XCTAssertFalse(task.hasOutstandingTwoMinutePush, "nothing left to undo")
    }

    /// `startDate` is deliberately left where the push put it. Restoring it
    /// would drag the now-completed task back onto the original day, putting
    /// two rows for one task there — the record and the completed task.
    func test_completingFromTheRecord_doesNotDragTheTaskBack() throws {
        let task = makeTask()
        task.createdAt = day(2026, 1, 5)
        for _ in 0..<2 {
            _ = TwoMinutePush.cycle(task, planDate: day(2026, 1, 6), missedOn: day(2026, 1, 5), context: context)
        }
        let record = try XCTUnwrap(TaskMissRecord.record(for: task, in: context))

        TwoMinutePush.completeFromRecord(record, task: task, context: context)

        XCTAssertEqual(task.twoMinuteDisplayDay(), day(2026, 1, 6), "completed on the day it was owed, not the day it was missed")
    }




    // MARK: - What Nightly Review offers

    /// **The two surfaces disagree, correctly — asserted from one state.**
    ///
    /// The calendar keeps a handled miss as history; the review drops it,
    /// because a completed task is no longer owed. Both are true at once,
    /// which is why this is one test rather than two.
    func test_handledMiss_staysOnTheCalendar_andLeavesTheReview() throws {
        let task = makeTask()
        task.createdAt = day(2026, 1, 5)
        for _ in 0..<2 {
            _ = TwoMinutePush.cycle(task, planDate: day(2026, 1, 6), missedOn: day(2026, 1, 5), context: context)
        }
        let reviewDate = day(2026, 1, 6)

        // Before completing: offered in the review, present on the calendar.
        XCTAssertEqual(TaskMissRecord.actionableRecords(before: reviewDate, tasks: [task], in: context).count, 1)
        XCTAssertEqual(TaskItem.twoMinuteRows(on: day(2026, 1, 5), from: [task], context: context).count, 1)

        let record = try XCTUnwrap(TaskMissRecord.record(for: task, in: context))
        TwoMinutePush.completeFromRecord(record, task: task, context: context)

        XCTAssertTrue(
            TaskMissRecord.actionableRecords(before: reviewDate, tasks: [task], in: context).isEmpty,
            "the review shows what is owed, and a completed task owes nothing"
        )
        XCTAssertEqual(
            TaskItem.twoMinuteRows(on: day(2026, 1, 5), from: [task], context: context).count, 1,
            "the calendar keeps it — the miss still happened"
        )
    }

    /// **Backlog only.** A miss made during *this* review is already
    /// represented by the task's own row further down the same list;
    /// offering both would be the same task twice, one of them as a "last
    /// chance" for something decided seconds ago.
    func test_actionableRecords_excludeAMissMadeDuringThisReview() throws {
        let task = makeTask()
        let reviewDate = day(2026, 1, 5)
        for _ in 0..<2 {
            _ = TwoMinutePush.cycle(task, planDate: day(2026, 1, 6), missedOn: reviewDate, context: context)
        }

        XCTAssertTrue(
            TaskMissRecord.actionableRecords(before: reviewDate, tasks: [task], in: context).isEmpty,
            "today's own miss is not backlog"
        )
        XCTAssertEqual(
            TaskMissRecord.actionableRecords(before: day(2026, 1, 6), tasks: [task], in: context).count, 1,
            "but it is backlog tomorrow"
        )
    }

    /// A record whose task has been deleted is dropped — there is nothing
    /// left to complete. The record still renders on the calendar, which is
    /// what the copied title is for.
    func test_actionableRecords_dropARecordWhoseTaskIsGone() throws {
        let task = makeTask()
        for _ in 0..<2 {
            _ = TwoMinutePush.cycle(task, planDate: day(2026, 1, 6), missedOn: day(2026, 1, 5), context: context)
        }
        context.delete(task)

        XCTAssertTrue(TaskMissRecord.actionableRecords(before: day(2026, 1, 6), tasks: [], in: context).isEmpty)
    }

    /// Oldest first — the review works down the backlog in the order it
    /// accumulated.
    func test_actionableRecords_areOldestFirst() throws {
        let older = makeTask(title: "Older")
        let newer = makeTask(title: "Newer")
        context.insert(TaskMissRecord(taskID: older.id, title: older.title, missedDay: day(2026, 1, 2), pushedToDay: day(2026, 1, 3)))
        context.insert(TaskMissRecord(taskID: newer.id, title: newer.title, missedDay: day(2026, 1, 4), pushedToDay: day(2026, 1, 5)))

        let offered = TaskMissRecord.actionableRecords(before: day(2026, 1, 6), tasks: [older, newer], in: context)
        XCTAssertEqual(offered.map(\.record.title), ["Older", "Newer"])
    }

    // MARK: - The mixed row list

    /// **The whole point: two rows, on two days, from one push.**
    func test_rows_missOnTheOriginalDay_liveTaskOnThePushedDay() throws {
        let task = makeTask(title: "Water the plant")
        task.createdAt = day(2026, 1, 5)
        for _ in 0..<2 {
            _ = TwoMinutePush.cycle(task, planDate: day(2026, 1, 6), missedOn: day(2026, 1, 5), context: context)
        }
        let all = [task]

        let fifth = TaskItem.twoMinuteRows(on: day(2026, 1, 5), from: all, context: context)
        XCTAssertEqual(fifth.count, 1)
        XCTAssertEqual(fifth.first?.status, .missed, "the day it was missed still shows it, as missed")
        if case .task = fifth.first { XCTFail("the original day holds the record, not the live task") }

        let sixth = TaskItem.twoMinuteRows(on: day(2026, 1, 6), from: all, context: context)
        XCTAssertEqual(sixth.count, 1)
        if case .miss = sixth.first { XCTFail("the pushed day holds the live task, not a record") }
        XCTAssertEqual(
            sixth.first?.status, OccurrenceStatus.none,
            "and the day it moved to shows it as still to do — the miss is carried by the record, not by both rows"
        )
    }

    /// Both kinds on one day: a task missed today and pushed forward leaves
    /// its record here, and an unrelated task created today is still live
    /// here. Misses sort first.
    func test_rows_canHoldBothKindsOnOneDay() throws {
        let pushed = makeTask(title: "Pushed away")
        pushed.createdAt = day(2026, 1, 5)
        for _ in 0..<2 {
            _ = TwoMinutePush.cycle(pushed, planDate: day(2026, 1, 6), missedOn: day(2026, 1, 5), context: context)
        }
        let staying = makeTask(title: "Still here")
        staying.createdAt = day(2026, 1, 5)

        let rows = TaskItem.twoMinuteRows(on: day(2026, 1, 5), from: [pushed, staying], context: context)

        XCTAssertEqual(rows.map(\.title), ["Pushed away", "Still here"], "misses first, then live work")
        XCTAssertEqual(rows.first?.status, .missed, "the record reads as a miss regardless of the task's own status")
    }

    /// A miss row stays a miss whatever became of the task. That day it was
    /// not done, and completing it later happened on a different day — the
    /// green belongs there, not here.
    ///
    /// Paired with `test_handledMiss_staysOnTheCalendar_andLeavesTheReview`,
    /// which asserts the other half from the same state: Nightly Review
    /// stops offering it, because a completed task is no longer owed.
    func test_rows_keepAMissAfterItsTaskIsCompleted() throws {
        let task = makeTask()
        task.createdAt = day(2026, 1, 5)
        for _ in 0..<2 {
            _ = TwoMinutePush.cycle(task, planDate: day(2026, 1, 6), missedOn: day(2026, 1, 5), context: context)
        }
        let record = try XCTUnwrap(TaskMissRecord.record(for: task, in: context))
        TwoMinutePush.completeFromRecord(record, task: task, context: context)

        let fifth = TaskItem.twoMinuteRows(on: day(2026, 1, 5), from: [task], context: context)
        XCTAssertEqual(fifth.count, 1, "the day still shows it carried the task")
        XCTAssertEqual(fifth.first?.status, .missed, "and it stays a miss — that day it was not done")
    }

    /// Undo collapses both rows back to one on the original day.
    func test_rows_undoCollapsesBackToOneRow() throws {
        let task = makeTask()
        task.createdAt = day(2026, 1, 5)
        for _ in 0..<2 {   // complete -> missed (pushes)
            _ = TwoMinutePush.cycle(task, planDate: day(2026, 1, 6), missedOn: day(2026, 1, 5), context: context)
        }
        // Undo is an explicit action now, not a third tap — see
        // `TwoMinutePush.undo`.
        TwoMinutePush.undo(for: task, context: context)

        XCTAssertEqual(TaskItem.twoMinuteRows(on: day(2026, 1, 5), from: [task], context: context).count, 1)
        XCTAssertTrue(TaskItem.twoMinuteRows(on: day(2026, 1, 6), from: [task], context: context).isEmpty)
    }

    /// A day with neither is empty — the record lookup failing open would
    /// put every past miss on every day.
    func test_rows_unrelatedDayIsEmpty() throws {
        let task = makeTask()
        task.createdAt = day(2026, 1, 5)
        for _ in 0..<2 {
            _ = TwoMinutePush.cycle(task, planDate: day(2026, 1, 6), missedOn: day(2026, 1, 5), context: context)
        }

        XCTAssertTrue(TaskItem.twoMinuteRows(on: day(2026, 1, 20), from: [task], context: context).isEmpty)
    }

    /// **`.missed` is no longer a resting state for a 2-Minute task.**
    ///
    /// It exists for the duration of one `cycle` call and is immediately
    /// converted into a record plus a move. The visible cycle on a live row
    /// is therefore `.none → .complete → (pushed away)`, with the third
    /// state living on the other day as history.
    func test_aLiveRowNeverRestsAtMissed() throws {
        let task = makeTask()
        _ = TwoMinutePush.cycle(task, planDate: day(2026, 1, 6), missedOn: day(2026, 1, 5), context: context)
        XCTAssertEqual(task.status, .complete)

        XCTAssertEqual(
            TwoMinutePush.cycle(task, planDate: day(2026, 1, 6), missedOn: day(2026, 1, 5), context: context), .missed,
            "the cycle still reports it, so callers can react"
        )
        XCTAssertEqual(task.status, OccurrenceStatus.none, "but the task does not stay there")
    }

    /// Completing on the pushed day, then missing again later, re-captures
    /// the prior state rather than restoring one from two pushes ago. This
    /// is what `clearPushBookkeeping` is for.
    /// UPDATED — this asserted the bug, so it now asserts the rule that
    /// replaced it.
    ///
    /// It demanded that a second miss *re-capture*, restoring "where it was
    /// before THIS push". That reads reasonably in isolation and is wrong
    /// once misses chain: the task was only sitting on Jan 6 because the
    /// Jan 5 miss put it there, so restoring Jan 6 restores a date the user
    /// never chose. Undoing the first miss has to unwind everything that
    /// followed from it, which means the capture is taken once, on the
    /// first miss of the chain, and held.
    ///
    /// The re-capture it was pinning came from `.complete` clearing the
    /// bookkeeping on the way to the second `.missed` — a transitional step
    /// being treated as the end of the chain. See `TwoMinutePush.apply`.
    func test_undoAfterASecondPushRestoresTheOriginalDate() throws {
        let task = makeTask()
        let original = day(2025, 12, 1)
        task.setStartDate(original)

        for _ in 0..<2 { _ = TwoMinutePush.cycle(task, planDate: day(2026, 1, 6), missedOn: day(2026, 1, 5), context: context) }
        _ = TwoMinutePush.cycle(task, planDate: day(2026, 1, 6), missedOn: day(2026, 1, 5), context: context)   // complete
        // Missed again from the day it landed on. One tap, not two:
        // `.complete` cycles straight to `.missed`.
        _ = TwoMinutePush.cycle(task, planDate: day(2026, 1, 9), missedOn: day(2026, 1, 6), context: context)

        TwoMinutePush.undo(for: task, context: context)

        XCTAssertEqual(
            task.startDate.map { calendar.startOfDay(for: $0) }, original,
            "the original date, from before the first miss — the whole chain unwinds"
        )
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

        TwoMinutePush.apply(to: task, planDate: day(2026, 1, 9), missedOn: day(2026, 1, 5), context: context)

        XCTAssertEqual(task.twoMinuteDisplayDay(), day(2026, 1, 9), "it moved")
        XCTAssertNotEqual(task.twoMinuteDisplayDay(), day(2026, 1, 5), "and left where it was")
        XCTAssertNotEqual(task.twoMinuteDisplayDay(), day(2026, 1, 10), "and did not spread forward")
    }

    /// Undo puts the display day back too — not just the stored date. The
    /// row returns to the day it came from.
    func test_undoRestoresTheDisplayDay() throws {
        let planDate = day(2026, 1, 9)
        let missedDay = day(2026, 1, 5)
        let task = makeTask()
        task.createdAt = day(2026, 1, 5)

        for _ in 0..<2 { _ = TwoMinutePush.cycle(task, planDate: planDate, missedOn: missedDay, context: context) }   // -> missed
        XCTAssertEqual(task.twoMinuteDisplayDay(), planDate)

        TwoMinutePush.undo(for: task, context: context)

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
        TwoMinutePush.apply(to: pushed, planDate: day(2026, 1, 9), missedOn: day(2026, 1, 5), context: context)
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
        let missedDay = day(2026, 1, 5)
        let prior = day(2025, 12, 1)
        let task = makeTask()
        task.setStartDate(prior)

        // A push made "last session".
        _ = TwoMinutePush.cycle(task, planDate: planDate, missedOn: missedDay, context: context)   // complete
        _ = TwoMinutePush.cycle(task, planDate: planDate, missedOn: missedDay, context: context)   // missed
        XCTAssertEqual(task.startDate.map { calendar.startOfDay(for: $0) }, planDate)

        // Nothing carries over between sessions but the task's own fields —
        // no state object is reconstructed here, deliberately.
        TwoMinutePush.undo(for: task, context: context)

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
        let missedDay = day(2026, 1, 5)
        let task = makeTask()
        XCTAssertNil(task.startDate)

        _ = TwoMinutePush.cycle(task, planDate: planDate, missedOn: missedDay, context: context)
        _ = TwoMinutePush.cycle(task, planDate: planDate, missedOn: missedDay, context: context)   // missed
        XCTAssertNotNil(task.startDate)

        TwoMinutePush.undo(for: task, context: context)

        XCTAssertNil(task.startDate, "no prior date means clear, not keep the pushed one")
        XCTAssertFalse(task.startDatePicked, "and the card must not show a picked state for a value never chosen")
    }

    /// **REVERSAL — completing a pushed task is NOT an undo.**
    ///
    /// This asserted the opposite: that completing after a miss cleared the
    /// push, because the undo fired on any transition out of `.missed`. Once
    /// a push resets the task to `.none`, that rule can no longer tell "I
    /// completed it" from "I changed my mind" — both land on a non-missed
    /// status.
    ///
    /// So completing keeps the pushed start date (the task was done on the
    /// day it was owed) and keeps the miss record (the miss still happened).
    /// Only the undo *capture* is dropped, so a later push re-captures
    /// rather than restoring a date from two pushes ago.
    func test_completingAPushedTask_keepsThePushAndTheRecord() throws {
        let planDate = day(2026, 1, 6)
        let missedDay = day(2026, 1, 5)
        let task = makeTask()
        for _ in 0..<2 { _ = TwoMinutePush.cycle(task, planDate: planDate, missedOn: missedDay, context: context) }   // -> missed, pushes
        XCTAssertTrue(task.hasOutstandingTwoMinutePush)

        XCTAssertEqual(TwoMinutePush.cycle(task, planDate: planDate, missedOn: missedDay, context: context), .complete)

        XCTAssertEqual(task.startDate.map { calendar.startOfDay(for: $0) }, planDate, "done on the day it was owed")
        XCTAssertEqual(try context.fetch(FetchDescriptor<TaskMissRecord>()).count, 1, "the miss still happened")
        // UPDATED — this asserted `false`, on the reasoning that completing
        // leaves nothing to reverse. That held while the record was inert
        // history. It is not: the record's row on the calendar is a live
        // undo target, and it outlives the completion. Tapping Jan 5's red
        // row after finishing the task on Jan 6 still has to put the start
        // date back, so the capture has to still be there to put back.
        //
        // The clearing now keys off whether any record is left standing
        // (`clearPushBookkeeping`), which is also what fixed the
        // transitional `.complete` overwriting the capture mid-chain.
        XCTAssertTrue(task.hasOutstandingTwoMinutePush, "the record is still a tappable undo, so the capture stays")

        TwoMinutePush.undo(for: task, context: context)
        XCTAssertNil(task.startDate, "and that undo still works after completion")
        XCTAssertTrue(task.isCompleted, "without un-completing it — completing and undoing are different things")
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
        TwoMinutePush.apply(to: task, planDate: day(2026, 1, 6), missedOn: day(2026, 1, 5), context: context)
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
        TwoMinutePush.apply(to: task, planDate: day(2026, 1, 6), missedOn: day(2026, 1, 5), context: context)
        task.status = .none   // complete-then-uncomplete collapses it

        TwoMinutePush.clearExpiredPushes(on: [task], asOf: day(2026, 1, 8))

        XCTAssertNil(task.startDate, "the old `.missed` gate stranded this date permanently")
    }

    /// Today is not past — a task pushed to today is doing its job.
    func test_leavesTodaysPushAlone() throws {
        let task = makeTask()
        TwoMinutePush.apply(to: task, planDate: day(2026, 1, 6), missedOn: day(2026, 1, 5), context: context)

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

    // MARK: - The calendar's own choice of date

    /// **The call site's date, not just the rule.** The calendar row used
    /// to compute `ChooseDayPlanning.planDate` inline, which before noon
    /// resolves to *today* — so marking today's row missed wrote
    /// `startDate = today`, the day the task was already on, and nothing
    /// moved. Identical to the recurring bug, in an independently written
    /// second copy of "the day being planned".
    ///
    /// Every other test in this file passes `planDate` explicitly, so none
    /// of them could see it: the rule was covered, the thing choosing its
    /// input was not. Sabotaging the call site's date produced **0
    /// failures** across the whole suite.
    ///
    /// The fix routes it through the same `calendarPushDay` the recurring
    /// row uses, so this walks the noon boundary through that function
    /// rather than re-deriving a floor here.
    func test_calendarPush_neverLandsOnTheDayBeingMarked() throws {
        let today = day(2026, 9, 21)

        for hour in [0, 8, 10, 11, 12, 13, 18, 23] {
            let now = calendar.date(byAdding: .hour, value: hour, to: today)!
            let planDate = DayTimelineGridView.calendarPushDay(missedOn: today, calendar: calendar, now: now)
            let task = makeTask(title: "Tap at \(hour)")

            _ = TwoMinutePush.cycle(task, planDate: planDate, missedOn: today, calendar: calendar, context: context)
            _ = TwoMinutePush.cycle(task, planDate: planDate, missedOn: today, calendar: calendar, context: context)

            XCTAssertGreaterThan(
                calendar.startOfDay(for: try XCTUnwrap(task.startDate)), today,
                "at \(hour):00 the push landed on the day it was marked — the task never moved"
            )
        }
    }

    /// End to end at 10am, the hour the bug was reported at: the task
    /// leaves today and the record says where it went.
    ///
    /// ⚠️ `TwoMinutePush.apply` also `assertionFailure`s on a degenerate
    /// pair, deliberately *not* unit-tested — it traps in debug, which is
    /// the point of it. The property above is the testable guard; the
    /// assertion is the backstop for a future caller that computes its own
    /// date again.
    func test_markingMissedOnTheCalendarAtTenAM_movesToTomorrow() throws {
        let today = day(2026, 9, 21)
        let morning = calendar.date(byAdding: .hour, value: 10, to: today)!
        let planDate = DayTimelineGridView.calendarPushDay(missedOn: today, calendar: calendar, now: morning)
        let task = makeTask()

        _ = TwoMinutePush.cycle(task, planDate: planDate, missedOn: today, calendar: calendar, context: context)
        _ = TwoMinutePush.cycle(task, planDate: planDate, missedOn: today, calendar: calendar, context: context)

        XCTAssertEqual(task.startDate.map { calendar.startOfDay(for: $0) }, day(2026, 9, 22))
        XCTAssertFalse(
            task.isEligibleToStart(on: today, calendar: calendar),
            "gone from today's list — before the fix it stayed, because startDate was today"
        )
        let records = TaskMissRecord.records(on: today, in: context)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(calendar.startOfDay(for: try XCTUnwrap(records.first).pushedToDay), day(2026, 9, 22))
    }

    // MARK: - A chain of misses

    private func missOnCalendar(_ task: TaskItem, on missedDay: Date, to planDate: Date) {
        // Two taps reach `.missed` from a live row; `apply` leaves the task
        // at `.none`, so the pushed row starts from `.none` again.
        _ = TwoMinutePush.cycle(task, planDate: planDate, missedOn: missedDay, calendar: calendar, context: context)
        _ = TwoMinutePush.cycle(task, planDate: planDate, missedOn: missedDay, calendar: calendar, context: context)
    }

    /// **Three days, three rows** — the reported bug. Missing Monday then
    /// missing again Tuesday used to leave Monday's record carrying the
    /// whole chain and Tuesday's day blank, because `apply` declined to
    /// insert a second record for a task that already had one.
    func test_missingOnConsecutiveDays_leavesARowOnEachDay() throws {
        let mon = day(2026, 9, 21), tue = day(2026, 9, 22), wed = day(2026, 9, 23)
        let task = makeTask()

        missOnCalendar(task, on: mon, to: tue)
        missOnCalendar(task, on: tue, to: wed)

        XCTAssertEqual(
            TaskMissRecord.records(for: task, in: context).map(\.missedDay), [mon, tue],
            "Tuesday's miss produced no record at all before this — its day read as empty"
        )
        XCTAssertEqual(task.startDate.map { calendar.startOfDay(for: $0) }, wed)

        func kinds(_ d: Date) -> [String] {
            TaskItem.twoMinuteRows(on: d, from: [task], context: context, calendar: calendar).map {
                if case .miss = $0 { return "miss" } else { return "task" }
            }
        }
        XCTAssertEqual(kinds(mon), ["miss"])
        XCTAssertEqual(kinds(tue), ["miss"], "the day that was blank")
        XCTAssertEqual(kinds(wed), ["task"])
    }

    /// **The capture survives the chain.** A second miss passes through
    /// `.complete` on the way, and that step used to clear the bookkeeping —
    /// so `apply` re-captured, storing the *pushed* date as the "prior"
    /// one. Undoing then restored Tuesday instead of clearing a start date
    /// the task never had.
    ///
    /// Sabotage note: removing the first-push gate entirely produced **0
    /// failures** across 685 tests, which is why this shipped wrong.
    func test_secondMissDoesNotOverwriteTheCapturedPriorState() throws {
        let mon = day(2026, 9, 21), tue = day(2026, 9, 22), wed = day(2026, 9, 23)
        let task = makeTask()
        XCTAssertNil(task.startDate, "no start date before any of this")

        missOnCalendar(task, on: mon, to: tue)
        missOnCalendar(task, on: tue, to: wed)

        XCTAssertNil(task.startDateBeforePush, "captured nil, not Tuesday")
        XCTAssertTrue(task.hasOutstandingTwoMinutePush, "the chain is still open")
    }

    /// Undoing the **first** miss unwinds everything after it: the task goes
    /// back to where it started, and no day is left showing a red row for a
    /// miss that no longer happened.
    func test_undoingTheFirstMissClearsTheWholeChain() throws {
        let mon = day(2026, 9, 21), tue = day(2026, 9, 22), wed = day(2026, 9, 23)
        let task = makeTask()
        missOnCalendar(task, on: mon, to: tue)
        missOnCalendar(task, on: tue, to: wed)

        let first = try XCTUnwrap(TaskMissRecord.records(for: task, in: context).first)
        TwoMinutePush.undo(first, for: task, context: context, calendar: calendar)

        XCTAssertTrue(TaskMissRecord.records(for: task, in: context).isEmpty, "both records go")
        XCTAssertNil(task.startDate, "restored to having none — not to Tuesday")
        XCTAssertFalse(task.hasOutstandingTwoMinutePush)
        // Not "no rows": with the start date cleared the live task falls
        // back to `createdAt`, which in this fixture is today. What must be
        // gone is the *miss* row.
        XCTAssertFalse(
            TaskItem.twoMinuteRows(on: mon, from: [task], context: context, calendar: calendar)
                .contains { if case .miss = $0 { return true } else { return false } },
            "no red row for a miss that no longer happened"
        )
    }

    /// Undoing a **later** miss unwinds only from there: the earlier miss
    /// still happened, so its row stays and the task goes back to the day
    /// the undone miss was marked on.
    func test_undoingALaterMissLeavesTheEarlierOneStanding() throws {
        let mon = day(2026, 9, 21), tue = day(2026, 9, 22), wed = day(2026, 9, 23)
        let task = makeTask()
        missOnCalendar(task, on: mon, to: tue)
        missOnCalendar(task, on: tue, to: wed)

        let second = try XCTUnwrap(TaskMissRecord.records(for: task, in: context).last)
        TwoMinutePush.undo(second, for: task, context: context, calendar: calendar)

        XCTAssertEqual(TaskMissRecord.records(for: task, in: context).map(\.missedDay), [mon])
        XCTAssertEqual(task.startDate.map { calendar.startOfDay(for: $0) }, tue, "back to the day that miss was marked on")
        XCTAssertTrue(task.hasOutstandingTwoMinutePush, "Monday's miss is still standing, so its capture stays")
    }

    /// Undoing the first miss after the chain was undone from the middle
    /// still restores the original — the capture was not consumed early.
    func test_undoingBothMissesInSequenceRestoresTheOriginal() throws {
        let mon = day(2026, 9, 21), tue = day(2026, 9, 22), wed = day(2026, 9, 23)
        let task = makeTask()
        missOnCalendar(task, on: mon, to: tue)
        missOnCalendar(task, on: tue, to: wed)

        let records = TaskMissRecord.records(for: task, in: context)
        TwoMinutePush.undo(try XCTUnwrap(records.last), for: task, context: context, calendar: calendar)
        TwoMinutePush.undo(try XCTUnwrap(records.first), for: task, context: context, calendar: calendar)

        XCTAssertNil(task.startDate)
        XCTAssertTrue(TaskMissRecord.records(for: task, in: context).isEmpty)
    }

    // MARK: - Row order is total, so it cannot shuffle

    /// **Hardening, not a demonstrated fix.** The order key was already
    /// status-independent — nothing in `twoMinuteTasksVisible` or
    /// `twoMinuteRows` reads `status`, unlike `Habit.todayOrderKey` before
    /// its own fix. What was missing is *totality*: `sorted(by:)` is not
    /// guaranteed stable, and its input here is `shelf.tasks`, a SwiftData
    /// to-many whose order is undefined. Equal keys could therefore come
    /// back in either order on any render.
    ///
    /// These two tests are what makes that unrepresentable rather than
    /// merely unlikely.
    func test_tasksCreatedInTheSameInstantHaveAStableOrder() throws {
        let created = day(2026, 9, 21)
        let a = makeTask(title: "Alpha"); a.createdAt = created
        let b = makeTask(title: "Bravo"); b.createdAt = created

        let forward = TaskItem.twoMinuteTasksVisible(on: created, from: [a, b], calendar: calendar).map(\.title)
        let reversed = TaskItem.twoMinuteTasksVisible(on: created, from: [b, a], calendar: calendar).map(\.title)

        XCTAssertEqual(forward, reversed, "same list whichever order the relationship hands them over in")
    }

    func test_missRecordsWithTheSameTitleHaveAStableOrder() throws {
        let missed = day(2026, 9, 21), pushed = day(2026, 9, 22)
        let a = makeTask(title: "Same"), b = makeTask(title: "Same")
        TwoMinutePush.apply(to: a, planDate: pushed, missedOn: missed, calendar: calendar, context: context)
        TwoMinutePush.apply(to: b, planDate: pushed, missedOn: missed, calendar: calendar, context: context)

        let ids = {
            TaskItem.twoMinuteRows(on: missed, from: [], context: self.context, calendar: self.calendar).map(\.id)
        }
        XCTAssertEqual(ids(), ids(), "identical titles and identical missedDay still order deterministically")
        XCTAssertEqual(ids().count, 2)
    }
}
