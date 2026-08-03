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
final class MockAISchedulingService: AISchedulingServiceProtocol {
    func generateProposedSchedule(
        shelves: [Shelf],
        freeSlots: [TimeSlot],
        eligibleHoursWindows: [EligibleHoursWindow],
        date: Date
    ) async throws -> [ScheduledBlock] {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date)

        let applicableRules: [(rule: SchedulingRule, shelf: Shelf)] = shelves
            .sorted { $0.sortOrder < $1.sortOrder }
            .flatMap { shelf in (shelf.schedulingRules ?? []).map { (rule: $0, shelf: shelf) } }
            .filter { $0.rule.isEnabled && $0.rule.effectiveDaysOfWeek.contains(weekday) }
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
                .filter { !$0.isScheduled && !scheduledTaskIDs.contains($0.id) && $0.isEligible(for: rule) }
                .sorted(by: taskOrdering)

            let (placed, leftoverInWindow) = pack(candidates: candidates, into: availableInWindow, rule: rule)
            for (task, start, end) in placed {
                blocks.append(ScheduledBlock(date: date, startTime: start, endTime: end, task: task))
                scheduledTaskIDs.insert(task.id)
            }

            let outsideWindow = subtract(remainingFree, window: window)
            remainingFree = (outsideWindow + leftoverInWindow).sorted { $0.start < $1.start }
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
    private func pack(
        candidates: [TaskItem],
        into slots: [TimeSlot],
        rule: SchedulingRule
    ) -> (placed: [(task: TaskItem, start: Date, end: Date)], remainingSlots: [TimeSlot]) {
        var slots = slots.sorted { $0.start < $1.start }
        var results: [(TaskItem, Date, Date)] = []
        var totalMinutesUsed = 0
        var taskCount = 0

        for task in candidates {
            if rule.fillStrategy == .maxTaskCount, taskCount >= rule.maxTaskCount { break }
            if rule.fillStrategy == .maxDuration, totalMinutesUsed >= rule.maxTotalMinutes { break }

            let minutesNeeded: Int
            switch rule.fillStrategy {
            case .fillToFit:
                minutesNeeded = task.estimatedMinutes
            case .maxDuration:
                // budget > 0 is guaranteed here: the loop-top check above
                // already breaks once totalMinutesUsed reaches the cap.
                let budget = rule.maxTotalMinutes - totalMinutesUsed
                if task.estimatedMinutes <= budget {
                    minutesNeeded = task.estimatedMinutes
                } else if task.isDivisible {
                    minutesNeeded = budget
                } else {
                    continue // doesn't fit the remaining budget and can't be split
                }
            case .maxTaskCount:
                if task.estimatedMinutes <= rule.maxMinutesPerTask {
                    minutesNeeded = task.estimatedMinutes
                } else if task.isDivisible {
                    minutesNeeded = rule.maxMinutesPerTask
                } else {
                    continue // too long for a single capped session and can't be split
                }
            }
            guard minutesNeeded > 0 else { continue }

            guard let placement = place(
                minutesNeeded: minutesNeeded,
                minimumSegment: task.minimumSegmentMinutes,
                isDivisible: task.isDivisible,
                in: slots
            ) else { continue }

            for (start, end) in placement {
                results.append((task, start, end))
            }
            slots = updatedSlots(after: placement, in: slots)
            totalMinutesUsed += minutesNeeded
            taskCount += 1

            if minutesNeeded >= task.estimatedMinutes {
                task.isScheduled = true
            } else {
                task.estimatedMinutes -= minutesNeeded
            }
        }

        return (results, slots)
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

    private func taskOrdering(_ lhs: TaskItem, _ rhs: TaskItem) -> Bool {
        if lhs.priority != rhs.priority {
            return priorityRank(lhs.priority) > priorityRank(rhs.priority)
        }
        return (lhs.dueDate ?? .distantFuture) < (rhs.dueDate ?? .distantFuture)
    }

    private func priorityRank(_ priority: Priority) -> Int {
        switch priority {
        case .high: return 2
        case .medium: return 1
        case .low: return 0
        }
    }
}
