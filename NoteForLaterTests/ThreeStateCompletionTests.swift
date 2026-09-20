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

    /// Cycling a block to `.missed` guarantees a fresh placement; cycling
    /// back off `.missed` **undoes it entirely**.
    ///
    /// **REVERSAL, and the reason this test changed rather than gained a
    /// sibling.** It previously asserted `afterIncomplete == 2` with the
    /// message "cycling to incomplete must not place *or remove* anything"
    /// — deliberately locking in that the replacement survived the undo.
    /// That was wrong in use: cycling Missed → Incomplete left a real block
    /// on a future day for work the user had just said wasn't missed after
    /// all, plus an inflated `pushedCount` and a `remainingMinutes` ledger
    /// topped up for a miss that no longer existed. The old expectation is
    /// inverted here rather than duplicated, because both cannot be true.
    ///
    /// **Also adds the assertion whose absence let the real bug through:
    /// which day the replacement lands on.** Nothing checked it, and the
    /// placement was in fact correct all along — `regenerateFromNow` was
    /// deleting it and re-placing the task on the missed day itself. Pinning
    /// the day here is what makes that distinguishable from a placement bug.
    func test_cycleBlockCompletion_missedGuaranteesPlacement_andCyclingOffUndoesIt() async {
        let task = makeEligibleTask()
        let missedDay = day(2026, 1, 5)
        let block = makeBlock(for: task, on: missedDay)
        task.isScheduled = true
        task.remainingMinutes = 0          // the block's 30 minutes were packed out of the ledger
        let viewModel = makeViewModel(targetDate: missedDay)

        // Complete -> Missed: must guarantee a fresh placement.
        _ = viewModel.cycleBlockCompletion(block)
        XCTAssertEqual(block.status, .complete)
        let afterComplete = (try? context.fetch(FetchDescriptor<ScheduledBlock>()))?.count ?? 0
        XCTAssertEqual(afterComplete, 1, "completing must not place anything new")

        _ = viewModel.cycleBlockCompletion(block)
        XCTAssertEqual(block.status, .missed)
        XCTAssertTrue(task.isScheduled, "a missed block must guarantee a fresh placement, re-marking the task scheduled")
        XCTAssertEqual(task.pushedCount, 1)
        XCTAssertEqual(task.remainingMinutes, 30, "the unworked 30 minutes go back to the ledger")

        let all = (try? context.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        XCTAssertEqual(all.count, 2, "missed must place a fresh block alongside the original")

        // **The day assertion.** Not "somewhere" — the next eligible day,
        // never the day it was missed on.
        let replacement = try? XCTUnwrap(all.first { $0.id != block.id })
        let replacementDay = calendar.startOfDay(for: try! XCTUnwrap(replacement).date)
        XCTAssertEqual(
            replacementDay, day(2026, 1, 6),
            "the replacement belongs on the task's next eligible day, not the day it was missed"
        )
        XCTAssertNotEqual(replacementDay, missedDay, "landing on the missed day is the bug this pins")
        XCTAssertEqual(block.guaranteedReplacementBlockID, try! XCTUnwrap(replacement).id, "the original must know which block to undo")

        // Missed -> Incomplete (.none): must undo the push completely.
        _ = viewModel.cycleBlockCompletion(block)
        XCTAssertEqual(block.status, .none)

        let afterUndo = (try? context.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        XCTAssertEqual(afterUndo.count, 1, "the replacement must be deleted, not left stranded")
        XCTAssertTrue(afterUndo.contains { $0.id == block.id }, "and the original must survive")
        XCTAssertEqual(task.pushedCount, 0, "pushedCount must come back down")
        XCTAssertEqual(task.remainingMinutes, 0, "the ledger must return to what it was before the miss")
        XCTAssertTrue(task.isScheduled, "isScheduled must return to its pre-miss value")
        XCTAssertFalse(block.hasGuaranteedReplacement, "no replacement is outstanding any more")
        XCTAssertNil(block.guaranteedReplacementBlockID)
        XCTAssertNil(block.remainingMinutesBeforeMiss)
        XCTAssertNil(block.wasScheduledBeforeMiss)
    }

    /// Cycling all the way round to `.complete` also undoes it — the cycle
    /// reaches `.none` first, so the undo must not be pinned to one exit.
    func test_cyclingFromMissedRoundToComplete_leavesNoReplacement() async {
        let task = makeEligibleTask()
        let block = makeBlock(for: task, on: day(2026, 1, 5))
        let viewModel = makeViewModel(targetDate: day(2026, 1, 5))

        _ = viewModel.cycleBlockCompletion(block)   // complete
        _ = viewModel.cycleBlockCompletion(block)   // missed
        _ = viewModel.cycleBlockCompletion(block)   // none  -> undo fires here
        _ = viewModel.cycleBlockCompletion(block)   // complete

        let remaining = (try? context.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(task.pushedCount, 0)
    }

    /// Re-missing after an undo pushes again, rather than being blocked by a
    /// stale flag. The old comment on `hasGuaranteedReplacement` called it
    /// permanent; it is not any more, and this is what that buys.
    func test_missedAgainAfterUndo_pushesAgain() async {
        let task = makeEligibleTask()
        let block = makeBlock(for: task, on: day(2026, 1, 5))
        let viewModel = makeViewModel(targetDate: day(2026, 1, 5))

        _ = viewModel.cycleBlockCompletion(block)   // complete
        _ = viewModel.cycleBlockCompletion(block)   // missed
        _ = viewModel.cycleBlockCompletion(block)   // none (undo)
        _ = viewModel.cycleBlockCompletion(block)   // complete
        _ = viewModel.cycleBlockCompletion(block)   // missed again

        let remaining = (try? context.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        XCTAssertEqual(remaining.count, 2, "a second miss must place a second replacement")
        XCTAssertEqual(task.pushedCount, 1, "and count once, not twice")
    }

    /// **The pre-existing-data case.** A block already carrying
    /// `hasGuaranteedReplacement` from before these fields existed has a
    /// replacement it cannot identify and no captured prior state. The undo
    /// must clear the flag and leave the ledger alone rather than writing a
    /// guess — the store held zero such blocks when this landed, but one
    /// created before the build reached the device would take this path.
    func test_undoWithNoCapturedState_clearsTheFlagWithoutInventingValues() async {
        let task = makeEligibleTask()
        let block = makeBlock(for: task, on: day(2026, 1, 5))
        task.remainingMinutes = 17
        task.pushedCount = 3
        task.isScheduled = true
        // The pre-migration shape: flag set, nothing captured.
        block.status = .missed
        block.hasGuaranteedReplacement = true
        XCTAssertNil(block.guaranteedReplacementBlockID)
        let viewModel = makeViewModel(targetDate: day(2026, 1, 5))

        _ = viewModel.cycleBlockCompletion(block)   // -> none, undo path

        XCTAssertFalse(block.hasGuaranteedReplacement, "the flag must clear even with nothing captured")
        XCTAssertEqual(task.remainingMinutes, 17, "no captured value means leave the ledger alone")
        XCTAssertTrue(task.isScheduled, "likewise isScheduled")
        XCTAssertEqual(task.pushedCount, 2, "pushedCount is recomputable by decrement, so it still reverses")
    }

    /// **The regression this pairs with: the regenerate must not throw the
    /// guaranteed placement away.**
    ///
    /// `cycleBlockCompletion` sets `ScheduleDirtyState.isDirty`, which makes
    /// the next `syncSchedule()` run a full `regenerateFromNow`. That sweep
    /// deletes every unapproved, unlocked, incomplete, non-manual block at or
    /// after its cutoff — which matched the replacement exactly — freed the
    /// task, and re-walked it from today, landing it back on the day it had
    /// just been missed on. Reproduced exactly this way before the fix:
    /// 2 blocks (09-18 missed, 09-19 replacement) became 2 blocks
    /// (09-18 missed, 09-18 12:00).
    ///
    /// **Correction to an earlier claim in this file's history:** the commit
    /// path is *not* spared because `NightlyReviewCommit` sets
    /// `isDirty = false`. It calls `regenerateFromNow` explicitly
    /// (`NightlyReviewCommit.swift`), and clears the flag afterwards. What
    /// actually spares it is cutoff arithmetic: its view model targets
    /// *tomorrow*, so `cutoff` is tomorrow and today's missed blocks all fall
    /// before it. A missed block on a future day would be swept there too.
    /// That is an accident, not a design — see docs/session-handoff.md.
    func test_regenerateFromNow_doesNotDestroyAGuaranteedReplacement() async {
        let today = calendar.startOfDay(for: .now)
        let task = makeEligibleTask()
        let block = makeBlock(for: task, on: today)
        task.isScheduled = true

        let fake = FakeCalendarService()
        let cal = calendar
        fake.freeSlotsProvider = { date in
            let start = cal.startOfDay(for: date)
            return [TimeSlot(start: start, end: cal.date(byAdding: .hour, value: 23, to: start)!)]
        }
        let viewModel = ScheduleReviewViewModel(modelContext: context, calendarService: fake, schedulingService: service, targetDate: today)

        _ = viewModel.cycleBlockCompletion(block)   // complete
        _ = viewModel.cycleBlockCompletion(block)   // missed
        let replacementID = try? XCTUnwrap(block.guaranteedReplacementBlockID)

        let shelves = (try? context.fetch(FetchDescriptor<Shelf>())) ?? []
        _ = await viewModel.regenerateFromNow(shelves: shelves, habits: [], eligibleHoursWindows: [])

        let all = (try? context.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        XCTAssertTrue(
            all.contains { $0.id == replacementID },
            "the regenerate deleted the guaranteed replacement — the task then gets re-walked onto the missed day"
        )
        for placed in all where placed.id != block.id {
            XCTAssertNotEqual(
                calendar.startOfDay(for: placed.date), today,
                "no replacement for a block missed today may land on today"
            )
        }
    }

    /// **A missed block must survive a regenerate.** It is a record of a
    /// decision, not an unresolved slot — the rule `resolveMissedPastBlocks`
    /// already states and this sweep was quietly breaking.
    ///
    /// The block is placed *later today*, deliberately: `cutoff` is roughly
    /// now, and only a block at or after it is eligible for the sweep. An
    /// earlier-today block survives regardless of the gate, so a fixture
    /// using one would pass against the broken code and prove nothing.
    func test_regenerateFromNow_neverDeletesAMissedBlock() async {
        let today = calendar.startOfDay(for: .now)
        let task = makeEligibleTask()
        let laterHour = min(23, calendar.component(.hour, from: .now) + 3)
        let block = makeBlock(for: task, on: today, hour: laterHour)
        task.isScheduled = true
        let originalID = block.id

        let fake = FakeCalendarService()
        let cal = calendar
        fake.freeSlotsProvider = { date in
            let start = cal.startOfDay(for: date)
            return [TimeSlot(start: start, end: cal.date(byAdding: .hour, value: 23, to: start)!)]
        }
        let viewModel = ScheduleReviewViewModel(modelContext: context, calendarService: fake, schedulingService: service, targetDate: today)

        _ = viewModel.cycleBlockCompletion(block)   // complete
        _ = viewModel.cycleBlockCompletion(block)   // missed

        let shelves = (try? context.fetch(FetchDescriptor<Shelf>())) ?? []
        _ = await viewModel.regenerateFromNow(shelves: shelves, habits: [], eligibleHoursWindows: [])

        let all = (try? context.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        let survivor = all.first { $0.id == originalID }
        XCTAssertNotNil(
            survivor,
            """
            The missed block was deleted and the task re-placed as a fresh \
            .none block — the user's decision silently discarded. `isCompleted` \
            is `status == .complete`, so `!isCompleted` sweeps up `.missed`.
            """
        )
        XCTAssertEqual(survivor?.status, .missed, "and it must still be missed, not reset")
    }

    /// A missed block with no guaranteed replacement must survive too — the
    /// `status == .none` rule has to stand on its own, not lean on the
    /// replacement exemption. A meal block is the real case: it cycles to
    /// `.missed` and never gets a `guaranteePlacement` at all.
    func test_regenerateFromNow_neverDeletesAMissedBlockWithNoReplacement() async {
        let today = calendar.startOfDay(for: .now)
        let laterHour = min(23, calendar.component(.hour, from: .now) + 3)
        let start = calendar.date(byAdding: .hour, value: laterHour, to: today)!
        let mealBlock = ScheduledBlock(date: today, startTime: start, endTime: start.addingTimeInterval(1800), task: nil)
        mealBlock.status = .missed
        context.insert(mealBlock)
        XCTAssertFalse(mealBlock.hasGuaranteedReplacement)

        let viewModel = makeViewModel(targetDate: today)
        let shelves = (try? context.fetch(FetchDescriptor<Shelf>())) ?? []
        _ = await viewModel.regenerateFromNow(shelves: shelves, habits: [], eligibleHoursWindows: [])

        let all = (try? context.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        XCTAssertTrue(
            all.contains { $0.id == mealBlock.id },
            "protecting only guaranteed replacements would miss this one entirely"
        )
    }

    /// **The day list must not show another day's block.** `insertWithRipple`
    /// assigned the whole store to `blocks`, and `timelineRows` does no day
    /// filtering, so a replacement placed on a later day rendered on today's
    /// grid — stacked on the block it replaced, since the time of day is
    /// preserved.
    func test_guaranteedReplacementDoesNotLeakIntoTodaysBlockList() async {
        let today = calendar.startOfDay(for: .now)
        let task = makeEligibleTask()
        let block = makeBlock(for: task, on: today)
        let viewModel = makeViewModel(targetDate: today)
        viewModel.loadExistingBlocks([block])

        _ = viewModel.cycleBlockCompletion(block)   // complete
        _ = viewModel.cycleBlockCompletion(block)   // missed

        for shown in viewModel.blocks {
            XCTAssertTrue(
                calendar.isDate(shown.date, inSameDayAs: today),
                "viewModel.blocks drives the day grid — it must hold only today's blocks"
            )
        }
        XCTAssertEqual(viewModel.blocks.count, 1, "just the missed original; the replacement belongs to another day")
    }

    /// **The Next gate is backlog-only for recurring occurrences**, matching
    /// the Habits step (`ScheduleReviewViewModel.backlogHabitOccurrences`).
    ///
    /// A recurring task due this evening may still legitimately happen;
    /// being made to declare it done or missed at 9pm while planning
    /// tomorrow is a false choice. Earlier days are over. Habits got this
    /// when their gate was split out; the recurring side kept the old
    /// combined rule and never did — the asymmetry was the oversight.
    ///
    /// Visibility is unchanged: the review date's own occurrences still
    /// render and are still markable. Gating only.
    func test_recurringOccurrenceGate_blocksBacklogButNotTheReviewDate() throws {
        let reviewDate = day(2026, 1, 5)
        let task = makeEligibleTask()
        task.isRecurring = true

        func occurrence(on target: Date) -> ReviewItem {
            .recurringTask(ScheduleReviewViewModel.RecurringTaskReviewOccurrence(
                id: "\(task.id)-\(Int(target.timeIntervalSince1970))",
                task: task,
                status: .none,
                targetTime: calendar.date(byAdding: .hour, value: 12, to: target)!,
                modeLabel: "Midday"
            ))
        }

        XCTAssertFalse(
            occurrence(on: reviewDate).blocksGate(context: context, reviewDate: reviewDate),
            "the review date's own occurrence may still happen — it must not block Next"
        )
        XCTAssertTrue(
            occurrence(on: day(2026, 1, 4)).blocksGate(context: context, reviewDate: reviewDate),
            "an earlier day is over, so an unresolved occurrence there is genuinely unaddressed"
        )
    }

    /// A resolved backlog occurrence satisfies the gate — the date bound
    /// must not turn the gate into "any backlog blocks".
    func test_recurringOccurrenceGate_resolvedBacklogDoesNotBlock() throws {
        let reviewDate = day(2026, 1, 5)
        let task = makeEligibleTask()
        task.isRecurring = true
        let item = ReviewItem.recurringTask(ScheduleReviewViewModel.RecurringTaskReviewOccurrence(
            id: "x", task: task, status: .missed,
            targetTime: calendar.date(byAdding: .hour, value: 12, to: day(2026, 1, 4))!,
            modeLabel: "Midday"
        ))

        XCTAssertFalse(item.blocksGate(context: context, reviewDate: reviewDate), "missed is a resolved, terminal answer")
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

        XCTAssertTrue(ReviewItem.block(block).blocksGate(context: context, reviewDate: day(2026, 1, 5)), "an unmarked block must block Next")

        block.status = .missed
        XCTAssertFalse(ReviewItem.block(block).blocksGate(context: context, reviewDate: day(2026, 1, 5)), "a missed block must satisfy the gate — it's a resolved, terminal answer")

        block.status = .complete
        XCTAssertFalse(ReviewItem.block(block).blocksGate(context: context, reviewDate: day(2026, 1, 5)))
    }

    func test_gate_blocksOnUnmarkedMeal_notOnMissedOrComplete() {
        let (block, selection, _) = makeMealBlock(on: day(2026, 1, 5))

        XCTAssertTrue(ReviewItem.meal(selection, targetTime: block.startTime).blocksGate(context: context, reviewDate: day(2026, 1, 5)))

        selection.status = .missed
        XCTAssertFalse(ReviewItem.meal(selection, targetTime: block.startTime).blocksGate(context: context, reviewDate: day(2026, 1, 5)))
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
        XCTAssertTrue(ReviewItem.block(block).blocksGate(context: context, reviewDate: day(2026, 1, 5)), "no RecurringTaskLog yet means .none — still unresolved")

        let log = RecurringTaskLog.logOrCreate(taskID: task.id, on: block.date, context: context, calendar: calendar)
        log.status = .missed
        XCTAssertFalse(ReviewItem.block(block).blocksGate(context: context, reviewDate: day(2026, 1, 5)), "resolved in RecurringTaskLog — must satisfy the gate regardless of block.status")
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
