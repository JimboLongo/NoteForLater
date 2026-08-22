import XCTest
@testable import NoteForLater

final class ReceiptLineParserTests: XCTestCase {
    func testStripsTrailingPrice() {
        XCTAssertEqual(ReceiptLineParser.cleanedItemName(from: "BANANAS 2.99"), "BANANAS")
        XCTAssertEqual(ReceiptLineParser.cleanedItemName(from: "MILK 2% $3.49"), "MILK 2%")
        XCTAssertEqual(ReceiptLineParser.cleanedItemName(from: "EGGS DOZEN 4.99 T"), "EGGS DOZEN")
    }

    func testStripsLeadingUPC() {
        XCTAssertEqual(ReceiptLineParser.cleanedItemName(from: "0123456 GREEK YOGURT"), "GREEK YOGURT")
    }

    func testDropsBoilerplateLines() {
        XCTAssertNil(ReceiptLineParser.cleanedItemName(from: "SUBTOTAL 24.50"))
        XCTAssertNil(ReceiptLineParser.cleanedItemName(from: "TOTAL   24.50"))
        XCTAssertNil(ReceiptLineParser.cleanedItemName(from: "VISA DEBIT ****1234"))
        XCTAssertNil(ReceiptLineParser.cleanedItemName(from: "CASH TENDER"))
        XCTAssertNil(ReceiptLineParser.cleanedItemName(from: "THANK YOU FOR SHOPPING"))
    }

    func testDropsPureNumericOrSymbolLines() {
        XCTAssertNil(ReceiptLineParser.cleanedItemName(from: "123456789"))
        XCTAssertNil(ReceiptLineParser.cleanedItemName(from: "----------------"))
        XCTAssertNil(ReceiptLineParser.cleanedItemName(from: ""))
        XCTAssertNil(ReceiptLineParser.cleanedItemName(from: "   "))
    }

    func testKeepsPlainItemNameUnchanged() {
        XCTAssertEqual(ReceiptLineParser.cleanedItemName(from: "OLIVE OIL"), "OLIVE OIL")
    }

    func testCandidateItemsFiltersWholeReceipt() {
        let lines = [
            "TRADER JOE'S",
            "0123456 BANANAS 1.99",
            "MILK 2% 3.49",
            "SUBTOTAL 5.48",
            "SALES TAX 0.44",
            "TOTAL 5.92",
            "VISA DEBIT ****1234",
            "THANK YOU FOR SHOPPING"
        ]
        XCTAssertEqual(ReceiptLineParser.candidateItems(from: lines), ["TRADER JOE'S", "BANANAS", "MILK 2%"])
    }

    // MARK: - upc(in:)

    func testUPC_matchesEightToTwelveDigitRuns() {
        XCTAssertEqual(ReceiptLineParser.upc(in: "12345678 ITEM"), "12345678", "8 digits (EAN-8 length) must match")
        XCTAssertEqual(ReceiptLineParser.upc(in: "049000028911 COCA COLA 12PK"), "049000028911", "12 digits (UPC-A length) must match")
    }

    func testUPC_tooShortOrTooLong_doesNotMatch() {
        XCTAssertNil(ReceiptLineParser.upc(in: "1234567 ITEM"), "7 digits is below the UPC-length floor")
        XCTAssertNil(ReceiptLineParser.upc(in: "1234567890123 ITEM"), "13 digits (EAN-13) is out of the 8-12 scope by design")
    }

    /// Ordinary prices never accidentally read as a barcode — a real
    /// receipt price never has 8+ digits before the decimal point, and
    /// the decimal point itself splits the digits either side of it into
    /// two separate, too-short runs.
    func testUPC_priceLikeText_doesNotMatch() {
        XCTAssertNil(ReceiptLineParser.upc(in: "BANANAS 5.99"))
        XCTAssertNil(ReceiptLineParser.upc(in: "TOTAL $124.99"))
    }

    /// When a line has more than one digit run of qualifying length, the
    /// first one (left to right, matching where a barcode is actually
    /// printed) is the one returned.
    func testUPC_multipleQualifyingRuns_returnsFirst() {
        XCTAssertEqual(ReceiptLineParser.upc(in: "123456789 ITEM 987654321"), "123456789")
    }

    func testUPC_noDigitRun_returnsNil() {
        XCTAssertNil(ReceiptLineParser.upc(in: "OLIVE OIL"))
        XCTAssertNil(ReceiptLineParser.upc(in: ""))
    }
}
