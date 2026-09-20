import Foundation
import SwiftData
import Observation

/// Drives the schedule review screen for a single day (default: today, but
/// navigable to any day) and every interaction the user has with a block:
/// delete (swipe left), auto-replace (swipe right), long-press to manually
/// replace, and — on today specifically — mark complete or push to another
/// day.
/// Why a task the walk finished without placing didn't fit.
///
/// Distinct from `SchedulingFitStatus`, which is a *static* judgment about
/// a rule's own caps and whose `.exceedsConstraint` case is deliberately
/// excluded from this list (that's the At-Risk path). Every task reaching
/// here already returns `.fits`: it could be placed in principle, but no
/// day inside the walk's horizon actually had room.
///
/// Derived in the fixed priority order the cases are listed in, so the
/// result is deterministic when several apply at once. The order runs
/// from most specific and directly measured to least: `.ruleBudgetFull`
/// is last because it is the only one inferred *by elimination* rather
/// than measured — the walk saw eligible days with usable free time and
/// still placed nothing, so the rule's own caps are what's left. Anything
/// measurable has to be ruled out before falling back to it.
enum UnplacedReason {
    /// The task has no schedulable time left — either it was never given
    /// a duration, or its `remainingMinutes` drained to zero without
    /// blocks to account for it. Either way `canEverFit` returns
    /// `.needsDuration` rather than `.fits`, which drops the task out of
    /// the scheduler's candidate pool *and* out of every "why didn't this
    /// get scheduled" list, so nothing surfaces it at all.
    ///
    /// First in priority: it's a directly measured configuration fact,
    /// not something inferred from what the walk did or didn't see, so it
    /// has to be checked before any derived reason. It's also the only
    /// case here where the task never even reached the packer.
    case needsDuration
    /// The rule's window never applied on any day in the horizon.
    case noEligibleDays
    /// The rule applied on only a handful of days — a rare-window rule.
    /// Separate from `.noEligibleDays` because the fix differs: widening
    /// an existing window versus it never coming up at all.
    case fewEligibleDays
    /// Eligible days existed but were completely booked.
    case noFreeTime
    /// Free time existed but no single stretch was long enough for one
    /// whole segment (or the whole task, if it isn't divisible).
    case noContiguousSlot
    /// Viable days probably remained — the walk stopped at `maxWalkDays`.
    case horizonReached
    /// Inferred by elimination: eligible days with usable free time, yet
    /// nothing placed, so the rule's task-count/duration caps were
    /// consumed by other tasks.
    ///
    /// **Believed unreachable in practice, and deliberately kept anyway.**
    /// A rule's budget resets each day, so for this to be the standing
    /// explanation something must consume it on *every* day of the walk.
    /// Only `pack()` spends that budget, and `pack()` excludes recurring
    /// tasks (`AISchedulingService.swift:168`) — so the consumption has to
    /// come from ordinary tasks placing repeatedly, which resets the stall
    /// counter, which runs the walk to `maxWalkDays`, which makes
    /// `.horizonReached` true and claims the case first. No fixture could
    /// be built that reaches this branch through the public API, so it has
    /// no test; the alternative was contriving one that asserted something
    /// other than what it claimed. It stays because the derivation needs a
    /// total fallback and "no reason at all" would be worse — but if you
    /// ever see it in the UI, that itself is the finding: something about
    /// budget accounting or walk termination has changed.
    case ruleBudgetFull
}

/// A task the walk couldn't place, with the reason and the numbers behind
/// it, so the UI can say something specific rather than restating an enum.
struct UnplacedTask: Identifiable {
    let task: TaskItem
    let reason: UnplacedReason
    /// The rule this was judged against — whichever of the task's
    /// eligible rules came up on the most days, i.e. the one that had the
    /// best chance and still didn't manage it.
    let rule: SchedulingRule?
    let eligibleDayCount: Int
    let totalFreeMinutes: Int
    let maxContiguousSlotMinutes: Int
    /// One whole segment for a divisible task, otherwise the whole thing.
    let requiredMinutes: Int

    var id: UUID { task.id }

    private var ruleName: String {
        guard let rule else { return "its schedule" }
        return rule.displayName.isEmpty ? rule.summary : rule.displayName
    }

    /// A plain sentence naming the rule and the actual numbers.
    var explanation: String {
        switch reason {
        case .needsDuration:
            // Same enum case, two genuinely different situations — and
            // they need different sentences because they need different
            // actions from the user. `estimatedMinutes` is what tells
            // them apart: zero means nobody ever set a duration, non-zero
            // means one was set and the remaining time has since drained
            // away without the task being finished.
            if task.estimatedMinutes <= 0 {
                return "No duration set, so the scheduler has nothing to place."
            }
            let placed = TaskItem.durationLabel(for: max(task.estimatedMinutes - task.remainingMinutes, 0))
            return "Set to \(TaskItem.durationLabel(for: task.estimatedMinutes)) but has no time left to schedule (\(placed) accounted for), and it isn't marked done."
        case .noEligibleDays:
            return "\(ruleName) never came up in the days checked."
        case .fewEligibleDays:
            return "\(ruleName) only came up on \(eligibleDayCount) day\(eligibleDayCount == 1 ? "" : "s"), and \(eligibleDayCount == 1 ? "it was" : "they were") already taken."
        case .noFreeTime:
            return "\(ruleName) came up on \(eligibleDayCount) days, all of them fully booked."
        case .noContiguousSlot:
            return "Needs \(TaskItem.durationLabel(for: requiredMinutes)) in one stretch, but the longest opening under \(ruleName) was \(TaskItem.durationLabel(for: maxContiguousSlotMinutes))."
        case .horizonReached:
            return "Ran out of days to check before this fit under \(ruleName)."
        case .ruleBudgetFull:
            return "\(ruleName) had room in the day but its own limits were already used up by other tasks."
        }
    }

    /// What the user can actually do about it.
    var suggestedAction: String {
        switch reason {
        case .needsDuration:
            return task.estimatedMinutes <= 0
                ? "Set a duration on this task."
                : "Mark it done if it's finished, or reset its duration to reschedule the rest."
        case .noEligibleDays, .fewEligibleDays:
            return "Widen this schedule's days or hours."
        case .noFreeTime:
            return "Your calendar is full during this window."
        case .noContiguousSlot:
            return task.isEffectivelyDivisible
                ? "Lower this task's minimum segment size."
                : "Make this task divisible, or shorten it."
        case .horizonReached:
            return "Nothing is misconfigured — this is a capacity limit."
        case .ruleBudgetFull:
            return "Raise this schedule's task or time limit, or reprioritize."
        }
    }
}

@Observable
final class ScheduleReviewViewModel {
    private let modelContext: ModelContext
    private let calendarService: CalendarServiceProtocol
    private let schedulingService: AISchedulingServiceProtocol

    private(set) var blocks: [ScheduledBlock] = []
    private(set) var calendarEvents: [CalendarEventSummary] = []
    var targetDate: Date
    var isGenerating = false
    var errorMessage: String?
    /// How many days the most recent `autoPlaceEligibleTasks` /
    /// `regenerateFromNow` walk actually visited.
    ///
    /// Exists for tests. Before batching, a test could prove stall
    /// detection had stopped the walk by counting the fake's per-day
    /// `fetchFreeSlots` calls — one call per day visited made the call
    /// count a faithful proxy for walk length. Batching destroys that
    /// proxy: the walk now issues exactly one ranged call covering a
    /// fixed `freeSlotPrefetchDays` window no matter where it actually
    /// stops, so network-call counts can no longer distinguish a walk
    /// that halted at day 14 from one that ran to day 30. This records
    /// the thing that test actually cared about, directly.
    private(set) var lastWalkDayCount = 0

    /// Tail of the chain of walks on **this** view model. Each new walk
    /// awaits the previous one before starting, so two can never read the
    /// same day's free slots and both place into it.
    ///
    /// Waiting rather than dropping, deliberately. A dropped sync would
    /// mean a day-swipe silently places nothing — a worse and much more
    /// confusing bug than the one being fixed, and invisible until someone
    /// noticed an empty day.
    ///
    /// **Per-instance only, and that is a known limitation rather than an
    /// oversight.** `NightlyReviewView` builds its own separate
    /// `ScheduleReviewViewModel` (`tomorrowViewModel`), which this chain
    /// cannot serialize against. It's left that way because the captured
    /// reproduction showed all 51 walk runs — and all 10 overlapping
    /// pairs — on a single instance, so cross-instance contention is
    /// unproven rather than shown to be harmless. Serializing across
    /// instances needs shared state (an actor or a singleton), which is a
    /// heavier change than the evidence currently justifies. The overlap
    /// invariant at insertion (`insertSchedulerBlock`) is the backstop
    /// that covers it regardless of which instance places the block.
    private var walkChain: Task<Void, Never>?

    /// Runs `body` after whatever walk is already in flight on this
    /// instance, and doesn't return until `body` itself has finished.
    private func serializingWalk(_ body: @escaping @MainActor () async -> Void) async {
        let previous = walkChain
        let task = Task { @MainActor in
            await previous?.value
            await body()
        }
        walkChain = task
        await task.value
    }

    /// Short per-instance tag, included in the overlap-rejection log so
    /// a rejection can be attributed to a specific view model — the
    /// cross-instance case `walkChain` can't serialize (see its doc
    /// comment) is exactly the one most likely to produce one.
    private let instanceTag = String(UUID().uuidString.prefix(4))
    /// Tasks the most recent walk finished without managing to place —
    /// still unscheduled, still eligible for an enabled rule, still able
    /// to fit one in principle, but no day inside the walk's horizon had
    /// room. Surfaced rather than buried: the alternative (what shipped
    /// before) was to keep crawling forward until the task finally fit,
    /// which put blocks ~1046 days out where they're functionally
    /// invisible.
    private(set) var tasksThatDidNotFit: [UnplacedTask] = []

    /// Per-rule tallies gathered as a walk runs, purely so a reason can be
    /// derived afterwards. Deliberately assembled out here rather than
    /// threaded through `AISchedulingService.pack()`: that would mean
    /// changing the packer's return signature to report per-day outcomes,
    /// which is the invasive version of this feature. Nothing here reads
    /// the packer's internals or affects placement in any way.
    private struct RuleWalkStats {
        var eligibleDayCount = 0
        var totalFreeMinutes = 0
        var maxContiguousSlotMinutes = 0
    }

    init(
        modelContext: ModelContext,
        calendarService: CalendarServiceProtocol,
        schedulingService: AISchedulingServiceProtocol,
        targetDate: Date = .now
    ) {
        self.modelContext = modelContext
        self.calendarService = calendarService
        self.schedulingService = schedulingService
        self.targetDate = targetDate
    }

    // MARK: - Generation (the nightly job)

    /// Builds tomorrow's proposed schedule from each shelf's SchedulingRules
    /// + free calendar slots. Called automatically each night (see
    /// NoteForLaterApp / TODO for BackgroundTasks wiring) and manually via
    /// a "Regenerate" button.
    func generateProposedSchedule(shelves: [Shelf], habits: [Habit], eligibleHoursWindows: [EligibleHoursWindow]) async {
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }

        // Generating always clears out anything left over from a day
        // before today first — see `clearBlocksBeforeToday`.
        await clearBlocksBeforeToday()

        // Resync against the calendar first so generation (and the events
        // shown alongside it) reflect anything added/changed since this
        // screen last loaded, rather than possibly-stale free/busy data.
        await loadCalendarEvents()

        do {
            let freeSlots = try await calendarService.fetchFreeSlots(for: targetDate)
            let proposed = try await schedulingService.generateProposedSchedule(
                shelves: shelves,
                habits: habits,
                freeSlots: freeSlots,
                eligibleHoursWindows: eligibleHoursWindows,
                date: targetDate,
                existingBlocks: blocks,
                context: modelContext
            )
            // The scheduler itself decides per-task whether to mark it fully
            // scheduled or just trim its remaining time (divisible tasks
            // that only got part of their time placed stay unscheduled).
            for block in proposed {
                insertSchedulerBlock(block, site: "generateProposedSchedule")
            }
            blocks = proposed.sorted { $0.startTime < $1.startTime }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Keeps `targetDate` fully populated — habits, the Recurring Tasks
    /// shelf's own tasks (see `Shelf.isRecurringTasks`), *and* every other
    /// shelf's rule-eligible tasks — without the user ever tapping
    /// Generate/Regenerate. The calendar is meant to always reflect what
    /// the current shelves/rules say should be there, live, the same way
    /// it's always reflected a habit's own target time — Generate/
    /// Regenerate no longer exists as its own concept; Nightly Review's
    /// end-of-day handoff (`regenerateFromNow`, via `NightlyReviewView
    /// .advance()`) is just the "review and re-optimize what's already
    /// there" action now, not the only way a day ever gets anything on it
    /// in the first place. Still fully governed by each
    /// shelf's own SchedulingRules (window, days, fill strategy), and only
    /// ever places a task a shelf's rule actually applies to — see
    /// `AISchedulingServiceProtocol.generateProposedSchedule`'s doc
    /// comment.
    ///
    /// Purely additive — inserts new blocks but never clears, moves, or
    /// re-optimizes what's already on a day (that's still
    /// `regenerateFromNow`'s job) — so it's safe
    /// (and idempotent) to call every time this screen appears or the
    /// viewed day changes: a task already `isScheduled`, or a habit/
    /// recurring occurrence that already has a block for the day, is
    /// simply skipped by the scheduler itself.
    ///
    /// Walks forward day by day starting at `targetDate`, same as
    /// `regenerateFromNow`'s own walk, for exactly as long as
    /// `hasRemainingSchedulableWork` says there's still a real,
    /// eligible-and-fittable task left unplaced anywhere — so a backlog
    /// that can't all fit in one day's rule windows keeps spilling
    /// forward onto the next day, and the next, until every task that
    /// *can* be scheduled *is*, without the user ever having to manually
    /// flip through each future day themselves. A task that can never
    /// fit any rule it's eligible for is already excluded from that
    /// check (see its own doc comment), so it's never what keeps this
    /// walking — only real, placeable backlog is, bounded by
    /// `taskStallThresholdDays` rather than a flat day-count cap (see
    /// its own doc comment, and §6.4).
    ///
    /// Every block already on a given day (task or habit, proposed or
    /// approved) has its time carved out of that day's `freeSlots`
    /// manually first — real Google free/busy has no idea about a block
    /// that hasn't been approved and pushed yet, and since this pass
    /// never clears anything to make room, skipping that carve-out would
    /// be free to hand that same slot to some other task entirely. Never
    /// touches a day already in the past, and — once tonight's Nightly
    /// Review has closed today out (see `NightlyReviewCompletionState`)
    /// — never touches today's remaining hours either, starting the walk
    /// at tomorrow instead; "today is over" the moment the review ran,
    /// not just at midnight. Fails silently — a background top-up
    /// erroring out shouldn't pop an alert over a screen the user didn't
    /// ask to regenerate. The 2-Minute Task shelf's tasks are
    /// deliberately never placed here — see
    /// `ScheduleReviewView.twoMinuteTasksSection`, an untimed checklist
    /// instead of a calendar block.
    func autoPlaceEligibleTasks(shelves: [Shelf], habits: [Habit], eligibleHoursWindows: [EligibleHoursWindow]) async {
        await serializingWalk { [self] in
            await performAutoPlaceEligibleTasks(shelves: shelves, habits: habits, eligibleHoursWindows: eligibleHoursWindows)
        }
    }

    private func performAutoPlaceEligibleTasks(shelves: [Shelf], habits: [Habit], eligibleHoursWindows: [EligibleHoursWindow]) async {
        guard targetDate >= Calendar.current.startOfDay(for: .now) else { return }
        removeStaleNonSpecificHabitBlocksAcrossFutureDays()
        trimOverflowingRuleBlocksAcrossFutureDays(shelves: shelves)

        let calendar = Calendar.current
        var cursorDay = calendar.startOfDay(for: targetDate)
        // Once tonight's Nightly Review has actually closed today out
        // (see `NightlyReviewCompletionState`), today's remaining free
        // hours stop being fair game for this walk to hand a brand-new
        // task — "today is over" the moment the review ran, not just at
        // midnight. Only ever bumps the *starting* day forward by one;
        // a day already further out than today is completely unaffected.
        if calendar.isDateInToday(cursorDay), NightlyReviewCompletionState.shared.isClosed(day: .now) {
            cursorDay = calendar.date(byAdding: .day, value: 1, to: cursorDay) ?? cursorDay
        }
        var dayIndex = 0
        var allBlocksNow = (try? modelContext.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        var anyInserted = false
        // See `taskStallThresholdDays` — bounds the walk without a flat
        // day-count cap. Reset to 0 any day that places at least one
        // task block, incremented otherwise.
        var consecutiveDaysWithoutTaskPlacement = 0
        var ruleStats: [UUID: RuleWalkStats] = [:]
        // One ranged call up front instead of one per iteration below.
        // Days past this window (rare — see `freeSlotPrefetchDays`) fall
        // through to the per-day call, preserving the `try?`/`break`
        // handling this loop already had.
        let prefetched = await prefetchFreeSlots(from: cursorDay, days: Self.freeSlotPrefetchDays)

        while dayIndex < Self.maxWalkDays
            && (dayIndex == 0 || (consecutiveDaysWithoutTaskPlacement < Self.taskStallThresholdDays && hasRemainingSchedulableWork(shelves: shelves))) {
            let resolvedSlots: [TimeSlot]?
            if let cached = prefetched[calendar.startOfDay(for: cursorDay)] {
                resolvedSlots = cached
            } else {
                resolvedSlots = try? await calendarService.fetchFreeSlots(for: cursorDay)
            }
            guard var freeSlots = resolvedSlots else { break }
            let dayBlocks = allBlocksNow.filter { calendar.isDate($0.date, inSameDayAs: cursorDay) }
            for existing in dayBlocks {
                freeSlots = subtracting(existing.startTime..<existing.endTime, from: freeSlots)
            }
            // Tallied from the post-subtraction slots — what's genuinely
            // still open, not what the calendar reported before existing
            // blocks were accounted for.
            accumulateRuleStats(&ruleStats, shelves: shelves, day: cursorDay, freeSlots: freeSlots, calendar: calendar)
            var placedTaskBlockToday = false
            if let newBlocks = try? await schedulingService.generateProposedSchedule(
                shelves: shelves,
                habits: habits,
                freeSlots: freeSlots,
                eligibleHoursWindows: eligibleHoursWindows,
                date: cursorDay,
                existingBlocks: dayBlocks,
                context: modelContext
            ), !newBlocks.isEmpty {
                // Only blocks the overlap invariant actually accepted
                // count from here on — a rejected one was never inserted,
                // so treating it as placed would both mark the day as
                // progress (resetting the stall counter) and show a block
                // in the UI that isn't in the store.
                let insertedBlocks = newBlocks.filter { insertSchedulerBlock($0, site: "autoPlaceEligibleTasks") }
                allBlocksNow += insertedBlocks
                anyInserted = anyInserted || !insertedBlocks.isEmpty
                // Recurring tasks are excluded deliberately. This counter
                // measures whether the *backlog* is making progress, and
                // a recurring task places itself on every occurrence day
                // whether or not anything is stuck — its `isScheduled` is
                // never set (see `AISchedulingService
                // .placeHabitsAndRecurringTasks`), so it's re-placed
                // forever. Counting it as progress made the counter
                // measure recurrence frequency instead: a *weekly*
                // recurrence reset it every 7th day, so it could never
                // climb to `taskStallThresholdDays` and stall detection
                // could never fire. The walk then ran until
                // `hasRemainingSchedulableWork` went false, which for a
                // task that fits nowhere nearby meant crawling ~1046 days
                // to the first day it happened to fit.
                placedTaskBlockToday = insertedBlocks.contains { $0.task != nil && !($0.task?.isRecurring ?? false) }
                if calendar.isDate(cursorDay, inSameDayAs: targetDate) {
                    blocks = (blocks + insertedBlocks).sorted { $0.startTime < $1.startTime }
                }
            }
            consecutiveDaysWithoutTaskPlacement = placedTaskBlockToday ? 0 : consecutiveDaysWithoutTaskPlacement + 1
            cursorDay = calendar.date(byAdding: .day, value: 1, to: cursorDay) ?? cursorDay
            dayIndex += 1
        }
        lastWalkDayCount = dayIndex
        // Empty whenever the walk stopped because the backlog genuinely
        // ran out; non-empty only when it stopped on the stall counter or
        // `maxWalkDays` with work still outstanding.
        tasksThatDidNotFit = unplacedTasks(shelves: shelves, stats: ruleStats, hitHorizon: dayIndex >= Self.maxWalkDays)

        if anyInserted {
            try? modelContext.save()
        }
    }

    /// Self-healing sweep across every day, today forward — not just
    /// `targetDate`: an occurrence whose mode isn't (or no longer is)
    /// Specific Time should never have a `ScheduledBlock` at all (see
    /// `AISchedulingService.placeHabitsAndRecurringTasks`'s own guard on
    /// `HabitOccurrenceTimeMode`), but one changed away from Specific
    /// Time before `HabitEditView.removeStaleBlocks` existed to clean up
    /// after it can still have a block left over from back then. Scoping
    /// this to only `targetDate` used to mean a future day nobody had
    /// actually flipped to yet — including one only ever glanced at
    /// through `WeekTimelineView`, which reads `ScheduledBlock`s straight
    /// from the store with no cleanup pass of its own — kept showing a
    /// habit that had already stopped being Specific Time, right up until
    /// the day it actually became `targetDate`. Same scope as
    /// `removeStaleBlocks` itself otherwise: only a not-yet-completed
    /// block, never a past or already-resolved one, so nothing about a
    /// day's actual history changes.
    ///
    /// Also covers a recurring `TaskItem` switched away from Specific
    /// Time (see `TaskItem.recurrenceTimeMode`) — unlike habits, a
    /// recurring task's time mode has no dedicated editor of its own with
    /// an equivalent immediate `removeStaleBlocks` call on save (it's
    /// edited live, on the task card, with no single "Save" moment to
    /// hook), so this broader sweep is the *only* place a stale recurring
    /// task block ever gets cleaned up, not just a backstop for it.
    private func removeStaleNonSpecificHabitBlocksAcrossFutureDays() {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: .now)
        let allBlocksNow = (try? modelContext.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        let stale = allBlocksNow.filter { block in
            guard block.date >= startOfToday, !block.isCompleted else { return false }
            if let habit = block.habit {
                return habit.timeMode(for: block.habitOccurrenceIndex) != .specific
            }
            // KEPT, not deleted, and deliberately widened from
            // `task.recurrenceTimeMode != .specific` to plain
            // `task.isRecurring`. Those are now the same set — a recurring
            // task can't be Specific Time — so this is a simplification,
            // not a behavior change.
            //
            // It survives stage 4b because it isn't dead: no recurring task
            // should ever have a future incomplete block again, and this is
            // the only sweep that cleans one up if one somehow appears. The
            // migration handles the blocks that exist today; this handles
            // anything that slips through afterwards.
            if let task = block.task, task.isRecurring {
                return true
            }
            return false
        }
        guard !stale.isEmpty else { return }
        let staleIDs = Set(stale.map(\.id))
        for block in stale {
            removeBlock(block)
        }
        // Saved explicitly here rather than left to the caller's own
        // save below — that one's skipped entirely whenever there's
        // nothing new to place (`guard !newBlocks.isEmpty else { return }`),
        // which would otherwise leave this deletion sitting unsaved.
        try? modelContext.save()
        loadExistingBlocks(allBlocksNow.filter { !staleIDs.contains($0.id) })
    }

    /// One-time cleanup for the accumulation two earlier bugs could leave
    /// behind: before the `existingBlocks` seeding fix, every appear/
    /// day-change re-filled a rule's budget from zero, so a "≤2 tasks"
    /// window could end up with far more than 2 task blocks stacked up
    /// over repeated visits; and before eligibility was made strict
    /// everywhere (see `AISchedulingServiceProtocol.generateProposedSchedule`'s
    /// doc comment), a task never toggled eligible for a rule could still
    /// get swept into that rule's leftover budget by the old tier-3
    /// fallback. Neither is possible going forward (both are fixed at the
    /// source), but every day that already accumulated either still needs
    /// it unwound once — not just whichever single day happens to be
    /// `targetDate` right now. `regenerateFromNow`'s own walk (and Nightly
    /// Review generally) populates many days ahead in one pass, so a day
    /// the user hasn't actually flipped to yet can carry the exact same
    /// leftover damage as today did. Swept across every day, today
    /// forward, that actually has a task block sitting on it — no
    /// artificial cutoff, since only days with real data to check cost
    /// anything here (this is pure date math against what's already in
    /// the model, no calendar network fetch involved).
    private func trimOverflowingRuleBlocksAcrossFutureDays(shelves: [Shelf]) {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: .now)
        let allBlocksNow = (try? modelContext.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        let blocksByDay = Dictionary(grouping: allBlocksNow.filter { $0.date >= startOfToday }) {
            calendar.startOfDay(for: $0.date)
        }

        var didTrim = false
        for (day, dayBlocks) in blocksByDay {
            didTrim = trimOverflowingRuleBlocks(shelves: shelves, day: day, dayBlocks: dayBlocks, calendar: calendar) || didTrim
        }

        if didTrim {
            try? modelContext.save()
            // Not `allBlocksNow` — that's a pre-trim snapshot, and every
            // block `removeBlock` deleted above is still in it, just with
            // `task`/`habit` now nil (see `removeBlock`'s nil-before-delete
            // ordering, §1.1a). Loading it back in would resurrect those
            // objects into `blocks` with both relationships nil, which
            // `ScheduledBlock.displayTitle` renders as "Open slot". Re-fetch
            // so deleted blocks are actually gone from what gets loaded.
            loadExistingBlocks((try? modelContext.fetch(FetchDescriptor<ScheduledBlock>())) ?? [])
        }
    }

    /// The actual per-day trim logic `trimOverflowingRuleBlocksAcrossFutureDays`
    /// runs for each day it finds — pulled out so it can run against any
    /// day's own blocks, not just `targetDate`'s. Only ever trims a task
    /// block that's unlocked, unapproved, and incomplete — the same "safe
    /// to touch" bar `regenerateFromNow`'s own clearing pass uses.
    /// Deletes straight through `modelContext`
    /// rather than touching `self.blocks` — the caller re-derives that
    /// from a fresh fetch once every day's been swept, so a day other
    /// than `targetDate` doesn't need its own bookkeeping here.
    @discardableResult
    private func trimOverflowingRuleBlocks(shelves: [Shelf], day: Date, dayBlocks: [ScheduledBlock], calendar: Calendar) -> Bool {
        let weekday = calendar.component(.weekday, from: day)
        let applicableRules: [SchedulingRule] = shelves
            .flatMap { $0.schedulingRules ?? [] }
            .filter { $0.isEnabled && $0.namedSchedule != nil && $0.effectiveDaysOfWeek.contains(weekday) }

        var didTrim = false
        for rule in applicableRules {
            guard
                let windowStart = calendar.date(bySettingHour: rule.effectiveStartHour, minute: rule.effectiveStartMinute, second: 0, of: day),
                let windowEnd = calendar.date(bySettingHour: rule.effectiveEndHour, minute: rule.effectiveEndMinute, second: 0, of: day),
                windowStart < windowEnd
            else { continue }

            // `status == .none`, not `!isCompleted` — same correction as
            // `performRegenerateFromNow`'s clearing pass, for the same
            // reason: `isCompleted` is `status == .complete`, so `.missed`
            // read as trimmable and a deliberately-missed block inside a
            // rule's window was deleted. Found by auditing for the gate after
            // the regenerate bug, not from a second report.
            // **Scoped to this rule's own shelf.** `applicableRules` is built
            // from *every* shelf's rules, and this filter previously matched
            // on the time window alone — so a rule belonging to one shelf
            // would pick up another shelf's blocks, find their tasks
            // (correctly) not eligible for it, and delete them through the
            // ineligible branch below. The owning shelf's own rule then
            // re-placed them on the next pass, and the cycle repeated on
            // every single navigation.
            //
            // Two shelves sharing one `NamedSchedule` is all it takes, which
            // is ordinary configuration rather than a corner case: "Work -
            // Afternoons" (12:00–17:00) attached to both a Personal rule and
            // a Work rule made every Personal block in that window
            // collateral damage of the Work rule's trim.
            //
            // A rule has no business deleting placements it could never have
            // made. Within a shelf the per-rule eligibility test below is
            // exactly right; across shelves it is meaningless.
            let trimmable = dayBlocks.filter {
                $0.task != nil && $0.task?.shelf?.id == rule.shelf?.id
                    && !$0.isLocked && $0.status == .none && !$0.manuallyPlaced && $0.approvalStatus != .approved
                    && $0.startTime >= windowStart && $0.startTime < windowEnd
            }
            guard !trimmable.isEmpty else { continue }

            // A divisible task's several segments (see `TaskItem
            // .isDivisible`/`minimumSegmentMinutes`) count as ONE task
            // toward a rule's own per-task cap, same as `pack()` counts
            // it, and are removed or kept together, never split apart —
            // otherwise a survivor could end up missing a piece of its
            // own placement, silently breaking its minimum-segment rule.
            var groupsByTask: [UUID: [ScheduledBlock]] = [:]
            for block in trimmable {
                guard let taskID = block.task?.id else { continue }
                groupsByTask[taskID, default: []].append(block)
            }
            var groups = groupsByTask.values
                .map { segments in (segments: segments, earliestStart: segments.map(\.startTime).min()!) }
                .sorted { $0.earliestStart < $1.earliestStart }

            // A task never marked eligible for this specific rule (see
            // `TaskItem.isEligible(for:)`) should never have a block
            // sitting in this rule's window at all — a leftover from
            // before eligibility was made strict everywhere. Removed
            // outright, before the count/duration cap below even runs.
            // Same treatment for a divisible task with a segment smaller
            // than its own configured minimum chunk (`minimumSegmentMinutes`)
            // — a leftover from before `pack()` enforced that floor
            // itself (a rule capped at, say, 15 min per task used to
            // happily chop a task with a 2-hour minimum into 15-minute
            // slivers). Removed as a whole group, not just the offending
            // segment — a partial removal would leave the survivor still
            // short of the floor it was supposed to meet in one piece.
            var eligibleGroups: [(segments: [ScheduledBlock], earliestStart: Date)] = []
            for group in groups {
                guard let task = group.segments.first?.task else { continue }
                let violatesMinimumSegment = task.isEffectivelyDivisible && task.minimumSegmentMinutes > 0
                    && group.segments.contains { Int($0.endTime.timeIntervalSince($0.startTime) / 60) < task.minimumSegmentMinutes }
                guard task.isEligible(for: rule), !violatesMinimumSegment else {
                    for block in group.segments {
                        block.task?.isScheduled = false
                        removeBlock(block)
                    }
                    didTrim = true
                    continue
                }
                eligibleGroups.append(group)
            }
            groups = eligibleGroups

            let maxCount: Int?
            let maxMinutes: Int?
            switch rule.fillStrategy {
            case .fillToFit:
                maxCount = nil
                maxMinutes = nil
            case .maxTaskCount:
                maxCount = rule.maxTaskCount
                maxMinutes = nil
            case .maxDuration:
                maxCount = rule.maxDurationTaskCountEnabled ? rule.maxTaskCount : nil
                maxMinutes = rule.maxTotalMinutes
            }

            func totalMinutes() -> Int {
                groups.reduce(0) { $0 + $1.segments.reduce(0) { $0 + Int($1.endTime.timeIntervalSince($1.startTime) / 60) } }
            }

            while (maxCount.map { groups.count > $0 } ?? false) || (maxMinutes.map { totalMinutes() > $0 } ?? false) {
                guard let excess = groups.popLast() else { break }
                for block in excess.segments {
                    block.task?.isScheduled = false
                    removeBlock(block)
                }
                didTrim = true
            }
        }

        return didTrim
    }

    // MARK: - Regenerate (from now, across as many days as it takes)

    /// Rebuilds the schedule starting from the next quarter-hour after
    /// whichever is later — right now, or the day currently on screen —
    /// never touching anything already in the past, and never touching an
    /// already-*approved* block anywhere (that's a real, pushed calendar
    /// event; the calendar's own free/busy already treats it as busy) —
    /// and keeps walking forward a day at a time until every eligible,
    /// currently-unscheduled task across every shelf has either been
    /// placed or genuinely can't ever fit anywhere. So tapping Regenerate
    /// while looking a few days ahead starts placing things there, not
    /// silently back on today — freeing up a batch of previous-day tasks
    /// (see `clearIncompletePastBlocks`) and regenerating while browsing a
    /// future day lands them starting from that day, not buried back on
    /// today where you're not even looking. A habit eligible for
    /// scheduling never "runs out" the way a shelf's task queue does — it
    /// recurs on every applicable day forever — so it keeps the walk going
    /// out to the full `habitPopulationDays` horizon on its own, rather than stopping
    /// the moment shelves empty out: that's the difference between a habit
    /// only showing up on whatever day happened to get generated versus
    /// showing up on every eligible day as you scroll the calendar
    /// forward.
    ///
    /// Every `ScheduledBlock` is fetched fresh from the store right here,
    /// rather than trusting a caller-supplied array — a caller that just
    /// finished deleting some (e.g. `clearIncompletePastBlocks`, or even a
    /// plain `deleteBlock` from a swipe moments earlier) would otherwise
    /// hand over a stale snapshot that still contains those now-deleted
    /// objects, and this function's own final `blocks = combined.filter
    /// { ... }` would silently resurrect them right back into view.
    /// Returns whether the walk actually reached its natural stopping
    /// point (stall threshold / habit horizon exhausted) rather than
    /// bailing out early on a `fetchFreeSlots` failure. Callers that use
    /// this as the dirty-flag escalation (see `ScheduleReviewView
    /// .syncSchedule`) need to know the difference — a caught-but-
    /// incomplete walk can still leave a stale block sitting past the
    /// point it reached, so the flag it's meant to clear must survive
    /// to be retried later instead of being dropped here.
    @discardableResult
    func regenerateFromNow(shelves: [Shelf], habits: [Habit], eligibleHoursWindows: [EligibleHoursWindow]) async -> Bool {
        var completed = false
        await serializingWalk { [self] in
            completed = await performRegenerateFromNow(shelves: shelves, habits: habits, eligibleHoursWindows: eligibleHoursWindows)
        }
        return completed
    }

    @discardableResult
    private func performRegenerateFromNow(shelves: [Shelf], habits: [Habit], eligibleHoursWindows: [EligibleHoursWindow]) async -> Bool {
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }
        var completedFully = true

        // Regenerating always clears out anything left over from a day
        // before today first — see `clearBlocksBeforeToday`.
        await clearBlocksBeforeToday()

        let calendar = Calendar.current
        let cutoff = Self.roundedUpToQuarterHour(max(targetDate, .now), calendar: calendar)
        // Completed task blocks are deliberately left alone here — they
        // stay on the shelf/calendar (faded, struck through) until Night
        // Time Review actually sweeps them; see `purgeCompletedBlocks`.
        let allBlocks = (try? modelContext.fetch(FetchDescriptor<ScheduledBlock>())) ?? []

        // A locked block is left alone entirely — same protection an
        // already-*approved* block gets, just for a reason the user chose
        // rather than the calendar push having already happened. A
        // manually placed block (see `ScheduledBlock.manuallyPlaced`)
        // gets the identical treatment — the empty-slot picker is itself
        // a deliberate user choice, same as locking, even when it lands
        // on a slot the task isn't rule-eligible for.
        // **Guaranteed replacements are protected**, the same way a locked
        // or manually-placed block is. Without this the regenerate deleted
        // the block `guaranteePlacement` had just put on the task's next
        // eligible day, freed the task, and re-walked it from `cutoff` —
        // landing it back on the very day it was missed, moments after being
        // marked missed. The placement logic was always right; its result was
        // being thrown away by the regenerate that `cycleBlockCompletion`'s
        // own `isDirty = true` triggers.
        let guaranteedReplacementIDs = Set(allBlocks.compactMap(\.guaranteedReplacementBlockID))
        var survivingBlocks = allBlocks
        // **`status == .none`, not `!isCompleted`.** `ScheduledBlock.isCompleted`
        // is `status == .complete`, so `.missed` read `false` here and a
        // deliberately-missed block was swept up and re-placed as a fresh
        // `.none` one — losing the decision the user had just made. That gate
        // predates three-state completion, where "not complete" really did
        // mean "unresolved, free to re-place"; it is the same lossy-`isCompleted`
        // read that made `.missed` invisible on the calendar circle, in a
        // different file.
        //
        // It also states the rule `resolveMissedPastBlocks` already claims:
        // "nothing is deleted from the calendar now — `.missed` is a real,
        // permanent record, not a state to sweep away." Only an untouched
        // block is free to be cleared and re-walked.
        //
        // This subsumes the guaranteed-replacement case rather than
        // special-casing it — a missed habit or meal block never gets a
        // replacement and was being swept just the same. The id-based
        // exemption below still earns its keep: the replacement itself is
        // `.none`.
        for block in allBlocks where block.approvalStatus != .approved && !block.isLocked && block.status == .none && !block.manuallyPlaced && !guaranteedReplacementIDs.contains(block.id) && block.startTime >= cutoff {
            block.task?.isScheduled = false
            removeBlock(block)
            survivingBlocks.removeAll { $0.id == block.id }
        }
        // Flushed explicitly rather than left to autosave — the walk below
        // repeatedly reads relationships that touch these same objects
        // (e.g. `habit.scheduledBlocks`, inside `generateProposedSchedule`)
        // across many iterations without ever otherwise yielding back to
        // SwiftData, which could otherwise still be carrying this batch of
        // deletes as pending when that happens.
        try? modelContext.save()

        var cursorDay = calendar.startOfDay(for: cutoff)
        var dayIndex = 0
        // Habits recur forever by design (see doc comment above) — a
        // habit alone never lets the walk stop on its own, so its own
        // reason to keep going is capped at a sane rolling horizon
        // (`Self.habitPopulationDays`).
        // Tasks, on the other hand, actually run out: `hasRemainingSchedulableWork`
        // only ever counts a task that's both eligible for one of its
        // shelf's rules and genuinely able to fit it (see `SchedulingRule
        // .canEverFit`), so it's guaranteed to go false once everything
        // real is placed — a task that can never fit anywhere is already
        // excluded, not counted as "remaining" forever.
        var newBlocks: [ScheduledBlock] = []
        let keepWalkingForHabits = hasSchedulableHabits(habits: habits)
        // Bounds the *task* side of the walk without a flat day-count
        // cap — see `taskStallThresholdDays`. Reset to 0 any day that
        // places at least one task block (habit placements don't count;
        // this is purely about whether the task backlog is making
        // progress), incremented otherwise.
        var consecutiveDaysWithoutTaskPlacement = 0
        var ruleStats: [UUID: RuleWalkStats] = [:]
        // Same batching as `autoPlaceEligibleTasks` — one ranged call up
        // front, per-day fallback beyond the window. The `try`/`catch`
        // below is unchanged: a cache hit simply skips the throwing call,
        // and a miss still routes through it, so a genuine fetch failure
        // sets `completedFully = false` and breaks exactly as before.
        let prefetched = await prefetchFreeSlots(from: cursorDay, days: Self.freeSlotPrefetchDays)

        while dayIndex < Self.maxWalkDays
            && (dayIndex == 0
                || (dayIndex < Self.habitPopulationDays && keepWalkingForHabits)
                || (consecutiveDaysWithoutTaskPlacement < Self.taskStallThresholdDays && hasRemainingSchedulableWork(shelves: shelves))) {
            do {
                var freeSlots: [TimeSlot]
                if let cached = prefetched[calendar.startOfDay(for: cursorDay)] {
                    freeSlots = cached
                } else {
                    freeSlots = try await calendarService.fetchFreeSlots(for: cursorDay)
                }
                if dayIndex == 0 && calendar.isDateInToday(cursorDay) {
                    // Today only offers up whatever's still ahead of the
                    // cutoff — everything earlier is already past, so it's
                    // left alone regardless of what free/busy reports. This
                    // only makes sense when the walk's first day really is
                    // today: if it's a future day instead (regenerating
                    // while browsing tomorrow, say), `cutoff` still carries
                    // whatever time-of-day `targetDate` happened to have
                    // (it's never normalized to midnight) — clipping by it
                    // here would wrongly cut off tomorrow's whole morning
                    // instead of leaving the future day's full day open.
                    freeSlots = freeSlots.compactMap { slot in
                        let start = max(slot.start, cutoff)
                        return start < slot.end ? TimeSlot(start: start, end: slot.end) : nil
                    }
                }
                // An approved surviving block is already reflected in the
                // calendar's own free/busy above (it's really been
                // pushed), but a locked-while-still-proposed,
                // completed-while-still-proposed, or manually-placed one
                // hasn't — carve its time back out manually so
                // regeneration doesn't schedule something new right on
                // top of it.
                let protectedSurviving = survivingBlocks.filter {
                    ($0.isLocked || $0.isCompleted || $0.manuallyPlaced) && $0.approvalStatus != .approved && calendar.isDate($0.date, inSameDayAs: cursorDay)
                }
                for protected in protectedSurviving {
                    freeSlots = subtracting(protected.startTime..<protected.endTime, from: freeSlots)
                }
                // See the matching call in `autoPlaceEligibleTasks` —
                // tallied after every subtraction, so it reflects what's
                // actually still open.
                accumulateRuleStats(&ruleStats, shelves: shelves, day: cursorDay, freeSlots: freeSlots, calendar: calendar)
                let dayBlocks = try await schedulingService.generateProposedSchedule(
                    shelves: shelves,
                    habits: habits,
                    freeSlots: freeSlots,
                    eligibleHoursWindows: eligibleHoursWindows,
                    date: cursorDay,
                    existingBlocks: survivingBlocks.filter { calendar.isDate($0.date, inSameDayAs: cursorDay) },
                    context: modelContext
                )
                for block in dayBlocks where insertSchedulerBlock(block, site: "regenerateFromNow") {
                    newBlocks.append(block)
                }
                // Recurring tasks excluded — see the matching comment in
                // `autoPlaceEligibleTasks`. Same counter, same defect.
                if dayBlocks.contains(where: { $0.task != nil && !($0.task?.isRecurring ?? false) }) {
                    consecutiveDaysWithoutTaskPlacement = 0
                } else {
                    consecutiveDaysWithoutTaskPlacement += 1
                }
            } catch {
                errorMessage = error.localizedDescription
                completedFully = false
                break
            }
            cursorDay = calendar.date(byAdding: .day, value: 1, to: cursorDay) ?? cursorDay
            dayIndex += 1
        }
        lastWalkDayCount = dayIndex
        tasksThatDidNotFit = unplacedTasks(shelves: shelves, stats: ruleStats, hitHorizon: dayIndex >= Self.maxWalkDays)
        try? modelContext.save()

        let combined = survivingBlocks + newBlocks
        blocks = combined
            .filter { calendar.isDate($0.date, inSameDayAs: targetDate) }
            .sorted { $0.startTime < $1.startTime }

        await loadCalendarEvents()
        return completedFully
    }

    /// Carves `occupied` out of `slots`, splitting or trimming whichever
    /// slot(s) it overlaps — used to protect a locked-but-not-yet-approved
    /// block's time during `regenerateFromNow`, the same way an approved
    /// block's time is already protected by the calendar's own free/busy.
    private func subtracting(_ occupied: Range<Date>, from slots: [TimeSlot]) -> [TimeSlot] {
        slots.flatMap { slot -> [TimeSlot] in
            guard occupied.lowerBound < slot.end, occupied.upperBound > slot.start else { return [slot] }
            var pieces: [TimeSlot] = []
            if occupied.lowerBound > slot.start {
                pieces.append(TimeSlot(start: slot.start, end: occupied.lowerBound))
            }
            if occupied.upperBound < slot.end {
                pieces.append(TimeSlot(start: occupied.upperBound, end: slot.end))
            }
            return pieces
        }.filter { $0.durationMinutes > 0 }
    }

    /// Whether any shelf still has an unscheduled task actually worth
    /// walking further days for — the condition `regenerateFromNow` keeps
    /// going for, so today running out of room pushes the overflow to
    /// tomorrow, and the day after that, and so on, until every real task
    /// is placed. Scoped to "eligible for one of the shelf's rules, and
    /// could still fit it" on purpose — every rule requires explicit
    /// eligibility now (no tier-3 catch-all left to sweep in an unmarked
    /// task), and a task that could never fit any of its own eligible
    /// rules (its remaining size, or divisible minimum, too big for what
    /// any of them ever offer) would otherwise keep this true forever,
    /// walking the day cap for nothing. Leaving it out of "remaining
    /// work" is exactly what lets `regenerateFromNow` walk without an
    /// artificial day cap for tasks that actually can be placed, while a
    /// genuinely-unplaceable one just stays put, unscheduled, for the
    /// user to notice and fix (a duration too big, a rule too narrow)
    /// rather than silently consuming the walk's time.
    ///
    /// How many consecutive days the task-side walk (`regenerateFromNow`,
    /// `autoPlaceEligibleTasks`) will place zero task blocks — while
    /// `hasRemainingSchedulableWork` is still `true` — before giving up,
    /// in place of a flat day-count cap (see §6.4). A weekday-restricted
    /// rule (e.g. "Fridays only") can legitimately go up to 6 days
    /// between chances to place anything; doubling that gives margin for
    /// a rule that's *also* narrow in some other way (a tight eligible-
    /// hours window, a low task-count cap already claimed by other
    /// shelves) without waiting anywhere near as long as a raw day count
    /// ever had to. Task placement, not habit placement, is what resets
    /// this — `regenerateFromNow`'s own habit walk has no stall concept
    /// at all (a habit recurs forever, so "zero habit blocks placed
    /// today" is never a sign of anything going wrong the way an empty
    /// day is for a finite task backlog); it's governed purely by
    /// `habitPopulationDays` instead.
    private static let taskStallThresholdDays = 14

    /// How far ahead `regenerateFromNow` keeps walking purely to lay down
    /// habit occurrences. Habits recur forever, so unlike the task side
    /// there's nothing that can ever "run out" to stop the walk — this is
    /// the horizon that does it. Was a local `let` inside
    /// `regenerateFromNow`; promoted to a shared constant so
    /// `freeSlotPrefetchDays` below can be derived from it.
    private static let habitPopulationDays = 30

    /// How many days of free/busy to pull in the single ranged call each
    /// walk makes up front (see `prefetchFreeSlots(from:days:)`).
    ///
    /// Derived, never hardcoded: it has to cover whichever of the two
    /// walk-termination conditions runs longer. `regenerateFromNow` walks
    /// at least `habitPopulationDays` whenever any habit exists, and the
    /// task side can then run a further `taskStallThresholdDays` past
    /// that before stalling out, so their sum is the horizon that covers
    /// the realistic worst case in one request.
    ///
    /// It is deliberately NOT a hard cap on the walk. A task backlog that
    /// places something every 10-13 days never trips the stall counter,
    /// so a walk can legitimately run past this window; days beyond it
    /// fall back to the per-day `fetchFreeSlots(for:)` rather than
    /// re-batching or truncating. That keeps the pathological case
    /// correct while costing nothing in the common one.
    private static let freeSlotPrefetchDays = habitPopulationDays + taskStallThresholdDays

    /// Hard ceiling on how many days either walk will ever visit.
    ///
    /// Defense in depth, not the primary terminator — with the recurring-
    /// task exclusion in place (see the counter comments in both walks)
    /// stall detection should stop things long before this binds. It
    /// exists so that any *future* condition which wrongly resets the
    /// stall counter degrades into a bounded miss instead of the
    /// unbounded day-by-day crawl that shipped a task ~1046 days out.
    ///
    /// Deliberately equal to `freeSlotPrefetchDays`: past that window the
    /// walk would fall back to one network call per day, so a walk that
    /// runs beyond it is both wrong *and* expensive. Capping here keeps
    /// the two bounds from drifting apart.
    private static let maxWalkDays = freeSlotPrefetchDays

    /// One ranged free/busy call covering `days` days from `startDay`,
    /// keyed by `startOfDay` for direct cursor lookup. Returns `[:]` on
    /// failure rather than throwing — a miss just sends each day down the
    /// per-day fallback path, which carries the caller's own existing
    /// error handling, so a failed pre-fetch degrades to exactly the
    /// behavior this optimization replaced instead of failing the walk.
    private func prefetchFreeSlots(from startDay: Date, days: Int) async -> [Date: [TimeSlot]] {
        let calendar = Calendar.current
        guard let end = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: startDay)) else { return [:] }
        return (try? await calendarService.fetchFreeSlots(from: startDay, to: end)) ?? [:]
    }

    /// Deliberately does NOT call `TaskItem.isEffectivelyEligible` —
    /// inlines the same check against `remainingMinutes` instead of
    /// `estimatedMinutes`, and that's load-bearing, not a style
    /// preference. This function is one of only two conditions that ever
    /// stop `regenerateFromNow`'s walk (see §6.4 — the other is
    /// `taskStallThresholdDays`, not a flat day-count backstop), so it
    /// has to be able to go `false` on its own, without depending on
    /// `isScheduled` ever getting set correctly elsewhere. `rule
    /// .canEverFit`'s underlying `fitStatus` returns `.needsDuration`
    /// (not `.fits`) the moment its `estimatedMinutes` argument is
    /// `<= 0` — so passing `remainingMinutes` here means a fully-drained
    /// task (`remainingMinutes == 0`) always evaluates as
    /// not-fitting-anything and drops out of "remaining work" on that
    /// alone, independent of whatever `isScheduled` happens to be. Pass
    /// `estimatedMinutes` (the task's original, undrained size) instead,
    /// and a task stuck at `remainingMinutes == 0` with `isScheduled`
    /// somehow still `false` would keep reporting "still fits" forever —
    /// the walk would never terminate on it. Do not "simplify" this back
    /// to `isEffectivelyEligible` without re-verifying the walk still stops.
    private func hasRemainingSchedulableWork(shelves: [Shelf]) -> Bool {
        shelves.contains { shelf in
            let rules = (shelf.schedulingRules ?? []).filter(\.isEnabled)
            guard !rules.isEmpty else { return false }
            return (shelf.tasks ?? []).contains { isSchedulableBacklog($0, rules: rules) }
        }
    }

    /// The one definition of "this task still wants a slot," shared by
    /// `hasRemainingSchedulableWork` (which short-circuits, and runs every
    /// loop iteration) and `remainingSchedulableTasks` (which collects).
    /// Kept single so the walk's own termination condition and the
    /// "won't fit" list reported to the user can never disagree about
    /// which tasks count.
    private func isSchedulableBacklog(_ task: TaskItem, rules: [SchedulingRule]) -> Bool {
        guard !task.isScheduled else { return false }
        return rules.contains { rule in
            task.isEligible(for: rule)
                && rule.canEverFit(estimatedMinutes: task.remainingMinutes, isDivisible: task.isEffectivelyDivisible, minimumSegmentMinutes: task.minimumSegmentMinutes)
        }
    }

    /// Folds one day's free time into each applicable rule's running
    /// tally. Free slots are clipped to the rule's *own* window rather
    /// than counted whole-day.
    ///
    /// That clipping is load-bearing for the reason to be right: a rule
    /// covering 6-8pm on a day with a free morning and a booked evening
    /// has no usable time at all, but a whole-day tally would record
    /// hours of it and the derivation would then blame the rule's caps
    /// (`.ruleBudgetFull`) instead of the genuine `.noFreeTime`.
    private func accumulateRuleStats(
        _ stats: inout [UUID: RuleWalkStats],
        shelves: [Shelf],
        day: Date,
        freeSlots: [TimeSlot],
        calendar: Calendar
    ) {
        let weekday = calendar.component(.weekday, from: day)
        for shelf in shelves {
            for rule in (shelf.schedulingRules ?? []) where rule.isEnabled && rule.namedSchedule != nil {
                guard rule.effectiveDaysOfWeek.contains(weekday) else { continue }
                guard
                    let windowStart = calendar.date(bySettingHour: rule.effectiveStartHour, minute: rule.effectiveStartMinute, second: 0, of: day),
                    let windowEnd = calendar.date(bySettingHour: rule.effectiveEndHour, minute: rule.effectiveEndMinute, second: 0, of: day),
                    windowStart < windowEnd
                else { continue }

                var entry = stats[rule.id] ?? RuleWalkStats()
                entry.eligibleDayCount += 1
                for slot in freeSlots {
                    let start = max(slot.start, windowStart)
                    let end = min(slot.end, windowEnd)
                    guard end > start else { continue }
                    let minutes = Int(end.timeIntervalSince(start) / 60)
                    entry.totalFreeMinutes += minutes
                    entry.maxContiguousSlotMinutes = max(entry.maxContiguousSlotMinutes, minutes)
                }
                stats[rule.id] = entry
            }
        }
    }

    /// Threshold for `.fewEligibleDays` — a rule that came up this many
    /// days or fewer is treated as rare-window rather than merely busy.
    private static let fewEligibleDaysThreshold = 3

    /// Tasks the scheduler silently skips because they have no schedulable
    /// time left, despite not being finished.
    ///
    /// Deliberately a *separate* collector from `remainingSchedulableTasks`
    /// rather than a loosening of it. That function shares its predicate
    /// with `hasRemainingSchedulableWork`, which is one of the walk's two
    /// termination conditions — widening it to include zero-remaining
    /// tasks would make the walk think it still had work to do and never
    /// stop. These tasks need reporting, not scheduling.
    ///
    /// The "drained" test compares against time actually placed rather
    /// than just checking for the presence of blocks. A task whose blocks
    /// fully account for its estimate is simply finished being scheduled
    /// — normal, not stranded. Only when the placed minutes fall short of
    /// the estimate has time gone missing.
    private func tasksWithNoSchedulableTime(shelves: [Shelf]) -> [TaskItem] {
        shelves.flatMap { shelf -> [TaskItem] in
            let rules = (shelf.schedulingRules ?? []).filter(\.isEnabled)
            guard !rules.isEmpty else { return [] }
            return (shelf.tasks ?? []).filter { task in
                // Recurring tasks are placed by the fixed-time pass and
                // never drain `remainingMinutes` at all, so this test
                // doesn't describe them.
                guard !task.isCompleted, !task.isRecurring else { return false }
                guard rules.contains(where: { task.isEligible(for: $0) }) else { return false }
                guard task.remainingMinutes <= 0 else { return false }
                guard task.estimatedMinutes > 0 else { return true } // never given a duration
                let placedMinutes = (task.scheduledBlocks ?? [])
                    .filter { !$0.isCompleted }
                    .reduce(0) { $0 + Int($1.endTime.timeIntervalSince($1.startTime) / 60) }
                return placedMinutes < task.estimatedMinutes
            }
        }
    }

    /// Pairs each still-unplaced task with a single reason, in the fixed
    /// priority order documented on `UnplacedReason`.
    private func unplacedTasks(shelves: [Shelf], stats: [UUID: RuleWalkStats], hitHorizon: Bool) -> [UnplacedTask] {
        // Checked first, and collected separately, because these tasks
        // never reach the packer at all — none of the walk-derived stats
        // below say anything about them.
        let needsDuration = tasksWithNoSchedulableTime(shelves: shelves).map { task in
            UnplacedTask(
                task: task,
                reason: .needsDuration,
                rule: (task.shelf?.schedulingRules ?? []).first { $0.isEnabled && task.isEligible(for: $0) },
                eligibleDayCount: 0,
                totalFreeMinutes: 0,
                maxContiguousSlotMinutes: 0,
                requiredMinutes: task.estimatedMinutes
            )
        }

        return needsDuration + remainingSchedulableTasks(shelves: shelves).map { task in
            // Judged against whichever eligible rule actually came up most
            // — the one that had the best shot and still didn't place it.
            let candidateRules = (task.shelf?.schedulingRules ?? []).filter {
                $0.isEnabled && task.isEffectivelyEligible(for: $0)
            }
            let bestRule = candidateRules.max {
                (stats[$0.id]?.eligibleDayCount ?? 0) < (stats[$1.id]?.eligibleDayCount ?? 0)
            }
            let tally = bestRule.flatMap { stats[$0.id] } ?? RuleWalkStats()
            let requiredMinutes = task.isEffectivelyDivisible && task.minimumSegmentMinutes > 0
                ? task.minimumSegmentMinutes
                : task.remainingMinutes

            let reason: UnplacedReason
            if tally.eligibleDayCount == 0 {
                reason = .noEligibleDays
            } else if tally.eligibleDayCount <= Self.fewEligibleDaysThreshold {
                reason = .fewEligibleDays
            } else if tally.totalFreeMinutes == 0 {
                reason = .noFreeTime
            } else if tally.maxContiguousSlotMinutes < requiredMinutes {
                reason = .noContiguousSlot
            } else if hitHorizon {
                reason = .horizonReached
            } else {
                reason = .ruleBudgetFull
            }

            return UnplacedTask(
                task: task,
                reason: reason,
                rule: bestRule,
                eligibleDayCount: tally.eligibleDayCount,
                totalFreeMinutes: tally.totalFreeMinutes,
                maxContiguousSlotMinutes: tally.maxContiguousSlotMinutes,
                requiredMinutes: requiredMinutes
            )
        }
    }

    /// Same predicate as `hasRemainingSchedulableWork`, but returning the
    /// actual tasks — what a walk reports as "didn't fit" once it stops.
    private func remainingSchedulableTasks(shelves: [Shelf]) -> [TaskItem] {
        shelves.flatMap { shelf -> [TaskItem] in
            let rules = (shelf.schedulingRules ?? []).filter(\.isEnabled)
            guard !rules.isEmpty else { return [] }
            return (shelf.tasks ?? []).filter { isSchedulableBacklog($0, rules: rules) }
        }
    }

    /// Whether the walk needs to keep going just because habits exist —
    /// every habit is assumed schedulable now (see `AISchedulingService`),
    /// so as long as there's at least one, *some* day ahead is bound to be
    /// applicable for it. Unlike `hasRemainingSchedulableWork`, this
    /// doesn't need to be re-checked per iteration: a habit doesn't get
    /// "used up" the way a shelf task does.
    private func hasSchedulableHabits(habits: [Habit]) -> Bool {
        !habits.isEmpty
    }

    /// Rounds up to the next quarter-hour — e.g. 10:35 -> 10:45, but 10:45
    /// exactly stays put (it's already on a boundary, not past one).
    private static func roundedUpToQuarterHour(_ date: Date, calendar: Calendar) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        let secondsIntoDay = date.timeIntervalSince(startOfDay)
        let quarterHour: TimeInterval = 15 * 60
        let roundedSeconds = (secondsIntoDay / quarterHour).rounded(.up) * quarterHour
        return startOfDay.addingTimeInterval(roundedSeconds)
    }

    // MARK: - Drag to reorder

    /// A movable row in the day's timeline: either a proposed block or an
    /// unlocked calendar event. Locked events are never passed in here —
    /// they're excluded entirely, keeping both their order and their time.
    enum TimelineEntryRef: Hashable {
        case block(UUID)
        case event(String)
    }

    /// Reorders the day's proposed blocks and unlocked calendar events to
    /// match `newOrder`, then repacks their times back-to-back in that new
    /// order, starting from the earliest slot in the group — each entry
    /// keeps its own duration, but later ones shift to close any gap the
    /// move opened up, and earlier ones get pushed later to make room.
    /// Locked events are excluded, so the group reshuffles only among
    /// itself rather than routing around fixed anchors. Any calendar event
    /// whose time actually changes gets pushed back to Google.
    func reorderTimeline(newOrder: [TimelineEntryRef]) {
        let blockLookup = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        let eventLookup = Dictionary(uniqueKeysWithValues: calendarEvents.map { ($0.id, $0) })

        let startTimes: [Date] = newOrder.compactMap { ref in
            switch ref {
            case .block(let id): return blockLookup[id]?.startTime
            case .event(let id): return eventLookup[id]?.start
            }
        }
        guard let anchor = startTimes.min() else { return }

        var cursor = anchor
        var updatedEvents: [CalendarEventSummary] = []

        for ref in newOrder {
            switch ref {
            case .block(let id):
                guard let block = blockLookup[id] else { continue }
                let duration = block.endTime.timeIntervalSince(block.startTime)
                if block.startTime != cursor {
                    block.startTime = cursor
                    block.endTime = cursor.addingTimeInterval(duration)
                    needsReapproval(block)
                }
                cursor = cursor.addingTimeInterval(duration)
            case .event(let id):
                guard let event = eventLookup[id] else { continue }
                let duration = event.end.timeIntervalSince(event.start)
                if event.start != cursor {
                    updatedEvents.append(CalendarEventSummary(id: event.id, title: event.title, start: cursor, end: cursor.addingTimeInterval(duration), notes: event.notes))
                }
                cursor = cursor.addingTimeInterval(duration)
            }
        }

        blocks = blocks.sorted { $0.startTime < $1.startTime }
        for updated in updatedEvents {
            if let idx = calendarEvents.firstIndex(where: { $0.id == updated.id }) {
                calendarEvents[idx] = updated
            }
        }
        guard !updatedEvents.isEmpty else { return }
        Task {
            for updated in updatedEvents {
                try? await calendarService.updateEvent(eventID: updated.id, title: updated.title, start: updated.start, end: updated.end, notes: updated.notes)
            }
        }
    }

    /// Moves a single unlocked block or calendar event to `newStart`
    /// (keeping its own duration), then shifts only the *other* unlocked
    /// entries that would now overlap it out of the way — cascading
    /// further if that opens a new overlap with their own neighbor.
    /// Anything that doesn't conflict keeps its exact original time, so
    /// gaps elsewhere in the day are preserved. This is what a drag on
    /// `DayTimelineGridView` commits — unlike `reorderTimeline` (driven by
    /// the old List's reorder, which always packed its whole group
    /// back-to-back with no gaps), dropping something back into the same
    /// slot it started in is a genuine no-op here rather than silently
    /// recomputing the same packed time and looking like it "snapped
    /// back." `unlockedOrder` is exactly the set of refs the caller
    /// considers movable — locked events are excluded from the ripple
    /// entirely, same as `reorderTimeline`.
    func moveEntry(_ dragged: TimelineEntryRef, to newStart: Date, among unlockedOrder: [TimelineEntryRef]) {
        let blockLookup = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        let eventLookup = Dictionary(uniqueKeysWithValues: calendarEvents.map { ($0.id, $0) })

        struct Entry {
            let ref: TimelineEntryRef
            var start: Date
            let duration: TimeInterval
        }

        var entries: [Entry] = unlockedOrder.compactMap { ref in
            switch ref {
            case .block(let id):
                guard let block = blockLookup[id] else { return nil }
                return Entry(ref: ref, start: block.startTime, duration: block.endTime.timeIntervalSince(block.startTime))
            case .event(let id):
                guard let event = eventLookup[id] else { return nil }
                return Entry(ref: ref, start: event.start, duration: event.end.timeIntervalSince(event.start))
            }
        }
        guard let draggedIndex = entries.firstIndex(where: { $0.ref == dragged }) else { return }
        entries[draggedIndex].start = newStart
        entries.sort { $0.start < $1.start }
        guard let pivotIndex = entries.firstIndex(where: { $0.ref == dragged }) else { return }

        // Ripple later: each subsequent entry starts no earlier than the
        // previous (already-resolved) entry ends.
        var cursor = entries[pivotIndex].start.addingTimeInterval(entries[pivotIndex].duration)
        if pivotIndex + 1 < entries.count {
            for i in (pivotIndex + 1)..<entries.count {
                if entries[i].start < cursor {
                    entries[i].start = cursor
                }
                cursor = entries[i].start.addingTimeInterval(entries[i].duration)
            }
        }

        // Ripple earlier: each preceding entry ends no later than the next
        // (already-resolved) entry starts.
        cursor = entries[pivotIndex].start
        if pivotIndex > 0 {
            for i in stride(from: pivotIndex - 1, through: 0, by: -1) {
                let end = entries[i].start.addingTimeInterval(entries[i].duration)
                if end > cursor {
                    entries[i].start = cursor.addingTimeInterval(-entries[i].duration)
                }
                cursor = entries[i].start
            }
        }

        var updatedEvents: [CalendarEventSummary] = []
        for entry in entries {
            switch entry.ref {
            case .block(let id):
                guard let block = blockLookup[id] else { continue }
                if block.startTime != entry.start {
                    block.startTime = entry.start
                    block.endTime = entry.start.addingTimeInterval(entry.duration)
                    needsReapproval(block)
                }
            case .event(let id):
                guard let event = eventLookup[id] else { continue }
                if event.start != entry.start {
                    updatedEvents.append(CalendarEventSummary(id: event.id, title: event.title, start: entry.start, end: entry.start.addingTimeInterval(entry.duration), notes: event.notes))
                }
            }
        }

        blocks = blocks.sorted { $0.startTime < $1.startTime }
        for updated in updatedEvents {
            if let idx = calendarEvents.firstIndex(where: { $0.id == updated.id }) {
                calendarEvents[idx] = updated
            }
        }
        guard !updatedEvents.isEmpty else { return }
        Task {
            for updated in updatedEvents {
                try? await calendarService.updateEvent(eventID: updated.id, title: updated.title, start: updated.start, end: updated.end, notes: updated.notes)
            }
        }
    }

    /// Saves a manual edit (title/time/notes) to a synced calendar event and
    /// pushes it back to Google.
    func saveEventEdit(_ updated: CalendarEventSummary) {
        if let idx = calendarEvents.firstIndex(where: { $0.id == updated.id }) {
            calendarEvents[idx] = updated
        }
        Task {
            try? await calendarService.updateEvent(eventID: updated.id, title: updated.title, start: updated.start, end: updated.end, notes: updated.notes)
        }
    }

    func loadExistingBlocks(_ existing: [ScheduledBlock]) {
        blocks = existing
            .filter { Calendar.current.isDate($0.date, inSameDayAs: targetDate) }
            .sorted { $0.startTime < $1.startTime }
    }

    /// Pulls existing calendar events for the day (with real titles) so the
    /// Schedule tab can show what's already blocked off, even before a
    /// schedule is generated. Failure (e.g. not signed in) just leaves this
    /// empty.
    func loadCalendarEvents() async {
        calendarEvents = (try? await calendarService.fetchEvents(for: targetDate)) ?? []
    }

    /// Switches which day is being reviewed and reloads both the stored
    /// blocks for that day and its calendar events.
    func changeTargetDate(to newDate: Date, existingBlocks: [ScheduledBlock]) async {
        targetDate = newDate
        loadExistingBlocks(existingBlocks)
        await loadCalendarEvents()
    }

    // MARK: - Approval

    /// Approves every block and pushes each to Google Calendar — creating
    /// a new event if it's never been pushed, or updating the same event
    /// in place if it has (so re-approving after an edit overwrites what's
    /// already there instead of duplicating it).
    func approveAll() {
        for block in blocks { block.approvalStatus = .approved }
        Task {
            for block in blocks {
                if let eventID = try? await calendarService.pushEvent(for: block) {
                    block.googleEventID = eventID
                }
            }
        }
    }

    func approve(_ block: ScheduledBlock) {
        block.approvalStatus = .approved
        Task {
            if let eventID = try? await calendarService.pushEvent(for: block) {
                block.googleEventID = eventID
            }
        }
    }

    // MARK: - Week view: drag to a new day/time

    /// `WeekTimelineView`'s own drag-to-reposition — simpler than the day
    /// timeline's drag (`moveEntry`/the ripple reflow it drives): this
    /// just relocates one block to a new day and time, with no reflow of
    /// anything else on either the old or new day. A week glance is meant
    /// for quick moves, not the same fine-grained same-day reordering the
    /// day view does — overlaps are left for the user to notice and sort
    /// out on the day view itself, same as a manually-placed block would.
    /// Drops back to "proposed" if it was approved, same as any other
    /// edit to an approved block. Keeps `blocks` (this ViewModel's own
    /// `targetDate`-scoped cache) in sync either way: added if the block
    /// just moved onto `targetDate`, removed if it just moved off it —
    /// otherwise the day view, if you flip back to it without this
    /// screen re-fetching first, would show a stale set.
    func moveBlock(_ block: ScheduledBlock, toDayStart newDayStart: Date, startMinutes: Int) {
        let calendar = Calendar.current
        let duration = block.durationMinutes
        let newStart = calendar.date(byAdding: .minute, value: startMinutes, to: newDayStart) ?? block.startTime
        let newEnd = calendar.date(byAdding: .minute, value: duration, to: newStart) ?? block.endTime
        block.date = newDayStart
        block.startTime = newStart
        block.endTime = newEnd
        needsReapproval(block)

        if calendar.isDate(newDayStart, inSameDayAs: targetDate) {
            if !blocks.contains(where: { $0.id == block.id }) {
                blocks.append(block)
            }
            blocks.sort { $0.startTime < $1.startTime }
        } else {
            blocks.removeAll { $0.id == block.id }
        }
    }

    // MARK: - Swipe left: delete, leave the slot open

    /// Removes the block entirely. The underlying task goes back to being
    /// unscheduled so it can be picked up on a future night. If it had
    /// already been pushed to the calendar, that event gets removed too.
    func deleteBlock(_ block: ScheduledBlock) {
        block.task?.isScheduled = false
        block.task?.pushedCount += 1
        if let eventID = block.googleEventID {
            Task { try? await calendarService.deleteEvent(eventID: eventID) }
        }
        // Restores, like every other deferral. A swipe means "not here,
        // not now" — completing the block is the separate gesture that
        // means the work is actually done, and `pushedCount` above is
        // itself the record of a deferral. Discarding the work outright
        // would need its own deliberate action, not a swipe side effect.
        removeBlock(block)
        blocks.removeAll { $0.id == block.id }
    }

    // MARK: - Swipe right: auto-replace with another queued to-do

    /// Swaps the block's task for the next-best unscheduled to-do (by
    /// priority, then due date), keeping the same time slot. The bumped task
    /// goes back into the unscheduled queue. If the block was already
    /// approved, it drops back to "proposed" so it's clear this needs
    /// re-approval (and re-pushing) before it matches the calendar again.
    func autoReplace(_ block: ScheduledBlock, candidatePool: [TaskItem]) {
        let outgoing = block.task
        let replacement = nextCandidate(from: candidatePool, block: block)

        outgoing?.isScheduled = false
        outgoing?.pushedCount += 1
        block.task = replacement
        replacement?.isScheduled = true
        needsReapproval(block)

        if let idx = blocks.firstIndex(where: { $0.id == block.id }) {
            blocks[idx] = block
        }
    }

    // MARK: - Long-press: manually pick the replacement

    /// Explicit version of autoReplace where the user chose the specific
    /// replacement task from a picker sheet. `newTask` no longer has to be
    /// unscheduled (see `replaceCandidates`) — if it already has its own
    /// active block elsewhere, that block is freed (deleted) as part of
    /// taking over this one, rather than left behind as a dangling
    /// duplicate placement. A user who wants to keep that old slot
    /// instead of freeing it wants Swap (`swapBlocks`), not Replace.
    func manualReplace(_ block: ScheduledBlock, with newTask: TaskItem) {
        let outgoing = block.task
        outgoing?.isScheduled = false
        outgoing?.pushedCount += 1

        for oldBlock in (newTask.scheduledBlocks ?? []) where oldBlock.id != block.id && !oldBlock.isCompleted {
            // The candidate keeps the time it had placed elsewhere — it's
            // moving to this block, not abandoning that work.
            removeBlock(oldBlock)
            blocks.removeAll { $0.id == oldBlock.id }
        }

        block.task = newTask
        newTask.isScheduled = true
        needsReapproval(block)

        if let idx = blocks.firstIndex(where: { $0.id == block.id }) {
            blocks[idx] = block
        }
    }

    /// The other option offered for a candidate that's already scheduled
    /// somewhere else (see `replaceCandidates`): rather than freeing the
    /// candidate's own slot the way Replace does, the two tasks trade
    /// places — `block`'s task takes over the candidate's old time, and
    /// the candidate takes over `block`'s time. Both stay scheduled
    /// throughout, just each in the other's spot, so neither task's own
    /// `isScheduled` flag needs to change.
    func swapBlocks(_ block: ScheduledBlock, with task: TaskItem) {
        guard let candidateBlock = (task.scheduledBlocks ?? []).first(where: { !$0.isCompleted }) else { return }
        let outgoing = block.task
        block.task = task
        candidateBlock.task = outgoing
        needsReapproval(block)
        needsReapproval(candidateBlock)

        let calendar = Calendar.current
        for affected in [block, candidateBlock] {
            if calendar.isDate(affected.date, inSameDayAs: targetDate) {
                if !blocks.contains(where: { $0.id == affected.id }) {
                    blocks.append(affected)
                }
            } else {
                blocks.removeAll { $0.id == affected.id }
            }
        }
        blocks.sort { $0.startTime < $1.startTime }
    }

    /// Which window a replacement/insertion candidate is being evaluated
    /// against — §8's eligibility/fit predicate (a rule whose window
    /// actually covers the target instant) is identical either way. What
    /// differs is the "already spoken for" exclusion and whether a fixed
    /// duration gets fit-checked: both contexts now let a candidate
    /// that's scheduled elsewhere through, gated the same "one movable
    /// block" way, but only `occupiedBlock` has a fixed slot size to fit
    /// against — an empty slot has none, so no candidate (scheduled or
    /// not) is fit-checked there; picking a task that doesn't fit its new
    /// spot just ripples the day to make room instead (see
    /// `moveExistingBlock`/`insertBlock`).
    enum CandidateSlotContext {
        /// Replace/Swap target. A candidate already scheduled elsewhere
        /// may still qualify, but only if it has a single, unlocked,
        /// incomplete block of its own to act on — Replace and Swap both
        /// need one movable block, not a guess at which piece of a
        /// divisible task's spread, or a user-pinned lock, should move.
        case occupiedBlock(ScheduledBlock)
        /// An empty slot — no existing occupant. A candidate already
        /// scheduled elsewhere still qualifies, under the identical
        /// "single, unlocked, incomplete block" gate `occupiedBlock`
        /// uses — picking one *moves* that block here
        /// (`moveExistingBlock`) rather than creating a second one;
        /// picking a genuinely unscheduled one still creates a fresh
        /// block (`insertBlock`), same as always. `includingInbox`
        /// widens the pool to unsorted (no-shelf) tasks too — only the
        /// long-press-to-insert popover wants that; the auto-scheduler's
        /// own candidate pool never includes Inbox tasks.
        case freeSlot(startTime: Date, includingInbox: Bool)
    }

    /// One task, evaluated against a `CandidateSlotContext` — `isEligible
    /// == false` only ever happens for `.freeSlot` (see
    /// `evaluateCandidates`'s own doc comment for why `.occupiedBlock`
    /// never produces one), and only for one of the three *soft*
    /// exclusions: no enabled scheduling rules on the shelf, the task's
    /// own `startDate` not reached yet, or no rule covering this slot's
    /// weekday/window that the task is actually eligible for.
    /// `ineligibleReason` names which, for `EmptySlotPickerSheet`'s
    /// caption — `nil` exactly when `isEligible` is `true`.
    struct CandidateEvaluation {
        let task: TaskItem
        let isEligible: Bool
        let ineligibleReason: String?
    }

    /// "MMM d" — same short-date pattern `TaskItem.recurrenceSummary`/
    /// `ShelfListView.TaskRow.pantryAgeText` already use, kept consistent
    /// for the "Starts Sep 12" ineligibility caption.
    private static let startDateReasonFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    /// "Outside Work – Afternoons" (names whichever of the task's own
    /// eligible rules exist, joined, since none of them cover this slot)
    /// or "Not eligible for any schedule" (the task isn't opted into
    /// anything on this shelf at all) — `EmptySlotPickerSheet`'s caption
    /// when the only failure is rule coverage. Same rule-name fallback
    /// (`displayName` unless empty, then `summary`) `ShelfListView
    /// .TaskRow.eligibleScheduleNames` already uses.
    private static func coverageReason(task: TaskItem, shelf: Shelf) -> String {
        let eligibleRuleNames = (shelf.schedulingRules ?? [])
            .filter { task.isEffectivelyEligible(for: $0) }
            .map { $0.displayName.isEmpty ? $0.summary : $0.displayName }
        guard !eligibleRuleNames.isEmpty else { return "Not eligible for any schedule" }
        return "Outside \(eligibleRuleNames.joined(separator: ", "))"
    }

    /// The single evaluation behind every "what can go here" picker. The
    /// Replace/Swap sheet, the empty-slot sheet, and Auto-Replace's own
    /// candidate pool used to each carry a separate, drifting copy of
    /// roughly this same predicate — one of them (the plain
    /// `unscheduledCandidates(from:)`, pre-§8) had drifted all the way to
    /// unused dead code, and another (Nightly Review's own Replace
    /// picker) had quietly ended up narrower than the other two Replace
    /// call sites. See `CandidateSlotContext` for what actually varies by
    /// caller.
    ///
    /// Every exclusion below is hard (the task is skipped outright, never
    /// appearing in the result) for `.occupiedBlock` — Replace/Swap and
    /// Auto-Replace have no UI for "included but grayed out" and don't
    /// want one. For `.freeSlot`, three specifically-marked checks are
    /// *soft* instead: the task still appears, `isEligible: false`, with
    /// a reason — placing something on the calendar by hand is a
    /// deliberate override of its own eligible-schedule constraint, per
    /// the empty-slot picker's own design. `replacementCandidates` below
    /// is just this, filtered to `isEligible` — the historical,
    /// eligible-only shape every other caller still wants, so there's
    /// exactly one evaluation, not a second copy that could drift from
    /// this one the way the pre-§8 versions did.
    func evaluateCandidates(from allTasks: [TaskItem], for context: CandidateSlotContext) -> [CandidateEvaluation] {
        let calendar = Calendar.current
        let startTime: Date
        let excludingTaskID: UUID?
        let blockDuration: Int?
        let allowsSoftIneligibility: Bool
        switch context {
        case .occupiedBlock(let block):
            startTime = block.startTime
            excludingTaskID = block.task?.id
            blockDuration = block.durationMinutes
            allowsSoftIneligibility = false
        case .freeSlot(let slotStart, _):
            startTime = slotStart
            excludingTaskID = nil
            blockDuration = nil
            allowsSoftIneligibility = true
        }
        let weekday = calendar.component(.weekday, from: startTime)

        var results: [CandidateEvaluation] = []
        for task in allTasks {
            // Hard, both contexts: already spoken for, completed, or a
            // Kitchen/Pantry task — never schedulable at all, regardless
            // of what its shelf's rules say (a kitchen shelf normally has
            // none, which is what excluded these before the "no enabled
            // rules" check below became soft; this keeps them out
            // explicitly instead of relying on that side effect).
            guard task.id != excludingTaskID, !task.isCompleted, !(task.shelf?.isKitchen ?? false) else { continue }

            switch context {
            case .occupiedBlock:
                if task.isScheduled {
                    let activeBlocks = (task.scheduledBlocks ?? []).filter { !$0.isCompleted }
                    guard activeBlocks.count <= 1, !(activeBlocks.first?.isLocked ?? false) else { continue }
                }
            case .freeSlot(_, let includingInbox):
                // A scheduled task may still qualify — picking it *moves*
                // its existing block here (see `moveExistingBlock`)
                // instead of creating a second one — but only under the
                // same "one movable block" gate `.occupiedBlock` already
                // uses just above: a divisible task spread across several
                // blocks, or one with a locked block, stays excluded
                // (hard — there's no single piece to gray out and let
                // through) rather than guessing which piece should move.
                if task.isScheduled {
                    let activeBlocks = (task.scheduledBlocks ?? []).filter { !$0.isCompleted }
                    guard activeBlocks.count <= 1, !(activeBlocks.first?.isLocked ?? false) else { continue }
                }
                if task.shelf == nil, !includingInbox { continue }
            }

            guard let shelf = task.shelf else {
                results.append(CandidateEvaluation(task: task, isEligible: true, ineligibleReason: nil)) // unsorted Inbox task — nothing further to check
                continue
            }

            // Soft (freeSlot only): no enabled rules on this shelf at all.
            guard shelf.hasEnabledSchedulingRules else {
                if allowsSoftIneligibility {
                    results.append(CandidateEvaluation(task: task, isEligible: false, ineligibleReason: "No scheduling rules"))
                }
                continue
            }
            // Soft (freeSlot only): this task's own start date hasn't
            // arrived yet.
            guard task.isEligibleToStart(on: startTime, calendar: calendar) else {
                if allowsSoftIneligibility {
                    let reason = task.startDate.map { "Starts \(Self.startDateReasonFormatter.string(from: $0))" } ?? "Not eligible to start yet"
                    results.append(CandidateEvaluation(task: task, isEligible: false, ineligibleReason: reason))
                }
                continue
            }

            // Soft (freeSlot only): no rule covering this slot's
            // weekday/window that the task is actually eligible for.
            let coveringRules = (shelf.schedulingRules ?? []).filter { rule in
                rule.isEnabled && rule.effectiveDaysOfWeek.contains(weekday) && Self.ruleWindow(rule, contains: startTime, calendar: calendar)
            }
            guard coveringRules.contains(where: { task.isEffectivelyEligible(for: $0) }) else {
                if allowsSoftIneligibility {
                    results.append(CandidateEvaluation(task: task, isEligible: false, ineligibleReason: Self.coverageReason(task: task, shelf: shelf)))
                }
                continue
            }

            // Hard, both contexts: a fixed slot size (occupiedBlock only
            // — freeSlot's blockDuration is always nil, so this never
            // trips there) the task's own duration can't fit into.
            if let blockDuration {
                let fitsWhole = task.estimatedMinutes > 0 && task.estimatedMinutes <= blockDuration
                let fitsDivisible = task.isEffectivelyDivisible && task.minimumSegmentMinutes > 0 && task.minimumSegmentMinutes <= blockDuration
                guard fitsWhole || fitsDivisible else { continue }
            }
            results.append(CandidateEvaluation(task: task, isEligible: true, ineligibleReason: nil))
        }
        return results
    }

    /// The historical, eligible-only shape — every caller except the
    /// empty-slot picker still wants exactly this. See
    /// `evaluateCandidates`'s own doc comment.
    func replacementCandidates(from allTasks: [TaskItem], for context: CandidateSlotContext) -> [TaskItem] {
        evaluateCandidates(from: allTasks, for: context).filter(\.isEligible).map(\.task)
    }

    private static func ruleWindow(_ rule: SchedulingRule, contains instant: Date, calendar: Calendar) -> Bool {
        guard
            let windowStart = calendar.date(bySettingHour: rule.effectiveStartHour, minute: rule.effectiveStartMinute, second: 0, of: instant),
            let windowEnd = calendar.date(bySettingHour: rule.effectiveEndHour, minute: rule.effectiveEndMinute, second: 0, of: instant),
            windowStart < windowEnd
        else { return false }
        return instant >= windowStart && instant < windowEnd
    }

    private func needsReapproval(_ block: ScheduledBlock) {
        if block.approvalStatus == .approved {
            block.approvalStatus = .proposed
        }
    }

    // MARK: - Today: complete / push to another day

    /// The timeline's tap-to-complete circle goes through here. A habit
    /// block stays exactly as it's always been — a plain two-state
    /// toggle, `HabitLog` (its own real, `.excused`-capable cycle) is
    /// that occurrence's actual source of truth, and out of scope for
    /// the three-state change. Un-tapping a habit block also resets that
    /// day's log, so the Habit Tracker (and its rolling stats, which read
    /// straight from the log) never disagrees with what the calendar
    /// shows. Everything else (an ordinary task block, or a meal block)
    /// delegates to `cycleBlockCompletion` — see that function's own doc
    /// comment.
    func toggleComplete(_ block: ScheduledBlock) {
        guard let habit = block.habit else {
            cycleBlockCompletion(block)
            return
        }
        block.isCompleted.toggle()
        // Only this block's own occurrence (BrushTeeth.1 vs .2, say) is
        // affected — the day-level status/streak/calendar stay pending
        // until every occurrence is resolved (see `Habit.status`).
        let status: OccurrenceStatus = block.isCompleted ? .complete : .none
        habitLog(for: habit, on: block.date).setOccurrence(block.habitOccurrenceIndex, to: status)
        HabitStatsRefreshCoordinator.shared.habitLogsChanged()
    }

    /// The three-state counterpart to the old two-state `toggleComplete`,
    /// for an ordinary (non-recurring, non-habit) task block or a meal
    /// block — "shelf task blocks" and "dinner on the calendar," the two
    /// kinds this change actually covers. Cycles `block.status`
    /// (`OccurrenceStatus.cycledExcludingExcused`, the one shared cycle
    /// every completion surface now uses — `TaskItem
    /// .cycleRecurringOccurrence`/`.cycleCompletion` are the other two
    /// callers) and mirrors it onto whichever real record the block
    /// represents:
    ///
    /// - A task block: `task.status` directly, not through the lossy
    ///   `isCompleted` setter — `.missed` needs to survive the mirror the
    ///   way it couldn't when this only ever flipped a plain `Bool` (see
    ///   `TaskItem.isCompleted`'s own doc comment). Landing on `.missed`
    ///   immediately guarantees a fresh placement — mirrors "marking
    ///   missed pushes immediately," the same reasoning a recurring
    ///   task's own interactive cycle already documents at `pushIfMissed`
    ///   — guarded on `!task.isScheduled` so re-cycling the same stale
    ///   block Missed → None → Missed again within one session can't
    ///   create a second placement while the first is still live.
    /// - A meal block: `MealSelection.status` directly. Landing on
    ///   `.complete` runs pantry deduction exactly once, guarded by
    ///   `hasDeductedPantry` rather than the current status, so cycling
    ///   Complete → Missed → Complete doesn't deduct twice.
    ///
    /// A recurring task's own block never reaches here at all — that's
    /// still `TaskItem.cycleRecurringOccurrence`'s own, separate
    /// immediate-write cycle (via `pushIfMissed`/
    /// `cycleRecurringTaskReviewOccurrence` in `NightlyReviewView`,
    /// `onCycleRecurringTaskOccurrence` on the calendar), untouched by
    /// this — `toggleComplete` never even calls this for one, and
    /// `NightlyReviewView`'s own `.block` tap handler branches on
    /// `task.isRecurring` before ever reaching this function.
    @discardableResult
    func cycleBlockCompletion(_ block: ScheduledBlock) -> OccurrenceStatus {
        let next = block.status.cycledExcludingExcused
        block.status = next

        if let task = block.task, !task.isRecurring {
            task.status = next
            if next == .complete {
                upsertCompletionRecord(for: task)
            } else {
                removeCompletionRecord(for: task)
            }
            // Task-side completion only — a habit/meal's own completion
            // never touches shelf-task scheduling at all, so it has
            // nothing to do with this flag.
            ScheduleDirtyState.shared.isDirty = true
            if next == .missed, !block.hasGuaranteedReplacement {
                // **Captured before anything is mutated** — these are the
                // values the undo restores, and two of them are about to be
                // overwritten. See `ScheduledBlock`'s own comment for why
                // they live on the block rather than in view state.
                block.remainingMinutesBeforeMiss = task.remainingMinutes
                block.wasScheduledBeforeMiss = task.isScheduled
                task.isScheduled = false
                task.pushedCount += 1
                // The old block stays (nothing deletes it anymore — see
                // this function's own doc comment) but is no longer an
                // active placement, so whatever of its duration wasn't
                // actually worked needs to go back to the task's own
                // ledger, the same restoration a real delete always
                // carried alongside it (`removeBlock`'s own doc comment)
                // — the missing half of that if this were skipped here.
                restoreRemainingMinutes(for: block)
                block.guaranteedReplacementBlockID = guaranteePlacement(
                    for: task, missedDate: block.date, missedStartTime: block.startTime, durationMinutes: block.durationMinutes
                )?.id
                block.hasGuaranteedReplacement = true
            } else if next != .missed, block.hasGuaranteedReplacement {
                // Leaving `.missed` in either direction — the cycle reaches
                // `.none` first and `.complete` on the tap after, and both
                // mean "this is no longer missed", so both must reverse the
                // push rather than only the one that happens to come next.
                undoGuaranteedPlacement(for: block, task: task)
            }
        }

        if let selection = block.mealSelection {
            selection.status = next
            if next == .complete, !selection.hasDeductedPantry {
                let recipes = (try? modelContext.fetch(FetchDescriptor<Recipe>())) ?? []
                let kitchenShelves = (try? modelContext.fetch(FetchDescriptor<Shelf>(
                    predicate: #Predicate { $0.isKitchen }
                ))) ?? []
                let pantryItems = (kitchenShelves.first?.tasks ?? []).filter { !$0.isCompleted }
                if let recipe = recipes.first(where: { $0.id == selection.recipeID }) {
                    PantryDeductionService.deduct(recipe: recipe, pantryItems: pantryItems)
                    selection.hasDeductedPantry = true
                }
            }
        }

        return next
    }

    /// See `TaskCompletionRecord.upsert(for:in:)`.
    func upsertCompletionRecord(for task: TaskItem) {
        TaskCompletionRecord.upsert(for: task, in: modelContext)
    }

    /// See `TaskCompletionRecord.remove(for:in:)`.
    private func removeCompletionRecord(for task: TaskItem) {
        TaskCompletionRecord.remove(for: task, in: modelContext)
    }

    /// Night Time Review's own sweep — every block still marked complete
    /// gets removed from the calendar entirely, task and habit alike.
    /// Deliberately *not* part of `regenerateFromNow`: a completed block
    /// stays visible (faded, struck through) through ordinary regenerates,
    /// and is only actually cleared out once Night Time Review runs.
    /// A task block's shelf task is deleted too — its stats already live
    /// independently in `TaskCompletionRecord` (upserted again here just
    /// in case this is somehow the first place that's ever seen it as
    /// complete). A habit block instead just loses the block itself — the
    /// habit and its completion history live independently in
    /// `Habit`/`HabitLog`, already updated the moment it was checked off
    /// (see `toggleComplete`), so there's nothing left to capture here.
    func purgeCompletedBlocks() async {
        let allBlocks = (try? modelContext.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        for block in allBlocks {
            guard block.isCompleted else { continue }
            if let task = block.task {
                upsertCompletionRecord(for: task)
                if let eventID = block.googleEventID {
                    try? await calendarService.deleteEvent(eventID: eventID)
                }
                removeBlock(block)
                blocks.removeAll { $0.id == block.id }
                // A recurring task (see `Shelf.isRecurringTasks`) is one
                // TaskItem shared across every occurrence's own block —
                // deleting it here the way a normal one-block task's is
                // would wipe out every future occurrence the moment a
                // single one gets swept.
                if !task.isRecurring {
                    modelContext.delete(task)
                }
            } else if block.habit != nil {
                if let eventID = block.googleEventID {
                    try? await calendarService.deleteEvent(eventID: eventID)
                }
                removeBlock(block)
                blocks.removeAll { $0.id == block.id }
            }
        }

        // A completed task with no block at all — the 2-Minute Task
        // shelf's tasks never get one (see `AISchedulingService`'s doc
        // comment), and the older Task Attribute Review "Mark Complete"
        // path (`TaskCardSheet`/`TaskReviewQueueSheet`) never created one
        // either — gets the same removal-from-shelf treatment here as a
        // completed block's task does above. Without this, a task
        // completed either of those ways would sit marked-done on its
        // shelf forever, since nothing else ever sweeps it.
        let allTasks = (try? modelContext.fetch(FetchDescriptor<TaskItem>())) ?? []
        for task in allTasks {
            guard task.isCompleted, !task.isRecurring, (task.scheduledBlocks ?? []).isEmpty else { continue }
            upsertCompletionRecord(for: task)
            modelContext.delete(task)
        }
    }

    /// A completed `MealSelection` has nothing further to say once
    /// tonight's review has committed it — same "nothing else ever
    /// sweeps it" problem `purgeCompletedBlocks` exists to solve for a
    /// completed block/task, called alongside it for the same reason.
    /// Without this, `NightlyReviewView.todayMealSelections`'s own
    /// `$0.isCompleted` clause has no date bound and matches every
    /// completed meal forever, since nothing else ever deletes the
    /// record — a dinner picked and checked off weeks ago would still
    /// surface in tonight's Today step alongside tonight's own meal.
    func purgeCompletedMealSelections() {
        // `$0.statusRaw == "complete"`, not `$0.isCompleted` — `#Predicate`
        // needs a real, persisted keypath; `isCompleted` is computed now
        // (see `MealSelection.isCompleted`'s own doc comment).
        let completed = (try? modelContext.fetch(FetchDescriptor<MealSelection>(
            predicate: #Predicate { $0.statusRaw == "complete" }
        ))) ?? []
        guard !completed.isEmpty else { return }

        // `ScheduledBlock.mealSelection` has no explicit delete rule, so
        // SwiftData defaults to `.nullify` — deleting the selection alone
        // leaves its block behind with `mealSelection` set to nil instead
        // of removing it. That orphan then passes `reviewableBlocks`'s own
        // `mealSelection == nil` filter (meant to exclude *live* meal
        // blocks, handled separately as `.meal`) and reappears as a
        // phantom "Open slot" row — same day, same 5pm slot as the dinner
        // that was just purged. Delete the block explicitly first, same
        // as `purgeCompletedBlocks` removes a block alongside its task
        // rather than relying on a cascade that isn't there.
        let completedIDs = Set(completed.map(\.id))
        let allBlocks = (try? modelContext.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        for block in allBlocks where block.mealSelection.map({ completedIDs.contains($0.id) }) ?? false {
            removeBlock(block)
            blocks.removeAll { $0.id == block.id }
        }

        for selection in completed {
            modelContext.delete(selection)
        }
    }

    /// Run at the start of every generate/regenerate — clears out every
    /// block (task or habit) left over from a day before today, so old
    /// days never just keep silently piling up unreviewed. An
    /// incomplete task goes back to its shelf, unscheduled, ready to be
    /// picked up by a future generate; a completed one is removed
    /// entirely (task and block alike, same as
    /// `purgeCompletedBlocks`) once its stats snapshot is captured. A
    /// habit block is just deleted — the habit itself, and its own
    /// completion history, live independently in `Habit`/`HabitLog`.
    private func clearBlocksBeforeToday() async {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let allBlocks = (try? modelContext.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        for block in allBlocks where calendar.startOfDay(for: block.date) < today {
            // **Completed blocks are still swept; incomplete ones are not.**
            // This used to delete every past block regardless of status,
            // which meant a missed day left no trace at all — completion
            // survived in `TaskCompletionRecord`, a miss had no equivalent
            // and simply vanished at midnight.
            guard block.isCompleted else {
                retainPastIncompleteBlock(block, calendar: calendar)
                continue
            }
            if let task = block.task {
                upsertCompletionRecord(for: task)
                // See the matching comment in `purgeCompletedBlocks` —
                // a recurring task's single TaskItem is shared across
                // every occurrence, so it survives past its own
                // completed block.
                if !task.isRecurring {
                    modelContext.delete(task)
                }
            }
            if let eventID = block.googleEventID {
                try? await calendarService.deleteEvent(eventID: eventID)
            }
            removeBlock(block)
            blocks.removeAll { $0.id == block.id }
        }
        try? modelContext.save()
    }

    /// Turns a past incomplete block into history rather than deleting it.
    ///
    /// Three things happen, and leaving any one out is its own bug:
    ///
    /// 1. **`.none` becomes `.missed`.** The day ended and it didn't happen,
    ///    so `.missed` is simply true — and it is what makes the record
    ///    legible. A retained `.none` block renders *identically to live
    ///    work* (empty circle, full opacity, tappable), so scrolling back a
    ///    month would show days full of things that look like they are still
    ///    to do. The calendar's existing three-state rendering already draws
    ///    `.missed` as faded with a red X, so this needs no new visual
    ///    treatment — only an honest status.
    ///
    /// 2. **The minutes go back to the task's ledger.** `removeBlock` did
    ///    this on the way out (see `restoreRemainingMinutes`); nothing else
    ///    does it now that the block survives. Without it the work is owed
    ///    but not counted, so the packer never re-places it.
    ///
    /// 3. **The task is unscheduled.** Same as before. It still has
    ///    unfinished work, and leaving `isScheduled == true` pointing at a
    ///    block that can never run means it is never placed again.
    ///
    /// The Google Calendar event is deleted and its id cleared: the block is
    /// now a record of something that did not happen, and leaving a live
    /// event on the real calendar for it would be a forward-looking
    /// commitment this no longer represents.
    private func retainPastIncompleteBlock(_ block: ScheduledBlock, calendar: Calendar) {
        if block.status == .none {
            block.status = .missed
        }
        restoreRemainingMinutes(for: block)
        block.task?.isScheduled = false
        if let eventID = block.googleEventID {
            Task { try? await calendarService.deleteEvent(eventID: eventID) }
            block.googleEventID = nil
        }
        blocks.removeAll { $0.id == block.id }
    }

    private func habitLog(for habit: Habit, on date: Date) -> HabitLog {
        habit.logOrCreate(on: date, context: modelContext)
    }

    // MARK: - Regenerate prompt: review vs. assume not completed

    /// Every not-yet-completed block from today or an earlier day, oldest
    /// first — the shared "what needs a decision" list for both Nightly
    /// Review's Today step and the Regenerate button's "Review Previous
    /// Events" option. A block still in the future (later today or beyond)
    /// isn't "done or not" yet, so it's never included here.
    static func reviewableBlocks(from allBlocks: [ScheduledBlock]) -> [ScheduledBlock] {
        allBlocks
            .filter { !$0.isCompleted && $0.startTime < .now }
            .sorted { $0.startTime < $1.startTime }
    }

    /// Whether regenerating should even bother asking — gated on whatever's
    /// already elapsed (any previous day in full, plus today up to right
    /// now — a block later today hasn't happened yet, so it's not
    /// "overdue"): if nothing's left over from before this exact moment,
    /// there's no meaningful difference between the two choices, so the
    /// prompt is skipped entirely and Regenerate just runs.
    static func hasIncompletePastBlocks(in allBlocks: [ScheduledBlock]) -> Bool {
        allBlocks.contains { !$0.isCompleted && $0.startTime < .now }
    }

    /// Stand-in minutes-since-midnight for an AM/Midday/PM occurrence —
    /// same idea as `Habit.nextTargetDate`'s own fallback times, kept
    /// separate since `openHabitOccurrencesForReview`'s ordering is by
    /// this exact stand-in time rather than that property.
    private static func targetMinutes(for mode: HabitOccurrenceTimeMode) -> Int {
        switch mode {
        case .am: return 6 * 60
        case .midday: return 12 * 60
        case .pm: return 21 * 60
        case .specific: return 0
        }
    }

    /// **Operational list — governs what the sweep acts on.** Do not
    /// widen this to admit more statuses for display purposes; see
    /// `allHabitOccurrencesForReview` below for that.
    ///
    /// AM/Midday/PM habit occurrences (see `HabitOccurrenceTimeMode`)
    /// genuinely still open (`.none`) as of `cutoff`, PLUS any occurrence
    /// whose id appears in `alsoInclude` regardless of its current status
    /// — the habit counterpart to `reviewableBlocks`/`hasIncompletePastBlocks`,
    /// needed because these never get a `ScheduledBlock` of their own (a
    /// Specific-Time occurrence doesn't need this, it already shows up as
    /// a real block those two already cover). Walks backward from
    /// `cutoff`'s own day so one left unchecked yesterday (or further
    /// back) still turns up, same reasoning `reviewableBlocks` pulls in
    /// backlog from any earlier day — bounded by each habit's own
    /// `startDate`, capped at 400 days back so a very old habit can't
    /// turn this into an unbounded scan. Filtered by exact `targetTime`,
    /// not just by day, so (unlike a same-day block) a PM habit isn't
    /// treated as "overdue" the moment its day starts.
    ///
    /// `alsoInclude` is what lets a row the caller just toggled to
    /// complete keep showing — faded and struck through, `isCompleted`
    /// now genuinely `true` — instead of vanishing the instant it drops
    /// out of the `.none` set, the same way a completed task's block
    /// stays visible in `reviewableBlocks` instead of disappearing. It's
    /// the caller's job to remember which ids it's touched — this
    /// function only decides whether to include a given id, never which
    /// ones a caller cares about remembering. `NightlyReviewView` no
    /// longer needs this parameter itself: its Today step now stages taps
    /// instead of writing immediately (see `stagedTodayToggleIDs`), so the
    /// real status never changes while that step is on screen and the
    /// `.none` filter below never has anything to exclude yet. Kept for
    /// any future caller that still wants the old immediate-write, keep-
    /// visible-after-toggling behavior.
    /// `context` is required rather than optional because this list feeds a
    /// **write**: `markUnresolvedHabitOccurrencesAsMissed` iterates it and
    /// writes `.missed` to everything it reports as unresolved. Reading
    /// through the `habit.logs` relationship here meant a habit completed
    /// today but not yet saved read as `.none`, qualified as unresolved,
    /// and had its completion overwritten with a miss — no rapid tapping
    /// required, just completing a habit and opening Nightly Review before
    /// a save landed. See `Habit.log(on:context:)`.
    /// `completedSince`, unlike `alsoInclude`, isn't id-based — it widens
    /// the *status* filter itself: any occurrence whose own day is
    /// strictly after this date is included even when `.complete`, not
    /// just `.none`. Lets a caller show "everything completed since the
    /// last review" (an occurrence checked off earlier today, before this
    /// review session ever opened) without the caller having to have
    /// already seen and remembered that occurrence's id the way
    /// `alsoInclude` requires. `nil` (the default) preserves the original
    /// `.none`-only behavior for every other caller. Strictly-after, not
    /// on-or-after: `completedSince` is `lastClosedReviewDay`, the day
    /// *already* closed out by the previous review session — a habit
    /// completed on that day was already surfaced and handled then, so
    /// including it again here would leak it into one extra review cycle.
    /// `NightlyReviewView.reviewCutoff`/`.reviewDisplayCutoff`'s shared
    /// formula — extracted purely for testability (matching
    /// `projectedRecurringTaskOccurrences`'s `today` parameter reasoning),
    /// since both properties are otherwise private `View` state. The two
    /// were deliberately different once: `reviewCutoff` used to clamp to
    /// `min(.now, dayEnd)` so an operational decision (mark missed, clear
    /// a stale block) never acted on a time that hadn't happened yet.
    /// That clamp is gone now — see `NightlyReviewView.reviewCutoff`'s own
    /// doc comment for why treating a not-yet-passed time as still
    /// "elapsed" once you're doing the Today→Tomorrow handoff is the
    /// correct call, not a bug — so this is now a pure function of
    /// `reviewDate` alone, the end of that day, full stop.
    static func nightlyReviewOperationalCutoff(reviewDate: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 1, to: reviewDate) ?? reviewDate
    }

    /// `DayTimelineGridView.openHabitOccurrences`'s core logic, extracted
    /// so it's unit-testable without constructing a live view. Every
    /// occurrence whose own `HabitOccurrenceTimeMode` is `mode` — no
    /// status filter: `OccurrenceStatus` has exactly four cases and every
    /// one of them must render now that a tap can cycle through all four
    /// (see `DayTimelineGridView.toggleHabitOccurrence`). Excluding
    /// `.excused` here (as an earlier version of this did) would make a
    /// row disappear mid-cycle with no way to tap it back out again.
    static func openHabitOccurrences(habits: [Habit], mode: HabitOccurrenceTimeMode, targetDate: Date, context: ModelContext, calendar: Calendar = .current) -> [(habit: Habit, index: Int, status: OccurrenceStatus)] {
        var result: [(habit: Habit, index: Int, status: OccurrenceStatus)] = []
        for habit in habits.sorted(by: { $0.sortOrder < $1.sortOrder }) where habit.isApplicable(on: targetDate, calendar: calendar) {
            let log = habit.log(on: targetDate, context: context, calendar: calendar)
            for index in 0..<max(habit.timesPerDay, 1) {
                guard habit.timeMode(for: index) == mode else { continue }
                let status = log?.occurrenceStatus(index) ?? .none
                result.append((habit: habit, index: index, status: status))
            }
        }
        return result
    }

    static func openHabitOccurrencesForReview(habits: [Habit], context: ModelContext, upTo cutoff: Date = .now, alsoInclude: Set<String> = [], completedSince: Date? = nil) -> [HabitReviewOccurrence] {
        let calendar = Calendar.current
        let cutoffDay = calendar.startOfDay(for: cutoff)
        let completedSinceDay = completedSince.map { calendar.startOfDay(for: $0) }
        var result: [HabitReviewOccurrence] = []
        for habit in habits {
            let earliestDay = calendar.startOfDay(for: habit.startDate)
            let scanFloorDay = calendar.date(byAdding: .day, value: -400, to: cutoffDay) ?? earliestDay
            let boundedEarliestDay = max(earliestDay, scanFloorDay)
            guard boundedEarliestDay <= cutoffDay else { continue }

            var cursor = cutoffDay
            while cursor >= boundedEarliestDay {
                if habit.isApplicable(on: cursor, calendar: calendar) {
                    for index in 0..<max(habit.timesPerDay, 1) {
                        let mode = habit.timeMode(for: index)
                        guard mode != .specific else { continue }
                        let targetTime = calendar.date(byAdding: .minute, value: targetMinutes(for: mode), to: cursor) ?? cursor
                        guard targetTime < cutoff else { continue }
                        let id = "\(habit.id)-\(index)-\(Int(cursor.timeIntervalSince1970))"
                        let status = habit.occurrenceStatus(index, on: cursor, context: context, calendar: calendar)
                        let completedRecently = status == .complete && completedSinceDay.map { cursor > $0 } ?? false
                        guard status == .none || alsoInclude.contains(id) || completedRecently else { continue }
                        result.append(HabitReviewOccurrence(id: id, habit: habit, index: index, status: status, targetTime: targetTime, modeLabel: mode.label))
                    }
                }
                guard let previousDay = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
                cursor = previousDay
            }
        }
        return result
    }

    /// **Display list — every habit occurrence, any status.** The
    /// counterpart to `openHabitOccurrencesForReview` (the **operational**
    /// list, `.none`-only) below: this one has no status filter at all,
    /// so a habit already resolved (complete/missed/excused) before
    /// tonight's review ever opened still shows up, in whatever state
    /// it's actually in, instead of being invisible the way the filtered
    /// list would make it. Otherwise structurally identical — same
    /// backward day-scan (bounded by each habit's own `startDate`, capped
    /// at 400 days back), same `targetTime < cutoff` bound, same `.specific`
    /// exclusion.
    ///
    /// A resolved occurrence (anything but `.none`) is further bounded to
    /// `cursor > completedSinceDay` — the same "strictly after the day the
    /// previous review closed" rule `openHabitOccurrencesForReview`'s own
    /// `completedRecently` already uses for `.complete`, generalized here
    /// to all three resolved statuses. Without this, a long-running habit
    /// with months of `.complete` days behind it would flood *every*
    /// future review with its entire history the backward scan can reach —
    /// the same 400-day floor that's appropriate for "how far back could
    /// an unresolved backlog item still matter" is very much not
    /// appropriate for "how far back should an already-handled day keep
    /// reappearing." An unresolved (`.none`) occurrence has no such bound —
    /// it's still open, so it keeps showing regardless of age, same as
    /// today. `completedSinceDay == nil` (no review has ever closed) falls
    /// back to `.distantPast`, i.e. no bound — acceptable only because
    /// it's a one-time, first-ever-review edge case.
    ///
    /// **Never used to decide what gets swept — this is a parallel,
    /// independent function, not a modification of the operational one.**
    /// `markUnresolvedHabitOccurrencesAsMissed` must keep calling
    /// `openHabitOccurrencesForReview` directly, live and unfrozen; only
    /// *that* filter is what actually protects the untimed path from
    /// corruption (see the spec's "What actually protects the untimed
    /// path") — weakening or bypassing it, even by feeding the sweep from
    /// this function instead, would reopen exactly what it protects
    /// against, regardless of any guard downstream. This function exists
    /// solely to feed `NightlyReviewView.frozenTodayHabitOccurrences`, the
    /// display-only frozen snapshot.
    static func allHabitOccurrencesForReview(habits: [Habit], context: ModelContext, upTo cutoff: Date = .now, completedSince: Date?, calendar: Calendar = .current) -> [HabitReviewOccurrence] {
        let cutoffDay = calendar.startOfDay(for: cutoff)
        let completedSinceDay = calendar.startOfDay(for: completedSince ?? .distantPast)
        var result: [HabitReviewOccurrence] = []
        for habit in habits {
            let earliestDay = calendar.startOfDay(for: habit.startDate)
            let scanFloorDay = calendar.date(byAdding: .day, value: -400, to: cutoffDay) ?? earliestDay
            let boundedEarliestDay = max(earliestDay, scanFloorDay)
            guard boundedEarliestDay <= cutoffDay else { continue }

            var cursor = cutoffDay
            while cursor >= boundedEarliestDay {
                if habit.isApplicable(on: cursor, calendar: calendar) {
                    for index in 0..<max(habit.timesPerDay, 1) {
                        let mode = habit.timeMode(for: index)
                        guard mode != .specific else { continue }
                        let targetTime = calendar.date(byAdding: .minute, value: targetMinutes(for: mode), to: cursor) ?? cursor
                        guard targetTime < cutoff else { continue }
                        let status = habit.occurrenceStatus(index, on: cursor, context: context, calendar: calendar)
                        guard status == .none || cursor > completedSinceDay else { continue }
                        let id = "\(habit.id)-\(index)-\(Int(cursor.timeIntervalSince1970))"
                        result.append(HabitReviewOccurrence(id: id, habit: habit, index: index, status: status, targetTime: targetTime, modeLabel: mode.label))
                    }
                }
                guard let previousDay = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
                cursor = previousDay
            }
        }
        return result
    }

    /// **Operational list — `.none` only.** `NightlyReviewView
    /// .openHabitOccurrencesForReview`'s core logic (the display-side
    /// wrapper of the same name), extracted so it's unit-testable without
    /// constructing a live view. Re-derives each `frozen` occurrence's
    /// `status` fresh, right now, rather than trusting whatever it was at
    /// the moment `frozen` was captured — this is the "live" half of the
    /// frozen-snapshot design that keeps a Nightly Review habit row
    /// visible (frozen identity) while still showing whichever of the
    /// four states it's actually in right now (live status), rather than
    /// the state it was in when the step was entered. `frozen` itself now
    /// comes from `allHabitOccurrencesForReview` (every status) rather
    /// than this file's own `openHabitOccurrencesForReview` (`.none`
    /// only) — freezing the *filtered* call's result would have meant an
    /// already-resolved habit never entered the frozen set to begin with,
    /// which is the exact gap `allHabitOccurrencesForReview` exists to
    /// close.
    static func refreshedHabitReviewOccurrences(frozen: [HabitReviewOccurrence], context: ModelContext, calendar: Calendar = .current) -> [HabitReviewOccurrence] {
        frozen.map { occurrence in
            let day = calendar.startOfDay(for: occurrence.targetTime)
            let status = occurrence.habit.occurrenceStatus(occurrence.index, on: day, context: context, calendar: calendar)
            return HabitReviewOccurrence(id: occurrence.id, habit: occurrence.habit, index: occurrence.index, status: status, targetTime: occurrence.targetTime, modeLabel: occurrence.modeLabel)
        }
    }

    /// **The Today-step "Next" gate's core predicate — habits only.**
    /// `NightlyReviewView.unresolvedHabitOccurrences`'s logic, extracted
    /// so it's unit-testable without constructing a live view (its
    /// `@Query` properties make that impractical).
    ///
    /// Ordinary task blocks and meals are gated separately now (see
    /// `NightlyReviewView.unresolvedGateReviewItems`, which covers both) —
    /// not folded into this same function, since a habit occurrence's own
    /// eligible-status set (`complete`/`missed`/`excused`, `Habit
    /// .cycleOccurrence`'s own four-state cycle) is different from a task
    /// block or meal's (`complete`/`missed`, `OccurrenceStatus
    /// .cycledExcludingExcused`'s three-state one, `.excused` never
    /// reachable). Both share the same underlying idea now, though:
    /// `.none` is "not actually looked at yet," never an accepted final
    /// state, and both reach a genuine terminal state in a bounded number
    /// of taps — this stopped being habit-specific the moment `.missed`
    /// became a real, deliberate answer for a block or meal too, instead
    /// of a stand-in for "not done" that the push-forward pipeline
    /// (`ScheduleReviewViewModel.cycleBlockCompletion`'s guaranteed-
    /// placement trigger, the meal backlog in `todayMealSelections`) was
    /// built to silently absorb.
    static func unresolvedHabitOccurrences(_ occurrences: [HabitReviewOccurrence]) -> [HabitReviewOccurrence] {
        occurrences.filter { $0.status == .none }
    }

    /// Unresolved occurrences from days **before** `reviewDate` — the ones
    /// that actually block Next on the Habits step.
    ///
    /// The review day's own are deliberately excluded. A habit due this
    /// evening may still legitimately happen: planning tomorrow at 9pm and
    /// being made to declare the 10pm habit missed or done is a false
    /// choice. Backlog from earlier days is different — those days are over,
    /// and nothing about them is still pending.
    ///
    /// **`reviewDate`, not the wall clock.** That is the day being closed
    /// out, and it is what every other boundary in this step already uses
    /// (`nightlyReviewOperationalCutoff` is `reviewDate + 1`). Under "Plan
    /// Today" the review date is *yesterday*, so the split lands there too —
    /// which is right: yesterday is the day being closed, so yesterday's
    /// habits are the ones still live.
    ///
    /// Compared by day rather than by instant, or a 9pm occurrence would
    /// block while a 9am one on the same date didn't.
    static func backlogHabitOccurrences(
        _ occurrences: [HabitReviewOccurrence],
        before reviewDate: Date,
        calendar: Calendar = .current
    ) -> [HabitReviewOccurrence] {
        let reviewDay = calendar.startOfDay(for: reviewDate)
        return unresolvedHabitOccurrences(occurrences)
            .filter { calendar.startOfDay(for: $0.targetTime) < reviewDay }
    }


    /// `NightlyReviewView.completedTasksWithNoBlock`'s core logic,
    /// extracted so the day-granularity bound (via `NightlyReviewCompletionState
    /// .completedSinceBound`) is unit-testable without constructing a live
    /// view. Same completion-record source, same has-no-live-block filter
    /// as before extraction — see that property's own doc comment for why
    /// `TaskCompletionRecord` rather than `allTasks` directly.
    static func completedTasksWithNoBlock(tasks: [TaskItem], context: ModelContext, completedSince: Date?) -> [TaskCompletionRecord] {
        let since = NightlyReviewCompletionState.completedSinceBound(closedDay: completedSince)
        let records = (try? context.fetch(FetchDescriptor<TaskCompletionRecord>(
            predicate: #Predicate { $0.completedAt >= since }
        ))) ?? []
        let liveTasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        return records.filter { record in
            guard let task = liveTasksByID[record.taskID] else { return true }
            return (task.scheduledBlocks ?? []).isEmpty
        }
    }

    /// `NightlyReviewView.reviewableBlocks`'s core logic, extracted for
    /// the same reason as `completedTasksWithNoBlock` above.
    ///
    /// `.none` and a *resolved* status (`.complete`/`.missed`) are
    /// bounded in opposite directions, deliberately: an unresolved
    /// (`.none`) block shows regardless of age (`startTime <
    /// reviewDisplayCutoff`, no lower bound) — a backlog left over from a
    /// busy week shouldn't quietly disappear, see this property's
    /// non-extracted doc comment for the original reasoning. A *resolved*
    /// block instead needs `startTime >= completedSinceBound` — no upper
    /// bound, so one resolved ahead of its scheduled day still shows
    /// without waiting for that future day's own review — but WITH a
    /// lower bound, so a resolved block from a review already closed out
    /// doesn't resurface the instant a later review runs. **This is now
    /// what actually bounds the `.missed` backlog** — `.missed` isn't
    /// deleted anymore (see `resolveMissedPastBlocks`'s own doc comment
    /// for the reversal), so this recency window is the only thing
    /// keeping an old, already-resolved missed block from piling up in
    /// every future Today step forever, exactly the role
    /// `RecurringTaskLog`'s own `.none`-only "still open" filter already
    /// plays for recurring tasks.
    static func reviewableBlocks(allBlocks: [ScheduledBlock], reviewDisplayCutoff: Date, completedSinceBound: Date) -> [ScheduledBlock] {
        allBlocks
            .filter {
                guard $0.mealSelection == nil else { return false }
                switch $0.status {
                case .none: return $0.startTime < reviewDisplayCutoff
                case .complete, .missed, .excused: return $0.startTime >= completedSinceBound
                }
            }
            .sorted { $0.startTime < $1.startTime }
    }

    /// `NightlyReviewView.todayMealSelections`'s core logic, extracted for
    /// the same reason as `reviewableBlocks` above — same `.none`-vs-
    /// resolved split, same reasoning: an unresolved selection shows
    /// regardless of age (no lower bound), a resolved one (`.complete` or
    /// — now that missed meals aren't deleted either, see
    /// `ScheduleReviewViewModel`'s meal-reversal doc comments —
    /// `.missed`) needs `date >= completedSinceBound` so it doesn't
    /// resurface once a later review has closed the book on it.
    static func todayMealSelections(allMealSelections: [MealSelection], cutoffDay: Date, completedSinceBound: Date) -> [MealSelection] {
        allMealSelections.filter {
            switch $0.status {
            case .none: return $0.date <= cutoffDay
            case .complete, .missed, .excused: return $0.date >= completedSinceBound
            }
        }
    }


    /// Task IDs whose most recent occurrence at or before `today` is still
    /// unresolved and needs to display as carried forward onto
    /// `targetDate` — a stand-in for the real `PushedRecurringOccurrence`
    /// Nightly Review would eventually create, shown without waiting for
    /// that to run. Display only: writes nothing, creates no records.
    ///
    /// Bounded exactly the way `PushedRecurringOccurrence.advanceOneHop`
    /// already bounds a *real* pushed occurrence at runtime: stops the
    /// moment the task's own next real recurrence day arrives, since the
    /// ordinary pattern takes back over there — an incomplete monthly task
    /// shows every day from `today` until its next pattern day, then hands
    /// off, never past it. `TaskItem.previousRecurringOccurrenceDate`/
    /// `nextRecurringOccurrenceDate` both cap their own walks (400/366
    /// days), so neither direction can scan unboundedly on an old daily
    /// task, and a task whose next occurrence falls outside that cap is
    /// treated as "never project" rather than "project forever."
    ///
    /// Shared between `DayTimelineGridView.openRecurringTaskOccurrences`
    /// (untimed) and `.projectedRecurringTaskOccurrences` (Specific-Time)
    /// so the carry-forward rule itself lives in exactly one place — only
    /// the display wrapper differs per mode, avoiding two near-copies of
    /// the same rule drifting apart. `alreadyCoveredTaskIDs` (a real
    /// `PushedRecurringOccurrence` already sitting on `targetDate`, or a
    /// real `ScheduledBlock` there) is the caller's job to supply, since
    /// both callers already have that data for their own reasons — this
    /// only excludes what it's told to, so a task never gets a duplicate
    /// row alongside its own real one. Excludes `!task.isPushable` tasks
    /// outright — this is a display stand-in for a real
    /// `PushedRecurringOccurrence` (see `pushRecurringOccurrenceIfNeeded`,
    /// which never creates one for such a task either), so it must not
    /// show a carry-forward that the real mechanism would never produce.
    static func carriedForwardRecurringTaskIDs(tasks: [TaskItem], targetDate: Date, alreadyCoveredTaskIDs: Set<UUID>, context: ModelContext, calendar: Calendar = .current, today: Date = .now) -> Set<UUID> {
        let targetDay = calendar.startOfDay(for: targetDate)
        let todayDay = calendar.startOfDay(for: today)
        guard targetDay > todayDay else { return [] }
        var result: Set<UUID> = []
        for task in tasks where task.isRecurring && task.isPushable {
            guard !alreadyCoveredTaskIDs.contains(task.id) else { continue }
            guard !task.hasRecurringOccurrence(on: targetDay, calendar: calendar) else { continue }
            guard let lastDay = task.previousRecurringOccurrenceDate(onOrBefore: todayDay, calendar: calendar) else { continue }
            guard !isRecurringTaskOccurrenceComplete(task: task, on: lastDay, context: context, calendar: calendar) else { continue }
            let dayAfterLast = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay
            guard let nextOccurrence = task.nextRecurringOccurrenceDate(asOf: dayAfterLast, calendar: calendar) else { continue }
            let handoffDay = calendar.startOfDay(for: nextOccurrence)
            guard targetDay < handoffDay else { continue }
            result.insert(task.id)
        }
        return result
    }
    /// Shared by `carriedForwardRecurringTaskIDs` — completion for a given
    /// day, checking whichever store that mode could plausibly have
    /// written to: a completed `ScheduledBlock` for a Specific-Time task
    /// (its long-standing completion store), or `RecurringTaskLog` for
    /// either mode (the untimed modes' own store, and — since a projected
    /// Specific-Time occurrence with no block writes here too, see
    /// `projectedRecurringTaskOccurrences` — the only place a *projected*
    /// Specific-Time completion could have landed).
    static func isRecurringTaskOccurrenceComplete(task: TaskItem, on day: Date, context: ModelContext, calendar: Calendar = .current) -> Bool {
        // KEPT DESPITE BEING UNREACHABLE FOR NEW DATA — do not delete.
        //
        // No recurring task can be Specific Time any more, so nothing will
        // create another block for one. But `migrateRecurringSpecificTimeTasksIfNeeded`
        // deliberately keeps *past and completed* blocks: they're the record
        // that the occurrence actually happened. This is the only thing that
        // still reads them. Deleting it would silently report a genuinely
        // completed historical occurrence as incomplete — four lines saved
        // in exchange for losing a user's completion history.
        if task.recurrenceTimeMode == .specific {
            let hasCompletedBlock = (task.scheduledBlocks ?? []).contains { calendar.isDate($0.date, inSameDayAs: day) && $0.isCompleted }
            if hasCompletedBlock { return true }
        }
        return RecurringTaskLog.log(taskID: task.id, on: day, context: context, calendar: calendar)?.isCompleted ?? false
    }

    /// `DayTimelineGridView.refreshHabitStreaks`'s core logic, extracted
    /// for the same reason as `projectedRecurringTaskOccurrences` above —
    /// deliberately *not* new streak math, just `Habit.currentStreak(asOf:)`
    /// (already signed, via `HabitStats.currentStreakDisplay`) called once
    /// per habit and collected, so a test can confirm the cache a calendar
    /// screen shows genuinely tracks `asOf` rather than silently drifting
    /// to always mean "today."
    ///
    /// Clamped to `min(date, today)` — `Habit.currentStreak(asOf:)` walks
    /// every applicable day up to its reference date, counting one with no
    /// log at all as a miss (see `Habit.status(on:asOf:)`). Passing a
    /// *future* `date` straight through would count every day between
    /// today and then as a miss that hasn't happened yet, reading more
    /// negative the further forward you navigate. A *past* `date` is left
    /// unclamped — that's a real as-of value someone genuinely wants (what
    /// the streak was on that day), not a projection into days that don't
    /// exist yet. `today` is a parameter (defaulting to `.now`), same
    /// reasoning as `projectedRecurringTaskOccurrences`'s own `today` —
    /// purely for testability, production callers never override it.
    static func habitStreaks(for habits: [Habit], asOf date: Date, calendar: Calendar = .current, today: Date = .now) -> [UUID: Int] {
        let clampedDate = min(date, today)
        return Dictionary(uniqueKeysWithValues: habits.map { ($0.id, $0.currentStreak(asOf: clampedDate, calendar: calendar)) })
    }

    static func hasOpenHabitOccurrences(habits: [Habit], context: ModelContext, upTo cutoff: Date = .now) -> Bool {
        !openHabitOccurrencesForReview(habits: habits, context: context, upTo: cutoff).isEmpty
    }

    /// One AM/Midday/PM recurring `TaskItem` occurrence — the task
    /// counterpart to `HabitReviewOccurrence`, same fields for the same
    /// reasons (`targetTime` is a stand-in, never shown, used purely for
    /// sorting/grouping into `OverdueBlocksReviewList`; `modeLabel` is
    /// what the row actually shows in its place). `status` is `.none` for
    /// every occurrence this operational list (`openRecurringTaskOccurrencesForReview`)
    /// produces — it exists on this struct only because
    /// `allRecurringTaskOccurrencesForReview` (the display list) shares
    /// the same type and needs to carry a real one.
    struct RecurringTaskReviewOccurrence: Identifiable {
        let id: String
        let task: TaskItem
        let status: OccurrenceStatus
        let targetTime: Date
        let modeLabel: String
    }

    /// **Operational list — governs what the sweep/push logic acts on.**
    /// Do not widen this to admit more statuses for display purposes; see
    /// `allRecurringTaskOccurrencesForReview` below for that — same split,
    /// same reasoning, as `openHabitOccurrencesForReview`/
    /// `allHabitOccurrencesForReview`.
    ///
    /// AM/Midday/PM recurring-`TaskItem` occurrences genuinely still open
    /// as of `cutoff` — the task counterpart to `openHabitOccurrencesForReview`,
    /// needed for the same reason: an occurrence in this mode never gets a
    /// `ScheduledBlock` of its own (see `TaskItem.recurrenceTimeMode`'s own
    /// doc comment), so `reviewableBlocks` can never surface a missed one,
    /// and — unlike habits — nothing else in Nightly Review ever checked
    /// `RecurringTaskLog` either. That's the whole bug: a miss here
    /// evaporated with no trace at all.
    ///
    /// Walks **forward** from each task's own bounded floor to `cutoff`
    /// (the habit version walks backward) so results come back
    /// oldest-occurrence-first per task — callers collapse this to at most
    /// one `PushedRecurringOccurrence` per task (see
    /// `pushMissedRecurringOccurrences`), and that record's `originalDate`
    /// should be the *earliest* unresolved miss, not whichever day this
    /// happened to check last.
    ///
    /// Completion is read through `RecurringTaskLog.log(taskID:on:context:)`
    /// — the fetch-based reader that sees a pending, unsaved log — never a
    /// relationship traversal, for the same reason `Habit.occurrenceStatus`
    /// requires `context:` instead of reading `habit.logs` (see that
    /// function's own doc comment): this list feeds a **write** decision
    /// (`pushMissedRecurringOccurrences` inserts a `PushedRecurringOccurrence`
    /// from it), and `RecurringTaskLog.taskID` isn't even a relationship —
    /// there's no relationship-based reader to reach for by mistake here in
    /// the first place.
    static func openRecurringTaskOccurrencesForReview(tasks: [TaskItem], context: ModelContext, upTo cutoff: Date = .now, calendar: Calendar = .current) -> [RecurringTaskReviewOccurrence] {
        let cutoffDay = calendar.startOfDay(for: cutoff)
        var result: [RecurringTaskReviewOccurrence] = []
        for task in tasks where task.isRecurring && task.recurrenceTimeMode != .specific {
            guard let anchor = task.dueDate else { continue }
            let anchorDay = calendar.startOfDay(for: anchor)
            guard anchorDay <= cutoffDay else { continue }
            // Same 400-day safety cap as the habit version, for the same
            // reason: bounds a very old task's scan without changing
            // behavior for anything realistic.
            let scanFloorDay = calendar.date(byAdding: .day, value: -400, to: cutoffDay) ?? anchorDay
            var cursor = max(anchorDay, scanFloorDay)
            while cursor <= cutoffDay {
                if task.hasRecurringOccurrence(on: cursor, calendar: calendar) {
                    let targetTime = calendar.date(byAdding: .minute, value: targetMinutes(for: task.recurrenceTimeMode), to: cursor) ?? cursor
                    if targetTime < cutoff {
                        let status = RecurringTaskLog.log(taskID: task.id, on: cursor, context: context, calendar: calendar)?.status ?? .none
                        if status == .none {
                            result.append(RecurringTaskReviewOccurrence(id: "\(task.id)-\(Int(cursor.timeIntervalSince1970))", task: task, status: status, targetTime: targetTime, modeLabel: task.recurrenceTimeMode.label))
                        }
                    }
                }
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = nextDay
            }
        }
        return result
    }

    /// **Display list — every status, mirrors `allHabitOccurrencesForReview`
    /// exactly.** Same structure as `openRecurringTaskOccurrencesForReview`
    /// above (forward day-scan, 400-day cap, `dueDate` bound, `.specific`-
    /// mode exclusion) but with no status filter for `.none` (always
    /// shown, unbounded backlog, same as before) — a resolved status
    /// (`.complete`/`.missed`) is bounded to `cursor > completedSinceDay`
    /// so a long-running daily task's whole resolved history doesn't
    /// flood every future review. `completedSinceDay` falls back to
    /// `.distantPast` when `completedSince` is `nil`.
    static func allRecurringTaskOccurrencesForReview(tasks: [TaskItem], context: ModelContext, upTo cutoff: Date = .now, completedSince: Date?, calendar: Calendar = .current) -> [RecurringTaskReviewOccurrence] {
        let cutoffDay = calendar.startOfDay(for: cutoff)
        let completedSinceDay = calendar.startOfDay(for: completedSince ?? .distantPast)
        var result: [RecurringTaskReviewOccurrence] = []
        for task in tasks where task.isRecurring && task.recurrenceTimeMode != .specific {
            guard let anchor = task.dueDate else { continue }
            let anchorDay = calendar.startOfDay(for: anchor)
            guard anchorDay <= cutoffDay else { continue }
            let scanFloorDay = calendar.date(byAdding: .day, value: -400, to: cutoffDay) ?? anchorDay
            var cursor = max(anchorDay, scanFloorDay)
            while cursor <= cutoffDay {
                if task.hasRecurringOccurrence(on: cursor, calendar: calendar) {
                    let targetTime = calendar.date(byAdding: .minute, value: targetMinutes(for: task.recurrenceTimeMode), to: cursor) ?? cursor
                    if targetTime < cutoff {
                        let status = RecurringTaskLog.log(taskID: task.id, on: cursor, context: context, calendar: calendar)?.status ?? .none
                        if status == .none || cursor > completedSinceDay {
                            result.append(RecurringTaskReviewOccurrence(id: "\(task.id)-\(Int(cursor.timeIntervalSince1970))", task: task, status: status, targetTime: targetTime, modeLabel: task.recurrenceTimeMode.label))
                        }
                    }
                }
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = nextDay
            }
        }
        return result
    }

    /// `NightlyReviewView.openRecurringTaskOccurrencesForReview`'s (the
    /// display-side wrapper's) core logic — the recurring-task
    /// counterpart to `refreshedHabitReviewOccurrences`. Re-derives each
    /// `frozen` occurrence's `status` fresh, right now, rather than
    /// trusting whatever it was when `frozen` was captured — same
    /// frozen-identity/live-status split.
    static func refreshedRecurringTaskReviewOccurrences(frozen: [RecurringTaskReviewOccurrence], context: ModelContext, calendar: Calendar = .current) -> [RecurringTaskReviewOccurrence] {
        frozen.map { occurrence in
            let day = calendar.startOfDay(for: occurrence.targetTime)
            let status = RecurringTaskLog.log(taskID: occurrence.task.id, on: day, context: context, calendar: calendar)?.status ?? .none
            return RecurringTaskReviewOccurrence(id: occurrence.id, task: occurrence.task, status: status, targetTime: occurrence.targetTime, modeLabel: occurrence.modeLabel)
        }
    }

    /// A Specific-Time recurring task's current status, read through
    /// `RecurringTaskLog` — the single source of truth for both
    /// `recurrenceTimeMode`s as of `TaskItem.cycleRecurringOccurrence` (see
    /// its own doc comment). `block.isCompleted` is a display mirror only;
    /// this is what `OverdueBlocksReviewList` actually renders/cycles for
    /// a recurring task's block row, and what the Next gate checks for it.
    static func recurringTaskOccurrenceStatus(task: TaskItem, on day: Date, context: ModelContext, calendar: Calendar = .current) -> OccurrenceStatus {
        RecurringTaskLog.log(taskID: task.id, on: day, context: context, calendar: calendar)?.status ?? .none
    }

    /// **What a calendar block should render as** — the one answer the day
    /// calendar's circle and its row fade both use, rather than each deriving
    /// it separately.
    ///
    /// A recurring task's block is only a mirror (`RecurringTaskLog` is the
    /// source of truth), so it reads through; every other block owns its own
    /// `status`. Deliberately **not** `block.isCompleted`, whose getter is
    /// `status == .complete` and therefore collapses `.missed` into `.none`.
    ///
    /// `static` and free of any view so it can be tested directly. That
    /// matters here specifically: the bug this replaces lived in the *call
    /// site* — the circle was perfectly capable of drawing three states and
    /// simply was not asked to — so a test that renders the circle with
    /// hand-written arguments passes while the screen stays broken. This is
    /// the half a test can actually hold.
    static func blockDisplayStatus(_ block: ScheduledBlock, context: ModelContext, calendar: Calendar = .current) -> OccurrenceStatus {
        if let task = block.task, task.isRecurring {
            return recurringTaskOccurrenceStatus(task: task, on: block.date, context: context, calendar: calendar)
        }
        return block.status
    }

    /// The Next gate's predicate for the AM/Midday/PM half of recurring
    /// tasks — mirrors `unresolvedHabitOccurrences` exactly.
    static func unresolvedRecurringTaskOccurrences(_ occurrences: [RecurringTaskReviewOccurrence]) -> [RecurringTaskReviewOccurrence] {
        occurrences.filter { $0.status == .none }
    }

    /// The Next gate's predicate for the Specific-Time half — a recurring
    /// task's own block, still `.none` in `RecurringTaskLog`. Non-recurring
    /// blocks are never included (`task.isRecurring` guard) — see
    /// `NightlyReviewView.unresolvedGateReviewItems`'s own comment for why
    /// those stay ungated.
    static func unresolvedRecurringTaskBlocks(_ blocks: [ScheduledBlock], context: ModelContext, calendar: Calendar = .current) -> [ScheduledBlock] {
        blocks.filter { block in
            guard let task = block.task, task.isRecurring, task.recurrenceTimeMode == .specific else { return false }
            return recurringTaskOccurrenceStatus(task: task, on: block.date, context: context, calendar: calendar) == .none
        }
    }

    /// The short line shown next to a disabled Next button on the Today
    /// step, naming exactly which gated categories are still blocking —
    /// "habit(s)," "task(s)," or both, never the generic "item(s)" a
    /// reader could misread as counting an ordinary unfinished (and
    /// deliberately ungated) task block. Only ever called with at least
    /// one nonzero count — the caller doesn't show this line otherwise.
    static func unresolvedGateMessage(unresolvedHabitCount: Int, unresolvedRecurringTaskCount: Int) -> String {
        var parts: [String] = []
        if unresolvedHabitCount > 0 {
            // "from an earlier day" because only backlog blocks now — today's
            // unmarked habits are visible on the step but don't gate. Without
            // it you'd read "1 habit still unmarked" with three unmarked ones
            // on screen.
            let noun = unresolvedHabitCount == 1 ? "1 habit" : "\(unresolvedHabitCount) habits"
            parts.append("\(noun) from an earlier day")
        }
        if unresolvedRecurringTaskCount > 0 {
            parts.append(unresolvedRecurringTaskCount == 1 ? "1 task" : "\(unresolvedRecurringTaskCount) tasks")
        }
        return parts.joined(separator: " and ") + " still unmarked"
    }

    /// The guarded creation step shared by `pushMissedRecurringOccurrences`
    /// (the commit-time sweep) and `NightlyReviewView
    /// .cycleRecurringTaskReviewOccurrence` (an interactive tap landing on
    /// `.missed`) — one implementation for "does this task already have an
    /// active push, and if not, start one," so the two triggers can never
    /// disagree about what counts as already-pushed. A fetch, not a
    /// relationship read, so a record inserted earlier in this same call
    /// (or by an interactive tap moments before Next) is visible here too.
    /// Returns `nil` when a push was already active — the caller does
    /// nothing further in that case, same as before this was extracted.
    /// Also returns `nil` outright when `task.isPushable` is `false` — a
    /// missed occurrence of that task just stays missed on its own day
    /// (whatever already wrote `.missed` to its log did so before this
    /// runs; this function only ever controls the *push*), waiting for
    /// the next natural recurrence instead of carrying forward.
    ///
    /// **This one `guard` is load-bearing for all three of `isPushable`'s
    /// suppression behaviors, not just this function's own:** the
    /// commit-time sweep (`pushMissedRecurringOccurrences`) and the
    /// interactive missed-tap both create a push only by calling this
    /// function, and the display-only carry-forward projection
    /// (`carriedForwardRecurringTaskIDs`) checks `task.isPushable` itself
    /// purely so it never shows a projection this function would refuse
    /// to back with a real record. If a future fourth creation path calls
    /// `context.insert(PushedRecurringOccurrence(...))` directly instead
    /// of routing through here, `isPushable == false` will silently stop
    /// working for it — there is no other enforcement point.
    static func pushRecurringOccurrenceIfNeeded(task: TaskItem, missedDay: Date, context: ModelContext) -> PushedRecurringOccurrence? {
        guard task.isPushable else { return nil }
        let taskID = task.id
        let alreadyPushed = (try? context.fetch(FetchDescriptor<PushedRecurringOccurrence>(
            predicate: #Predicate { $0.taskID == taskID && !$0.isCompleted }
        )))?.first != nil
        guard !alreadyPushed else { return nil }
        let occurrence = PushedRecurringOccurrence(taskID: taskID, originalDate: missedDay)
        context.insert(occurrence)
        return occurrence
    }

    /// Creates a `PushedRecurringOccurrence` for every recurring task left
    /// incomplete by tonight's review that doesn't already have one
    /// pending — both the block-scoped case (Specific Time, sourced from
    /// `reviewedBlocks`) and the `RecurringTaskLog`-scoped case
    /// (AM/Midday/PM, sourced from `openRecurringTaskOccurrencesForReview`
    /// since those tasks have no block for the first loop to ever see).
    /// Uses `pushRecurringOccurrenceIfNeeded` for the actual creation, so
    /// this and an interactive missed-tap can never both push the same
    /// task.
    ///
    /// Also writes `.missed` to the occurrence's own `RecurringTaskLog`
    /// (mirroring into a linked Specific-Time block same as
    /// `TaskItem.cycleRecurringOccurrence` does) — the task counterpart to
    /// `markUnresolvedHabitOccurrencesAsMissed`'s habit-log write. Without
    /// this, an occurrence the interactive gate didn't catch would get a
    /// push record but its log would silently stay `.none` forever, with
    /// only the push as evidence anything happened.
    ///
    /// Returns each freshly-created record alongside its task and the day
    /// it was missed, so the caller can hop it forward once immediately
    /// (`PushedRecurringOccurrence.advanceOneHop`) instead of leaving it to
    /// sit unresolved until the next app launch's catch-up walk.
    @discardableResult
    static func pushMissedRecurringOccurrences(reviewedBlocks: [ScheduledBlock], tasks: [TaskItem], context: ModelContext, cutoff: Date) -> [(occurrence: PushedRecurringOccurrence, task: TaskItem, missedDay: Date)] {
        var created: [(occurrence: PushedRecurringOccurrence, task: TaskItem, missedDay: Date)] = []

        func markMissedAndPush(task: TaskItem, missedDay: Date) {
            let log = RecurringTaskLog.logOrCreate(taskID: task.id, on: missedDay, context: context, calendar: .current)
            log.status = .missed
            log.lastModified = .now
            if let block = (task.scheduledBlocks ?? []).first(where: { Calendar.current.isDate($0.date, inSameDayAs: missedDay) }) {
                // `.status`, not `.isCompleted` — same reasoning as
                // `TaskItem.cycleRecurringOccurrence`'s own mirror write:
                // this block is still only ever a mirror of
                // `RecurringTaskLog` (unchanged), but writing the real
                // status now lets that mirror preserve `.missed`
                // distinctly from `.none` too.
                block.status = .missed
            }
            if let occurrence = pushRecurringOccurrenceIfNeeded(task: task, missedDay: missedDay, context: context) {
                created.append((occurrence, task, missedDay))
            }
        }

        // **REVERSAL — only an explicitly missed occurrence pushes now.**
        //
        // Both arms used to sweep anything not complete, and
        // `markMissedAndPush` *writes* `log.status = .missed` before
        // pushing — so the commit turned every unresolved occurrence into a
        // miss and pushed it. That was right when `.none` was the only
        // non-complete state and had to stand in for "unfinished". Now
        // `.missed` says it explicitly, and deciding on the user's behalf
        // that an untouched occurrence was missed is both a false record and
        // an unasked-for push.
        //
        // `status == .missed`, not `!isCompleted`: the same lossy read that
        // produced three separate bugs this session (see
        // docs/session-handoff.md) — it means "including missed" but also
        // "including never looked at".
        //
        // The untimed arm is gone entirely rather than filtered.
        // `openRecurringTaskOccurrencesForReview` returns `.none` occurrences
        // *only*, so under the new rule it can never yield anything
        // pushable — a filtered call would be a permanent no-op dressed up
        // as logic. An occurrence marked `.missed` interactively already
        // pushed at the moment of the tap (`NightlyReviewView.pushIfMissed`),
        // which is why nothing is lost by dropping it.
        //
        // What happens to an unmarked occurrence instead: it stays `.none`,
        // keeps no forward presence, and resurfaces in the Today step's
        // backlog (`allRecurringTaskOccurrencesForReview` walks back 400 days)
        // until it is actually marked.
        for block in reviewedBlocks where block.status == .missed {
            guard let task = block.task, task.isRecurring else { continue }
            markMissedAndPush(task: task, missedDay: block.date)
        }
        return created
    }

    /// Toggles an untimed (AM/Midday/PM) habit occurrence's completion —
    /// the habit counterpart to `toggleComplete`, for a
    /// `HabitReviewOccurrence` that (unlike a habit-linked block) has no
    /// `ScheduledBlock` to toggle in the first place.
    func toggleHabitOccurrence(habit: Habit, index: Int, isCompleted: Bool, day: Date) {
        habitLog(for: habit, on: day).setOccurrence(index, to: isCompleted ? .none : .complete)
        HabitStatsRefreshCoordinator.shared.habitLogsChanged()
    }

    /// Marks every still-open (`.none`) habit occurrence up through
    /// `cutoff` as missed — timed (a `reviewableBlocks` habit block left
    /// incomplete) or untimed (`openHabitOccurrencesForReview`) — the
    /// habit counterpart to `clearIncompletePastBlocks`'s task-side sweep.
    /// Mirrors `NightlyReviewView.markUnresolvedHabitOccurrencesAsMissed`,
    /// generalized so the Calendar tab's own "Review Previous Events"/
    /// "Assume Not Completed" flow gives habits the same treatment tasks
    /// already get there, instead of silently leaving them unresolved.
    func markUnresolvedHabitOccurrencesAsMissed(allBlocks: [ScheduledBlock], habits: [Habit], cutoff: Date = .now) {
        for block in allBlocks {
            guard let habit = block.habit, !block.isCompleted, block.startTime < cutoff else { continue }
            habitLog(for: habit, on: block.date).setOccurrence(block.habitOccurrenceIndex, to: .missed)
        }
        for occurrence in Self.openHabitOccurrencesForReview(habits: habits, context: modelContext, upTo: cutoff) {
            habitLog(for: occurrence.habit, on: occurrence.targetTime).setOccurrence(occurrence.index, to: .missed)
        }
        try? modelContext.save()
        HabitStatsRefreshCoordinator.shared.habitLogsChanged()
    }

    /// The merged timeline `DayTimelineGridView` actually renders: proposed
    /// blocks plus whatever's genuinely external on the calendar. A pushed
    /// block whose Google event has already synced back shows up in both
    /// `blocks` and `calendarEvents` — matched here by event ID, or by
    /// title as a fallback if the ID round-trip hasn't landed yet — and the
    /// external copy is dropped so it isn't double-rendered. Shared by
    /// `ScheduleReviewView` and `NightlyReviewView`'s Plan step, which both
    /// show the same kind of day.
    static func timelineRows(blocks: [ScheduledBlock], calendarEvents: [CalendarEventSummary]) -> [DayTimelineRow] {
        let blockTitles = Set(blocks.compactMap { block -> String? in
            guard block.task != nil || block.habit != nil else { return nil }
            return block.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        let blockEventIDs = Set(blocks.compactMap(\.googleEventID))
        let eventRows = calendarEvents
            .filter { event in
                !blockEventIDs.contains(event.id)
                    && !blockTitles.contains(event.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }
            .map(DayTimelineRow.event)
        let proposedRows = blocks.map(DayTimelineRow.proposed)
        return (eventRows + proposedRows).sorted { $0.startTime < $1.startTime }
    }

    /// Gives back exactly what `block` was holding, capped at the task's
    /// own `estimatedMinutes` so bookkeeping drift (or a task whose
    /// duration was edited down after this block was placed) can never
    /// push `remainingMinutes` past the task's own stated size. A no-op
    /// for a completed block (its task is either being deleted right
    /// alongside it or intentionally left alone — see the two callers)
    /// or one with no task at all. Shared by every place that frees an
    /// *incomplete* block without the task ever finishing it —
    /// `clearIncompletePastBlocks`, `regenerateFromNow`'s own
    /// forward-looking clear, and `clearBlocksBeforeToday` — so a
    /// partially-scheduled divisible task never permanently shrinks just
    /// because its block got cleared instead of finished. See
    /// `TaskItem.remainingMinutes`'s doc comment for the bug this closes.
    private func restoreRemainingMinutes(for block: ScheduledBlock) {
        guard let task = block.task, !block.isCompleted else { return }
        task.remainingMinutes = min(task.estimatedMinutes, task.remainingMinutes + block.durationMinutes)
    }

    /// The single way a `ScheduledBlock` is removed. **Use this rather
    /// than calling `modelContext.delete` on a block directly.**
    ///
    /// Restoring is the default because forgetting it is silent and
    /// unrecoverable: `pack()` decrements `remainingMinutes` when it
    /// places a block, so a delete that skips the restore permanently
    /// destroys that time. Four separate call sites had independently
    /// grown the same delete-without-restore shape — the two
    /// `trimOverflowingRuleBlocks` branches, `deleteBlock`, and
    /// `manualReplace` — which is how two real tasks ended up incomplete
    /// with `remainingMinutes = 0` and nothing scheduled. Three other
    /// paths got it right. Nothing about the old shape made the
    /// difference visible, and nothing stopped a fifth being written the
    /// same way.
    ///
    /// Completed blocks are safe to pass: `restoreRemainingMinutes`
    /// already no-ops on them, since their time was genuinely spent.
    ///
    /// Also clears the task/habit inverse before deleting — otherwise a
    /// task claimed by a *new* block later in the same run can find its
    /// inverse still held by the one being removed, which SwiftData
    /// reports as a hard "relationship already has a value but it's not
    /// the target" crash rather than silently overwriting it.
    /// The one place a **scheduler-placed** block enters the store.
    /// Refuses to insert a task block that would overlap an existing task
    /// block, and returns whether it inserted.
    ///
    /// Defense in depth alongside `serializingWalk`, not a substitute for
    /// it. Serialization removes the cause; this catches the symptom
    /// regardless of cause — including from a view model instance the
    /// chain can't see, or from some future write path nobody has thought
    /// of yet. It would have caught the original double-booking the first
    /// time it happened rather than after a database pull.
    ///
    /// **Exemptions, all deliberate:**
    /// - *Habit* blocks may overlap anything. Habits are allowed to
    ///   double-book by design (see `AISchedulingService
    ///   .placeHabitsAndRecurringTasks`).
    /// - *Recurring task* blocks are placed at their own fixed anchor by
    ///   that same pass and may also overlap. Whether they should is a
    ///   real open question, but it is not this bug and changing it here
    ///   would be a silent behavior change.
    /// - *User drags* never come through here — `insertBlock(for:startTime:)`
    ///   is the manual path, and a deliberate drag onto an occupied slot
    ///   stays possible.
    @discardableResult
    private func insertSchedulerBlock(_ block: ScheduledBlock, site: String) -> Bool {
        if let task = block.task, !task.isRecurring {
            let existing = (try? modelContext.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
            let conflict = existing.first { other in
                guard other.id != block.id, !other.isCompleted else { return false }
                guard let otherTask = other.task, !otherTask.isRecurring else { return false }
                return block.startTime < other.endTime && other.startTime < block.endTime
            }
            if let conflict {
                let formatter = DateFormatter()
                formatter.dateFormat = "MM-dd HH:mm"
                DiagFileLog.write("[\(instanceTag)] REJECTED site=\(site) \"\(task.title)\" \(formatter.string(from: block.startTime))–\(formatter.string(from: block.endTime)) — would overlap \"\(conflict.task?.title ?? "?")\"")
                // Never inserted, so it must not leave a half-attached
                // relationship behind.
                block.task = nil
                block.habit = nil
                return false
            }
        }
        modelContext.insert(block)
        return true
    }

    private func removeBlock(_ block: ScheduledBlock, restoringRemainingMinutes: Bool = true) {
        if restoringRemainingMinutes {
            restoreRemainingMinutes(for: block)
        }
        block.task = nil
        block.habit = nil
        modelContext.delete(block)
    }

    /// "Assume Not Completed" — the fast alternative to reviewing each
    /// overdue block one at a time: unschedules every one of them (same as
    /// swiping it away in the review list) so a following
    /// `regenerateFromNow` is free to place them again starting from right
    /// now. **REVERSAL:** this used to be `clearIncompletePastBlocks` and
    /// deleted the stale block outright (its Google Calendar event too).
    /// Nothing is deleted from the calendar now — `.missed` is a real,
    /// permanent record, not a state to sweep away, and
    /// `reviewableBlocks`'s own `.none`-only "still needs a decision"
    /// filter is what keeps an already-resolved missed block from
    /// resurfacing in review, not deletion. One direct, visible
    /// consequence worth naming: the block's synced Google Calendar
    /// event (if it had been approved) also survives now, indefinitely —
    /// a stale "missed" event stays on the user's actual calendar rather
    /// than getting cleaned up.
    ///
    /// The interactive cycle (`cycleBlockCompletion`) already guarantees
    /// a fresh placement the moment a tap lands a task block on
    /// `.missed` — this exists as the same kind of redundant, *guarded*
    /// safety net `pushMissedRecurringOccurrences` already is for
    /// recurring tasks, not the primary trigger anymore. It only
    /// actually does anything for a `.missed` block whose task never got
    /// re-placed some other way — concretely, the one-time migration
    /// backfill (old incomplete-and-past records translated straight to
    /// `.missed`) never goes through the interactive cycle at all, so
    /// this is what actually guarantees placement for those. Guarded on
    /// `ScheduledBlock.hasGuaranteedReplacement` — see that property's
    /// own doc comment for why `task.isScheduled` alone can't tell
    /// "already handled" apart from "still reads scheduled from this
    /// exact block's own now-missed placement."
    ///
    /// Never touches a habit-linked block (`$0.habit == nil` below) —
    /// unchanged reasoning from before this reversal: a habit's
    /// completion record of record is `HabitLog`
    /// (`markUnresolvedHabitOccurrencesAsMissed` marks it missed there,
    /// independent of this function entirely), not this function's
    /// concern either way.
    func resolveMissedPastBlocks(allBlocks: [ScheduledBlock]) {
        // `task?.isRecurring != true` — a recurring task's own missed
        // block also carries `.status == .missed` (see `TaskItem
        // .cycleRecurringOccurrence`'s mirror write), but that task's
        // next placement is `PushedRecurringOccurrence`'s job
        // (`pushMissedRecurringOccurrences`/`pushIfMissed`), not
        // `guaranteePlacement`'s — that's scoped to rule-based shelf
        // eligibility (`TaskItem.nextEligibleDay`), which a recurring
        // task doesn't place through at all. Matches the old
        // `clearIncompletePastBlocks`-era split exactly:
        // `missedNonRecurringPlacements` was always its own,
        // separately-`!task.isRecurring`-filtered list, never folded
        // into the same sweep as the recurring push.
        let toResolve = allBlocks.filter {
            $0.status == .missed && $0.habit == nil && !$0.hasGuaranteedReplacement && $0.task?.isRecurring != true
        }
        for block in toResolve {
            guard let task = block.task else { continue }
            task.isScheduled = false
            task.pushedCount += 1
            // Same restoration `cycleBlockCompletion` already does for
            // the interactive path — see its own comment. This block
            // stays (nothing deletes it), but its duration wasn't
            // actually worked, so it needs to go back to the task's own
            // ledger before a fresh placement is guaranteed.
            restoreRemainingMinutes(for: block)
            guaranteePlacement(for: task, missedDate: block.date, missedStartTime: block.startTime, durationMinutes: block.durationMinutes)
            block.hasGuaranteedReplacement = true
        }
    }

    /// Relocates `task`'s existing block to `startTime` on `targetDate`,
    /// rather than `insertBlock` creating a second one — reached the same
    /// way `insertBlock` is (long-press an open slot, pick a candidate
    /// from `EmptySlotPickerSheet`), for a candidate `replacementCandidates`
    /// already gated to exactly one active, unlocked block (see
    /// `.freeSlot`'s own doc comment) — nothing here needs to disambiguate
    /// which block moves. The block's own duration is preserved exactly,
    /// never truncated to fit whatever room happens to be at `startTime`;
    /// `insertWithRipple` is what actually finds room there, bumping
    /// anything in the way forward (or, if the day's genuinely full,
    /// pushing it to *its own* next eligible day) — the same
    /// lock-respecting, bump-don't-overflow treatment `guaranteePlacement`
    /// and the recurring-occurrence push already get, rather than the
    /// moved block silently landing on top of something else. No upfront
    /// "does it fit" filter in the candidate list either, deliberately
    /// consistent with how `insertBlock` already treats an unscheduled
    /// candidate — ripple is what reconciles size against room, not a
    /// filter that would hide a candidate from a gap it doesn't fit
    /// verbatim but could still be rippled into.
    /// No-op (guard, not a crash) if the gate above somehow let through a
    /// task with no actual movable block — defensive only; every real
    /// caller already guarantees one exists.
    func moveExistingBlock(for task: TaskItem, to startTime: Date) {
        guard let block = (task.scheduledBlocks ?? []).first(where: { !$0.isCompleted && !$0.isLocked }) else { return }
        let duration = block.endTime.timeIntervalSince(block.startTime)
        block.date = targetDate
        block.startTime = startTime
        block.endTime = startTime.addingTimeInterval(duration)
        block.manuallyPlaced = true
        needsReapproval(block)
        insertWithRipple(block)
    }

    /// Creates a brand-new block for `task` at `startTime` — reached by
    /// tapping an open slot on the timeline grid and picking a candidate.
    /// Sized by the task's own estimated duration, or a 30-minute default
    /// if it doesn't have one, same fallback the AI Scheduler itself uses.
    func insertBlock(for task: TaskItem, startTime: Date) {
        let isEstimated = task.estimatedMinutes <= 0
        let minutes = isEstimated ? 30 : task.estimatedMinutes
        let endTime = startTime.addingTimeInterval(TimeInterval(minutes * 60))
        let block = ScheduledBlock(date: targetDate, startTime: startTime, endTime: endTime, task: task, isEstimatedDuration: isEstimated)
        block.manuallyPlaced = true
        modelContext.insert(block)
        task.isScheduled = true
        blocks.append(block)
        blocks.sort { $0.startTime < $1.startTime }
    }

    /// Keeps `blocks` in sync with a `ScheduledBlock` a caller inserted
    /// directly into `modelContext`, bypassing this view model entirely —
    /// currently only `NightlyReviewView.insertMealBlock`, which creates
    /// the Meals step's 5pm block itself rather than going through
    /// `insertBlock`. `blocks` is `private(set)` and is what the Tomorrow
    /// step actually renders (`DayTimelineGridView`'s `rows` come from
    /// `tomorrowViewModel.blocks`, not a live fetch) — without this, a
    /// newly picked meal's block exists in the store but the already-
    /// loaded `blocks` snapshot never learns about it, so it never
    /// appears on the calendar until something else happens to reload.
    func registerInsertedBlock(_ block: ScheduledBlock) {
        blocks.append(block)
        blocks.sort { $0.startTime < $1.startTime }
    }

    /// Mirror of `registerInsertedBlock`, for a caller that deletes a
    /// block directly rather than through `removeBlock` — currently only
    /// `NightlyReviewView.removeMealBlock`, run right before re-picking a
    /// meal inserts its replacement. Without this, re-picking would leave
    /// the old block's now-stale entry sitting in `blocks` alongside the
    /// new one.
    func deregisterBlock(_ block: ScheduledBlock) {
        blocks.removeAll { $0.id == block.id }
    }

    /// Routes `block` through `RippleSchedulingService`, then reloads
    /// `blocks` from `modelContext` wholesale rather than trying to patch
    /// individual entries — a ripple can move, bump-to-another-day, or
    /// leave untouched an arbitrary number of other blocks in ways that
    /// are much simpler to just re-read than to track through
    /// `registerInsertedBlock`/`deregisterBlock` calls one at a time.
    /// This only ever runs once per Nightly Review commit or manual
    /// push, not a hot path, so the full reload's cost is a non-issue.
    func insertWithRipple(_ block: ScheduledBlock) {
        RippleSchedulingService.insertWithRipple(block, context: modelContext)
        // **Scoped to `targetDate`, like every other assignment to `blocks`.**
        // This assigned the whole store, and `timelineRows` does no day
        // filtering of its own — so a replacement placed on a *later* day
        // rendered on today's grid, stacked exactly on the block it replaced
        // (`guaranteePlacement` keeps the missed block's time of day).
        // Leaving the day and coming back reloaded through the filtered path
        // and it vanished, which is what made it look like a repaint problem
        // rather than the wrong list.
        loadExistingBlocks((try? modelContext.fetch(FetchDescriptor<ScheduledBlock>())) ?? [])
    }

    /// Guarantees an incomplete, non-recurring task actually lands
    /// somewhere on the calendar rather than being freed up
    /// (`clearIncompletePastBlocks`'s own unschedule-and-hope) to
    /// compete for a slot in whatever future general regenerate walk
    /// happens to run next — the concrete bug this fixes: a task like
    /// "Stirfry recipes" sits with room genuinely free in its own
    /// eligible window, yet never actually gets placed because nothing
    /// forces the issue. Rebuilds a block at the task's own missed
    /// time-of-day on `TaskItem.nextEligibleDay`, then routes it through
    /// `insertWithRipple` so it displaces (or gets displaced by, if the
    /// day genuinely has no room) other tasks rather than silently
    /// failing to place. `missedDate`/`missedStartTime` are the just-
    /// deleted block's own values, captured by the caller before
    /// `clearIncompletePastBlocks` removes it — there is nothing left to
    /// read them from by the time this runs.
    @discardableResult
    func guaranteePlacement(for task: TaskItem, missedDate: Date, missedStartTime: Date, durationMinutes: Int) -> ScheduledBlock? {
        let calendar = Calendar.current
        guard let nextDay = task.nextEligibleDay(after: missedDate, calendar: calendar) else {
            DiagFileLog.write("RIPPLE GAVE UP taskID=\(task.id) title=\(task.title) reason=No eligible day found for a missed Nightly Review task.")
            modelContext.insert(PushRecursionWarning(taskID: task.id, taskTitle: task.title, message: "No eligible day left to reschedule it on."))
            try? modelContext.save()
            return nil
        }
        // **Window start, not the missed block's time-of-day.**
        //
        // REVERSAL. This used to rebuild the block at whatever hour it was
        // missed at, and that is not merely a preference difference — it
        // could place a block **outside every window the task is eligible
        // for**. `nextEligibleDay` returns a day on which *some* rule
        // applies; reusing the missed hour ignores which. Miss a 9am block
        // placed by a Mornings rule, land on a day that only has an
        // Afternoons rule, and the replacement sits at 9am under no rule at
        // all — where the trim then treats it as a leftover. That is the
        // correctness argument; "a deferred task should get the front of the
        // next day" is the product one.
        //
        // The rule that made `nextDay` eligible is the one whose window is
        // used, so the two can never disagree. Falls back to the missed
        // time-of-day only if no applicable rule can be resolved, which
        // `nextEligibleDay` having succeeded makes unreachable in practice.
        let weekday = calendar.component(.weekday, from: nextDay)
        let applicableRule = (task.shelf?.schedulingRules ?? [])
            .filter { $0.isEnabled && task.isEffectivelyEligible(for: $0) && $0.effectiveDaysOfWeek.contains(weekday) }
            .min { lhs, rhs in
                (lhs.effectiveStartHour, lhs.effectiveStartMinute) < (rhs.effectiveStartHour, rhs.effectiveStartMinute)
            }
        let fallback = calendar.dateComponents([.hour, .minute], from: missedStartTime)
        let startHour = applicableRule?.effectiveStartHour ?? fallback.hour ?? 9
        let startMinute = applicableRule?.effectiveStartMinute ?? fallback.minute ?? 0
        guard let start = calendar.date(bySettingHour: startHour, minute: startMinute, second: 0, of: nextDay) else { return nil }
        let end = start.addingTimeInterval(TimeInterval(durationMinutes * 60))
        let block = ScheduledBlock(date: nextDay, startTime: start, endTime: end, task: task, isEstimatedDuration: task.estimatedMinutes <= 0)
        modelContext.insert(block)
        task.isScheduled = true
        insertWithRipple(block)
        return block
    }

    /// Reverses everything `cycleBlockCompletion`'s `.missed` branch did.
    ///
    /// Order matters: the replacement is removed **without** its usual
    /// minutes restoration, because the captured `remainingMinutesBeforeMiss`
    /// is then written directly. Letting `removeBlock` restore first and
    /// overwriting after would work today but leaves two sources competing
    /// for one field, which is the shape that drained `remainingMinutes` to
    /// zero before (see `removeBlock`'s own doc comment).
    ///
    /// A `nil` capture is a real case, not a defect — see `ScheduledBlock`'s
    /// comment. The replacement is still deleted if its id is known, and the
    /// flag still clears; only the two restores are skipped, because there is
    /// no honest value to write and a guess here corrupts a task's ledger
    /// silently.
    func undoGuaranteedPlacement(for block: ScheduledBlock, task: TaskItem) {
        if let replacementID = block.guaranteedReplacementBlockID,
           let replacement = blocks.first(where: { $0.id == replacementID })
            ?? (try? modelContext.fetch(FetchDescriptor<ScheduledBlock>()))?.first(where: { $0.id == replacementID }) {
            removeBlock(replacement, restoringRemainingMinutes: false)
        }
        task.pushedCount = max(0, task.pushedCount - 1)
        if let priorMinutes = block.remainingMinutesBeforeMiss {
            task.remainingMinutes = priorMinutes
        }
        if let wasScheduled = block.wasScheduledBeforeMiss {
            task.isScheduled = wasScheduled
        }
        block.hasGuaranteedReplacement = false
        block.guaranteedReplacementBlockID = nil
        block.remainingMinutesBeforeMiss = nil
        block.wasScheduledBeforeMiss = nil
        // Same day-scoping as `insertWithRipple` — this copied its unfiltered
        // shape when it was written.
        loadExistingBlocks((try? modelContext.fetch(FetchDescriptor<ScheduledBlock>())) ?? [])
    }

    /// §5.1/§8: same `taskOrdering` the auto-scheduler itself sorts
    /// candidates by, not a separate priority→createdAt→dueDate
    /// comparator. Filtered through `replacementCandidates` first — Auto
    /// only ever offers a genuinely unscheduled task (`.occupiedBlock`
    /// already widens the pool to scheduled-elsewhere candidates for the
    /// *manual* picker, but `autoReplace` itself has no logic to free a
    /// replacement's old block the way `manualReplace` does, so taking
    /// one here would silently leave it double-booked).
    private func nextCandidate(from pool: [TaskItem], block: ScheduledBlock) -> TaskItem? {
        let calendar = Calendar.current
        return replacementCandidates(from: pool, for: .occupiedBlock(block))
            .filter { !$0.isScheduled }
            .sorted { MockAISchedulingService.taskOrdering($0, $1, asOf: block.date, calendar: calendar) }
            .first
    }
}
