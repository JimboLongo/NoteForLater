import XCTest
import SwiftData
@testable import NoteForLater

/// Coverage for the two rules that decide whether a **habit** occurrence
/// gets a real `ScheduledBlock`:
///
/// 1. `placeHabitsAndRecurringTasks` places a block for a Specific-Time
///    occurrence and, crucially, *not* for an AM/Midday/PM one — those
///    surface as untimed list items instead.
/// 2. `removeStaleNonSpecificHabitBlocksAcrossFutureDays` sweeps a future
///    block belonging to an occurrence since switched *off* Specific Time,
///    and leaves a still-Specific one alone.
///
/// **Why this file exists.** Both rules were caught by exactly zero of 553
/// tests. Found by sabotaging each against the existing suite — dropping
/// the `.specific` guard so every untimed habit got a calendar block, and
/// neutering the sweep so stale ones were never cleaned up — and watching
/// the suite stay green both times. Nothing called
/// `placeHabitsAndRecurringTasks` at all, which turned out to have a cause
/// rather than being an oversight (see the `async` note below).
///
/// It surfaced while removing the *task* side of both functions: the habit
/// arm and the task arm live in the same function bodies, so deleting one
/// meant cutting directly beside a path nothing verified. These tests land
/// first so that deletion has something to fail against.
///
/// ⚠️ **Every test here must be `async`.** A synchronous test that merely
/// constructs `MockAISchedulingService` crashes the whole test host with
/// `malloc: pointer being freed was not allocated`, before any assertion
/// runs, taking the entire run down with it (`Executed 0 tests`). Marking
/// the test `async` is the entire fix. This is the same hazard already
/// recorded for `ScheduleReviewViewModel`, and it is *broader* than that
/// note says: it applies to these scheduling service objects too, and to
/// bare construction, not only to a view model's `deinit`. It is also the
/// likeliest reason this code had no coverage — a first attempt to add
/// some presents as a crash in the production code rather than as a rule
/// about the test harness.
final class HabitUntimedBlockPlacementTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self,
                SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self,
                Habit.self, HabitLog.self, MealSelection.self, Recipe.self,
                PushRecursionWarning.self, TaskCompletionRecord.self, RecurringTaskLog.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    private var calendar: Calendar { .current }

    /// Tomorrow — comfortably inside the habit's `startDate`, with every
    /// weekday enabled, so `daysOfWeek` can never be the reason a placement
    /// is skipped. The time mode must be the only variable.
    private func testDay() -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now))!
    }

    private func makeHabit(mode: HabitOccurrenceTimeMode, name: String = "Stretch") throws -> Habit {
        let habit = Habit(
            name: name,
            startDate: calendar.date(byAdding: .day, value: -30, to: .now)!,
            reminderTimesOfDay: [9 * 60]
        )
        habit.occurrenceTimeModesRaw = [mode.rawValue]
        context.insert(habit)
        try context.save()
        return habit
    }

    /// A wide-open day, so nothing about slot availability can explain a
    /// missing block. A Specific-Time habit is placed at its own anchor
    /// regardless of free slots, but keeping the day open removes the
    /// question entirely.
    private func wholeDayFree(_ date: Date) -> [TimeSlot] {
        let start = calendar.date(byAdding: .hour, value: 6, to: calendar.startOfDay(for: date))!
        return [TimeSlot(start: start, end: calendar.date(byAdding: .hour, value: 16, to: start)!)]
    }

    private func place(_ habits: [Habit], on date: Date) -> [ScheduledBlock] {
        MockAISchedulingService().placeHabitsAndRecurringTasks(
            shelves: [],
            habits: habits,
            freeSlots: wholeDayFree(date),
            eligibleHoursWindows: [],
            date: date,
            context: context
        ).blocks
    }

    // MARK: - Rule 1: only Specific Time gets a calendar block

    /// The positive half. Without it, a sabotage that stopped placing
    /// *anything* would also satisfy the negative test below, and the pair
    /// would prove nothing.
    func test_specificTimeHabitOccurrence_getsABlock() async throws {
        let habit = try makeHabit(mode: .specific)

        let blocks = place([habit], on: testDay())

        XCTAssertEqual(blocks.count, 1)
        let block = try XCTUnwrap(blocks.first)
        XCTAssertEqual(block.habit?.id, habit.id)
        XCTAssertEqual(calendar.component(.hour, from: block.startTime), 9, "placed at its own anchor time")
    }

    /// The rule the sabotage proved was unguarded: an untimed occurrence
    /// gets **no** block. It renders as a list item in the day's
    /// Morning/Midday/Evening section instead, completion tracked in
    /// `HabitLog` rather than on a block.
    func test_untimedHabitOccurrence_getsNoBlock() async throws {
        for mode in [HabitOccurrenceTimeMode.am, .midday, .pm] {
            let habit = try makeHabit(mode: mode, name: "Stretch \(mode.rawValue)")

            XCTAssertTrue(place([habit], on: testDay()).isEmpty, "\(mode) must not be placed on the calendar")
        }
    }

    /// Mixed occurrences on one habit: only the Specific-Time one is
    /// placed. Pins that the guard reads the *occurrence index* rather than
    /// the habit as a whole — an off-by-one there would be invisible to the
    /// single-occurrence tests above.
    func test_mixedOccurrences_onlyTheSpecificOneIsPlaced() async throws {
        let habit = Habit(
            name: "Water",
            startDate: calendar.date(byAdding: .day, value: -30, to: .now)!,
            timesPerDay: 2,
            reminderTimesOfDay: [8 * 60, 14 * 60]
        )
        habit.occurrenceTimeModesRaw = [HabitOccurrenceTimeMode.am.rawValue, HabitOccurrenceTimeMode.specific.rawValue]
        context.insert(habit)
        try context.save()

        let blocks = place([habit], on: testDay())

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(try XCTUnwrap(blocks.first).habitOccurrenceIndex, 1, "the AM occurrence must not be placed")
    }

    // MARK: - Rule 2: switching a habit off Specific Time sweeps its future blocks

    @discardableResult
    private func makeBlock(for habit: Habit, daysAhead: Int, complete: Bool = false) -> ScheduledBlock {
        let day = calendar.date(byAdding: .day, value: daysAhead, to: calendar.startOfDay(for: .now))!
        let start = calendar.date(byAdding: .hour, value: 9, to: day)!
        let block = ScheduledBlock(date: day, startTime: start, endTime: start.addingTimeInterval(900), task: nil, habit: habit)
        block.status = complete ? .complete : .none
        context.insert(block)
        return block
    }

    /// `removeStaleNonSpecificHabitBlocksAcrossFutureDays` is private, so
    /// this drives it through its only caller, the auto-place pass — the
    /// same route real use takes, since the sweep has no trigger of its own.
    @MainActor
    private func sweep() async {
        let viewModel = ScheduleReviewViewModel(
            modelContext: context,
            calendarService: FakeCalendarService(),
            schedulingService: MockAISchedulingService(),
            targetDate: calendar.startOfDay(for: .now)
        )
        await viewModel.autoPlaceEligibleTasks(shelves: [], habits: [], eligibleHoursWindows: [])
    }

    private func blockCount() throws -> Int {
        try context.fetch(FetchDescriptor<ScheduledBlock>()).count
    }

    /// The rule the second sabotage proved was unguarded.
    @MainActor
    func test_futureBlockForNowUntimedHabit_isSweptAway() async throws {
        let habit = try makeHabit(mode: .specific)
        makeBlock(for: habit, daysAhead: 3)
        try context.save()
        XCTAssertEqual(try blockCount(), 1)

        // The edit the sweep exists to clean up after.
        habit.occurrenceTimeModesRaw = [HabitOccurrenceTimeMode.pm.rawValue]
        try context.save()

        await sweep()

        XCTAssertEqual(try blockCount(), 0,
                       "an untimed occurrence has no calendar block, so the stale one must go")
    }

    /// The other side, so the sweep can't pass by deleting everything: a
    /// habit still on Specific Time keeps its future block.
    @MainActor
    func test_futureBlockForStillSpecificHabit_isKept() async throws {
        let habit = try makeHabit(mode: .specific)
        makeBlock(for: habit, daysAhead: 3)
        try context.save()

        await sweep()

        XCTAssertEqual(try blockCount(), 1,
                       "still Specific Time — its block is exactly where it belongs")
    }

    /// And history is never touched, matching the sweep's own
    /// `date >= startOfToday, !isCompleted` guard.
    @MainActor
    func test_pastAndCompletedHabitBlocks_survive() async throws {
        let habit = try makeHabit(mode: .specific)
        makeBlock(for: habit, daysAhead: -2)                 // past
        makeBlock(for: habit, daysAhead: 4, complete: true)  // future, already done
        try context.save()

        habit.occurrenceTimeModesRaw = [HabitOccurrenceTimeMode.am.rawValue]
        try context.save()

        await sweep()

        XCTAssertEqual(try blockCount(), 2,
                       "the sweep is for stale future work, not for rewriting history")
    }
}
