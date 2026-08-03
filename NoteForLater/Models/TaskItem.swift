import Foundation
import SwiftData

/// A sorted item living on one of the user's shelves. Inbox items become
/// TaskItems once the user routes them to a shelf. Only tasks on a shelf
/// with an enabled SchedulingRule are candidates for auto-scheduling.
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

    /// Whether the AI Scheduler may split this task across multiple blocks
    /// (different times/slots the same day) if it doesn't fit in one
    /// contiguous window. Each piece is at least `minimumSegmentMinutes`.
    var isDivisible: Bool = false
    var minimumSegmentMinutes: Int = 15

    /// SchedulingRule IDs (from this task's shelf) that this task should
    /// NOT be pulled by — everything else is eligible. Empty (the default)
    /// means eligible for every rule on the shelf, matching "all checked"
    /// in the UI; a rule added to the shelf later is automatically eligible
    /// too, since nothing has excluded it yet.
    var excludedSchedulingRuleIDs: [UUID] = []

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
        createdAt: Date = .now,
        isDivisible: Bool = false,
        minimumSegmentMinutes: Int = 15
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
        self.isDivisible = isDivisible
        self.minimumSegmentMinutes = minimumSegmentMinutes
    }

    var priority: Priority {
        get { Priority(rawValue: priorityRaw) ?? .medium }
        set { priorityRaw = newValue.rawValue }
    }

    func isEligible(for rule: SchedulingRule) -> Bool {
        !excludedSchedulingRuleIDs.contains(rule.id)
    }

    func setEligible(_ eligible: Bool, for rule: SchedulingRule) {
        if eligible {
            excludedSchedulingRuleIDs.removeAll { $0 == rule.id }
        } else if !excludedSchedulingRuleIDs.contains(rule.id) {
            excludedSchedulingRuleIDs.append(rule.id)
        }
    }

    static func durationLabel(for minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) hr" : "\(hours)h \(remainder)m"
    }

    var durationLabel: String { Self.durationLabel(for: estimatedMinutes) }
}
