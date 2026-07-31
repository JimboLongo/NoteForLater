import Foundation
import Compression

/// Reads the first worksheet of a .xlsx file into the same ParsedTable shape
/// CSVParser produces. .xlsx is a ZIP archive of OOXML documents, so this
/// implements just enough of the ZIP + spreadsheet XML formats to read a
/// simple task-list export (Excel, Numbers, Google Sheets all produce
/// compatible files) without pulling in a third-party dependency.
enum XLSXParser {
    static func parseTable(at url: URL) throws -> ParsedTable {
        let data = try Data(contentsOf: url)
        let zip = MinimalZipReader(data: data)

        var sharedStrings: [String] = []
        if let sharedStringsData = try zip.readEntry(named: "xl/sharedStrings.xml") {
            let parser = SharedStringsXMLParser()
            let xmlParser = XMLParser(data: sharedStringsData)
            xmlParser.delegate = parser
            xmlParser.parse()
            sharedStrings = parser.strings
        }

        guard let sheetData = try zip.readEntry(named: "xl/worksheets/sheet1.xml") else {
            throw TaskImportError.invalidArchive
        }
        let worksheetParser = WorksheetXMLParser(sharedStrings: sharedStrings)
        let xmlParser = XMLParser(data: sheetData)
        xmlParser.delegate = worksheetParser
        xmlParser.parse()

        return buildTable(fromSheetRows: worksheetParser.orderedRows)
    }

    private static func buildTable(fromSheetRows sheetRows: [(number: Int, cells: [String: String])]) -> ParsedTable {
        let sorted = sheetRows.sorted { $0.number < $1.number }
        guard let headerRow = sorted.first else { return ParsedTable(headers: [], rows: []) }
        let columnHeaders = headerRow.cells // columnLetter -> header text

        var rows: [[String: String]] = []
        for entry in sorted.dropFirst() {
            guard !entry.cells.isEmpty else { continue }
            var dict: [String: String] = [:]
            for (columnLetter, header) in columnHeaders {
                let trimmedHeader = header.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedHeader.isEmpty else { continue }
                dict[trimmedHeader] = entry.cells[columnLetter] ?? ""
            }
            rows.append(dict)
        }
        let headers = columnHeaders.values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return ParsedTable(headers: headers, rows: rows)
    }
}

// MARK: - xl/sharedStrings.xml

private final class SharedStringsXMLParser: NSObject, XMLParserDelegate {
    private(set) var strings: [String] = []
    private var currentText = ""
    private var insideText = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "si":
            currentText = ""
        case "t":
            insideText = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideText { currentText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "t":
            insideText = false
        case "si":
            strings.append(currentText)
        default:
            break
        }
    }
}

// MARK: - xl/worksheets/sheet1.xml

private final class WorksheetXMLParser: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private(set) var orderedRows: [(number: Int, cells: [String: String])] = []

    private var currentRowNumber = 0
    private var currentRowCells: [String: String] = [:]
    private var currentCellColumn = ""
    private var currentCellType = ""
    private var currentValue = ""
    private var insideValue = false

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "row":
            currentRowCells = [:]
            currentRowNumber = Int(attributeDict["r"] ?? "") ?? (currentRowNumber + 1)
        case "c":
            let ref = attributeDict["r"] ?? ""
            currentCellColumn = String(ref.prefix { $0.isLetter })
            currentCellType = attributeDict["t"] ?? ""
            currentValue = ""
        case "v":
            insideValue = true
            currentValue = ""
        case "t":
            if currentCellType == "inlineStr" {
                insideValue = true
                currentValue = ""
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideValue { currentValue += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "v":
            insideValue = false
        case "t":
            if currentCellType == "inlineStr" { insideValue = false }
        case "c":
            guard !currentCellColumn.isEmpty else { break }
            let resolved: String
            if currentCellType == "s", let index = Int(currentValue), sharedStrings.indices.contains(index) {
                resolved = sharedStrings[index]
            } else {
                resolved = currentValue
            }
            currentRowCells[currentCellColumn] = resolved
        case "row":
            orderedRows.append((number: currentRowNumber, cells: currentRowCells))
        default:
            break
        }
    }
}

// MARK: - Minimal ZIP reader (no external dependency)

/// Reads a single named entry out of a ZIP archive by walking the central
/// directory, then inflating it if needed. Covers just what .xlsx files use:
/// stored (method 0) or deflated (method 8) entries, no encryption/splitting.
private struct MinimalZipReader {
    let data: Data

    func readEntry(named targetName: String) throws -> Data? {
        guard let eocdOffset = findEndOfCentralDirectory() else {
            throw TaskImportError.invalidArchive
        }
        let centralDirOffset = Int(readUInt32(at: eocdOffset + 16))
        let totalEntries = Int(readUInt16(at: eocdOffset + 10))

        var offset = centralDirOffset
        for _ in 0..<totalEntries {
            guard offset + 46 <= data.count, readUInt32(at: offset) == 0x02014b50 else { break }
            let compressionMethod = readUInt16(at: offset + 10)
            let compressedSize = Int(readUInt32(at: offset + 20))
            let uncompressedSize = Int(readUInt32(at: offset + 24))
            let filenameLength = Int(readUInt16(at: offset + 28))
            let extraLength = Int(readUInt16(at: offset + 30))
            let commentLength = Int(readUInt16(at: offset + 32))
            let localHeaderOffset = Int(readUInt32(at: offset + 42))
            let nameStart = offset + 46
            let nameEnd = nameStart + filenameLength
            guard nameEnd <= data.count else { break }
            let name = String(data: data.subdata(in: nameStart..<nameEnd), encoding: .utf8) ?? ""

            if name == targetName {
                return try extractLocalEntry(
                    localHeaderOffset: localHeaderOffset,
                    compressionMethod: compressionMethod,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize
                )
            }
            offset = nameEnd + extraLength + commentLength
        }
        return nil
    }

    private func extractLocalEntry(localHeaderOffset: Int, compressionMethod: UInt16, compressedSize: Int, uncompressedSize: Int) throws -> Data {
        guard readUInt32(at: localHeaderOffset) == 0x04034b50 else {
            throw TaskImportError.invalidArchive
        }
        let filenameLength = Int(readUInt16(at: localHeaderOffset + 26))
        let extraLength = Int(readUInt16(at: localHeaderOffset + 28))
        let dataStart = localHeaderOffset + 30 + filenameLength + extraLength
        let dataEnd = dataStart + compressedSize
        guard dataEnd <= data.count else { throw TaskImportError.invalidArchive }
        let compressed = data.subdata(in: dataStart..<dataEnd)

        switch compressionMethod {
        case 0:
            return compressed
        case 8:
            return try inflate(compressed, expectedSize: uncompressedSize)
        default:
            throw TaskImportError.unsupportedCompression
        }
    }

    /// ZIP's "deflate" method stores raw DEFLATE data (no zlib/gzip wrapper).
    /// Apple's Compression framework decodes that despite the COMPRESSION_ZLIB name.
    private func inflate(_ compressed: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        var decoded = Data(count: expectedSize)
        let resultSize = decoded.withUnsafeMutableBytes { destRaw -> Int in
            compressed.withUnsafeBytes { srcRaw -> Int in
                guard let dest = destRaw.bindMemory(to: UInt8.self).baseAddress,
                      let src = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dest, expectedSize, src, compressed.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard resultSize == expectedSize else {
            throw TaskImportError.decompressionFailed
        }
        return decoded
    }

    private func findEndOfCentralDirectory() -> Int? {
        guard data.count >= 22 else { return nil }
        let searchFloor = max(0, data.count - 22 - 65535)
        var i = data.count - 22
        while i >= searchFloor {
            if readUInt32(at: i) == 0x06054b50 {
                return i
            }
            i -= 1
        }
        return nil
    }

    private func readUInt16(at offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private func readUInt32(at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }
}
