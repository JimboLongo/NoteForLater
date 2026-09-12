import XCTest
@testable import NoteForLater

/// Coverage for combining a recurring task's frequency and next occurrence
/// onto one line (`ShelfListView.TaskRow.recurrenceLine`) instead of two
/// separate rows, and the disambiguation rule for how much of the next
/// occurrence's date to show (`TaskRow.recurrenceNextOccurrenceLabel`).
///
/// No `ModelContainer` needed — `TaskItem` can be constructed and read
/// directly, same as `TaskAttributeToggleTests`.
final class ShelfListRecurrenceLineTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth))!
    }

    private func weekdayAbbreviation(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }

    // MARK: - Disambiguation rule

    /// A Wednesday reference day; six days out lands on the following
    /// Tuesday — still inside the "unambiguous" window.
    func test_nextOccurrenceLabel_withinSixDays_isBareWeekday() {
        let today = day(2026, 9, 9) // Wednesday
        let sixDaysOut = calendar.date(byAdding: .day, value: 6, to: today)!

        let label = TaskRow.recurrenceNextOccurrenceLabel(for: sixDaysOut, today: today, calendar: calendar)

        XCTAssertEqual(label, weekdayAbbreviation(for: sixDaysOut), "6 days out is still unambiguous — bare weekday only")
    }

    /// Fail-then-pass target: the boundary between "bare weekday" and
    /// "needs disambiguation" — one day further than the previous case
    /// must switch to including month/day.
    func test_nextOccurrenceLabel_sevenDaysOut_addsMonthAndDay() {
        let today = day(2026, 9, 9)
        let sevenDaysOut = calendar.date(byAdding: .day, value: 7, to: today)!

        let label = TaskRow.recurrenceNextOccurrenceLabel(for: sevenDaysOut, today: today, calendar: calendar)

        XCTAssertNotEqual(label, weekdayAbbreviation(for: sevenDaysOut), "7 days out is ambiguous on a bare weekday — must disambiguate")
        XCTAssertTrue(label.contains("Sep"), "should include the month once disambiguating")
        XCTAssertTrue(label.contains("16"), "should include the day once disambiguating")
        XCTAssertFalse(label.contains("2026"), "same calendar year as today — no year needed")
    }

    /// Same-year far-out date must not carry a year at all — only the
    /// cross-year case (below) does.
    func test_nextOccurrenceLabel_farButSameYear_omitsYear() {
        let today = day(2026, 1, 1)
        let farOut = day(2026, 6, 15)

        let label = TaskRow.recurrenceNextOccurrenceLabel(for: farOut, today: today, calendar: calendar)

        XCTAssertFalse(label.contains("2026"))
    }

    /// A yearly-recurring task whose next occurrence is far enough out
    /// (so it's already in the month/day branch, not the bare-weekday
    /// one) *and* lands in the next calendar year — "Jan 15" alone would
    /// read ambiguously close to the boundary, so the year is added too.
    /// A year-crossing occurrence that's still within the near (≤6 day)
    /// window does *not* need this: a bare weekday like "Sun" only ever
    /// means "the very next one," regardless of which year its actual
    /// calendar date happens to fall in — there's no month/day shown
    /// there for a year to disambiguate in the first place.
    func test_nextOccurrenceLabel_crossesIntoNextYear_includesYear() {
        let today = day(2026, 12, 20)
        let farNextYear = day(2027, 1, 15)

        let label = TaskRow.recurrenceNextOccurrenceLabel(for: farNextYear, today: today, calendar: calendar)

        XCTAssertTrue(label.contains("2027"), "must disambiguate the year once the occurrence crosses into a new one")
    }

    // MARK: - recurrenceLine: one line, not two

    func test_recurrenceLine_combinesFrequencyAndNextOccurrence() {
        let today = calendar.startOfDay(for: .now)
        let task = TaskItem(title: "Water the garden", dueDate: today, estimatedMinutes: 10)
        task.isRecurring = true
        task.recurrenceUnit = .days
        task.recurrenceIntervalCount = 1

        let row = TaskRow(task: task, showsScheduledBadge: true)
        let line = row.recurrenceLine

        XCTAssertNotNil(line)
        let parts = line?.components(separatedBy: " · ")
        XCTAssertEqual(parts?.count, 2, "frequency and next occurrence must be one line, not two")
        XCTAssertEqual(parts?.first, task.recurrenceSummary)
        XCTAssertEqual(parts?.last, weekdayAbbreviation(for: .now), "a daily task's next occurrence is always today")
    }

    func test_recurrenceLine_nilForNonRecurringTask() {
        let task = TaskItem(title: "Plain task", estimatedMinutes: 10)
        let row = TaskRow(task: task, showsScheduledBadge: true)

        XCTAssertNil(row.recurrenceLine)
    }
}
