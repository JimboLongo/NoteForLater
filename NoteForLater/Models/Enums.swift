import Foundation

/// `unset` is the default for a brand-new task or Inbox item — priority
/// starts unselected, same as duration and due date, until the user
/// explicitly picks one.
enum Priority: String, Codable, CaseIterable, Identifiable {
    case unset, low, medium, high
    var id: String { rawValue }

    var label: String {
        switch self {
        case .unset: return "None"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
}

/// Lifecycle of a proposed schedule block shown during the nightly review.
enum ApprovalStatus: String, Codable {
    case proposed
    case approved
    case rejected
}

/// A free window of time on the user's calendar, as reported by the Calendar service.
struct TimeSlot: Identifiable, Hashable {
    let id = UUID()
    let start: Date
    let end: Date

    var durationMinutes: Int {
        Int(end.timeIntervalSince(start) / 60)
    }
}
