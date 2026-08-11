import Foundation
import SwiftData

/// Deprecated — kept only so `NoteForLaterApp`'s one-time launch migration
/// can read rows that already exist in a production database. Nothing
/// else in the app references this anymore: "unsorted" is just
/// `TaskItem.shelf == nil` now (see `InboxViewModel`). Removing this type
/// from the schema entirely isn't safe — the on-device store predates any
/// SwiftData version tracking, so there's no supported staged-migration
/// path to drop an entity outright; the migration converts every row to a
/// TaskItem and deletes it instead, leaving this table permanently empty
/// after the first launch.
@Model
final class InboxItem {
    var id: UUID = UUID()
    var text: String = ""
    var createdAt: Date = Date.now
    var sourceGmailMessageID: String?
    var dueDate: Date?
    var dueDateDecided: Bool = false
    var nextStep: String = ""
    var estimatedMinutes: Int = 0
    var durationDecided: Bool = false
    var tags: [String] = []
    var priorityRaw: String = Priority.unset.rawValue
    var isDivisible: Bool = false
    var minimumSegmentMinutes: Int = 15
    var includedSchedulingRuleIDs: [UUID] = []

    init() {}

    var priority: Priority {
        get { Priority(rawValue: priorityRaw) ?? .unset }
        set { priorityRaw = newValue.rawValue }
    }
}
