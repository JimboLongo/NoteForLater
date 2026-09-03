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
        log.isCompleted = true

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

    // MARK: - Gap 2: immediate one-hop relocation, and no double-placement on relaunch

    /// The behavior `NightlyReviewView`'s today→tomorrow `Task` now
    /// performs: create the record, then hop it once, synchronously,
    /// instead of leaving it at today's date for the next app launch.
    func test_advanceOneHop_relocatesSpecificTimeMissImmediately() {
        let anchor = day(2026, 8, 31)
        let task = TaskItem(title: "Pay rent", dueDate: anchor, estimatedMinutes: 15)
        task.isRecurring = true
        task.recurrenceUnit = .months
        task.recurrenceIntervalCount = 1
        task.recurrenceTimeMode = .specific
        context.insert(task)

        let occurrence = PushedRecurringOccurrence(taskID: task.id, originalDate: anchor)
        context.insert(occurrence)

        let tomorrow = day(2026, 9, 1)
        let resolved = PushedRecurringOccurrence.advanceOneHop(occurrence, task: task, from: anchor, to: tomorrow, calendar: calendar, context: context)

        XCTAssertFalse(resolved)
        XCTAssertEqual(calendar.startOfDay(for: occurrence.currentDate), tomorrow)
        let blocks = (try? context.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        XCTAssertEqual(blocks.count, 1, "exactly one placeholder block should exist, relocated to tomorrow")
        XCTAssertEqual(blocks.first.map { calendar.startOfDay(for: $0.date) }, tomorrow)
    }

    /// The double-placement question flagged during design: if Nightly
    /// Review already hopped an occurrence forward tonight, a same-night
    /// app relaunch must not hop it again. Simulates
    /// `NoteForLaterApp.advanceOneDay`'s `while cursor < today` loop
    /// directly, with "today" still equal to the night of the review
    /// (nothing has actually rolled over) — the loop must see
    /// `occurrence.currentDate` already at-or-past that "today" and do
    /// nothing.
    func test_advanceOneHop_sameNightRelaunch_doesNotDoublePlace() {
        let anchor = day(2026, 8, 31)
        let task = TaskItem(title: "Pay rent", dueDate: anchor, estimatedMinutes: 15)
        task.isRecurring = true
        task.recurrenceUnit = .months
        task.recurrenceIntervalCount = 1
        task.recurrenceTimeMode = .specific
        context.insert(task)

        let occurrence = PushedRecurringOccurrence(taskID: task.id, originalDate: anchor)
        context.insert(occurrence)
        let tonight = anchor
        let tomorrow = day(2026, 9, 1)

        // Tonight's review: one immediate hop, same as the production call
        // site in `NightlyReviewView`.
        _ = PushedRecurringOccurrence.advanceOneHop(occurrence, task: task, from: tonight, to: tomorrow, calendar: calendar, context: context)
        let blocksAfterReview = (try? context.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        XCTAssertEqual(blocksAfterReview.count, 1)

        // Simulated same-night relaunch: `NoteForLaterApp.init()`'s
        // catch-up walk, with `today` still `tonight` (no day has actually
        // elapsed) — mirrors the loop body of `advanceOneDay` exactly.
        var cursor = calendar.startOfDay(for: occurrence.currentDate)
        var changed = false
        while cursor < calendar.startOfDay(for: tonight) {
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            let resolved = PushedRecurringOccurrence.advanceOneHop(occurrence, task: task, from: cursor, to: next, calendar: calendar, context: context)
            changed = true
            if resolved { break }
            cursor = next
        }

        XCTAssertFalse(changed, "the loop must not advance at all once currentDate already reaches today")
        XCTAssertEqual(calendar.startOfDay(for: occurrence.currentDate), tomorrow, "should still sit at exactly the day the review hopped it to")
        let blocksAfterRelaunch = (try? context.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        XCTAssertEqual(blocksAfterRelaunch.count, 1, "must still be exactly one block — no duplicate created by the simulated relaunch")
    }

    /// Same double-placement question, one calendar day further on: the
    /// app is opened the *next* day (a completely ordinary relaunch, not
    /// same-night) — the walk should find nothing left to do, since
    /// tonight's hop already caught it up to exactly that day.
    func test_advanceOneHop_nextDayRelaunch_findsNothingLeftToCatchUp() {
        let anchor = day(2026, 8, 31)
        let task = TaskItem(title: "Pay rent", dueDate: anchor, estimatedMinutes: 15)
        task.isRecurring = true
        task.recurrenceUnit = .months
        task.recurrenceIntervalCount = 1
        task.recurrenceTimeMode = .specific
        context.insert(task)

        let occurrence = PushedRecurringOccurrence(taskID: task.id, originalDate: anchor)
        context.insert(occurrence)
        let tomorrow = day(2026, 9, 1)
        _ = PushedRecurringOccurrence.advanceOneHop(occurrence, task: task, from: anchor, to: tomorrow, calendar: calendar, context: context)

        // Relaunch the *next* day: "today" for the launch-time walk is now
        // `tomorrow` itself.
        var cursor = calendar.startOfDay(for: occurrence.currentDate)
        var changed = false
        while cursor < tomorrow {
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            let resolved = PushedRecurringOccurrence.advanceOneHop(occurrence, task: task, from: cursor, to: next, calendar: calendar, context: context)
            changed = true
            if resolved { break }
            cursor = next
        }

        XCTAssertFalse(changed)
        let blocks = (try? context.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        XCTAssertEqual(blocks.count, 1)
    }
}
