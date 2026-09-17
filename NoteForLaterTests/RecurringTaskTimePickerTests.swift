import XCTest
import SwiftData
@testable import NoteForLater

/// Coverage for the Specific-Time picker on a recurring task
/// (`TaskItem.recurrenceTimeOfDayMinutes`) — previously the calendar time
/// was an invisible side effect of `dueDate`'s own time-of-day (the
/// recurrence anchor), set once by `makeRecurring()`'s 9am default and
/// never otherwise editable. `recurrenceTimeOfDayMinutes` is a field of
/// its own, deliberately: `dueDate`'s time-of-day is now only ever a
/// fallback for a task that's never touched the picker, read through
/// `effectiveRecurrenceTimeOfDayMinutes`/`recurringOccurrenceTime` — the
/// one place every real caller (real placement, the future-day
/// projection, the push-forward placeholder relocation) already goes
/// through.
final class RecurringTaskTimePickerTests: XCTestCase {
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

    // MARK: - Fail-then-pass target: setting a time places the occurrence there

    func test_settingRecurrenceTimeOfDay_placesOccurrenceAtThatTime() {
        let anchor = day(2026, 9, 1) // midnight, no time-of-day set
        let task = makeSpecificTimeTask(anchor: anchor)
        task.recurrenceTimeOfDayMinutes = 14 * 60 + 30 // 2:30 PM

        let occurrenceTime = task.recurringOccurrenceTime(on: day(2026, 9, 5), calendar: calendar)

        let components = calendar.dateComponents([.hour, .minute], from: occurrenceTime!)
        XCTAssertEqual(components.hour, 14)
        XCTAssertEqual(components.minute, 30)
    }

    // MARK: - The projection for a future day uses it too

    // MARK: - Switching modes and back preserves the time

    func test_switchingAwayFromSpecificAndBack_preservesTimeOfDay() {
        let task = makeSpecificTimeTask(anchor: day(2026, 9, 1))
        task.recurrenceTimeOfDayMinutes = 20 * 60 // 8 PM

        task.recurrenceTimeMode = .am
        task.recurrenceTimeMode = .midday
        // Legacy row shape: the setter refuses `.specific` for tasks now
        // (see `TaskItem.recurrenceTimeMode`), so this writes the raw
        // column directly, which is exactly the pre-migration state
        // `migrateRecurringSpecificTimeTasksIfNeeded` exists to clear. The
        // machinery under test is retired but not yet deleted — see stage
        // 4b — so it stays covered until it goes.
        task.recurrenceTimeModeRaw = HabitOccurrenceTimeMode.specific.rawValue

        XCTAssertEqual(task.recurrenceTimeOfDayMinutes, 20 * 60)
        let occurrenceTime = task.recurringOccurrenceTime(on: day(2026, 9, 10), calendar: calendar)
        XCTAssertEqual(calendar.component(.hour, from: occurrenceTime!), 20)
    }

    // MARK: - An existing recurring task with no explicit time still works

    func test_noExplicitTimeSet_fallsBackToDueDatesTimeOfDay() {
        let anchor = calendar.date(bySettingHour: 16, minute: 45, second: 0, of: day(2026, 9, 1))!
        let task = makeSpecificTimeTask(anchor: anchor)
        XCTAssertNil(task.recurrenceTimeOfDayMinutes, "a task predating this feature has never set this field")

        let occurrenceTime = task.recurringOccurrenceTime(on: day(2026, 9, 8), calendar: calendar)

        let components = calendar.dateComponents([.hour, .minute], from: occurrenceTime!)
        XCTAssertEqual(components.hour, 16, "must keep placing at the anchor's own time until the picker is actually touched")
        XCTAssertEqual(components.minute, 45)
    }

    func test_effectiveRecurrenceTimeOfDayMinutes_prefersExplicitOverFallback() {
        let anchor = calendar.date(bySettingHour: 16, minute: 45, second: 0, of: day(2026, 9, 1))!
        let task = makeSpecificTimeTask(anchor: anchor)
        task.recurrenceTimeOfDayMinutes = 9 * 60

        XCTAssertEqual(task.effectiveRecurrenceTimeOfDayMinutes, 9 * 60)
    }

    // MARK: - Changing the time moves already-generated future blocks

    // MARK: - `QuarterHourClockTime` — the Occurrence Time wheels' own conversion

    /// Fail-then-pass target: every valid combination the three wheels
    /// can actually select (hour 1–12, minute one of 0/15/30/45, AM or
    /// PM) must round-trip through minutes-since-midnight and back to
    /// the exact same triplet — the wheels only ever offer these finite,
    /// bounded values, so there's no wrapping/invalid state to land on
    /// (unlike the old `UIDatePicker`-backed control, which spun forever
    /// in `.time` mode regardless of `minuteInterval`).
    func test_quarterHourClockTime_allWheelCombinations_roundTripExactly() {
        for hour in 1...12 {
            for minute in [0, 15, 30, 45] {
                for isPM in [false, true] {
                    let clock = QuarterHourClockTime(hour12: hour, minute: minute, isPM: isPM)
                    let minutes = clock.minutesSinceMidnight

                    XCTAssertTrue((0..<1440).contains(minutes), "minutesSinceMidnight must always land in a single valid day, got \(minutes)")

                    let roundTripped = QuarterHourClockTime(minutesSinceMidnight: minutes)
                    XCTAssertEqual(roundTripped, clock, "hour \(hour), minute \(minute), PM \(isPM) must round-trip exactly")
                }
            }
        }
    }

    func test_quarterHourClockTime_midnight_isTwelveAM() {
        let clock = QuarterHourClockTime(minutesSinceMidnight: 0)

        XCTAssertEqual(clock.hour12, 12)
        XCTAssertEqual(clock.minute, 0)
        XCTAssertFalse(clock.isPM)
    }

    func test_quarterHourClockTime_noon_isTwelvePM() {
        let clock = QuarterHourClockTime(minutesSinceMidnight: 12 * 60)

        XCTAssertEqual(clock.hour12, 12)
        XCTAssertEqual(clock.minute, 0)
        XCTAssertTrue(clock.isPM)
    }

    func test_quarterHourClockTime_afternoon_convertsToPM() {
        // 2:30 PM
        let clock = QuarterHourClockTime(minutesSinceMidnight: 14 * 60 + 30)

        XCTAssertEqual(clock.hour12, 2)
        XCTAssertEqual(clock.minute, 30)
        XCTAssertTrue(clock.isPM)
    }
}
