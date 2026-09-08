import XCTest
import SwiftData
@testable import NoteForLater

/// Coverage for the Habits tab's Today list rework:
/// `Habit.todayOrderKey` (the fixed, non-debounced sort — replaces the old
/// `nextTargetDate`-based "what's coming up next" queue) and
/// `Habit.cycleOccurrence` (the four-state tap cycle, extracted onto the
/// model specifically so it's testable without a live `HabitsTodayView`,
/// same reasoning as `ScheduleReviewViewModel.moveExistingBlock` earlier
/// in this app's history).
final class HabitTodayViewTests: XCTestCase {
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
            for: Habit.self, HabitLog.self, ScheduledBlock.self, TaskItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    private func makeHabit(
        name: String,
        daysOfWeek: [Int] = [1, 2, 3, 4, 5, 6, 7],
        sortOrder: Int = 0,
        timeMode: HabitOccurrenceTimeMode = .specific,
        idealMinutes: Int = 540
    ) -> Habit {
        let habit = Habit(name: name, daysOfWeek: daysOfWeek, idealTimesOfDay: [idealMinutes], sortOrder: sortOrder)
        habit.occurrenceTimeModesRaw = [timeMode.rawValue]
        context.insert(habit)
        return habit
    }

    // MARK: - todayOrderKey

    /// More frequent (more days/week) sorts before less frequent —
    /// "daily before weekly" is the concrete case named in the request.
    func test_todayOrderKey_dailyBeforeWeekly() {
        let daily = makeHabit(name: "Daily", daysOfWeek: [1, 2, 3, 4, 5, 6, 7])
        let weekly = makeHabit(name: "Weekly", daysOfWeek: [2])
        XCTAssertTrue(daily.todayOrderKey < weekly.todayOrderKey)
    }

    /// Within the same frequency, AM sorts before PM.
    func test_todayOrderKey_AMBeforePM_withinSameFrequency() {
        let am = makeHabit(name: "Stretch", daysOfWeek: [1, 2, 3, 4, 5, 6, 7], timeMode: .am)
        let pm = makeHabit(name: "Wind Down", daysOfWeek: [1, 2, 3, 4, 5, 6, 7], timeMode: .pm)
        XCTAssertTrue(am.todayOrderKey < pm.todayOrderKey)
    }

    /// A 7am Specific-Time occurrence and an AM-mode occurrence land at
    /// the same representative minute, exactly the "sort together
    /// sensibly" behavior the request called for — asserted here as
    /// "tied, so the stable tiebreak decides" rather than one arbitrarily
    /// outranking the other.
    func test_todayOrderKey_specificAt7AM_tiesWithAMMode() {
        let specific7am = makeHabit(name: "B", timeMode: .specific, idealMinutes: 7 * 60)
        let amMode = makeHabit(name: "A", timeMode: .am)
        // The time-of-day component itself must be equal — checked
        // directly, not via the full `<` operator, since that cascades
        // into `sortOrder`/`name` tiebreaks that make two *different*
        // habits compare unequal even once their time-of-day genuinely
        // ties (as it should, deterministically, once the primary keys
        // are equal).
        XCTAssertEqual(specific7am.todayOrderKey.occurrenceZeroMinutes, amMode.todayOrderKey.occurrenceZeroMinutes)
        XCTAssertEqual(specific7am.todayOrderKey.frequencyRank, amMode.todayOrderKey.frequencyRank)
    }

    /// Same frequency and time-of-day: falls through to `sortOrder`, then
    /// `name` — deterministic every time, not incidental array order.
    func test_todayOrderKey_stableTiebreak_sortOrderThenName() {
        let first = makeHabit(name: "Zzz", sortOrder: 0)
        let second = makeHabit(name: "Aaa", sortOrder: 1)
        XCTAssertTrue(first.todayOrderKey < second.todayOrderKey, "lower sortOrder wins even though its name sorts later")

        let alsoZero1 = makeHabit(name: "Banana", sortOrder: 5)
        let alsoZero2 = makeHabit(name: "Apple", sortOrder: 5)
        XCTAssertTrue(alsoZero2.todayOrderKey < alsoZero1.todayOrderKey, "equal sortOrder falls through to name")
    }

    // MARK: - cycleOccurrence — the four-state cycle

    /// none → complete → missed → excused → none, and back to `.complete`
    /// on a fifth tap — the wrap actually wraps, not just stops at
    /// `.excused`.
    ///
    /// Verified fail-then-pass: with `cycleOccurrence` temporarily
    /// reverted to the old boolean toggle (`status != .complete ? .complete
    /// : .none`, the pre-fix "only complete/unselected" behavior), this
    /// test failed at the second tap — status came back `.none` instead
    /// of `.missed`, `.missed`/`.excused` never reachable at all.
    /// Restored the real cycle and reran: green. Both via `xcodebuild
    /// test`.
    func test_cycleOccurrence_advancesThroughAllFourStates_andWraps() {
        let habit = makeHabit(name: "Floss")
        let today = calendar.startOfDay(for: .now)

        let s1 = habit.cycleOccurrence(0, on: today, context: context, calendar: calendar)
        XCTAssertEqual(s1, .complete)
        let s2 = habit.cycleOccurrence(0, on: today, context: context, calendar: calendar)
        XCTAssertEqual(s2, .missed)
        let s3 = habit.cycleOccurrence(0, on: today, context: context, calendar: calendar)
        XCTAssertEqual(s3, .excused)
        let s4 = habit.cycleOccurrence(0, on: today, context: context, calendar: calendar)
        XCTAssertEqual(s4, .none)
        let s5 = habit.cycleOccurrence(0, on: today, context: context, calendar: calendar)
        XCTAssertEqual(s5, .complete, "must wrap back around, not stop at .none")
    }

    /// `block.isCompleted` is `true` only for `.complete` — confirmed for
    /// `.missed` and `.excused` specifically, since a block's own flag
    /// can't distinguish the two and nothing downstream should be reading
    /// it expecting to.
    func test_cycleOccurrence_blockIsCompletedOnlyTrueForComplete() {
        let habit = makeHabit(name: "Meditate")
        let today = calendar.startOfDay(for: .now)
        let start = calendar.date(byAdding: .hour, value: 7, to: today)!
        let block = ScheduledBlock(date: today, startTime: start, endTime: calendar.date(byAdding: .minute, value: 10, to: start)!, task: nil, habit: habit, habitOccurrenceIndex: 0)
        context.insert(block)

        habit.cycleOccurrence(0, on: today, context: context, calendar: calendar) // -> complete
        XCTAssertTrue(block.isCompleted)
        habit.cycleOccurrence(0, on: today, context: context, calendar: calendar) // -> missed
        XCTAssertFalse(block.isCompleted, "missed must not read as completed")
        habit.cycleOccurrence(0, on: today, context: context, calendar: calendar) // -> excused
        XCTAssertFalse(block.isCompleted, "excused must not read as completed")
    }

    // MARK: - Editing a non-today date

    /// Cycling an occurrence for a past day must write that day's log,
    /// not today's — the whole point of the date navigation feature.
    ///
    /// Verified fail-then-pass: with `cycleOccurrence` temporarily
    /// hardcoded to ignore its `date` parameter and always resolve
    /// against `.now` (reproducing "editing three days ago silently
    /// edits today instead"), this test failed — the past day's status
    /// came back `.none` (nothing was ever written there) while today's
    /// picked up the `.complete` that should have landed three days back.
    /// Restored the real parameterized write and reran: green. Both via
    /// `xcodebuild test`.
    func test_cycleOccurrence_onPastDate_writesThatDatesLog_notToday() {
        let habit = makeHabit(name: "Read")
        let today = calendar.startOfDay(for: .now)
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: today)!

        habit.cycleOccurrence(0, on: threeDaysAgo, context: context, calendar: calendar)

        let pastStatus = habit.logOrCreate(on: threeDaysAgo, context: context, calendar: calendar).occurrenceStatus(0)
        let todayStatus = habit.logOrCreate(on: today, context: context, calendar: calendar).occurrenceStatus(0)

        XCTAssertEqual(pastStatus, .complete, "the edit must land on the day that was actually being edited")
        XCTAssertEqual(todayStatus, .none, "today's own log must be untouched by an edit made on a different day")

        let allLogs = try? context.fetch(FetchDescriptor<HabitLog>())
        XCTAssertEqual(allLogs?.filter { calendar.isDate($0.date, inSameDayAs: threeDaysAgo) }.count, 1, "exactly one log for the edited day, not a duplicate")
    }
}
