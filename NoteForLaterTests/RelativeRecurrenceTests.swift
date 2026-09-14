import XCTest
import SwiftData
@testable import NoteForLater

/// Coverage for Relative Date recurrence (`RecurrenceMode.relativeDate`) —
/// a second evaluator behind `TaskItem.hasRecurringOccurrence`'s one public
/// entry point, alongside the original interval+unit+anchor evaluator
/// (`RecurrenceMode.specificDate`, unchanged). See that method's own doc
/// comment for why every real caller only ever goes through it, never the
/// two private `hasSpecificDateOccurrence`/`hasRelativeDateOccurrence`
/// implementations directly.
///
/// Central invariant under test throughout: every pattern
/// `hasRelativeDateOccurrence` can express resolves to exactly one real day
/// in every month, with no skip or fallback logic — see that function's own
/// doc comment. `RelativeRecurrenceOrdinal` deliberately stops at
/// `.fourth`/`.last` (no `.fifth`) specifically so this holds.
final class RelativeRecurrenceTests: XCTestCase {
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
            for: TaskItem.self, ScheduledBlock.self, Shelf.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    private func makeRelativeTask(
        anchor: Date,
        intervalMonths: Int = 1,
        scope: RelativeRecurrenceScope,
        ordinal: RelativeRecurrenceOrdinal,
        weekday: Int? = nil
    ) -> TaskItem {
        let task = TaskItem(title: "Relative task", dueDate: anchor, estimatedMinutes: 15)
        task.isRecurring = true
        task.recurrenceIntervalCount = intervalMonths
        task.recurrenceMode = .relativeDate
        task.relativeRecurrenceScope = scope
        task.relativeRecurrenceOrdinal = ordinal
        task.relativeRecurrenceWeekday = weekday
        context.insert(task)
        return task
    }

    // MARK: - Fail-then-pass target: last day of the month

    /// Fail-then-pass target. Confirmed against a 31-day month, a 28-day
    /// month (Feb 2026, not a leap year), and a 30-day month — "last day"
    /// must track each month's own real length, never a fixed day number.
    func test_lastDayOfMonth_tracksEachMonthsOwnLength() {
        let task = makeRelativeTask(anchor: day(2026, 1, 1), scope: .dayOfMonth, ordinal: .last)

        XCTAssertTrue(task.hasRecurringOccurrence(on: day(2026, 1, 31), calendar: calendar), "January has 31 days")
        XCTAssertFalse(task.hasRecurringOccurrence(on: day(2026, 1, 30), calendar: calendar))
        XCTAssertTrue(task.hasRecurringOccurrence(on: day(2026, 2, 28), calendar: calendar), "February 2026 is not a leap year — 28 days")
        XCTAssertFalse(task.hasRecurringOccurrence(on: day(2026, 2, 27), calendar: calendar))
        XCTAssertTrue(task.hasRecurringOccurrence(on: day(2026, 4, 30), calendar: calendar), "April has 30 days")
        XCTAssertFalse(task.hasRecurringOccurrence(on: day(2026, 4, 29), calendar: calendar))
    }

    /// Leap year: last day of February must be the 29th, not a hardcoded 28.
    func test_lastDayOfMonth_leapYearFebruary_isThe29th() {
        let task = makeRelativeTask(anchor: day(2028, 1, 1), scope: .dayOfMonth, ordinal: .last)

        XCTAssertTrue(calendar.dateComponents([.year], from: day(2028, 2, 1)).year != nil) // sanity: 2028 exists
        XCTAssertTrue(task.hasRecurringOccurrence(on: day(2028, 2, 29), calendar: calendar), "2028 is a leap year")
        XCTAssertFalse(task.hasRecurringOccurrence(on: day(2028, 2, 28), calendar: calendar), "the 28th is not the last day in a leap year")
    }

    // MARK: - First day of the month

    func test_firstDayOfMonth_matchesOnlyTheFirst() {
        let task = makeRelativeTask(anchor: day(2026, 1, 1), scope: .dayOfMonth, ordinal: .first)

        XCTAssertTrue(task.hasRecurringOccurrence(on: day(2026, 3, 1), calendar: calendar))
        XCTAssertFalse(task.hasRecurringOccurrence(on: day(2026, 3, 2), calendar: calendar))
        XCTAssertFalse(task.hasRecurringOccurrence(on: day(2026, 3, 31), calendar: calendar))
    }

    // MARK: - Fail-then-pass target: first Saturday of the month

    /// Fail-then-pass target. January 2026's Saturdays: 3, 10, 17, 24, 31.
    func test_firstSaturdayOfMonth() {
        let task = makeRelativeTask(anchor: day(2026, 1, 3), scope: .weekdayOfMonth, ordinal: .first, weekday: 7)

        XCTAssertTrue(task.hasRecurringOccurrence(on: day(2026, 1, 3), calendar: calendar))
        XCTAssertFalse(task.hasRecurringOccurrence(on: day(2026, 1, 10), calendar: calendar), "second Saturday must not match 'first'")
        XCTAssertFalse(task.hasRecurringOccurrence(on: day(2026, 1, 2), calendar: calendar), "a Friday must never match regardless of position")
    }

    // MARK: - Every offered weekday-of-month ordinal always exists

    /// Every month is at least 28 days (4 full weeks), so 1st–4th
    /// <weekday> always exist — no month can be missing one. Verified
    /// across all four ordinals in the same 30-day month (September
    /// 2026, Saturdays: 5, 12, 19, 26).
    func test_firstThroughFourthSaturday_allExistInTheSameMonth() {
        let saturdays: [RelativeRecurrenceOrdinal: Int] = [.first: 5, .second: 12, .third: 19, .fourth: 26]
        for (ordinal, expectedDay) in saturdays {
            let task = makeRelativeTask(anchor: day(2026, 9, 1), scope: .weekdayOfMonth, ordinal: ordinal, weekday: 7)
            XCTAssertTrue(task.hasRecurringOccurrence(on: day(2026, 9, expectedDay), calendar: calendar), "\(ordinal) Saturday should be Sept \(expectedDay)")
        }
    }

    /// A 28-day February has exactly 4 Saturdays — "4th" and "Last" must
    /// agree on the same day here, confirming "4th always exists" holds
    /// even at the minimum month length.
    func test_fourthSaturday_andLastSaturday_agree_inTwentyEightDayFebruary() {
        let fourthTask = makeRelativeTask(anchor: day(2026, 1, 1), scope: .weekdayOfMonth, ordinal: .fourth, weekday: 7)
        let lastTask = makeRelativeTask(anchor: day(2026, 1, 1), scope: .weekdayOfMonth, ordinal: .last, weekday: 7)

        XCTAssertTrue(fourthTask.hasRecurringOccurrence(on: day(2026, 2, 28), calendar: calendar))
        XCTAssertTrue(lastTask.hasRecurringOccurrence(on: day(2026, 2, 28), calendar: calendar))
    }

    /// January 2026 has 5 Saturdays — "4th" (24th) and "Last" (31st) must
    /// diverge here, since this is exactly the month-length case that
    /// would have made a "5th" ordinal sometimes present, sometimes not.
    /// "Last" is what's offered instead — it must land on the 31st, not
    /// the 24th.
    func test_fourthSaturday_andLastSaturday_diverge_inFiveSaturdayMonth() {
        let fourthTask = makeRelativeTask(anchor: day(2026, 1, 1), scope: .weekdayOfMonth, ordinal: .fourth, weekday: 7)
        let lastTask = makeRelativeTask(anchor: day(2026, 1, 1), scope: .weekdayOfMonth, ordinal: .last, weekday: 7)

        XCTAssertTrue(fourthTask.hasRecurringOccurrence(on: day(2026, 1, 24), calendar: calendar))
        XCTAssertFalse(fourthTask.hasRecurringOccurrence(on: day(2026, 1, 31), calendar: calendar))
        XCTAssertTrue(lastTask.hasRecurringOccurrence(on: day(2026, 1, 31), calendar: calendar))
        XCTAssertFalse(lastTask.hasRecurringOccurrence(on: day(2026, 1, 24), calendar: calendar))
    }

    // MARK: - `.weekOfMonth` under a non-default `firstWeekday`

    /// The Nth-weekday-of-month calculation reads `calendar.component(.weekOfMonth, from:)`,
    /// which is itself relative to `calendar.firstWeekday`. The reasoning
    /// this relies on (consecutive occurrences of the same weekday are
    /// always exactly 7 days apart, so they always cross exactly one
    /// week boundary and land in consecutive `weekOfMonth` values) should
    /// hold regardless of what `firstWeekday` is set to — verified here
    /// against a real, different `firstWeekday`, not just reasoned about.
    func test_weekOfMonthOrdinal_isStableAcrossDifferentFirstWeekday() {
        var mondayFirstCalendar = calendar
        mondayFirstCalendar.firstWeekday = 2 // Monday, ISO-style — default US calendars use 1 (Sunday)
        XCTAssertNotEqual(calendar.firstWeekday, mondayFirstCalendar.firstWeekday, "sanity: the two calendars must actually differ")

        let firstTask = makeRelativeTask(anchor: day(2026, 1, 1), scope: .weekdayOfMonth, ordinal: .first, weekday: 7)
        let secondTask = makeRelativeTask(anchor: day(2026, 1, 1), scope: .weekdayOfMonth, ordinal: .second, weekday: 7)
        let fourthTask = makeRelativeTask(anchor: day(2026, 1, 1), scope: .weekdayOfMonth, ordinal: .fourth, weekday: 7)
        let lastTask = makeRelativeTask(anchor: day(2026, 1, 1), scope: .weekdayOfMonth, ordinal: .last, weekday: 7)

        for cal in [calendar, mondayFirstCalendar] {
            XCTAssertTrue(firstTask.hasRecurringOccurrence(on: day(2026, 1, 3), calendar: cal))
            XCTAssertTrue(secondTask.hasRecurringOccurrence(on: day(2026, 1, 10), calendar: cal))
            XCTAssertTrue(fourthTask.hasRecurringOccurrence(on: day(2026, 1, 24), calendar: cal))
            XCTAssertTrue(lastTask.hasRecurringOccurrence(on: day(2026, 1, 31), calendar: cal))
            XCTAssertFalse(fourthTask.hasRecurringOccurrence(on: day(2026, 1, 31), calendar: cal), "4th must not slide onto Last's day under either firstWeekday")
        }
    }

    // MARK: - Month-interval count still applies to Relative Date

    /// "Every 2 months" must skip the in-between month even in Relative
    /// mode — `recurrenceUnit` itself is never read by this evaluator,
    /// but `recurrenceIntervalCount` (months, implicitly) still is.
    func test_monthIntervalCount_skipsNonCadenceMonths() {
        let task = makeRelativeTask(anchor: day(2026, 1, 1), intervalMonths: 2, scope: .dayOfMonth, ordinal: .last)

        XCTAssertTrue(task.hasRecurringOccurrence(on: day(2026, 1, 31), calendar: calendar), "anchor month itself")
        XCTAssertFalse(task.hasRecurringOccurrence(on: day(2026, 2, 28), calendar: calendar), "one month later — off cadence")
        XCTAssertTrue(task.hasRecurringOccurrence(on: day(2026, 3, 31), calendar: calendar), "two months later — on cadence")
    }

    // MARK: - Large-interval walks stay within the existing 366/400-day caps

    /// `nextRecurringOccurrenceDate`'s 366-day cap, exercised close to
    /// its actual limit rather than trivially. Anchor is the first
    /// Saturday of January 2026 (the 3rd); with a 12-month interval, the
    /// next occurrence after Jan 4 2026 is the first Saturday of January
    /// 2027 (the 2nd) — 363 days later. This must still be found, not
    /// silently return nil at the boundary.
    func test_nextRecurringOccurrenceDate_largeInterval_staysUnderCap() {
        let task = makeRelativeTask(anchor: day(2026, 1, 3), intervalMonths: 12, scope: .weekdayOfMonth, ordinal: .first, weekday: 7)

        let next = task.nextRecurringOccurrenceDate(asOf: day(2026, 1, 4), calendar: calendar)

        XCTAssertNotNil(next, "a real occurrence 363 days out must still be found under the 366-day cap")
        if let next {
            XCTAssertTrue(calendar.isDate(next, inSameDayAs: day(2027, 1, 2)))
        }
    }

    /// `previousRecurringOccurrenceDate`'s 400-day cap, same shape.
    /// Walking backward from Dec 31 2026 (just before the Jan 2027
    /// occurrence) must reach back to the anchor's own occurrence, Jan 3
    /// 2026 — 362 days back, under the 400-day default `scanDays`.
    func test_previousRecurringOccurrenceDate_largeInterval_staysUnderCap() {
        let task = makeRelativeTask(anchor: day(2026, 1, 3), intervalMonths: 12, scope: .weekdayOfMonth, ordinal: .first, weekday: 7)

        let previous = task.previousRecurringOccurrenceDate(onOrBefore: day(2026, 12, 31), calendar: calendar)

        XCTAssertNotNil(previous, "an occurrence 362 days back must still be found under the 400-day default scanDays")
        if let previous {
            XCTAssertTrue(calendar.isDate(previous, inSameDayAs: day(2026, 1, 3)))
        }
    }

    // MARK: - Migration: existing recurring tasks are unaffected

    /// A recurring task built the same way every existing test/task in
    /// this app already builds one — never touching `recurrenceMode` —
    /// must default to `.specificDate` and keep running through the
    /// original, unmodified evaluator.
    func test_existingRecurringTask_defaultsToSpecificDateMode_andBehavesUnchanged() {
        let task = TaskItem(title: "Water the garden", dueDate: day(2026, 1, 1), estimatedMinutes: 15)
        task.isRecurring = true
        task.recurrenceUnit = .days
        task.recurrenceIntervalCount = 3
        context.insert(task)

        XCTAssertEqual(task.recurrenceMode, .specificDate)
        XCTAssertTrue(task.hasRecurringOccurrence(on: day(2026, 1, 4), calendar: calendar), "every 3 days from Jan 1 — Jan 4 is a real occurrence")
        XCTAssertFalse(task.hasRecurringOccurrence(on: day(2026, 1, 3), calendar: calendar))
    }

    // MARK: - `recurrenceSummary`

    func test_recurrenceSummary_relativeDate_dayOfMonth_last() {
        let task = makeRelativeTask(anchor: day(2026, 1, 1), scope: .dayOfMonth, ordinal: .last)

        XCTAssertEqual(task.recurrenceSummary, "Every month on the last day")
    }

    func test_recurrenceSummary_relativeDate_weekdayOfMonth() {
        let task = makeRelativeTask(anchor: day(2026, 1, 1), intervalMonths: 2, scope: .weekdayOfMonth, ordinal: .first, weekday: 7)

        XCTAssertEqual(task.recurrenceSummary, "Every 2 months on the first Saturday")
    }
}
