import Foundation

/// Turns "here's my shelves' SchedulingRules + here's my open calendar
/// time" into a proposed set of ScheduledBlocks for a given day. There's
/// no separate "generate" moment anymore — the calendar is meant to
/// always be live, reflecting whatever the current shelves/rules say
/// should be on a day the instant it's viewed (see
/// `ScheduleReviewViewModel.autoPlaceEligibleTasks`, which calls this on
/// every appear/day-change). Nightly Review's own end-of-day handoff
/// (`regenerateFromNow`) still calls this too, for its own different
/// job: clearing out and re-optimizing whatever isn't locked/approved
/// across every future day, the chance to review and move things around
/// the night before — not the only way a day ever gets populated in the
/// first place.
///
/// TODO(Claude Code): Replace the greedy mock packer with a real call to the
/// Claude API (Messages API) — same shape, just smarter task selection.
protocol AISchedulingServiceProtocol: AnyObject {
    /// A task only ever gets pulled into a rule's window if it's been
    /// explicitly toggled eligible for that specific schedule on its own
    /// task card ("Eligible Schedules") — a task that only has, say,
    /// Weekends toggled on is never a candidate for a weekday rule's
    /// leftover budget, no matter how much room that rule still has. (An
    /// earlier version relaxed this once every explicitly-eligible task
    /// already had a slot, on the theory that unused budget was being
    /// wasted — but that meant a task's own eligible-schedule choices
    /// could be silently overridden by whichever rule happened to run
    /// short on candidates, which is the opposite of what that toggle is
    /// for.)
    /// `existingBlocks` — every task/habit block already sitting on
    /// `date`, from any earlier call — is what lets a rule's own
    /// fill-strategy budget (e.g. "≤2 tasks") stay a real cap across
    /// *repeated* calls, not just within a single one: each call's own
    /// `pack()` seeds its task-count/total-minutes counters with
    /// whatever's already occupying that rule's window before it decides
    /// how much more room it has. Without this, a rule capped at 2 tasks
    /// would place 2 more every single time this ran — which, now that
    /// `ScheduleReviewViewModel.autoPlaceEligibleTasks` calls this on
    /// every appear/day-change rather than once via an explicit generate,
    /// is routine, not a rare double-run.
    func generateProposedSchedule(
        shelves: [Shelf],
        habits: [Habit],
        freeSlots: [TimeSlot],
        eligibleHoursWindows: [EligibleHoursWindow],
        date: Date,
        existingBlocks: [ScheduledBlock]
    ) async throws -> [ScheduledBlock]

    /// The two categories that jump the whole queue — habits and the
    /// Recurring Tasks shelf's own tasks (see `Shelf.isRecurringTasks`) —
    /// split out of `generateProposedSchedule` so a caller can top these
    /// up on their own, without a full (rule-packing, network-fetching)
    /// pass. Synchronous and side-effect-free — no calendar or model
    /// access here, that's on the caller. `generateProposedSchedule`
    /// itself opens with this same pass — this is only kept as its own
    /// entry point in case something ever needs just the habit/recurring
    /// half without the rest.
    func placeHabitsAndRecurringTasks(
        shelves: [Shelf],
        habits: [Habit],
        freeSlots: [TimeSlot],
        eligibleHoursWindows: [EligibleHoursWindow],
        date: Date
    ) -> (blocks: [ScheduledBlock], remainingFree: [TimeSlot])
}

/// Greedy packer, but rule-aware: for each enabled SchedulingRule whose
/// days include `date`'s weekday, intersects the rule's time window with
/// whatever calendar time is still free, then pulls tasks from that rule's
/// shelf according to its fill strategy. Rules run in shelf/rule sortOrder,
/// and free time consumed by one rule isn't available to the next — so two
/// shelves with overlapping windows on the same day never double-book the
/// same slot.
///
/// Each rule's own pass covers two tiers, in order, both pulling from
/// that same rule's window, that same rule's fill-strategy budget, and
/// only tasks explicitly marked eligible for this specific rule (never
/// anywhere else — a task never lands outside a shelf's own
/// eligible-schedule hours just because there was leftover time somewhere
/// else in the day, and never under a rule it wasn't opted into just
/// because that rule had room left):
///   1. Shelf task, has a real duration, eligible for this rule — today's
///      baseline behavior.
///   2. Same, but no duration set — guessed (see `guessedMinutes`) rather
///      than left unscheduled forever.
/// Inbox tasks (no shelf at all) are deliberately never auto-scheduled —
/// they're surfaced for the user to sort or explicitly place instead (see
/// ScheduleReviewView's pre-generate "Review Inbox" prompt and the
/// timeline's long-press-to-insert picker).
/// Within every rule, ordering (`tieredOrdering`) puts a real duration
/// before a guessed one — so a guess only ever fills time nothing
/// better-specified wanted.
final class MockAISchedulingService: AISchedulingServiceProtocol {
    func generateProposedSchedule(
        shelves: [Shelf],
        habits: [Habit],
        freeSlots: [TimeSlot],
        eligibleHoursWindows: [EligibleHoursWindow],
        date: Date,
        existingBlocks: [ScheduledBlock]
    ) async throws -> [ScheduledBlock] {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date)

        // A rule only ever contributes a window that's actually defined on
        // the Schedules screen — never its own dead "custom" fallback
        // fields (see SchedulingRule.effectiveStartHour etc.). Those fields
        // exist only so a rule whose NamedSchedule gets deleted doesn't
        // crash; without this filter it would instead silently keep
        // scheduling into whatever stale window it happened to be created
        // with, with no way to see or edit that window anywhere in the UI.
        let applicableRules: [(rule: SchedulingRule, shelf: Shelf)] = shelves
            .sorted { $0.sortOrder < $1.sortOrder }
            .flatMap { shelf in (shelf.schedulingRules ?? []).map { (rule: $0, shelf: shelf) } }
            .filter { $0.rule.isEnabled && $0.rule.namedSchedule != nil && $0.rule.effectiveDaysOfWeek.contains(weekday) }
            .sorted { $0.rule.sortOrder < $1.rule.sortOrder }

        let (initialBlocks, freeAfterHabits) = placeHabitsAndRecurringTasks(
            shelves: shelves,
            habits: habits,
            freeSlots: freeSlots,
            eligibleHoursWindows: eligibleHoursWindows,
            date: date
        )
        var blocks = initialBlocks
        var remainingFree = freeAfterHabits

        var scheduledTaskIDs = Set<UUID>()

        // Each rule's window gets one combined pack() call covering all
        // three tiers at once (eligible-and-timed, eligible-and-guessed,
        // then not-explicitly-eligible) — a single call so the rule's own
        // fill-strategy budget (e.g. "≤2 tasks") is enforced once across
        // every tier, not reset per tier and potentially double-spent.
        for (rule, shelf) in applicableRules {
            guard
                let windowStart = calendar.date(bySettingHour: rule.effectiveStartHour, minute: rule.effectiveStartMinute, second: 0, of: date),
                let windowEnd = calendar.date(bySettingHour: rule.effectiveEndHour, minute: rule.effectiveEndMinute, second: 0, of: date),
                windowStart < windowEnd
            else { continue }

            let window = TimeSlot(start: windowStart, end: windowEnd)
            let availableInWindow = intersect(remainingFree, with: window)
            guard !availableInWindow.isEmpty else { continue }

            let candidates = (shelf.tasks ?? [])
                // A recurring task (see `Shelf.isRecurringTasks`) is
                // placed exclusively by the fixed-time pass above, at its
                // own anchor time on every occurrence day — `isScheduled`
                // is deliberately never set for it, so without this
                // exclusion it would look permanently unscheduled and
                // eligible to *also* get pulled in here if this shelf
                // ever picked up a SchedulingRule of its own. A task
                // whose own `startDate` hasn't arrived yet (see
                // `TaskItem.isEligibleToStart`) is excluded the same way —
                // it just sits out this day's packing entirely rather
                // than counting as unschedulable.
                .filter { !$0.isScheduled && !$0.isRecurring && !scheduledTaskIDs.contains($0.id) && $0.isEligibleToStart(on: date, calendar: calendar) }
                // A task never toggled eligible for this specific rule
                // simply isn't a candidate for it, full stop — see this
                // method's doc comment.
                .filter { $0.isEligible(for: rule) }
                .sorted { tieredOrdering($0, $1) }

            // Every task block already sitting inside this rule's own
            // window — whichever call actually placed it — counts against
            // its budget before a single new candidate is considered. Habit
            // blocks are excluded: those aren't rule-packed at all, and a
            // habit is explicitly allowed to double-book against a task
            // (see `placeHabitsAndRecurringTasks`), so it was never part of
            // this rule's own budget to begin with.
            let alreadyInWindow = existingBlocks.filter { $0.task != nil && $0.startTime >= windowStart && $0.startTime < windowEnd }
            // Counted by distinct task, not by block — a divisible task
            // already split across several of its own minimum-size
            // segments (see `TaskItem.isDivisible`/`minimumSegmentMinutes`)
            // is still only ONE task against a per-task cap, same as
            // `pack()` itself only bumps `taskCount` once per task no
            // matter how many segments that task's own placement produced.
            let startingTaskCount = Set(alreadyInWindow.compactMap { $0.task?.id }).count
            let startingMinutesUsed = alreadyInWindow.reduce(0) { $0 + Int($1.endTime.timeIntervalSince($1.startTime) / 60) }

            let (placed, leftoverInWindow) = pack(
                candidates: candidates,
                into: availableInWindow,
                rule: rule,
                startingTaskCount: startingTaskCount,
                startingMinutesUsed: startingMinutesUsed
            )
            for (task, start, end, isEstimated) in placed {
                blocks.append(ScheduledBlock(date: date, startTime: start, endTime: end, task: task, isEstimatedDuration: isEstimated))
                scheduledTaskIDs.insert(task.id)
            }

            let outsideWindow = subtract(remainingFree, window: window)
            remainingFree = (outsideWindow + leftoverInWindow).sorted { $0.start < $1.start }
        }

        return blocks.sorted { $0.startTime < $1.startTime }
    }

    // MARK: - Habits + Recurring Tasks (also callable on their own)

    /// The shared front-of-day pass `generateProposedSchedule` itself opens
    /// with — pulled out so a caller (see
    /// `ScheduleReviewViewModel.autoPlaceHabitsAndRecurringTasks`) can top
    /// these up on their own without a full regenerate.
    func placeHabitsAndRecurringTasks(
        shelves: [Shelf],
        habits: [Habit],
        freeSlots: [TimeSlot],
        eligibleHoursWindows: [EligibleHoursWindow],
        date: Date
    ) -> (blocks: [ScheduledBlock], remainingFree: [TimeSlot]) {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date)

        var remainingFree = freeSlots.sorted { $0.start < $1.start }

        // Global guardrail: clip the day's whole free pool down to whatever
        // falls inside the enabled eligible-hours windows for this weekday,
        // before any shelf rule gets a turn. No windows configured = no
        // restriction, so this is a no-op by default.
        let eligibleToday = eligibleHoursWindows.filter { $0.isEnabled && $0.daysOfWeek.contains(weekday) }
        if !eligibleToday.isEmpty {
            let eligibleRanges = eligibleToday.compactMap { window -> TimeSlot? in
                guard
                    let start = calendar.date(bySettingHour: window.startHour, minute: window.startMinute, second: 0, of: date),
                    let end = calendar.date(bySettingHour: window.endHour, minute: window.endMinute, second: 0, of: date),
                    start < end
                else { return nil }
                return TimeSlot(start: start, end: end)
            }
            remainingFree = eligibleRanges
                .flatMap { intersect(remainingFree, with: $0) }
                .sorted { $0.start < $1.start }
        }

        var blocks: [ScheduledBlock] = []

        // The shelf marked `isTwoMinuteTasks` (see `Shelf.isTwoMinuteTasks`)
        // is deliberately NOT placed onto the calendar here — it used to
        // jump the queue and land at the very front of the day's free
        // time, which in practice meant midnight whenever nothing else
        // occupied the morning. These are surfaced instead as their own
        // untimed checklist above the calendar (see
        // `ScheduleReviewView.twoMinuteTasksSection`) and in Nightly
        // Review's own step — nothing here ever gives one of its tasks a
        // start/end time.

        // Every habit is assumed schedulable — placed first, one block per
        // occurrence (not just the first), each exactly at that
        // occurrence's own target time and `estimatedMinutes` long —
        // deliberately ignoring eligible hours entirely (neither the
        // day's overall guardrail nor any per-habit concept constrains
        // *when* it lands, only *whether* it's applicable today and not
        // already fully resolved). A habit's target time is a commitment
        // the user made directly; it shouldn't get bumped around by a
        // scheduling concept that exists for tasks — and, going the other
        // way, a habit is the one thing allowed to land on a time a task
        // already occupies (or vice versa below); nothing here checks for
        // that. Whichever occurrences already have a block for this day
        // (checked by start time, since a block itself doesn't record an
        // occurrence index) are left alone rather than re-added — a habit
        // can be partially placed (one occurrence generated earlier, say)
        // and still pick up its remaining occurrences here. An occurrence
        // past `idealTimesOfDay` reuses the last time on the list.
        //
        // Placed before any task packing below specifically so tasks can
        // see where habits already are and route around them — see
        // `habitOccupiedRanges` — since only a habit is allowed to
        // double-book, never a task against anything else.
        let eligibleHabits = habits
            .filter {
                $0.isApplicable(on: date, calendar: calendar)
                    && $0.status(on: date, asOf: date, calendar: calendar) == nil
            }
            .sorted { $0.sortOrder < $1.sortOrder }

        var habitOccupiedRanges: [TimeSlot] = []
        for habit in eligibleHabits {
            let existingBlocksToday = (habit.scheduledBlocks ?? []).filter { calendar.isDate($0.date, inSameDayAs: date) }
            habitOccupiedRanges.append(contentsOf: existingBlocksToday.map { TimeSlot(start: $0.startTime, end: $0.endTime) })
            // Keyed by occurrence index, not start time — a block that's
            // been dragged to a different time (see
            // `ScheduleReviewViewModel.reorderTimeline`) no longer sits at
            // its own `idealTimesOfDay` slot, so matching on start time
            // alone would miss it and place a second, duplicate block for
            // the same occurrence right back at the original ideal time
            // every time this runs (every time the Calendar tab reappears
            // or the viewed day changes — see `autoPlaceHabitsAndRecurringTasks`).
            let existingOccurrenceIndices = Set(existingBlocksToday.map(\.habitOccurrenceIndex))

            for occurrenceIndex in 0..<max(habit.timesPerDay, 1) {
                // The authoritative check — an occurrence already marked
                // complete/missed/excused never gets placed again, even if
                // its own block happened to get swept up and deleted by
                // something unrelated (e.g. `regenerateFromNow` clearing
                // out not-yet-approved future blocks): resolved is
                // resolved, regardless of whether a block still exists for
                // it right now.
                guard habit.occurrenceStatus(occurrenceIndex, on: date, calendar: calendar) == .none else { continue }
                // An AM/Midday/PM occurrence (see `HabitOccurrenceTimeMode`)
                // never gets a calendar block at all — it surfaces instead
                // as an untimed list item (see
                // `DayTimelineGridView.habitOccurrenceSection`).
                guard habit.timeMode(for: occurrenceIndex) == .specific else { continue }
                // Still-incomplete but already on the calendar somewhere
                // (moved or not) — don't duplicate it.
                guard !existingOccurrenceIndices.contains(occurrenceIndex) else { continue }
                let idealMinutes = occurrenceIndex < habit.idealTimesOfDay.count
                    ? habit.idealTimesOfDay[occurrenceIndex]
                    : (habit.idealTimesOfDay.last ?? 0)
                let start = calendar.date(bySettingHour: idealMinutes / 60, minute: idealMinutes % 60, second: 0, of: date) ?? date
                let end = start.addingTimeInterval(TimeInterval(habit.estimatedMinutes * 60))
                blocks.append(ScheduledBlock(date: date, startTime: start, endTime: end, task: nil, habit: habit, habitOccurrenceIndex: occurrenceIndex))
                habitOccupiedRanges.append(TimeSlot(start: start, end: end))
            }
        }

        // Any task with "Recurring?" toggled on (see `TaskItem.isRecurring`,
        // toggleable from the top of any task card, on any shelf) is
        // treated the same way habits are — every occurrence due today
        // (see `TaskItem.hasRecurringOccurrence`) is placed unconditionally
        // at its own fixed anchor time (`recurringOccurrenceTime`),
        // regardless of what else is going on: a recurring task is a
        // commitment with a fixed time, not something competing for free
        // time the way a shelf's rule-packed tasks do. One recurring task
        // can carry many blocks over its lifetime — unlike every other
        // task, `TaskItem.isScheduled`/`isCompleted` stay meaningless
        // here; completion lives entirely on each occurrence's own block.
        for task in shelves.flatMap({ $0.tasks ?? [] }) where task.isRecurring {
            guard task.hasRecurringOccurrence(on: date, calendar: calendar) else { continue }
            guard let start = task.recurringOccurrenceTime(on: date, calendar: calendar) else { continue }
            let alreadyExists = (task.scheduledBlocks ?? []).contains { calendar.isDate($0.date, inSameDayAs: date) }
            guard !alreadyExists else { continue }
            let minutes = task.estimatedMinutes > 0 ? task.estimatedMinutes : 30
            let end = start.addingTimeInterval(TimeInterval(minutes * 60))
            blocks.append(ScheduledBlock(date: date, startTime: start, endTime: end, task: task, isEstimatedDuration: task.estimatedMinutes <= 0))
            habitOccupiedRanges.append(TimeSlot(start: start, end: end))
        }

        // Carved out of the free pool before any task ever gets packed —
        // this is what keeps a rule-packed task from ever landing on a
        // habit's or recurring task's time, the one overlap that isn't
        // allowed. A habit or recurring task itself never consults this;
        // each is only ever the thing being routed around.
        for occupied in habitOccupiedRanges {
            remainingFree = subtract(remainingFree, window: occupied)
        }

        return (blocks, remainingFree)
    }

    // MARK: - Packing

    /// Greedily places candidates into `slots` per the rule's fill
    /// strategy, returning what got placed and whatever slot time is left.
    ///
    /// When a divisible task only gets part of its time placed (truncated
    /// by a maxDuration budget or a maxTaskCount per-task cap), its
    /// `estimatedMinutes` is reduced by exactly what got scheduled and it's
    /// left unscheduled — the remainder stays on the shelf, eligible to be
    /// picked up again by another rule or a future night. Only a task whose
    /// *entire* remaining time gets placed is marked scheduled.
    ///
    /// A task with no duration set at all (`estimatedMinutes <= 0`, e.g.
    /// "Duration: No" on its card) would otherwise never clear the
    /// `minutesNeeded > 0` guard below and sit unscheduled forever —
    /// instead it gets a guessed duration (see `guessedMinutes`) just for
    /// this placement. `task.estimatedMinutes` itself is left untouched
    /// (still 0/unset), so the caller can tell it was a guess and mark the
    /// resulting block's duration with "~" rather than presenting it as a
    /// real commitment.
    private func pack(
        candidates: [TaskItem],
        into slots: [TimeSlot],
        rule: SchedulingRule,
        startingTaskCount: Int = 0,
        startingMinutesUsed: Int = 0
    ) -> (placed: [(task: TaskItem, start: Date, end: Date, isEstimated: Bool)], remainingSlots: [TimeSlot]) {
        var slots = slots.sorted { $0.start < $1.start }
        var results: [(TaskItem, Date, Date, Bool)] = []
        var totalMinutesUsed = startingMinutesUsed
        var taskCount = startingTaskCount

        for task in candidates {
            if rule.fillStrategy == .maxTaskCount, taskCount >= rule.maxTaskCount { break }
            if rule.fillStrategy == .maxDuration, totalMinutesUsed >= rule.maxTotalMinutes { break }
            // Max Total Duration's own optional secondary cap — stops the
            // window early even with budget still left, once its own
            // `maxTaskCount` tasks are already in.
            if rule.fillStrategy == .maxDuration, rule.maxDurationTaskCountEnabled, taskCount >= rule.maxTaskCount { break }

            let isEstimated = task.estimatedMinutes <= 0
            // `remainingMinutes`, not `estimatedMinutes` — a task already
            // partially placed by an earlier pack() call has less left to
            // offer than its original stated size, and `estimatedMinutes`
            // itself is never touched by the scheduler (see `TaskItem
            // .remainingMinutes`'s doc comment).
            let baseMinutes = isEstimated ? guessedMinutes(for: rule) : task.remainingMinutes

            let minutesNeeded: Int
            switch rule.fillStrategy {
            case .fillToFit:
                minutesNeeded = baseMinutes
            case .maxDuration:
                // budget > 0 is guaranteed here: the loop-top check above
                // already breaks once totalMinutesUsed reaches the cap.
                let budget = rule.maxTotalMinutes - totalMinutesUsed
                if baseMinutes <= budget {
                    minutesNeeded = baseMinutes
                } else if task.isDivisible {
                    minutesNeeded = budget
                } else {
                    continue // doesn't fit the remaining budget and can't be split
                }
            case .maxTaskCount:
                if baseMinutes <= rule.maxMinutesPerTask {
                    minutesNeeded = baseMinutes
                } else if task.isDivisible {
                    minutesNeeded = rule.maxMinutesPerTask
                } else {
                    continue // too long for a single capped session and can't be split
                }
            }
            guard minutesNeeded > 0 else { continue }
            // A divisible task with no minimum segment chosen yet ("Not
            // Selected") can't be split safely — treat it as not ready.
            guard !task.isDivisible || task.minimumSegmentMinutes > 0 else { continue }
            // A divisible task's own minimum chunk size is a hard floor —
            // if this rule's own per-task cap (Max Task Count) or
            // remaining budget (Max Total Duration) can't offer at least
            // that much in one placement, the task simply doesn't fit
            // this rule at all. Without this, the branches above would
            // otherwise happily hand it whatever's left of the rule's own
            // budget even when that's smaller than the one floor the user
            // actually set — a 2-hour-minimum task getting split into
            // 15-minute slivers because that's all a "≤15 min each" rule
            // ever offers.
            guard !task.isDivisible || minutesNeeded >= task.minimumSegmentMinutes else { continue }

            guard let placement = place(
                minutesNeeded: minutesNeeded,
                minimumSegment: task.minimumSegmentMinutes,
                isDivisible: task.isDivisible,
                in: slots
            ) else { continue }

            for (start, end) in placement {
                results.append((task, start, end, isEstimated))
            }
            slots = updatedSlots(after: placement, in: slots)
            // Not always equal to `minutesNeeded` — `place` rounds a
            // final divisible segment up to the task's own minimum chunk
            // size rather than ever leaving a sliver smaller than it, so
            // the actual placed total can run a few minutes over what was
            // asked for. Bookkeeping (the budget/cap counters below, and
            // what's left owed on the task itself) has to track the real
            // placed amount, not the request, or the two drift apart.
            let actualMinutes = placement.reduce(0) { $0 + Int($1.end.timeIntervalSince($1.start) / 60) }
            totalMinutesUsed += actualMinutes
            taskCount += 1

            if isEstimated || actualMinutes >= task.remainingMinutes {
                task.isScheduled = true
                task.remainingMinutes = 0
            } else {
                task.remainingMinutes -= actualMinutes
            }
        }

        return (results, slots)
    }

    /// A flat 30-minute default — the same fallback `ScheduleReviewViewModel
    /// .insertBlock` already uses for a duration-less task added manually
    /// from the timeline — capped to whatever the rule itself allows, so
    /// the guess never busts a rule's own per-task or total-minutes cap
    /// (e.g. a "≤15 min each" rule never gets a 30-minute guess).
    private func guessedMinutes(for rule: SchedulingRule) -> Int {
        let defaultGuess = 30
        switch rule.fillStrategy {
        case .maxTaskCount:
            return rule.maxMinutesPerTask > 0 ? min(defaultGuess, rule.maxMinutesPerTask) : defaultGuess
        case .maxDuration:
            return rule.maxTotalMinutes > 0 ? min(defaultGuess, rule.maxTotalMinutes) : defaultGuess
        case .fillToFit:
            return defaultGuess
        }
    }

    /// Tries a single contiguous slot first; falls back to splitting across
    /// multiple slots (each piece >= minimumSegment) only if `isDivisible`.
    private func place(minutesNeeded: Int, minimumSegment: Int, isDivisible: Bool, in slots: [TimeSlot]) -> [(start: Date, end: Date)]? {
        if let slot = slots.first(where: { $0.durationMinutes >= minutesNeeded }) {
            let end = slot.start.addingTimeInterval(TimeInterval(minutesNeeded * 60))
            return [(slot.start, end)]
        }

        guard isDivisible else { return nil }

        var remaining = minutesNeeded
        var segments: [(Date, Date)] = []
        for slot in slots {
            guard remaining > 0 else { break }
            guard slot.durationMinutes >= minimumSegment else { continue }
            // A trailing sliver smaller than the task's own configured
            // minimum chunk is never scheduled — the guard above already
            // guarantees this slot can hold at least `minimumSegment`, so
            // rounding the final piece up to it (rather than the smaller
            // `remaining`) trades a few extra minutes on the calendar for
            // never producing a segment under the floor the user chose.
            let take = remaining >= minimumSegment ? min(remaining, slot.durationMinutes) : minimumSegment
            let segmentEnd = slot.start.addingTimeInterval(TimeInterval(take * 60))
            segments.append((slot.start, segmentEnd))
            remaining -= take
        }
        return remaining <= 0 ? segments : nil
    }

    /// Removes whatever `placement` consumed from `slots`, keeping leftovers.
    private func updatedSlots(after placement: [(start: Date, end: Date)], in slots: [TimeSlot]) -> [TimeSlot] {
        var result = slots
        for segment in placement {
            result = result.flatMap { slot -> [TimeSlot] in
                guard segment.start >= slot.start, segment.end <= slot.end else { return [slot] }
                var pieces: [TimeSlot] = []
                if segment.start > slot.start {
                    pieces.append(TimeSlot(start: slot.start, end: segment.start))
                }
                if segment.end < slot.end {
                    pieces.append(TimeSlot(start: segment.end, end: slot.end))
                }
                return pieces
            }
        }
        return result.filter { $0.durationMinutes > 0 }
    }

    // MARK: - Slot arithmetic

    private func intersect(_ slots: [TimeSlot], with window: TimeSlot) -> [TimeSlot] {
        slots.compactMap { slot in
            let start = max(slot.start, window.start)
            let end = min(slot.end, window.end)
            return start < end ? TimeSlot(start: start, end: end) : nil
        }
    }

    /// The parts of `slots` that fall outside `window`, untouched.
    private func subtract(_ slots: [TimeSlot], window: TimeSlot) -> [TimeSlot] {
        slots.flatMap { slot -> [TimeSlot] in
            var pieces: [TimeSlot] = []
            if slot.start < window.start {
                pieces.append(TimeSlot(start: slot.start, end: min(slot.end, window.start)))
            }
            if slot.end > window.end {
                pieces.append(TimeSlot(start: max(slot.start, window.end), end: slot.end))
            }
            return pieces.filter { $0.durationMinutes > 0 }
        }
    }

    // MARK: - Ordering

    /// Every candidate here has already passed the eligible-for-`rule`
    /// filter (see `generateProposedSchedule`'s per-rule loop), so the
    /// only tier left to break ties on is duration.
    private func tieredOrdering(_ lhs: TaskItem, _ rhs: TaskItem) -> Bool {
        return durationTieredOrdering(lhs, rhs)
    }

    /// A real duration always sorts before a guessed one (see `pack`'s
    /// `isEstimated` handling) — within each tier, so a task that never
    /// had its duration set only ever fills time nothing better-specified
    /// wanted first, rather than potentially crowding out a properly-
    /// estimated task on `taskOrdering` priority/age alone.
    private func durationTieredOrdering(_ lhs: TaskItem, _ rhs: TaskItem) -> Bool {
        let lhsHasDuration = lhs.estimatedMinutes > 0
        let rhsHasDuration = rhs.estimatedMinutes > 0
        if lhsHasDuration != rhsHasDuration {
            return lhsHasDuration && !rhsHasDuration
        }
        return taskOrdering(lhs, rhs)
    }

    /// Nearing due date first, then priority (high before low), then
    /// whichever task has been sitting on the shelf longest (oldest
    /// `createdAt` first) — the three real ranking criteria. Whatever
    /// survives all three still tied (most often several tasks added in
    /// the same batch import, sharing an identical `createdAt`) falls
    /// through to a fourth, "minimize how many tasks it takes to fill the
    /// available time" tiebreak: larger before smaller, and a task that
    /// fills a slot in one whole piece before a divisible one that would
    /// have to be chopped up to do the same — so, all else equal, one
    /// 2-hour task is preferred over four 30-minute divisible ones for
    /// filling a 2-hour window, rather than fragmenting it four ways.
    private func taskOrdering(_ lhs: TaskItem, _ rhs: TaskItem) -> Bool {
        let lhsDue = lhs.dueDate ?? .distantFuture
        let rhsDue = rhs.dueDate ?? .distantFuture
        if lhsDue != rhsDue {
            return lhsDue < rhsDue
        }
        if lhs.priority != rhs.priority {
            return priorityRank(lhs.priority) > priorityRank(rhs.priority)
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        if lhs.estimatedMinutes != rhs.estimatedMinutes {
            return lhs.estimatedMinutes > rhs.estimatedMinutes
        }
        return !lhs.isDivisible && rhs.isDivisible
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
