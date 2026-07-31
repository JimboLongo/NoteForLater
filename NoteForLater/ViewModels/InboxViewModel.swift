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

    /// Routes an inbox entry onto a shelf, creating a TaskItem and
    /// removing the original brain-dump entry.
    func route(_ item: InboxItem, to shelf: Shelf) {
        let task = TaskItem(title: item.text, shelf: shelf)
        modelContext.insert(task)
        modelContext.delete(item)
    }

    func discard(_ item: InboxItem) {
        modelContext.delete(item)
    }
}
