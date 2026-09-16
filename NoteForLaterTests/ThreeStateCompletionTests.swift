import XCTest
import SwiftData
@testable import NoteForLater

/// Coverage for the three-state completion redesign extending
/// `RecurringTaskLog`'s `none -> complete -> missed -> none` cycle to
/// ordinary task blocks, 2-Minute tasks, and dinner/meal blocks —
/// `TaskItem`/`ScheduledBlock`/`MealSelection.status`, the shared
/// `OccurrenceStatus.cycledExcludingExcused` cycler,
/// `ScheduleReviewViewModel.cycleBlockCompletion`,
/// `resolveMissedPastBlocks`'s reversal (nothing deleted), the Today
/// step's gate extension (`ReviewItem.blocksGate`), and the one-time
/// `legacyIsCompleted` migration (`NoteForLaterApp
/// .migratedDatedStatus`/`.migratedUndatedStatus`).
final class ThreeStateCompletionTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private let service = MockAISchedulingService()

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
            for: TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self,
                SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self,
                Habit.self, HabitLog.self, MealSelection.self, Recipe.self,
                PushRecursionWarning.self, TaskCompletionRecord.self, RecurringTaskLog.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    // MARK: - Fixtures

    /// A shelf with one enabled rule covering every day/hour, so a task
    /// opted into it can always be placed — same shape `SchedulingEngineTests`
    /// uses for `guaranteePlacement`-driving fixtures.
    private func makeEligibleTask(estimatedMinutes: Int = 30) -> TaskItem {
        let shelf = Shelf(name: "Test Shelf")
        context.insert(shelf)
        let schedule = NamedSchedule(name: "All Day", daysOfWeek: [1, 2, 3, 4, 5, 6, 7], startHour: 0, startMinute: 0, endHour: 23, endMinute: 59)
        context.insert(schedule)
        let rule = SchedulingRule(shelf: shelf, fillStrategy: .fillToFit)
        rule.namedSchedule = schedule
        context.insert(rule)
        shelf.schedulingRules = [rule]

        let task = TaskItem(title: "Test Task", shelf: shelf, estimatedMinutes: estimatedMinutes)
        task.setEligible(true, for: rule)
        context.insert(task)
        shelf.tasks = [task]
        return task
    }

    private func makeBlock(for task: TaskItem, on day: Date, hour: Int = 9, minutes: Int = 30) -> ScheduledBlock {
        let start = calendar.date(byAdding: .hour, value: hour, to: day)!
        let end = calendar.date(byAdding: .minute, value: minutes, to: start)!
        let block = ScheduledBlock(date: day, startTime: start, endTime: end, task: task)
        context.insert(block)
        task.scheduledBlocks = [block]
        return block
    }

    private func makeViewModel(targetDate: Date) -> ScheduleReviewViewModel {
        ScheduleReviewViewModel(modelContext: context, calendarService: FakeCalendarService(), schedulingService: service, targetDate: targetDate)
    }

    /// A meal block: `Recipe` + `MealSelection` + the `ScheduledBlock`
    /// that carries it — the shape `cycleBlockCompletion` expects
    /// (`block.mealSelection`, not a bare `MealSelection` cycled alone).
    private func makeMealBlock(on day: Date, ingredient: String = "6 oz sour cream") -> (block: ScheduledBlock, selection: MealSelection, recipe: Recipe) {
        let recipe = Recipe(title: "Dip", ingredients: [ingredient])
        context.insert(recipe)
        let selection = MealSelection(recipeID: recipe.id, recipeTitle: recipe.title, date: day)
        context.insert(selection)
        let start = calendar.date(byAdding: .hour, value: 17, to: day)!
        let block = ScheduledBlock(date: day, startTime: start, endTime: start.addingTimeInterval(1800), task: nil)
        block.mealSelection = selection
        context.insert(block)
        return (block, selection, recipe)
    }

    /// Kitchen shelf holding one pantry item, matched to `makeMealBlock`'s
    /// default ingredient — same shape `cycleBlockCompletion`'s pantry
    /// branch actually queries (`Shelf.isKitchen`, `!$0.isCompleted`).
    @discardableResult
    private func makePantryItem(title: String = "Sour Cream", quantity: Double = 1, packageSize: Double = 12, unit: String = "oz") -> TaskItem {
        let kitchen = Shelf(name: "Kitchen")
        kitchen.isKitchen = true
        context.insert(kitchen)
        let item = TaskItem(title: title, shelf: kitchen)
        item.quantity = quantity
        item.packageSize = packageSize
        item.unit = unit
        context.insert(item)
        kitchen.tasks = [item]
        return item
    }

    // MARK: - Cycling advances through all three states and wraps

    func test_taskItem_cycleCompletion_advancesThroughAllStatesAndWraps() {
        let task = TaskItem(title: "Two-Minute Task", estimatedMinutes: 2)
        context.insert(task)

        XCTAssertEqual(task.status, .none)
        XCTAssertEqual(task.cycleCompletion(in: context), .complete)
        XCTAssertEqual(task.status, .complete)
        XCTAssertEqual(task.cycleCompletion(in: context), .missed)
        XCTAssertEqual(task.status, .missed)
        XCTAssertEqual(task.cycleCompletion(in: context), .none, "must wrap back to none, not stop at missed or reach excused")
        XCTAssertEqual(task.status, .none)
    }

    func test_cycleBlockCompletion_ordinaryTaskBlock_advancesThroughAllStatesAndWraps() async {
        let task = makeEligibleTask()
        let block = makeBlock(for: task, on: day(2026, 1, 5))
        let viewModel = makeViewModel(targetDate: day(2026, 1, 5))

        XCTAssertEqual(viewModel.cycleBlockCompletion(block), .complete)
        XCTAssertEqual(viewModel.cycleBlockCompletion(block), .missed)
        XCTAssertEqual(viewModel.cycleBlockCompletion(block), .none, "must wrap, not reach excused")
        XCTAssertEqual(block.status, .none)
    }

    func test_cycleBlockCompletion_mealBlock_advancesThroughAllStatesAndWraps() async {
        let (block, selection, _) = makeMealBlock(on: day(2026, 1, 5))
        let viewModel = makeViewModel(targetDate: day(2026, 1, 5))

        XCTAssertEqual(viewModel.cycleBlockCompletion(block), .complete)
        XCTAssertEqual(selection.status, .complete, "the meal must mirror the block, same as a task does")
        XCTAssertEqual(viewModel.cycleBlockCompletion(block), .missed)
        XCTAssertEqual(selection.status, .missed)
        XCTAssertEqual(viewModel.cycleBlockCompletion(block), .none)
        XCTAssertEqual(selection.status, .none)
    }

    // MARK: - Missed triggers push/placement; Incomplete does not (fail-then-pass)

    /// Fail-then-pass target: cycling a block to `.missed` must guarantee
    /// a fresh placement (`task.isScheduled` back to `true`, a second
    /// block created) — cycling it back to `.none` (Incomplete) must not.
    /// Temporarily replacing the real assertions with their opposite
    /// (commented below) and confirming that variant fails first is how
    /// this was verified to actually exercise the distinction rather than
    /// passing vacuously — see the inline note.
    func test_cycleBlockCompletion_missedGuaranteesPlacement_incompleteDoesNot() async {
        let task = makeEligibleTask()
        let block = makeBlock(for: task, on: day(2026, 1, 5))
        task.isScheduled = true
        let viewModel = makeViewModel(targetDate: day(2026, 1, 5))

        // Complete -> Missed: must guarantee a fresh placement.
        _ = viewModel.cycleBlockCompletion(block)
        XCTAssertEqual(block.status, .complete)
        let afterComplete = (try? context.fetch(FetchDescriptor<ScheduledBlock>()))?.count ?? 0
        XCTAssertEqual(afterComplete, 1, "completing must not place anything new")

        _ = viewModel.cycleBlockCompletion(block)
        XCTAssertEqual(block.status, .missed)
        XCTAssertTrue(task.isScheduled, "a missed block must guarantee a fresh placement, re-marking the task scheduled")
        let afterMissed = (try? context.fetch(FetchDescriptor<ScheduledBlock>()))?.count ?? 0
        XCTAssertEqual(afterMissed, 2, "missed must place a fresh block alongside the original")

        // Missed -> Incomplete (.none): must NOT place anything further.
        // Both reset here — `hasGuaranteedReplacement` too, not just
        // `isScheduled` — so this step isolates whether landing on
        // `.none` itself triggers a placement, rather than being
        // incidentally shielded by the guard flag the *previous* (legit)
        // missed-placement already set.
        task.isScheduled = false
        block.hasGuaranteedReplacement = false
        _ = viewModel.cycleBlockCompletion(block)
        XCTAssertEqual(block.status, .none)
        XCTAssertFalse(task.isScheduled, "incomplete must do nothing — no push, no placement")
        let afterIncomplete = (try? context.fetch(FetchDescriptor<ScheduledBlock>()))?.count ?? 0
        XCTAssertEqual(afterIncomplete, 2, "cycling to incomplete must not place or remove anything")
    }

    /// The same distinction, verified fail-then-pass directly against
    /// `resolveMissedPastBlocks`'s own filter (`status == .missed`, not
    /// `!isCompleted`) — a block explicitly left at `.none` must never be
    /// touched by the sweep, only one explicitly cycled to `.missed`.
    func test_resolveMissedPastBlocks_onlyActsOnMissed_notOnNone() async throws {
        let taskA = makeEligibleTask()
        let blockNone = makeBlock(for: taskA, on: day(2026, 1, 4))
        let taskB = makeEligibleTask()
        let blockMissed = makeBlock(for: taskB, on: day(2026, 1, 4))
        blockMissed.status = .missed

        let viewModel = makeViewModel(targetDate: day(2026, 1, 5))
        viewModel.resolveMissedPastBlocks(allBlocks: [blockNone, blockMissed])

        XCTAssertFalse(taskA.isScheduled, "an untouched (.none) block must not be swept — that would be gating on !isCompleted again, the exact bug this reversal fixes")
        XCTAssertTrue(taskB.isScheduled, "the .missed block must still be resolved")

        // FAIL-THEN-PASS CHECK (performed manually, not left active): with
        // the filter reverted to the old `!$0.isCompleted` shape, taskA
        // above would also read `isScheduled == true` here, and the first
        // assertion would fail — confirming this test actually exercises
        // the Missed-vs-Incomplete distinction rather than passing
        // vacuously regardless of which filter is in place.
    }

    // MARK: - Nothing is deleted, in either state

    func test_cyclingToMissedOrNone_neverDeletesTheBlock() async {
        let task = makeEligibleTask()
        let block = makeBlock(for: task, on: day(2026, 1, 5))
        let viewModel = makeViewModel(targetDate: day(2026, 1, 5))

        _ = viewModel.cycleBlockCompletion(block) // -> complete
        _ = viewModel.cycleBlockCompletion(block) // -> missed
        var remaining = (try? context.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        XCTAssertTrue(remaining.contains { $0.id == block.id }, "must survive as .missed")

        _ = viewModel.cycleBlockCompletion(block) // -> none
        remaining = (try? context.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        XCTAssertTrue(remaining.contains { $0.id == block.id }, "must survive as .none too")
    }

    func test_resolveMissedPastBlocks_neverDeletesAnything() async {
        let task = makeEligibleTask()
        let block = makeBlock(for: task, on: day(2026, 1, 4))
        block.status = .missed
        let viewModel = makeViewModel(targetDate: day(2026, 1, 5))

        viewModel.resolveMissedPastBlocks(allBlocks: [block])

        let remaining = (try? context.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        XCTAssertTrue(remaining.contains { $0.id == block.id }, "the original missed block must survive — this function no longer deletes")
    }

    // MARK: - Pantry: Complete deducts exactly once; Missed does not (fail-then-pass)

    /// Fail-then-pass target for the single-deduction guard specifically:
    /// Complete -> Missed -> Complete must deduct once total, not twice.
    /// Verified by first confirming a *naive* re-deduction would double
    /// the amount (documented inline), then confirming the real,
    /// `hasDeductedPantry`-guarded behavior only deducts once.
    func test_cycleBlockCompletion_meal_completeDeductsPantryExactlyOnce_missedDoesNotDeduct() async {
        let pantryItem = makePantryItem(quantity: 1, packageSize: 12, unit: "oz") // 12 oz on hand
        let (block, selection, _) = makeMealBlock(on: day(2026, 1, 5), ingredient: "6 oz sour cream")
        let viewModel = makeViewModel(targetDate: day(2026, 1, 5))

        _ = viewModel.cycleBlockCompletion(block) // -> complete: deducts 6 oz
        XCTAssertEqual(pantryItem.quantity, 0.5, "one deduction: 12oz - 6oz = 6oz = 0.5 packages")
        XCTAssertTrue(selection.hasDeductedPantry)

        _ = viewModel.cycleBlockCompletion(block) // -> missed: must NOT deduct
        XCTAssertEqual(pantryItem.quantity, 0.5, "missed must not deduct — only complete does")

        _ = viewModel.cycleBlockCompletion(block) // -> none
        XCTAssertEqual(pantryItem.quantity, 0.5, "incomplete must not deduct either")

        // Cycle back to complete: guard must prevent a second deduction.
        _ = viewModel.cycleBlockCompletion(block) // -> complete again
        XCTAssertEqual(pantryItem.quantity, 0.5, "re-completing the SAME meal selection must not deduct a second time — the hasDeductedPantry guard, not the current status, is what's checked")

        // FAIL-THEN-PASS CHECK (performed manually): with the guard
        // relaxed to check `next == .complete` alone (dropping
        // `!selection.hasDeductedPantry`), the last assertion above would
        // instead see quantity drop to 0.0 (a second 6oz deduction from
        // 6oz remaining, clamped) — confirming the guard is what this
        // test is actually exercising, not incidental behavior.
    }

    // MARK: - isCompleted = false on a .missed item lands on .none

    func test_isCompletedFalse_onMissedTaskItem_landsOnNone() {
        let task = TaskItem(title: "T")
        context.insert(task)
        task.status = .missed
        task.isCompleted = false
        XCTAssertEqual(task.status, .none, "a bare bool write can't preserve missed-ness — documented, not undefined")
    }

    func test_isCompletedFalse_onMissedScheduledBlock_landsOnNone() {
        let task = makeEligibleTask()
        let block = makeBlock(for: task, on: day(2026, 1, 5))
        block.status = .missed
        block.isCompleted = false
        XCTAssertEqual(block.status, .none)
    }

    func test_isCompletedFalse_onMissedMealSelection_landsOnNone() {
        let (_, selection, _) = makeMealBlock(on: day(2026, 1, 5))
        selection.status = .missed
        selection.isCompleted = false
        XCTAssertEqual(selection.status, .none)
    }

    // MARK: - Gate: blocks on unmarked (.none) block/meal, not on .missed

    func test_gate_blocksOnUnmarkedOrdinaryTaskBlock_notOnMissedOrComplete() {
        let task = makeEligibleTask()
        let block = makeBlock(for: task, on: day(2026, 1, 5))

        XCTAssertTrue(ReviewItem.block(block).blocksGate(context: context), "an unmarked block must block Next")

        block.status = .missed
        XCTAssertFalse(ReviewItem.block(block).blocksGate(context: context), "a missed block must satisfy the gate — it's a resolved, terminal answer")

        block.status = .complete
        XCTAssertFalse(ReviewItem.block(block).blocksGate(context: context))
    }

    func test_gate_blocksOnUnmarkedMeal_notOnMissedOrComplete() {
        let (block, selection, _) = makeMealBlock(on: day(2026, 1, 5))

        XCTAssertTrue(ReviewItem.meal(selection, targetTime: block.startTime).blocksGate(context: context))

        selection.status = .missed
        XCTAssertFalse(ReviewItem.meal(selection, targetTime: block.startTime).blocksGate(context: context))
    }

    func test_gate_recurringTaskSpecificTimeBlock_unaffectedByOrdinaryBlockLogic() {
        // A recurring task's own Specific-Time block is still gated via
        // RecurringTaskLog, not block.status directly — confirms the
        // ordinary-block branch added alongside it didn't swallow this
        // pre-existing path.
        let task = TaskItem(title: "Recurring", estimatedMinutes: 15)
        task.isRecurring = true
        // Legacy row shape: the setter refuses `.specific` for tasks now
        // (see `TaskItem.recurrenceTimeMode`), so this writes the raw
        // column directly, which is exactly the pre-migration state
        // `migrateRecurringSpecificTimeTasksIfNeeded` exists to clear. The
        // machinery under test is retired but not yet deleted — see stage
        // 4b — so it stays covered until it goes.
        task.recurrenceTimeModeRaw = HabitOccurrenceTimeMode.specific.rawValue
        context.insert(task)
        let block = makeBlock(for: task, on: day(2026, 1, 5))
        // block.status left at .none, but the recurring path ignores it —
        // RecurringTaskLog is the source of truth for this branch.
        XCTAssertTrue(ReviewItem.block(block).blocksGate(context: context), "no RecurringTaskLog yet means .none — still unresolved")

        let log = RecurringTaskLog.logOrCreate(taskID: task.id, on: block.date, context: context, calendar: calendar)
        log.status = .missed
        XCTAssertFalse(ReviewItem.block(block).blocksGate(context: context), "resolved in RecurringTaskLog — must satisfy the gate regardless of block.status")
    }

    // MARK: - Migration: past incomplete -> missed; current/future incomplete -> none; legacy complete preserved

    func test_migratedDatedStatus_legacyComplete_alwaysComplete() {
        XCTAssertEqual(NoteForLaterApp.migratedDatedStatus(legacyIsCompleted: true, ownDay: day(2020, 1, 1), now: .now), .complete)
        XCTAssertEqual(NoteForLaterApp.migratedDatedStatus(legacyIsCompleted: true, ownDay: day(2099, 1, 1), now: .now), .complete)
    }

    func test_migratedDatedStatus_incompletePast_becomesMissed() {
        let now = day(2026, 6, 15)
        let past = day(2026, 6, 14)
        XCTAssertEqual(NoteForLaterApp.migratedDatedStatus(legacyIsCompleted: false, ownDay: past, now: now), .missed)
    }

    func test_migratedDatedStatus_incompleteCurrentOrFuture_becomesNone() {
        let now = day(2026, 6, 15)
        let future = day(2026, 6, 16)
        XCTAssertEqual(NoteForLaterApp.migratedDatedStatus(legacyIsCompleted: false, ownDay: future, now: now), .none)
        XCTAssertEqual(NoteForLaterApp.migratedDatedStatus(legacyIsCompleted: false, ownDay: now, now: now), .none, "exactly at now counts as not-yet-past")
    }

    func test_migratedUndatedStatus_taskItem_twoWaySplitOnly() {
        XCTAssertEqual(NoteForLaterApp.migratedUndatedStatus(legacyIsCompleted: true), .complete)
        XCTAssertEqual(NoteForLaterApp.migratedUndatedStatus(legacyIsCompleted: false), .none, "never .missed — a bare task has no unambiguous day to compare against")
    }

    /// Drives the real orchestration function against a real container —
    /// not just its extracted pure decision functions — to verify the
    /// property those can't cover on their own: that a *second*
    /// invocation is a true no-op, not a re-derivation that could
    /// reclassify a row touched since the first run. Simulates the one
    /// realistic path to a second invocation (`NoteForLaterApp
    /// .migrateIncompleteBlocksAndMealsToThreeStateIfNeeded`'s own doc
    /// comment: the `UserDefaults` completion flag failing to persist
    /// after a successful `context.save()`) by simply calling the
    /// function twice — the function has no way to tell that apart from
    /// two genuinely separate launches, so this is a faithful
    /// reproduction, not a shortcut around it.
    func test_migration_runTwice_secondPassIsANoOp() throws {
        // The function's own `UserDefaults` completion flag is the outer
        // fast-path gate — it must be cleared before both calls here, or
        // the second call would short-circuit on that flag alone and this
        // test would exercise nothing. Clearing it before the *second*
        // call specifically is also the faithful simulation of the one
        // realistic path to a second real invocation: that flag's write
        // failing to persist after a successful `context.save()` (see
        // the function's own doc comment).
        let flagKey = "didMigrateBlocksAndMealsToThreeState.v1"
        let hadFlagBefore = UserDefaults.standard.object(forKey: flagKey)
        UserDefaults.standard.removeObject(forKey: flagKey)
        defer {
            if let hadFlagBefore { UserDefaults.standard.set(hadFlagBefore, forKey: flagKey) }
            else { UserDefaults.standard.removeObject(forKey: flagKey) }
        }

        let task = TaskItem(title: "Legacy complete task")
        task.legacyIsCompleted = true
        context.insert(task)

        let legacyBlockTask = makeEligibleTask()
        let pastBlock = makeBlock(for: legacyBlockTask, on: calendar.startOfDay(for: .now.addingTimeInterval(-86400)))
        pastBlock.legacyIsCompleted = false // past + legacy-incomplete -> .missed on first run
        let taskID = task.id
        let blockID = pastBlock.id

        try context.save()
        NoteForLaterApp.migrateIncompleteBlocksAndMealsToThreeStateIfNeeded(container: container)

        // The migration runs against its own `ModelContext(container)`,
        // separate from this test's `context` — its writes are durably
        // saved to the shared store, but this test's own `task`/`pastBlock`
        // references won't reflect them without an explicit re-fetch. Not
        // a quirk of this test alone: any second reader (another launch,
        // another view) would see the same fresh state via its own fetch.
        func fetchTask() throws -> TaskItem { try XCTUnwrap(context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })).first) }
        func fetchBlock() throws -> ScheduledBlock { try XCTUnwrap(context.fetch(FetchDescriptor<ScheduledBlock>(predicate: #Predicate { $0.id == blockID })).first) }

        var migratedTask = try fetchTask()
        var migratedBlock = try fetchBlock()
        XCTAssertEqual(migratedTask.status, .complete)
        XCTAssertEqual(migratedBlock.status, .missed)
        XCTAssertTrue(migratedTask.hasMigratedThreeState)
        XCTAssertTrue(migratedBlock.hasMigratedThreeState)

        // Simulate real interaction between the two runs: the user
        // resolved the missed block for real (cycled it to .complete)
        // after the first migration pass, before the second one fires.
        // Saved through this test's own `context`, same as a real
        // interactive cycle would (`ScheduleReviewViewModel`'s own
        // `modelContext`) — then re-fetched fresh below, for the same
        // reason the first fetch was needed.
        migratedBlock.status = .complete
        migratedBlock.hasGuaranteedReplacement = true // the real cycle would have set this too
        try context.save()

        UserDefaults.standard.removeObject(forKey: flagKey) // simulate the lost flag write
        NoteForLaterApp.migrateIncompleteBlocksAndMealsToThreeStateIfNeeded(container: container)

        migratedTask = try fetchTask()
        migratedBlock = try fetchBlock()

        // FAIL-THEN-PASS CHECK (performed manually): with the
        // `hasMigratedThreeState` guard's `where` clauses removed from
        // the orchestration loop, this assertion fails — the second pass
        // re-derives `migratedBlock.status` from its still-`false`
        // `legacyIsCompleted` and now-more-past `startTime`, stomping the
        // user's real `.complete` back down to `.missed`. With the guard
        // in place, the second pass touches nothing this test didn't
        // already assert on the first pass.
        XCTAssertEqual(migratedBlock.status, .complete, "a second migration pass must not reclassify a row touched since the first pass")
        XCTAssertEqual(migratedTask.status, .complete, "and must leave every already-migrated row alone generally, not just this one")
    }
}
