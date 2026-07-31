import Foundation

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
