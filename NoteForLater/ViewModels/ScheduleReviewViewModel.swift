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
            return task.isDivisible
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
    private func removeStaleNonSpecificHabitBlocksAcrossFutureDays() {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: .now)
        let allBlocksNow = (try? modelContext.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        let stale = allBlocksNow.filter { block in
            guard block.date >= startOfToday, let habit = block.habit, !block.isCompleted else { return false }
            return habit.timeMode(for: block.habitOccurrenceIndex) != .specific
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
            loadExistingBlocks(allBlocksNow)
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

            let trimmable = dayBlocks.filter {
                $0.task != nil && !$0.isLocked && !$0.isCompleted && $0.approvalStatus != .approved
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
                let violatesMinimumSegment = task.isDivisible && task.minimumSegmentMinutes > 0
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
        // rather than the calendar push having already happened.
        var survivingBlocks = allBlocks
        for block in allBlocks where block.approvalStatus != .approved && !block.isLocked && !block.isCompleted && block.startTime >= cutoff {
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
                // pushed), but a locked-while-still-proposed or
                // completed-while-still-proposed one hasn't — carve its
                // time back out manually so regeneration doesn't schedule
                // something new right on top of it.
                let protectedSurviving = survivingBlocks.filter {
                    ($0.isLocked || $0.isCompleted) && $0.approvalStatus != .approved && calendar.isDate($0.date, inSameDayAs: cursorDay)
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
                && rule.canEverFit(estimatedMinutes: task.remainingMinutes, isDivisible: task.isDivisible, minimumSegmentMinutes: task.minimumSegmentMinutes)
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
            let requiredMinutes = task.isDivisible && task.minimumSegmentMinutes > 0
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
    /// actually covers the target instant, plus — for an occupied block
    /// specifically — fitting its fixed duration) is identical either
    /// way. Only the "is this candidate already spoken for" exclusion
    /// differs: Replace/Swap can still take a candidate that's scheduled
    /// elsewhere (see `occupiedBlock` below); an empty slot never can —
    /// there's nothing here yet to trade places with, and `insertBlock`
    /// just creates a fresh block rather than freeing an old one.
    enum CandidateSlotContext {
        /// Replace/Swap target. A candidate already scheduled elsewhere
        /// may still qualify, but only if it has a single, unlocked,
        /// incomplete block of its own to act on — Replace and Swap both
        /// need one movable block, not a guess at which piece of a
        /// divisible task's spread, or a user-pinned lock, should move.
        case occupiedBlock(ScheduledBlock)
        /// An empty slot — no existing occupant, and no fixed duration
        /// yet (`insertBlock` sizes the new block to whichever task gets
        /// picked), so only genuinely unscheduled tasks qualify and
        /// there's no block-duration fit check to run.
        /// `includingInbox` widens the pool to unsorted (no-shelf) tasks
        /// too — only the long-press-to-insert popover wants that; the
        /// auto-scheduler's own candidate pool never includes Inbox
        /// tasks.
        case freeSlot(startTime: Date, includingInbox: Bool)
    }

    /// The single filter behind every "what can go here" picker. The
    /// Replace/Swap sheet, the empty-slot sheet, and Auto-Replace's own
    /// candidate pool used to each carry a separate, drifting copy of
    /// roughly this same predicate — one of them (the plain
    /// `unscheduledCandidates(from:)`, pre-§8) had drifted all the way to
    /// unused dead code, and another (Nightly Review's own Replace
    /// picker) had quietly ended up narrower than the other two Replace
    /// call sites. See `CandidateSlotContext` for what actually varies by
    /// caller.
    func replacementCandidates(from allTasks: [TaskItem], for context: CandidateSlotContext) -> [TaskItem] {
        let calendar = Calendar.current
        let startTime: Date
        let excludingTaskID: UUID?
        let blockDuration: Int?
        switch context {
        case .occupiedBlock(let block):
            startTime = block.startTime
            excludingTaskID = block.task?.id
            blockDuration = block.durationMinutes
        case .freeSlot(let slotStart, _):
            startTime = slotStart
            excludingTaskID = nil
            blockDuration = nil
        }
        let weekday = calendar.component(.weekday, from: startTime)

        return allTasks.filter { task in
            guard task.id != excludingTaskID, !task.isCompleted else { return false }

            switch context {
            case .occupiedBlock:
                if task.isScheduled {
                    let activeBlocks = (task.scheduledBlocks ?? []).filter { !$0.isCompleted }
                    guard activeBlocks.count <= 1, !(activeBlocks.first?.isLocked ?? false) else { return false }
                }
            case .freeSlot(_, let includingInbox):
                guard !task.isScheduled else { return false }
                if task.shelf == nil, !includingInbox { return false }
            }

            guard let shelf = task.shelf else { return true } // unsorted Inbox task — nothing further to check
            guard shelf.hasEnabledSchedulingRules, task.isEligibleToStart(on: startTime, calendar: calendar) else { return false }

            let coveringRules = (shelf.schedulingRules ?? []).filter { rule in
                rule.isEnabled && rule.effectiveDaysOfWeek.contains(weekday) && Self.ruleWindow(rule, contains: startTime, calendar: calendar)
            }
            guard coveringRules.contains(where: { task.isEffectivelyEligible(for: $0) }) else { return false }

            if let blockDuration {
                let fitsWhole = task.estimatedMinutes > 0 && task.estimatedMinutes <= blockDuration
                let fitsDivisible = task.isDivisible && task.minimumSegmentMinutes > 0 && task.minimumSegmentMinutes <= blockDuration
                guard fitsWhole || fitsDivisible else { return false }
            }
            return true
        }
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

    /// The timeline's tap-to-complete circle goes through here rather than
    /// flipping `block.isCompleted` directly — same Habit Tracker sync
    /// `markComplete` does, but both directions: un-tapping a habit block
    /// also resets that day's log, so the Habit Tracker (and its rolling
    /// stats, which read straight from the log) never disagrees with what
    /// the calendar shows. A task-backed block instead syncs
    /// `task.isCompleted` (so the shelf row fades/strikes through) and a
    /// `TaskCompletionRecord` (so the Task Stats page has it even after
    /// `regenerateFromNow` eventually purges the task itself).
    func toggleComplete(_ block: ScheduledBlock) {
        block.isCompleted.toggle()
        if let task = block.task {
            // A recurring task's TaskItem is shared across every
            // occurrence's own block (see `Shelf.isRecurringTasks`) —
            // completion lives entirely on the block for these, same as
            // a habit's does, rather than mirrored onto the shared task
            // (which one occurrence finishing shouldn't mark done for
            // every other occurrence, past or future).
            if !task.isRecurring {
                task.isCompleted = block.isCompleted
                if block.isCompleted {
                    upsertCompletionRecord(for: task)
                } else {
                    removeCompletionRecord(for: task)
                }
                // Task-side completion only — a habit occurrence's own
                // completion (below) never touches shelf-task scheduling
                // at all, so it has nothing to do with this flag.
                ScheduleDirtyState.shared.isDirty = true
            }
        }
        guard let habit = block.habit else { return }
        // Only this block's own occurrence (BrushTeeth.1 vs .2, say) is
        // affected — the day-level status/streak/calendar stay pending
        // until every occurrence is resolved (see `Habit.status`).
        let status: OccurrenceStatus = block.isCompleted ? .complete : .none
        habitLog(for: habit, on: block.date).setOccurrence(block.habitOccurrenceIndex, to: status)
        HabitStatsRefreshCoordinator.shared.habitLogsChanged()
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
            if let task = block.task {
                if block.isCompleted {
                    upsertCompletionRecord(for: task)
                    // See the matching comment in `purgeCompletedBlocks` —
                    // a recurring task's single TaskItem is shared across
                    // every occurrence, so it survives past its own
                    // completed block.
                    if !task.isRecurring {
                        modelContext.delete(task)
                    }
                } else {
                    task.isScheduled = false
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

    private func habitLog(for habit: Habit, on date: Date) -> HabitLog {
        habit.logOrCreate(on: date, context: modelContext, site: "ScheduleReviewViewModel.habitLog")
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
    /// the caller's job to remember which ids it's touched (see
    /// `ScheduleReviewView`'s `pastReviewCompletedHabitOccurrenceIDs`) —
    /// this function only decides whether to include a given id, never
    /// which ones a caller cares about remembering.
    /// `context` is required rather than optional because this list feeds a
    /// **write**: `markUnresolvedHabitOccurrencesAsMissed` iterates it and
    /// writes `.missed` to everything it reports as unresolved. Reading
    /// through the `habit.logs` relationship here meant a habit completed
    /// today but not yet saved read as `.none`, qualified as unresolved,
    /// and had its completion overwritten with a miss — no rapid tapping
    /// required, just completing a habit and opening Nightly Review before
    /// a save landed. See `Habit.log(on:context:)`.
    static func openHabitOccurrencesForReview(habits: [Habit], context: ModelContext, upTo cutoff: Date = .now, alsoInclude: Set<String> = []) -> [HabitReviewOccurrence] {
        let calendar = Calendar.current
        let cutoffDay = calendar.startOfDay(for: cutoff)
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
                        guard status == .none || alsoInclude.contains(id) else { continue }
                        result.append(HabitReviewOccurrence(id: id, habit: habit, index: index, isCompleted: status == .complete, targetTime: targetTime, modeLabel: mode.label))
                    }
                }
                guard let previousDay = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
                cursor = previousDay
            }
        }
        return result
    }

    static func hasOpenHabitOccurrences(habits: [Habit], context: ModelContext, upTo cutoff: Date = .now) -> Bool {
        !openHabitOccurrencesForReview(habits: habits, context: context, upTo: cutoff).isEmpty
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
    /// now. Covers any previous day in full, plus today up to right now —
    /// not a block later today, which hasn't happened yet and isn't
    /// "not completed," just not-yet-due. A locked block is left exactly
    /// where it is, same as `regenerateFromNow`'s own routine
    /// forward-looking clear respects it — locked means "don't move this,"
    /// full stop, whether or not it's been completed yet.
    /// Unlike `deleteBlock` (whose calendar-event removal is fire-and-forget
    /// — fine for a single swipe, where nothing downstream depends on it
    /// having landed yet), this `await`s each deletion: the caller always
    /// calls `regenerateFromNow` right after this, and that pulls fresh
    /// free/busy from the calendar to decide what's open — a pushed event
    /// that hasn't actually finished being deleted yet would still show
    /// that time as busy, and the freed task wouldn't actually get a slot
    /// back despite being unscheduled again.
    /// `cutoff` defaults to right now (the regular Regenerate flow's
    /// notion of "past"), but Nightly Review's Plan step passes its own —
    /// whichever day was picked in Choose Day, not real-now — so a task
    /// left unchecked there gets freed up for tomorrow's generation even
    /// when `reviewDate` isn't today.
    func clearIncompletePastBlocks(allBlocks: [ScheduledBlock], cutoff: Date = .now) async {
        // Deliberately ignores isLocked — a lock only pins a block within
        // a day's own layout. Once that day is over, protecting it here
        // would make it immortal: it still matches reviewableBlocks'
        // `startTime < reviewCutoff` filter, so it would keep resurfacing
        // in every future Today step with no in-app way to resolve it.
        // Clearing isn't destructive — the task survives and
        // remainingMinutes is restored below, so it just goes back to the
        // shelf to be rescheduled. Locking still protects present/future
        // blocks everywhere else (regenerateFromNow etc).
        let toClear = allBlocks.filter { !$0.isCompleted && $0.startTime < cutoff }
        for block in toClear {
            block.task?.isScheduled = false
            block.task?.pushedCount += 1
            if let eventID = block.googleEventID {
                try? await calendarService.deleteEvent(eventID: eventID)
            }
            removeBlock(block)
            blocks.removeAll { $0.id == block.id }
        }
        // Flushed explicitly rather than left to autosave — the caller
        // always runs `regenerateFromNow` right after this, which does its
        // own heavy run of fetches/inserts/deletes and repeatedly reads
        // relationships (e.g. `habit.scheduledBlocks`) touching these same
        // objects; leaving this batch of deletes unsaved going into that
        // has been the difference between a clean regenerate and a crash.
        try? modelContext.save()
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
        modelContext.insert(block)
        task.isScheduled = true
        blocks.append(block)
        blocks.sort { $0.startTime < $1.startTime }
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
