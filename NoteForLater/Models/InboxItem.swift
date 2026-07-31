import Foundation
import SwiftData

/// A raw, unsorted brain-dump entry. The whole point of the Inbox is that
/// capture is instant and frictionless — sorting happens later.
@Model
final class InboxItem {
    var id: UUID
    var text: String
    var createdAt: Date

    /// Set when this item came from a Gmail sync rather than manual typing,
    /// so re-syncing doesn't create duplicates for mail already imported.
    var sourceGmailMessageID: String?

    init(text: String, createdAt: Date = .now, sourceGmailMessageID: String? = nil) {
        self.id = UUID()
        self.text = text
        self.createdAt = createdAt
        self.sourceGmailMessageID = sourceGmailMessageID
    }
}
