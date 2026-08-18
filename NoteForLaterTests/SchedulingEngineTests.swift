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
}
