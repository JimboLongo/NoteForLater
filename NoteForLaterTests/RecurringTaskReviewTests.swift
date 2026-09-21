import XCTest
import SwiftData
@testable import NoteForLater

/// Regression coverage for two Nightly Review gaps in the recurring-task
/// push chain (see `PushedRecurringOccurrence`):
///
/// 1. An AM/Midday/PM recurring `TaskItem` never gets a `ScheduledBlock`,
///    so the old `reviewedBlocks`-only capture loop in `NightlyReviewView`
///    could never see one — a miss simply evaporated, no
///    `PushedRecurringOccurrence` ever created. Fixed by
///    `ScheduleReviewViewModel.openRecurringTaskOccurrencesForReview` /
///    `pushMissedRecurringOccurrences`, sourced from `RecurringTaskLog`
///    instead of a block.
/// 2. A record created by Nightly Review only ever got relocated onto
///    tomorrow's calendar at the *next app launch*
///    (`NoteForLaterApp.processPushedRecurringOccurrencesIfNeeded`), never
///    during the review itself — so a miss couldn't show up on the
///    Tomorrow step the same night it happened. Fixed by extracting the
///    per-day hop into `PushedRecurringOccurrence.advanceOneHop`, shared
///    between the launch-time catch-up loop and one immediate call from
///    Nightly Review's today→tomorrow `Task`.
final class RecurringTaskReviewTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    /// Same reasoning as `SchedulingEngineTests`/`HabitRollingStatsTests` —
    /// fixed zone so this doesn't depend on the machine running it.
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

    /// Monthly Midday recurring task, anchored on Aug 31 (a real
    /// recurrence day for a monthly-on-the-31st pattern), never completed
    /// — the exact "Review Monarch Expenses" shape pulled from the live
    /// device store during the investigation this fixes.
    private func makeMiddayRecurringTask(anchor: Date) -> TaskItem {
        let task = TaskItem(title: "Review Monarch Expenses", dueDate: anchor, estimatedMinutes: 30)
        task.isRecurring = true
        task.recurrenceUnit = .months
        task.recurrenceIntervalCount = 1
        task.recurrenceTimeMode = .midday
        context.insert(task)
        return task
    }

    // MARK: - Gap 1: the miss must actually be captured

    /// **REVERSAL — an untimed occurrence the user never touched is no
    /// longer captured or pushed at the commit.**
    ///
    /// This was "Gap 1's regression case": the commit's untimed arm existed
    /// specifically to sweep `.none` occurrences into `.missed` and push
    /// them, and this test pinned that with six assertions. It was correct
    /// when `.none` was the only non-complete state. Now `.missed` is an
    /// explicit decision, and only an explicit decision pushes — so the
    /// untimed arm is gone entirely rather than filtered
    /// (`openRecurringTaskOccurrencesForReview` returns `.none` occurrences
    /// only, so a filtered call would be a permanent no-op dressed as logic).
    ///
    /// Inverted in place rather than deleted: the situation it constructs —
    /// an untimed recurring task with no log at all, exactly the on-device
    /// state it was written from — is still the case that matters most. Only
    /// the expected outcome flipped.
    ///
    /// Nothing is lost by this. An occurrence marked `.missed` interactively
    /// already pushed at the moment of the tap
    /// (`NightlyReviewView.pushIfMissed`), and an untouched one resurfaces as
    /// backlog in the Today step, which walks back 400 days.
    func test_pushMissedRecurringOccurrences_doesNotCaptureAnUntouchedMiddayOccurrence() throws {
        let anchor = day(2026, 8, 31)
        let task = makeMiddayRecurringTask(anchor: anchor)
        let cutoff = day(2026, 9, 1)

        // No `RecurringTaskLog` at all — the task was never touched,
        // exactly the state found on-device.
        let created = ScheduleReviewViewModel.pushMissedRecurringOccurrences(
            reviewedBlocks: [], // AM/Midday/PM: no ScheduledBlock ever exists for this task
            tasks: [task],
            context: context,
            cutoff: cutoff,
            plannedDay: cutoff
        )

        XCTAssertTrue(created.isEmpty, "never looked at is not the same as missed")
        XCTAssertNil(
            RecurringTaskLog.log(taskID: task.id, on: anchor, context: context, calendar: calendar)?.status,
            "the commit must not write a decision the user did not make"
        )
        XCTAssertTrue(try context.fetch(FetchDescriptor<PushedRecurringOccurrence>()).isEmpty)
    }

    /// The other half of the reversal: an occurrence the user *did* mark
    /// missed still pushes at the commit. Without this the change above
    /// could be satisfied by the sweep doing nothing at all.
    ///
    /// Uses a block-backed task because that is the only arm left — the
    /// untimed arm is gone, and an untimed occurrence marked `.missed`
    /// interactively has already pushed via `pushIfMissed`.
    func test_pushMissedRecurringOccurrences_stillPushesAnExplicitlyMissedBlock() throws {
        let anchor = day(2026, 8, 31)
        let task = makeMiddayRecurringTask(anchor: anchor)
        let block = ScheduledBlock(date: anchor, startTime: anchor, endTime: anchor.addingTimeInterval(900), task: task)
        context.insert(block)
        block.status = .missed

        let created = ScheduleReviewViewModel.pushMissedRecurringOccurrences(
            reviewedBlocks: [block], tasks: [task], context: context, cutoff: day(2026, 9, 1), plannedDay: day(2026, 9, 1)
        )

        XCTAssertEqual(created.count, 1, "an explicit miss still pushes")
        XCTAssertEqual(created.first?.task.id, task.id)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PushedRecurringOccurrence>()).count, 1)
    }

    /// The block arm's own half of the reversal: a recurring task's block
    /// left merely **unmarked** must not push either.
    ///
    /// Added because sabotage found this uncovered — reverting the block
    /// arm's filter from `status == .missed` back to `!isCompleted` left all
    /// 632 tests green. `ScheduledBlock.isCompleted` is `status ==
    /// .complete`, so `!isCompleted` silently means "including never looked
    /// at", the same lossy read that produced three separate bugs this
    /// session.
    func test_pushMissedRecurringOccurrences_doesNotPushAnUnmarkedBlock() throws {
        let anchor = day(2026, 8, 31)
        let task = makeMiddayRecurringTask(anchor: anchor)
        let block = ScheduledBlock(date: anchor, startTime: anchor, endTime: anchor.addingTimeInterval(900), task: task)
        context.insert(block)
        XCTAssertEqual(block.status, OccurrenceStatus.none, "untouched, which reads !isCompleted just like a real miss")

        let created = ScheduleReviewViewModel.pushMissedRecurringOccurrences(
            reviewedBlocks: [block], tasks: [task], context: context, cutoff: day(2026, 9, 1), plannedDay: day(2026, 9, 1)
        )

        XCTAssertTrue(created.isEmpty, "an unmarked block is not a miss")
        XCTAssertNil(
            RecurringTaskLog.log(taskID: task.id, on: anchor, context: context, calendar: calendar)?.status,
            "and the commit must not write .missed to its log"
        )
        XCTAssertTrue(try context.fetch(FetchDescriptor<PushedRecurringOccurrence>()).isEmpty)
    }

    /// A completed occurrence (real `RecurringTaskLog`, `isCompleted: true`)
    /// must never be pushed — the read side of the fix has to go through
    /// `RecurringTaskLog.log(taskID:on:context:)`, never a relationship, or
    /// a completion made moments earlier in the same review session could
    /// be missed by a stale read and get pushed anyway.
    func test_pushMissedRecurringOccurrences_skipsCompletedOccurrence() {
        let anchor = day(2026, 8, 31)
        let task = makeMiddayRecurringTask(anchor: anchor)
        let cutoff = day(2026, 9, 1)

        let log = RecurringTaskLog.logOrCreate(taskID: task.id, on: anchor, context: context, calendar: calendar)
        log.status = .complete

        let created = ScheduleReviewViewModel.pushMissedRecurringOccurrences(
            reviewedBlocks: [], tasks: [task], context: context, cutoff: cutoff, plannedDay: cutoff
        )
        XCTAssertTrue(created.isEmpty)
    }

    /// A task already mid-chain (an unresolved `PushedRecurringOccurrence`
    /// from an earlier miss) must not get a second record — same
    /// "already pushed" guard the original block-only loop had.
    func test_pushMissedRecurringOccurrences_skipsAlreadyPushedTask() {
        let anchor = day(2026, 6, 30)
        let task = makeMiddayRecurringTask(anchor: anchor)
        context.insert(PushedRecurringOccurrence(taskID: task.id, originalDate: anchor))

        let created = ScheduleReviewViewModel.pushMissedRecurringOccurrences(
            reviewedBlocks: [], tasks: [task], context: context, cutoff: day(2026, 9, 1), plannedDay: day(2026, 9, 1)
        )
        XCTAssertTrue(created.isEmpty)

        let pending = try? context.fetch(FetchDescriptor<PushedRecurringOccurrence>())
        XCTAssertEqual(pending?.count, 1, "should still be exactly the one pre-existing record, not two")
    }

    // MARK: - advanceOneHop: what survives the removal of Specific Time

    // MARK: - A push lands where it is owed, and stays there

    /// **REVERSAL — `advanceOneHop` is gone, and these two tests replace
    /// the pair that pinned it.**
    ///
    /// A record used to be created at the day of the miss and walked
    /// forward one day at a time — by the app-launch catch-up routine, and
    /// by an immediate one-hop call from each interactive surface. That made
    /// a miss found several days late land the day *after* the miss, still
    /// in the past, and crawl from there.
    ///
    /// It now lands on the day being planned at creation, and nothing moves
    /// it. Both halves of the deleted function are still pinned, just
    /// earlier: the destination by `test_pushLandsOnThePlannedDay`, and the
    /// resolve-on-a-recurrence-day half by
    /// `test_noRecordWhenThePlannedDayAlreadyRecurs` — which is now a
    /// question asked once at creation rather than re-checked on every hop.
    func test_pushLandsOnThePlannedDay_notTheDayAfterTheMiss() throws {
        let anchor = day(2026, 8, 31)
        let task = makeMiddayRecurringTask(anchor: anchor)
        // Missed a while back; the review being run is planning much later.
        let plannedDay = day(2026, 9, 12)

        let pushed = try XCTUnwrap(ScheduleReviewViewModel.pushRecurringOccurrenceIfNeeded(
            task: task, missedDay: anchor, plannedDay: plannedDay, context: context
        ))

        XCTAssertEqual(calendar.startOfDay(for: pushed.currentDate), plannedDay, "it lands where it is owed")
        XCTAssertEqual(calendar.startOfDay(for: pushed.originalDate), anchor, "and still remembers where it came from")
        XCTAssertNotEqual(
            calendar.startOfDay(for: pushed.currentDate), day(2026, 9, 1),
            "not the day after the miss — that is the walk this replaces"
        )
    }

    /// No record at all when the planned day already carries the
    /// occurrence: the task recurs there anyway, so a record would draw a
    /// second identical row.
    ///
    /// The walk used to catch this after the fact, by noticing it had
    /// landed on a recurrence day and deleting itself. Placed directly,
    /// there is nothing to drift onto.
    func test_noRecordWhenThePlannedDayAlreadyRecurs() throws {
        let anchor = day(2026, 8, 31)
        let task = makeMiddayRecurringTask(anchor: anchor)
        let recurrenceDay = day(2026, 9, 30)
        XCTAssertTrue(task.hasRecurringOccurrence(on: recurrenceDay, calendar: calendar), "sanity: a real pattern day")

        let pushed = ScheduleReviewViewModel.pushRecurringOccurrenceIfNeeded(
            task: task, missedDay: anchor, plannedDay: recurrenceDay, context: context
        )

        XCTAssertNil(pushed, "the task shows there on its own")
        XCTAssertTrue(try context.fetch(FetchDescriptor<PushedRecurringOccurrence>()).isEmpty)
    }

    /// And nothing advances it afterwards. The record sits on its day until
    /// acted on — this is the property the whole change is for.
    func test_aPushedRecordDoesNotMoveOnItsOwn() throws {
        let anchor = day(2026, 8, 31)
        let task = makeMiddayRecurringTask(anchor: anchor)
        let plannedDay = day(2026, 9, 1)
        let pushed = try XCTUnwrap(ScheduleReviewViewModel.pushRecurringOccurrenceIfNeeded(
            task: task, missedDay: anchor, plannedDay: plannedDay, context: context
        ))

        // Whatever else happens to the task, the record keeps its day.
        task.isNightlyReviewed = true
        _ = task.cycleRecurringOccurrence(on: day(2026, 9, 5), context: context, calendar: calendar)

        XCTAssertEqual(calendar.startOfDay(for: pushed.currentDate), plannedDay)
    }
}
