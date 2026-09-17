import XCTest
import SwiftData
@testable import NoteForLater

/// Characterization for `ScheduleReviewViewModel.commitTodayStep` — the
/// batch the Nightly Review runs when you leave Review Schedule.
///
/// **These describe what it does today, not what it should do.** The batch
/// shipped with no coverage at all: neutering its entire body left 556/556
/// passing, because it lived inside a private SwiftUI `View` method that no
/// test could reach. It was extracted (3f2d959) specifically so these could
/// exist, which means they were written *after* the move rather than before
/// it — the usual characterize-first order was impossible here, and the
/// window in between was genuinely unverified.
///
/// So: pin the current behaviour, verify by sabotage that the pins catch a
/// break, and only then let anything move.
///
/// ⚠️ Every test constructing `ScheduleReviewViewModel` must be `async` —
/// see the handoff's note on implicitly-`@MainActor` types, or the whole
/// run dies with `Executed 0 tests` and no failing test named.
final class NightlyReviewCommitTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self,
                SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self,
                Habit.self, HabitLog.self, MealSelection.self, Recipe.self,
                PushRecursionWarning.self, TaskCompletionRecord.self, RecurringTaskLog.self,
                PushedRecurringOccurrence.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    private var calendar: Calendar { .current }
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// A block on `reviewDate` with a task behind it.
    @discardableResult
    private func makeBlock(on date: Date, complete: Bool, recurring: Bool = false, title: String = "T") -> ScheduledBlock {
        let shelf = Shelf(name: "Errands")
        context.insert(shelf)
        let task = TaskItem(title: title, shelf: shelf, estimatedMinutes: 30)
        task.isRecurring = recurring
        if recurring {
            task.recurrenceIntervalCount = 1
            task.dueDate = date
        }
        context.insert(task)
        let start = calendar.date(byAdding: .hour, value: 9, to: date)!
        let block = ScheduledBlock(date: date, startTime: start, endTime: start.addingTimeInterval(1800), task: task)
        block.status = complete ? .complete : .none
        context.insert(block)
        return block
    }

    /// Runs the synchronous half with the arguments the view passes.
    @discardableResult
    private func commit(
        reviewed: [ScheduledBlock],
        reviewDate: Date,
        immediatelyPushed: inout Set<UUID>,
        markMissed: () -> Void = {}
    ) throws -> TodayStepCommitHandoff {
        let allTasks = try context.fetch(FetchDescriptor<TaskItem>())
        let allBlocks = try context.fetch(FetchDescriptor<ScheduledBlock>())
        return ScheduleReviewViewModel.commitTodayStep(
            reviewableBlocks: reviewed,
            reviewCutoff: calendar.date(byAdding: .day, value: 1, to: reviewDate)!,
            allBlocks: allBlocks,
            allTasks: allTasks,
            reviewDate: reviewDate,
            immediatelyPushedRecurringOccurrenceIDs: &immediatelyPushed,
            modelContext: context,
            markUnresolvedHabitOccurrencesAsMissed: markMissed
        )
    }

    // MARK: - The stamp

    /// Every reviewed block's task is stamped `isNightlyReviewed`. That flag
    /// is what tells the rest of the app "this was just looked at", and the
    /// async half clears it again — so the stamp existing at the end of the
    /// *synchronous* half is the contract.
    func test_stampsEveryReviewedBlocksTask() throws {
        let reviewDate = day(2026, 1, 5)
        let done = makeBlock(on: reviewDate, complete: true, title: "Done")
        let open = makeBlock(on: reviewDate, complete: false, title: "Open")
        try context.save()

        var pushed: Set<UUID> = []
        _ = try commit(reviewed: [done, open], reviewDate: reviewDate, immediatelyPushed: &pushed)

        XCTAssertTrue(try XCTUnwrap(done.task).isNightlyReviewed)
        XCTAssertTrue(try XCTUnwrap(open.task).isNightlyReviewed)
    }

    /// A block *not* in the reviewed set is untouched — the batch acts on
    /// the frozen list it was handed, not on everything in the store.
    func test_leavesUnreviewedBlocksAlone() throws {
        let reviewDate = day(2026, 1, 5)
        let reviewed = makeBlock(on: reviewDate, complete: false, title: "In")
        let untouched = makeBlock(on: reviewDate, complete: false, title: "Out")
        try context.save()

        var pushed: Set<UUID> = []
        _ = try commit(reviewed: [reviewed], reviewDate: reviewDate, immediatelyPushed: &pushed)

        XCTAssertTrue(try XCTUnwrap(reviewed.task).isNightlyReviewed)
        XCTAssertFalse(try XCTUnwrap(untouched.task).isNightlyReviewed, "not in the frozen set")
    }

    // MARK: - The handoff split

    /// The handoff partitions reviewed blocks the way the async half needs:
    /// completed *recurring* tasks (whose stamp it resets by hand, since a
    /// recurring task survives its block being purged) and incomplete tasks.
    func test_handoffPartitionsCompletedRecurringFromIncomplete() throws {
        let reviewDate = day(2026, 1, 5)
        let completedRecurring = makeBlock(on: reviewDate, complete: true, recurring: true, title: "Recurring done")
        let completedPlain = makeBlock(on: reviewDate, complete: true, title: "Plain done")
        let incomplete = makeBlock(on: reviewDate, complete: false, title: "Not done")
        try context.save()

        var pushed: Set<UUID> = []
        let handoff = try commit(
            reviewed: [completedRecurring, completedPlain, incomplete],
            reviewDate: reviewDate, immediatelyPushed: &pushed
        )

        XCTAssertEqual(handoff.recurringCompletedTasks.map(\.title), ["Recurring done"],
                       "only completed *recurring* tasks — a completed plain one is deleted outright later")
        XCTAssertEqual(handoff.incompleteTasks.map(\.title), ["Not done"])
    }

    /// `frozenAllBlocks` is the store's blocks as of this moment, handed
    /// forward so the async half's `resolveMissedPastBlocks` can't see
    /// anything created after the commit started.
    func test_handoffCarriesTheFrozenBlockList() throws {
        let reviewDate = day(2026, 1, 5)
        let block = makeBlock(on: reviewDate, complete: false)
        try context.save()

        var pushed: Set<UUID> = []
        let handoff = try commit(reviewed: [block], reviewDate: reviewDate, immediatelyPushed: &pushed)

        XCTAssertEqual(handoff.frozenAllBlocks.count, 1)
    }

    // MARK: - The tap-pushed cleanup

    /// An occurrence pushed by tapping during the step is drained from the
    /// pending set — the set is emptied whatever happens, so a second commit
    /// can't reprocess it.
    func test_drainsTheImmediatelyPushedSet() throws {
        let reviewDate = day(2026, 1, 5)
        let block = makeBlock(on: reviewDate, complete: false)
        let task = try XCTUnwrap(block.task)
        let occurrence = PushedRecurringOccurrence(taskID: task.id, originalDate: reviewDate)
        context.insert(occurrence)
        try context.save()

        var pushed: Set<UUID> = [occurrence.id]
        _ = try commit(reviewed: [block], reviewDate: reviewDate, immediatelyPushed: &pushed)

        XCTAssertTrue(pushed.isEmpty, "drained, so a re-entry can't double-process it")
    }

    /// The habit sweep is invoked — passed in as a closure because it lives
    /// on the view. Pinned because it is the one piece of the batch with no
    /// observable result of its own here.
    func test_callsTheHabitSweepExactlyOnce() throws {
        let reviewDate = day(2026, 1, 5)
        let block = makeBlock(on: reviewDate, complete: false)
        try context.save()

        var calls = 0
        var pushed: Set<UUID> = []
        _ = try commit(reviewed: [block], reviewDate: reviewDate, immediatelyPushed: &pushed, markMissed: { calls += 1 })

        XCTAssertEqual(calls, 1)
    }

    /// Closing the day out is what stops already-reviewed work reappearing
    /// tomorrow. Runs even when nothing was reviewed.
    func test_marksTheReviewDayClosed_evenWithNothingReviewed() throws {
        let reviewDate = day(2026, 1, 5)
        var pushed: Set<UUID> = []
        _ = try commit(reviewed: [], reviewDate: reviewDate, immediatelyPushed: &pushed)

        XCTAssertEqual(
            NightlyReviewCompletionState.shared.lastClosedReviewDay.map { calendar.startOfDay(for: $0) },
            calendar.startOfDay(for: reviewDate)
        )
    }

    // MARK: - The trigger: which edge fires it

    /// **The re-anchor, pinned.** The commit is keyed to *leaving* Review
    /// Schedule, not to arriving at Inbox.
    ///
    /// Those were the same edge until the reorder put Inbox first — and the
    /// old code keyed on arrival while its own comment said it meant
    /// departure ("this whole batch runs 'on Next from the Today step'").
    /// Keying on departure also makes it survive the next reorder.
    func test_commitFiresOnLeavingReviewSchedule_notOnEnteringInbox() {
        XCTAssertEqual(NightlyReviewView.Step.today.exitEffect, .commitReviewSchedule)
        for step in NightlyReviewView.Step.allCases where step != .today {
            XCTAssertNil(step.exitEffect, "\(step) must not commit")
        }
    }

    /// ⚠️ **What these two tests do NOT cover: the wiring.**
    ///
    /// They pin which step *declares* the commit. They cannot see whether
    /// `advance()` actually calls `runExitEffects` — deleting that one line
    /// so the batch never fires at all is caught by **nothing** (verified by
    /// sabotage: 0 failures).
    ///
    /// Same shape as the `CardRow`-vs-render drift: the rule is asserted,
    /// the code that consumes the rule is not, and the failure shows up as
    /// something that silently stops happening. It survives here because
    /// `advance()` is a private method on a SwiftUI `View`, the same
    /// unreachability that left the batch itself uncovered until 3f2d959.
    ///
    /// Closing it means extracting the step-transition logic the way the
    /// batch itself was extracted — `StepAutoSkip.walkForward` is already a
    /// testable free function, so the seam exists. Not done here: that is a
    /// second extraction, and this change is already anchored on one.
    ///
    /// `back()` must never re-commit. It passes `onEnter: { _ in }` and
    /// never calls the exit hook, so stepping back into Review Schedule and
    /// forward again fires the batch a second time *by design of the
    /// view* — which is why the batch itself is also re-entry safe below.
    func test_onlyForwardNavigationHasAnExitEffect() {
        XCTAssertTrue(NightlyReviewView.Step.exitEffectsRunOnAdvanceOnly)
    }

    // MARK: - Runs once

    /// **The property the re-anchoring has to preserve.** Running the batch
    /// twice against the same reviewed set must not double-push or
    /// double-drain — the second pass finds the set already empty and the
    /// occurrences already resolved.
    ///
    /// The view protects this structurally (`back()` passes
    /// `onEnter: { _ in }`, so reversing into a step never re-runs entry
    /// effects), but that is a reading of the view, not a property of the
    /// batch. This asserts the batch itself is safe if it ever is re-entered.
    func test_runningTwice_doesNotDoublePush() throws {
        let reviewDate = day(2026, 1, 5)
        let block = makeBlock(on: reviewDate, complete: false)
        let task = try XCTUnwrap(block.task)
        let occurrence = PushedRecurringOccurrence(taskID: task.id, originalDate: reviewDate)
        context.insert(occurrence)
        try context.save()

        var pushed: Set<UUID> = [occurrence.id]
        _ = try commit(reviewed: [block], reviewDate: reviewDate, immediatelyPushed: &pushed)
        let afterFirst = try context.fetch(FetchDescriptor<PushedRecurringOccurrence>()).count

        _ = try commit(reviewed: [block], reviewDate: reviewDate, immediatelyPushed: &pushed)
        let afterSecond = try context.fetch(FetchDescriptor<PushedRecurringOccurrence>()).count

        XCTAssertEqual(afterSecond, afterFirst, "a second pass must not create more pushes")
        XCTAssertTrue(pushed.isEmpty)
    }

    // MARK: - The habit-miss sweep (characterization)

    private func makeHabit(name: String, startDate: Date, mode: HabitOccurrenceTimeMode = .am) -> Habit {
        let habit = Habit(name: name, startDate: startDate, reminderTimesOfDay: [9 * 60])
        habit.occurrenceTimeModesRaw = [mode.rawValue]
        context.insert(habit)
        return habit
    }

    private func sweep(habits: [Habit], reviewDate: Date) throws {
        ScheduleReviewViewModel.markUnresolvedHabitOccurrencesAsMissed(
            allBlocks: try context.fetch(FetchDescriptor<ScheduledBlock>()),
            allHabits: habits,
            reviewCutoff: ScheduleReviewViewModel.nightlyReviewOperationalCutoff(reviewDate: reviewDate),
            reviewDate: reviewDate,
            modelContext: context,
            habitLog: { habit, date in habit.logOrCreate(on: date, context: self.context) }
        )
    }

    /// An untimed occurrence left unmarked on a day before the review date
    /// is swept to `.missed`. This is the sweep's core job.
    func test_sweepMarksUnresolvedBacklogOccurrenceMissed() throws {
        let reviewDate = day(2026, 1, 5)
        let habit = makeHabit(name: "Stretch", startDate: day(2026, 1, 1))
        try context.save()

        try sweep(habits: [habit], reviewDate: reviewDate)

        let log = habit.logOrCreate(on: day(2026, 1, 4), context: context)
        XCTAssertEqual(log.occurrenceStatus(0), .missed)
    }

    /// An already-answered occurrence is never overwritten — completing
    /// something and then committing must not turn it into a miss.
    ///
    /// ⚠️ **This pins the behaviour, not the guard.** Removing the sweep's
    /// own `guard !occurrence.isCompleted, status == .none` fails nothing,
    /// because `openHabitOccurrencesForReview` already filters to `.none`
    /// (plus `alsoInclude`/`completedRecently`) before the loop sees
    /// anything — so a completion never reaches the guard. The guard is
    /// defence-in-depth behind that filter, and this test is genuinely
    /// covering the filter. Stated so the next person doesn't read a
    /// passing test as proof the guard itself is load-bearing.
    func test_sweepNeverOverwritesACompletion() throws {
        let reviewDate = day(2026, 1, 5)
        let habit = makeHabit(name: "Stretch", startDate: day(2026, 1, 1))
        let earlier = day(2026, 1, 4)
        let log = habit.logOrCreate(on: earlier, context: context)
        log.setOccurrence(0, to: .complete)
        try context.save()

        try sweep(habits: [habit], reviewDate: reviewDate)

        XCTAssertEqual(habit.logOrCreate(on: earlier, context: context).occurrenceStatus(0), .complete)
    }

    /// A habit block whose log says complete is likewise left alone — the
    /// log is authoritative, the block's flag is only a mirror.
    func test_sweepReadsTheLogNotTheBlockFlag() throws {
        let reviewDate = day(2026, 1, 5)
        let earlier = day(2026, 1, 4)
        let habit = makeHabit(name: "Stretch", startDate: day(2026, 1, 1), mode: .specific)
        let start = calendar.date(byAdding: .hour, value: 9, to: earlier)!
        let block = ScheduledBlock(date: earlier, startTime: start, endTime: start.addingTimeInterval(900), task: nil, habit: habit)
        block.status = .none          // flag says not done...
        context.insert(block)
        habit.logOrCreate(on: earlier, context: context).setOccurrence(0, to: .complete)   // ...log says done
        try context.save()

        try sweep(habits: [habit], reviewDate: reviewDate)

        XCTAssertEqual(habit.logOrCreate(on: earlier, context: context).occurrenceStatus(0), .complete,
                       "the log wins — a drifted block flag must not destroy a completion")
    }
}
