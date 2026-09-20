import XCTest
import SwiftData
@testable import NoteForLater

/// Coverage for recurring tasks getting the same tap-through cycle habits
/// already have, per the four decisions this was built against:
///
/// 1. `RecurringTaskLog` now stores a real `status: OccurrenceStatus`
///    (backed by `statusRaw: String`, same raw-value pattern
///    `Habit.occurrenceTimeModesRaw` uses), not just `isCompleted: Bool`.
/// 2. AM/Midday/PM and Specific-Time behave identically — both route
///    through this same log (`TaskItem.cycleRecurringOccurrence`);
///    `ScheduledBlock.isCompleted` is a mirror only, never truth.
/// 3. The cycle is `none -> complete -> missed -> none` — no `.excused`.
/// 4. Landing on `.missed` creates a real `PushedRecurringOccurrence`
///    immediately (`ScheduleReviewViewModel.pushRecurringOccurrenceIfNeeded`),
///    not a display-only projection.
///
/// The orphaned-completion fix in docs/session-handoff.md (a projected
/// Specific-Time completion, written to `RecurringTaskLog` before a real
/// block existed, used to get silently lost once a real block was
/// generated — `AISchedulingService.placeHabitsAndRecurringTasks` now
/// seeds a fresh block's `isCompleted` from the log) isn't covered here:
/// a minimal-fixture call into the full scheduling pipeline crashed on a
/// pre-existing SwiftData issue unrelated to this two-line fix, so it's
/// verified by direct code review instead of a test in this file.
///
/// Also pins the contradiction-D dedup: an interactive missed-tap and
/// the commit-time sweep (`pushMissedRecurringOccurrences`) must never
/// both push the same
/// task.
final class RecurringTaskCycleTests: XCTestCase {
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
            for: TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self,
                SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self,
                Habit.self, HabitLog.self, MealSelection.self, Recipe.self,
                PushRecursionWarning.self, RecurringTaskLog.self, PushedRecurringOccurrence.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    private func makeUntimedTask(anchor: Date, mode: HabitOccurrenceTimeMode = .midday) -> TaskItem {
        let task = TaskItem(title: "Review Monarch Expenses", dueDate: anchor, estimatedMinutes: 30)
        task.isRecurring = true
        task.recurrenceUnit = .months
        task.recurrenceIntervalCount = 1
        task.recurrenceTimeMode = mode
        context.insert(task)
        return task
    }

    private func makeSpecificTimeTask(anchor: Date) -> TaskItem {
        let task = TaskItem(title: "Pay rent", dueDate: anchor, estimatedMinutes: 15)
        task.isRecurring = true
        task.recurrenceUnit = .months
        task.recurrenceIntervalCount = 1
        // Legacy row shape: the setter refuses `.specific` for tasks now
        // (see `TaskItem.recurrenceTimeMode`), so this writes the raw
        // column directly, which is exactly the pre-migration state
        // `migrateRecurringSpecificTimeTasksIfNeeded` exists to clear. The
        // machinery under test is retired but not yet deleted — see stage
        // 4b — so it stays covered until it goes.
        task.recurrenceTimeModeRaw = HabitOccurrenceTimeMode.specific.rawValue
        context.insert(task)
        return task
    }

    // MARK: - Decision 3: three-state cycle, no excused

    func test_cycleRecurringOccurrence_advancesThroughThreeStates_andWraps() {
        let day = day(2026, 9, 9)
        let task = makeUntimedTask(anchor: day)

        XCTAssertEqual(task.cycleRecurringOccurrence(on: day, context: context, calendar: calendar), .complete)
        XCTAssertEqual(task.cycleRecurringOccurrence(on: day, context: context, calendar: calendar), .missed)
        XCTAssertEqual(task.cycleRecurringOccurrence(on: day, context: context, calendar: calendar), .none, "must wrap straight back to none — no .excused in a task's cycle")
        XCTAssertEqual(task.cycleRecurringOccurrence(on: day, context: context, calendar: calendar), .complete, "the wrap must repeat cleanly on a second lap")
    }

    // MARK: - Decision 2: both time modes behave identically

    func test_cycleRecurringOccurrence_specificTimeMode_mirrorsIntoBlock_butLogIsTruth() {
        let anchor = day(2026, 9, 1)
        let task = makeSpecificTimeTask(anchor: anchor)
        let block = ScheduledBlock(date: anchor, startTime: anchor, endTime: anchor.addingTimeInterval(900), task: task)
        context.insert(block)

        XCTAssertEqual(task.cycleRecurringOccurrence(on: anchor, context: context, calendar: calendar), .complete)
        XCTAssertTrue(block.isCompleted, "the linked block should mirror .complete")

        XCTAssertEqual(task.cycleRecurringOccurrence(on: anchor, context: context, calendar: calendar), .missed)
        XCTAssertFalse(block.isCompleted, "missed is not complete — the block mirror must reflect that")
        XCTAssertEqual(RecurringTaskLog.log(taskID: task.id, on: anchor, context: context, calendar: calendar)?.status, .missed, "the log, not the block, is what actually carries .missed")
    }

    // MARK: - Decision 4 + fail-then-pass #1: missed creates a push immediately

    /// Fail-then-pass target #1 ("missed-creates-a-push"): with
    /// `pushRecurringOccurrenceIfNeeded` temporarily forced to never
    /// create a record, this failed — confirmed via `xcodebuild test`,
    /// see the commit message. Restored, confirmed passing.
    func test_missedOccurrence_createsPushedRecurringOccurrence_immediately() {
        let day = day(2026, 9, 9)
        let task = makeUntimedTask(anchor: day)

        let status = task.cycleRecurringOccurrence(on: day, context: context, calendar: calendar)
        XCTAssertEqual(status, .complete)
        let next = task.cycleRecurringOccurrence(on: day, context: context, calendar: calendar)
        XCTAssertEqual(next, .missed)

        // This is the exact call `NightlyReviewView.pushIfMissed` makes
        // the instant a cycle lands on `.missed` — not deferred to Next.
        let pushed = ScheduleReviewViewModel.pushRecurringOccurrenceIfNeeded(task: task, missedDay: day, context: context)
        XCTAssertNotNil(pushed, "marking missed must create a real push record immediately")

        let allPushes = (try? context.fetch(FetchDescriptor<PushedRecurringOccurrence>())) ?? []
        XCTAssertEqual(allPushes.count, 1)
        XCTAssertEqual(allPushes.first?.taskID, task.id)
        XCTAssertFalse(allPushes.first?.isCompleted ?? true)
    }

    // MARK: - `isPushable == false` suppresses the push machinery entirely

    /// Fail-then-pass target: marking a non-pushable task missed must not
    /// create a `PushedRecurringOccurrence` — the log still records
    /// `.missed` (that part is unrelated to pushing and untouched by
    /// `isPushable`), but nothing carries it forward. It just stays
    /// missed on its own day and waits for the next natural recurrence.
    func test_nonPushableTask_markedMissed_createsNoPushRecord() {
        let day = day(2026, 9, 9)
        let task = makeUntimedTask(anchor: day)
        task.isPushable = false

        let status = task.cycleRecurringOccurrence(on: day, context: context, calendar: calendar)
        XCTAssertEqual(status, .complete)
        let next = task.cycleRecurringOccurrence(on: day, context: context, calendar: calendar)
        XCTAssertEqual(next, .missed)
        XCTAssertEqual(RecurringTaskLog.log(taskID: task.id, on: day, context: context, calendar: calendar)?.status, .missed, "the miss itself is still recorded — isPushable only controls the push")

        let pushed = ScheduleReviewViewModel.pushRecurringOccurrenceIfNeeded(task: task, missedDay: day, context: context)

        XCTAssertNil(pushed, "a non-pushable task must never get a push record")
        let allPushes = (try? context.fetch(FetchDescriptor<PushedRecurringOccurrence>())) ?? []
        XCTAssertTrue(allPushes.isEmpty)
    }

    /// The commit-time sweep shares the same guarded function, so a
    /// non-pushable task **explicitly marked missed** there must also get no
    /// push record.
    ///
    /// **REVERSAL:** the block used to be left merely incomplete, and the
    /// test asserted the sweep wrote `.missed` to the log itself. The sweep
    /// no longer marks anything — only an occurrence already at `.missed`
    /// is pushable — so the fixture marks it first and the log assertion
    /// becomes a precondition rather than an outcome. What the test is
    /// actually for is unchanged: `isPushable == false` must suppress the
    /// record.
    func test_nonPushableTask_commitTimeSweep_createsNoPushRecord() {
        let anchor = day(2026, 9, 9)
        let task = makeSpecificTimeTask(anchor: anchor)
        task.isPushable = false
        let block = ScheduledBlock(date: anchor, startTime: anchor, endTime: anchor.addingTimeInterval(900), task: task)
        context.insert(block)
        block.status = .missed

        let created = ScheduleReviewViewModel.pushMissedRecurringOccurrences(
            reviewedBlocks: [block], tasks: [task], context: context, cutoff: anchor.addingTimeInterval(86400)
        )

        XCTAssertTrue(created.isEmpty)
        let allPushes = (try? context.fetch(FetchDescriptor<PushedRecurringOccurrence>())) ?? []
        XCTAssertTrue(allPushes.isEmpty, "isPushable == false suppresses the record even for a real miss")
    }

    // MARK: - Undoing a push

    /// **The shared cycle-and-reconcile entry point, which both surfaces
    /// now call.**
    ///
    /// This is the test that would have caught the real bug. The undo
    /// function itself was covered and correct; what was missing was any
    /// assertion that a *tap* reaches it — and both call sites lived in
    /// private view methods no test can reach. So the day calendar pushed
    /// without ever undoing (`cycleRecurringTaskOccurrence` had
    /// `if next == .missed { push }` and no matching `else`) while Nightly
    /// Review undid correctly, and every test stayed green.
    ///
    /// Testing the shared function covers both surfaces at once, because
    /// there is now only one place the decision lives.
    func test_cycleReconcilingPush_pushesOnMissedAndUndoesOnTheWayBack() throws {
        let anchor = day(2026, 9, 9)
        let task = makeUntimedTask(anchor: anchor)

        let toComplete = ScheduleReviewViewModel.cycleRecurringOccurrenceReconcilingPush(
            task: task, on: anchor, context: context, calendar: calendar
        )
        XCTAssertEqual(toComplete.next, .complete)
        XCTAssertNil(toComplete.pushed, "completing pushes nothing")
        XCTAssertTrue(try context.fetch(FetchDescriptor<PushedRecurringOccurrence>()).isEmpty)

        let toMissed = ScheduleReviewViewModel.cycleRecurringOccurrenceReconcilingPush(
            task: task, on: anchor, context: context, calendar: calendar
        )
        XCTAssertEqual(toMissed.next, .missed)
        XCTAssertNotNil(toMissed.pushed, "landing on missed creates the record")
        XCTAssertEqual(try context.fetch(FetchDescriptor<PushedRecurringOccurrence>()).count, 1)

        let toNone = ScheduleReviewViewModel.cycleRecurringOccurrenceReconcilingPush(
            task: task, on: anchor, context: context, calendar: calendar
        )
        XCTAssertEqual(toNone.next, OccurrenceStatus.none)
        XCTAssertEqual(toNone.undone.count, 1, "the caller needs the ids to drop them from its session tracking")
        XCTAssertTrue(
            try context.fetch(FetchDescriptor<PushedRecurringOccurrence>()).isEmpty,
            "cycling back off missed must leave no record — this is what stayed broken on the day calendar"
        )
    }

    /// **Completing a pushed occurrence removes the push, on the tap.**
    ///
    /// The scenario as actually performed: missed on Monday creates the
    /// record, it hops to Tuesday, and Tuesday's pushed row is tapped
    /// straight to `.complete` from `.none` — never passing through
    /// `.missed` on that day at all.
    ///
    /// The undo gates on "not landing on `.missed`", not on "was `.none`",
    /// so this is covered by the same branch. Pinned separately anyway
    /// because it is the case a `.none`-specific check would silently miss,
    /// and that is exactly the shape of the bug this whole area keeps
    /// producing.
    func test_completingAPushedOccurrence_removesTheRecordImmediately() throws {
        let monday = day(2026, 9, 14)
        let tuesday = day(2026, 9, 15)
        let task = makeUntimedTask(anchor: monday)

        // Missed on Monday, hopped to Tuesday.
        _ = ScheduleReviewViewModel.cycleRecurringOccurrenceReconcilingPush(task: task, on: monday, context: context, calendar: calendar) // complete
        let missed = ScheduleReviewViewModel.cycleRecurringOccurrenceReconcilingPush(task: task, on: monday, context: context, calendar: calendar) // missed
        let pushed = try XCTUnwrap(missed.pushed)
        _ = PushedRecurringOccurrence.advanceOneHop(pushed, task: task, from: monday, to: tuesday, calendar: calendar, context: context)
        XCTAssertEqual(calendar.startOfDay(for: pushed.currentDate), tuesday, "the row now sits on Tuesday")

        // Tapping Tuesday's row once: .none -> .complete.
        let done = ScheduleReviewViewModel.cycleRecurringOccurrenceReconcilingPush(task: task, on: tuesday, context: context, calendar: calendar)

        XCTAssertEqual(done.next, .complete)
        XCTAssertEqual(done.undone.count, 1)
        XCTAssertTrue(
            try context.fetch(FetchDescriptor<PushedRecurringOccurrence>()).isEmpty,
            "the push is gone on the tap — not left for the next launch to clean up"
        )
    }

    /// Cycling all the way round to `.complete` also undoes it — the cycle
    /// reaches `.none` first, so the undo must not be pinned to one exit.
    func test_cycleReconcilingPush_undoesOnTheCompleteExitToo() throws {
        let anchor = day(2026, 9, 9)
        let task = makeUntimedTask(anchor: anchor)
        for _ in 0..<2 {
            _ = ScheduleReviewViewModel.cycleRecurringOccurrenceReconcilingPush(task: task, on: anchor, context: context, calendar: calendar)
        }
        XCTAssertEqual(try context.fetch(FetchDescriptor<PushedRecurringOccurrence>()).count, 1)

        _ = ScheduleReviewViewModel.cycleRecurringOccurrenceReconcilingPush(task: task, on: anchor, context: context, calendar: calendar) // -> none
        _ = ScheduleReviewViewModel.cycleRecurringOccurrenceReconcilingPush(task: task, on: anchor, context: context, calendar: calendar) // -> complete

        XCTAssertTrue(try context.fetch(FetchDescriptor<PushedRecurringOccurrence>()).isEmpty)
    }

    /// **Cycling a recurring occurrence back off `.missed` deletes the push.**
    ///
    /// All new — sabotage found this at zero coverage: adding the undo to
    /// the live code changed nothing in 633 tests, so nothing was asserting
    /// either that the record survived or that it went.
    ///
    /// It survived because `pushIfMissed`'s own comment claimed the reversal
    /// was "handled there instead, via the already-existing
    /// `isAlreadyResolved` check" in `advance()`. It was not:
    /// `isAlreadyResolved` only asks whether a *completed* log exists for the
    /// pushed day, which says nothing about an occurrence cycled back to
    /// `.none`. The record stayed live and kept hopping forward.
    func test_undoRecurringPush_deletesTheOutstandingRecord() throws {
        let anchor = day(2026, 9, 9)
        let task = makeUntimedTask(anchor: anchor)
        let pushed = try XCTUnwrap(
            ScheduleReviewViewModel.pushRecurringOccurrenceIfNeeded(task: task, missedDay: anchor, context: context)
        )
        XCTAssertEqual(try context.fetch(FetchDescriptor<PushedRecurringOccurrence>()).count, 1)

        let removed = ScheduleReviewViewModel.undoRecurringPush(for: task, context: context)

        XCTAssertEqual(removed, [pushed.id], "the caller needs the ids to drop them from its own session tracking")
        XCTAssertTrue(
            try context.fetch(FetchDescriptor<PushedRecurringOccurrence>()).isEmpty,
            "changing your mind must leave no record behind — otherwise it keeps hopping forward"
        )
    }

    /// The full round trip through the real cycle: missed pushes, cycling on
    /// to `.none` undoes it. This is the sequence a user actually performs.
    func test_cyclingMissedThenIncomplete_leavesNoPush() throws {
        let anchor = day(2026, 9, 9)
        let task = makeUntimedTask(anchor: anchor)

        _ = task.cycleRecurringOccurrence(on: anchor, context: context, calendar: calendar)   // .complete
        _ = task.cycleRecurringOccurrence(on: anchor, context: context, calendar: calendar)   // .missed
        _ = ScheduleReviewViewModel.pushRecurringOccurrenceIfNeeded(task: task, missedDay: anchor, context: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PushedRecurringOccurrence>()).count, 1)

        let next = task.cycleRecurringOccurrence(on: anchor, context: context, calendar: calendar)   // .none
        XCTAssertEqual(next, OccurrenceStatus.none)
        ScheduleReviewViewModel.undoRecurringPush(for: task, context: context)

        XCTAssertTrue(try context.fetch(FetchDescriptor<PushedRecurringOccurrence>()).isEmpty)
    }

    /// A resolved record is history and must survive — the undo is scoped to
    /// live chains, matching the "already pushed" guard's own notion.
    func test_undoRecurringPush_leavesACompletedRecordAlone() throws {
        let anchor = day(2026, 9, 9)
        let task = makeUntimedTask(anchor: anchor)
        let resolved = PushedRecurringOccurrence(taskID: task.id, originalDate: anchor)
        resolved.isCompleted = true
        context.insert(resolved)

        let removed = ScheduleReviewViewModel.undoRecurringPush(for: task, context: context)

        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PushedRecurringOccurrence>()).count, 1, "a resolved chain is not undone")
    }

    /// Another task's push is untouched — the predicate is per-task, and a
    /// fetch-all-then-delete would have passed every other test here.
    func test_undoRecurringPush_doesNotTouchAnotherTasksPush() throws {
        let anchor = day(2026, 9, 9)
        let mine = makeUntimedTask(anchor: anchor)
        let theirs = makeUntimedTask(anchor: anchor)
        _ = ScheduleReviewViewModel.pushRecurringOccurrenceIfNeeded(task: mine, missedDay: anchor, context: context)
        _ = ScheduleReviewViewModel.pushRecurringOccurrenceIfNeeded(task: theirs, missedDay: anchor, context: context)

        ScheduleReviewViewModel.undoRecurringPush(for: mine, context: context)

        let left = try context.fetch(FetchDescriptor<PushedRecurringOccurrence>())
        XCTAssertEqual(left.count, 1)
        XCTAssertEqual(left.first?.taskID, theirs.id)
    }

    /// Default is `true`, matching every task's behavior before this
    /// field existed — an opt-out, not an opt-in.
    func test_isPushable_defaultsToTrue() {
        let task = makeUntimedTask(anchor: day(2026, 9, 9))

        XCTAssertTrue(task.isPushable)
    }

    // MARK: - Contradiction D + fail-then-pass #2: no duplicate push

    /// Fail-then-pass target #2 ("no-duplicate-row"): with the
    /// "already pushed" guard in `pushRecurringOccurrenceIfNeeded`
    /// temporarily disabled, this failed — two records existed instead
    /// of one — confirmed via `xcodebuild test`, see the commit message.
    /// Restored, confirmed passing.
    ///
    /// Simulates the exact sequence decision 4 introduces, using a
    /// Specific-Time task deliberately: cycling to `.missed` mirrors
    /// `block.isCompleted = false` (already false), so the commit-time
    /// sweep's block-scoped loop — which only ever checks
    /// `!block.isCompleted`, never the log's own status — still sees this
    /// block as a candidate and tries to push it again. Only the shared
    /// "already pushed" guard in `pushRecurringOccurrenceIfNeeded` is
    /// what stops a second record. (An untimed task doesn't exercise
    /// this: the sweep's other loop sources candidates from
    /// `openRecurringTaskOccurrencesForReview`, which is already
    /// `.none`-only, so an already-missed untimed occurrence is filtered
    /// out before the guard ever gets a chance to matter.)
    func test_interactivePush_thenCommitTimeSweep_doesNotDoublePush() {
        let anchor = day(2026, 9, 9)
        let task = makeSpecificTimeTask(anchor: anchor)
        let block = ScheduledBlock(date: anchor, startTime: anchor, endTime: anchor.addingTimeInterval(900), task: task)
        context.insert(block)

        // The interactive tap: cycle to missed, push immediately.
        _ = task.cycleRecurringOccurrence(on: anchor, context: context, calendar: calendar) // .complete
        _ = task.cycleRecurringOccurrence(on: anchor, context: context, calendar: calendar) // .missed
        let interactivePush = ScheduleReviewViewModel.pushRecurringOccurrenceIfNeeded(task: task, missedDay: anchor, context: context)
        XCTAssertNotNil(interactivePush)

        // The commit-time sweep, run afterward in the same session,
        // exactly as `advance()` does on Next.
        let cutoff = anchor.addingTimeInterval(86400)
        let created = ScheduleReviewViewModel.pushMissedRecurringOccurrences(
            reviewedBlocks: [block], tasks: [task], context: context, cutoff: cutoff
        )

        XCTAssertTrue(created.isEmpty, "the sweep must not create a second record for a task the interactive tap already pushed")
        let allPushes = (try? context.fetch(FetchDescriptor<PushedRecurringOccurrence>())) ?? []
        XCTAssertEqual(allPushes.count, 1, "exactly one push record must exist, not two")
    }

    /// **REVERSAL — the sweep must NOT mark an untouched occurrence missed.**
    ///
    /// This asserted the opposite: that every occurrence the sweep processed
    /// got `.missed` written to its log, mirroring
    /// `markUnresolvedHabitOccurrencesAsMissed`. That was right when `.none`
    /// was the only non-complete state and had to stand in for "unfinished".
    /// Now `.missed` says it explicitly, and deciding on the user's behalf
    /// that an untouched occurrence was missed writes a false record *and*
    /// pushes work nobody deferred.
    ///
    /// Inverted rather than deleted: the behaviour is the exact negation of
    /// what it used to pin, so the test still belongs — it is the guard that
    /// the sweep stays passive. An untouched occurrence stays `.none` and
    /// resurfaces as backlog in the Today step until actually marked.
    func test_pushMissedRecurringOccurrences_leavesAnUntouchedOccurrenceAlone() {
        let anchor = day(2026, 8, 31)
        let task = makeUntimedTask(anchor: anchor)
        let cutoff = day(2026, 9, 1)

        let created = ScheduleReviewViewModel.pushMissedRecurringOccurrences(
            reviewedBlocks: [], tasks: [task], context: context, cutoff: cutoff
        )

        XCTAssertTrue(created.isEmpty, "nothing was marked missed, so nothing is pushed")
        XCTAssertNil(
            RecurringTaskLog.log(taskID: task.id, on: anchor, context: context, calendar: calendar)?.status,
            "an occurrence the user never touched must not be rewritten to .missed by the commit"
        )
        XCTAssertTrue(((try? context.fetch(FetchDescriptor<PushedRecurringOccurrence>())) ?? []).isEmpty)
    }

    // MARK: - Operational vs. display list (mirrors the habit split)

    /// Guardrail, same purpose as the habit equivalent: pins
    /// `openRecurringTaskOccurrencesForReview` (the operational list) to
    /// `.none` only, so a future widening for display purposes fails
    /// this test instead of silently reopening the untimed-path
    /// protection this mirrors from the habit side.
    func test_openRecurringTaskOccurrencesForReview_onlyEverReturnsNoneStatus() {
        let reviewDay = day(2026, 9, 9)
        let completedTask = makeUntimedTask(anchor: reviewDay, mode: .am)
        _ = completedTask.cycleRecurringOccurrence(on: reviewDay, context: context, calendar: calendar)
        let missedTask = makeUntimedTask(anchor: reviewDay, mode: .midday)
        _ = missedTask.cycleRecurringOccurrence(on: reviewDay, context: context, calendar: calendar)
        _ = missedTask.cycleRecurringOccurrence(on: reviewDay, context: context, calendar: calendar)
        let noneTask = makeUntimedTask(anchor: reviewDay, mode: .pm)

        let result = ScheduleReviewViewModel.openRecurringTaskOccurrencesForReview(
            tasks: [completedTask, missedTask, noneTask], context: context, upTo: reviewDay.addingTimeInterval(86400), calendar: calendar
        )

        XCTAssertTrue(result.allSatisfy { $0.status == .none })
        XCTAssertEqual(result.map(\.task.id), [noneTask.id])
    }

    func test_allRecurringTaskOccurrencesForReview_completedBeforeReviewOpened_stillAppears() {
        let reviewDay = day(2026, 9, 9)
        let task = makeUntimedTask(anchor: reviewDay, mode: .am)
        _ = task.cycleRecurringOccurrence(on: reviewDay, context: context, calendar: calendar)

        let result = ScheduleReviewViewModel.allRecurringTaskOccurrencesForReview(
            tasks: [task], context: context, upTo: reviewDay.addingTimeInterval(86400), completedSince: nil, calendar: calendar
        )

        XCTAssertEqual(result.first(where: { calendar.isDate($0.targetTime, inSameDayAs: reviewDay) })?.status, .complete)
    }

    func test_unresolvedRecurringTaskOccurrences_filtersToNoneOnly() {
        let reviewDay = day(2026, 9, 9)
        let task = makeUntimedTask(anchor: reviewDay)
        let all = ScheduleReviewViewModel.allRecurringTaskOccurrencesForReview(
            tasks: [task], context: context, upTo: reviewDay.addingTimeInterval(86400), completedSince: nil, calendar: calendar
        )
        XCTAssertEqual(ScheduleReviewViewModel.unresolvedRecurringTaskOccurrences(all).count, 1)

        _ = task.cycleRecurringOccurrence(on: reviewDay, context: context, calendar: calendar)
        let allAfter = ScheduleReviewViewModel.allRecurringTaskOccurrencesForReview(
            tasks: [task], context: context, upTo: reviewDay.addingTimeInterval(86400), completedSince: nil, calendar: calendar
        )
        XCTAssertTrue(ScheduleReviewViewModel.unresolvedRecurringTaskOccurrences(allAfter).isEmpty)
    }

    func test_unresolvedRecurringTaskBlocks_ignoresNonRecurringBlocks() {
        let anchor = day(2026, 9, 1)
        let recurringTask = makeSpecificTimeTask(anchor: anchor)
        let recurringBlock = ScheduledBlock(date: anchor, startTime: anchor, endTime: anchor.addingTimeInterval(900), task: recurringTask)
        context.insert(recurringBlock)

        let ordinaryTask = TaskItem(title: "Ordinary", estimatedMinutes: 30)
        context.insert(ordinaryTask)
        let ordinaryBlock = ScheduledBlock(date: anchor, startTime: anchor, endTime: anchor.addingTimeInterval(1800), task: ordinaryTask)
        context.insert(ordinaryBlock)

        let result = ScheduleReviewViewModel.unresolvedRecurringTaskBlocks([recurringBlock, ordinaryBlock], context: context, calendar: calendar)
        XCTAssertEqual(result.map(\.id), [recurringBlock.id], "an ordinary, non-recurring block must never be gated")
    }

    // MARK: - Day calendar consolidation (DayTimelineGridView routes through the same cycle)

    /// The block path is the one most likely to get missed in this
    /// consolidation, since it shares `DayTimelineGridView.completeCircle(for:)`
    /// with every ordinary (non-recurring) task block. Confirms a
    /// recurring task's block status is readable live (through
    /// `RecurringTaskLog`, via `recurringTaskOccurrenceStatus` — the same
    /// function `completeCircle(for:)` calls to decide which branch to
    /// render), separate from its own `isCompleted` mirror, which stays
    /// `true` only for `.complete` — while a non-recurring task's block
    /// keeps its single, unrelated `isCompleted` flag, untouched by any
    /// of this and with no missed concept of its own at all.
    func test_recurringTaskBlock_liveStatusCycles_nonRecurringBlockStaysPlainToggle() {
        let anchor = day(2026, 9, 1)
        let recurringTask = makeSpecificTimeTask(anchor: anchor)
        let recurringBlock = ScheduledBlock(date: anchor, startTime: anchor, endTime: anchor.addingTimeInterval(900), task: recurringTask)
        context.insert(recurringBlock)

        XCTAssertEqual(recurringTask.cycleRecurringOccurrence(on: anchor, context: context, calendar: calendar), .complete)
        XCTAssertTrue(recurringBlock.isCompleted, "the mirror reflects .complete")

        XCTAssertEqual(recurringTask.cycleRecurringOccurrence(on: anchor, context: context, calendar: calendar), .missed)
        XCTAssertFalse(recurringBlock.isCompleted, "the mirror is false for anything but .complete — .missed reads the same as .none there")
        XCTAssertEqual(ScheduleReviewViewModel.recurringTaskOccurrenceStatus(task: recurringTask, on: anchor, context: context, calendar: calendar), .missed, "completeCircle(for:) reads this, not the mirror, to render red/missed")

        let ordinaryTask = TaskItem(title: "Ordinary", estimatedMinutes: 30)
        context.insert(ordinaryTask)
        let ordinaryBlock = ScheduledBlock(date: anchor, startTime: anchor, endTime: anchor.addingTimeInterval(1800), task: ordinaryTask)
        context.insert(ordinaryBlock)

        XCTAssertFalse(ordinaryTask.isRecurring, "confirms this task takes completeCircle(for:)'s plain-toggle branch, not the recurring one")
        XCTAssertFalse(ordinaryBlock.isCompleted)
        ordinaryBlock.isCompleted.toggle()
        XCTAssertTrue(ordinaryBlock.isCompleted, "a non-recurring block only ever has this one plain flag — no cycle, no missed state")
    }

    /// Fail-then-pass target #2 ("marking missed from the calendar
    /// creates exactly one push"): replicates the exact sequence
    /// `DayTimelineGridView.cycleRecurringTaskOccurrence` runs when a tap
    /// lands on `.missed` — push, then hop immediately — since that
    /// function is private to a live view and can't be called directly
    /// here. Unlike Nightly Review's own `pushIfMissed` (which tracks
    /// what it created in `immediatelyPushedRecurringOccurrenceIDs` and
    /// defers the hop to its own commit-time `advance()`), the calendar
    /// has no later commit moment to defer to, so the hop happens right
    /// away — this is what distinguishes this test from
    /// `test_missedOccurrence_createsPushedRecurringOccurrence_immediately`
    /// above, which stops at "the record exists."
    ///
    /// Verified fail-then-pass: temporarily changed `PushedRecurringOccurrence
    /// .advanceOneHop` to return immediately without moving `occurrence
    /// .currentDate` — this test failed on the "hopped to tomorrow"
    /// assertion (`currentDate` was still today). Restored and reran:
    /// green. Both via `xcodebuild test`.
    func test_markingMissedFromCalendar_createsExactlyOnePush_andHopsItImmediately() {
        let today = day(2026, 9, 9)
        let task = makeUntimedTask(anchor: today)

        XCTAssertEqual(task.cycleRecurringOccurrence(on: today, context: context, calendar: calendar), .complete)
        XCTAssertEqual(task.cycleRecurringOccurrence(on: today, context: context, calendar: calendar), .missed)

        guard let pushed = ScheduleReviewViewModel.pushRecurringOccurrenceIfNeeded(task: task, missedDay: today, context: context) else {
            return XCTFail("marking missed must create a push")
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        PushedRecurringOccurrence.advanceOneHop(pushed, task: task, from: today, to: tomorrow, calendar: calendar, context: context)

        let allPushes = (try? context.fetch(FetchDescriptor<PushedRecurringOccurrence>())) ?? []
        XCTAssertEqual(allPushes.count, 1, "exactly one push record")
        XCTAssertEqual(calendar.startOfDay(for: allPushes.first!.currentDate), tomorrow, "hopped immediately to tomorrow — the calendar has no later commit step to defer this to the way Nightly Review does")
    }
}
