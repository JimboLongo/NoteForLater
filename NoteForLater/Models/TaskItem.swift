import Foundation
import SwiftData

/// A sorted item living in one of the four holding pens. Inbox items become
/// TaskItems once the user routes them to a pen. Only `.todo` items are
/// candidates for auto-scheduling.
@Model
final class TaskItem {
    var id: UUID
    var title: String
    var notes: String
    var holdingPenRaw: String
    var createdAt: Date
    var dueDate: Date?
    var estimatedMinutes: Int
    var priorityRaw: String
    var isScheduled: Bool

    @Relationship(deleteRule: .nullify, inverse: \ScheduledBlock.task)
    var scheduledBlock: ScheduledBlock?

    init(
        title: String,
        notes: String = "",
        holdingPen: HoldingPen,
        dueDate: Date? = nil,
        estimatedMinutes: Int = 30,
        priority: Priority = .medium
    ) {
        self.id = UUID()
        self.title = title
        self.notes = notes
        self.holdingPenRaw = holdingPen.rawValue
        self.createdAt = .now
        self.dueDate = dueDate
        self.estimatedMinutes = estimatedMinutes
        self.priorityRaw = priority.rawValue
        self.isScheduled = false
    }

    var holdingPen: HoldingPen {
        get { HoldingPen(rawValue: holdingPenRaw) ?? .reference }
        set { holdingPenRaw = newValue.rawValue }
    }

    var priority: Priority {
        get { Priority(rawValue: priorityRaw) ?? .medium }
        set { priorityRaw = newValue.rawValue }
    }
}
