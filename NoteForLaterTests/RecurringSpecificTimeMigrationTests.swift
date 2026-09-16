import XCTest
import SwiftData
@testable import NoteForLater

/// Coverage for `NoteForLaterApp.migrateRecurringSpecificTimeTasksIfNeeded`,
/// the one-time pass that moves any recurring task still on Specific Time
/// onto Midday and clears the calendar blocks that mode had created for it.
///
/// **This migration is empty against the author's live store** — checked at
/// the time the change was written: five recurring tasks, all already
/// Midday, and not one `ScheduledBlock` has ever belonged to a recurring
/// task. It is written and tested anyway, because "empty today" is a fact
/// about one device at one moment, not a property of the code: a task
/// created between now and the build landing would hit it.
final class RecurringSpecificTimeMigrationTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    private let flagKey = "didMigrateRecurringSpecificTimeTasks.v1"

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self,
                SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self,
                Habit.self, HabitLog.self, MealSelection.self, Recipe.self,
                PushRecursionWarning.self, TaskCompletionRecord.self, RecurringTaskLog.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        UserDefaults.standard.removeObject(forKey: flagKey)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: flagKey)
    }

    // MARK: - Fixtures

    /// A recurring task in the pre-migration shape. Written to
    /// `recurrenceTimeModeRaw` rather than through `recurrenceTimeMode`,
    /// because the setter now coerces `.specific` away — which is exactly
    /// why this state can only arrive from an older build's stored data.
    private func makeLegacySpecificTask(title: String = "Pay rent") -> TaskItem {
        let task = TaskItem(title: title, estimatedMinutes: 30)
        task.isRecurring = true
        task.recurrenceTimeModeRaw = HabitOccurrenceTimeMode.specific.rawValue
        context.insert(task)
        return task
    }

    private func makeBlock(for task: TaskItem, daysFromToday: Int, complete: Bool) -> ScheduledBlock {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: daysFromToday, to: calendar.startOfDay(for: .now))!
        let start = calendar.date(byAdding: .hour, value: 9, to: day)!
        let block = ScheduledBlock(date: day, startTime: start, endTime: start.addingTimeInterval(1800), task: task)
        block.status = complete ? .complete : .none
        context.insert(block)
        return block
    }

    private func fetchTask(_ id: UUID) throws -> TaskItem {
        try XCTUnwrap(context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first)
    }

    private func blockCount() throws -> Int {
        try context.fetch(FetchDescriptor<ScheduledBlock>()).count
    }

    // MARK: - The mode itself

    func test_recurringSpecificTimeTask_becomesMidday() throws {
        let task = makeLegacySpecificTask()
        let id = task.id
        try context.save()

        NoteForLaterApp.migrateRecurringSpecificTimeTasksIfNeeded(container: container)

        // The migration runs against its own `ModelContext(container)`, so
        // this test's reference won't reflect its writes without a re-fetch
        // — same as any other reader on a later launch.
        let migrated = try fetchTask(id)
        XCTAssertEqual(migrated.recurrenceTimeMode, .midday)
        XCTAssertTrue(migrated.hasMigratedOffSpecificTime)
    }

    /// The point of the whole stage, asserted end-to-end: once migrated,
    /// the card stops asking for a duration it has no block to spend.
    func test_afterMigration_durationAndDivisibleAreHidden() throws {
        let task = makeLegacySpecificTask()
        task.estimatedMinutes = 120
        let id = task.id
        let shelf = Shelf(name: "Recurring Tasks")
        context.insert(shelf)
        try context.save()

        XCTAssertEqual(CardRow.duration.visibility(task: task, shelf: shelf), .shown, "sanity: the legacy shape does show Duration")

        NoteForLaterApp.migrateRecurringSpecificTimeTasksIfNeeded(container: container)

        let migrated = try fetchTask(id)
        XCTAssertEqual(CardRow.duration.visibility(task: migrated, shelf: shelf), .hidden)
        XCTAssertEqual(CardRow.divisible.visibility(task: migrated, shelf: shelf), .hidden)
    }

    /// Per the decision on this stage: the stored value is **kept**.
    ///
    /// This looks inconsistent with stage 3's reset-on-toggle-off, and
    /// isn't. There, the user flipped a toggle and chose to change what the
    /// task is, so clearing what that hid is honouring the choice. Here the
    /// app withdrew a capability the user never asked to lose — destroying
    /// their data on the way would be the app helping itself, not them.
    func test_migration_keepsEstimatedMinutes() throws {
        let task = makeLegacySpecificTask()
        task.estimatedMinutes = 45
        task.durationPicked = true
        let id = task.id
        try context.save()

        NoteForLaterApp.migrateRecurringSpecificTimeTasksIfNeeded(container: container)

        let migrated = try fetchTask(id)
        XCTAssertEqual(migrated.estimatedMinutes, 45, "hiding a row is not a reason to destroy the value behind it")
        XCTAssertTrue(migrated.durationPicked)
    }

    // MARK: - Blocks: future incomplete go, history stays

    func test_migration_removesFutureIncompleteBlocks() throws {
        let task = makeLegacySpecificTask()
        _ = makeBlock(for: task, daysFromToday: 3, complete: false)
        try context.save()
        XCTAssertEqual(try blockCount(), 1)

        NoteForLaterApp.migrateRecurringSpecificTimeTasksIfNeeded(container: container)

        XCTAssertEqual(try blockCount(), 0, "an untimed occurrence has no block, so the stale one must go")
    }

    /// The asymmetry that matters. A completed block is the record that the
    /// occurrence happened, and
    /// `ScheduleReviewViewModel.isRecurringTaskOccurrenceComplete` still
    /// reads exactly these. Deleting them would silently un-complete work
    /// the user actually did.
    func test_migration_keepsPastAndCompletedBlocks() throws {
        let task = makeLegacySpecificTask()
        _ = makeBlock(for: task, daysFromToday: -3, complete: false)  // past, incomplete
        _ = makeBlock(for: task, daysFromToday: -1, complete: true)   // past, complete
        _ = makeBlock(for: task, daysFromToday: 2, complete: true)    // future, already complete
        _ = makeBlock(for: task, daysFromToday: 4, complete: false)   // the only one to remove
        try context.save()
        XCTAssertEqual(try blockCount(), 4)

        NoteForLaterApp.migrateRecurringSpecificTimeTasksIfNeeded(container: container)

        XCTAssertEqual(try blockCount(), 3, "only the future incomplete block is removed")
    }

    // MARK: - Scope: what it must not touch

    /// Habits keep all four modes and most of them are on Specific Time.
    /// The migration fetches `TaskItem` and guards on `isRecurring`, so a
    /// habit is never even considered — asserted rather than assumed,
    /// because this is the one way the change could damage something the
    /// user never asked to change.
    func test_migration_leavesHabitsAlone() throws {
        let habit = Habit(name: "Stretch")
        context.insert(habit)
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: 3, to: calendar.startOfDay(for: .now))!
        let start = calendar.date(byAdding: .hour, value: 7, to: day)!
        let block = ScheduledBlock(date: day, startTime: start, endTime: start.addingTimeInterval(900), task: nil, habit: habit)
        context.insert(block)
        try context.save()

        NoteForLaterApp.migrateRecurringSpecificTimeTasksIfNeeded(container: container)

        XCTAssertEqual(try blockCount(), 1, "a habit's future block is not this migration's business")
    }

    /// A non-recurring task's time mode is meaningless — nothing reads it —
    /// so the migration must not rewrite it, and must not touch its blocks.
    func test_migration_leavesNonRecurringTasksAlone() throws {
        let task = TaskItem(title: "One-off", estimatedMinutes: 30)
        task.recurrenceTimeModeRaw = HabitOccurrenceTimeMode.specific.rawValue
        context.insert(task)
        let id = task.id
        _ = makeBlock(for: task, daysFromToday: 3, complete: false)
        try context.save()

        NoteForLaterApp.migrateRecurringSpecificTimeTasksIfNeeded(container: container)

        XCTAssertEqual(try fetchTask(id).recurrenceTimeMode, .specific, "untouched — nothing reads this for a non-recurring task")
        XCTAssertEqual(try blockCount(), 1)
    }

    // MARK: - Idempotence

    /// Simulates the one realistic path to a second invocation — the
    /// `UserDefaults` flag failing to persist after a successful save — by
    /// clearing the flag and calling again. The function can't tell that
    /// apart from two genuine launches, so this is a faithful reproduction.
    ///
    /// The real guarantee is the per-row flag, committed in the same save:
    /// even with the outer flag gone, an already-migrated row is skipped.
    func test_migration_runTwice_secondPassIsANoOp() throws {
        let task = makeLegacySpecificTask()
        let id = task.id
        _ = makeBlock(for: task, daysFromToday: -1, complete: true)
        try context.save()

        NoteForLaterApp.migrateRecurringSpecificTimeTasksIfNeeded(container: container)
        let afterFirst = try fetchTask(id)
        XCTAssertEqual(afterFirst.recurrenceTimeMode, .midday)

        // Someone edits the task between launches, back to a mode the
        // migration would otherwise rewrite. The per-row flag must stop it.
        afterFirst.recurrenceTimeModeRaw = HabitOccurrenceTimeMode.specific.rawValue
        try context.save()

        UserDefaults.standard.removeObject(forKey: flagKey)
        NoteForLaterApp.migrateRecurringSpecificTimeTasksIfNeeded(container: container)

        XCTAssertEqual(try fetchTask(id).recurrenceTimeMode, .specific,
                       "already migrated once — a second pass must not reclassify a row touched since")
        XCTAssertEqual(try blockCount(), 1, "and must not re-sweep its blocks")
    }

    /// An interrupted run must be resumable. A task inserted after the
    /// first pass has never been seen, so its per-row flag is false and the
    /// next launch finishes the job.
    func test_migration_completesRowsAddedAfterAnInterruptedRun() throws {
        let first = makeLegacySpecificTask(title: "First")
        try context.save()
        NoteForLaterApp.migrateRecurringSpecificTimeTasksIfNeeded(container: container)

        let late = makeLegacySpecificTask(title: "Arrived later")
        let lateID = late.id
        try context.save()
        XCTAssertFalse(late.hasMigratedOffSpecificTime)

        UserDefaults.standard.removeObject(forKey: flagKey)
        NoteForLaterApp.migrateRecurringSpecificTimeTasksIfNeeded(container: container)

        XCTAssertEqual(try fetchTask(lateID).recurrenceTimeMode, .midday)
        XCTAssertEqual(try fetchTask(first.id).recurrenceTimeMode, .midday)
    }

    /// The outer flag is the fast path, not the guarantee. With it set, the
    /// function returns before fetching anything.
    func test_migration_outerFlagShortCircuits() throws {
        UserDefaults.standard.set(true, forKey: flagKey)
        let task = makeLegacySpecificTask()
        let id = task.id
        try context.save()

        NoteForLaterApp.migrateRecurringSpecificTimeTasksIfNeeded(container: container)

        XCTAssertEqual(try fetchTask(id).recurrenceTimeMode, .specific, "gated off — this run did nothing")
    }
}
