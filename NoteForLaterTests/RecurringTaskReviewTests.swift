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

    /// Gap 1's regression case. To verify this genuinely fails on the old
    /// code — not just "doesn't compile" for a brand-new function, which
    /// proves nothing about behavior — the `openRecurringTaskOccurrencesForReview`
    /// half of `pushMissedRecurringOccurrences` was temporarily commented
    /// out (leaving only the block-scoped loop, exactly what
    /// `NightlyReviewView.swift:386-394` did before this fix) and this
    /// test was run in isolation: all 6 assertions in this test failed —
    /// `created.count` came back `0`, both `first` lookups `nil`, the
    /// fetched `pending` count `0`, and the final `XCTAssertFalse` failed
    /// on the coalesced `true`. Restoring the real implementation and
    /// re-running flipped all 6 green with no other change. Both runs were
    /// executed via `xcodebuild test`, not inferred.
    func test_pushMissedRecurringOccurrences_capturesMissedMiddayRecurringTask() throws {
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

        XCTAssertEqual(created.count, 1, "a missed midday recurring occurrence should produce exactly one pushed record")
        XCTAssertEqual(created.first?.task.id, task.id)
        XCTAssertEqual(created.first.map { calendar.startOfDay(for: $0.missedDay) }, calendar.startOfDay(for: anchor))

        let pending = try context.fetch(FetchDescriptor<PushedRecurringOccurrence>())
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.taskID, task.id)
        XCTAssertFalse(pending.first?.isCompleted ?? true)
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
