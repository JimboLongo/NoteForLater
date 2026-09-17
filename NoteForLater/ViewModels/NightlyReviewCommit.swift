import Foundation
import SwiftData

// MARK: - The Nightly Review "Review Schedule" commit

/// What the synchronous half of the commit hands to the asynchronous half.
struct TodayStepCommitHandoff {
    let recurringCompletedTasks: [TaskItem]
    let incompleteTasks: [TaskItem]
    let allFreshRecurringTaskPushes: [(occurrence: PushedRecurringOccurrence, task: TaskItem, missedDay: Date)]
    let frozenAllBlocks: [ScheduledBlock]
}

extension ScheduleReviewViewModel {
    /// **Everything the Nightly Review commits when you leave Review
    /// Schedule**, lifted out of `NightlyReviewView.runEntryEffects` so it
    /// can be tested at all.
    ///
    /// It could not be before: it lived inside a `private` method on a
    /// SwiftUI `View`, unreachable from any test. Neutering the entire
    /// 49-line body left **556/556 passing** — the third time sabotage has
    /// found a side-effect body invisible to a green run (the Recurring
    /// toggle and the habit block-placement arms were the first two), and
    /// extraction was the answer every time.
    ///
    /// Moved verbatim: the body text is unchanged, with captured view state
    /// replaced by parameters *of the same names*. No reordering and no
    /// simplification, so the diff is readable as a move rather than a
    /// rewrite.
    ///
    /// **Split along the boundary that already existed**, rather than an
    /// invented one — the original wrapped its second half in `Task {}`.
    /// This is the synchronous half; `finishTodayStepCommit` is the rest.
    /// That split is what makes "fires exactly once" assertable: this runs
    /// once per session and launches the other once.
    static func commitTodayStep(
        reviewableBlocks: [ScheduledBlock],
        reviewCutoff: Date,
        allBlocks: [ScheduledBlock],
        allTasks: [TaskItem],
        reviewDate: Date,
        immediatelyPushedRecurringOccurrenceIDs: inout Set<UUID>,
        modelContext: ModelContext,
        markUnresolvedHabitOccurrencesAsMissed: () -> Void
    ) -> TodayStepCommitHandoff {
        // REVERSAL/redesign: `.block`/`.meal` taps used to stage into
        // `stagedTodayToggleIDs`/`stagedMealSelectionIDs` and only
        // write here, on commit. They write immediately now, exactly
        // like `.habit`/`.recurringTask` already did — a three-state
        // cycle needs to know which of the three states a row is
        // *actually* in right now to decide what the next tap
        // produces, which a staged pending-flip can't represent for
        // more than two (see `cycleBlockCompletion`/
        // `mealCircleTapped`, both called directly from `todayStep`).
        // Nothing left to replay here.
        //
        // §7.2: this whole batch runs "on Next from the Today step,"
        // i.e. right here on the today→inbox transition, not deferred
        // all the way to the tomorrow handoff below. Freeze exactly
        // what `reviewItems` represented at this exact synchronous
        // moment before anything else (Inbox routing, in particular)
        // can touch it — see `TaskItem.isNightlyReviewed`'s own doc
        // comment for why a live re-derive isn't safe across the
        // async gap below.
        let reviewedBlocks = reviewableBlocks
        let frozenCutoff = reviewCutoff
        let frozenAllBlocks = allBlocks
        for block in reviewedBlocks {
            block.task?.isNightlyReviewed = true
        }
        // Captured now, before `purgeCompletedBlocks` clears each
        // purged block's own `task` reference to nil below — a
        // recurring task survives its block being purged (only a
        // non-recurring one is deleted outright), so it's the one
        // case that needs its stamp explicitly reset afterward.
        let recurringCompletedTasks = reviewedBlocks.filter(\.isCompleted).compactMap(\.task).filter(\.isRecurring)
        let incompleteTasks = reviewedBlocks.filter { !$0.isCompleted }.compactMap(\.task)

        // A recurring task's own missed block just sits there now
        // (nothing deletes it — see `resolveMissedPastBlocks`'s own
        // doc comment), but still needs something to actually push
        // the occurrence forward — that's this call, not
        // `resolveMissedPastBlocks`, which explicitly excludes a
        // recurring task's own block (`task?.isRecurring != true`)
        // since its next placement is this mechanism's job, not
        // `guaranteePlacement`'s. Also covers AM/Midday/PM recurring
        // tasks, which never have a
        // block for the state above to capture in the first place (see
        // `ScheduleReviewViewModel.pushMissedRecurringOccurrences`'s own
        // doc comment). Skips any task that's already being pushed (an
        // earlier miss that hasn't resolved yet) — that record's own
        // `currentDate` already points at today, so there's nothing new
        // to record.
        let freshlyPushedRecurringOccurrences = ScheduleReviewViewModel.pushMissedRecurringOccurrences(
            reviewedBlocks: reviewedBlocks, tasks: allTasks, context: modelContext, cutoff: frozenCutoff
        )
        // Immediate-tap-created pushes (see `pushIfMissed`, fired
        // whenever cycling a habit-style row this step landed on
        // `.missed`) aren't in `freshlyPushedRecurringOccurrences` —
        // that only holds records the sweep call just above created
        // itself. Fetched here by id and folded in below so the
        // hop-forward loop treats both origins identically — without
        // this, a tap-created push would sit at today's date, un-
        // hopped, until the next app launch, silently undoing "pushes
        // immediately." A push a later tap in this same session
        // resolved (cycled back past `.missed` to `.complete`) is
        // deleted here instead of hopped — reusing `isAlreadyResolved`,
        // written for exactly this, rather than a second bespoke check.
        let calendarForPushCleanup = Calendar.current
        let tapPushedRecurringOccurrences: [(occurrence: PushedRecurringOccurrence, task: TaskItem, missedDay: Date)] = immediatelyPushedRecurringOccurrenceIDs.compactMap { id in
            guard let occurrence = (try? modelContext.fetch(FetchDescriptor<PushedRecurringOccurrence>(predicate: #Predicate { $0.id == id })))?.first,
                  let task = allTasks.first(where: { $0.id == occurrence.taskID })
            else { return nil }
            if PushedRecurringOccurrence.isAlreadyResolved(occurrence, task: task, calendar: calendarForPushCleanup, context: modelContext) {
                modelContext.delete(occurrence)
                return nil
            }
            guard calendarForPushCleanup.isDate(occurrence.currentDate, inSameDayAs: occurrence.originalDate) else { return nil }
            return (occurrence, task, occurrence.originalDate)
        }
        immediatelyPushedRecurringOccurrenceIDs = []
        let allFreshRecurringTaskPushes = freshlyPushedRecurringOccurrences + tapPushedRecurringOccurrences

        // Any habit occurrence the Today review showed but never got
        // checked off — timed or not — is done being reviewable the
        // moment Today is left behind, so it's marked missed right
        // here, synchronously, before any of the async cleanup below.
        // Deliberately not folded into `resolveMissedPastBlocks`
        // itself (used here too, just below): a passed-but-undone
        // habit should still get a fresh shot later *today* during an
        // ordinary intra-day Regenerate, not be written off — only
        // Nightly Review's own end-of-day handoff means "no more
        // chances left." (Correcting a stale claim this comment used
        // to make: `resolveMissedPastBlocks` does *not* currently
        // have another caller from any Regenerate flow — grepped while
        // verifying `reviewCutoff`'s widened-cutoff change was safe,
        // confirmed exactly one call site, right below. The design
        // reasoning above still holds regardless — habits and blocks
        // are swept by two genuinely different mechanisms on purpose —
        // it just isn't *currently* enforced by a second caller the
        // way this used to say.)
        markUnresolvedHabitOccurrencesAsMissed()
        // Closes `reviewDate` out for `ScheduleReviewViewModel
        // .autoPlaceEligibleTasks`'s own live auto-place walk — once
        // tonight's review has actually run, today's remaining free
        // hours stop being fair game for a brand-new task to land on,
        // same as if the day had already ended. Set synchronously,
        // right alongside the habit sweep above, not buried in the
        // Task below — this is the moment today is actually closed,
        // not an incidental side effect of the async cleanup.
        NightlyReviewCompletionState.shared.markReviewed(day: reviewDate)
        return TodayStepCommitHandoff(
            recurringCompletedTasks: recurringCompletedTasks,
            incompleteTasks: incompleteTasks,
            allFreshRecurringTaskPushes: allFreshRecurringTaskPushes,
            frozenAllBlocks: frozenAllBlocks
        )
    }

    /// The asynchronous half, previously the body of the `Task {}`.
    ///
    /// Left `async` and *not* wrapped in its own `Task` so a caller can
    /// await it. The view still fires it unstructured, exactly as before —
    /// see the handoff note on that being a latent risk, not fixed here.
    static func finishTodayStepCommit(
        _ handoff: TodayStepCommitHandoff,
        tomorrowViewModel: ScheduleReviewViewModel,
        allShelves: [Shelf],
        allHabits: [Habit],
        eligibleHoursWindows: [EligibleHoursWindow],
        modelContext: ModelContext
    ) async {
        let recurringCompletedTasks = handoff.recurringCompletedTasks
        let incompleteTasks = handoff.incompleteTasks
        let allFreshRecurringTaskPushes = handoff.allFreshRecurringTaskPushes
        let frozenAllBlocks = handoff.frozenAllBlocks
        // Complete → swept from the calendar entirely, same as
        // every other completed block; this is the one place that
        // actually happens (see `purgeCompletedBlocks`) — a plain
        // regenerate leaves a completed block faded in place
        // instead.
        await tomorrowViewModel.purgeCompletedBlocks()
        tomorrowViewModel.purgeCompletedMealSelections()
        // REVERSAL: `resolveIncompleteMealSelections` (deleted an
        // incomplete-and-past meal outright) is gone — with meals
        // now covered by the Today gate (see
        // `unresolvedGateReviewItems`), nothing can reach this
        // point still `.none`; every meal `reviewedBlocks`/
        // `todayMealSelections` showed was already interactively
        // resolved to `.complete` or `.missed` before Next was
        // even enabled. Nothing left here to sweep.
        for task in recurringCompletedTasks {
            task.isNightlyReviewed = false
        }
        // REVERSAL: nothing is deleted from the calendar for a
        // missed block anymore (see `resolveMissedPastBlocks`'s
        // own doc comment) — the interactive cycle
        // (`ScheduleReviewViewModel.cycleBlockCompletion`) already
        // guaranteed a fresh placement the moment each one was
        // tapped to `.missed`, immediately, the same way a
        // recurring task's own miss already pushes immediately
        // (`pushIfMissed`). This call is the same redundant,
        // guarded safety net `pushMissedRecurringOccurrences` is
        // for recurring tasks — it only actually does anything for
        // a block that never went through the interactive cycle
        // at all (the one-time migration backfill).
        tomorrowViewModel.resolveMissedPastBlocks(allBlocks: frozenAllBlocks)
        for task in incompleteTasks {
            task.isNightlyReviewed = false
        }
        // Same guarantee as `guaranteePlacement` above, for a
        // recurring miss: rather than leaving the record it just
        // created sitting at today's date until the next app
        // launch's catch-up walk gets to it
        // (`NoteForLaterApp.processPushedRecurringOccurrencesIfNeeded`),
        // hop it forward one day — onto tomorrow — right now, via
        // the exact function that walk uses per day
        // (`PushedRecurringOccurrence.advanceOneHop`). Only ever
        // one hop, for records created by *this* review — a task
        // whose miss dates further back (the review didn't run for
        // several nights) is still left for that launch-time walk
        // to catch all the way up, deliberately: this Task isn't
        // the place to fast-forward stale backlog.
        let calendar = Calendar.current
        for pushed in allFreshRecurringTaskPushes {
            guard let next = calendar.date(byAdding: .day, value: 1, to: pushed.missedDay) else { continue }
            PushedRecurringOccurrence.advanceOneHop(pushed.occurrence, task: pushed.task, from: pushed.missedDay, to: next, calendar: calendar, context: modelContext)
        }
        // Unconditional — today's (and any prior day's) unfinished
        // tasks were just freed up above, and they need an actual
        // following day to land on. `regenerateFromNow`, not
        // `regenerateSingleDay` (doesn't exist — see §6.3),
        // walking forward until everything schedulable has a real
        // slot. A locked block on a present or future day is
        // never touched by any of this — but a locked *past*
        // incomplete block already was, eleven lines up: §7.3
        // deliberately strips lock protection once a block's own
        // day is over (see `resolveMissedPastBlocks`).
        let completedFully = await tomorrowViewModel.regenerateFromNow(shelves: allShelves, habits: allHabits, eligibleHoursWindows: eligibleHoursWindows)
        if completedFully {
            ScheduleDirtyState.shared.isDirty = false
        }
    }

    /// Marks every still-unresolved habit occurrence missed when the review
    /// commits.
    ///
    /// Extracted from `NightlyReviewView` for the same reason the commit
    /// batch was: it writes user data once a night and **sabotaging it
    /// entirely failed 0 tests**. Moved verbatim — body text unchanged,
    /// captured view state replaced by parameters of the same names.
    static func markUnresolvedHabitOccurrencesAsMissed(
        allBlocks: [ScheduledBlock],
        allHabits: [Habit],
        reviewCutoff: Date,
        reviewDate: Date,
        modelContext: ModelContext,
        habitLog: (Habit, Date) -> HabitLog
    ) {
        // PERMANENT, deliberately — kept when the rest of the
        // duplicate-investigation instrumentation is stripped, for the same
        // reason `DiagFileLog`'s overlap-rejection line is kept.
        //
        // This routine overwrites real user data once a night and leaves no
        // other trace. Without these two counts, "the sweep protected every
        // completion" and "the sweep never ran at all" produce **identical**
        // output — an unchanged miss count — and the first attempt to verify
        // the guard was unfalsifiable for exactly that reason. Every claim
        // ever made about this function before this line existed rested on
        // absence of evidence from a test that had never run.
        //
        // `untimedOccurrences=0` means the run was vacuous and any pass
        // drawn from it is worthless. That is the whole value of the line.
        //
        // Deliberately NOT `reviewableBlocks`/`openHabitOccurrencesForReview`
        // — those are scoped to `reviewDisplayCutoff` (what the step
        // *shows*) rather than `reviewCutoff` (what this sweep *acts* on).
        // The two are computed identically now (see `reviewCutoff`'s own
        // doc comment for why the old `.now`-clamped version got removed —
        // a habit due later tonight is now correctly swept, not protected
        // from it), but this stays reading `reviewCutoff` specifically
        // rather than switching to `reviewDisplayCutoff` directly: they
        // answer different questions that only happen to agree today, and
        // a future divergence between them should change this sweep's
        // behavior by way of `reviewCutoff` actually changing, not
        // silently by way of which property happened to get read here.
        let sweepBlocks = allBlocks.filter { ($0.startTime < reviewCutoff || $0.isCompleted) && $0.habit != nil }
        let sweepOccurrences = ScheduleReviewViewModel.openHabitOccurrencesForReview(
            habits: allHabits,
            context: modelContext,
            upTo: reviewCutoff,
            completedSince: NightlyReviewCompletionState.shared.lastClosedReviewDay
        )
        DiagFileLog.write("SWEEP ENTER reviewDate=\(ISO8601DateFormatter().string(from: reviewDate).prefix(10)) cutoff=\(ISO8601DateFormatter().string(from: reviewCutoff).prefix(19)) habitBlocks=\(sweepBlocks.count) untimedOccurrences=\(sweepOccurrences.count)")
        for block in sweepBlocks {
            guard let habit = block.habit else { continue }
            // The LOG is authoritative; `block.isCompleted` is a mirror
            // written alongside it by every habit-completion path. This
            // loop used to consult only the flag and never the log, so a
            // log saying `.complete` got overwritten with `.missed`
            // whenever the flag had drifted — e.g. `HabitDetailView
            // .setDay`, which writes the log for a whole day and never
            // touches any block.
            //
            // Reading the log also closes the converse (flag `true`, log
            // `.none`, reachable by cycling a day back to unselected in
            // that same calendar): the old flag check skipped those, and
            // nothing else ever swept them, so the occurrence stayed
            // unresolved forever and counted as neither complete nor
            // missed in streak/rolling-30 math.
            //
            // `habitLog(for:on:)` routes through `Habit.logOrCreate`,
            // which FETCHES rather than traversing `habit.logs`, so this
            // sees a pending unsaved completion. Reading it any other way
            // would reintroduce the same blindness one layer up.
            let log = habitLog(habit, block.date)
            let status = log.occurrenceStatus(block.habitOccurrenceIndex)
            guard status == .none else { continue }
            log.setOccurrence(block.habitOccurrenceIndex, to: .missed)
        }
        // **Backlog only, matching the gate.**
        //
        // This used to sweep the review day's own occurrences too, and that
        // was the right call *under the old gate*: nothing could reach the
        // sweep unresolved, because Next was blocked until every occurrence
        // had been answered. Removing that gate invalidates the premise —
        // today's occurrences now routinely arrive here as `.none`, and
        // sweeping them would mark the 10pm habit you're about to do as
        // missed at 9pm. Same call, changed input, not churn.
        //
        // What this costs is small, and smaller than it first looks: an
        // unmarked *past* day already reads as `.no` in
        // `Habit.status(on:asOf:)` without any explicit marker (pinned by
        // `test_unmarkedPastDayCountsAsAMiss_withoutAnExplicitMissedMarker`).
        // So the sweep is **cosmetic correctness, not arithmetic
        // correctness** — it writes the marker the Habits screen draws an
        // icon from. Skipping today costs one evening of a missing icon,
        // and tomorrow's review sweeps it as backlog anyway.
        let reviewDay = Calendar.current.startOfDay(for: reviewDate)
        for occurrence in sweepOccurrences where Calendar.current.startOfDay(for: occurrence.targetTime) < reviewDay {
            let log = habitLog(occurrence.habit, occurrence.targetTime)
            let status = log.occurrenceStatus(occurrence.index)
            guard !occurrence.isCompleted, status == .none else { continue }
            log.setOccurrence(occurrence.index, to: .missed)
        }
        HabitStatsRefreshCoordinator.shared.habitLogsChanged()
    }
}
