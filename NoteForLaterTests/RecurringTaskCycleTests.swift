import XCTest
import SwiftData
@testable import NoteForLater

/// Coverage for recurring tasks getting the same tap-through cycle habits
/// already have, per the four decisions this was built against:
///
/// 1. `RecurringTaskLog` now stores a real `status: OccurrenceStatus`
///    (backed by `statusRaw: String`, same raw-value pattern
///    `Habit.occurrenceTimeModesRaw` uses), not just `isCompleted: Bool`.
/// 2. AM/Midday/PM and Specific-Time behave identically — both route
///    through this same log (`TaskItem.cycleRecurringOccurrence`);
///    `ScheduledBlock.isCompleted` is a mirror only, never truth.
/// 3. The cycle is `none -> complete -> missed -> none` — no `.excused`.
/// 4. Landing on `.missed` creates a real `PushedRecurringOccurrence`
///    immediately (`ScheduleReviewViewModel.pushRecurringOccurrenceIfNeeded`),
///    not a display-only projection.
///
/// The orphaned-completion fix in docs/session-handoff.md (a projected
/// Specific-Time completion, written to `RecurringTaskLog` before a real
/// block existed, used to get silently lost once a real block was
/// generated — `AISchedulingService.placeHabitsAndRecurringTasks` now
/// seeds a fresh block's `isCompleted` from the log) isn't covered here:
/// a minimal-fixture call into the full scheduling pipeline crashed on a
/// pre-existing SwiftData issue unrelated to this two-line fix, so it's
/// verified by direct code review instead of a test in this file.
///
/// Also pins the contradiction-D dedup: an interactive missed-tap and
/// the commit-time sweep (`pushMissedRecurringOccurrences`) must never
/// both push the same
/// task.
final class RecurringTaskCycleTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth))!
    }

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self,
                SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self,
                Habit.self, HabitLog.self, MealSelection.self, Recipe.self,
                PushRecursionWarning.self, RecurringTaskLog.self, PushedRecurringOccurrence.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    private func makeUntimedTask(anchor: Date, mode: HabitOccurrenceTimeMode = .midday) -> TaskItem {
        let task = TaskItem(title: "Review Monarch Expenses", dueDate: anchor, estimatedMinutes: 30)
        task.isRecurring = true
        task.recurrenceUnit = .months
        task.recurrenceIntervalCount = 1
        task.recurrenceTimeMode = mode
        context.insert(task)
        return task
    }

    private func makeSpecificTimeTask(anchor: Date) -> TaskItem {
        let task = TaskItem(title: "Pay rent", dueDate: anchor, estimatedMinutes: 15)
        task.isRecurring = true
        task.recurrenceUnit = .months
        task.recurrenceIntervalCount = 1
        task.recurrenceTimeMode = .specific
        context.insert(task)
        return task
    }

    // MARK: - Decision 3: three-state cycle, no excused

    func test_cycleRecurringOccurrence_advancesThroughThreeStates_andWraps() {
        let day = day(2026, 9, 9)
        let task = makeUntimedTask(anchor: day)

        XCTAssertEqual(task.cycleRecurringOccurrence(on: day, context: context, calendar: calendar), .complete)
        XCTAssertEqual(task.cycleRecurringOccurrence(on: day, context: context, calendar: calendar), .missed)
        XCTAssertEqual(task.cycleRecurringOccurrence(on: day, context: context, calendar: calendar), .none, "must wrap straight back to none — no .excused in a task's cycle")
        XCTAssertEqual(task.cycleRecurringOccurrence(on: day, context: context, calendar: calendar), .complete, "the wrap must repeat cleanly on a second lap")
    }

    // MARK: - Decision 2: both time modes behave identically

    func test_cycleRecurringOccurrence_specificTimeMode_mirrorsIntoBlock_butLogIsTruth() {
        let anchor = day(2026, 9, 1)
        let task = makeSpecificTimeTask(anchor: anchor)
        let block = ScheduledBlock(date: anchor, startTime: anchor, endTime: anchor.addingTimeInterval(900), task: task)
        context.insert(block)

        XCTAssertEqual(task.cycleRecurringOccurrence(on: anchor, context: context, calendar: calendar), .complete)
        XCTAssertTrue(block.isCompleted, "the linked block should mirror .complete")

        XCTAssertEqual(task.cycleRecurringOccurrence(on: anchor, context: context, calendar: calendar), .missed)
        XCTAssertFalse(block.isCompleted, "missed is not complete — the block mirror must reflect that")
        XCTAssertEqual(RecurringTaskLog.log(taskID: task.id, on: anchor, context: context, calendar: calendar)?.status, .missed, "the log, not the block, is what actually carries .missed")
    }

    // MARK: - Decision 4 + fail-then-pass #1: missed creates a push immediately

    /// Fail-then-pass target #1 ("missed-creates-a-push"): with
    /// `pushRecurringOccurrenceIfNeeded` temporarily forced to never
    /// create a record, this failed — confirmed via `xcodebuild test`,
    /// see the commit message. Restored, confirmed passing.
    func test_missedOccurrence_createsPushedRecurringOccurrence_immediately() {
        let day = day(2026, 9, 9)
        let task = makeUntimedTask(anchor: day)

        let status = task.cycleRecurringOccurrence(on: day, context: context, calendar: calendar)
        XCTAssertEqual(status, .complete)
        let next = task.cycleRecurringOccurrence(on: day, context: context, calendar: calendar)
        XCTAssertEqual(next, .missed)

        // This is the exact call `NightlyReviewView.pushIfMissed` makes
        // the instant a cycle lands on `.missed` — not deferred to Next.
        let pushed = ScheduleReviewViewModel.pushRecurringOccurrenceIfNeeded(task: task, missedDay: day, context: context)
        XCTAssertNotNil(pushed, "marking missed must create a real push record immediately")

        let allPushes = (try? context.fetch(FetchDescriptor<PushedRecurringOccurrence>())) ?? []
        XCTAssertEqual(allPushes.count, 1)
        XCTAssertEqual(allPushes.first?.taskID, task.id)
        XCTAssertFalse(allPushes.first?.isCompleted ?? true)
    }

    // MARK: - Contradiction D + fail-then-pass #2: no duplicate push

    /// Fail-then-pass target #2 ("no-duplicate-row"): with the
    /// "already pushed" guard in `pushRecurringOccurrenceIfNeeded`
    /// temporarily disabled, this failed — two records existed instead
    /// of one — confirmed via `xcodebuild test`, see the commit message.
    /// Restored, confirmed passing.
    ///
    /// Simulates the exact sequence decision 4 introduces, using a
    /// Specific-Time task deliberately: cycling to `.missed` mirrors
    /// `block.isCompleted = false` (already false), so the commit-time
    /// sweep's block-scoped loop — which only ever checks
    /// `!block.isCompleted`, never the log's own status — still sees this
    /// block as a candidate and tries to push it again. Only the shared
    /// "already pushed" guard in `pushRecurringOccurrenceIfNeeded` is
    /// what stops a second record. (An untimed task doesn't exercise
    /// this: the sweep's other loop sources candidates from
    /// `openRecurringTaskOccurrencesForReview`, which is already
    /// `.none`-only, so an already-missed untimed occurrence is filtered
    /// out before the guard ever gets a chance to matter.)
    func test_interactivePush_thenCommitTimeSweep_doesNotDoublePush() {
        let anchor = day(2026, 9, 9)
        let task = makeSpecificTimeTask(anchor: anchor)
        let block = ScheduledBlock(date: anchor, startTime: anchor, endTime: anchor.addingTimeInterval(900), task: task)
        context.insert(block)

        // The interactive tap: cycle to missed, push immediately.
        _ = task.cycleRecurringOccurrence(on: anchor, context: context, calendar: calendar) // .complete
        _ = task.cycleRecurringOccurrence(on: anchor, context: context, calendar: calendar) // .missed
        let interactivePush = ScheduleReviewViewModel.pushRecurringOccurrenceIfNeeded(task: task, missedDay: anchor, context: context)
        XCTAssertNotNil(interactivePush)

        // The commit-time sweep, run afterward in the same session,
        // exactly as `advance()` does on Next.
        let cutoff = anchor.addingTimeInterval(86400)
        let created = ScheduleReviewViewModel.pushMissedRecurringOccurrences(
            reviewedBlocks: [block], tasks: [task], context: context, cutoff: cutoff
        )

        XCTAssertTrue(created.isEmpty, "the sweep must not create a second record for a task the interactive tap already pushed")
        let allPushes = (try? context.fetch(FetchDescriptor<PushedRecurringOccurrence>())) ?? []
        XCTAssertEqual(allPushes.count, 1, "exactly one push record must exist, not two")
    }

    /// The sweep's own new responsibility (mirroring
    /// `markUnresolvedHabitOccurrencesAsMissed`): every occurrence it
    /// processes gets `.missed` written to its log, not just a push
    /// record with the log silently left at `.none`.
    func test_pushMissedRecurringOccurrences_writesMissedStatus_toLog() {
        let anchor = day(2026, 8, 31)
        let task = makeUntimedTask(anchor: anchor)
        let cutoff = day(2026, 9, 1)

        _ = ScheduleReviewViewModel.pushMissedRecurringOccurrences(
            reviewedBlocks: [], tasks: [task], context: context, cutoff: cutoff
        )

        XCTAssertEqual(RecurringTaskLog.log(taskID: task.id, on: anchor, context: context, calendar: calendar)?.status, .missed)
    }

    // MARK: - Operational vs. display list (mirrors the habit split)

    /// Guardrail, same purpose as the habit equivalent: pins
    /// `openRecurringTaskOccurrencesForReview` (the operational list) to
    /// `.none` only, so a future widening for display purposes fails
    /// this test instead of silently reopening the untimed-path
    /// protection this mirrors from the habit side.
    func test_openRecurringTaskOccurrencesForReview_onlyEverReturnsNoneStatus() {
        let reviewDay = day(2026, 9, 9)
        let completedTask = makeUntimedTask(anchor: reviewDay, mode: .am)
        _ = completedTask.cycleRecurringOccurrence(on: reviewDay, context: context, calendar: calendar)
        let missedTask = makeUntimedTask(anchor: reviewDay, mode: .midday)
        _ = missedTask.cycleRecurringOccurrence(on: reviewDay, context: context, calendar: calendar)
        _ = missedTask.cycleRecurringOccurrence(on: reviewDay, context: context, calendar: calendar)
        let noneTask = makeUntimedTask(anchor: reviewDay, mode: .pm)

        let result = ScheduleReviewViewModel.openRecurringTaskOccurrencesForReview(
            tasks: [completedTask, missedTask, noneTask], context: context, upTo: reviewDay.addingTimeInterval(86400), calendar: calendar
        )

        XCTAssertTrue(result.allSatisfy { $0.status == .none })
        XCTAssertEqual(result.map(\.task.id), [noneTask.id])
    }

    func test_allRecurringTaskOccurrencesForReview_completedBeforeReviewOpened_stillAppears() {
        let reviewDay = day(2026, 9, 9)
        let task = makeUntimedTask(anchor: reviewDay, mode: .am)
        _ = task.cycleRecurringOccurrence(on: reviewDay, context: context, calendar: calendar)

        let result = ScheduleReviewViewModel.allRecurringTaskOccurrencesForReview(
            tasks: [task], context: context, upTo: reviewDay.addingTimeInterval(86400), completedSince: nil, calendar: calendar
        )

        XCTAssertEqual(result.first(where: { calendar.isDate($0.targetTime, inSameDayAs: reviewDay) })?.status, .complete)
    }

    func test_unresolvedRecurringTaskOccurrences_filtersToNoneOnly() {
        let reviewDay = day(2026, 9, 9)
        let task = makeUntimedTask(anchor: reviewDay)
        let all = ScheduleReviewViewModel.allRecurringTaskOccurrencesForReview(
            tasks: [task], context: context, upTo: reviewDay.addingTimeInterval(86400), completedSince: nil, calendar: calendar
        )
        XCTAssertEqual(ScheduleReviewViewModel.unresolvedRecurringTaskOccurrences(all).count, 1)

        _ = task.cycleRecurringOccurrence(on: reviewDay, context: context, calendar: calendar)
        let allAfter = ScheduleReviewViewModel.allRecurringTaskOccurrencesForReview(
            tasks: [task], context: context, upTo: reviewDay.addingTimeInterval(86400), completedSince: nil, calendar: calendar
        )
        XCTAssertTrue(ScheduleReviewViewModel.unresolvedRecurringTaskOccurrences(allAfter).isEmpty)
    }

    func test_unresolvedRecurringTaskBlocks_ignoresNonRecurringBlocks() {
        let anchor = day(2026, 9, 1)
        let recurringTask = makeSpecificTimeTask(anchor: anchor)
        let recurringBlock = ScheduledBlock(date: anchor, startTime: anchor, endTime: anchor.addingTimeInterval(900), task: recurringTask)
        context.insert(recurringBlock)

        let ordinaryTask = TaskItem(title: "Ordinary", estimatedMinutes: 30)
        context.insert(ordinaryTask)
        let ordinaryBlock = ScheduledBlock(date: anchor, startTime: anchor, endTime: anchor.addingTimeInterval(1800), task: ordinaryTask)
        context.insert(ordinaryBlock)

        let result = ScheduleReviewViewModel.unresolvedRecurringTaskBlocks([recurringBlock, ordinaryBlock], context: context, calendar: calendar)
        XCTAssertEqual(result.map(\.id), [recurringBlock.id], "an ordinary, non-recurring block must never be gated")
    }
}
