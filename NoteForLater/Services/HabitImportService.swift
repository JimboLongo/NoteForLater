import Foundation
import SwiftData

enum HabitImportError: LocalizedError {
    case missingNameColumn

    var errorDescription: String? {
        switch self {
        case .missingNameColumn: return "The file needs a \"Name\" column."
        }
    }
}

/// Column headers recognized during import, matched case-insensitively
/// against a small set of common aliases.
enum ImportedHabitField {
    case name, startDate, timesPerDay, days, reminderTimes

    private static let aliases: [ImportedHabitField: Set<String>] = [
        .name: ["name", "habit", "title"],
        .startDate: ["start date", "startdate", "start"],
        .timesPerDay: ["times per day", "timesperday", "frequency", "times", "x per day"],
        .days: ["days", "days of week", "daysofweek", "schedule"],
        .reminderTimes: ["reminder times", "reminders", "reminder", "times of day", "reminder time"]
    ]

    static func match(header: String) -> ImportedHabitField? {
        let normalized = header.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for (field, names) in aliases where names.contains(normalized) {
            return field
        }
        return nil
    }
}

struct HabitImportSummary {
    var importedCount = 0
    var errors: [String] = []
}

/// Bulk-creates habits from a parsed .csv/.xlsx table, reusing the same
/// CSV/XLSX readers and date parser as TaskImportService. Only "Name" is
/// required — everything else falls back to the same defaults HabitEditView
/// starts a new habit with.
enum HabitImportService {
    static func importHabits(
        from url: URL,
        modelContext: ModelContext,
        startingSortOrder: Int
    ) throws -> HabitImportSummary {
        let table: ParsedTable
        switch url.pathExtension.lowercased() {
        case "csv":
            table = try CSVParser.parseTable(contentsOf: url)
        case "xlsx":
            table = try XLSXParser.parseTable(at: url)
        default:
            throw TaskImportError.unsupportedFileType
        }

        guard !table.rows.isEmpty else { throw TaskImportError.emptyFile }

        let fieldByHeader: [String: ImportedHabitField] = Dictionary(
            uniqueKeysWithValues: table.headers.compactMap { header in
                ImportedHabitField.match(header: header).map { (header, $0) }
            }
        )
        guard fieldByHeader.values.contains(.name) else {
            throw HabitImportError.missingNameColumn
        }

        var summary = HabitImportSummary()
        var nextOrder = startingSortOrder

        for (index, row) in table.rows.enumerated() {
            var values: [ImportedHabitField: String] = [:]
            for (header, rawValue) in row {
                guard let field = fieldByHeader[header] else { continue }
                let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { values[field] = trimmed }
            }

            guard let name = values[.name], !name.isEmpty else {
                summary.errors.append("Row \(index + 2): missing name, skipped.")
                continue
            }

            let startDate = values[.startDate].flatMap(TaskImportDateParser.parse) ?? Calendar.current.startOfDay(for: .now)
            let timesPerDay = max(values[.timesPerDay].flatMap { Int($0) } ?? 1, 1)
            let daysOfWeek = values[.days].flatMap(HabitImportDaysParser.parse) ?? [1, 2, 3, 4, 5, 6, 7]
            let reminderTimes = resolvedReminderTimes(from: values[.reminderTimes], timesPerDay: timesPerDay)

            let habit = Habit(
                name: name,
                startDate: startDate,
                timesPerDay: timesPerDay,
                daysOfWeek: daysOfWeek,
                reminderTimesOfDay: reminderTimes,
                sortOrder: nextOrder
            )
            modelContext.insert(habit)
            nextOrder += 1
            summary.importedCount += 1
        }

        return summary
    }

    /// Parses the reminder-times cell (comma/semicolon separated clock
    /// times), then pads or truncates to match `timesPerDay` the same way
    /// HabitEditView does when the count is adjusted by hand.
    private static func resolvedReminderTimes(from raw: String?, timesPerDay: Int) -> [Int] {
        var times = (raw ?? "")
            .split(whereSeparator: { $0 == "," || $0 == ";" })
            .compactMap { HabitImportTimeParser.parse(String($0)) }

        if times.isEmpty {
            times = [540]
        }
        if times.count < timesPerDay {
            let lastMinute = times.last ?? 8 * 60
            let toAdd = timesPerDay - times.count
            for step in 1...toAdd {
                times.append(min(lastMinute + step * 120, 23 * 60 + 59))
            }
        } else if times.count > timesPerDay {
            times = Array(times.prefix(timesPerDay))
        }
        return times
    }
}

/// Parses a single clock-time cell ("8:00 AM", "13:00", "6:30pm", ...) into
/// minutes since midnight.
enum HabitImportTimeParser {
    private static let formats = ["h:mm a", "h:mma", "HH:mm", "H:mm", "h a", "ha"]

    static func parse(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                return (components.hour ?? 0) * 60 + (components.minute ?? 0)
            }
        }
        return nil
    }
}

/// Parses a days-of-week cell: a comma/semicolon-separated list of day
/// names/abbreviations, or one of the shorthand keywords below.
enum HabitImportDaysParser {
    private static let nameToWeekday: [String: Int] = [
        "sun": 1, "sunday": 1,
        "mon": 2, "monday": 2,
        "tue": 3, "tues": 3, "tuesday": 3,
        "wed": 4, "weds": 4, "wednesday": 4,
        "thu": 5, "thur": 5, "thurs": 5, "thursday": 5,
        "fri": 6, "friday": 6,
        "sat": 7, "saturday": 7
    ]

    static func parse(_ raw: String) -> [Int]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        switch trimmed {
        case "daily", "every day", "everyday", "all", "every": return [1, 2, 3, 4, 5, 6, 7]
        case "weekdays", "weekday": return [2, 3, 4, 5, 6]
        case "weekends", "weekend": return [1, 7]
        default: break
        }

        let days = trimmed
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "/" })
            .compactMap { nameToWeekday[$0.trimmingCharacters(in: .whitespaces)] }
        return days.isEmpty ? nil : Array(Set(days)).sorted()
    }
}
