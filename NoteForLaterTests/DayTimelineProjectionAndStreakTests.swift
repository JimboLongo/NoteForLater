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

    // MARK: - Carry-forward projection of an incomplete recurring task

    /// Verified fail-then-pass: with `carriedForwardRecurringTaskIDs`
    /// temporarily reverted to `return []` unconditionally, this test
    /// failed — the incomplete task never carried forward onto the future
    /// non-pattern day. Restored the real walk and reran: green. Both via
    /// `xcodebuild test`.
    func test_carriedForward_incompleteMonthlyTask_appearsOnFutureNonPatternDay() {
        let anchor = day(2026, 8, 10)
        let fixedToday = day(2026, 9, 10) // also a pattern day, left incomplete
        let notAPatternDay = day(2026, 9, 20)
        let task = makeMonthlyTask(anchor: anchor)

        let result = ScheduleReviewViewModel.carriedForwardRecurringTaskIDs(
            tasks: [task], targetDate: notAPatternDay, alreadyCoveredTaskIDs: [], context: context, calendar: calendar, today: fixedToday
        )

        XCTAssertTrue(result.contains(task.id))
    }

    /// Fail-then-pass target: a non-pushable task's incomplete occurrence
    /// must never carry forward onto a future day — this projection is a
    /// display stand-in for a real `PushedRecurringOccurrence`
    /// (`ScheduleReviewViewModel.pushRecurringOccurrenceIfNeeded`, which
    /// itself never creates one for such a task), so it must agree.
    func test_carriedForward_nonPushableTask_neverProjectsForward() {
        let anchor = day(2026, 8, 10)
        let fixedToday = day(2026, 9, 10)
        let notAPatternDay = day(2026, 9, 20)
        let task = makeMonthlyTask(anchor: anchor)
        task.isPushable = false

        let result = ScheduleReviewViewModel.carriedForwardRecurringTaskIDs(
            tasks: [task], targetDate: notAPatternDay, alreadyCoveredTaskIDs: [], context: context, calendar: calendar, today: fixedToday
        )

        XCTAssertFalse(result.contains(task.id), "a non-pushable task's miss must stay on its own day, never carried forward")
    }

    /// The bound: projection stops the moment the task's own next real
    /// pattern day arrives — never past it, never indefinitely.
    func test_carriedForward_stopsOnAndAfterNextRealPatternDay() {
        let anchor = day(2026, 8, 10)
        let fixedToday = day(2026, 9, 10)
        let nextPatternDay = day(2026, 10, 10)
        let wellAfterHandoff = day(2026, 10, 15)
        let task = makeMonthlyTask(anchor: anchor)

        let onHandoffDay = ScheduleReviewViewModel.carriedForwardRecurringTaskIDs(
            tasks: [task], targetDate: nextPatternDay, alreadyCoveredTaskIDs: [], context: context, calendar: calendar, today: fixedToday
        )
        let afterHandoff = ScheduleReviewViewModel.carriedForwardRecurringTaskIDs(
            tasks: [task], targetDate: wellAfterHandoff, alreadyCoveredTaskIDs: [], context: context, calendar: calendar, today: fixedToday
        )

        XCTAssertFalse(onHandoffDay.contains(task.id), "the real occurrence takes over on its own pattern day, not a projection")
        XCTAssertFalse(afterHandoff.contains(task.id), "must not project past the handoff day either")
    }

    /// A completed occurrence has nothing to carry forward.
    func test_carriedForward_completedOccurrence_doesNotProject() {
        let anchor = day(2026, 8, 10)
        let fixedToday = day(2026, 9, 10)
        let notAPatternDay = day(2026, 9, 20)
        let task = makeMonthlyTask(anchor: anchor)
        RecurringTaskLog.logOrCreate(taskID: task.id, on: fixedToday, context: context, calendar: calendar).status = .complete

        let result = ScheduleReviewViewModel.carriedForwardRecurringTaskIDs(
            tasks: [task], targetDate: notAPatternDay, alreadyCoveredTaskIDs: [], context: context, calendar: calendar, today: fixedToday
        )

        XCTAssertFalse(result.contains(task.id))
    }

}
