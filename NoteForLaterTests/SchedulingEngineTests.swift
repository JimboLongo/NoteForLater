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
                Habit.self, HabitLog.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    // MARK: - Fixtures

    /// A shelf with one enabled rule, on a `NamedSchedule` covering every
    /// day of the week (so the fixture never has to care which weekday
    /// `on` actually falls on) and the full clock (so `freeSlots` alone
    /// decides what's actually available).
    private func makeShelf(fillStrategy: FillStrategy, maxTotalMinutes: Int = 120) -> (shelf: Shelf, rule: SchedulingRule) {
        let shelf = Shelf(name: "Test Shelf")
        context.insert(shelf)

        let schedule = NamedSchedule(name: "All Day", daysOfWeek: [1, 2, 3, 4, 5, 6, 7], startHour: 0, startMinute: 0, endHour: 23, endMinute: 59)
        context.insert(schedule)

        let rule = SchedulingRule(shelf: shelf, fillStrategy: fillStrategy, maxTotalMinutes: maxTotalMinutes)
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
            existingBlocks: []
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
            existingBlocks: []
        )

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.durationMinutes, 50)
        XCTAssertEqual(task.estimatedMinutes, 120)
        XCTAssertEqual(task.remainingMinutes, 70)
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
            existingBlocks: []
        )

        XCTAssertTrue(blocks.isEmpty)
        XCTAssertFalse(task.isScheduled)
    }
}
