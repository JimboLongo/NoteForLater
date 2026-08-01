import Foundation
import SwiftData
import Observation

/// Drives InboxView. The only job of the inbox is fast capture + fast sorting:
/// an item either becomes a TaskItem in one of the four holding pens, or gets
/// deleted outright.
@Observable
final class InboxViewModel {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func addItem(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        modelContext.insert(InboxItem(text: trimmed))
    }

    /// Routes an inbox entry onto a shelf, creating a TaskItem that carries
    /// over everything filled in on the inbox item, and removing the
    /// original brain-dump entry.
    func route(_ item: InboxItem, to shelf: Shelf) {
        let task = TaskItem(
            title: item.text,
            shelf: shelf,
            dueDate: item.dueDate,
            nextStep: item.nextStep,
            estimatedMinutes: item.estimatedMinutes,
            tags: item.tags,
            priority: item.priority,
            createdAt: item.createdAt
        )
        modelContext.insert(task)
        modelContext.delete(item)
    }

    func discard(_ item: InboxItem) {
        modelContext.delete(item)
    }

    /// Pulls in every unread inbox email as a new InboxItem, skipping any
    /// message already imported by a previous sync. Returns how many were
    /// newly added.
    @discardableResult
    func syncGmail(existingItems: [InboxItem], gmailService: GmailServiceProtocol) async throws -> Int {
        let alreadyImported = Set(existingItems.compactMap(\.sourceGmailMessageID))
        let messages = try await gmailService.fetchUnreadInboxMessages()

        var importedCount = 0
        for message in messages where !alreadyImported.contains(message.id) {
            let text = message.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? message.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
                : message.subject
            guard !text.isEmpty else { continue }
            modelContext.insert(InboxItem(text: text, sourceGmailMessageID: message.id))
            importedCount += 1
        }
        return importedCount
    }
}
