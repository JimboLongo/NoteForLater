import Foundation

/// Common intermediate shape produced by both CSVParser and XLSXParser so
/// TaskImportService can treat the two file types identically.
struct ParsedTable {
    let headers: [String]
    let rows: [[String: String]]
}

enum CSVParser {
    static func parseTable(contentsOf url: URL) throws -> ParsedTable {
        let text = try String(contentsOf: url, encoding: .utf8)
        return buildTable(from: parse(text))
    }

    static func buildTable(from rawRows: [[String]]) -> ParsedTable {
        guard let headerRow = rawRows.first else { return ParsedTable(headers: [], rows: []) }
        let headers = headerRow.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        var rows: [[String: String]] = []
        for rawRow in rawRows.dropFirst() {
            guard !rawRow.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { continue }
            var dict: [String: String] = [:]
            for (index, header) in headers.enumerated() where index < rawRow.count {
                dict[header] = rawRow[index]
            }
            rows.append(dict)
        }
        return ParsedTable(headers: headers, rows: rows)
    }

    /// RFC4180-ish parser: handles quoted fields, embedded commas/newlines,
    /// and escaped quotes ("" inside a quoted field).
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var insideQuotes = false
        let chars = Array(text)
        var i = 0

        func endField() {
            row.append(field)
            field = ""
        }
        func endRow() {
            endField()
            rows.append(row)
            row = []
        }

        while i < chars.count {
            let c = chars[i]
            if insideQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        insideQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"":
                    insideQuotes = true
                case ",":
                    endField()
                case "\n":
                    endRow()
                case "\r":
                    if !(i + 1 < chars.count && chars[i + 1] == "\n") {
                        endRow()
                    }
                default:
                    field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty {
            endRow()
        }
        return rows.filter { !($0.count == 1 && $0[0].trimmingCharacters(in: .whitespaces).isEmpty) }
    }
}
