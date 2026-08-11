import Foundation
import SwiftData

enum TaskImportError: LocalizedError {
    case unsupportedFileType
    case emptyFile
    case missingTitleColumn
    case invalidArchive
    case unsupportedCompression
    case decompressionFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType: return "That file isn't a .csv or .xlsx."
        case .emptyFile: return "The file has no rows to import."
        case .missingTitleColumn: return "The file needs a \"Task\" column."
        case .invalidArchive: return "This .xlsx file couldn't be read."
        case .unsupportedCompression: return "This .xlsx file uses an unsupported compression method."
        case .decompressionFailed: return "This .xlsx file's contents couldn't be decompressed."
        }
    }
}

/// Column headers recognized during import, matched case-insensitively
/// against a small set of common aliases.
enum ImportedTaskField {
    case title, notes, shelf, dueDate, nextStep, duration, tags, priority, dateAdded

    private static let aliases: [ImportedTaskField: Set<String>] = [
        .title: ["title", "task", "name"],
        .notes: ["notes", "description", "note"],
        .shelf: ["shelf", "pen", "list", "category"],
        .dueDate: ["due date", "due", "duedate"],
        .nextStep: ["next step", "next action", "nextstep"],
        .duration: ["duration", "duration (min)", "duration minutes", "estimated minutes", "minutes"],
        .tags: ["tags", "keywords", "labels"],
        .priority: ["priority"],
        .dateAdded: ["date added", "created", "created at", "dateadded"]
    ]

    static func match(header: String) -> ImportedTaskField? {
        let normalized = header.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for (field, names) in aliases where names.contains(normalized) {
            return field
        }
        return nil
    }
}

struct TaskImportSummary {
    var importedCount = 0
    var errors: [String] = []
}

/// Bulk-creates tasks from a parsed .csv/.xlsx table. A row whose Shelf
/// column matches an existing shelf becomes a TaskItem there; otherwise it
/// lands on `defaultShelf`, or — if `defaultShelf` is nil (the user picked
/// "Inbox") — as an unsorted TaskItem (`shelf == nil`) instead, ready to
/// be sorted later. Either way every recognized column is preserved.
enum TaskImportService {
    static func importTasks(
        from url: URL,
        defaultShelf: Shelf?,
        allShelves: [Shelf],
        modelContext: ModelContext
    ) throws -> TaskImportSummary {
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

        let fieldByHeader: [String: ImportedTaskField] = Dictionary(
            uniqueKeysWithValues: table.headers.compactMap { header in
                ImportedTaskField.match(header: header).map { (header, $0) }
            }
        )
        guard fieldByHeader.values.contains(.title) else {
            throw TaskImportError.missingTitleColumn
        }

        var summary = TaskImportSummary()

        for (index, row) in table.rows.enumerated() {
            var values: [ImportedTaskField: String] = [:]
            for (header, rawValue) in row {
                guard let field = fieldByHeader[header] else { continue }
                let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { values[field] = trimmed }
            }

            guard let title = values[.title], !title.isEmpty else {
                summary.errors.append("Row \(index + 2): missing title, skipped.")
                continue
            }

            let matchedShelf = values[.shelf]
                .flatMap { name in allShelves.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }

            let tags = (values[.tags] ?? "")
                .split(whereSeparator: { $0 == "," || $0 == ";" })
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
            let dueDate = values[.dueDate].flatMap(TaskImportDateParser.parse)
            let priority = values[.priority].flatMap { Priority(rawValue: $0.lowercased()) } ?? .medium
            let createdAt = values[.dateAdded].flatMap(TaskImportDateParser.parse) ?? .now

            guard let shelf = matchedShelf ?? defaultShelf else {
                // No column match and the default is "Inbox": a plain
                // capture entry, same as typing it by hand — but every
                // column that was present still carries over.
                modelContext.insert(TaskItem(
                    title: title,
                    shelf: nil,
                    dueDate: dueDate,
                    nextStep: values[.nextStep] ?? "",
                    estimatedMinutes: values[.duration].flatMap { Int($0) } ?? 30,
                    tags: tags,
                    priority: priority,
                    createdAt: createdAt
                ))
                summary.importedCount += 1
                continue
            }

            let task = TaskItem(
                title: title,
                notes: values[.notes] ?? "",
                shelf: shelf,
                dueDate: dueDate,
                nextStep: values[.nextStep] ?? "",
                estimatedMinutes: values[.duration].flatMap { Int($0) } ?? 30,
                tags: tags,
                priority: priority,
                createdAt: createdAt
            )
            modelContext.insert(task)
            summary.importedCount += 1
        }

        return summary
    }
}

enum TaskImportDateParser {
    /// DateFormatter's pattern matching bleeds across separators — e.g. the
    /// pattern "yyyy-MM-dd" will happily "match" "8/5/26" as year 8 instead
    /// of rejecting it. Pairing each format with a regex that validates the
    /// literal shape of the string first prevents that cross-matching.
    private static let candidates: [(regex: String, format: String)] = [
        (#"^\d{4}-\d{1,2}-\d{1,2}$"#, "yyyy-MM-dd"),
        (#"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$"#, "yyyy-MM-dd'T'HH:mm:ss"),
        (#"^\d{1,2}/\d{1,2}/\d{4}$"#, "M/d/yyyy"),
        (#"^\d{1,2}/\d{1,2}/\d{2}$"#, "M/d/yy"),
        (#"^[A-Za-z]{3,9}\.? \d{1,2}, \d{4}$"#, "MMM d, yyyy"),
        (#"^[A-Za-z]{3,9}\.? \d{1,2}, \d{4}$"#, "MMMM d, yyyy")
    ]

    static func parse(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let isoDate = ISO8601DateFormatter().date(from: trimmed) {
            return isoDate
        }

        for candidate in candidates where trimmed.range(of: candidate.regex, options: .regularExpression) != nil {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = candidate.format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        // Excel serial date fallback (days since 1899-12-30) for numeric
        // cells that came through as plain numbers.
        if let serial = Double(trimmed), serial > 20000, serial < 80000 {
            let excelEpoch = Calendar(identifier: .gregorian).date(from: DateComponents(year: 1899, month: 12, day: 30))!
            return Calendar.current.date(byAdding: .day, value: Int(serial), to: excelEpoch)
        }

        return nil
    }
}
