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

/// The step size for a recurring task's repeat interval (see
/// `TaskItem.isRecurring`) — "every 2 `weeks`", say.
enum RecurrenceUnit: String, Codable, CaseIterable, Identifiable {
    case days, weeks, months
    var id: String { rawValue }

    func label(for count: Int) -> String {
        let singular: String
        switch self {
        case .days: singular = "day"
        case .weeks: singular = "week"
        case .months: singular = "month"
        }
        return count == 1 ? singular : "\(singular)s"
    }
}

/// How a single habit occurrence lands on the day — `specific` places it
/// on the calendar at its own `idealTimesOfDay` slot, the way every
/// occurrence used to work; the other three surface it instead as an
/// untimed list item (see `DayTimelineGridView`) grouped into the day's
/// Morning (above the calendar), Midday (splitting the calendar in two at
/// noon), or Evening (below the calendar) section.
enum HabitOccurrenceTimeMode: String, Codable, CaseIterable, Identifiable {
    case am, midday, pm, specific
    var id: String { rawValue }

    var label: String {
        switch self {
        case .am: return "AM"
        case .midday: return "Midday"
        case .pm: return "PM"
        case .specific: return "Specific Time"
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
