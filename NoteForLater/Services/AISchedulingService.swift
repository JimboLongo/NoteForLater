import Foundation

/// Turns "here's my shelves' SchedulingRules + here's my open calendar
/// time" into a proposed set of ScheduledBlocks for a given day. This is
/// the piece the nightly job calls to build tomorrow's preview.
///
/// TODO(Claude Code): Replace the greedy mock packer with a real call to the
/// Claude API (Messages API) — same shape, just smarter task selection.
protocol AISchedulingServiceProtocol: AnyObject {
    func generateProposedSchedule(
        shelves: [Shelf],
        habits: [Habit],
        freeSlots: [TimeSlot],
        eligibleHoursWindows: [EligibleHoursWindow],
        date: Date
    ) async throws -> [ScheduledBlock]
}

/// Greedy packer, but rule-aware: for each enabled SchedulingRule whose
/// days include `date`'s weekday, intersects the rule's time window with
/// whatever calendar time is still free, then pulls tasks from that rule's
/// shelf according to its fill strategy. Rules run in shelf/rule sortOrder,
/// and free time consumed by one rule isn't available to the next — so two
/// shelves with overlapping windows on the same day never double-book the
/// same slot.
///
/// Each rule's own pass actually covers three tiers, in order, all pulling
/// from that same rule's window and that same rule's fill-strategy budget
/// (never anywhere else — a task never lands outside a shelf's own
/// eligible-schedule hours just because there was leftover time somewhere
/// else in the day):
///   1. Shelf task, has a real duration, eligible for this rule — today's
///      baseline behavior.
///   2. Same, but no duration set — guessed (see `guessedMinutes`) rather
///      than left unscheduled forever.
///   3. A task on this same shelf that was never marked eligible for this
///      specific rule at all — only reached once every eligible task
///      already has a slot, and only for whatever's left of this rule's
///      own budget (a "≤2 tasks" rule still never places more than 2, this
///      tier just relaxes *which* tasks can fill those 2).
/// Inbox tasks (no shelf at all) are deliberately never auto-scheduled —
/// they're surfaced for the user to sort or explicitly place instead (see
/// ScheduleReviewView's pre-generate "Review Inbox" prompt and the
/// timeline's long-press-to-insert picker).
/// Within every rule, ordering (`tieredOrdering`) is eligible before
/// not-eligible, and within each of those, a real duration before a
/// guessed one — so a guess, or a not-explicitly-eligible task, only ever
/// fills time nothing better-specified wanted.
final class MockAISchedulingService: AISchedulingServiceProtocol {
    func generateProposedSchedule(
        shelves: [Shelf],
        habits: [Habit],
        freeSlots: [TimeSlot],
        eligibleHoursWindows: [EligibleHoursWindow],
        date: Date
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

        var scheduledTaskIDs = Set<UUID>()
        var blocks: [ScheduledBlock] = []

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
                .filter { !$0.isScheduled && !scheduledTaskIDs.contains($0.id) }
                .sorted { tieredOrdering($0, $1, rule: rule) }

            let (placed, leftoverInWindow) = pack(candidates: candidates, into: availableInWindow, rule: rule)
            for (task, start, end, isEstimated) in placed {
                blocks.append(ScheduledBlock(date: date, startTime: start, endTime: end, task: task, isEstimatedDuration: isEstimated))
                scheduledTaskIDs.insert(task.id)
            }

            let outsideWindow = subtract(remainingFree, window: window)
            remainingFree = (outsideWindow + leftoverInWindow).sorted { $0.start < $1.start }
        }

        // Every habit is assumed schedulable — placed last, one block per
        // occurrence (not just the first), each exactly at that
        // occurrence's own target time and `estimatedMinutes` long —
        // deliberately ignoring eligible hours entirely (neither the
        // day's overall guardrail nor any per-habit concept constrains
        // *when* it lands, only *whether* it's applicable today and not
        // already fully resolved). A habit's target time is a commitment
        // the user made directly; it shouldn't get bumped around by a
        // scheduling concept that exists for tasks. Whichever occurrences
        // already have a block for this day (checked by start time, since
        // a block itself doesn't record an occurrence index) are left
        // alone rather than re-added — a habit can be partially placed
        // (one occurrence generated earlier, say) and still pick up its
        // remaining occurrences here. An occurrence past `idealTimesOfDay`
        // reuses the last time on the list.
        let eligibleHabits = habits
            .filter {
                $0.isApplicable(on: date, calendar: calendar)
                    && $0.status(on: date, asOf: date, calendar: calendar) == nil
            }
            .sorted { $0.sortOrder < $1.sortOrder }

        for habit in eligibleHabits {
            let existingStarts = Set(
                (habit.scheduledBlocks ?? [])
                    .filter { calendar.isDate($0.date, inSameDayAs: date) }
                    .map(\.startTime)
            )
            for occurrenceIndex in 0..<max(habit.timesPerDay, 1) {
                let idealMinutes = occurrenceIndex < habit.idealTimesOfDay.count
                    ? habit.idealTimesOfDay[occurrenceIndex]
                    : (habit.idealTimesOfDay.last ?? 0)
                let start = calendar.date(bySettingHour: idealMinutes / 60, minute: idealMinutes % 60, second: 0, of: date) ?? date
                guard !existingStarts.contains(start) else { continue }
                let end = start.addingTimeInterval(TimeInterval(habit.estimatedMinutes * 60))
                blocks.append(ScheduledBlock(date: date, startTime: start, endTime: end, task: nil, habit: habit, habitOccurrenceIndex: occurrenceIndex))
            }
        }

        return blocks.sorted { $0.startTime < $1.startTime }
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
        rule: SchedulingRule
    ) -> (placed: [(task: TaskItem, start: Date, end: Date, isEstimated: Bool)], remainingSlots: [TimeSlot]) {
        var slots = slots.sorted { $0.start < $1.start }
        var results: [(TaskItem, Date, Date, Bool)] = []
        var totalMinutesUsed = 0
        var taskCount = 0

        for task in candidates {
            if rule.fillStrategy == .maxTaskCount, taskCount >= rule.maxTaskCount { break }
            if rule.fillStrategy == .maxDuration, totalMinutesUsed >= rule.maxTotalMinutes { break }

            let isEstimated = task.estimatedMinutes <= 0
            let baseMinutes = isEstimated ? guessedMinutes(for: rule) : task.estimatedMinutes

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
            totalMinutesUsed += minutesNeeded
            taskCount += 1

            if isEstimated || minutesNeeded >= task.estimatedMinutes {
                task.isScheduled = true
            } else {
                task.estimatedMinutes -= minutesNeeded
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
            let take = min(remaining, slot.durationMinutes)
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

    /// A task explicitly marked eligible for `rule` always sorts before
    /// one that wasn't — that checkbox is still a real signal of intent,
    /// even though a not-yet-eligible task can still fill whatever's left
    /// of the rule's own budget once every eligible one already has a
    /// slot (see `generateProposedSchedule`'s per-rule loop).
    private func tieredOrdering(_ lhs: TaskItem, _ rhs: TaskItem, rule: SchedulingRule) -> Bool {
        let lhsEligible = lhs.isEligible(for: rule)
        let rhsEligible = rhs.isEligible(for: rule)
        if lhsEligible != rhsEligible {
            return lhsEligible && !rhsEligible
        }
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

    /// Priority first (high before low), then whichever task has been
    /// sitting on the shelf longest (oldest `createdAt` first), then due
    /// date as the final tiebreaker.
    private func taskOrdering(_ lhs: TaskItem, _ rhs: TaskItem) -> Bool {
        if lhs.priority != rhs.priority {
            return priorityRank(lhs.priority) > priorityRank(rhs.priority)
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return (lhs.dueDate ?? .distantFuture) < (rhs.dueDate ?? .distantFuture)
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
