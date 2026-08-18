import Foundation
import SwiftData
import Observation

/// Drives InboxView. The only job of the inbox is fast capture + fast sorting:
/// an item either becomes a shelved TaskItem, or gets deleted outright.
/// "Unsorted" is just `TaskItem.shelf == nil` — there's no separate model.
@Observable
final class InboxViewModel {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    @discardableResult
    func addItem(_ text: String) -> TaskItem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let item = TaskItem(title: trimmed, shelf: nil)
        modelContext.insert(item)
        return item
    }

    /// Sorts an unsorted task onto `shelf`. Duration: if the task already
    /// had one set explicitly, that wins; otherwise it falls back to the
    /// shelf's own default (0, "no duration," when the shelf doesn't track
    /// duration at all — see `Shelf.resolvedDuration`). Eligible schedules
    /// defaults to every one of the shelf's own enabled rules — opted in
    /// automatically rather than making the user flip each toggle by hand
    /// right after picking the shelf; still freely editable from the task
    /// card afterward.
    func route(_ task: TaskItem, to shelf: Shelf) {
        task.shelf = shelf
        task.estimatedMinutes = shelf.resolvedDuration(candidateMinutes: task.estimatedMinutes)
        task.remainingMinutes = task.estimatedMinutes
        if !shelf.effectiveTracksDuration {
            task.isDivisible = false
            task.minimumSegmentMinutes = 0
        }
        if !shelf.effectiveTracksNextStep {
            task.nextStep = ""
        }
        if !shelf.effectiveTracksPriority {
            task.priority = .unset
        }
        if !shelf.effectiveTracksDueDates {
            task.dueDate = nil
        }
        task.includedSchedulingRuleIDs = (shelf.schedulingRules ?? []).filter(\.isEnabled).map(\.id)
    }

    func discard(_ task: TaskItem) {
        modelContext.delete(task)
    }

    /// Pulls in every unread inbox email as a new unsorted TaskItem,
    /// skipping any message already imported by a previous sync. Returns
    /// how many were newly added.
    @discardableResult
    func syncGmail(existingTasks: [TaskItem], gmailService: GmailServiceProtocol) async throws -> Int {
        let alreadyImported = Set(existingTasks.compactMap(\.sourceGmailMessageID))
        let messages = try await gmailService.fetchUnreadInboxMessages()

        var importedCount = 0
        for message in messages where !alreadyImported.contains(message.id) {
            let text = message.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? message.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
                : message.subject
            guard !text.isEmpty else { continue }
            modelContext.insert(TaskItem(title: text, shelf: nil, sourceGmailMessageID: message.id))
            importedCount += 1
        }
        return importedCount
    }
}
