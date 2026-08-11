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
}
