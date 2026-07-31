import Foundation

/// Turns "here's my open to-do list + here are my open calendar slots" into a
/// proposed set of ScheduledBlocks for a given day. This is the piece the
/// nightly job calls to build tomorrow's preview.
///
/// TODO(Claude Code): Replace the greedy mock packer with a real call to the
/// Claude API (Messages API). Suggested approach:
///   1. Serialize `tasks` (title, estimatedMinutes, priority, dueDate) and
///      `freeSlots` (start/end) to JSON.
///   2. Send a prompt asking the model to assign tasks to slots, respecting
///      priority/due dates and leaving buffer time, returning structured JSON
///      (tool use / structured output is a good fit here).
///   3. Parse the response back into ScheduledBlock instances.
///   4. Keep this mock implementation around as a fallback for offline mode
///      or if the API call fails.
protocol AISchedulingServiceProtocol: AnyObject {
    func generateProposedSchedule(
        tasks: [TaskItem],
        freeSlots: [TimeSlot],
        date: Date
    ) async throws -> [ScheduledBlock]
}

final class MockAISchedulingService: AISchedulingServiceProtocol {

    /// Simple greedy packer: highest priority / earliest due date first,
    /// dropped into the earliest slot with enough room.
    func generateProposedSchedule(
        tasks: [TaskItem],
        freeSlots: [TimeSlot],
        date: Date
    ) async throws -> [ScheduledBlock] {
        let schedulable = tasks
            .filter { ($0.shelf?.isEligibleForScheduling ?? false) && !$0.isScheduled }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority {
                    return priorityRank(lhs.priority) > priorityRank(rhs.priority)
                }
                return (lhs.dueDate ?? .distantFuture) < (rhs.dueDate ?? .distantFuture)
            }

        var remainingSlots = freeSlots.sorted { $0.start < $1.start }
        var blocks: [ScheduledBlock] = []

        for task in schedulable {
            guard let index = remainingSlots.firstIndex(where: { $0.durationMinutes >= task.estimatedMinutes }) else {
                continue // no room left today; stays in the queue for another night
            }
            let slot = remainingSlots[index]
            let blockEnd = slot.start.addingTimeInterval(TimeInterval(task.estimatedMinutes * 60))
            blocks.append(ScheduledBlock(date: date, startTime: slot.start, endTime: blockEnd, task: task))

            let leftover = TimeSlot(start: blockEnd, end: slot.end)
            remainingSlots.remove(at: index)
            if leftover.durationMinutes > 0 {
                remainingSlots.append(leftover)
                remainingSlots.sort { $0.start < $1.start }
            }
        }

        return blocks
    }

    private func priorityRank(_ priority: Priority) -> Int {
        switch priority {
        case .high: return 2
        case .medium: return 1
        case .low: return 0
        }
    }
}
