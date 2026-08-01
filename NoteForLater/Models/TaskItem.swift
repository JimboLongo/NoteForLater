import Foundation
import SwiftData

/// A sorted item living on one of the user's shelves. Inbox items become
/// TaskItems once the user routes them to a shelf. Only tasks on a shelf
/// with `isEligibleForScheduling` are candidates for auto-scheduling.
@Model
final class TaskItem {
    var id: UUID
    var title: String
    var notes: String
    var createdAt: Date
    var dueDate: Date?
    var nextStep: String = ""
    var estimatedMinutes: Int = 30
    var tags: [String] = []
    var priorityRaw: String = Priority.medium.rawValue
    var isScheduled: Bool = false

    var shelf: Shelf?

    @Relationship(deleteRule: .nullify, inverse: \ScheduledBlock.task)
    var scheduledBlock: ScheduledBlock?

    init(
        title: String,
        notes: String = "",
        shelf: Shelf,
        dueDate: Date? = nil,
        nextStep: String = "",
        estimatedMinutes: Int = 30,
        tags: [String] = [],
        priority: Priority = .medium,
        createdAt: Date = .now
    ) {
        self.id = UUID()
        self.title = title
        self.notes = notes
        self.shelf = shelf
        self.createdAt = createdAt
        self.dueDate = dueDate
        self.nextStep = nextStep
        self.estimatedMinutes = estimatedMinutes
        self.tags = tags
        self.priorityRaw = priority.rawValue
        self.isScheduled = false
    }

    var priority: Priority {
        get { Priority(rawValue: priorityRaw) ?? .medium }
        set { priorityRaw = newValue.rawValue }
    }

    static func durationLabel(for minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) hr" : "\(hours)h \(remainder)m"
    }

    var durationLabel: String { Self.durationLabel(for: estimatedMinutes) }
}
