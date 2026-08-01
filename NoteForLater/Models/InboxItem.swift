import Foundation
import SwiftData

/// A raw, unsorted brain-dump entry. The whole point of the Inbox is that
/// capture is instant and frictionless — sorting happens later. It can
/// still carry the same attributes a TaskItem would (due date, next step,
/// duration, tags, priority), filled in from InboxItemDetailView, which
/// carry over onto the TaskItem created when it's routed to a shelf.
@Model
final class InboxItem {
    var id: UUID
    var text: String
    var createdAt: Date

    /// Set when this item came from a Gmail sync rather than manual typing,
    /// so re-syncing doesn't create duplicates for mail already imported.
    var sourceGmailMessageID: String?

    var dueDate: Date?
    var nextStep: String
    var estimatedMinutes: Int
    var tags: [String]
    var priorityRaw: String

    init(
        text: String,
        createdAt: Date = .now,
        sourceGmailMessageID: String? = nil,
        dueDate: Date? = nil,
        nextStep: String = "",
        estimatedMinutes: Int = 30,
        tags: [String] = [],
        priority: Priority = .medium
    ) {
        self.id = UUID()
        self.text = text
        self.createdAt = createdAt
        self.sourceGmailMessageID = sourceGmailMessageID
        self.dueDate = dueDate
        self.nextStep = nextStep
        self.estimatedMinutes = estimatedMinutes
        self.tags = tags
        self.priorityRaw = priority.rawValue
    }

    var priority: Priority {
        get { Priority(rawValue: priorityRaw) ?? .medium }
        set { priorityRaw = newValue.rawValue }
    }

    var durationLabel: String { TaskItem.durationLabel(for: estimatedMinutes) }
}
