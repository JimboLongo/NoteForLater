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

/// Which recurrence evaluator a recurring `TaskItem` uses — see
/// `TaskItem.hasRecurringOccurrence`'s own doc comment for how the two
/// branch from one shared entry point. `.specificDate` is the original
/// interval+unit+anchor behavior (unchanged); `.relativeDate` is pattern
/// based ("the last day of the month," "the first Saturday"). Defaults
/// to `.specificDate` so every recurring task that existed before this
/// field did keeps behaving exactly as it always has.
enum RecurrenceMode: String, Codable, CaseIterable, Identifiable {
    case specificDate, relativeDate
    var id: String { rawValue }

    var label: String {
        switch self {
        case .specificDate: return "Specific Date"
        case .relativeDate: return "Relative Date"
        }
    }
}

/// The two shapes a Relative Date pattern can take — see
/// `TaskItem.relativeRecurrenceOrdinal`/`.relativeRecurrenceWeekday` for
/// the parameters each one reads.
enum RelativeRecurrenceScope: String, Codable, CaseIterable, Identifiable {
    /// "The 1st" / "the last day" of the month — only `.first`/`.last`
    /// are ever offered as `RelativeRecurrenceOrdinal` values for this
    /// scope (see `TaskItem.hasRelativeDateOccurrence`'s doc comment for
    /// why any other day-of-month is deliberately left to Specific Date
    /// instead). `TaskReviewCard`'s "Day" row folds that third option in
    /// as "Same day" — a `DayOfMonthPosition` case that isn't a
    /// `RelativeRecurrenceOrdinal` at all, since choosing it switches the
    /// task to `.specificDate` rather than picking an ordinal here.
    case dayOfMonth
    /// "The first/second/third/fourth/last <weekday>" of the month.
    case weekdayOfMonth
    var id: String { rawValue }

    /// This is its only caller (`TaskReviewCard`'s "On the" row).
    /// Shortened to "Day"/"Weekday" once, then widened back out to these
    /// exact strings — the row's own fixed-width column (see
    /// `PickedMenuPicker`) removes the wrapping risk that motivated the
    /// original shortening, so there's no longer a reason not to spell
    /// these out.
    var label: String {
        switch self {
        case .dayOfMonth: return "Day of month"
        case .weekdayOfMonth: return "Day of Week"
        }
    }
}

/// The position within the month a Relative Date pattern names.
/// Deliberately stops at `.fourth`/`.last` — no `.fifth` — see
/// `TaskItem.hasRelativeDateOccurrence`'s doc comment for why that's load-
/// bearing, not just a smaller feature set.
enum RelativeRecurrenceOrdinal: Int, Codable, CaseIterable, Identifiable {
    case first = 1, second = 2, third = 3, fourth = 4, last = -1
    var id: Int { rawValue }

    var label: String {
        switch self {
        case .first: return "First"
        case .second: return "Second"
        case .third: return "Third"
        case .fourth: return "Fourth"
        case .last: return "Last"
        }
    }

    /// "1st"/"2nd"/"3rd"/"4th"/"last" — for `TaskItem.recurrenceShortSummary`
    /// only; the Position picker's own menu still shows `.label`'s full
    /// words.
    var shortOrdinalLabel: String {
        switch self {
        case .first: return "1st"
        case .second: return "2nd"
        case .third: return "3rd"
        case .fourth: return "4th"
        case .last: return "last"
        }
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

    /// The modes a recurring **task** may be set to. Habits keep
    /// `allCases`; this is deliberately narrower.
    ///
    /// `.specific` is the only mode that puts an occurrence on the calendar
    /// as a real `ScheduledBlock`. For habits that's the point. For
    /// recurring tasks it meant a second, parallel completion store (the
    /// block's own `isCompleted` alongside `RecurringTaskLog`) and a whole
    /// placeholder-block pipeline for pushing an occurrence forward —
    /// machinery that, checked against the live store, had never produced a
    /// single row. A recurring task is now always an untimed list item.
    ///
    /// This is the whole of the rule. Because it excludes `.specific`,
    /// `TaskItem.recurringAndUntimed` is true for every recurring task,
    /// which is what hides Duration and Divisible on the card — see
    /// `CardRow.duration`, which anticipated this and needs no new clause.
    static var taskSelectableCases: [HabitOccurrenceTimeMode] {
        allCases.filter { $0 != .specific }
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
