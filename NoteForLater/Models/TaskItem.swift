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
    var nextStep: String
    var estimatedMinutes: Int
    var tags: [String]
    var priorityRaw: String
    var isScheduled: Bool

    @Relationship(deleteRule: .nullify, inverse: \ScheduledBlock.task)
    var scheduledBlock: ScheduledBlock?

    init(
        title: String,
        notes: String = "",
        holdingPen: HoldingPen,
        dueDate: Date? = nil,
        nextStep: String = "",
        estimatedMinutes: Int = 30,
        tags: [String] = [],
        priority: Priority = .medium
    ) {
        self.id = UUID()
        self.title = title
        self.notes = notes
        self.holdingPenRaw = holdingPen.rawValue
        self.createdAt = .now
        self.dueDate = dueDate
        self.nextStep = nextStep
        self.estimatedMinutes = estimatedMinutes
        self.tags = tags
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

    static func durationLabel(for minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) hr" : "\(hours)h \(remainder)m"
    }

    var durationLabel: String { Self.durationLabel(for: estimatedMinutes) }
}
