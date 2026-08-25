import XCTest
import SwiftData
@testable import NoteForLater

/// Scheduling engine spec (docs/NoteForLater-Scheduling-Spec.md).
/// Phase 1: `TaskItem.remainingMinutes` + packing floor fixes — §12 cases
/// 7-9, plus two cases for the init/clamp behavior `remainingMinutes`
/// depends on.
/// Phase 2: `SchedulingRule.fitStatus`/`canEverFit`, `TaskItem
/// .isEffectivelyEligible`, `syncEligibilityWithFit` removal — §12 cases
/// 1-6 (fit checking) and 10 (Tier-3-removal regression, now against the
/// `isEffectivelyEligible` filter).
/// Phase 4: `TaskItem.slack`/`isAtRisk`/`atRiskBlocker`, `taskOrdering`'s
/// slack-based primary sort tier — §12 cases 11-14 (ordering), plus
/// slack/at-risk boundary and blocker-naming coverage.
/// Phase 5: stall detection (§6.4, replacing the old flat 365-day
/// `taskSafetyCapDays`) and the ViewModel-level case for why
/// `ScheduleDirtyState`'s flush has to escalate to `regenerateFromNow`
/// rather than just running `autoPlaceEligibleTasks` again — §6. Full
/// UI-level coverage of the dirty flag's ~10 trigger sites (Views only,
/// no ViewModel logic of their own beyond a one-line flag set) isn't
/// covered here — this suite has no UI-testing harness, only SwiftData-
/// backed unit tests.
final class SchedulingEngineTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private let service = MockAISchedulingService()

    /// Fixed zone/dates, same reasoning as `HabitRollingStatsTests` — these
    /// tests must not depend on the wall clock or the machine's timezone.
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
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    // MARK: - Fixtures

    /// A shelf with one enabled rule, on a `NamedSchedule` covering every
    /// day of the week (so the fixture never has to care which weekday
    /// `on` actually falls on) and the full clock (so `freeSlots` alone
    /// decides what's actually available).
    private func makeShelf(fillStrategy: FillStrategy, maxTotalMinutes: Int = 120, maxTaskCount: Int = 2, maxMinutesPerTask: Int = 15) -> (shelf: Shelf, rule: SchedulingRule) {
        let shelf = Shelf(name: "Test Shelf")
        context.insert(shelf)

        let schedule = NamedSchedule(name: "All Day", daysOfWeek: [1, 2, 3, 4, 5, 6, 7], startHour: 0, startMinute: 0, endHour: 23, endMinute: 59)
        context.insert(schedule)

        let rule = SchedulingRule(shelf: shelf, fillStrategy: fillStrategy, maxTotalMinutes: maxTotalMinutes, maxTaskCount: maxTaskCount, maxMinutesPerTask: maxMinutesPerTask)
        rule.namedSchedule = schedule
        context.insert(rule)
        shelf.schedulingRules = [rule]

        return (shelf, rule)
    }

    /// Inserted on `shelf` and explicitly opted into `rule` — eligibility
    /// is opt-in only (see `TaskItem.includedSchedulingRuleIDs`), so a
    /// candidate that's never toggled in is invisible to the packer
    /// regardless of anything else about it.
    private func makeTask(shelf: Shelf, rule: SchedulingRule, estimatedMinutes: Int, isDivisible: Bool, minimumSegmentMinutes: Int) -> TaskItem {
        let task = TaskItem(title: "Test Task", shelf: shelf, estimatedMinutes: estimatedMinutes, isDivisible: isDivisible, minimumSegmentMinutes: minimumSegmentMinutes)
        task.setEligible(true, for: rule)
        context.insert(task)
        shelf.tasks = (shelf.tasks ?? []) + [task]
        return task
    }

    private func businessHoursSlot(on date: Date) -> TimeSlot {
        TimeSlot(
            start: calendar.date(byAdding: .hour, value: 9, to: date)!,
            end: calendar.date(byAdding: .hour, value: 17, to: date)!
        )
    }

    // MARK: - §12.7 — divisible task below its own segment floor is skipped, not truncated

    func test_divisibleTaskBelowSegmentFloor_isNotPlaced() async throws {
        let testDay = day(2026, 1, 5)
        let (shelf, rule) = makeShelf(fillStrategy: .maxDuration, maxTotalMinutes: 20)
        let task = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 240, isDivisible: true, minimumSegmentMinutes: 60)

        let blocks = try await service.generateProposedSchedule(
            shelves: [shelf],
            habits: [],
            freeSlots: [businessHoursSlot(on: testDay)],
            eligibleHoursWindows: [],
            date: testDay,
            existingBlocks: [],
            context: context
        )

        XCTAssertTrue(blocks.isEmpty)
        XCTAssertEqual(task.remainingMinutes, 240)
        XCTAssertFalse(task.isScheduled)
    }

    // MARK: - §12.8 — partial placement drains remainingMinutes, never estimatedMinutes

    func test_partialPlacement_decrementsRemainingNotEstimated() async throws {
        let testDay = day(2026, 1, 5)
        let (shelf, rule) = makeShelf(fillStrategy: .maxDuration, maxTotalMinutes: 50)
        let task = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 120, isDivisible: true, minimumSegmentMinutes: 30)

        let blocks = try await service.generateProposedSchedule(
            shelves: [shelf],
            habits: [],
            freeSlots: [businessHoursSlot(on: testDay)],
            eligibleHoursWindows: [],
            date: testDay,
            existingBlocks: [],
            context: context
        )

        XCTAssertEqual(blocks.count, 1)
        // Was 50 (the rule's whole remaining budget) with 70 left over.
        // Those numbers encoded the orphan bug: 50 isn't a multiple of
        // this task's own 30-minute segment floor, and 70 left over means
        // future placements take 60 and strand a 10-minute remainder no
        // slot is ever allowed to accept. The budget is now floored to a
        // whole segment, so both the placed amount and what's left stay
        // multiples of 30. The property this test exists for — that
        // partial placement drains `remainingMinutes` and never touches
        // `estimatedMinutes` — is unchanged and still asserted below.
        XCTAssertEqual(blocks.first?.durationMinutes, 30)
        XCTAssertEqual(task.estimatedMinutes, 120)
        XCTAssertEqual(task.remainingMinutes, 90)
        XCTAssertFalse(task.isScheduled)
    }

    // MARK: - §12.9 — clearing that partial block restores remainingMinutes to full

    func test_clearIncompletePastBlocks_restoresRemainingMinutes() async throws {
        let testDay = day(2026, 1, 5)
        let yesterday = day(2026, 1, 4)
        let (shelf, rule) = makeShelf(fillStrategy: .maxDuration, maxTotalMinutes: 50)
        let task = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 120, isDivisible: true, minimumSegmentMinutes: 30)
        // Simulates the partial placement from the test above, landed
        // yesterday rather than today — this is what makes the block
        // genuinely "past" without depending on wall-clock time.
        task.remainingMinutes = 70
        task.isScheduled = true
        let blockStart = calendar.date(byAdding: .hour, value: 9, to: yesterday)!
        let blockEnd = calendar.date(byAdding: .minute, value: 50, to: blockStart)!
        let block = ScheduledBlock(date: yesterday, startTime: blockStart, endTime: blockEnd, task: task)
        context.insert(block)

        let viewModel = ScheduleReviewViewModel(modelContext: context, calendarService: FakeCalendarService(), schedulingService: service, targetDate: testDay)
        await viewModel.clearIncompletePastBlocks(allBlocks: [block], cutoff: testDay)

        XCTAssertEqual(task.remainingMinutes, 120)
        XCTAssertFalse(task.isScheduled)
    }

    // MARK: - remainingMinutes starts in sync with estimatedMinutes

    func test_taskInit_remainingMinutesMatchesEstimated() {
        let shelf = Shelf(name: "Test Shelf")
        let task = TaskItem(title: "Sample", shelf: shelf, estimatedMinutes: 120)
        XCTAssertEqual(task.remainingMinutes, 120)
    }

    // MARK: - restoring more than the gap clamps to estimatedMinutes

    func test_clearIncompletePastBlocks_clampsRemainingToEstimated() async throws {
        let testDay = day(2026, 1, 5)
        let yesterday = day(2026, 1, 4)
        let (shelf, rule) = makeShelf(fillStrategy: .maxDuration, maxTotalMinutes: 50)
        let task = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 120, isDivisible: true, minimumSegmentMinutes: 30)
        // Already has more headroom than a straightforward restore should
        // need — the block below being freed would push remainingMinutes
        // to 150 (100 + 50) if the restore didn't clamp.
        task.remainingMinutes = 100
        task.isScheduled = false
        let blockStart = calendar.date(byAdding: .hour, value: 9, to: yesterday)!
        let blockEnd = calendar.date(byAdding: .minute, value: 50, to: blockStart)!
        let block = ScheduledBlock(date: yesterday, startTime: blockStart, endTime: blockEnd, task: task)
        context.insert(block)

        let viewModel = ScheduleReviewViewModel(modelContext: context, calendarService: FakeCalendarService(), schedulingService: service, targetDate: testDay)
        await viewModel.clearIncompletePastBlocks(allBlocks: [block], cutoff: testDay)

        XCTAssertEqual(task.remainingMinutes, 120)
    }

    // MARK: - §7.3 — a lock doesn't survive the day it was pinning past

    /// A lock only pins a block within its own day's layout — once that
    /// day is over, `clearIncompletePastBlocks` clears it the same as any
    /// other incomplete past block. Without this, a locked past-incomplete
    /// block would keep matching `reviewableBlocks`' `startTime <
    /// reviewCutoff` filter forever, with no in-app way to resolve it.
    func test_clearIncompletePastBlocks_clearsLockedBlockToo() async throws {
        let testDay = day(2026, 1, 5)
        let yesterday = day(2026, 1, 4)
        let (shelf, rule) = makeShelf(fillStrategy: .maxDuration, maxTotalMinutes: 50)
        let task = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 120, isDivisible: true, minimumSegmentMinutes: 30)
        task.remainingMinutes = 70
        task.isScheduled = true
        let blockStart = calendar.date(byAdding: .hour, value: 9, to: yesterday)!
        let blockEnd = calendar.date(byAdding: .minute, value: 50, to: blockStart)!
        let block = ScheduledBlock(date: yesterday, startTime: blockStart, endTime: blockEnd, task: task)
        block.isLocked = true
        context.insert(block)

        let viewModel = ScheduleReviewViewModel(modelContext: context, calendarService: FakeCalendarService(), schedulingService: service, targetDate: testDay)
        await viewModel.clearIncompletePastBlocks(allBlocks: [block], cutoff: testDay)

        XCTAssertEqual(task.remainingMinutes, 120)
        XCTAssertFalse(task.isScheduled)
    }

    // MARK: - regenerateFromNow's own forward-looking clear also restores remainingMinutes

    /// `regenerateFromNow` clears non-approved/non-locked/non-completed
    /// blocks from `cutoff` (≈ now) forward on its own, separately from
    /// `clearIncompletePastBlocks` — same defect, different call site, so
    /// it needs its own regression test rather than trusting the other
    /// one to cover it. `cutoff` is `max(targetDate, .now)`, so this uses
    /// a day genuinely in the future (not a fixed 2026 date) to land
    /// after real "now" regardless of when the suite runs, and to keep
    /// `clearBlocksBeforeToday` (which only touches days *before* today)
    /// from getting to this block first.
    func test_regenerateFromNow_restoresRemainingMinutesForClearedBlock() async throws {
        let futureDay = calendar.date(byAdding: .day, value: 3, to: calendar.startOfDay(for: .now))!
        // Budget equals the task's full size, so a correct restore places
        // everything in one placement — the buggy behavior (remainingMinutes
        // stuck at 70) also fits in that same budget and also places
        // everything in one placement, so the two are only
        // distinguishable by *how much* actually got placed, not by
        // whether the task ends up fully scheduled.
        let (shelf, rule) = makeShelf(fillStrategy: .maxDuration, maxTotalMinutes: 120)
        let task = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 120, isDivisible: true, minimumSegmentMinutes: 30)
        task.remainingMinutes = 70
        task.isScheduled = true
        let blockStart = calendar.date(byAdding: .hour, value: 9, to: futureDay)!
        let blockEnd = calendar.date(byAdding: .minute, value: 50, to: blockStart)!
        let block = ScheduledBlock(date: futureDay, startTime: blockStart, endTime: blockEnd, task: task, approvalStatus: .proposed)
        context.insert(block)

        let calendarService = FakeCalendarService()
        calendarService.freeSlotsToReturn = [businessHoursSlot(on: futureDay)]
        let viewModel = ScheduleReviewViewModel(modelContext: context, calendarService: calendarService, schedulingService: service, targetDate: futureDay)

        await viewModel.regenerateFromNow(shelves: [shelf], habits: [], eligibleHoursWindows: [])

        let placedMinutes = ((try? context.fetch(FetchDescriptor<ScheduledBlock>())) ?? [])
            .filter { $0.task?.id == task.id }
            .reduce(0) { $0 + $1.durationMinutes }
        // 120, not 70 — proves the cleared block's 50 minutes were given
        // back before the re-walk decided how much room the task had.
        XCTAssertEqual(placedMinutes, 120)
        XCTAssertEqual(task.remainingMinutes, 0)
        XCTAssertTrue(task.isScheduled)
    }

    // MARK: - §12.1-4 — SchedulingRule.fitStatus / canEverFit

    /// §12.1 — divisible @ 60min, maxTaskCount rule capped at 15min/task.
    func test_fitStatus_divisibleChunkExceedsMaxTaskCountCap() {
        let shelf = Shelf(name: "Test Shelf")
        let rule = SchedulingRule(shelf: shelf, fillStrategy: .maxTaskCount, maxMinutesPerTask: 15)
        XCTAssertEqual(rule.fitStatus(estimatedMinutes: 240, isDivisible: true, minimumSegmentMinutes: 60), .exceedsConstraint)
        XCTAssertFalse(rule.canEverFit(estimatedMinutes: 240, isDivisible: true, minimumSegmentMinutes: 60))
    }

    /// §12.2 — same task, maxDuration rule with 120min total: the segment
    /// (60min) fits even though the whole task (240min) wouldn't.
    func test_fitStatus_divisibleChunkFitsMaxDurationBudget() {
        let shelf = Shelf(name: "Test Shelf")
        let rule = SchedulingRule(shelf: shelf, fillStrategy: .maxDuration, maxTotalMinutes: 120)
        XCTAssertEqual(rule.fitStatus(estimatedMinutes: 240, isDivisible: true, minimumSegmentMinutes: 60), .fits)
        XCTAssertTrue(rule.canEverFit(estimatedMinutes: 240, isDivisible: true, minimumSegmentMinutes: 60))
    }

    /// §12.3 — divisible, minimumSegmentMinutes == 0 ("Not Selected").
    func test_fitStatus_divisibleWithNoMinimumSegment_needsMinimumSegment() {
        let shelf = Shelf(name: "Test Shelf")
        let rule = SchedulingRule(shelf: shelf, fillStrategy: .maxDuration, maxTotalMinutes: 120)
        XCTAssertEqual(rule.fitStatus(estimatedMinutes: 240, isDivisible: true, minimumSegmentMinutes: 0), .needsMinimumSegment)
        XCTAssertFalse(rule.canEverFit(estimatedMinutes: 240, isDivisible: true, minimumSegmentMinutes: 0))
    }

    /// §12.4 — estimatedMinutes == 0, even under fillToFit (no cap at all).
    func test_fitStatus_zeroDuration_needsDuration() {
        let shelf = Shelf(name: "Test Shelf")
        let rule = SchedulingRule(shelf: shelf, fillStrategy: .fillToFit)
        XCTAssertEqual(rule.fitStatus(estimatedMinutes: 0, isDivisible: false, minimumSegmentMinutes: 0), .needsDuration)
        XCTAssertFalse(rule.canEverFit(estimatedMinutes: 0, isDivisible: false, minimumSegmentMinutes: 0))
    }

    // MARK: - §12.5-6 — isEffectivelyEligible never writes to includedSchedulingRuleIDs

    /// §12.5 — a task explicitly toggled eligible for a rule it can't fit
    /// keeps that toggle (`isEligible` stays `true`, the ID stays in the
    /// array) even though it isn't effectively eligible right now.
    func test_isEffectivelyEligible_falseWhenTaskEligibleButCannotFit() {
        let (shelf, rule) = makeShelf(fillStrategy: .maxDuration, maxTotalMinutes: 10)
        let task = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 60, isDivisible: false, minimumSegmentMinutes: 0)

        XCTAssertTrue(task.isEligible(for: rule))
        XCTAssertFalse(task.isEffectivelyEligible(for: rule))
        XCTAssertTrue(task.includedSchedulingRuleIDs.contains(rule.id))
    }

    /// §12.6 — loosening the rule afterward flips `isEffectivelyEligible`
    /// back to `true` with no user action. Also the direct regression
    /// guard for `syncEligibilityWithFit`'s removal: asserts the rule ID
    /// is still present in `includedSchedulingRuleIDs` both immediately
    /// after the fit failure *and* after loosening — not just that the
    /// derived Bool flips. If anything ever reintroduces a write-on-fit-
    /// failure (the exact bug `syncEligibilityWithFit` had), this catches
    /// it: the ID would already be gone by the time the rule loosens, and
    /// `isEffectivelyEligible` would stay `false` even though the fit
    /// itself would now pass.
    func test_isEffectivelyEligible_trueAfterLooseningRule_idNeverStripped() {
        let (shelf, rule) = makeShelf(fillStrategy: .maxDuration, maxTotalMinutes: 10)
        let task = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 60, isDivisible: false, minimumSegmentMinutes: 0)

        XCTAssertFalse(task.isEffectivelyEligible(for: rule))
        XCTAssertTrue(task.includedSchedulingRuleIDs.contains(rule.id), "a fit failure must never strip the rule ID")

        rule.maxTotalMinutes = 90 // loosened — no call to setEligible, no user action

        XCTAssertTrue(task.isEffectivelyEligible(for: rule))
        XCTAssertTrue(task.includedSchedulingRuleIDs.contains(rule.id), "still present after loosening — proves nothing was ever destructively written during the failure window")
    }

    // MARK: - §12.10 — Tier-3-removal regression, against isEffectivelyEligible

    /// A task never toggled eligible for the shelf's only rule is never
    /// placed, even with hours of free time and nothing else competing
    /// for it — proves there's no leftover-budget fallback sweeping in an
    /// unmarked task just because a `fillToFit` window has room to spare.
    func test_ineligibleTask_neverPlaced_evenWithRoomToSpare() async throws {
        let testDay = day(2026, 1, 5)
        let (shelf, _) = makeShelf(fillStrategy: .fillToFit)
        let task = TaskItem(title: "Ineligible Task", shelf: shelf, estimatedMinutes: 30)
        // Deliberately never made eligible for the shelf's rule — that's the point.
        context.insert(task)
        shelf.tasks = (shelf.tasks ?? []) + [task]

        let blocks = try await service.generateProposedSchedule(
            shelves: [shelf],
            habits: [],
            freeSlots: [businessHoursSlot(on: testDay)],
            eligibleHoursWindows: [],
            date: testDay,
            existingBlocks: [],
            context: context
        )

        XCTAssertTrue(blocks.isEmpty)
        XCTAssertFalse(task.isScheduled)
    }

    // MARK: - §12.11-14 — ordering (AISchedulingService.taskOrdering)
    //
    // `taskOrdering` is private, so these test it indirectly: a
    // `maxTaskCount` rule capped at exactly 1 places only the single
    // candidate the ordering ranks first, so which task's block shows up
    // in the result is a direct readout of which one won.

    /// §12.11 — negative slack (due soon, not enough of its own remaining
    /// time to spare) beats positive slack even against high priority.
    func test_ordering_negativeSlackBeatsPositiveSlackHighPriority() async throws {
        let testDay = day(2026, 1, 5)
        let (shelf, rule) = makeShelf(fillStrategy: .maxTaskCount, maxTaskCount: 1, maxMinutesPerTask: 120)

        let atRisk = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 60, isDivisible: false, minimumSegmentMinutes: 0)
        atRisk.title = "At Risk"
        atRisk.priority = .low
        // `slack` measures to the *end* of `dueDate`'s own day, not the
        // literal instant (see `TaskItem.endOfDueDate`) — so "due later
        // today" is never enough on its own to go negative; this has to
        // be due on an *earlier* calendar day than the one being packed.
        // Due yesterday, 60 minutes of work still owed today → slack -60.
        atRisk.dueDate = calendar.date(byAdding: .day, value: -1, to: testDay)!

        let comfortable = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 60, isDivisible: false, minimumSegmentMinutes: 0)
        comfortable.title = "Comfortable"
        comfortable.priority = .high
        comfortable.dueDate = calendar.date(byAdding: .day, value: 30, to: testDay)!

        let blocks = try await service.generateProposedSchedule(
            shelves: [shelf], habits: [], freeSlots: [businessHoursSlot(on: testDay)],
            eligibleHoursWindows: [], date: testDay, existingBlocks: [],
            context: context
        )

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.task?.title, "At Risk")
    }

    /// §12.12 — equal slack, differing priority → higher priority first.
    func test_ordering_equalSlack_higherPriorityFirst() async throws {
        let testDay = day(2026, 1, 5)
        let (shelf, rule) = makeShelf(fillStrategy: .maxTaskCount, maxTaskCount: 1, maxMinutesPerTask: 120)
        let dueDate = calendar.date(byAdding: .day, value: 5, to: testDay)!

        let low = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 60, isDivisible: false, minimumSegmentMinutes: 0)
        low.title = "Low"
        low.priority = .low
        low.dueDate = dueDate

        let high = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 60, isDivisible: false, minimumSegmentMinutes: 0)
        high.title = "High"
        high.priority = .high
        high.dueDate = dueDate // same estimatedMinutes + same dueDate → same slack

        let blocks = try await service.generateProposedSchedule(
            shelves: [shelf], habits: [], freeSlots: [businessHoursSlot(on: testDay)],
            eligibleHoursWindows: [], date: testDay, existingBlocks: [],
            context: context
        )

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.task?.title, "High")
    }

    /// §12.13 — equal slack and priority → older `createdAt` first.
    func test_ordering_equalSlackAndPriority_olderCreatedAtFirst() async throws {
        let testDay = day(2026, 1, 5)
        let (shelf, rule) = makeShelf(fillStrategy: .maxTaskCount, maxTaskCount: 1, maxMinutesPerTask: 120)
        let dueDate = calendar.date(byAdding: .day, value: 5, to: testDay)!

        let older = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 60, isDivisible: false, minimumSegmentMinutes: 0)
        older.title = "Older"
        older.priority = .medium
        older.dueDate = dueDate
        older.createdAt = calendar.date(byAdding: .day, value: -10, to: testDay)!

        let newer = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 60, isDivisible: false, minimumSegmentMinutes: 0)
        newer.title = "Newer"
        newer.priority = .medium
        newer.dueDate = dueDate
        newer.createdAt = testDay

        let blocks = try await service.generateProposedSchedule(
            shelves: [shelf], habits: [], freeSlots: [businessHoursSlot(on: testDay)],
            eligibleHoursWindows: [], date: testDay, existingBlocks: [],
            context: context
        )

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.task?.title, "Older")
    }

    /// §12.14a — slack, priority, and `createdAt` all tied → larger
    /// `remainingMinutes` first. Simplest possible tie: no due date on
    /// either task. `slack(asOf:)` returns `nil` for both, and
    /// `taskOrdering`'s switch treats `(nil, nil)` as equal (falls
    /// through to the next tier) — same as any other genuinely-tied
    /// pair, without needing to engineer matching due dates. (A due-date
    /// construction here would also have to fight `slack`'s day-level
    /// granularity — see `TaskItem.endOfDueDate` — since it only sees
    /// which *day* a task is due, not the time, so two tasks can't have
    /// both a differing `remainingMinutes` and a genuinely-equal slack
    /// unless their due dates differ by a whole multiple of 1440
    /// minutes, which forces unrealistically large task sizes. No due
    /// date at all sidesteps that entirely.)
    func test_ordering_allTiersEqual_largerRemainingMinutesFirst() async throws {
        let testDay = day(2026, 1, 5)
        let (shelf, rule) = makeShelf(fillStrategy: .maxTaskCount, maxTaskCount: 1, maxMinutesPerTask: 120)
        let createdAt = testDay

        let small = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 30, isDivisible: false, minimumSegmentMinutes: 0)
        small.title = "Small"
        small.priority = .medium
        small.createdAt = createdAt

        let large = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 90, isDivisible: false, minimumSegmentMinutes: 0)
        large.title = "Large"
        large.priority = .medium
        large.createdAt = createdAt

        XCTAssertNil(small.slack(asOf: testDay, calendar: calendar))
        XCTAssertNil(large.slack(asOf: testDay, calendar: calendar))

        let blocks = try await service.generateProposedSchedule(
            shelves: [shelf], habits: [], freeSlots: [businessHoursSlot(on: testDay)],
            eligibleHoursWindows: [], date: testDay, existingBlocks: [],
            context: context
        )

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.task?.title, "Large")
    }

    /// §12.14b — same size (so slack ties without needing compensating
    /// due dates), same everything else → non-divisible before divisible.
    func test_ordering_allTiersEqual_nonDivisibleBeforeDivisible() async throws {
        let testDay = day(2026, 1, 5)
        let (shelf, rule) = makeShelf(fillStrategy: .maxTaskCount, maxTaskCount: 1, maxMinutesPerTask: 120)
        let dueDate = calendar.date(byAdding: .day, value: 5, to: testDay)!
        let createdAt = testDay

        let divisible = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 60, isDivisible: true, minimumSegmentMinutes: 60)
        divisible.title = "Divisible"
        divisible.priority = .medium
        divisible.dueDate = dueDate
        divisible.createdAt = createdAt

        let nonDivisible = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 60, isDivisible: false, minimumSegmentMinutes: 0)
        nonDivisible.title = "Non-Divisible"
        nonDivisible.priority = .medium
        nonDivisible.dueDate = dueDate
        nonDivisible.createdAt = createdAt

        let blocks = try await service.generateProposedSchedule(
            shelves: [shelf], habits: [], freeSlots: [businessHoursSlot(on: testDay)],
            eligibleHoursWindows: [], date: testDay, existingBlocks: [],
            context: context
        )

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.task?.title, "Non-Divisible")
    }

    // MARK: - slack / isAtRisk boundaries

    func test_slack_noDueDate_isNil() {
        let shelf = Shelf(name: "Test Shelf")
        let task = TaskItem(title: "No Due Date", shelf: shelf, estimatedMinutes: 60)
        XCTAssertNil(task.slack(asOf: .now))
        XCTAssertFalse(task.isAtRisk(asOf: .now))
    }

    /// Exactly zero slack is not negative — the boundary itself must not
    /// read as at risk. Slack measures to the *end* of `dueDate`'s own
    /// day (`TaskItem.endOfDueDate`), so hitting exactly zero requires
    /// `remainingMinutes` to equal the full stretch from `now` to
    /// midnight — 1440 minutes when `now` is itself midnight, as it is
    /// here via `day(...)`.
    func test_isAtRisk_exactlyZeroSlack_notAtRisk() {
        let shelf = Shelf(name: "Test Shelf")
        let task = TaskItem(title: "Zero Slack", shelf: shelf, estimatedMinutes: 1440)
        task.dueDatePicked = true
        let now = day(2026, 1, 5)
        task.dueDate = now // due today — end of day is exactly 1440 minutes away

        XCTAssertEqual(task.slack(asOf: now, calendar: calendar), 0)
        XCTAssertFalse(task.isAtRisk(asOf: now, calendar: calendar))
    }

    /// Correction 1 — a task fully placed (`remainingMinutes == 0`, so
    /// pure slack math reads healthy: `slack` is never even consulted by
    /// the `remainingMinutes > 0` branch) but whose actual block ends
    /// after its own due date is still at risk. This is the common
    /// real-world case — the packer did its job, the result just misses
    /// the deadline — and slack alone can't see it.
    func test_isAtRisk_scheduledPastDeadline_evenWithZeroRemainingMinutes() throws {
        let shelf = Shelf(name: "Test Shelf")
        context.insert(shelf)
        let task = TaskItem(title: "Placed Late", shelf: shelf, estimatedMinutes: 60)
        context.insert(task)
        task.remainingMinutes = 0
        task.isScheduled = true
        task.dueDatePicked = true
        let now = day(2026, 1, 5)
        task.dueDate = now // due today — deadline is midnight starting tomorrow
        // Placed tomorrow, cleanly past the deadline (not just past the
        // literal `dueDate` instant, which same-day math no longer
        // treats as "late" at all — see `TaskItem.endOfDueDate`).
        let blockStart = calendar.date(byAdding: .day, value: 1, to: now)!
        let blockEnd = calendar.date(byAdding: .minute, value: 60, to: blockStart)!
        let block = ScheduledBlock(date: blockStart, startTime: blockStart, endTime: blockEnd, task: task)
        context.insert(block)
        try context.save()

        // Pure slack math alone would call this healthy: `remainingMinutes
        // == 0` means the first branch of `isAtRisk` never even looks at
        // slack's sign — proving this test actually exercises the second
        // (scheduled-past-deadline) branch, not a slack coincidence.
        XCTAssertEqual(task.remainingMinutes, 0)
        XCTAssertTrue(task.isAtRisk(asOf: now, calendar: calendar))
        XCTAssertEqual(task.atRiskBlocker(asOf: now, calendar: calendar), "Scheduled past its due date")
    }

    /// Correction 2 — a task with a real rule toggled on that fails its
    /// own fit check (`.exceedsConstraint`) must name that, not "No
    /// eligible schedule." `makeTask` already calls `setEligible(true,
    /// for: rule)`, so `includedSchedulingRuleIDs` is non-empty here —
    /// this is the exact case the naive `includedSchedulingRuleIDs
    /// .isEmpty` check would have gotten wrong.
    func test_atRiskBlocker_namesFitStatus_notEmptyEligibleArray() {
        let (shelf, rule) = makeShelf(fillStrategy: .maxTaskCount, maxTaskCount: 2, maxMinutesPerTask: 15)
        let task = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 60, isDivisible: false, minimumSegmentMinutes: 0)
        let now = day(2026, 1, 5)
        task.dueDatePicked = true
        // Due yesterday — slack measures to the end of that day, already
        // behind `now`, so 60 minutes of remaining work guarantees
        // negative slack regardless of time-of-day (see `TaskItem
        // .endOfDueDate`; a due time later *today* wouldn't be enough on
        // its own anymore).
        task.dueDate = calendar.date(byAdding: .day, value: -1, to: now)!

        XCTAssertFalse(task.includedSchedulingRuleIDs.isEmpty, "fixture invalid — task must actually be toggled eligible for this to test the right thing")
        XCTAssertTrue(task.isAtRisk(asOf: now, calendar: calendar))
        XCTAssertEqual(task.atRiskBlocker(asOf: now, calendar: calendar), "Exceeds every eligible schedule's time constraint")
    }

    /// `slack(asOf:)` measures from whatever day is passed, not real
    /// `.now` — `taskOrdering` relies on this for a multi-day walk, where
    /// each day's own candidates need to be ordered by how much slack
    /// they have as of *that* day, not by today's headroom reused for
    /// every later day. Uses a fixed due date and checks slack shrinks
    /// correctly as the `asOf` day advances toward it.
    func test_slack_measuresFromPackingDay_notNow() {
        let shelf = Shelf(name: "Test Shelf")
        let task = TaskItem(title: "Multi-Day", shelf: shelf, estimatedMinutes: 60)
        task.dueDate = day(2026, 1, 10)

        let earlyDay = day(2026, 1, 5) // 5 days before the deadline
        let laterDay = day(2026, 1, 8) // 2 days before the deadline

        let earlySlack = task.slack(asOf: earlyDay, calendar: calendar)
        let laterSlack = task.slack(asOf: laterDay, calendar: calendar)

        XCTAssertNotNil(earlySlack)
        XCTAssertNotNil(laterSlack)
        // 5 days of headroom vs. 2 — slack as of the earlier day must be
        // the larger number, proving the calculation actually moved with
        // the day passed in rather than being pinned to a single value.
        XCTAssertGreaterThan(earlySlack!, laterSlack!)
        XCTAssertEqual(earlySlack! - laterSlack!, 3 * 24 * 60, "the 3-day gap between the two `asOf` days should show up minute-for-minute in the slack difference")
    }

    // MARK: - Review follow-up: dueDate's time-of-day must not drive risk

    /// A task due today at 9am must not read as at risk (or past due) at
    /// 5pm the same day — `dueDate`'s time-of-day is never something the
    /// user actually chose as a deadline (it auto-fills to `.now`, and
    /// even a real pick usually comes from a date-only picker leaving
    /// that same incidental time attached underneath — see `TaskItem
    /// .endOfDueDate`), so "due today" has to mean the whole day, not
    /// whatever minute the field happened to get its value.
    func test_isAtRisk_dueTodayAt9am_notAtRiskAt5pm() {
        let shelf = Shelf(name: "Test Shelf")
        let task = TaskItem(title: "Due Today", shelf: shelf, estimatedMinutes: 120)
        let testDay = day(2026, 1, 5)
        task.dueDatePicked = true
        task.dueDate = calendar.date(byAdding: .hour, value: 9, to: testDay)!
        let fivePM = calendar.date(byAdding: .hour, value: 17, to: testDay)!

        // Sanity check: the literal due *instant* really has passed by
        // 5pm — proving a healthy result here comes from the end-of-day
        // fix, not from the due time coincidentally still being ahead.
        XCTAssertLessThan(task.dueDate!, fivePM)

        XCTAssertFalse(task.isAtRisk(asOf: fivePM, calendar: calendar))
        XCTAssertNil(task.atRiskBlocker(asOf: fivePM, calendar: calendar))
    }

    /// `dueDate` auto-fills to `.now` the instant "Has due date" flips
    /// to Yes, purely so the picker has something to show — before
    /// `dueDatePicked` is `true`, that value is a placeholder nobody
    /// actually chose, not a real deadline. `isAtRisk` must never flag
    /// (or `taskOrdering`-adjacent code prioritize) a task off of it.
    func test_isAtRisk_dueDatePickedFalse_autoFilledDateNeverAtRisk() {
        let shelf = Shelf(name: "Test Shelf")
        let task = TaskItem(title: "Auto-Filled Date", shelf: shelf, estimatedMinutes: 120)
        let now = calendar.date(byAdding: .hour, value: 23, to: day(2026, 1, 5))! // 11pm
        task.dueDate = now // simulates the auto-fill-to-.now behavior
        task.dueDatePicked = false // never actually confirmed

        // Sanity check: without the `dueDatePicked` gate, this would
        // already read as at risk — only 1 hour left before midnight,
        // 2 hours of work still owed — proving the gate is doing real
        // work here, not coincidentally agreeing with an already-healthy
        // fixture.
        XCTAssertLessThan(task.slack(asOf: now, calendar: calendar) ?? 0, 0)

        XCTAssertFalse(task.isAtRisk(asOf: now, calendar: calendar))
        XCTAssertNil(task.atRiskBlocker(asOf: now, calendar: calendar))
    }

    // MARK: - §6.4 — stall detection replaces the flat 365-day task-walk cap

    /// `hasRemainingSchedulableWork` only checks `isEligible` + `canEverFit`
    /// — it doesn't know about a rule's own day-of-week restriction. A
    /// rule on a `NamedSchedule` whose `daysOfWeek` matches nothing
    /// (misconfigured, or every day manually unchecked) is exactly the
    /// mismatch that made the old flat 365-day cap expensive: the task
    /// stays "remaining" forever, but the packer's own per-rule loop
    /// (`effectiveDaysOfWeek.contains(weekday)`) skips this rule on
    /// every single day, so nothing is ever actually placed. Stall
    /// detection has to be what stops this, not the day-of-week check
    /// itself (which has no way to know "no day will ever match" ahead
    /// of time without literally trying every day).
    func test_autoPlaceEligibleTasks_stallDetection_stopsAtThreshold_notOldFixedCap() async throws {
        let shelf = Shelf(name: "Test Shelf")
        context.insert(shelf)
        let schedule = NamedSchedule(name: "Never", daysOfWeek: [], startHour: 0, startMinute: 0, endHour: 23, endMinute: 59)
        context.insert(schedule)
        let rule = SchedulingRule(shelf: shelf, fillStrategy: .fillToFit)
        rule.namedSchedule = schedule
        context.insert(rule)
        shelf.schedulingRules = [rule]

        let task = TaskItem(title: "Stuck Task", shelf: shelf, estimatedMinutes: 30)
        task.setEligible(true, for: rule)
        context.insert(task)
        shelf.tasks = [task]

        // Genuinely in the future relative to the real wall clock, not a
        // fixed 2026 date — `autoPlaceEligibleTasks` early-returns for
        // any day in the past (`targetDate >= startOfDay(for: .now)`),
        // which would make this test pass for the wrong reason (zero
        // calls at all) once 2026 itself becomes the past.
        let testDay = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 3, to: .now)!)
        let calendarService = FakeCalendarService()
        calendarService.freeSlotsToReturn = [businessHoursSlot(on: testDay)]
        let viewModel = ScheduleReviewViewModel(modelContext: context, calendarService: calendarService, schedulingService: service, targetDate: testDay)

        await viewModel.autoPlaceEligibleTasks(shelves: [shelf], habits: [], eligibleHoursWindows: [])

        // 14 == the production `taskStallThresholdDays` (private to
        // ScheduleReviewViewModel, so asserted here as a literal) — the
        // walk visiting exactly this many days, not 365 and not
        // unboundedly many, is the actual thing this test is proving.
        //
        // Read off `lastWalkDayCount` rather than the fake's call count:
        // batching means the walk issues one ranged call covering a fixed
        // 44-day window regardless of where it stops, so a call count can
        // no longer tell a 14-day walk apart from a 30-day one. Asserting
        // the requested *span* wouldn't work either — that's always 44.
        XCTAssertEqual(viewModel.lastWalkDayCount, 14)
        XCTAssertFalse(task.isScheduled)
        XCTAssertEqual(task.remainingMinutes, 30)

        // And the batching itself: one ranged call, and no per-day
        // fallback, since 14 days is comfortably inside the 44-day
        // pre-fetch window.
        XCTAssertEqual(calendarService.fetchFreeSlotsRangedCallCount, 1)
        XCTAssertEqual(calendarService.fetchFreeSlotsCallCount, 0)
        // 44 == freeSlotPrefetchDays (habitPopulationDays 30 +
        // taskStallThresholdDays 14), both private — asserted as a
        // literal for the same reason as the 14 above.
        let requested = try XCTUnwrap(calendarService.lastRangedRequest)
        XCTAssertEqual(calendarDays(from: requested.start, to: requested.end, calendar: calendar).count, 44)
    }

    /// The fallback path that keeps the pre-fetch horizon from silently
    /// becoming a cap. A task backlog that places something every 13 days
    /// never trips the 14-day stall counter, so the walk legitimately runs
    /// past the 44-day pre-fetched window.
    ///
    /// **Rewritten.** This test used to assert the walk ran past day 44
    /// and fell back to per-day calls. Adding `maxWalkDays` (= the same 44)
    /// makes that scenario impossible by construction: the walk can no
    /// longer leave the pre-fetched window, so the fallback branch inside
    /// these two walks is now unreachable. That's a deliberate consequence
    /// of the walk-termination fix, not a regression — but it means the
    /// invariant worth protecting has changed. What this now asserts is
    /// that the cap and the pre-fetch horizon stay tied together: a walk
    /// that would once have overshot instead stops exactly at the window
    /// edge and never needs a single fallback call. If someone later
    /// raises `maxWalkDays` above `freeSlotPrefetchDays`, this fails.
    ///
    /// The fallback code itself stays — `fetchFreeSlots(for:)` has other
    /// callers (`AISchedulingService.generateProposedSchedule`), and a
    /// failed pre-fetch still routes every day through it.
    func test_autoPlaceEligibleTasks_neverWalksPastPrefetchWindow() async throws {
        let shelf = Shelf(name: "Test Shelf")
        context.insert(shelf)
        // Only Mondays, so placement happens once every 7 days — enough
        // to keep resetting the stall counter (7 < 14) so the walk never
        // stalls, and it only stops once the backlog genuinely runs out.
        let schedule = NamedSchedule(name: "Mondays", daysOfWeek: [2], startHour: 0, startMinute: 0, endHour: 23, endMinute: 59)
        context.insert(schedule)
        let rule = SchedulingRule(shelf: shelf, fillStrategy: .maxTaskCount, maxTaskCount: 1, maxMinutesPerTask: 60)
        rule.namedSchedule = schedule
        context.insert(rule)
        shelf.schedulingRules = [rule]

        // 10 tasks, one placeable per Monday → ~70 days of walking, well
        // past the 44-day pre-fetch window.
        var tasks: [TaskItem] = []
        for index in 0..<10 {
            let task = TaskItem(title: "Task \(index)", shelf: shelf, estimatedMinutes: 60)
            task.setEligible(true, for: rule)
            context.insert(task)
            tasks.append(task)
        }
        shelf.tasks = tasks

        let testDay = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 3, to: .now)!)
        let calendarService = FakeCalendarService()
        // Per-day slots, not a fixed array: this walk needs real
        // placements on days far past `testDay`, and slots anchored to
        // the wrong date get discarded by the packer.
        calendarService.freeSlotsProvider = { [self.businessHoursSlot(on: $0)] }
        let viewModel = ScheduleReviewViewModel(modelContext: context, calendarService: calendarService, schedulingService: service, targetDate: testDay)

        await viewModel.autoPlaceEligibleTasks(shelves: [shelf], habits: [], eligibleHoursWindows: [])

        // This fixture would run ~70 days without a cap (10 tasks, one
        // placeable per Monday), so hitting exactly 44 is the cap binding,
        // not the backlog running out.
        XCTAssertEqual(viewModel.lastWalkDayCount, 44, "the walk must stop at maxWalkDays rather than continuing past the pre-fetched window")
        XCTAssertEqual(calendarService.fetchFreeSlotsRangedCallCount, 1, "one pre-fetch, never a second batch")
        XCTAssertEqual(calendarService.fetchFreeSlotsCallCount, 0, "with the cap tied to the pre-fetch horizon, no day should ever need the per-day fallback")

        // The backlog didn't fit in the horizon, so the leftovers must be
        // reported rather than chased to whatever distant day they'd fit.
        XCTAssertFalse(viewModel.tasksThatDidNotFit.isEmpty, "tasks left unplaced when the cap binds must be surfaced")
    }

    // MARK: - Double-booking: serialized walks + overlap invariant

    /// The regression test for the confirmed case-1 mechanism: two walks
    /// started while the first was still running, both read the same
    /// empty slot, and both placed into it. Serialization makes the
    /// second wait for the first, so it sees the first's block.
    func test_concurrentWalks_doNotDoubleBookTheSameSlot() async throws {
        let testDay = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 3, to: .now)!)
        let (shelf, rule) = makeShelf(fillStrategy: .fillToFit)
        _ = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 60, isDivisible: false, minimumSegmentMinutes: 0)

        let calendarService = FakeCalendarService()
        calendarService.freeSlotsProvider = { [self.businessHoursSlot(on: $0)] }
        let viewModel = ScheduleReviewViewModel(modelContext: context, calendarService: calendarService, schedulingService: service, targetDate: testDay)

        // Fired without awaiting between them — the shape that produced
        // the captured collision.
        async let first: Void = viewModel.autoPlaceEligibleTasks(shelves: [shelf], habits: [], eligibleHoursWindows: [])
        async let second: Void = viewModel.autoPlaceEligibleTasks(shelves: [shelf], habits: [], eligibleHoursWindows: [])
        _ = await (first, second)

        let taskBlocks = ((try? context.fetch(FetchDescriptor<ScheduledBlock>())) ?? [])
            .filter { $0.task != nil && !($0.task?.isRecurring ?? false) }
        for (i, a) in taskBlocks.enumerated() {
            for b in taskBlocks[(i + 1)...] {
                XCTAssertFalse(
                    a.startTime < b.endTime && b.startTime < a.endTime,
                    "two scheduler-placed task blocks overlap: \(a.startTime)–\(a.endTime) and \(b.startTime)–\(b.endTime)"
                )
            }
        }
    }

    /// The invariant itself, independent of concurrency: a scheduler walk
    /// must not place a task block over an existing one even when the
    /// conflicting block was already sitting in the store.
    func test_overlapInvariant_rejectsSchedulerBlockOverExistingTaskBlock() async throws {
        let testDay = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 3, to: .now)!)
        let (shelf, rule) = makeShelf(fillStrategy: .fillToFit)
        let newcomer = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 60, isDivisible: false, minimumSegmentMinutes: 0)

        // An unrelated task already occupies the whole business day, but
        // isn't itself a candidate (already scheduled).
        let occupant = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 480, isDivisible: false, minimumSegmentMinutes: 0)
        occupant.isScheduled = true
        occupant.remainingMinutes = 0
        let slot = businessHoursSlot(on: testDay)
        let occupying = ScheduledBlock(date: testDay, startTime: slot.start, endTime: slot.end, task: occupant)
        context.insert(occupying)
        occupant.scheduledBlocks = [occupying]

        let calendarService = FakeCalendarService()
        // The fake reports the day fully free, so only the invariant can
        // stop the newcomer landing on top of the occupant.
        calendarService.freeSlotsProvider = { [self.businessHoursSlot(on: $0)] }
        let viewModel = ScheduleReviewViewModel(modelContext: context, calendarService: calendarService, schedulingService: service, targetDate: testDay)

        await viewModel.autoPlaceEligibleTasks(shelves: [shelf], habits: [], eligibleHoursWindows: [])

        let newcomerBlocks = (newcomer.scheduledBlocks ?? []).filter { !$0.isCompleted }
        for block in newcomerBlocks {
            XCTAssertFalse(
                block.startTime < occupying.endTime && occupying.startTime < block.endTime,
                "the invariant must refuse a scheduler placement that overlaps an existing task block"
            )
        }
    }

    /// Habits are allowed to double-book by design — the invariant must
    /// not quietly change that.
    func test_overlapInvariant_stillAllowsHabitBlockOverTaskBlock() throws {
        let testDay = day(2026, 1, 5)
        let (shelf, rule) = makeShelf(fillStrategy: .fillToFit)
        let task = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 60, isDivisible: false, minimumSegmentMinutes: 0)
        let start = calendar.date(byAdding: .hour, value: 9, to: testDay)!
        let taskBlock = ScheduledBlock(date: testDay, startTime: start, endTime: calendar.date(byAdding: .minute, value: 60, to: start)!, task: task)
        context.insert(taskBlock)

        let habit = Habit(name: "Stretch")
        context.insert(habit)
        let habitBlock = ScheduledBlock(date: testDay, startTime: start, endTime: calendar.date(byAdding: .minute, value: 30, to: start)!, task: nil, habit: habit)
        context.insert(habitBlock)

        // Nothing in the invariant applies to a habit block: it has no
        // task, so it's exempt by construction.
        XCTAssertNil(habitBlock.task)
        XCTAssertNotNil(habitBlock.habit)
        XCTAssertTrue(
            habitBlock.startTime < taskBlock.endTime && taskBlock.startTime < habitBlock.endTime,
            "fixture invalid — the habit block must actually overlap the task block"
        )
    }

    /// A recurring task's fixed-anchor block may still overlap a
    /// rule-packed one. Whether it *should* is a real open question, but
    /// changing it here would be a silent behavior change.
    func test_overlapInvariant_stillAllowsRecurringBlockOverTaskBlock() async throws {
        let testDay = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 3, to: .now)!)
        let (shelf, rule) = makeShelf(fillStrategy: .fillToFit)
        let ordinary = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 60, isDivisible: false, minimumSegmentMinutes: 0)

        let recurring = TaskItem(title: "Daily", shelf: shelf, estimatedMinutes: 30)
        recurring.isRecurring = true
        recurring.recurrenceIntervalCount = 1
        recurring.recurrenceUnit = .days
        // Anchored at 9am, the same hour the packer will start from.
        recurring.dueDate = calendar.date(byAdding: .hour, value: 9, to: testDay)!
        recurring.setEligible(true, for: rule)
        context.insert(recurring)
        shelf.tasks = [ordinary, recurring]

        let calendarService = FakeCalendarService()
        calendarService.freeSlotsProvider = { [self.businessHoursSlot(on: $0)] }
        let viewModel = ScheduleReviewViewModel(modelContext: context, calendarService: calendarService, schedulingService: service, targetDate: testDay)

        await viewModel.autoPlaceEligibleTasks(shelves: [shelf], habits: [], eligibleHoursWindows: [])

        let recurringBlocks = ((try? context.fetch(FetchDescriptor<ScheduledBlock>())) ?? [])
            .filter { $0.task?.isRecurring == true }
        XCTAssertFalse(recurringBlocks.isEmpty, "the recurring task must still be placed — the invariant exempts it")
    }

    // MARK: - Migration: repairing remainingMinutes drained by the leak

    /// No blocks at all — the whole estimate is owed. This is the shape of
    /// the four tasks found drained in the real device store.
    func test_repairedRemainingMinutes_noBlocks_resetsToEstimate() {
        let shelf = Shelf(name: "S")
        let task = TaskItem(title: "Drained", shelf: shelf, estimatedMinutes: 120)
        task.remainingMinutes = 0
        XCTAssertEqual(task.repairedRemainingMinutes(), 120)
    }

    /// Partial blocks — only the unplaced remainder is owed. Nothing in
    /// the store matches this today, but divisible tasks reach it
    /// routinely now that the packer places whole segments.
    func test_repairedRemainingMinutes_partialBlocks_returnsEstimateMinusPlaced() throws {
        let testDay = day(2026, 1, 5)
        let shelf = Shelf(name: "S")
        context.insert(shelf)
        let task = TaskItem(title: "Half placed", shelf: shelf, estimatedMinutes: 240, isDivisible: true, minimumSegmentMinutes: 60)
        task.remainingMinutes = 0 // drained by the leak
        context.insert(task)

        // Two 60-minute segments placed = 120 of 240.
        var blocks: [ScheduledBlock] = []
        for hour in [9, 14] {
            let start = calendar.date(byAdding: .hour, value: hour, to: testDay)!
            let block = ScheduledBlock(date: testDay, startTime: start, endTime: calendar.date(byAdding: .minute, value: 60, to: start)!, task: task)
            context.insert(block)
            blocks.append(block)
        }
        task.scheduledBlocks = blocks

        XCTAssertEqual(task.placedMinutes, 120)
        XCTAssertEqual(task.repairedRemainingMinutes(), 120, "only the time not yet on the calendar is owed back")
    }

    /// Blocks already cover the estimate — leave it completely alone.
    /// This is "Investigate Sub Item IDs": resetting it would re-offer 120
    /// minutes already sitting on the calendar.
    func test_repairedRemainingMinutes_fullyPlaced_returnsNil() throws {
        let testDay = day(2026, 1, 5)
        let shelf = Shelf(name: "S")
        context.insert(shelf)
        let task = TaskItem(title: "Fully placed", shelf: shelf, estimatedMinutes: 120)
        task.remainingMinutes = 0
        task.isScheduled = true
        context.insert(task)
        let start = calendar.date(byAdding: .hour, value: 9, to: testDay)!
        let block = ScheduledBlock(date: testDay, startTime: start, endTime: calendar.date(byAdding: .minute, value: 120, to: start)!, task: task)
        context.insert(block)
        task.scheduledBlocks = [block]

        XCTAssertNil(task.repairedRemainingMinutes(), "a correctly fully-scheduled task must never be touched")
    }

    /// A completed block's time was genuinely spent, so it doesn't count
    /// as "placed" and doesn't protect the task from repair either.
    func test_repairedRemainingMinutes_completedBlocksDoNotCountAsPlaced() throws {
        let testDay = day(2026, 1, 5)
        let shelf = Shelf(name: "S")
        context.insert(shelf)
        let task = TaskItem(title: "Had a completed block", shelf: shelf, estimatedMinutes: 120)
        task.remainingMinutes = 0
        context.insert(task)
        let start = calendar.date(byAdding: .hour, value: 9, to: testDay)!
        let block = ScheduledBlock(date: testDay, startTime: start, endTime: calendar.date(byAdding: .minute, value: 120, to: start)!, task: task)
        block.isCompleted = true
        context.insert(block)
        task.scheduledBlocks = [block]

        XCTAssertEqual(task.placedMinutes, 0, "completed time is spent, not reserved")
    }

    func test_repairedRemainingMinutes_skipsCompletedRecurringAndDurationlessTasks() {
        let shelf = Shelf(name: "S")

        let completed = TaskItem(title: "Done", shelf: shelf, estimatedMinutes: 120)
        completed.remainingMinutes = 0
        completed.isCompleted = true
        XCTAssertNil(completed.repairedRemainingMinutes())

        let recurring = TaskItem(title: "Recurring", shelf: shelf, estimatedMinutes: 30)
        recurring.isRecurring = true
        recurring.remainingMinutes = 0
        XCTAssertNil(recurring.repairedRemainingMinutes(), "recurring tasks never drain remainingMinutes, so there's nothing to repair")

        let noDuration = TaskItem(title: "No duration", shelf: shelf, estimatedMinutes: 0)
        XCTAssertNil(noDuration.repairedRemainingMinutes())
    }

    /// Already-correct values are left alone, so the migration is a no-op
    /// on a healthy store and safe to re-run.
    func test_repairedRemainingMinutes_alreadyCorrect_returnsNil() {
        let shelf = Shelf(name: "S")
        let task = TaskItem(title: "Healthy", shelf: shelf, estimatedMinutes: 120)
        XCTAssertEqual(task.remainingMinutes, 120)
        XCTAssertNil(task.repairedRemainingMinutes())
    }

    // MARK: - Monthly recurrence on a day short months don't have

    /// A task recurring monthly with `dueDate` anchored to the 31st lands
    /// on the last real day of any month too short to have one, without
    /// permanently drifting off day 31 once a long-enough month comes
    /// back around — Jan 31 -> Feb 28 -> Mar 31 -> Apr 30 -> May 31, all
    /// twelve months walked directly against `hasRecurringOccurrence`,
    /// the same production code path `AISchedulingService
    /// .placeHabitsAndRecurringTasks` calls per day.
    func test_hasRecurringOccurrence_monthlyOn31st_landsOnLastDayOfShortMonths() {
        let shelf = Shelf(name: "S")
        let task = TaskItem(title: "Monthly", shelf: shelf)
        task.isRecurring = true
        task.recurrenceIntervalCount = 1
        task.recurrenceUnit = .months
        task.dueDate = day(2026, 1, 31)

        let expectedFireDays: [Int: Int] = [
            1: 31, 2: 28, 3: 31, 4: 30, 5: 31, 6: 30,
            7: 31, 8: 31, 9: 30, 10: 31, 11: 30, 12: 31
        ]
        for month in 1...12 {
            let daysInMonth = calendar.range(of: .day, in: .month, for: day(2026, month, 1))!.count
            let firingDays = (1...daysInMonth).filter { task.hasRecurringOccurrence(on: day(2026, month, $0), calendar: calendar) }
            XCTAssertEqual(firingDays, [expectedFireDays[month]!], "month \(month) (has \(daysInMonth) days)")
        }
    }

    /// Same shape, but every 2 months — confirms the short-month clamp
    /// doesn't throw off the interval itself (a naive day-count-based
    /// implementation could plausibly fire an extra time recovering from
    /// February's clamp).
    func test_hasRecurringOccurrence_monthlyOn31stEveryTwoMonths_skipsAlternateMonths() {
        let shelf = Shelf(name: "S")
        let task = TaskItem(title: "Bimonthly", shelf: shelf)
        task.isRecurring = true
        task.recurrenceIntervalCount = 2
        task.recurrenceUnit = .months
        task.dueDate = day(2026, 1, 31)

        let expectedFireDays: [Int: Int?] = [
            1: 31, 2: nil, 3: 31, 4: nil, 5: 31, 6: nil,
            7: 31, 8: nil, 9: 30, 10: nil, 11: 30, 12: nil
        ]
        for month in 1...12 {
            let daysInMonth = calendar.range(of: .day, in: .month, for: day(2026, month, 1))!.count
            let firingDays = (1...daysInMonth).filter { task.hasRecurringOccurrence(on: day(2026, month, $0), calendar: calendar) }
            let expected = expectedFireDays[month]!.map { [$0] } ?? []
            XCTAssertEqual(firingDays, expected, "month \(month) (has \(daysInMonth) days)")
        }
    }

    // MARK: - TaskItem.recurrenceTimeMode

    func test_recurrenceTimeMode_defaultsToSpecific() {
        let shelf = Shelf(name: "S")
        let task = TaskItem(title: "T", shelf: shelf)
        XCTAssertEqual(task.recurrenceTimeMode, .specific, "an existing recurring task with no raw value set yet must keep behaving exactly as before this field existed")
    }

    func test_recurrenceTimeMode_getSetRoundTrips() {
        let shelf = Shelf(name: "S")
        let task = TaskItem(title: "T", shelf: shelf)
        for mode in HabitOccurrenceTimeMode.allCases {
            task.recurrenceTimeMode = mode
            XCTAssertEqual(task.recurrenceTimeMode, mode)
        }
    }

    // MARK: - remainingMinutes must survive every block deletion

    /// Builds a task fully placed into one block, i.e. the state
    /// `pack()` leaves behind: remainingMinutes drained to 0,
    /// isScheduled true, one block accounting for the whole estimate.
    private func makePlacedTask(minutes: Int = 120) -> (shelf: Shelf, rule: SchedulingRule, task: TaskItem, block: ScheduledBlock, day: Date) {
        let testDay = day(2026, 1, 5)
        let (shelf, rule) = makeShelf(fillStrategy: .fillToFit)
        let task = makeTask(shelf: shelf, rule: rule, estimatedMinutes: minutes, isDivisible: false, minimumSegmentMinutes: 0)
        task.remainingMinutes = 0
        task.isScheduled = true
        let start = calendar.date(byAdding: .hour, value: 9, to: testDay)!
        let block = ScheduledBlock(date: testDay, startTime: start, endTime: calendar.date(byAdding: .minute, value: minutes, to: start)!, task: task)
        context.insert(block)
        task.scheduledBlocks = [block]
        return (shelf, rule, task, block, testDay)
    }

    /// `deleteBlock` is the user's swipe. It means "not here, not now" —
    /// the deferral it records via `pushedCount` — not "this work is
    /// done," which is what completing the block means. Before the fix it
    /// destroyed the task's remaining time outright, which is how a
    /// routine swipe turned into a permanently unschedulable task.
    func test_deleteBlock_restoresRemainingMinutes() async throws {
        let fixture = makePlacedTask()
        let viewModel = ScheduleReviewViewModel(modelContext: context, calendarService: FakeCalendarService(), schedulingService: service, targetDate: fixture.day)

        viewModel.deleteBlock(fixture.block)

        XCTAssertEqual(fixture.task.remainingMinutes, 120, "a swipe defers the work; it must not destroy it")
        XCTAssertFalse(fixture.task.isScheduled)
        XCTAssertEqual(fixture.task.pushedCount, 1, "still recorded as a deferral")
    }

    /// `manualReplace` frees whatever block the incoming task already held
    /// elsewhere. That task is moving, not abandoning the work.
    func test_manualReplace_restoresRemainingMinutesOnTheFreedBlock() async throws {
        let testDay = day(2026, 1, 5)
        let (shelf, rule) = makeShelf(fillStrategy: .fillToFit)

        let outgoing = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 60, isDivisible: false, minimumSegmentMinutes: 0)
        let targetStart = calendar.date(byAdding: .hour, value: 14, to: testDay)!
        let targetBlock = ScheduledBlock(date: testDay, startTime: targetStart, endTime: calendar.date(byAdding: .minute, value: 60, to: targetStart)!, task: outgoing)
        context.insert(targetBlock)

        // The incoming task already holds its own block elsewhere.
        let incoming = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 120, isDivisible: false, minimumSegmentMinutes: 0)
        incoming.remainingMinutes = 0
        incoming.isScheduled = true
        let oldStart = calendar.date(byAdding: .hour, value: 9, to: testDay)!
        let oldBlock = ScheduledBlock(date: testDay, startTime: oldStart, endTime: calendar.date(byAdding: .minute, value: 120, to: oldStart)!, task: incoming)
        context.insert(oldBlock)
        incoming.scheduledBlocks = [oldBlock]

        let viewModel = ScheduleReviewViewModel(modelContext: context, calendarService: FakeCalendarService(), schedulingService: service, targetDate: testDay)
        viewModel.manualReplace(targetBlock, with: incoming)

        XCTAssertEqual(incoming.remainingMinutes, 120, "the freed block's minutes must come back — the task moved, it didn't finish")
    }

    /// The highest-frequency leak: `trimOverflowingRuleBlocksAcrossFutureDays`
    /// runs at the top of every `autoPlaceEligibleTasks`, so on essentially
    /// every Calendar appear. It sweeps blocks whose task is no longer
    /// eligible for the rule that placed them.
    func test_trimSweepOfIneligibleBlock_restoresRemainingMinutes() async throws {
        let fixture = makePlacedTask()
        // Make it ineligible for the rule that placed it, so the trim
        // sweep picks the block up.
        fixture.task.setEligible(false, for: fixture.rule)

        let futureDay = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 3, to: .now)!)
        let start = calendar.date(byAdding: .hour, value: 9, to: futureDay)!
        fixture.block.date = futureDay
        fixture.block.startTime = start
        fixture.block.endTime = calendar.date(byAdding: .minute, value: 120, to: start)!

        let calendarService = FakeCalendarService()
        calendarService.freeSlotsProvider = { [self.businessHoursSlot(on: $0)] }
        let viewModel = ScheduleReviewViewModel(modelContext: context, calendarService: calendarService, schedulingService: service, targetDate: futureDay)

        await viewModel.autoPlaceEligibleTasks(shelves: [fixture.shelf], habits: [], eligibleHoursWindows: [])

        XCTAssertEqual(fixture.task.remainingMinutes, 120, "the trim sweep must give back the time it reclaims — this is the leak that ran on every Calendar appear")
    }

    /// `trimOverflowingRuleBlocksAcrossFutureDays` loaded its pre-trim
    /// `allBlocksNow` snapshot back into `blocks` after deleting the excess
    /// groups — reinserting the very objects `removeBlock` had just nil'd
    /// out and deleted. `ScheduledBlock.displayTitle` falls back to "Open
    /// slot" for a block with no task and no habit, so a trimmed block
    /// resurrected this way rendered as a phantom "Open slot" row.
    func test_trimSweepOfOverflowingRuleBlocks_doesNotResurrectDeletedBlocksAsOpenSlots() async throws {
        let (shelf, rule) = makeShelf(fillStrategy: .maxTaskCount, maxTaskCount: 1, maxMinutesPerTask: 120)

        let futureDay = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 3, to: .now)!)

        let first = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 60, isDivisible: false, minimumSegmentMinutes: 0)
        first.remainingMinutes = 0
        first.isScheduled = true
        let firstStart = calendar.date(byAdding: .hour, value: 9, to: futureDay)!
        let firstBlock = ScheduledBlock(date: futureDay, startTime: firstStart, endTime: calendar.date(byAdding: .minute, value: 60, to: firstStart)!, task: first)
        context.insert(firstBlock)
        first.scheduledBlocks = [firstBlock]

        // Starts later than `first`, so it's the one the count-cap trim
        // pops off (`groups` sorted ascending by `earliestStart`, excess
        // popped from the end).
        let second = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 60, isDivisible: false, minimumSegmentMinutes: 0)
        second.remainingMinutes = 0
        second.isScheduled = true
        let secondStart = calendar.date(byAdding: .hour, value: 12, to: futureDay)!
        let secondBlock = ScheduledBlock(date: futureDay, startTime: secondStart, endTime: calendar.date(byAdding: .minute, value: 60, to: secondStart)!, task: second)
        context.insert(secondBlock)
        second.scheduledBlocks = [secondBlock]

        let calendarService = FakeCalendarService()
        calendarService.freeSlotsProvider = { [self.businessHoursSlot(on: $0)] }
        let viewModel = ScheduleReviewViewModel(modelContext: context, calendarService: calendarService, schedulingService: service, targetDate: futureDay)

        await viewModel.autoPlaceEligibleTasks(shelves: [shelf], habits: [], eligibleHoursWindows: [])

        XCTAssertFalse(
            viewModel.blocks.contains { $0.task == nil && $0.habit == nil },
            "a block the trim sweep just deleted must not come back as a task-less, habit-less \"Open slot\""
        )
    }

    /// The counterpart guard: a *completed* block's time was genuinely
    /// spent, so removal must NOT hand it back.
    func test_completedBlockRemoval_doesNotRestore() async throws {
        let fixture = makePlacedTask()
        fixture.block.isCompleted = true

        let viewModel = ScheduleReviewViewModel(modelContext: context, calendarService: FakeCalendarService(), schedulingService: service, targetDate: fixture.day)
        await viewModel.purgeCompletedBlocks()

        XCTAssertEqual(fixture.task.remainingMinutes, 0, "completed work must stay spent — restoring it would resurrect finished time")
    }

    /// `MealSelection` has no delete/expiry logic anywhere else in the
    /// app — `NightlyReviewView.todayMealSelections`'s own
    /// `$0.isCompleted` clause has no date bound, so a completed meal
    /// would match that filter forever unless something actually deletes
    /// the record. `purgeCompletedMealSelections` is that something,
    /// called alongside `purgeCompletedBlocks` at the same commit point.
    func test_purgeCompletedMealSelections_deletesCompletedKeepsIncomplete() async throws {
        let completed = MealSelection(recipeID: UUID(), recipeTitle: "Tacos", date: day(2026, 1, 1))
        completed.isCompleted = true
        context.insert(completed)
        let incomplete = MealSelection(recipeID: UUID(), recipeTitle: "Soup", date: day(2026, 1, 2))
        context.insert(incomplete)

        let viewModel = ScheduleReviewViewModel(modelContext: context, calendarService: FakeCalendarService(), schedulingService: service, targetDate: day(2026, 1, 2))
        viewModel.purgeCompletedMealSelections()

        let remaining = (try? context.fetch(FetchDescriptor<MealSelection>())) ?? []
        XCTAssertFalse(remaining.contains { $0.id == completed.id }, "a completed meal selection must not survive the purge — nothing else ever deletes it")
        XCTAssertTrue(remaining.contains { $0.id == incomplete.id }, "an incomplete meal selection is still-open backlog and must not be swept")
    }

    /// `ScheduledBlock.mealSelection` has no explicit delete rule, so
    /// SwiftData defaults to `.nullify` — deleting only the `MealSelection`
    /// would leave its block behind with `mealSelection` set to nil, which
    /// then passes `reviewableBlocks`'s own `mealSelection == nil` filter
    /// and reappears as a phantom "Open slot" row on the same day/time the
    /// purged dinner occupied. The purge must remove the block too.
    func test_purgeCompletedMealSelections_alsoDeletesAssociatedBlock() async throws {
        let completed = MealSelection(recipeID: UUID(), recipeTitle: "Tacos", date: day(2026, 1, 1))
        completed.isCompleted = true
        context.insert(completed)
        let completedStart = calendar.date(byAdding: .hour, value: 17, to: day(2026, 1, 1))!
        let completedBlock = ScheduledBlock(date: day(2026, 1, 1), startTime: completedStart, endTime: calendar.date(byAdding: .hour, value: 1, to: completedStart)!, task: nil)
        completedBlock.isLocked = true
        completedBlock.mealSelection = completed
        context.insert(completedBlock)

        let incomplete = MealSelection(recipeID: UUID(), recipeTitle: "Soup", date: day(2026, 1, 2))
        context.insert(incomplete)
        let incompleteStart = calendar.date(byAdding: .hour, value: 17, to: day(2026, 1, 2))!
        let incompleteBlock = ScheduledBlock(date: day(2026, 1, 2), startTime: incompleteStart, endTime: calendar.date(byAdding: .hour, value: 1, to: incompleteStart)!, task: nil)
        incompleteBlock.isLocked = true
        incompleteBlock.mealSelection = incomplete
        context.insert(incompleteBlock)

        let viewModel = ScheduleReviewViewModel(modelContext: context, calendarService: FakeCalendarService(), schedulingService: service, targetDate: day(2026, 1, 2))
        viewModel.purgeCompletedMealSelections()

        let remainingBlocks = (try? context.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        XCTAssertFalse(remainingBlocks.contains { $0.id == completedBlock.id }, "the purged meal's block must be deleted, not just nulled out — an orphan survives as a phantom \"Open slot\" row")
        XCTAssertTrue(remainingBlocks.contains { $0.id == incompleteBlock.id }, "a still-open meal's block is live backlog and must not be touched")
    }

    /// The flip side of the completed-purge tests: a `MealSelection` from
    /// an earlier, unresolved day must be swept (selection and block
    /// alike, same orphan-block concern as `purgeCompletedMealSelections`)
    /// once the day it's for has been reviewed — otherwise it resurfaces
    /// in every future Nightly Review forever. Also proves no pantry
    /// deduction happens on this path: the matching pantry item's
    /// quantity must be untouched, since an incomplete selection means
    /// the dinner never happened.
    func test_resolveIncompleteMealSelections_deletesBacklogSelectionAndBlockWithNoDeduction() async throws {
        let recipe = Recipe(title: "Omelette", ingredients: ["2 eggs"])
        context.insert(recipe)
        let eggs = TaskItem(title: "Eggs")
        eggs.quantity = 12
        context.insert(eggs)

        let backlogDay = day(2026, 1, 1)
        let reviewDay = day(2026, 1, 3)
        let selection = MealSelection(recipeID: recipe.id, recipeTitle: recipe.title, date: backlogDay)
        context.insert(selection)
        let start = calendar.date(byAdding: .hour, value: 17, to: backlogDay)!
        let block = ScheduledBlock(date: backlogDay, startTime: start, endTime: calendar.date(byAdding: .hour, value: 1, to: start)!, task: nil)
        block.isLocked = true
        block.mealSelection = selection
        context.insert(block)

        let viewModel = ScheduleReviewViewModel(modelContext: context, calendarService: FakeCalendarService(), schedulingService: service, targetDate: reviewDay)
        viewModel.resolveIncompleteMealSelections(reviewDate: reviewDay)

        let remainingSelections = (try? context.fetch(FetchDescriptor<MealSelection>())) ?? []
        XCTAssertFalse(remainingSelections.contains { $0.id == selection.id }, "an incomplete backlog meal selection must be resolved away once its day has been reviewed, or it resurfaces forever")
        let remainingBlocks = (try? context.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        XCTAssertFalse(remainingBlocks.contains { $0.id == block.id }, "the backlog selection's block must go with it — an orphan survives as a phantom \"Open slot\" row")
        XCTAssertEqual(eggs.quantity, 12, "an incomplete meal never happened — resolving it must not trigger pantry deduction")
    }

    /// A meal still due today or later — not backlog — must survive: only
    /// a selection whose own day is on or before the reviewed day is
    /// resolved away.
    func test_resolveIncompleteMealSelections_leavesFutureSelectionUntouched() async throws {
        let reviewDay = day(2026, 1, 3)
        let futureDay = day(2026, 1, 4)
        let selection = MealSelection(recipeID: UUID(), recipeTitle: "Soup", date: futureDay)
        context.insert(selection)

        let viewModel = ScheduleReviewViewModel(modelContext: context, calendarService: FakeCalendarService(), schedulingService: service, targetDate: reviewDay)
        viewModel.resolveIncompleteMealSelections(reviewDate: reviewDay)

        let remaining = (try? context.fetch(FetchDescriptor<MealSelection>())) ?? []
        XCTAssertTrue(remaining.contains { $0.id == selection.id }, "a meal planned for a day after the one being reviewed hasn't had its chance yet and must not be swept")
    }

    /// `insertMealBlock` calls `modelContext.insert(block)` directly,
    /// bypassing `ScheduleReviewViewModel.insertBlock` entirely — without
    /// `registerInsertedBlock` keeping the view model's own `blocks` in
    /// sync, the Tomorrow step (which renders `tomorrowViewModel.blocks`,
    /// not a live fetch) never learns the new block exists.
    func test_registerInsertedBlock_addsToBlocksSortedByStartTime() async throws {
        let viewModel = ScheduleReviewViewModel(modelContext: context, calendarService: FakeCalendarService(), schedulingService: service, targetDate: day(2026, 1, 2))
        let earlyStart = calendar.date(byAdding: .hour, value: 9, to: day(2026, 1, 2))!
        let earlyBlock = ScheduledBlock(date: day(2026, 1, 2), startTime: earlyStart, endTime: calendar.date(byAdding: .hour, value: 1, to: earlyStart)!, task: nil)
        context.insert(earlyBlock)
        viewModel.loadExistingBlocks([earlyBlock])

        let mealStart = calendar.date(byAdding: .hour, value: 17, to: day(2026, 1, 2))!
        let mealBlock = ScheduledBlock(date: day(2026, 1, 2), startTime: mealStart, endTime: calendar.date(byAdding: .hour, value: 1, to: mealStart)!, task: nil)
        context.insert(mealBlock)
        viewModel.registerInsertedBlock(mealBlock)

        XCTAssertTrue(viewModel.blocks.contains { $0.id == mealBlock.id }, "a directly-inserted block must be reflected in the cached blocks array the Tomorrow step actually renders")
        XCTAssertEqual(viewModel.blocks.map(\.id), [earlyBlock.id, mealBlock.id], "blocks must stay sorted by startTime after the insert")
    }

    /// Mirror of the above: `removeMealBlock` deletes the old block
    /// directly when re-picking a meal, and must clear the stale entry out
    /// of `blocks` too, or it lingers alongside the replacement.
    func test_deregisterBlock_removesFromBlocks() async throws {
        let viewModel = ScheduleReviewViewModel(modelContext: context, calendarService: FakeCalendarService(), schedulingService: service, targetDate: day(2026, 1, 2))
        let start = calendar.date(byAdding: .hour, value: 17, to: day(2026, 1, 2))!
        let block = ScheduledBlock(date: day(2026, 1, 2), startTime: start, endTime: calendar.date(byAdding: .hour, value: 1, to: start)!, task: nil)
        context.insert(block)
        viewModel.registerInsertedBlock(block)
        XCTAssertTrue(viewModel.blocks.contains { $0.id == block.id })

        viewModel.deregisterBlock(block)

        XCTAssertFalse(viewModel.blocks.contains { $0.id == block.id }, "re-picking a meal must not leave the old block's stale entry sitting in blocks")
    }

    // MARK: - Unplaced reasons — one coarse explanation per task per walk

    /// Builds a shelf whose single rule runs on `daysOfWeek` between the
    /// given hours, plus a viewmodel and a `testDay` guaranteed to be a
    /// Monday so weekday-restricted fixtures are deterministic.
    private func makeReasonFixture(
        daysOfWeek: [Int],
        startHour: Int = 0,
        endHour: Int = 23,
        fillStrategy: FillStrategy = .fillToFit,
        maxTaskCount: Int = 2,
        maxMinutesPerTask: Int = 15
    ) -> (shelf: Shelf, rule: SchedulingRule, testDay: Date) {
        let shelf = Shelf(name: "Test Shelf")
        context.insert(shelf)
        let schedule = NamedSchedule(name: "Window", daysOfWeek: daysOfWeek, startHour: startHour, startMinute: 0, endHour: endHour, endMinute: 59)
        context.insert(schedule)
        let rule = SchedulingRule(shelf: shelf, fillStrategy: fillStrategy, maxTotalMinutes: 120, maxTaskCount: maxTaskCount, maxMinutesPerTask: maxMinutesPerTask)
        rule.namedSchedule = schedule
        context.insert(rule)
        shelf.schedulingRules = [rule]

        // Next Monday at least 3 days out — future relative to real `.now`
        // (autoPlaceEligibleTasks early-returns on past days) and a fixed
        // weekday so day-of-week fixtures behave predictably.
        var day = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 3, to: .now)!)
        while calendar.component(.weekday, from: day) != 2 {
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return (shelf, rule, day)
    }

    private func runWalk(shelf: Shelf, testDay: Date, freeSlots: @escaping (Date) -> [TimeSlot]) async -> ScheduleReviewViewModel {
        let calendarService = FakeCalendarService()
        calendarService.freeSlotsProvider = freeSlots
        let viewModel = ScheduleReviewViewModel(modelContext: context, calendarService: calendarService, schedulingService: service, targetDate: testDay)
        await viewModel.autoPlaceEligibleTasks(shelves: [shelf], habits: [], eligibleHoursWindows: [])
        return viewModel
    }

    /// The regression test. Reproduces the exact state pulled from the
    /// device store for "Overage calc": incomplete, eligible for its
    /// shelf's rule, 120 estimated minutes, zero remaining, no blocks to
    /// account for the difference. Before the fix it appeared in no list
    /// at all — `canEverFit(estimatedMinutes: 0)` returns `.needsDuration`,
    /// which drops it from the scheduler's candidates *and* from
    /// `tasksThatDidNotFit`, while `isAtRisk` needs `remainingMinutes > 0`
    /// or a block past the deadline and it has neither.
    func test_unplacedReason_drainedToZeroRemaining_isSurfaced() async throws {
        let (shelf, rule, testDay) = makeReasonFixture(daysOfWeek: [1, 2, 3, 4, 5, 6, 7])
        let drained = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 120, isDivisible: false, minimumSegmentMinutes: 0)
        drained.remainingMinutes = 0

        let viewModel = await runWalk(shelf: shelf, testDay: testDay) { [self.businessHoursSlot(on: $0)] }

        let entry = try XCTUnwrap(
            viewModel.tasksThatDidNotFit.first { $0.task.id == drained.id },
            "a task drained to zero remaining while still incomplete must be surfaced, not silently skipped"
        )
        XCTAssertEqual(entry.reason, .needsDuration)
        XCTAssertTrue(entry.explanation.contains("no time left"), "the drained case needs its own sentence, not the never-configured one")
    }

    /// The other half of the same enum case: a task nobody ever gave a
    /// duration to. Same `.needsDuration`, different sentence and action.
    func test_unplacedReason_neverGivenADuration_usesDifferentSentence() async throws {
        let (shelf, rule, testDay) = makeReasonFixture(daysOfWeek: [1, 2, 3, 4, 5, 6, 7])
        let unconfigured = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 0, isDivisible: false, minimumSegmentMinutes: 0)

        let viewModel = await runWalk(shelf: shelf, testDay: testDay) { [self.businessHoursSlot(on: $0)] }

        let entry = try XCTUnwrap(viewModel.tasksThatDidNotFit.first { $0.task.id == unconfigured.id })
        XCTAssertEqual(entry.reason, .needsDuration)
        XCTAssertTrue(entry.explanation.contains("No duration set"))
        XCTAssertNotEqual(entry.suggestedAction, "", "must tell the user what to do")
    }

    /// `.needsDuration` is measured, not inferred, so it precedes every
    /// walk-derived reason even when those would also apply.
    func test_unplacedReason_needsDuration_winsOverDerivedReasons() async throws {
        // A rule that never applies would otherwise yield .noEligibleDays.
        let (shelf, rule, testDay) = makeReasonFixture(daysOfWeek: [])
        let drained = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 120, isDivisible: false, minimumSegmentMinutes: 0)
        drained.remainingMinutes = 0

        let viewModel = await runWalk(shelf: shelf, testDay: testDay) { [self.businessHoursSlot(on: $0)] }

        let entry = try XCTUnwrap(viewModel.tasksThatDidNotFit.first { $0.task.id == drained.id })
        XCTAssertEqual(entry.reason, .needsDuration, "the measured configuration fact must win over the derived reason")
    }

    /// A task holding a block while at zero remaining is surfaced only if
    /// the block doesn't account for its estimate — and its block is never
    /// deleted either way.
    func test_unplacedReason_zeroRemainingWithPartialBlock_surfacedAndBlockKept() async throws {
        let (shelf, rule, testDay) = makeReasonFixture(daysOfWeek: [1, 2, 3, 4, 5, 6, 7])
        let task = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 120, isDivisible: false, minimumSegmentMinutes: 0)
        task.remainingMinutes = 0
        // Only 30 of the 120 minutes accounted for — 90 went missing.
        let blockStart = calendar.date(byAdding: .hour, value: 9, to: testDay)!
        let block = ScheduledBlock(date: testDay, startTime: blockStart, endTime: calendar.date(byAdding: .minute, value: 30, to: blockStart)!, task: task)
        context.insert(block)
        task.scheduledBlocks = [block]

        let viewModel = await runWalk(shelf: shelf, testDay: testDay) { [self.businessHoursSlot(on: $0)] }

        XCTAssertTrue(viewModel.tasksThatDidNotFit.contains { $0.task.id == task.id })
        XCTAssertEqual((task.scheduledBlocks ?? []).count, 1, "surfacing must never sweep the block — it may be real work the user intends to do")
    }

    /// The boundary that keeps this from crying wolf: a task fully placed
    /// by its blocks legitimately has zero remaining and must NOT appear.
    func test_unplacedReason_fullyPlacedTaskAtZeroRemaining_isNotSurfaced() async throws {
        let (shelf, rule, testDay) = makeReasonFixture(daysOfWeek: [1, 2, 3, 4, 5, 6, 7])
        let task = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 120, isDivisible: false, minimumSegmentMinutes: 0)
        task.remainingMinutes = 0
        task.isScheduled = true
        let blockStart = calendar.date(byAdding: .hour, value: 9, to: testDay)!
        let block = ScheduledBlock(date: testDay, startTime: blockStart, endTime: calendar.date(byAdding: .minute, value: 120, to: blockStart)!, task: task)
        context.insert(block)
        task.scheduledBlocks = [block]

        let viewModel = await runWalk(shelf: shelf, testDay: testDay) { [self.businessHoursSlot(on: $0)] }

        XCTAssertFalse(
            viewModel.tasksThatDidNotFit.contains { $0.task.id == task.id },
            "a task whose blocks fully account for its estimate is finished being scheduled, not stranded"
        )
    }

    /// A rule whose schedule has no days at all never applies, so the walk
    /// never even considers the task.
    func test_unplacedReason_noEligibleDays() async throws {
        let (shelf, rule, testDay) = makeReasonFixture(daysOfWeek: [])
        let task = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 60, isDivisible: false, minimumSegmentMinutes: 0)

        let viewModel = await runWalk(shelf: shelf, testDay: testDay) { [self.businessHoursSlot(on: $0)] }

        let entry = try XCTUnwrap(viewModel.tasksThatDidNotFit.first { $0.task.id == task.id })
        XCTAssertEqual(entry.reason, .noEligibleDays)
        XCTAssertEqual(entry.eligibleDayCount, 0)
    }

    /// A Mondays-only rule comes up ~2 times in a 14-day stall window —
    /// rare-window territory, distinct from never applying at all.
    func test_unplacedReason_fewEligibleDays() async throws {
        let (shelf, rule, testDay) = makeReasonFixture(daysOfWeek: [2])
        // Bigger than any opening, so it never places and the walk stalls.
        let task = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 600, isDivisible: false, minimumSegmentMinutes: 0)

        let viewModel = await runWalk(shelf: shelf, testDay: testDay) { [self.businessHoursSlot(on: $0)] }

        let entry = try XCTUnwrap(viewModel.tasksThatDidNotFit.first { $0.task.id == task.id })
        XCTAssertEqual(entry.reason, .fewEligibleDays)
        XCTAssertLessThanOrEqual(entry.eligibleDayCount, 3)
        XCTAssertGreaterThan(entry.eligibleDayCount, 0)
    }

    /// Every eligible day exists but is completely booked.
    func test_unplacedReason_noFreeTime() async throws {
        let (shelf, rule, testDay) = makeReasonFixture(daysOfWeek: [1, 2, 3, 4, 5, 6, 7])
        let task = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 60, isDivisible: false, minimumSegmentMinutes: 0)

        let viewModel = await runWalk(shelf: shelf, testDay: testDay) { _ in [] }

        let entry = try XCTUnwrap(viewModel.tasksThatDidNotFit.first { $0.task.id == task.id })
        XCTAssertEqual(entry.reason, .noFreeTime)
        XCTAssertEqual(entry.totalFreeMinutes, 0)
    }

    /// Plenty of total free time, but chopped into pieces too short for
    /// one whole segment.
    func test_unplacedReason_noContiguousSlot() async throws {
        let (shelf, rule, testDay) = makeReasonFixture(daysOfWeek: [1, 2, 3, 4, 5, 6, 7])
        let task = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 240, isDivisible: true, minimumSegmentMinutes: 120)

        // Four 30-minute openings a day: 120 minutes total, longest 30.
        let viewModel = await runWalk(shelf: shelf, testDay: testDay) { day in
            (0..<4).map { index in
                let start = self.calendar.date(byAdding: .hour, value: 9 + index * 2, to: day)!
                return TimeSlot(start: start, end: self.calendar.date(byAdding: .minute, value: 30, to: start)!)
            }
        }

        let entry = try XCTUnwrap(viewModel.tasksThatDidNotFit.first { $0.task.id == task.id })
        XCTAssertEqual(entry.reason, .noContiguousSlot)
        XCTAssertGreaterThan(entry.totalFreeMinutes, 0, "free time exists — it's the fragmentation that blocks it")
        XCTAssertEqual(entry.maxContiguousSlotMinutes, 30)
        XCTAssertEqual(entry.requiredMinutes, 120, "a divisible task needs one whole segment, not its whole duration")
    }

    /// Pins the documented priority order: a task satisfying BOTH
    /// `.noContiguousSlot` and `.ruleBudgetFull` must resolve to the
    /// former, because that one is measured and the latter is inferred by
    /// elimination.
    func test_unplacedReason_priorityOrder_contiguousSlotBeatsBudgetFull() async throws {
        // `.maxDuration` with a 120-minute budget, deliberately chosen so
        // BOTH tasks still pass `canEverFit` (a task that fails it is an
        // At-Risk case and never reaches this list at all — see the test
        // below). The filler drains the whole budget, and separately no
        // single opening is long enough for `blocked`'s 2-hour segment.
        let (shelf, rule, testDay) = makeReasonFixture(
            daysOfWeek: [1, 2, 3, 4, 5, 6, 7],
            fillStrategy: .maxDuration
        )
        rule.maxTotalMinutes = 120
        // Created first, so `taskOrdering`'s createdAt tiebreak runs it
        // first and it consumes the budget before `blocked` is reached.
        let filler = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 120, isDivisible: true, minimumSegmentMinutes: 30)
        let blocked = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 240, isDivisible: true, minimumSegmentMinutes: 120)

        // Four 30-minute openings: 120 minutes total (exactly the filler's
        // size), longest 30 — far short of `blocked`'s 120-minute segment.
        let viewModel = await runWalk(shelf: shelf, testDay: testDay) { day in
            (0..<4).map { index in
                let start = self.calendar.date(byAdding: .hour, value: 9 + index * 2, to: day)!
                return TimeSlot(start: start, end: self.calendar.date(byAdding: .minute, value: 30, to: start)!)
            }
        }

        XCTAssertTrue(filler.isScheduled, "fixture invalid — the filler must actually consume the budget")
        let entry = try XCTUnwrap(viewModel.tasksThatDidNotFit.first { $0.task.id == blocked.id })
        XCTAssertEqual(entry.reason, .noContiguousSlot, "the measured reason must win over the inferred fallback")
    }

    /// The walk hit `maxWalkDays` with viable days still ahead of it.
    func test_unplacedReason_horizonReached() async throws {
        // Mondays only, one task per Monday: placement keeps resetting the
        // stall counter (7 < 14) so the walk runs all the way to the cap
        // with backlog still outstanding.
        let (shelf, rule, testDay) = makeReasonFixture(
            daysOfWeek: [2],
            fillStrategy: .maxTaskCount,
            maxTaskCount: 1,
            maxMinutesPerTask: 60
        )
        var tasks: [TaskItem] = []
        for index in 0..<10 {
            let task = TaskItem(title: "Task \(index)", shelf: shelf, estimatedMinutes: 60)
            task.setEligible(true, for: rule)
            context.insert(task)
            tasks.append(task)
        }
        shelf.tasks = tasks

        let viewModel = await runWalk(shelf: shelf, testDay: testDay) { [self.businessHoursSlot(on: $0)] }

        XCTAssertEqual(viewModel.lastWalkDayCount, 44, "fixture invalid — the walk must actually reach the cap")
        let entry = try XCTUnwrap(viewModel.tasksThatDidNotFit.first)
        XCTAssertEqual(entry.reason, .horizonReached)
    }

    /// A task that places normally produces no entry at all.
    func test_unplacedReason_taskThatFits_producesNoEntry() async throws {
        let (shelf, rule, testDay) = makeReasonFixture(daysOfWeek: [1, 2, 3, 4, 5, 6, 7])
        let task = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 60, isDivisible: false, minimumSegmentMinutes: 0)

        let viewModel = await runWalk(shelf: shelf, testDay: testDay) { [self.businessHoursSlot(on: $0)] }

        XCTAssertTrue(task.isScheduled)
        XCTAssertTrue(viewModel.tasksThatDidNotFit.isEmpty)
    }

    /// Guards the boundary from `99996ab`: a task failing `canEverFit`
    /// belongs to At-Risk, not here, and must not appear in this list even
    /// though it's unscheduled.
    func test_unplacedReason_taskFailingCanEverFit_isNotListed() async throws {
        let (shelf, rule, testDay) = makeReasonFixture(
            daysOfWeek: [1, 2, 3, 4, 5, 6, 7],
            fillStrategy: .maxTaskCount,
            maxTaskCount: 5,
            maxMinutesPerTask: 30
        )
        // 60 minutes against a 30-minute per-task cap — can never fit.
        let tooBig = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 60, isDivisible: false, minimumSegmentMinutes: 0)

        let viewModel = await runWalk(shelf: shelf, testDay: testDay) { [self.businessHoursSlot(on: $0)] }

        XCTAssertFalse(tooBig.isScheduled)
        XCTAssertFalse(
            viewModel.tasksThatDidNotFit.contains { $0.task.id == tooBig.id },
            "a task that can never fit any rule is an At-Risk case, not an unplaced-this-walk case"
        )
    }

    // MARK: - Divisibility invariants — whole segments, no orphan remainders

    /// The regression test for the reported bug: a 4-hour task divisible
    /// into 2-hour segments, against a rule whose remaining budget is 3.5
    /// hours. `minutesNeeded` was set to the raw 210-minute budget, and
    /// `place`'s whole-task fast path put all 210 minutes in ONE block —
    /// never reaching the segment-splitting loop — leaving a 30-minute
    /// remainder that no future slot could accept, since every slot is
    /// gated on holding a full 2-hour segment. The task then sat
    /// permanently unschedulable while still counting as remaining work.
    ///
    /// Note the budget, not the slot, is what caps this. A slot too small
    /// to hold the whole task simply places nothing that day and tries
    /// again tomorrow, which was never the bug.
    func test_divisibleTask_budgetFlooredToWholeSegments_noOrphanRemainder() async throws {
        let testDay = day(2026, 1, 5)
        // 210-minute budget: 1.75 segments' worth, deliberately not a
        // multiple of the 120-minute segment size.
        let (shelf, rule) = makeShelf(fillStrategy: .maxDuration, maxTotalMinutes: 210)
        let task = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 240, isDivisible: true, minimumSegmentMinutes: 120)

        let blocks = try await service.generateProposedSchedule(
            shelves: [shelf],
            habits: [],
            freeSlots: [businessHoursSlot(on: testDay)],
            eligibleHoursWindows: [],
            date: testDay,
            existingBlocks: [],
            context: context
        )

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.durationMinutes, 120, "must place one whole 2-hour segment, not the raw 210-minute budget")
        XCTAssertEqual(task.remainingMinutes, 120, "the remainder must stay a placeable multiple of the segment size, never a 30-minute orphan")
    }

    /// The slot-splitting path: two slots, neither able to hold the whole
    /// task, each taking a whole segment rather than whatever it happens
    /// to hold.
    func test_divisibleTask_splitAcrossSlots_takesWholeSegmentsOnly() async throws {
        let testDay = day(2026, 1, 5)
        let (shelf, rule) = makeShelf(fillStrategy: .fillToFit)
        let task = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 240, isDivisible: true, minimumSegmentMinutes: 120)

        // 3.5 hours then 2 hours. The first slot must yield 120, not 210 —
        // taking 210 used to leave 30 minutes, which the second slot then
        // rounded back UP to a full 120, over-placing the task by 90
        // minutes total.
        let morning = calendar.date(byAdding: .hour, value: 8, to: testDay)!
        let afternoon = calendar.date(byAdding: .hour, value: 14, to: testDay)!
        let blocks = try await service.generateProposedSchedule(
            shelves: [shelf],
            habits: [],
            freeSlots: [
                TimeSlot(start: morning, end: calendar.date(byAdding: .minute, value: 210, to: morning)!),
                TimeSlot(start: afternoon, end: calendar.date(byAdding: .hour, value: 2, to: afternoon)!)
            ],
            eligibleHoursWindows: [],
            date: testDay,
            existingBlocks: [],
            context: context
        )

        XCTAssertEqual(blocks.map(\.durationMinutes), [120, 120], "every segment must be a whole multiple, and the total must not exceed the task")
        XCTAssertEqual(task.remainingMinutes, 0)
    }

    /// The same task across two separate whole-segment slots drains fully.
    func test_divisibleTask_twoWholeSegmentSlots_placesBoth() async throws {
        let testDay = day(2026, 1, 5)
        let (shelf, rule) = makeShelf(fillStrategy: .fillToFit)
        let task = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 240, isDivisible: true, minimumSegmentMinutes: 120)

        let morning = calendar.date(byAdding: .hour, value: 9, to: testDay)!
        let afternoon = calendar.date(byAdding: .hour, value: 14, to: testDay)!
        let blocks = try await service.generateProposedSchedule(
            shelves: [shelf],
            habits: [],
            freeSlots: [
                TimeSlot(start: morning, end: calendar.date(byAdding: .hour, value: 2, to: morning)!),
                TimeSlot(start: afternoon, end: calendar.date(byAdding: .hour, value: 2, to: afternoon)!)
            ],
            eligibleHoursWindows: [],
            date: testDay,
            existingBlocks: [],
            context: context
        )

        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.map(\.durationMinutes), [120, 120])
        XCTAssertEqual(task.remainingMinutes, 0)
    }

    /// The whole-task fast path is untouched — a slot big enough for the
    /// entire task still places it in one block rather than chunking it.
    func test_divisibleTask_wholeTaskFastPath_stillPlacesInOneBlock() async throws {
        let testDay = day(2026, 1, 5)
        let (shelf, rule) = makeShelf(fillStrategy: .fillToFit)
        let task = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 240, isDivisible: true, minimumSegmentMinutes: 120)

        let blocks = try await service.generateProposedSchedule(
            shelves: [shelf],
            habits: [],
            freeSlots: [businessHoursSlot(on: testDay)],
            eligibleHoursWindows: [],
            date: testDay,
            existingBlocks: [],
            context: context
        )

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.durationMinutes, 240)
        XCTAssertEqual(task.remainingMinutes, 0)
    }

    func test_validSegmentOptions_onlyProperDivisors() {
        XCTAssertEqual(TaskItem.validSegmentOptions(for: 45), [15])
        XCTAssertEqual(TaskItem.validSegmentOptions(for: 60), [15, 30])
        XCTAssertEqual(TaskItem.validSegmentOptions(for: 90), [15, 30, 45])
        XCTAssertEqual(TaskItem.validSegmentOptions(for: 240), [15, 30, 60, 120])
        XCTAssertEqual(TaskItem.validSegmentOptions(for: 25), [], "no candidate divides 25 evenly — divisibility isn't expressible")
        XCTAssertEqual(TaskItem.validSegmentOptions(for: 50), [])
        XCTAssertEqual(TaskItem.validSegmentOptions(for: 0), [])
    }

    func test_validateDivisibility_snapsDownToLargestValidDivisor() {
        let shelf = Shelf(name: "Test Shelf")
        let task = TaskItem(title: "T", shelf: shelf, estimatedMinutes: 60, isDivisible: true, minimumSegmentMinutes: 30)
        // 45 has only 15 as a divisor, so a 30-minute segment is invalid.
        task.estimatedMinutes = 45
        XCTAssertTrue(task.validateDivisibility())
        XCTAssertEqual(task.minimumSegmentMinutes, 15, "must snap DOWN, never up to a coarser chunk than chosen")
        XCTAssertTrue(task.isDivisible)
    }

    func test_validateDivisibility_clearsDivisibilityWhenNoDivisorExists() {
        let shelf = Shelf(name: "Test Shelf")
        let task = TaskItem(title: "T", shelf: shelf, estimatedMinutes: 60, isDivisible: true, minimumSegmentMinutes: 30)
        task.estimatedMinutes = 25
        XCTAssertTrue(task.validateDivisibility())
        XCTAssertFalse(task.isDivisible, "25 minutes can't be split evenly by any offered segment")
        XCTAssertEqual(task.minimumSegmentMinutes, 0)
    }

    func test_validateDivisibility_nonDivisibleAlwaysClearsSegment() {
        let shelf = Shelf(name: "Test Shelf")
        let task = TaskItem(title: "T", shelf: shelf, estimatedMinutes: 60, isDivisible: false, minimumSegmentMinutes: 30)
        XCTAssertTrue(task.validateDivisibility())
        XCTAssertEqual(task.minimumSegmentMinutes, 0)
    }

    /// The shelf-move path specifically — `resolvedDuration` rewrites
    /// `estimatedMinutes` without the user touching divisibility, which is
    /// how a stale segment size survives into the packer.
    func test_validateDivisibility_afterShelfMoveResolvedDuration() {
        let source = Shelf(name: "Source")
        let target = Shelf(name: "Target")
        target.tracksDuration = true
        target.defaultDurationMinutes = 45
        context.insert(source)
        context.insert(target)

        let task = TaskItem(title: "T", shelf: source, estimatedMinutes: 60, isDivisible: true, minimumSegmentMinutes: 30)
        context.insert(task)

        // Mirrors what TaskCardSheet/TaskReviewQueueSheet do on a move.
        task.shelf = target
        task.estimatedMinutes = target.resolvedDuration(candidateMinutes: task.estimatedMinutes)
        task.validateDivisibility()

        if task.estimatedMinutes == 45 {
            XCTAssertEqual(task.minimumSegmentMinutes, 15, "a 30-minute segment can't survive a move to a 45-minute duration")
        }
        XCTAssertTrue(
            task.minimumSegmentMinutes == 0 || task.estimatedMinutes % task.minimumSegmentMinutes == 0,
            "whatever the resolved duration turned out to be, the segment must evenly divide it"
        )
    }

    // MARK: - Walk termination — recurring tasks must not defeat stall detection

    /// The regression test for the real bug: a weekly recurring task
    /// re-places itself every 7th day, and because recurring tasks never
    /// get `isScheduled` set they're placed again on every occurrence,
    /// forever. When those placements reset the stall counter, the counter
    /// climbs 1…6, resets, climbs 1…6 — never reaching 14 — so stall
    /// detection can never fire, and the walk crawls forward day by day
    /// until an unplaceable task finally fits (~1046 days in the report
    /// that surfaced this).
    func test_recurringTaskDoesNotResetStallCounter_walkStaysBounded() async throws {
        let shelf = Shelf(name: "Test Shelf")
        context.insert(shelf)
        let schedule = NamedSchedule(name: "All Day", daysOfWeek: [1, 2, 3, 4, 5, 6, 7], startHour: 0, startMinute: 0, endHour: 23, endMinute: 59)
        context.insert(schedule)
        // Cap per-task minutes low so the backlog task below can never fit.
        let rule = SchedulingRule(shelf: shelf, fillStrategy: .maxTaskCount, maxTaskCount: 5, maxMinutesPerTask: 30)
        rule.namedSchedule = schedule
        context.insert(rule)
        shelf.schedulingRules = [rule]

        let testDay = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 3, to: .now)!)

        // Weekly recurring task — the counter-resetting culprit.
        let recurring = TaskItem(title: "Weekly Recurring", shelf: shelf, estimatedMinutes: 30)
        recurring.isRecurring = true
        recurring.recurrenceIntervalCount = 1
        recurring.recurrenceUnit = .weeks
        recurring.dueDate = testDay
        recurring.setEligible(true, for: rule)
        context.insert(recurring)

        // Backlog task that can never fit this rule (60 > 30-minute cap),
        // so `hasRemainingSchedulableWork` stays true forever.
        let neverFits = TaskItem(title: "Never Fits", shelf: shelf, estimatedMinutes: 60)
        neverFits.setEligible(true, for: rule)
        context.insert(neverFits)
        shelf.tasks = [recurring, neverFits]

        let calendarService = FakeCalendarService()
        calendarService.freeSlotsProvider = { [self.businessHoursSlot(on: $0)] }
        let viewModel = ScheduleReviewViewModel(modelContext: context, calendarService: calendarService, schedulingService: service, targetDate: testDay)

        await viewModel.autoPlaceEligibleTasks(shelves: [shelf], habits: [], eligibleHoursWindows: [])

        // 44 == maxWalkDays (private). Before the fix this walk was
        // effectively unbounded — it only stopped when the never-fitting
        // task happened to fit, which under these rules is never.
        XCTAssertLessThanOrEqual(viewModel.lastWalkDayCount, 44, "the walk must stay bounded even with a recurring task placing on it repeatedly")
        // And it should stop on the stall counter well before the cap,
        // since recurring placements no longer count as backlog progress.
        XCTAssertEqual(viewModel.lastWalkDayCount, 14, "recurring placements must not reset the stall counter")
    }

    /// A task that genuinely can't be placed is reported rather than
    /// buried at whatever distant day it eventually fits.
    func test_unplaceableTask_reportedAsDidNotFit_withNoBlock() async throws {
        let shelf = Shelf(name: "Test Shelf")
        context.insert(shelf)
        let schedule = NamedSchedule(name: "All Day", daysOfWeek: [1, 2, 3, 4, 5, 6, 7], startHour: 0, startMinute: 0, endHour: 23, endMinute: 59)
        context.insert(schedule)
        // `.fillToFit` imposes no per-task cap, so `canEverFit` is true —
        // this task is legitimately schedulable in principle. What defeats
        // it is that no *day* has a big enough opening (below), which is
        // exactly the "didn't fit in the horizon" case. A task that fails
        // `canEverFit` outright is a different category entirely: it's
        // excluded from `hasRemainingSchedulableWork` by design, and is
        // already surfaced through `atRiskBlocker`'s "exceeds every
        // eligible schedule's time constraint".
        let rule = SchedulingRule(shelf: shelf, fillStrategy: .fillToFit)
        rule.namedSchedule = schedule
        context.insert(rule)
        shelf.schedulingRules = [rule]

        let neverFits = TaskItem(title: "Never Fits", shelf: shelf, estimatedMinutes: 60)
        neverFits.setEligible(true, for: rule)
        context.insert(neverFits)
        shelf.tasks = [neverFits]

        let testDay = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 3, to: .now)!)
        let calendarService = FakeCalendarService()
        // Only 30 minutes free per day — never enough for a 60-minute
        // non-divisible task, on any day the walk visits.
        calendarService.freeSlotsProvider = { day in
            let start = self.calendar.date(byAdding: .hour, value: 9, to: day)!
            return [TimeSlot(start: start, end: self.calendar.date(byAdding: .minute, value: 30, to: start)!)]
        }
        let viewModel = ScheduleReviewViewModel(modelContext: context, calendarService: calendarService, schedulingService: service, targetDate: testDay)

        await viewModel.autoPlaceEligibleTasks(shelves: [shelf], habits: [], eligibleHoursWindows: [])

        XCTAssertTrue(viewModel.tasksThatDidNotFit.contains { $0.task.id == neverFits.id }, "an unplaceable task must be surfaced, not silently dropped")
        XCTAssertFalse(neverFits.isScheduled)
        XCTAssertTrue((neverFits.scheduledBlocks ?? []).isEmpty, "it must not get a block at some far-future day")
    }

    /// A recurring task on its own doesn't keep the walk alive past the
    /// cap — it has no backlog to make progress on.
    func test_recurringTaskAlone_doesNotExtendWalkPastCap() async throws {
        let shelf = Shelf(name: "Test Shelf")
        context.insert(shelf)
        let schedule = NamedSchedule(name: "All Day", daysOfWeek: [1, 2, 3, 4, 5, 6, 7], startHour: 0, startMinute: 0, endHour: 23, endMinute: 59)
        context.insert(schedule)
        let rule = SchedulingRule(shelf: shelf, fillStrategy: .fillToFit)
        rule.namedSchedule = schedule
        context.insert(rule)
        shelf.schedulingRules = [rule]

        let testDay = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 3, to: .now)!)
        let recurring = TaskItem(title: "Daily Recurring", shelf: shelf, estimatedMinutes: 30)
        recurring.isRecurring = true
        recurring.recurrenceIntervalCount = 1
        recurring.recurrenceUnit = .days
        recurring.dueDate = testDay
        recurring.setEligible(true, for: rule)
        context.insert(recurring)
        shelf.tasks = [recurring]

        let calendarService = FakeCalendarService()
        calendarService.freeSlotsProvider = { [self.businessHoursSlot(on: $0)] }
        let viewModel = ScheduleReviewViewModel(modelContext: context, calendarService: calendarService, schedulingService: service, targetDate: testDay)

        await viewModel.autoPlaceEligibleTasks(shelves: [shelf], habits: [], eligibleHoursWindows: [])

        XCTAssertLessThanOrEqual(viewModel.lastWalkDayCount, 44, "a daily recurring task must not keep the walk running indefinitely")
    }

    // MARK: - Follow-On #1 — per-day slicing of a shared multi-day busy list

    /// The case the ranged fetch introduces and the per-day fetch never
    /// could: one busy list covering many days is handed to *every* day in
    /// the span, so each day has to clamp it to its own window. An event
    /// crossing midnight must not surface as busy time on the next day.
    func test_freeSlotsInWindow_clampsBusyRangeCrossingMidnight() {
        let day = self.day(2026, 1, 5)
        let nextDay = self.day(2026, 1, 6)
        // 11pm on day 1 → 1am on day 2.
        let overnight = TimeSlot(
            start: calendar.date(byAdding: .hour, value: 23, to: day)!,
            end: calendar.date(byAdding: .hour, value: 1, to: nextDay)!
        )
        let fullDay = { (d: Date) in (start: d, end: self.calendar.date(byAdding: .day, value: 1, to: d)!) }

        let dayOne = freeSlots(inWindow: fullDay(day), busy: [overnight])
        XCTAssertEqual(dayOne.count, 1)
        XCTAssertEqual(dayOne.first?.start, day)
        XCTAssertEqual(dayOne.first?.end, calendar.date(byAdding: .hour, value: 23, to: day)!, "day one's free time must end where the overnight event starts")

        let dayTwo = freeSlots(inWindow: fullDay(nextDay), busy: [overnight])
        XCTAssertEqual(dayTwo.count, 1)
        XCTAssertEqual(dayTwo.first?.start, calendar.date(byAdding: .hour, value: 1, to: nextDay)!, "day two must start free at 1am, when the overnight event actually ends")
        XCTAssertEqual(dayTwo.first?.end, self.day(2026, 1, 7))
    }

    /// A busy range belonging to some other day entirely is ignored rather
    /// than clipping the day being sliced — the common case, since a 44-day
    /// batch means almost every entry belongs to a different day.
    func test_freeSlotsInWindow_ignoresBusyRangeFromAnotherDay() {
        let day = self.day(2026, 1, 5)
        let elsewhere = TimeSlot(
            start: calendar.date(byAdding: .hour, value: 10, to: self.day(2026, 1, 20))!,
            end: calendar.date(byAdding: .hour, value: 11, to: self.day(2026, 1, 20))!
        )
        let window = (start: day, end: calendar.date(byAdding: .day, value: 1, to: day)!)

        let result = freeSlots(inWindow: window, busy: [elsewhere])

        XCTAssertEqual(result.count, 1, "an unrelated day's event must leave this day untouched")
        XCTAssertEqual(result.first?.start, window.start)
        XCTAssertEqual(result.first?.end, window.end)
    }

    // MARK: - §6 — why the dirty flag has to escalate to regenerateFromNow

    /// `autoPlaceEligibleTasks` is additive-plus-a-narrow-trim, not purely
    /// additive: `trimOverflowingRuleBlocksAcrossFutureDays` does clear a
    /// block whose task has since gone ineligible for the rule that placed
    /// it, or that now violates that rule's own count/duration cap — but
    /// only by walking each day's `applicableRules`, which is itself
    /// filtered to rules whose `effectiveDaysOfWeek` still covers that
    /// day. A block stranded on a day its rule's schedule no longer
    /// covers is invisible to that walk, so it's never reached. This is
    /// the concrete case `ScheduleDirtyState`'s escalation exists for: a
    /// task placed under a rule, then the rule's own schedule edited to
    /// drop that weekday (the equivalent of an edit on the rule/schedule
    /// itself) — the light path alone leaves the stale block exactly
    /// where it is forever; only `regenerateFromNow`'s real clear-and-
    /// rewalk actually fixes it.
    func test_autoPlaceAlone_leavesStalePlacement_regenerateFromNow_fixesIt() async throws {
        // Genuinely in the future relative to the real wall clock — both
        // autoPlaceEligibleTasks's own past-day guard and
        // regenerateFromNow's `cutoff = max(targetDate, .now)` need this
        // to actually be ahead of "now," or the fixture's premise (a
        // block that's still there to go stale) breaks for reasons
        // unrelated to what this test is checking.
        let testDay = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 3, to: .now)!)
        let (shelf, rule) = makeShelf(fillStrategy: .fillToFit)
        let task = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 60, isDivisible: false, minimumSegmentMinutes: 0)

        let calendarService = FakeCalendarService()
        calendarService.freeSlotsToReturn = [businessHoursSlot(on: testDay)]
        let viewModel = ScheduleReviewViewModel(modelContext: context, calendarService: calendarService, schedulingService: service, targetDate: testDay)

        // Place it once while still eligible.
        await viewModel.autoPlaceEligibleTasks(shelves: [shelf], habits: [], eligibleHoursWindows: [])
        XCTAssertTrue(task.isScheduled, "fixture invalid — task must actually get placed first")

        // Simulate the edit that would have set ScheduleDirtyState.isDirty
        // in the real app: the rule's own schedule is narrowed so it no
        // longer covers the weekday the block already landed on (task
        // eligibility itself is untouched). This is deliberately NOT an
        // eligibility toggle — trimOverflowingRuleBlocksAcrossFutureDays
        // already sweeps those (see its "task never marked eligible for
        // this specific rule" cleanup), so that scenario can't
        // demonstrate the gap this test is about. A schedule-window
        // change is different: trimOverflowingRuleBlocks only inspects
        // rules whose `effectiveDaysOfWeek` still includes the day being
        // swept (see its `applicableRules` filter), so once testDay's
        // weekday is dropped, this rule is skipped for testDay entirely
        // and its stale block is invisible to that sweep.
        let testWeekday = calendar.component(.weekday, from: testDay)
        rule.namedSchedule?.daysOfWeek = [1, 2, 3, 4, 5, 6, 7].filter { $0 != testWeekday }

        // The light path alone must NOT be able to fix this — proving
        // why a purely-additive top-up can't be the only thing that
        // ever runs.
        await viewModel.autoPlaceEligibleTasks(shelves: [shelf], habits: [], eligibleHoursWindows: [])
        XCTAssertTrue(task.isScheduled, "autoPlaceEligibleTasks incorrectly cleared a stale block — its per-day rule sweep is only supposed to reach days a rule's own schedule still covers")

        // The escalation path — what ScheduleDirtyState.isDirty actually
        // triggers — must fix it.
        await viewModel.regenerateFromNow(shelves: [shelf], habits: [], eligibleHoursWindows: [])
        XCTAssertFalse(task.isScheduled, "regenerateFromNow should have cleared the block once its rule no longer covers that day")
    }

    // MARK: - ScheduleDirtyState sanity

    func test_scheduleDirtyState_isASingleton_defaultsFalse() {
        ScheduleDirtyState.shared.isDirty = false // reset in case another test left it set
        XCTAssertFalse(ScheduleDirtyState.shared.isDirty)
        ScheduleDirtyState.shared.isDirty = true
        XCTAssertTrue(ScheduleDirtyState.shared.isDirty, "must be the same shared instance every time it's accessed")
        ScheduleDirtyState.shared.isDirty = false // leave it clean for any other test that reads it
    }

    // MARK: - §8 — the consolidated replacement/insertion candidate filter

    // NOTE: every test below is `async` even though `replacementCandidates`
    // itself is synchronous, and they must stay that way — as must any
    // future test that constructs a `ScheduleReviewViewModel` at all.
    //
    // The project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so
    // that class is implicitly `@MainActor` despite carrying no
    // annotation, which makes its `deinit` an *isolated* deinit. Address
    // Sanitizer pins the crash to the dealloc, not the init:
    //
    //   free
    //   swift::TaskLocal::StopLookupScope::~StopLookupScope()
    //   swift_task_deinitOnExecutorImpl(...)
    //   ScheduleReviewViewModel.__deallocating_deinit
    //
    // An isolated deinit released with no enclosing Swift Task anywhere
    // up the stack trips a runtime bug in that task-local scope teardown
    // and frees a pointer that was never malloc'd, taking down the whole
    // runner before any assertion runs. XCTest's synchronous path
    // (`-[NSInvocation invoke]` straight into the test method) is exactly
    // that no-Task context; an `async` test method supplies one.
    //
    // This is a bug in the Swift runtime's isolated-deinit teardown, not
    // a defect in `ScheduleReviewViewModel`. The viewmodel is correct as
    // written; it just happens to be the first MainActor-isolated class
    // this suite deallocates outside a task.
    //
    // Confirmed by experiment, so nobody has to re-derive it:
    //   - marking the class `nonisolated` makes the sync case pass —
    //     that identifies the trigger, and is REJECTED as a fix. It
    //     would strip MainActor protection from a viewmodel that touches
    //     `@Observable` state and a `ModelContext`, trading a
    //     test-only crash for real concurrency unsafety in the app.
    //     Do not "simplify" the async annotations away by reaching for
    //     it.
    //   - `@MainActor` on this test class does NOT help; XCTest still
    //     invokes sync methods with no Task
    //   - releasing the viewmodel inside a `Task {}`, a
    //     `Task.detached {}`, or a plain sync closure called from an
    //     async test all pass — so the app's task-based release paths,
    //     including Nightly Review's background `Task {}`, are clear
    //
    // KNOWN GAP, unproven either way: whether SwiftUI's `@State`
    // teardown is itself a no-Task context. If it is, the same bad free
    // is reachable from the app, not just from tests. Argued unlikely —
    // the viewmodel has lived in a SwiftUI hierarchy across many
    // launches without incident, and a genuinely no-Task teardown path
    // would present as a reproducible crash rather than a rare one —
    // but nothing here actually settles it. If a malloc "pointer being
    // freed was not allocated" ever shows up in the app with no obvious
    // cause, start here rather than rediscovering it.

    /// Builds a 60-minute block on `testDay` at 10am, occupied by its own
    /// task, plus the viewmodel that owns the filter under test.
    private func makeOccupiedBlock(on testDay: Date, shelf: Shelf, rule: SchedulingRule) -> (block: ScheduledBlock, viewModel: ScheduleReviewViewModel) {
        let occupant = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 60, isDivisible: false, minimumSegmentMinutes: 0)
        let start = calendar.date(byAdding: .hour, value: 10, to: testDay)!
        let block = ScheduledBlock(date: testDay, startTime: start, endTime: calendar.date(byAdding: .hour, value: 1, to: start)!, task: occupant)
        occupant.isScheduled = true
        context.insert(block)
        let viewModel = ScheduleReviewViewModel(modelContext: context, calendarService: FakeCalendarService(), schedulingService: service, targetDate: testDay)
        return (block, viewModel)
    }

    /// The core §8 gap: pre-Phase-7 the picker offered any unscheduled
    /// task on a shelf with enabled rules, whether or not the task was
    /// actually toggled eligible for a rule covering that window.
    func test_replacementCandidates_excludesTaskNotEligibleForAnyCoveringRule() async {
        let testDay = day(2026, 1, 5)
        let (shelf, rule) = makeShelf(fillStrategy: .fillToFit)
        let (block, viewModel) = makeOccupiedBlock(on: testDay, shelf: shelf, rule: rule)

        let eligible = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 30, isDivisible: false, minimumSegmentMinutes: 0)
        // Same shelf, same everything — just never toggled in.
        let notToggledIn = TaskItem(title: "Not Eligible", shelf: shelf, estimatedMinutes: 30)
        context.insert(notToggledIn)
        shelf.tasks = (shelf.tasks ?? []) + [notToggledIn]

        let candidates = viewModel.replacementCandidates(from: [eligible, notToggledIn], for: .occupiedBlock(block))

        XCTAssertTrue(candidates.contains { $0.id == eligible.id })
        XCTAssertFalse(candidates.contains { $0.id == notToggledIn.id }, "a task never toggled eligible for any rule covering this window must not be offered")
    }

    /// §8's duration check — a task that can't fit the block it would be
    /// taking over isn't a real candidate for it.
    func test_replacementCandidates_excludesTaskLongerThanTheBlock() async {
        let testDay = day(2026, 1, 5)
        let (shelf, rule) = makeShelf(fillStrategy: .fillToFit)
        let (block, viewModel) = makeOccupiedBlock(on: testDay, shelf: shelf, rule: rule)

        let fits = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 60, isDivisible: false, minimumSegmentMinutes: 0)
        let tooBig = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 90, isDivisible: false, minimumSegmentMinutes: 0)
        // Divisible with a segment floor that does fit — allowed, since
        // only one segment has to land in this block.
        let divisibleFits = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 240, isDivisible: true, minimumSegmentMinutes: 30)

        let candidates = viewModel.replacementCandidates(from: [fits, tooBig, divisibleFits], for: .occupiedBlock(block))

        XCTAssertTrue(candidates.contains { $0.id == fits.id }, "exactly-fits must qualify")
        XCTAssertFalse(candidates.contains { $0.id == tooBig.id }, "90 minutes can't occupy a 60-minute block")
        XCTAssertTrue(candidates.contains { $0.id == divisibleFits.id }, "divisible with a 30-min floor fits a 60-min block one segment at a time")
    }

    /// The `.freeSlot` context differs from `.occupiedBlock` in its
    /// exclusions only — no duration check (insertBlock sizes the block
    /// to the task), and already-scheduled tasks never qualify since
    /// there's nothing here to trade places with.
    func test_replacementCandidates_freeSlot_excludesScheduled_andHonorsInboxFlag() async {
        let testDay = day(2026, 1, 5)
        let (shelf, rule) = makeShelf(fillStrategy: .fillToFit)
        let viewModel = ScheduleReviewViewModel(modelContext: context, calendarService: FakeCalendarService(), schedulingService: service, targetDate: testDay)
        let slotStart = calendar.date(byAdding: .hour, value: 10, to: testDay)!

        let unscheduled = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 30, isDivisible: false, minimumSegmentMinutes: 0)
        let alreadyScheduled = makeTask(shelf: shelf, rule: rule, estimatedMinutes: 30, isDivisible: false, minimumSegmentMinutes: 0)
        alreadyScheduled.isScheduled = true
        // No shelf at all — an unsorted Inbox task.
        let inboxTask = TaskItem(title: "Unsorted", estimatedMinutes: 30)
        context.insert(inboxTask)

        let pool = [unscheduled, alreadyScheduled, inboxTask]
        let withInbox = viewModel.replacementCandidates(from: pool, for: .freeSlot(startTime: slotStart, includingInbox: true))
        let withoutInbox = viewModel.replacementCandidates(from: pool, for: .freeSlot(startTime: slotStart, includingInbox: false))

        XCTAssertTrue(withInbox.contains { $0.id == unscheduled.id })
        XCTAssertFalse(withInbox.contains { $0.id == alreadyScheduled.id }, "an empty slot has nothing to swap with, so a scheduled task never qualifies")
        XCTAssertTrue(withInbox.contains { $0.id == inboxTask.id }, "includingInbox: true is what the long-press insert popover needs")
        XCTAssertFalse(withoutInbox.contains { $0.id == inboxTask.id }, "includingInbox: false must exclude unsorted tasks")
    }

    // MARK: - TaskEditSnapshot — startDate

    /// `startDate` is edited on the card (Start Date row, and the
    /// "Recurring?" toggle) same as every other field the snapshot exists
    /// to protect. `b30d2ba` added the four recurrence fields but missed
    /// it — the consequence was Cancel not reverting a startDate edit,
    /// `hasChanges` reading it as untouched (button showed "Skip" instead
    /// of "Save Changes"), and `advance()` never marking the schedule
    /// dirty. `Equatable` is synthesized, so once the field exists on the
    /// struct a mutation is visible for free.
    func test_taskEditSnapshot_capturesAndRestoresStartDate() {
        let shelf = Shelf(name: "S")
        let task = TaskItem(title: "T", shelf: shelf, estimatedMinutes: 30)
        let originalStart = day(2026, 1, 5)
        task.startDate = originalStart

        let original = TaskEditSnapshot(task)

        task.startDate = day(2026, 2, 1)
        let mutated = TaskEditSnapshot(task)

        XCTAssertNotEqual(mutated, original, "a startDate-only edit must be visible to hasChanges")

        original.restore(into: task)
        XCTAssertEqual(task.startDate, originalStart, "Cancel must put the old startDate back")
    }

    // MARK: - openHabitOccurrencesForReview — completedSince

    /// An AM/Midday/PM occurrence already `.complete` before this review
    /// session ever opened used to be permanently invisible to Nightly
    /// Review's Today step — the primary filter is `status == .none`, and
    /// `alsoInclude` only ever contained ids the caller had itself just
    /// toggled mid-session. `completedSince` widens the filter itself:
    /// an already-complete occurrence shows if its own day is strictly
    /// after the last time a review closed a day out. `completedSince`
    /// here is `yesterday`, not `today` itself — that's what
    /// `lastClosedReviewDay` actually holds in production (the day the
    /// *previous* review session closed), so this is the real shape of
    /// the call, not just "same day as the occurrence."
    func test_openHabitOccurrencesForReview_completedSince_surfacesAlreadyCompleteOccurrence() {
        let yesterday = day(2026, 1, 9)
        let today = day(2026, 1, 10)
        // `startDate == today` keeps the backward scan to exactly one day,
        // so the assertions below aren't drowned out by several other
        // still-`.none` backlog days this fixture doesn't care about.
        let habit = Habit(name: "Stretch", startDate: today)
        habit.occurrenceTimeModesRaw = ["am"]
        context.insert(habit)

        let log = habit.logOrCreate(on: today, context: context)
        log.setOccurrence(0, to: .complete)

        let withoutCompletedSince = ScheduleReviewViewModel.openHabitOccurrencesForReview(
            habits: [habit], context: context, upTo: calendar.date(byAdding: .hour, value: 12, to: today)!
        )
        XCTAssertTrue(withoutCompletedSince.isEmpty, "unchanged default behavior: an already-complete occurrence stays hidden with no completedSince")

        let withCompletedSince = ScheduleReviewViewModel.openHabitOccurrencesForReview(
            habits: [habit], context: context, upTo: calendar.date(byAdding: .hour, value: 12, to: today)!,
            completedSince: yesterday
        )
        let surfaced = try? XCTUnwrap(withCompletedSince.first)
        XCTAssertEqual(surfaced?.isCompleted, true, "should surface as completed, not pending")
    }

    /// The other flip side: `completedSince` set to the occurrence's own
    /// day (not the day before it) must NOT surface it — that occurrence
    /// was already reviewed and closed out by the session that set
    /// `lastClosedReviewDay` to that exact day, so showing it again in
    /// the very next review would leak it into one extra review cycle.
    func test_openHabitOccurrencesForReview_completedSince_excludesOccurrenceOnBoundaryItself() {
        let today = day(2026, 1, 10)
        let habit = Habit(name: "Stretch", startDate: today)
        habit.occurrenceTimeModesRaw = ["am"]
        context.insert(habit)

        let log = habit.logOrCreate(on: today, context: context)
        log.setOccurrence(0, to: .complete)

        let result = ScheduleReviewViewModel.openHabitOccurrencesForReview(
            habits: [habit], context: context, upTo: calendar.date(byAdding: .hour, value: 12, to: today)!,
            completedSince: today
        )
        XCTAssertTrue(result.isEmpty, "a completion on the boundary day itself was already closed out by that day's own review")
    }

    /// The flip side: a `completedSince` boundary must not reach backward
    /// into occurrences from before the last review closed — those were
    /// already reviewed and closed out, and re-surfacing them would mean
    /// "everything ever completed" rather than "since last review."
    func test_openHabitOccurrencesForReview_completedSince_excludesOccurrenceBeforeBoundary() {
        let habit = Habit(name: "Stretch", startDate: day(2026, 1, 1))
        habit.occurrenceTimeModesRaw = ["am"]
        context.insert(habit)

        let yesterday = day(2026, 1, 9)
        let today = day(2026, 1, 10)
        let log = habit.logOrCreate(on: yesterday, context: context)
        log.setOccurrence(0, to: .complete)

        let result = ScheduleReviewViewModel.openHabitOccurrencesForReview(
            habits: [habit], context: context, upTo: calendar.date(byAdding: .hour, value: 12, to: today)!,
            completedSince: today
        )
        XCTAssertFalse(
            result.contains { calendar.isDate($0.targetTime, inSameDayAs: yesterday) },
            "a completion from before the completedSince boundary must stay excluded"
        )
    }

}
