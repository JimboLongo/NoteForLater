import Foundation
import SwiftData
import Observation

/// Drives the nightly "preview tomorrow's schedule" review screen and all
/// three interactions the user has with a proposed block: delete (swipe
/// left), auto-replace (swipe right), and manual replace (long-press).
@Observable
final class ScheduleReviewViewModel {
    private let modelContext: ModelContext
    private let calendarService: CalendarServiceProtocol
    private let schedulingService: AISchedulingServiceProtocol

    private(set) var blocks: [ScheduledBlock] = []
    var targetDate: Date
    var isGenerating = false
    var errorMessage: String?

    init(
        modelContext: ModelContext,
        calendarService: CalendarServiceProtocol,
        schedulingService: AISchedulingServiceProtocol,
        targetDate: Date = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
    ) {
        self.modelContext = modelContext
        self.calendarService = calendarService
        self.schedulingService = schedulingService
        self.targetDate = targetDate
    }

    // MARK: - Generation (the nightly job)

    /// Builds tomorrow's proposed schedule from open to-dos + free calendar
    /// slots. Called automatically each night (see NoteForLaterApp /
    /// TODO for BackgroundTasks wiring) and manually via a "Regenerate" button.
    func generateProposedSchedule(allTasks: [TaskItem]) async {
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }

        do {
            let freeSlots = try await calendarService.fetchFreeSlots(for: targetDate)
            let proposed = try await schedulingService.generateProposedSchedule(
                tasks: allTasks,
                freeSlots: freeSlots,
                date: targetDate
            )
            for block in proposed {
                block.task?.isScheduled = true
                modelContext.insert(block)
            }
            blocks = proposed.sorted { $0.startTime < $1.startTime }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadExistingBlocks(_ existing: [ScheduledBlock]) {
        blocks = existing
            .filter { Calendar.current.isDate($0.date, inSameDayAs: targetDate) }
            .sorted { $0.startTime < $1.startTime }
    }

    // MARK: - Approval

    func approveAll() {
        for block in blocks { block.approvalStatus = .approved }
        Task {
            for block in blocks {
                try? await calendarService.createEvent(for: block)
            }
        }
    }

    func approve(_ block: ScheduledBlock) {
        block.approvalStatus = .approved
        Task { try? await calendarService.createEvent(for: block) }
    }

    // MARK: - Swipe left: delete, leave the slot open

    /// Removes the block entirely. The underlying task goes back to being
    /// unscheduled so it can be picked up on a future night.
    func deleteBlock(_ block: ScheduledBlock) {
        block.task?.isScheduled = false
        modelContext.delete(block)
        blocks.removeAll { $0.id == block.id }
    }

    // MARK: - Swipe right: auto-replace with another queued to-do

    /// Swaps the block's task for the next-best unscheduled to-do (by
    /// priority, then due date), keeping the same time slot. The bumped task
    /// goes back into the unscheduled queue.
    func autoReplace(_ block: ScheduledBlock, candidatePool: [TaskItem]) {
        let outgoing = block.task
        let replacement = nextCandidate(from: candidatePool, excluding: outgoing)

        outgoing?.isScheduled = false
        block.task = replacement
        replacement?.isScheduled = true

        if let idx = blocks.firstIndex(where: { $0.id == block.id }) {
            blocks[idx] = block
        }
    }

    // MARK: - Long-press: manually pick the replacement

    /// Explicit version of autoReplace where the user chose the specific
    /// replacement task from a picker sheet.
    func manualReplace(_ block: ScheduledBlock, with newTask: TaskItem) {
        let outgoing = block.task
        outgoing?.isScheduled = false

        block.task = newTask
        newTask.isScheduled = true

        if let idx = blocks.firstIndex(where: { $0.id == block.id }) {
            blocks[idx] = block
        }
    }

    /// Tasks eligible to fill an empty/replaced slot: unscheduled, schedulable pen.
    func unscheduledCandidates(from allTasks: [TaskItem], excluding block: ScheduledBlock) -> [TaskItem] {
        allTasks.filter { $0.holdingPen.isSchedulable && !$0.isScheduled && $0.id != block.task?.id }
    }

    private func nextCandidate(from pool: [TaskItem], excluding outgoing: TaskItem?) -> TaskItem? {
        pool
            .filter { $0.holdingPen.isSchedulable && !$0.isScheduled && $0.id != outgoing?.id }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority {
                    return priorityRank(lhs.priority) > priorityRank(rhs.priority)
                }
                return (lhs.dueDate ?? .distantFuture) < (rhs.dueDate ?? .distantFuture)
            }
            .first
    }

    private func priorityRank(_ priority: Priority) -> Int {
        switch priority {
        case .high: return 2
        case .medium: return 1
        case .low: return 0
        }
    }
}
