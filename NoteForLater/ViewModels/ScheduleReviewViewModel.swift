import Foundation
import SwiftData
import Observation

/// Drives the schedule review screen for a single day (default: today, but
/// navigable to any day) and every interaction the user has with a block:
/// delete (swipe left), auto-replace (swipe right), long-press to manually
/// replace, and — on today specifically — mark complete or push to another
/// day.
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
                existingBlocks: blocks
            )
            // The scheduler itself decides per-task whether to mark it fully
            // scheduled or just trim its remaining time (divisible tasks
            // that only got part of their time placed stay unscheduled).
            for block in proposed {
                modelContext.insert(block)
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

        while dayIndex == 0 || (consecutiveDaysWithoutTaskPlacement < Self.taskStallThresholdDays && hasRemainingSchedulableWork(shelves: shelves)) {
            guard var freeSlots = try? await calendarService.fetchFreeSlots(for: cursorDay) else { break }
            let dayBlocks = allBlocksNow.filter { calendar.isDate($0.date, inSameDayAs: cursorDay) }
            for existing in dayBlocks {
                freeSlots = subtracting(existing.startTime..<existing.endTime, from: freeSlots)
            }
            var placedTaskBlockToday = false
            if let newBlocks = try? await schedulingService.generateProposedSchedule(
                shelves: shelves,
                habits: habits,
                freeSlots: freeSlots,
                eligibleHoursWindows: eligibleHoursWindows,
                date: cursorDay,
                existingBlocks: dayBlocks
            ), !newBlocks.isEmpty {
                for block in newBlocks {
                    modelContext.insert(block)
                }
                allBlocksNow += newBlocks
                anyInserted = true
                placedTaskBlockToday = newBlocks.contains { $0.task != nil }
                if calendar.isDate(cursorDay, inSameDayAs: targetDate) {
                    blocks = (blocks + newBlocks).sorted { $0.startTime < $1.startTime }
                }
            }
            consecutiveDaysWithoutTaskPlacement = placedTaskBlockToday ? 0 : consecutiveDaysWithoutTaskPlacement + 1
            cursorDay = calendar.date(byAdding: .day, value: 1, to: cursorDay) ?? cursorDay
            dayIndex += 1
        }

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
            block.habit = nil
            modelContext.delete(block)
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
                        block.task = nil
                        block.habit = nil
                        modelContext.delete(block)
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
                    block.task = nil
                    block.habit = nil
                    modelContext.delete(block)
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
            restoreRemainingMinutes(for: block)
            // Explicitly clears the task/habit's to-one inverse before the
            // delete, rather than letting SwiftData's delete-rule nullify
            // sort it out on its own — otherwise a task picked up by a
            // *new* block later in this same run (before this delete has
            // actually settled) can find its `scheduledBlock` inverse
            // still claimed by the one being removed, which SwiftData
            // reports as a hard "relationship already has a value but
            // it's not the target" crash rather than silently overwriting it.
            block.task = nil
            block.habit = nil
            modelContext.delete(block)
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
        // reason to keep going is capped at a sane rolling horizon.
        // Tasks, on the other hand, actually run out: `hasRemainingSchedulableWork`
        // only ever counts a task that's both eligible for one of its
        // shelf's rules and genuinely able to fit it (see `SchedulingRule
        // .canEverFit`), so it's guaranteed to go false once everything
        // real is placed — a task that can never fit anywhere is already
        // excluded, not counted as "remaining" forever.
        let habitPopulationDays = 30
        var newBlocks: [ScheduledBlock] = []
        let keepWalkingForHabits = hasSchedulableHabits(habits: habits)
        // Bounds the *task* side of the walk without a flat day-count
        // cap — see `taskStallThresholdDays`. Reset to 0 any day that
        // places at least one task block (habit placements don't count;
        // this is purely about whether the task backlog is making
        // progress), incremented otherwise.
        var consecutiveDaysWithoutTaskPlacement = 0

        while dayIndex == 0
            || (dayIndex < habitPopulationDays && keepWalkingForHabits)
            || (consecutiveDaysWithoutTaskPlacement < Self.taskStallThresholdDays && hasRemainingSchedulableWork(shelves: shelves)) {
            do {
                var freeSlots = try await calendarService.fetchFreeSlots(for: cursorDay)
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
                let dayBlocks = try await schedulingService.generateProposedSchedule(
                    shelves: shelves,
                    habits: habits,
                    freeSlots: freeSlots,
                    eligibleHoursWindows: eligibleHoursWindows,
                    date: cursorDay,
                    existingBlocks: survivingBlocks.filter { calendar.isDate($0.date, inSameDayAs: cursorDay) }
                )
                for block in dayBlocks {
                    modelContext.insert(block)
                    newBlocks.append(block)
                }
                if dayBlocks.contains(where: { $0.task != nil }) {
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
            return (shelf.tasks ?? []).contains { task in
                guard !task.isScheduled else { return false }
                return rules.contains { rule in
                    task.isEligible(for: rule)
                        && rule.canEverFit(estimatedMinutes: task.remainingMinutes, isDivisible: task.isDivisible, minimumSegmentMinutes: task.minimumSegmentMinutes)
                }
            }
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
        // See the matching comment in `regenerateFromNow` — clears the
        // task/habit inverse explicitly before the delete so it can't be
        // left claiming this block once it's gone.
        block.task = nil
        block.habit = nil
        modelContext.delete(block)
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
        let replacement = nextCandidate(from: candidatePool, excluding: outgoing)

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
            oldBlock.task = nil
            modelContext.delete(oldBlock)
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

    /// Candidates for the Replace/Swap picker: on a schedulable shelf,
    /// not the block's own current task, not already completed, and —
    /// unlike `unscheduledCandidates` — not required to be unscheduled.
    /// A candidate that's already scheduled elsewhere is included as
    /// long as it has at most one active block and that block isn't
    /// locked, since taking over its slot (Replace) or trading places
    /// with it (Swap) both need a single, movable block to act on; a
    /// divisible task split across several blocks, or one pinned via a
    /// locked block, is left out rather than guessing which piece should
    /// move.
    func replaceCandidates(from allTasks: [TaskItem], excluding block: ScheduledBlock) -> [TaskItem] {
        allTasks.filter { task in
            guard task.shelf?.hasEnabledSchedulingRules ?? false, task.id != block.task?.id, !task.isCompleted else { return false }
            guard task.isScheduled else { return true }
            let activeBlocks = (task.scheduledBlocks ?? []).filter { !$0.isCompleted }
            return activeBlocks.count <= 1 && !(activeBlocks.first?.isLocked ?? false)
        }
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
                block.task = nil
                modelContext.delete(block)
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
                block.habit = nil
                modelContext.delete(block)
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
            restoreRemainingMinutes(for: block)
            if let eventID = block.googleEventID {
                try? await calendarService.deleteEvent(eventID: eventID)
            }
            block.task = nil
            block.habit = nil
            modelContext.delete(block)
            blocks.removeAll { $0.id == block.id }
        }
        try? modelContext.save()
    }

    private func habitLog(for habit: Habit, on date: Date) -> HabitLog {
        let calendar = Calendar.current
        if let existing = habit.log(on: date, calendar: calendar) {
            return existing
        }
        let newLog = HabitLog(habit: habit, date: calendar.startOfDay(for: date))
        modelContext.insert(newLog)
        return newLog
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
    static func openHabitOccurrencesForReview(habits: [Habit], upTo cutoff: Date = .now, alsoInclude: Set<String> = []) -> [HabitReviewOccurrence] {
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
                        let status = habit.occurrenceStatus(index, on: cursor, calendar: calendar)
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

    static func hasOpenHabitOccurrences(habits: [Habit], upTo cutoff: Date = .now) -> Bool {
        !openHabitOccurrencesForReview(habits: habits, upTo: cutoff).isEmpty
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
        for occurrence in Self.openHabitOccurrencesForReview(habits: habits, upTo: cutoff) {
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
        let toClear = allBlocks.filter { !$0.isCompleted && $0.startTime < cutoff && !$0.isLocked }
        for block in toClear {
            block.task?.isScheduled = false
            block.task?.pushedCount += 1
            restoreRemainingMinutes(for: block)
            if let eventID = block.googleEventID {
                try? await calendarService.deleteEvent(eventID: eventID)
            }
            // See the matching comment in `regenerateFromNow` — clearing
            // the inverse explicitly before the delete avoids a SwiftData
            // "relationship already has a value but it's not the target"
            // crash when a new block claims this same task/habit shortly
            // after (regenerateFromNow always runs right after this).
            block.task = nil
            block.habit = nil
            modelContext.delete(block)
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

    /// Tasks eligible to fill an empty/replaced slot: unscheduled, on a schedulable shelf.
    func unscheduledCandidates(from allTasks: [TaskItem], excluding block: ScheduledBlock) -> [TaskItem] {
        allTasks.filter { ($0.shelf?.hasEnabledSchedulingRules ?? false) && !$0.isScheduled && $0.id != block.task?.id }
    }

    /// Same, but for tapping an open slot on the timeline grid — there's no
    /// existing block/task to exclude yet.
    func unscheduledCandidates(from allTasks: [TaskItem]) -> [TaskItem] {
        allTasks.filter { ($0.shelf?.hasEnabledSchedulingRules ?? false) && !$0.isScheduled }
    }

    /// Same as `unscheduledCandidates(from:)`, but also includes unsorted
    /// Inbox tasks (no shelf at all) — used by the timeline's
    /// long-press-to-insert popover specifically, where you're manually
    /// placing something rather than picking from the auto-scheduler's own
    /// rule-gated candidate pool.
    func unscheduledCandidatesIncludingInbox(from allTasks: [TaskItem]) -> [TaskItem] {
        allTasks.filter { task in
            guard !task.isScheduled else { return false }
            guard let shelf = task.shelf else { return true }
            return shelf.hasEnabledSchedulingRules
        }
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

    /// Same ordering AISchedulingService uses when picking tasks to
    /// generate a schedule: priority first, then whichever has been
    /// sitting on the shelf longest (oldest `createdAt` first), then due
    /// date as the final tiebreaker.
    private func nextCandidate(from pool: [TaskItem], excluding outgoing: TaskItem?) -> TaskItem? {
        pool
            .filter { ($0.shelf?.hasEnabledSchedulingRules ?? false) && !$0.isScheduled && $0.id != outgoing?.id }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority {
                    return priorityRank(lhs.priority) > priorityRank(rhs.priority)
                }
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt < rhs.createdAt
                }
                return (lhs.dueDate ?? .distantFuture) < (rhs.dueDate ?? .distantFuture)
            }
            .first
    }

    private func priorityRank(_ priority: Priority) -> Int {
        switch priority {
        case .high: return 3
        case .medium: return 2
        case .low: return 1
        case .unset: return 0
        }
    }
}
