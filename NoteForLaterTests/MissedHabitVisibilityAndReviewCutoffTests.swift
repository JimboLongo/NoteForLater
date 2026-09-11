import XCTest
import SwiftData
@testable import NoteForLater

/// Coverage for two connected `DayTimelineGridView`/`NightlyReviewView`
/// changes:
///
/// 1. `DayTimelineGridView.openHabitOccurrences` dropped `.missed` (and
///    `.excused`) occurrences entirely instead of showing them, visually
///    distinct — fixed to include `.missed`, reusing `HabitsView`'s own
///    red-fill/xmark treatment rather than inventing new styling.
///    `.excused` was left excluded at first (undecided), then included
///    too once tapping was routed through the full four-state cycle for
///    every state rather than a two-way toggle plus a `.missed`/`.excused`
///    special case — a tap can now *produce* `.excused` from any state, so
///    it has to render or the row disappears mid-cycle with no way back.
///
///    A second, independent reason a missed *Specific-Time* habit's row
///    could vanish: `ScheduleReviewViewModel.clearIncompletePastBlocks`
///    deleted any incomplete past block regardless of whether it was
///    task- or habit-linked. Fixed by excluding habit-linked blocks from
///    that clearing outright — a habit's completion record of record is
///    `HabitLog`, not block-existence, and `AISchedulingService
///    .placeHabitsAndRecurringTasks` generates each day's habit blocks
///    independent of whether an earlier day's block still exists
///    (verified directly, not assumed).
///
/// 2. `NightlyReviewView.reviewCutoff` used to clamp to `min(.now,
///    dayEnd)`, so reviewing at 7pm with `reviewDate` = today gave a 7pm
///    cutoff — a 9pm habit was correctly *displayed* (`reviewDisplayCutoff`
///    never clamped) but never *swept*, since the sweep and the past-block
///    clear both read the clamped cutoff. Fixed by removing the clamp
///    entirely (`ScheduleReviewViewModel.nightlyReviewOperationalCutoff`,
///    extracted from the two identical private `NightlyReviewView`
///    properties for testability) — deliberately: a habit not done by
///    review time now IS incomplete, regardless of the wall clock.
///    Verified this only changes behavior on the reviewDate=today path —
///    every earlier `reviewDate` (Plan Today, or the "catching up on an
///    earlier day" `DatePicker`) already had `dayEnd` before `.now`
///    regardless, so the old clamp was already inert there.
final class MissedHabitVisibilityAndReviewCutoffTests: XCTestCase {
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
            for: TaskItem.self, ScheduledBlock.self, Shelf.self, Habit.self, HabitLog.self,
                CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self,
                Tag.self, NamedSchedule.self, MealSelection.self, Recipe.self, PushRecursionWarning.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    private func makeHabit(name: String, mode: HabitOccurrenceTimeMode = .midday, startDate: Date) -> Habit {
        let habit = Habit(name: name, startDate: startDate, daysOfWeek: [1, 2, 3, 4, 5, 6, 7], idealTimesOfDay: [540])
        habit.occurrenceTimeModesRaw = [mode.rawValue]
        context.insert(habit)
        return habit
    }

    // MARK: - 1a. Missed occurrences render on the calendar

    /// Verified fail-then-pass: with `ScheduleReviewViewModel
    /// .openHabitOccurrences`'s guard temporarily reverted to
    /// `status == .none || status == .complete` (the pre-fix filter),
    /// this test failed — the missed occurrence was absent from the
    /// result, reproducing the reported "disappears entirely" bug.
    /// Restored the real filter and reran: green. Both via `xcodebuild
    /// test`.
    func test_openHabitOccurrences_missedOccurrence_stillRenders() {
        let start = day(2026, 9, 1)
        let today = day(2026, 9, 9)
        let habit = makeHabit(name: "Floss", mode: .midday, startDate: start)
        habit.logOrCreate(on: today, context: context, calendar: calendar).setOccurrence(0, to: .missed)

        let result = ScheduleReviewViewModel.openHabitOccurrences(habits: [habit], mode: .midday, targetDate: today, context: context, calendar: calendar)

        XCTAssertTrue(result.contains { $0.habit.id == habit.id && $0.status == .missed })
    }

    /// `.excused` stays excluded — undecided, not settled (see the view's
    /// own doc comment). This pins the *current* choice down as a test so
    /// a future change to it is deliberate, not accidental.
    /// Reverses the earlier "leave `.excused` out, undecided" choice: once
    /// tapping routes every state through the full four-state cycle
    /// (`toggleHabitOccurrence`), a tap can *produce* `.excused` by
    /// cycling forward from `.missed` — excluding it here would make the
    /// row disappear mid-cycle with no way to tap it back out again.
    ///
    /// Verified fail-then-pass: with `ScheduleReviewViewModel
    /// .openHabitOccurrences`'s filter temporarily reverted to exclude
    /// `.excused` (the pre-this-change behavior), this test failed — the
    /// excused occurrence was absent from the result, reproducing exactly
    /// the "row vanishes mid-cycle" failure mode this change closes.
    /// Restored the unfiltered version and reran: green. Both via
    /// `xcodebuild test`.
    func test_openHabitOccurrences_excusedOccurrence_nowRenders() {
        let start = day(2026, 9, 1)
        let today = day(2026, 9, 9)
        let habit = makeHabit(name: "Meditate", mode: .midday, startDate: start)
        habit.logOrCreate(on: today, context: context, calendar: calendar).setOccurrence(0, to: .excused)

        let result = ScheduleReviewViewModel.openHabitOccurrences(habits: [habit], mode: .midday, targetDate: today, context: context, calendar: calendar)

        XCTAssertTrue(result.contains { $0.habit.id == habit.id && $0.status == .excused }, "an excused occurrence must render, not disappear mid-cycle")
    }

    /// A completed occurrence must keep behaving exactly as before this
    /// change — still included, still reporting `.complete`.
    func test_openHabitOccurrences_completedOccurrence_stillBehavesAsBefore() {
        let start = day(2026, 9, 1)
        let today = day(2026, 9, 9)
        let habit = makeHabit(name: "Read", mode: .midday, startDate: start)
        habit.logOrCreate(on: today, context: context, calendar: calendar).setOccurrence(0, to: .complete)

        let result = ScheduleReviewViewModel.openHabitOccurrences(habits: [habit], mode: .midday, targetDate: today, context: context, calendar: calendar)

        XCTAssertTrue(result.contains { $0.habit.id == habit.id && $0.status == .complete })
    }

    // MARK: - 1b. clearIncompletePastBlocks must not delete habit blocks

    /// The second, independent reason a missed Specific-Time habit's row
    /// could vanish, confirmed and fixed: a habit-linked incomplete block
    /// must survive `clearIncompletePastBlocks` regardless of how far past
    /// its own `startTime` the cutoff reaches.
    @MainActor
    func test_clearIncompletePastBlocks_habitLinkedBlock_isNeverDeleted() async {
        let habitStart = day(2026, 9, 1)
        let blockDay = day(2026, 9, 9)
        let habit = makeHabit(name: "Stretch", mode: .specific, startDate: habitStart)
        let block = ScheduledBlock(
            date: blockDay,
            startTime: calendar.date(byAdding: .hour, value: 21, to: blockDay)!,
            endTime: calendar.date(byAdding: .hour, value: 21, to: blockDay)!.addingTimeInterval(600),
            task: nil, habit: habit, habitOccurrenceIndex: 0
        )
        context.insert(block)

        let viewModel = ScheduleReviewViewModel(
            modelContext: context, calendarService: FakeCalendarService(), schedulingService: MockAISchedulingService(), targetDate: blockDay
        )
        // Cutoff well past the block's own startTime — under the old,
        // unconditional filter this alone would have been enough to
        // delete it.
        let farPastCutoff = calendar.date(byAdding: .day, value: 30, to: blockDay)!
        await viewModel.clearIncompletePastBlocks(allBlocks: [block], cutoff: farPastCutoff)

        let remaining = (try? context.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        XCTAssertEqual(remaining.count, 1, "a habit-linked block must never be cleared by this function")
    }

    /// Sanity check on the other side: an ordinary *task*-linked incomplete
    /// past block must still be cleared exactly as before — the habit
    /// exclusion must not have accidentally protected everything.
    @MainActor
    func test_clearIncompletePastBlocks_taskLinkedBlock_stillClearedAsBefore() async {
        let blockDay = day(2026, 9, 9)
        let task = TaskItem(title: "Test Task", estimatedMinutes: 30)
        context.insert(task)
        let block = ScheduledBlock(
            date: blockDay,
            startTime: calendar.date(byAdding: .hour, value: 9, to: blockDay)!,
            endTime: calendar.date(byAdding: .hour, value: 9, to: blockDay)!.addingTimeInterval(1800),
            task: task
        )
        context.insert(block)

        let viewModel = ScheduleReviewViewModel(
            modelContext: context, calendarService: FakeCalendarService(), schedulingService: MockAISchedulingService(), targetDate: blockDay
        )
        let farPastCutoff = calendar.date(byAdding: .day, value: 30, to: blockDay)!
        await viewModel.clearIncompletePastBlocks(allBlocks: [block], cutoff: farPastCutoff)

        let remaining = (try? context.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        XCTAssertEqual(remaining.count, 0, "an ordinary task block must still be cleared")
    }

    // MARK: - 2. reviewCutoff no longer clamps to .now

    /// Verified fail-then-pass: with `nightlyReviewOperationalCutoff`
    /// temporarily reverted to `min(.now, dayEnd)` (the pre-fix formula),
    /// this test failed — a far-future `reviewDate` returned `.now`
    /// (today's real date) instead of that far-future day's own end.
    /// Restored the pure `dayEnd` formula and reran: green. Both via
    /// `xcodebuild test`. A near reviewDate is deliberately avoided here
    /// specifically so this can't coincidentally pass regardless of when
    /// the suite happens to run — see the file's own header for why.
    func test_nightlyReviewOperationalCutoff_isDayEnd_notClampedToNow() {
        let farFutureReviewDate = day(2031, 6, 15)
        let expectedCutoff = day(2031, 6, 16)

        let cutoff = ScheduleReviewViewModel.nightlyReviewOperationalCutoff(reviewDate: farFutureReviewDate, calendar: calendar)

        XCTAssertEqual(cutoff, expectedCutoff)
    }

    /// The concrete reported bug, reproduced and fixed at the mechanism
    /// `NightlyReviewView`'s sweep actually depends on: a PM-mode habit's
    /// stand-in target time is 9pm (`ScheduleReviewViewModel
    /// .targetMinutes`); reviewing at 7pm used to compute a 7pm cutoff,
    /// which excluded the 9pm occurrence from the sweep's own candidate
    /// list entirely — it stayed `.none` and resurfaced every review.
    ///
    /// Verified fail-then-pass: with `nightlyReviewOperationalCutoff`
    /// temporarily hardcoded to return 7pm on `reviewDate` (standing in
    /// for the old `min(.now, dayEnd)` clamp when "now" is 7pm), this test
    /// failed — the 9pm habit was excluded, reproducing the bug exactly.
    /// Restored the real `dayEnd` formula and reran: green. Both via
    /// `xcodebuild test`.
    ///
    /// Deliberately built with `Calendar.current` here, not the file's own
    /// fixed `America/New_York` `calendar` — `openHabitOccurrencesForReview`
    /// itself hardcodes `Calendar.current` internally (a pre-existing
    /// limitation, not something this task touches), so constructing the
    /// habit/cutoff against a *different* calendar risked a spurious
    /// pass/fail purely from a timezone offset between the two, independent
    /// of the actual fix.
    ///
    /// `startDate` is `reviewDate` itself, deliberately — the function
    /// walks backward day by day up to 400 days scanning for *any*
    /// unresolved occurrence, so a habit with any earlier history would
    /// make this assertion pass regardless of whether `reviewDate`'s own
    /// occurrence specifically qualified (confirmed this was a real
    /// failure mode, not theoretical: an earlier version of this test used
    /// an older `startDate` and stayed green under the reverted cutoff too
    /// — for the wrong reason, an *earlier* day's occurrence, not
    /// `reviewDate`'s). Starting the habit on `reviewDate` itself leaves
    /// exactly one occurrence the walk could possibly find.
    func test_9pmHabit_reviewedAt7pm_isIncludedAsSweepCandidate() {
        let systemCalendar = Calendar.current
        let reviewDate = systemCalendar.startOfDay(for: systemCalendar.date(from: DateComponents(year: 2026, month: 9, day: 9))!)
        let habit = makeHabit(name: "Evening Walk", mode: .pm, startDate: reviewDate)
        // Left at `.none` — never completed, the whole point of the test.

        let cutoff = ScheduleReviewViewModel.nightlyReviewOperationalCutoff(reviewDate: reviewDate, calendar: systemCalendar)
        let result = ScheduleReviewViewModel.openHabitOccurrencesForReview(habits: [habit], context: context, upTo: cutoff)

        XCTAssertTrue(result.contains { $0.habit.id == habit.id }, "a 9pm habit must be a sweep candidate even when the review itself runs before 9pm")
    }

    /// The Plan Today path (`reviewDate` = yesterday) must be unchanged —
    /// verified by confirming the new, unclamped cutoff equals exactly
    /// what the *old* `min(now, dayEnd)` formula would also have produced
    /// for that same `reviewDate`, rather than just assuming it from the
    /// reasoning alone.
    func test_planTodayPath_cutoffUnchangedByRemovingTheClamp() {
        let now = day(2026, 9, 10)
        let reviewDate = ChooseDayPlanning.reviewDate(forPlanning: .today, now: now, calendar: calendar)

        let newCutoff = ScheduleReviewViewModel.nightlyReviewOperationalCutoff(reviewDate: reviewDate, calendar: calendar)
        let oldClampedCutoff = min(now, newCutoff)

        XCTAssertEqual(newCutoff, oldClampedCutoff, "removing the .now clamp must not change the reviewDate=yesterday (Plan Today) path")
    }

    // MARK: - Full four-state cycle on the day calendar

    /// `DayTimelineGridView.toggleHabitOccurrence` now unconditionally
    /// delegates to `Habit.cycleOccurrence` for every state — no logic of
    /// its own left to test beyond that delegation, so this pins the
    /// invariant it relies on: cycling from each of the four states lands
    /// on the next one, and a fifth tap wraps back around. Same cycle
    /// `HabitTodayViewTests.test_cycleOccurrence_advancesThroughAllFourStates_andWraps`
    /// already covers on the Habits tab's own model-level call — repeated
    /// here specifically because the calendar's tap now depends on it too,
    /// per "verify, don't assume."
    func test_cycleOccurrence_fromEachState_advancesToNext_andWraps() {
        let start = day(2026, 9, 1)
        let today = day(2026, 9, 9)
        let habit = makeHabit(name: "Journal", mode: .midday, startDate: start)

        let s1 = habit.cycleOccurrence(0, on: today, context: context, calendar: calendar)
        XCTAssertEqual(s1, .complete)
        let s2 = habit.cycleOccurrence(0, on: today, context: context, calendar: calendar)
        XCTAssertEqual(s2, .missed)
        let s3 = habit.cycleOccurrence(0, on: today, context: context, calendar: calendar)
        XCTAssertEqual(s3, .excused)
        let s4 = habit.cycleOccurrence(0, on: today, context: context, calendar: calendar)
        XCTAssertEqual(s4, .none)
        let s5 = habit.cycleOccurrence(0, on: today, context: context, calendar: calendar)
        XCTAssertEqual(s5, .complete, "a fifth tap must wrap back around, not stop at .none")
    }

    /// `block.isCompleted` must be `true` for `.complete` and `false` for
    /// every other state, across a full cycle including the wrap — the
    /// same rule `HabitDetailView.setDay` already uses, confirmed here
    /// specifically because `toggleHabitOccurrence` on the calendar now
    /// routes every state (not just `.missed`/`.excused`) through this
    /// same sync path.
    func test_cycleOccurrence_blockIsCompletedOnlyTrueForComplete_acrossFullCycle() {
        let start = day(2026, 9, 1)
        let today = day(2026, 9, 9)
        let habit = makeHabit(name: "Stretch", mode: .specific, startDate: start)
        let blockStart = calendar.date(byAdding: .hour, value: 7, to: today)!
        let block = ScheduledBlock(date: today, startTime: blockStart, endTime: calendar.date(byAdding: .minute, value: 10, to: blockStart)!, task: nil, habit: habit, habitOccurrenceIndex: 0)
        context.insert(block)

        _ = habit.cycleOccurrence(0, on: today, context: context, calendar: calendar) // -> complete
        XCTAssertTrue(block.isCompleted)
        _ = habit.cycleOccurrence(0, on: today, context: context, calendar: calendar) // -> missed
        XCTAssertFalse(block.isCompleted)
        _ = habit.cycleOccurrence(0, on: today, context: context, calendar: calendar) // -> excused
        XCTAssertFalse(block.isCompleted)
        _ = habit.cycleOccurrence(0, on: today, context: context, calendar: calendar) // -> none
        XCTAssertFalse(block.isCompleted)
        _ = habit.cycleOccurrence(0, on: today, context: context, calendar: calendar) // -> complete again, after the wrap
        XCTAssertTrue(block.isCompleted, "isCompleted must resync correctly after the cycle wraps back around")
    }
}
