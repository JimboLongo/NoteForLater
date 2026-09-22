import XCTest
import SwiftData
@testable import NoteForLater

/// Coverage for several changes to the recurring card's "Repeats"/"Time"
/// sections:
///
/// 1. Every menu-style control there now marks its "picked" flag on any
///    interaction, even re-choosing the value already showing — fixing a
///    bug where `Picker(selection:)` silently never fires when the tap
///    doesn't change the bound value (see `PickedMenuPicker`'s own doc
///    comment).
/// 2. The old Specific-Date-vs-Relative-Date mode toggle is gone. "Every
///    [N] [days/weeks/months]" is the only top-level control now; when
///    the unit is months, an "On the" row appears offering Day of
///    month/Day of Week, and the day-of-month branch itself offers First
///    day/Last day/Same day (the third being what "Specific Date,
///    monthly" already meant, now reachable from what looks like one
///    unified flow — see `TaskReviewCard.DayOfMonthPosition`'s own doc
///    comment).
/// 3. Every `PickedMenuPicker`'s value column is now fixed to its widest
///    option's width, so switching selections never visibly resizes it —
///    see the widest-option-label tests below for the regression net on
///    that.
///
/// `TaskReviewCard` itself isn't constructible here (its `@Query`
/// properties need a live SwiftUI/SwiftData environment) — this
/// exercises the pulled-out `internal` `select*`/`backfill*` functions
/// directly, same reasoning as `RecurringTaskCardLayoutTests`.
final class RepeatsRedesignTests: XCTestCase {
    /// A task in the state creation *used* to leave: value defaults present,
    /// picked flags false.
    ///
    /// Still a real state — every task created before
    /// `TaskItem.applyCreationDefaults` existed is in it — and it is what
    /// the tests using this helper are actually about. They were relying on
    /// `makeForDirectCapture` to produce it incidentally; now they ask for
    /// it, which is what they meant all along.
    private func makeUnconfiguredRecurringTask(title: String = "Water the garden") -> TaskItem {
        let task = makeRecurringTask(title: title)
        task.recurrenceIntervalCount = 1
        task.recurrenceUnit = .days
        task.recurrenceIntervalPicked = false
        task.recurrenceTimeModePicked = false
        task.relativeRecurrencePicked = false
        return task
    }

    private func makeRecurringTask(title: String = "Water the garden") -> TaskItem {
        let shelf = Shelf(name: "Recurring Tasks")
        shelf.isRecurringTasks = true
        return TaskItem.makeForDirectCapture(title: title, shelf: shelf)
    }

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth))!
    }

    // MARK: - Part 1: selecting the already-default value still marks picked

    /// Fail-then-pass target — the exact bug reported: `recurrenceUnit`'s
    /// stored default is `.days`, so a task that genuinely wants "every
    /// day" and never touches anything else would previously never mark
    /// `recurrenceIntervalPicked`.
    func test_selectRecurrenceUnit_alreadyDefaultValue_stillMarksPicked() {
        let task = makeUnconfiguredRecurringTask()
        XCTAssertEqual(task.recurrenceUnit, .days)
        XCTAssertFalse(task.recurrenceIntervalPicked)

        TaskReviewCard.selectRecurrenceUnit(.days, on: task)

        XCTAssertTrue(task.recurrenceIntervalPicked)
    }

    func test_selectRecurrenceUnit_switchingAwayFromMonths_forcesSpecificDate() {
        let task = makeRecurringTask()
        task.recurrenceMode = .relativeDate
        task.recurrenceUnit = .months

        TaskReviewCard.selectRecurrenceUnit(.days, on: task)

        XCTAssertEqual(task.recurrenceMode, .specificDate)
    }

    func test_selectRecurrenceUnit_stayingOnMonths_leavesModeAlone() {
        let task = makeRecurringTask()
        task.recurrenceMode = .relativeDate
        task.recurrenceUnit = .months

        TaskReviewCard.selectRecurrenceUnit(.months, on: task)

        XCTAssertEqual(task.recurrenceMode, .relativeDate)
    }

    func test_selectRecurrenceTimeMode_alreadyDefaultValue_stillMarksPicked() {
        let task = makeUnconfiguredRecurringTask()
        XCTAssertEqual(task.recurrenceTimeMode, .midday)
        XCTAssertFalse(task.recurrenceTimeModePicked)

        TaskReviewCard.selectRecurrenceTimeMode(.midday, on: task)

        XCTAssertTrue(task.recurrenceTimeModePicked)
    }

    func test_selectMonthlyScope_alreadySelectedValue_stillMarksPicked() {
        let task = makeRecurringTask()
        task.recurrenceUnit = .months
        task.relativeRecurrenceScope = .dayOfMonth

        TaskReviewCard.selectMonthlyScope(.dayOfMonth, on: task)

        XCTAssertTrue(task.relativeRecurrencePicked)
        XCTAssertEqual(task.recurrenceMode, .relativeDate)
    }

    func test_selectDayOfMonthPosition_alreadySameAsAnchor_stillMarksPicked() {
        let task = makeRecurringTask()
        task.recurrenceUnit = .months
        XCTAssertEqual(task.recurrenceMode, .specificDate)
        XCTAssertEqual(TaskReviewCard.dayOfMonthPosition(for: task), .sameAsAnchor)

        TaskReviewCard.selectDayOfMonthPosition(.sameAsAnchor, on: task)

        XCTAssertTrue(task.relativeRecurrencePicked)
        XCTAssertEqual(task.recurrenceMode, .specificDate)
    }

    func test_selectRelativeOrdinal_alreadySelectedValue_stillMarksPicked() {
        let task = makeRecurringTask()
        task.recurrenceUnit = .months
        task.recurrenceMode = .relativeDate
        task.relativeRecurrenceScope = .weekdayOfMonth
        task.relativeRecurrenceOrdinal = .first

        TaskReviewCard.selectRelativeOrdinal(.first, on: task)

        XCTAssertTrue(task.relativeRecurrencePicked)
    }

    func test_selectRelativeWeekday_alreadySelectedValue_stillMarksPicked() {
        let task = makeRecurringTask()
        task.recurrenceUnit = .months
        task.recurrenceMode = .relativeDate
        task.relativeRecurrenceScope = .weekdayOfMonth
        task.relativeRecurrenceWeekday = 3

        TaskReviewCard.selectRelativeWeekday(3, on: task)

        XCTAssertTrue(task.relativeRecurrencePicked)
    }

    // MARK: - Soft defaults: "Repeats"/"Time" show a real value before being picked, without affecting missing-ness

    /// `recurrenceShortSummary` (what `repeatsSummaryText` displays) is a
    /// live read of the stored fields, not gated on any "picked" flag —
    /// so a fresh task's real default already reads "Daily" here.
    /// `recurrenceIntervalPicked`/`missingAttributeNames` are what
    /// actually track whether this was confirmed, and neither reading
    /// "Daily" changes: this is a cosmetic pre-fill, not a silent answer.
    /// UPDATED — this asserted the bug, and the default it asserted has
    /// also changed.
    ///
    /// It pinned "shows Daily, reports Every as missing" — the displayed
    /// default and the registered state disagreeing, which is exactly the
    /// defect `TaskItem.applyCreationDefaults` exists to remove. A displayed
    /// default is now the value. The default itself is Monthly.
    func test_freshRecurringTask_repeatDefaultsToMonthly_andCountsAsAnswered() {
        let task = makeRecurringTask()

        XCTAssertEqual(task.recurrenceShortSummary, "Monthly")
        XCTAssertTrue(task.recurrenceIntervalPicked, "shown means held")
        XCTAssertFalse(task.missingAttributeNames(consideringShelf: task.shelf).contains("Every"))
    }

    /// The pre-`applyCreationDefaults` state still reports missing — the
    /// rule did not change, only what creation writes.
    func test_unconfiguredRecurringTask_stillReportsEveryAsMissing() {
        let task = makeUnconfiguredRecurringTask()

        XCTAssertFalse(task.recurrenceIntervalPicked)
        XCTAssertTrue(task.missingAttributeNames(consideringShelf: task.shelf).contains("Every"))
    }

    /// Same guarantee, for `recurrenceTimeMode`'s new default.
    /// UPDATED — same reversal as the Every test above. Midday is still the
    /// default; it now counts as chosen.
    func test_freshRecurringTask_timeDefaultsToMidday_andCountsAsAnswered() {
        let task = makeRecurringTask()

        XCTAssertEqual(task.recurrenceTimeMode, .midday)
        XCTAssertEqual(task.recurrenceTimeMode.label, "Midday")
        XCTAssertTrue(task.recurrenceTimeModePicked)
        XCTAssertFalse(task.missingAttributeNames(consideringShelf: task.shelf).contains("Time"))
    }

    // MARK: - Part 2: every old two-mode pattern is still reachable, and evaluates the same

    /// Old Specific Date, daily.
    func test_pattern_daily_stillReachable() {
        let anchor = day(2026, 9, 1)
        let task = makeRecurringTask()
        task.dueDate = anchor
        TaskReviewCard.selectRecurrenceUnit(.days, on: task)
        task.recurrenceIntervalCount = 3

        XCTAssertEqual(task.recurrenceMode, .specificDate)
        XCTAssertTrue(task.hasRecurringOccurrence(on: day(2026, 9, 4), calendar: calendar))
        XCTAssertFalse(task.hasRecurringOccurrence(on: day(2026, 9, 5), calendar: calendar))
    }

    /// Old Specific Date, weekly.
    func test_pattern_weekly_stillReachable() {
        let anchor = day(2026, 9, 1) // a Tuesday
        let task = makeRecurringTask()
        task.dueDate = anchor
        TaskReviewCard.selectRecurrenceUnit(.weeks, on: task)
        task.recurrenceIntervalCount = 2

        XCTAssertEqual(task.recurrenceMode, .specificDate)
        XCTAssertTrue(task.hasRecurringOccurrence(on: day(2026, 9, 15), calendar: calendar))
        XCTAssertFalse(task.hasRecurringOccurrence(on: day(2026, 9, 8), calendar: calendar))
    }

    /// Old Specific Date, monthly — "the anchor's day," now reached via
    /// "On the" → Day → "Same day" instead of the removed mode toggle.
    func test_pattern_monthly_sameDay_stillReachable() {
        let anchor = day(2026, 9, 17)
        let task = makeRecurringTask()
        task.dueDate = anchor
        TaskReviewCard.selectRecurrenceUnit(.months, on: task)
        TaskReviewCard.selectDayOfMonthPosition(.sameAsAnchor, on: task)

        XCTAssertEqual(task.recurrenceMode, .specificDate)
        XCTAssertTrue(task.hasRecurringOccurrence(on: day(2026, 10, 17), calendar: calendar))
        XCTAssertFalse(task.hasRecurringOccurrence(on: day(2026, 10, 18), calendar: calendar))
    }

    /// Old Relative Date, day-of-month, first.
    func test_pattern_monthly_firstDay_stillReachable() {
        let anchor = day(2026, 9, 1)
        let task = makeRecurringTask()
        task.dueDate = anchor
        TaskReviewCard.selectRecurrenceUnit(.months, on: task)
        TaskReviewCard.selectMonthlyScope(.dayOfMonth, on: task)
        TaskReviewCard.selectDayOfMonthPosition(.first, on: task)

        XCTAssertEqual(task.recurrenceMode, .relativeDate)
        XCTAssertTrue(task.hasRecurringOccurrence(on: day(2026, 10, 1), calendar: calendar))
        XCTAssertFalse(task.hasRecurringOccurrence(on: day(2026, 10, 2), calendar: calendar))
    }

    /// Old Relative Date, day-of-month, last.
    func test_pattern_monthly_lastDay_stillReachable() {
        let anchor = day(2026, 9, 1)
        let task = makeRecurringTask()
        task.dueDate = anchor
        TaskReviewCard.selectRecurrenceUnit(.months, on: task)
        TaskReviewCard.selectMonthlyScope(.dayOfMonth, on: task)
        TaskReviewCard.selectDayOfMonthPosition(.last, on: task)

        XCTAssertEqual(task.recurrenceMode, .relativeDate)
        XCTAssertTrue(task.hasRecurringOccurrence(on: day(2026, 9, 30), calendar: calendar))
        XCTAssertFalse(task.hasRecurringOccurrence(on: day(2026, 9, 29), calendar: calendar))
    }

    /// Old Relative Date, weekday-of-month — the user's own worked
    /// example, "the fourth Saturday."
    func test_pattern_monthly_weekdayOfMonth_stillReachable() {
        let anchor = day(2026, 9, 1)
        let task = makeRecurringTask()
        task.dueDate = anchor
        TaskReviewCard.selectRecurrenceUnit(.months, on: task)
        TaskReviewCard.selectMonthlyScope(.weekdayOfMonth, on: task)
        TaskReviewCard.selectRelativeOrdinal(.fourth, on: task)
        TaskReviewCard.selectRelativeWeekday(7, on: task) // Saturday

        XCTAssertEqual(task.recurrenceMode, .relativeDate)
        // The fourth Saturday of September 2026 is the 26th.
        XCTAssertTrue(task.hasRecurringOccurrence(on: day(2026, 9, 26), calendar: calendar))
        XCTAssertFalse(task.hasRecurringOccurrence(on: day(2026, 9, 19), calendar: calendar))
    }

    // MARK: - Part 2: `recurrenceMode` still stored, still what the picker displays back correctly

    func test_dayOfMonthPosition_derivesFromStoredFields_bothDirections() {
        let task = makeRecurringTask()
        task.recurrenceUnit = .months

        // Never touched (fresh, `.specificDate` default) reads as "Same day."
        XCTAssertEqual(TaskReviewCard.dayOfMonthPosition(for: task), .sameAsAnchor)

        TaskReviewCard.selectDayOfMonthPosition(.first, on: task)
        XCTAssertEqual(TaskReviewCard.dayOfMonthPosition(for: task), .first)

        TaskReviewCard.selectDayOfMonthPosition(.last, on: task)
        XCTAssertEqual(TaskReviewCard.dayOfMonthPosition(for: task), .last)

        TaskReviewCard.selectDayOfMonthPosition(.sameAsAnchor, on: task)
        XCTAssertEqual(TaskReviewCard.dayOfMonthPosition(for: task), .sameAsAnchor)
    }

    // MARK: - Migration: existing rows of both modes evaluate identically after the flag backfill

    /// The far more common, longstanding case: a pre-existing task that
    /// was always Specific Date + monthly (recurring on the same day
    /// every month), created before `relativeRecurrencePicked` gated on
    /// `recurrenceUnit` at all — simulated here exactly as real old data
    /// would look, with the flag still at its stored default (`false`).
    func test_migration_existingSpecificDateMonthlyTask_readsAsMissingBeforeBackfill_notAfter() {
        let task = makeUnconfiguredRecurringTask()
        task.dueDate = day(2026, 9, 17)
        task.recurrenceUnit = .months
        task.recurrenceMode = .specificDate
        task.recurrenceIntervalPicked = true
        // Pre-existing data: never touched, since this flag didn't
        // gate anything for Specific Date before this change.
        XCTAssertFalse(task.relativeRecurrencePicked)

        XCTAssertTrue(task.missingAttributeNames(consideringShelf: task.shelf).contains("Pattern"))

        TaskReviewCard.backfillRelativeRecurrencePickedIfNeeded(task)

        XCTAssertTrue(task.relativeRecurrencePicked)
        XCTAssertFalse(task.missingAttributeNames(consideringShelf: task.shelf).contains("Pattern"))
    }

    /// The backfill only ever touches the "picked" bookkeeping — it must
    /// never change which dates the task actually recurs on.
    func test_migration_doesNotChangeWhichDatesRecur_specificDateMonthly() {
        let anchor = day(2026, 9, 17)
        let task = makeRecurringTask()
        task.dueDate = anchor
        task.recurrenceUnit = .months
        task.recurrenceMode = .specificDate

        let before = (1...31).map { day(2026, 10, min($0, 30)) }.map {
            task.hasRecurringOccurrence(on: $0, calendar: calendar)
        }

        TaskReviewCard.backfillRelativeRecurrencePickedIfNeeded(task)

        let after = (1...31).map { day(2026, 10, min($0, 30)) }.map {
            task.hasRecurringOccurrence(on: $0, calendar: calendar)
        }

        XCTAssertEqual(before, after)
    }

    /// A pre-existing Relative Date task already had this flag set true
    /// by the old Pattern picker — the backfill must leave it, and the
    /// task's evaluation, untouched (not a no-op guard bug that
    /// accidentally re-decides anything).
    func test_migration_existingRelativeDateTask_alreadyPicked_backfillIsANoOp() {
        let anchor = day(2026, 9, 1)
        let task = makeRecurringTask()
        task.dueDate = anchor
        task.recurrenceUnit = .months
        task.recurrenceMode = .relativeDate
        task.relativeRecurrenceScope = .weekdayOfMonth
        task.relativeRecurrenceOrdinal = .fourth
        task.relativeRecurrenceWeekday = 7
        task.relativeRecurrencePicked = true

        let beforeOccurrence = task.hasRecurringOccurrence(on: day(2026, 9, 26), calendar: calendar)

        TaskReviewCard.backfillRelativeRecurrencePickedIfNeeded(task)

        XCTAssertTrue(task.relativeRecurrencePicked)
        XCTAssertEqual(task.hasRecurringOccurrence(on: day(2026, 9, 26), calendar: calendar), beforeOccurrence)
        XCTAssertTrue(beforeOccurrence)
    }

    /// A daily/weekly task is never affected by the backfill at all —
    /// `relativeRecurrencePicked` isn't checked for it either way.
    func test_migration_nonMonthlyTask_backfillIsANoOp() {
        let task = makeUnconfiguredRecurringTask()
        task.dueDate = day(2026, 9, 1)
        task.recurrenceUnit = .days
        task.recurrenceIntervalPicked = true
        XCTAssertFalse(task.relativeRecurrencePicked)

        TaskReviewCard.backfillRelativeRecurrencePickedIfNeeded(task)

        XCTAssertFalse(task.relativeRecurrencePicked)
        XCTAssertFalse(task.missingAttributeNames(consideringShelf: task.shelf).contains("Pattern"))
    }

    /// A genuinely fresh, never-configured monthly task (no anchor yet)
    /// must NOT get backfilled — there's nothing to prove it was ever
    /// really configured, so it should still correctly read as missing
    /// and prompt the user, same as before this migration existed.
    func test_migration_freshUnconfiguredTask_isNotBackfilled() {
        let task = makeUnconfiguredRecurringTask()
        task.recurrenceUnit = .months
        XCTAssertNil(task.dueDate)

        TaskReviewCard.backfillRelativeRecurrencePickedIfNeeded(task)

        XCTAssertFalse(task.relativeRecurrencePicked)
    }

    // MARK: - Fixed-width columns: regression net for the "picked" tripwires above

    /// `PickedMenuPicker` fixes its value column to the widest of
    /// whatever's in its `options` array, measured live via SwiftUI
    /// layout (see that type's own doc comment) — so the resize jump
    /// itself can't silently come back through this mechanism: any
    /// option added to a picker's `options` list is automatically
    /// included in that measurement, by construction, with nothing here
    /// to fall out of date.
    ///
    /// What *can* silently drift is the render test's own fixture
    /// (`RecurringTaskCardRenderTests.makeWorstCaseRelativeTask`), which
    /// names specific values ("Day of Week," "Fourth," "Wednesday,"
    /// "Specific Time") as "the widest option" by hand. These tests pin
    /// today's actual widest label for every option set a
    /// `PickedMenuPicker` on this card uses — if a future option is ever
    /// added or renamed to something longer, one of these fails, forcing
    /// a conscious look at whether the render fixture (and its
    /// screenshot) still needs updating, rather than that fixture
    /// quietly continuing to exercise a value that's no longer actually
    /// the worst case.
    func test_widestOptionLabel_recurrenceUnit_isMonths() {
        let widest = RecurrenceUnit.allCases.map { $0.label(for: 2) }.max(by: { $0.count < $1.count })
        XCTAssertEqual(widest, "months")
    }

    func test_widestOptionLabel_habitOccurrenceTimeMode_isSpecificTime() {
        let widest = HabitOccurrenceTimeMode.allCases.map(\.label).max(by: { $0.count < $1.count })
        XCTAssertEqual(widest, "Specific Time")
    }

    func test_widestOptionLabel_relativeRecurrenceScope_isDayOfMonth() {
        let widest = RelativeRecurrenceScope.allCases.map(\.label).max(by: { $0.count < $1.count })
        XCTAssertEqual(widest, "Day of month")
    }

    func test_widestOptionLabel_dayOfMonthPosition_isFirstDay() {
        let widest = TaskReviewCard.DayOfMonthPosition.allCases.map(\.label).max(by: { $0.count < $1.count })
        XCTAssertEqual(widest, "First day", "\"First day\" (9) edges out \"Last day\"/\"Same day\" (8 each)")
    }

    func test_widestOptionLabel_relativeRecurrenceOrdinal_isFourthOrSecondOrThird() {
        let widest = RelativeRecurrenceOrdinal.allCases.map(\.label).max(by: { $0.count < $1.count })
        XCTAssertEqual(widest?.count, 6, "\"Second\"/\"Third\"/\"Fourth\" are all 6 characters — the render fixture uses \"Fourth\"")
    }

    func test_widestOptionLabel_weekdaySymbols_isWednesday() {
        let widest = Calendar.current.weekdaySymbols.max(by: { $0.count < $1.count })
        XCTAssertEqual(widest, "Wednesday")
    }
}
