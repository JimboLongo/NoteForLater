import Foundation
import SwiftData
import Observation

/// Drives the schedule review screen for a single day (default: tomorrow,
/// but navigable to any day) and every interaction the user has with a
/// block: delete (swipe left), auto-replace (swipe right), long-press to
/// manually replace, and — on today specifically — mark complete or push
/// to another day.
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
        targetDate: Date = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
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
    func generateProposedSchedule(shelves: [Shelf], eligibleHoursWindows: [EligibleHoursWindow]) async {
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }

        do {
            let freeSlots = try await calendarService.fetchFreeSlots(for: targetDate)
            let proposed = try await schedulingService.generateProposedSchedule(
                shelves: shelves,
                freeSlots: freeSlots,
                eligibleHoursWindows: eligibleHoursWindows,
                date: targetDate
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

    // MARK: - Swipe left: delete, leave the slot open

    /// Removes the block entirely. The underlying task goes back to being
    /// unscheduled so it can be picked up on a future night. If it had
    /// already been pushed to the calendar, that event gets removed too.
    func deleteBlock(_ block: ScheduledBlock) {
        block.task?.isScheduled = false
        if let eventID = block.googleEventID {
            Task { try? await calendarService.deleteEvent(eventID: eventID) }
        }
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
        block.task = replacement
        replacement?.isScheduled = true
        needsReapproval(block)

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
        needsReapproval(block)

        if let idx = blocks.firstIndex(where: { $0.id == block.id }) {
            blocks[idx] = block
        }
    }

    private func needsReapproval(_ block: ScheduledBlock) {
        if block.approvalStatus == .approved {
            block.approvalStatus = .proposed
        }
    }

    // MARK: - Today: complete / push to another day

    func markComplete(_ block: ScheduledBlock) {
        block.isCompleted = true
    }

    /// "I didn't get to this" — same as deleting it: unschedules the task
    /// (and removes the pushed calendar event, if any) so it's picked up
    /// again by a future night's generation.
    func pushToAnotherDay(_ block: ScheduledBlock) {
        deleteBlock(block)
    }

    /// Tasks eligible to fill an empty/replaced slot: unscheduled, on a schedulable shelf.
    func unscheduledCandidates(from allTasks: [TaskItem], excluding block: ScheduledBlock) -> [TaskItem] {
        allTasks.filter { ($0.shelf?.hasEnabledSchedulingRules ?? false) && !$0.isScheduled && $0.id != block.task?.id }
    }

    private func nextCandidate(from pool: [TaskItem], excluding outgoing: TaskItem?) -> TaskItem? {
        pool
            .filter { ($0.shelf?.hasEnabledSchedulingRules ?? false) && !$0.isScheduled && $0.id != outgoing?.id }
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
