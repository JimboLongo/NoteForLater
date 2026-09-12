import XCTest
import SwiftData
@testable import NoteForLater

/// Coverage for the Today step's "Next" gate: `ScheduleReviewViewModel
/// .unresolvedHabitOccurrences`/`.habitGateMessage`, the extracted core
/// logic behind `NightlyReviewView.unresolvedHabitOccurrences` (private,
/// and behind `@Query` properties impractical to construct here — see that
/// property's own doc comment).
///
/// Deliberately scoped to habit occurrences only — task blocks and meals
/// were ruled out after an explicit audit: both expose only a plain
/// `isCompleted` boolean with no "explicitly decided not done" state, and
/// leaving one incomplete is the normal input the push-forward pipeline
/// already handles (a recurring habit/task block gets pushed forward, a
/// non-recurring one gets re-guaranteed placement, an incomplete meal just
/// sits in next time's backlog). Gating on those would make an ordinary
/// night with leftover work permanently block the review, with no way to
/// clear it short of falsely marking it complete. `NightlyReviewView
/// .finishAndDismiss` (what "Close" calls) never reads this gate at all —
/// confirmed by reading it, not tested here, since it takes no habit/step
/// state as input in the first place.
final class NightlyReviewNextGateTests: XCTestCase {
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

    private func makeHabit(name: String, mode: HabitOccurrenceTimeMode, startDate: Date) -> Habit {
        let habit = Habit(name: name, startDate: startDate, daysOfWeek: [1, 2, 3, 4, 5, 6, 7], idealTimesOfDay: [540])
        habit.occurrenceTimeModesRaw = [mode.rawValue]
        context.insert(habit)
        return habit
    }

    private func occurrence(habit: Habit, on day: Date, status: OccurrenceStatus) -> HabitReviewOccurrence {
        HabitReviewOccurrence(id: "\(habit.id)-0-\(Int(day.timeIntervalSince1970))", habit: habit, index: 0, status: status, targetTime: day, modeLabel: "AM")
    }

    /// Fail-then-pass target: Next must be disabled (gate reports a
    /// blocking occurrence) with one habit left `.none`, and enabled the
    /// moment it's marked to any resolved state.
    func test_oneUnresolvedHabit_blocksGate_thenClearsOnceMarked() {
        let reviewDay = day(2026, 9, 9)
        let habit = makeHabit(name: "Stretch", mode: .am, startDate: reviewDay)

        let beforeMarking = ScheduleReviewViewModel.unresolvedHabitOccurrences([occurrence(habit: habit, on: reviewDay, status: .none)])
        XCTAssertFalse(beforeMarking.isEmpty, "an unmarked habit occurrence must block Next")

        let afterMarking = ScheduleReviewViewModel.unresolvedHabitOccurrences([occurrence(habit: habit, on: reviewDay, status: .complete)])
        XCTAssertTrue(afterMarking.isEmpty, "marking the habit complete must clear the gate")
    }

    func test_eachResolvedState_satisfiesTheGate() {
        let reviewDay = day(2026, 9, 9)
        let habit = makeHabit(name: "Stretch", mode: .am, startDate: reviewDay)

        for status: OccurrenceStatus in [.complete, .missed, .excused] {
            let result = ScheduleReviewViewModel.unresolvedHabitOccurrences([occurrence(habit: habit, on: reviewDay, status: status)])
            XCTAssertTrue(result.isEmpty, "\(status) must satisfy the gate")
        }
    }

    func test_fullyResolvedList_enablesNext() {
        let reviewDay = day(2026, 9, 9)
        let a = makeHabit(name: "Stretch", mode: .am, startDate: reviewDay)
        let b = makeHabit(name: "Journal", mode: .pm, startDate: reviewDay)
        let c = makeHabit(name: "Walk", mode: .midday, startDate: reviewDay)

        let occurrences = [
            occurrence(habit: a, on: reviewDay, status: .complete),
            occurrence(habit: b, on: reviewDay, status: .missed),
            occurrence(habit: c, on: reviewDay, status: .excused),
        ]

        XCTAssertTrue(ScheduleReviewViewModel.unresolvedHabitOccurrences(occurrences).isEmpty)
    }

    func test_oneStillNone_amongOthersResolved_keepsGateBlocking() {
        let reviewDay = day(2026, 9, 9)
        let a = makeHabit(name: "Stretch", mode: .am, startDate: reviewDay)
        let b = makeHabit(name: "Journal", mode: .pm, startDate: reviewDay)

        let occurrences = [
            occurrence(habit: a, on: reviewDay, status: .complete),
            occurrence(habit: b, on: reviewDay, status: .none),
        ]

        let result = ScheduleReviewViewModel.unresolvedHabitOccurrences(occurrences)
        XCTAssertEqual(result.map(\.habit.id), [b.id], "only the still-.none habit should block")
    }

    /// The gate's reason line names habits specifically, not "items" —
    /// so it can't be misread as counting an unfinished task block, which
    /// this gate never touches.
    func test_gateMessage_namesHabitsSpecifically_andPluralizes() {
        XCTAssertEqual(ScheduleReviewViewModel.habitGateMessage(unresolvedCount: 1), "1 habit still unmarked")
        XCTAssertEqual(ScheduleReviewViewModel.habitGateMessage(unresolvedCount: 3), "3 habits still unmarked")
        XCTAssertFalse(ScheduleReviewViewModel.habitGateMessage(unresolvedCount: 3).contains("item"), "must say habits, not items — blocks/meals aren't part of this gate")
    }
}
