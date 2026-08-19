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
            existingBlocks: []
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
            eligibleHoursWindows: [], date: testDay, existingBlocks: []
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
            eligibleHoursWindows: [], date: testDay, existingBlocks: []
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
            eligibleHoursWindows: [], date: testDay, existingBlocks: []
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
            eligibleHoursWindows: [], date: testDay, existingBlocks: []
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
            eligibleHoursWindows: [], date: testDay, existingBlocks: []
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

        XCTAssertTrue(viewModel.tasksThatDidNotFit.contains { $0.id == neverFits.id }, "an unplaceable task must be surfaced, not silently dropped")
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

}
