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
            cutoff: cutoff
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
            reviewedBlocks: [block], tasks: [task], context: context, cutoff: day(2026, 9, 1)
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
            reviewedBlocks: [block], tasks: [task], context: context, cutoff: day(2026, 9, 1)
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
            reviewedBlocks: [], tasks: [task], context: context, cutoff: cutoff
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
            reviewedBlocks: [], tasks: [task], context: context, cutoff: day(2026, 9, 1)
        )
        XCTAssertTrue(created.isEmpty)

        let pending = try? context.fetch(FetchDescriptor<PushedRecurringOccurrence>())
        XCTAssertEqual(pending?.count, 1, "should still be exactly the one pre-existing record, not two")
    }

    // MARK: - advanceOneHop: what survives the removal of Specific Time

    /// Three tests used to live here, all built around the Specific-Time
    /// *placeholder block* — relocating it a day at a time, and not
    /// double-placing it on relaunch. That block no longer exists (stage
    /// 4b), so those tests went with it.
    ///
    /// **What they were also covering incidentally still matters**, and
    /// would have been left bare: `advanceOneHop`'s own date walk. These two
    /// pin exactly that, so the surviving half of the function keeps its
    /// coverage rather than losing it as a side effect of deleting the half
    /// that went away.
    func test_advanceOneHop_advancesTheCursor_whenNextIsNotARecurrenceDay() {
        let anchor = day(2026, 8, 31)
        let task = makeMiddayRecurringTask(anchor: anchor)
        let occurrence = PushedRecurringOccurrence(taskID: task.id, originalDate: anchor)
        context.insert(occurrence)

        let next = day(2026, 9, 1)
        let resolved = PushedRecurringOccurrence.advanceOneHop(
            occurrence, task: task, from: anchor, to: next, calendar: calendar, context: context
        )

        XCTAssertFalse(resolved, "not a recurrence day, so the chain continues")
        XCTAssertEqual(occurrence.currentDate, next)
    }

    /// The resolving half: landing on a real recurrence day deletes the
    /// pushed record and lets the ordinary pattern take over.
    func test_advanceOneHop_resolves_whenNextIsARecurrenceDay() throws {
        let anchor = day(2026, 8, 31)
        let task = makeMiddayRecurringTask(anchor: anchor)
        let occurrence = PushedRecurringOccurrence(taskID: task.id, originalDate: anchor)
        context.insert(occurrence)
        try context.save()

        let next = day(2026, 9, 30)
        XCTAssertTrue(task.hasRecurringOccurrence(on: next, calendar: calendar), "sanity: a real pattern day")

        let resolved = PushedRecurringOccurrence.advanceOneHop(
            occurrence, task: task, from: anchor, to: next, calendar: calendar, context: context
        )
        try context.save()

        XCTAssertTrue(resolved)
        let pending = try context.fetch(FetchDescriptor<PushedRecurringOccurrence>())
        XCTAssertTrue(pending.isEmpty, "resolved chains are deleted, not left sitting")
    }
}
