import XCTest
import SwiftData
@testable import NoteForLater

/// Coverage for the "tasks completed in last night's Nightly Review show
/// up again in tonight's Today step" bug: `NightlyReviewView
/// .completedTasksWithNoBlock` compared `TaskCompletionRecord.completedAt`
/// (a full timestamp) against `lastClosedReviewDay` (day-granular) with a
/// plain `>=`, so every record from the day just closed re-qualified for
/// the very next review — the identical off-by-one already fixed once in
/// `ScheduleReviewViewModel.openHabitOccurrencesForReview`'s `cursor >
/// completedSinceDay`, missed here and in the Two-Minute-Tasks step's own
/// copy of the same filter. Fixed by centralizing the bound as
/// `NightlyReviewCompletionState.completedSinceBound`, tested directly
/// here without a UserDefaults-backed singleton.
///
/// Also covers `ScheduleReviewViewModel.reviewableBlocks`'s companion fix:
/// its old `startTime < reviewDisplayCutoff || $0.isCompleted` was the
/// same unbounded-OR shape as the still-live `todayMealSelections` bug
/// (`$0.isCompleted || $0.date <= cutoffDay`) — masked only by
/// `purgeCompletedBlocks` deleting every completed block on the
/// `.today`→`.inbox` commit. Bounding a completed block's admission by
/// `completedSinceBound` (instead of leaving it unconditional) closes that
/// leak for whenever the purge is skipped.
final class NightlyReviewCompletionLeakTests: XCTestCase {
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
            for: TaskItem.self, ScheduledBlock.self, Shelf.self, TaskCompletionRecord.self,
                Habit.self, HabitLog.self, MealSelection.self, Recipe.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    private func makeRecord(title: String, completedAt: Date) -> TaskCompletionRecord {
        let record = TaskCompletionRecord(taskID: UUID(), title: title, createdAt: completedAt, completedAt: completedAt, pushedCount: 0)
        context.insert(record)
        return record
    }

    // MARK: - completedTasksWithNoBlock

    /// The exact reported bug: a task completed on the day the review
    /// closed must not reappear in the very next review.
    ///
    /// Verified fail-then-pass: with `NightlyReviewCompletionState
    /// .completedSinceBound` temporarily reverted to `closedDay ??
    /// .distantPast` (the pre-fix plain `>=` comparison), this test
    /// failed — the closed-day record came back in the result. Restored
    /// the real bound and reran: green. Both via `xcodebuild test`.
    func test_completedTasksWithNoBlock_recordFromClosedReviewDay_doesNotReappear() {
        let closedDay = day(2026, 9, 8)
        let completedOnClosedDay = calendar.date(byAdding: .hour, value: 21, to: closedDay)! // 9pm the same day
        _ = makeRecord(title: "Review Monarch Expenses", completedAt: completedOnClosedDay)

        let result = ScheduleReviewViewModel.completedTasksWithNoBlock(tasks: [], context: context, completedSince: closedDay)

        XCTAssertTrue(result.isEmpty, "a record completed on the day just closed must not resurface in the next review")
    }

    /// A task completed *after* the closed review day (i.e. today, since
    /// the last close) must still show — this is the whole point of
    /// `completedTasksWithNoBlock` existing at all.
    func test_completedTasksWithNoBlock_recordFromAfterClosedReviewDay_doesReappear() {
        let closedDay = day(2026, 9, 8)
        let completedTheNextDay = day(2026, 9, 9)
        let record = makeRecord(title: "Take out trash", completedAt: completedTheNextDay)

        let result = ScheduleReviewViewModel.completedTasksWithNoBlock(tasks: [], context: context, completedSince: closedDay)

        XCTAssertEqual(result.map(\.id), [record.id])
    }

    // MARK: - reviewableBlocks

    /// A completed `ScheduledBlock` older than the review window (i.e.
    /// from before the last closed review day) must not appear even if
    /// `purgeCompletedBlocks` never ran to delete it — the defensive
    /// bound `reviewableBlocks` needed instead of the old unconditional
    /// `isCompleted` branch.
    func test_reviewableBlocks_oldCompletedBlock_doesNotAppear_evenWithoutPurge() {
        let closedDay = day(2026, 9, 8)
        let completedSinceBound = NightlyReviewCompletionState.completedSinceBound(closedDay: closedDay, calendar: calendar)
        let ancientDay = day(2026, 8, 1)

        let staleBlock = ScheduledBlock(
            date: ancientDay,
            startTime: calendar.date(byAdding: .hour, value: 9, to: ancientDay)!,
            endTime: calendar.date(byAdding: .hour, value: 10, to: ancientDay)!,
            task: nil
        )
        staleBlock.isCompleted = true
        context.insert(staleBlock)

        let reviewDisplayCutoff = calendar.date(byAdding: .day, value: 1, to: day(2026, 9, 9))!
        let result = ScheduleReviewViewModel.reviewableBlocks(allBlocks: [staleBlock], reviewDisplayCutoff: reviewDisplayCutoff, completedSinceBound: completedSinceBound)

        XCTAssertTrue(result.isEmpty, "a completed block from before the last closed review day must not leak back in, purge or no purge")
    }

    /// Sanity check on the other side of that same bound: an incomplete
    /// block from before the review window must still show — the
    /// intentional "backlog" behavior `reviewableBlocks` was never meant
    /// to lose.
    func test_reviewableBlocks_oldIncompleteBlock_stillAppears() {
        let closedDay = day(2026, 9, 8)
        let completedSinceBound = NightlyReviewCompletionState.completedSinceBound(closedDay: closedDay, calendar: calendar)
        let ancientDay = day(2026, 8, 1)

        let backlogBlock = ScheduledBlock(
            date: ancientDay,
            startTime: calendar.date(byAdding: .hour, value: 9, to: ancientDay)!,
            endTime: calendar.date(byAdding: .hour, value: 10, to: ancientDay)!,
            task: nil
        )
        context.insert(backlogBlock)

        let reviewDisplayCutoff = calendar.date(byAdding: .day, value: 1, to: day(2026, 9, 9))!
        let result = ScheduleReviewViewModel.reviewableBlocks(allBlocks: [backlogBlock], reviewDisplayCutoff: reviewDisplayCutoff, completedSinceBound: completedSinceBound)

        XCTAssertEqual(result.map(\.id), [backlogBlock.id], "an old but still-incomplete block must keep surfacing as backlog")
    }

    // MARK: - Class-level regression: every reviewItems-feeding path

    /// One row per path that feeds `NightlyReviewView.reviewItems` today
    /// — habit occurrences, blocks, completed-with-no-block tasks, and
    /// meal selections. Table-driven on purpose: this bug has now been
    /// found four times, separately, weeks apart, by noticing a UI
    /// symptom — each fix arrived only after a screenshot. A fifth path
    /// added later with the same day-granularity mistake should fail a
    /// test the day it's written, not get discovered the same way. Each
    /// row builds its own isolated in-memory store so the four checks
    /// can't cross-contaminate.
    private struct ReviewPathCheck {
        let name: String
        /// Builds one item completed exactly on `closedDay`, runs the
        /// real production path, and reports whether it's included.
        let sameDayCompletionLeaks: (_ closedDay: Date, _ calendar: Calendar) throws -> Bool
        /// Same shape, for an item completed the day *after* `closedDay`
        /// — must still show, or the fix went too far the other way.
        let afterDayCompletionShows: (_ closedDay: Date, _ calendar: Calendar) throws -> Bool
    }

    private static let allReviewPathChecks: [ReviewPathCheck] = [
        ReviewPathCheck(
            name: "habit occurrences (openHabitOccurrencesForReview)",
            sameDayCompletionLeaks: { closedDay, calendar in
                let context = try NightlyReviewCompletionLeakTests.makeContext(for: Habit.self, HabitLog.self)
                let habit = Habit(name: "Floss", startDate: calendar.date(byAdding: .day, value: -30, to: closedDay)!, daysOfWeek: [1, 2, 3, 4, 5, 6, 7], idealTimesOfDay: [420])
                habit.occurrenceTimeModesRaw = [HabitOccurrenceTimeMode.am.rawValue]
                context.insert(habit)
                habit.logOrCreate(on: closedDay, context: context, calendar: calendar).setOccurrence(0, to: .complete)
                let cutoff = calendar.date(byAdding: .day, value: 2, to: closedDay)!
                let result = ScheduleReviewViewModel.openHabitOccurrencesForReview(habits: [habit], context: context, upTo: cutoff, completedSince: closedDay)
                return result.contains { calendar.isDate($0.targetTime, inSameDayAs: closedDay) }
            },
            afterDayCompletionShows: { closedDay, calendar in
                let context = try NightlyReviewCompletionLeakTests.makeContext(for: Habit.self, HabitLog.self)
                let dayAfter = calendar.date(byAdding: .day, value: 1, to: closedDay)!
                let habit = Habit(name: "Floss", startDate: calendar.date(byAdding: .day, value: -30, to: closedDay)!, daysOfWeek: [1, 2, 3, 4, 5, 6, 7], idealTimesOfDay: [420])
                habit.occurrenceTimeModesRaw = [HabitOccurrenceTimeMode.am.rawValue]
                context.insert(habit)
                habit.logOrCreate(on: dayAfter, context: context, calendar: calendar).setOccurrence(0, to: .complete)
                let cutoff = calendar.date(byAdding: .day, value: 2, to: dayAfter)!
                let result = ScheduleReviewViewModel.openHabitOccurrencesForReview(habits: [habit], context: context, upTo: cutoff, completedSince: closedDay)
                return result.contains { calendar.isDate($0.targetTime, inSameDayAs: dayAfter) }
            }
        ),
        ReviewPathCheck(
            name: "completed-with-no-block tasks (completedTasksWithNoBlock)",
            sameDayCompletionLeaks: { closedDay, calendar in
                let context = try NightlyReviewCompletionLeakTests.makeContext(for: TaskCompletionRecord.self)
                let completedAt = calendar.date(byAdding: .hour, value: 20, to: closedDay)!
                let record = TaskCompletionRecord(taskID: UUID(), title: "Test", createdAt: completedAt, completedAt: completedAt, pushedCount: 0)
                context.insert(record)
                let result = ScheduleReviewViewModel.completedTasksWithNoBlock(tasks: [], context: context, completedSince: closedDay)
                return result.contains { $0.id == record.id }
            },
            afterDayCompletionShows: { closedDay, calendar in
                let context = try NightlyReviewCompletionLeakTests.makeContext(for: TaskCompletionRecord.self)
                let dayAfter = calendar.date(byAdding: .day, value: 1, to: closedDay)!
                let record = TaskCompletionRecord(taskID: UUID(), title: "Test", createdAt: dayAfter, completedAt: dayAfter, pushedCount: 0)
                context.insert(record)
                let result = ScheduleReviewViewModel.completedTasksWithNoBlock(tasks: [], context: context, completedSince: closedDay)
                return result.contains { $0.id == record.id }
            }
        ),
        ReviewPathCheck(
            name: "scheduled blocks (reviewableBlocks)",
            sameDayCompletionLeaks: { closedDay, calendar in
                let context = try NightlyReviewCompletionLeakTests.makeContext(for: ScheduledBlock.self)
                let block = ScheduledBlock(date: closedDay, startTime: calendar.date(byAdding: .hour, value: 9, to: closedDay)!, endTime: calendar.date(byAdding: .hour, value: 10, to: closedDay)!, task: nil)
                block.isCompleted = true
                context.insert(block)
                let completedSinceBound = NightlyReviewCompletionState.completedSinceBound(closedDay: closedDay, calendar: calendar)
                let reviewDisplayCutoff = calendar.date(byAdding: .day, value: -1, to: closedDay)! // in the past, so only the isCompleted branch could admit it
                let result = ScheduleReviewViewModel.reviewableBlocks(allBlocks: [block], reviewDisplayCutoff: reviewDisplayCutoff, completedSinceBound: completedSinceBound)
                return result.contains { $0.id == block.id }
            },
            afterDayCompletionShows: { closedDay, calendar in
                let context = try NightlyReviewCompletionLeakTests.makeContext(for: ScheduledBlock.self)
                let dayAfter = calendar.date(byAdding: .day, value: 1, to: closedDay)!
                let block = ScheduledBlock(date: dayAfter, startTime: calendar.date(byAdding: .hour, value: 9, to: dayAfter)!, endTime: calendar.date(byAdding: .hour, value: 10, to: dayAfter)!, task: nil)
                block.isCompleted = true
                context.insert(block)
                let completedSinceBound = NightlyReviewCompletionState.completedSinceBound(closedDay: closedDay, calendar: calendar)
                let reviewDisplayCutoff = calendar.date(byAdding: .day, value: -1, to: closedDay)!
                let result = ScheduleReviewViewModel.reviewableBlocks(allBlocks: [block], reviewDisplayCutoff: reviewDisplayCutoff, completedSinceBound: completedSinceBound)
                return result.contains { $0.id == block.id }
            }
        ),
        ReviewPathCheck(
            name: "meal selections (todayMealSelections)",
            sameDayCompletionLeaks: { closedDay, calendar in
                let context = try NightlyReviewCompletionLeakTests.makeContext(for: MealSelection.self)
                let selection = MealSelection(recipeID: UUID(), recipeTitle: "Test", date: closedDay)
                selection.isCompleted = true
                context.insert(selection)
                let completedSinceBound = NightlyReviewCompletionState.completedSinceBound(closedDay: closedDay, calendar: calendar)
                let cutoffDay = calendar.date(byAdding: .day, value: -1, to: closedDay)! // in the past, so only the isCompleted branch could admit it
                let result = ScheduleReviewViewModel.todayMealSelections(allMealSelections: [selection], cutoffDay: cutoffDay, completedSinceBound: completedSinceBound)
                return result.contains { $0.id == selection.id }
            },
            afterDayCompletionShows: { closedDay, calendar in
                let context = try NightlyReviewCompletionLeakTests.makeContext(for: MealSelection.self)
                let dayAfter = calendar.date(byAdding: .day, value: 1, to: closedDay)!
                let selection = MealSelection(recipeID: UUID(), recipeTitle: "Test", date: dayAfter)
                selection.isCompleted = true
                context.insert(selection)
                let completedSinceBound = NightlyReviewCompletionState.completedSinceBound(closedDay: closedDay, calendar: calendar)
                let cutoffDay = calendar.date(byAdding: .day, value: -1, to: closedDay)!
                let result = ScheduleReviewViewModel.todayMealSelections(allMealSelections: [selection], cutoffDay: cutoffDay, completedSinceBound: completedSinceBound)
                return result.contains { $0.id == selection.id }
            }
        ),
    ]

    private static func makeContext(for types: any PersistentModel.Type...) throws -> ModelContext {
        let container = try ModelContainer(for: Schema(types), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    /// The class-level assertion: nothing completed on (or before) the
    /// closed review day appears in the very next review, across every
    /// path that feeds `reviewItems`. Add a row to `allReviewPathChecks`
    /// for any new path — this loop covers it automatically from then on.
    func test_noReviewPath_surfacesCompletionFromTheClosedReviewDay() throws {
        let closedDay = day(2026, 9, 8)
        for check in Self.allReviewPathChecks {
            let leaked = try check.sameDayCompletionLeaks(closedDay, calendar)
            XCTAssertFalse(leaked, "\(check.name) surfaced an item completed on the closed review day itself")
        }
    }

    /// The other half of the same table: fixing the leak must not also
    /// hide a completion made *after* the closed day — every path must
    /// still show that.
    func test_everyReviewPath_stillSurfacesCompletionFromAfterTheClosedReviewDay() throws {
        let closedDay = day(2026, 9, 8)
        for check in Self.allReviewPathChecks {
            let shows = try check.afterDayCompletionShows(closedDay, calendar)
            XCTAssertTrue(shows, "\(check.name) failed to surface an item completed after the closed review day")
        }
    }
}
