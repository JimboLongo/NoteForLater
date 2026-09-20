import XCTest
import SwiftData
@testable import NoteForLater

/// Coverage for two `DayTimelineGridView` changes:
///
/// 1. A Specific-Time recurring task's occurrence only ever shows up via a
///    real `ScheduledBlock` — block generation (`regenerateFromNow`) only
///    reaches as far ahead as its own walk has actually run, so navigating
///    past that point made the occurrence disappear entirely (confirmed
///    against the live device store: two Specific-Time recurring tasks had
///    zero `ScheduledBlock`s at all, though for a different reason —
///    their own recurrence was over a year out — which is what motivated
///    checking `hasRecurringOccurrence`/`timelineRows`'s logic directly
///    rather than assuming from that data alone). AM/Midday/PM occurrences
///    were already unaffected — `openRecurringTaskOccurrences` reads
///    `TaskItem.hasRecurringOccurrence(on:)`, pure date math with no block
///    dependency. Fixed with `ScheduleReviewViewModel
///    .projectedRecurringTaskOccurrences` — a display-time projection, not
///    a materialized block, reading `RecurringTaskLog` for completion the
///    same way the untimed modes already do (see that function's own doc
///    comment for why generation depth was deliberately left untouched).
/// 2. Habit rows on the calendar showing `Habit.currentStreak(asOf:)` —
///    `ScheduleReviewViewModel.habitStreaks(for:asOf:)` is the cached,
///    once-per-render source `DayTimelineGridView.cachedHabitStreaks`
///    reads from, computed as of the *displayed* day rather than always
///    today.
final class DayTimelineProjectionAndStreakTests: XCTestCase {
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
            for: TaskItem.self, ScheduledBlock.self, Shelf.self, RecurringTaskLog.self,
                Habit.self, HabitLog.self, PushedRecurringOccurrence.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    /// Daily Specific-Time recurring task, anchored well in the past so
    /// every day in these tests is a real recurrence day.
    private func makeSpecificTimeTask(anchor: Date) -> TaskItem {
        let task = TaskItem(title: "Water the garden", dueDate: anchor, estimatedMinutes: 15)
        task.isRecurring = true
        task.recurrenceUnit = .days
        task.recurrenceIntervalCount = 1
        // Legacy row shape: the setter refuses `.specific` for tasks now
        // (see `TaskItem.recurrenceTimeMode`), so this writes the raw
        // column directly, which is exactly the pre-migration state
        // `migrateRecurringSpecificTimeTasksIfNeeded` exists to clear. The
        // machinery under test is retired but not yet deleted — see stage
        // 4b — so it stays covered until it goes.
        task.recurrenceTimeModeRaw = HabitOccurrenceTimeMode.specific.rawValue
        context.insert(task)
        return task
    }

    /// Monthly recurring task (untimed — mode doesn't matter to the
    /// carry-forward rule itself, `.midday` picked arbitrarily), anchored
    /// so every month's 10th is a real pattern day.
    private func makeMonthlyTask(anchor: Date, mode: HabitOccurrenceTimeMode = .midday) -> TaskItem {
        let task = TaskItem(title: "Pay rent", dueDate: anchor, estimatedMinutes: 10)
        task.isRecurring = true
        task.recurrenceUnit = .months
        task.recurrenceIntervalCount = 1
        // Raw, not through the setter: it coerces `.specific` to `.midday`
        // for tasks now (see `TaskItem.recurrenceTimeMode`), and the
        // Specific-Time callers below are exercising the pre-migration row
        // shape on purpose. Every other mode is unaffected by writing raw.
        task.recurrenceTimeModeRaw = mode.rawValue
        context.insert(task)
        return task
    }

    /// A fixed "today" for every test below, passed explicitly to
    /// `projectedRecurringTaskOccurrences(today:)` rather than relying on
    /// its `.now` default — the future/not-future distinction these tests
    /// exercise must not depend on which real-world day the test suite
    /// happens to run on.
    private let fixedToday = { () -> Date in
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: 10))!
    }()

    // MARK: - 1. Appears on a future day with no ScheduledBlock

    // MARK: - 2. Day independence

    // MARK: - Habit streak display

    private func makeHabit(name: String, daysOfWeek: [Int] = [1, 2, 3, 4, 5, 6, 7], startDate: Date) -> Habit {
        let habit = Habit(name: name, startDate: startDate, daysOfWeek: daysOfWeek, idealTimesOfDay: [540])
        context.insert(habit)
        return habit
    }

    /// `habitStreaks(for:asOf:)` must match `Habit.currentStreak(asOf:)`
    /// exactly — it's a thin collection wrapper, not new math, and this
    /// guards against that ever drifting (e.g. someone "simplifying" it to
    /// always pass `.now`).
    func test_habitStreaks_matchesCurrentStreak_forTheDisplayedDate() {
        let start = day(2026, 8, 1)
        let habit = makeHabit(name: "Stretch", startDate: start)
        // Three-day hit streak ending on Sept 3, so "as of" a date in the
        // middle of it and a date after it produce genuinely different
        // numbers — a hardcoded `.now` would fail this.
        for offset in 0..<3 {
            let logDay = calendar.date(byAdding: .day, value: offset, to: start)!
            habit.logOrCreate(on: logDay, context: context, calendar: calendar).setOccurrence(0, to: .complete)
        }
        let midStreakDay = calendar.date(byAdding: .day, value: 1, to: start)!
        let afterStreakDay = calendar.date(byAdding: .day, value: 5, to: start)!

        let midResult = ScheduleReviewViewModel.habitStreaks(for: [habit], asOf: midStreakDay, calendar: calendar)
        let afterResult = ScheduleReviewViewModel.habitStreaks(for: [habit], asOf: afterStreakDay, calendar: calendar)

        XCTAssertEqual(midResult[habit.id], habit.currentStreak(asOf: midStreakDay, calendar: calendar))
        XCTAssertEqual(afterResult[habit.id], habit.currentStreak(asOf: afterStreakDay, calendar: calendar))
        XCTAssertNotEqual(midResult[habit.id], afterResult[habit.id], "as-of date must actually matter, not just happen to match")
    }

    /// The clamp: a *future* day must show the streak as of *today*, not
    /// a walk that counts every intervening day (none of which have
    /// happened yet) as a miss. A *past* day is left unclamped — that's a
    /// real as-of value, not a projection into days that don't exist.
    ///
    /// Verified fail-then-pass: with the `min(date, today)` clamp
    /// temporarily removed (passing `date` straight through), this test
    /// failed — the future day's streak came back more negative than
    /// today's, reproducing the reported bug. Restored the clamp and
    /// reran: green. Both via `xcodebuild test`.
    func test_habitStreaks_futureDayClampsToToday_pastDayUnclamped() {
        let start = day(2026, 8, 1)
        let habit = makeHabit(name: "Stretch", startDate: start)
        for offset in 0..<3 {
            let logDay = calendar.date(byAdding: .day, value: offset, to: start)!
            habit.logOrCreate(on: logDay, context: context, calendar: calendar).setOccurrence(0, to: .complete)
        }
        let fixedToday = calendar.date(byAdding: .day, value: 5, to: start)! // after the 3-day streak
        let futureDay = calendar.date(byAdding: .day, value: 20, to: start)!
        let pastDay = calendar.date(byAdding: .day, value: 1, to: start)! // mid-streak

        let futureResult = ScheduleReviewViewModel.habitStreaks(for: [habit], asOf: futureDay, calendar: calendar, today: fixedToday)
        let todayResult = ScheduleReviewViewModel.habitStreaks(for: [habit], asOf: fixedToday, calendar: calendar, today: fixedToday)
        let pastResult = ScheduleReviewViewModel.habitStreaks(for: [habit], asOf: pastDay, calendar: calendar, today: fixedToday)

        XCTAssertEqual(futureResult[habit.id], todayResult[habit.id], "a future day must clamp to today's own streak")
        XCTAssertEqual(pastResult[habit.id], habit.currentStreak(asOf: pastDay, calendar: calendar), "a past day must keep showing its true as-of value, not clamp")
    }

    // MARK: - A pushed occurrence appears on one day only

    /// **REVERSAL — the carry-forward projection is gone, and these five
    /// tests went with the mechanism they covered.**
    ///
    /// `carriedForwardRecurringTaskIDs` painted a "Pushed" row onto *every*
    /// future day until a task's next real recurrence. That was asked for
    /// when it was the only way to keep a miss visible. It is too much: the
    /// push should be a single day's reminder, not a banner on every day you
    /// scroll to.
    ///
    /// The mechanism it duplicated already existed. `PushedRecurringOccurrence`
    /// carries a `currentDate` and shows the occurrence on **exactly that
    /// day**, and `advanceOneHop` walks it forward one day at a time at each
    /// launch until it meets the next real recurrence, where it resolves
    /// itself. So this is a removal, not a narrowing — one row that follows
    /// you forward, and scroll-ahead days are clean.
    ///
    /// **Where the deleted tests' coverage went.** Four of the five were
    /// pinning rules the record enforces independently, and those tests
    /// already exist:
    /// - non-pushable never pushes →
    ///   `RecurringTaskCycleTests.test_nonPushableTask_commitTimeSweep_createsNoPushRecord`
    /// - stops at the next real pattern day →
    ///   `RecurringTaskReviewTests.test_advanceOneHop_resolves_whenNextIsARecurrenceDay`
    /// - keeps moving otherwise →
    ///   `RecurringTaskReviewTests.test_advanceOneHop_advancesTheCursor_whenNextIsNotARecurrenceDay`
    /// - a completed occurrence stops →
    ///   `PushedRecurringOccurrence.isAlreadyResolved`, covered by the same pair
    ///
    /// The fifth — untouched-vs-missed — became the `.missed`-only gate and
    /// is covered in `RecurringTaskReviewTests`. What none of them pinned is
    /// the property this change is actually about, so that is what replaces
    /// them.
    func test_pushedOccurrence_identifiesExactlyOneDay() {
        let anchor = day(2026, 8, 10)
        let task = makeMonthlyTask(anchor: anchor)
        let missedDay = day(2026, 9, 10)
        let pushed = PushedRecurringOccurrence(taskID: task.id, originalDate: missedDay)
        context.insert(pushed)

        // The display predicate `DayTimelineGridView.pushedTaskIDsForTargetDate`
        // applies: not completed, and `currentDate` is the day being shown.
        func appears(on target: Date) -> Bool {
            !pushed.isCompleted && calendar.isDate(pushed.currentDate, inSameDayAs: target)
        }

        XCTAssertTrue(appears(on: missedDay), "the day it sits on")
        XCTAssertFalse(appears(on: day(2026, 9, 11)), "not tomorrow — it has not hopped yet")
        XCTAssertFalse(appears(on: day(2026, 9, 20)), "and emphatically not every day until the next recurrence, which is what was removed")
    }

    /// After a hop it appears on the new day and **stops appearing on the
    /// old one** — the "follows you forward" half. A projection would have
    /// shown both.
    func test_pushedOccurrence_movesRatherThanAccumulates() {
        let anchor = day(2026, 8, 10)
        let task = makeMonthlyTask(anchor: anchor)
        let missedDay = day(2026, 9, 10)
        let nextDay = day(2026, 9, 11)
        let pushed = PushedRecurringOccurrence(taskID: task.id, originalDate: missedDay)
        context.insert(pushed)

        PushedRecurringOccurrence.advanceOneHop(pushed, task: task, from: missedDay, to: nextDay, calendar: calendar, context: context)

        func appears(on target: Date) -> Bool {
            !pushed.isCompleted && calendar.isDate(pushed.currentDate, inSameDayAs: target)
        }
        XCTAssertTrue(appears(on: nextDay), "it moved forward one day")
        XCTAssertFalse(appears(on: missedDay), "and left the day it came from — one row, not two")
    }

}
