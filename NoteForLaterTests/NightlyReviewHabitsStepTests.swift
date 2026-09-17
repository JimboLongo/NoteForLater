import XCTest
import SwiftData
@testable import NoteForLater

/// Coverage for moving habits out of the old combined "Review Schedule"
/// (`.today`) step into their own, earlier `.habits` step — placed right
/// after `.chooseDay` (see `NightlyReviewView.Step`'s own doc comment for
/// why there and not literally first: the habit list depends on
/// `reviewDate`, which Choose Day sets).
///
/// `NightlyReviewView` itself isn't unit-testable here (its `@Query`
/// properties need a live SwiftUI environment) — same limitation
/// `NightlyReviewAutoSkipTests`/`NightlyReviewNextGateTests` already work
/// around by exercising the real `NightlyReviewView.Step` type (loosened
/// to `internal` for exactly this) directly, and the extracted
/// `ScheduleReviewViewModel` functions the view's own gate/freeze
/// properties are thin wrappers around. This file does the same.
final class NightlyReviewHabitsStepTests: XCTestCase {
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

    private func habitOccurrence(habit: Habit, on day: Date, status: OccurrenceStatus) -> HabitReviewOccurrence {
        HabitReviewOccurrence(id: "\(habit.id)-0-\(Int(day.timeIntervalSince1970))", habit: habit, index: 0, status: status, targetTime: day, modeLabel: "AM")
    }

    private func makeRecurringTask(name: String, anchor: Date) -> TaskItem {
        let task = TaskItem(title: name, dueDate: anchor, estimatedMinutes: 15)
        task.isRecurring = true
        task.recurrenceUnit = .days
        task.recurrenceIntervalCount = 1
        task.recurrenceTimeMode = .am
        context.insert(task)
        return task
    }

    private func recurringTaskOccurrence(task: TaskItem, on day: Date, status: OccurrenceStatus) -> ScheduleReviewViewModel.RecurringTaskReviewOccurrence {
        ScheduleReviewViewModel.RecurringTaskReviewOccurrence(id: "\(task.id)-\(Int(day.timeIntervalSince1970))", task: task, status: status, targetTime: day, modeLabel: "AM")
    }

    // MARK: - Fail-then-pass target: step ordering

    /// Fail-then-pass target. Verified against the real `NightlyReviewView
    /// .Step` enum, not a stand-in — this is an `Int`-rawValue enum with no
    /// explicit values, so declaration order is the only thing that
    /// determines this.
    func test_habitsStep_immediatelyFollowsChooseDay() {
        let chooseDayRawValue = NightlyReviewView.Step.chooseDay.rawValue

        let next = NightlyReviewView.Step(rawValue: chooseDayRawValue + 1)

        XCTAssertEqual(next, .habits)
    }

    /// `.twoMinuteTasks` must come right after `.habits` — pins the full
    /// intended order (chooseDay -> habits -> twoMinuteTasks -> ...), not
    /// just the first hop.
    /// Was `test_twoMinuteTasksStep_immediatelyFollowsHabits`. **Updated
    /// for the reorder, not deleted:** Inbox now sits between them, so that
    /// shelf changes made while sorting the Inbox are in place before
    /// anything schedules against them.
    ///
    /// Still pins that Habits comes straight after Choose Day — the one
    /// ordering constraint that is structural rather than preference, since
    /// the habit list depends on `reviewDate`, which Choose Day sets.
    func test_inboxImmediatelyFollowsHabits_andHabitsFollowsChooseDay() {
        XCTAssertEqual(NightlyReviewView.Step(rawValue: NightlyReviewView.Step.chooseDay.rawValue + 1), .habits)
        XCTAssertEqual(NightlyReviewView.Step(rawValue: NightlyReviewView.Step.habits.rawValue + 1), .inbox)
    }

    /// The full order, pinned as an exact array. Order is user-visible, and
    /// `advance()`/`back()` derive from declaration order — so a reorder
    /// should be an explicit diff here rather than a silent behaviour shift.
    func test_stepOrder() {
        XCTAssertEqual(
            NightlyReviewView.Step.allCases,
            [.chooseDay, .habits, .inbox, .twoMinuteTasks, .today, .atRisk, .meals, .tomorrow]
        )
    }

    // MARK: - Fail-then-pass target: `.habits` is auto-skip eligible, unlike `.today`

    /// Fail-then-pass target. `.habits` must be free to auto-skip when
    /// empty (unlike `.today`, which always shows even when sparse).
    func test_habitsStep_isAutoSkipEligible() {
        XCTAssertTrue(NightlyReviewView.Step.autoSkipEligible.contains(.habits))
    }

    func test_todayStep_isStillNotAutoSkipEligible() {
        XCTAssertFalse(NightlyReviewView.Step.autoSkipEligible.contains(.today))
    }

    /// Real `StepAutoSkip.walkForward`, real `Step`, only `isEmpty` faked
    /// (unconditionally `true`) — mirrors `NightlyReviewAutoSkipTests
    /// .test_realStep_todayNeverAutoSkippedEvenWhenReportedEmpty`'s shape.
    /// Starting at `.habits`, a walk that finds it eligible-and-empty must
    /// skip it and continue to `.twoMinuteTasks` (also eligible; still
    /// reported empty by the same adversarial `isEmpty`), landing on
    /// `.today`, which is not auto-skip eligible regardless of what
    /// `isEmpty` claims.
    func test_realStep_habitsSkipsWhenEmpty_continuingPastTwoMinuteTasksToToday() {
        let result = StepAutoSkip.walkForward(
            from: NightlyReviewView.Step.habits,
            next: { NightlyReviewView.Step(rawValue: $0.rawValue + 1) ?? .tomorrow },
            isEligible: { NightlyReviewView.Step.autoSkipEligible.contains($0) },
            isEmpty: { _ in true },
            onEnter: { _ in },
            maxSteps: NightlyReviewView.Step.allCases.count
        )

        XCTAssertEqual(result.landed, .today)
        XCTAssertEqual(result.skipped, [.habits, .inbox, .twoMinuteTasks],
                       "Inbox now sits between Habits and the 2-Minute step")
    }

    // MARK: - The Habits step's own gate

    /// Same underlying `ScheduleReviewViewModel.unresolvedHabitOccurrences`
    /// `NightlyReviewNextGateTests` already exercises for the old combined
    /// gate — confirmed here again explicitly as the Habits step's own,
    /// now-sole gate, so this file stands alone as coverage for "the new
    /// step's Next button is blocked by an unresolved habit and clears
    /// once marked" without depending on that other file's continued
    /// existence.
    func test_habitsGate_blocksOnUnresolvedHabit_clearsOnceMarked() {
        let reviewDay = day(2026, 9, 9)
        let habit = makeHabit(name: "Stretch", mode: .am, startDate: reviewDay)

        let unresolved = ScheduleReviewViewModel.unresolvedHabitOccurrences([habitOccurrence(habit: habit, on: reviewDay, status: .none)])
        XCTAssertFalse(unresolved.isEmpty, "an unmarked habit must block the Habits step's Next button")

        let resolved = ScheduleReviewViewModel.unresolvedHabitOccurrences([habitOccurrence(habit: habit, on: reviewDay, status: .complete)])
        XCTAssertTrue(resolved.isEmpty, "marking it must clear the gate")
    }

    // MARK: - `.today`'s gate: recurring tasks only, independent of habit status

    /// Confirms the split itself: `.today`'s own gate predicate
    /// (`unresolvedRecurringTaskOccurrences`) must still block on an
    /// unresolved recurring task regardless of what any habit occurrence's
    /// status is — the two lists are entirely separate inputs now, with no
    /// shared list for a mistake to accidentally recombine them into.
    func test_todayGate_blocksOnUnresolvedRecurringTask_regardlessOfHabitStatus() {
        let reviewDay = day(2026, 9, 9)
        let task = makeRecurringTask(name: "Take out trash", anchor: reviewDay)
        let habit = makeHabit(name: "Stretch", mode: .am, startDate: reviewDay)

        // The habit is fully resolved — if a bug ever re-merged the two
        // gates, this could wrongly look like "everything's resolved."
        _ = habitOccurrence(habit: habit, on: reviewDay, status: .complete)

        let unresolvedTasks = ScheduleReviewViewModel.unresolvedRecurringTaskOccurrences([
            recurringTaskOccurrence(task: task, on: reviewDay, status: .none)
        ])

        XCTAssertFalse(unresolvedTasks.isEmpty, "an unresolved recurring task must still block .today's Next button on its own, independent of any habit")
    }

    /// The flip side — a fully resolved recurring task must clear
    /// `.today`'s gate on its own, with no habit occurrence involved in
    /// the check at all (none is passed in).
    func test_todayGate_clearsOnceRecurringTaskResolved_withNoHabitsInThePicture() {
        let reviewDay = day(2026, 9, 9)
        let task = makeRecurringTask(name: "Take out trash", anchor: reviewDay)

        let unresolvedTasks = ScheduleReviewViewModel.unresolvedRecurringTaskOccurrences([
            recurringTaskOccurrence(task: task, on: reviewDay, status: .missed)
        ])

        XCTAssertTrue(unresolvedTasks.isEmpty, "a resolved (non-.none) recurring task must satisfy .today's gate")
    }
}
