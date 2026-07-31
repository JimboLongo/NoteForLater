import Foundation
import SwiftData

/// A raw, unsorted brain-dump entry. The whole point of the Inbox is that
/// capture is instant and frictionless — sorting happens later.
@Model
final class InboxItem {
    var id: UUID
    var text: String
    var createdAt: Date

    init(text: String, createdAt: Date = .now) {
        self.id = UUID()
        self.text = text
        self.createdAt = createdAt
    }
}
