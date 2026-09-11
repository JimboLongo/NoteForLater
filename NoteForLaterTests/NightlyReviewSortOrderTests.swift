import XCTest
import SwiftData
@testable import NoteForLater

/// Coverage for `OverdueBlocksReviewList.groupedByDay`'s sort: a prior
/// version pushed resolved habits (complete/missed/excused) to the end of
/// their day so an unresolved item wasn't buried under one already handled
/// — but that made a row jump position the instant you tapped it, which
/// reads as worse than a completed habit just sitting inline. This pins the
/// reverted behavior: everything within a day sorts by `sortTime` alone,
/// regardless of status, so a habit's position never moves when its status
/// does. `sortTime` for a habit occurrence is a stand-in built from its
/// `HabitOccurrenceTimeMode` (see `ScheduleReviewViewModel.targetMinutes`),
/// so AM/Midday/PM order is explicit, not incidental — and `habitSortOrder`
/// is an explicit tiebreak (the same `Habit.sortOrder` field
/// `openHabitOccurrences` sorts by) for two habits sharing a time mode,
/// rather than relying on the caller happening to pass habits in
/// `sortOrder` already.
final class NightlyReviewSortOrderTests: XCTestCase {
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

    private func makeHabit(name: String, mode: HabitOccurrenceTimeMode, startDate: Date, sortOrder: Int = 0) -> Habit {
        let habit = Habit(name: name, startDate: startDate, daysOfWeek: [1, 2, 3, 4, 5, 6, 7], idealTimesOfDay: [540])
        habit.occurrenceTimeModesRaw = [mode.rawValue]
        habit.sortOrder = sortOrder
        context.insert(habit)
        return habit
    }

    private func occurrence(habit: Habit, mode: HabitOccurrenceTimeMode, on day: Date, status: OccurrenceStatus) -> HabitReviewOccurrence {
        let minutes: Int = mode == .am ? 6 * 60 : (mode == .midday ? 12 * 60 : 21 * 60)
        let targetTime = calendar.date(byAdding: .minute, value: minutes, to: day)!
        return HabitReviewOccurrence(id: "\(habit.id)-0-\(Int(targetTime.timeIntervalSince1970))", habit: habit, index: 0, status: status, targetTime: targetTime, modeLabel: mode.label)
    }

    /// Fail-then-pass target: with the old two-tier (`isResolvedHabit`)
    /// sort still in place, cycling a habit to `.complete` moved it to the
    /// end of its day, past a still-open habit due later that same day.
    /// Reverting to a pure `sortTime` sort means status changes alone must
    /// never reorder the list.
    func test_togglingAHabitsStatus_doesNotChangeItsPosition() {
        let reviewDay = day(2026, 9, 9)
        let morningHabit = makeHabit(name: "Stretch", mode: .am, startDate: reviewDay)
        let eveningHabit = makeHabit(name: "Journal", mode: .pm, startDate: reviewDay)

        func order(morningStatus: OccurrenceStatus) -> [String] {
            let items: [ReviewItem] = [
                .habit(occurrence(habit: morningHabit, mode: .am, on: reviewDay, status: morningStatus)),
                .habit(occurrence(habit: eveningHabit, mode: .pm, on: reviewDay, status: .none)),
            ]
            let list = OverdueBlocksReviewList(items: items, onToggle: { _ in })
            return list.groupedByDay.flatMap { $0.items }.map(\.id)
        }

        let beforeToggle = order(morningStatus: .none)
        let afterToggle = order(morningStatus: .complete)

        XCTAssertEqual(beforeToggle, afterToggle, "cycling the AM habit's status must not change row order")
        XCTAssertEqual(beforeToggle.first, "habit-\(morningHabit.id)-0-\(Int(calendar.date(byAdding: .minute, value: 6 * 60, to: reviewDay)!.timeIntervalSince1970))", "AM habit should still lead")
    }

    func test_amMiddayPm_sortInThatOrder() {
        let reviewDay = day(2026, 9, 9)
        let am = makeHabit(name: "Stretch", mode: .am, startDate: reviewDay)
        let midday = makeHabit(name: "Walk", mode: .midday, startDate: reviewDay)
        let pm = makeHabit(name: "Journal", mode: .pm, startDate: reviewDay)

        let items: [ReviewItem] = [
            .habit(occurrence(habit: pm, mode: .pm, on: reviewDay, status: .none)),
            .habit(occurrence(habit: midday, mode: .midday, on: reviewDay, status: .complete)),
            .habit(occurrence(habit: am, mode: .am, on: reviewDay, status: .missed)),
        ]
        let list = OverdueBlocksReviewList(items: items, onToggle: { _ in })
        let orderedNames: [String] = list.groupedByDay.flatMap { $0.items }.compactMap {
            if case .habit(let occurrence) = $0 { return occurrence.habit.name }
            return nil
        }

        XCTAssertEqual(orderedNames, ["Stretch", "Walk", "Journal"], "AM before Midday before PM, regardless of status")
    }

    /// Two habits sharing the same time mode keep a stable order — by
    /// `sortOrder`, same as `openHabitOccurrences` — whether or not either
    /// one has been resolved.
    func test_sameTimeMode_ordersBySortOrder_regardlessOfStatus() {
        let reviewDay = day(2026, 9, 9)
        let first = makeHabit(name: "Vitamins", mode: .am, startDate: reviewDay, sortOrder: 0)
        let second = makeHabit(name: "Meditate", mode: .am, startDate: reviewDay, sortOrder: 1)

        let items: [ReviewItem] = [
            .habit(occurrence(habit: second, mode: .am, on: reviewDay, status: .none)),
            .habit(occurrence(habit: first, mode: .am, on: reviewDay, status: .complete)),
        ]
        let list = OverdueBlocksReviewList(items: items, onToggle: { _ in })
        let orderedNames: [String] = list.groupedByDay.flatMap { $0.items }.compactMap {
            if case .habit(let occurrence) = $0 { return occurrence.habit.name }
            return nil
        }

        XCTAssertEqual(orderedNames, ["Vitamins", "Meditate"], "lower sortOrder leads even though it's the completed one")
    }
}
