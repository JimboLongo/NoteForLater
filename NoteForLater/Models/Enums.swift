import Foundation

/// The designated "holding pens" that inbox items get sorted into.
enum HoldingPen: String, Codable, CaseIterable, Identifiable {
    case todo = "To-Do List"
    case shopping = "Stuff to Buy"
    case futureProject = "Future Project"
    case reference = "Reference"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .todo: return "checklist"
        case .shopping: return "cart"
        case .futureProject: return "lightbulb"
        case .reference: return "archivebox"
        }
    }

    /// Only items in these pens are eligible to be auto-scheduled onto the calendar.
    var isSchedulable: Bool {
        self == .todo
    }
}

enum Priority: String, Codable, CaseIterable, Identifiable {
    case low, medium, high
    var id: String { rawValue }
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
