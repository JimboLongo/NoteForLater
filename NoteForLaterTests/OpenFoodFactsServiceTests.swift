import XCTest
@testable import NoteForLater

/// `OpenFoodFactsService.parseProductInfo(from:)` is pure — no network
/// involved, so these hand-build the JSON bytes a real response would
/// contain rather than mocking `URLSession`. `lookupProductInfo(upc:)`
/// itself (the actual network call) is intentionally untested here, same
/// as this repo's existing convention for its other real HTTP methods
/// (e.g. `GoogleCalendarService`'s calls aren't unit-tested either) —
/// this pure function is the seam that carries all the actual logic worth
/// verifying.
final class OpenFoodFactsServiceTests: XCTestCase {
    private func data(_ json: String) -> Data {
        Data(json.utf8)
    }

    func test_parseProductInfo_foundWithBoth_returnsAllThreeFields() {
        let json = """
        {
            "status": 1,
            "code": "3017620422003",
            "product": { "product_name": "  Nutella  ", "brands": "Ferrero", "quantity": "400 g" }
        }
        """
        let info = OpenFoodFactsService.parseProductInfo(from: data(json))
        XCTAssertEqual(info, .init(name: "Nutella", brand: "Ferrero", size: "400 g"), "name must be trimmed same as before")
    }

    func test_parseProductInfo_foundWithBrandOnly_sizeIsNil() {
        let json = """
        { "status": 1, "product": { "product_name": "Nutella", "brands": "Ferrero" } }
        """
        XCTAssertEqual(OpenFoodFactsService.parseProductInfo(from: data(json)), .init(name: "Nutella", brand: "Ferrero", size: nil))
    }

    func test_parseProductInfo_foundWithSizeOnly_brandIsNil() {
        let json = """
        { "status": 1, "product": { "product_name": "Nutella", "quantity": "400 g" } }
        """
        XCTAssertEqual(OpenFoodFactsService.parseProductInfo(from: data(json)), .init(name: "Nutella", brand: nil, size: "400 g"))
    }

    /// Both keys missing, and both keys present-but-blank — both shapes
    /// must collapse to the same nil/nil, not just the missing-key case.
    func test_parseProductInfo_foundWithNeither_bothNil() {
        let missingKeys = """
        { "status": 1, "product": { "product_name": "Nutella" } }
        """
        let blankValues = """
        { "status": 1, "product": { "product_name": "Nutella", "brands": "  ", "quantity": "" } }
        """
        XCTAssertEqual(OpenFoodFactsService.parseProductInfo(from: data(missingKeys)), .init(name: "Nutella", brand: nil, size: nil))
        XCTAssertEqual(OpenFoodFactsService.parseProductInfo(from: data(blankValues)), .init(name: "Nutella", brand: nil, size: nil))
    }

    /// `brands` lists more than one, comma-separated — only the first is
    /// kept, since a receipt row has room for one brand name.
    func test_parseProductInfo_multipleBrands_takesFirstOnly() {
        let json = """
        { "status": 1, "product": { "product_name": "Nutella", "brands": "Ferrero, Ferrero USA, Ferrero SpA" } }
        """
        XCTAssertEqual(OpenFoodFactsService.parseProductInfo(from: data(json))?.brand, "Ferrero")
    }

    func test_parseProductInfo_notFound_returnsNil() {
        let json = """
        { "status": 0, "status_verbose": "product not found", "code": "00000000" }
        """
        XCTAssertNil(OpenFoodFactsService.parseProductInfo(from: data(json)))
    }

    /// `status == 1` with no usable name at all — a malformed-but-valid
    /// response shape, distinct from `status == 0`. Both must still
    /// collapse to `nil` overall, even with a real brand/size present.
    func test_parseProductInfo_foundButNoProductName_returnsNilOverall() {
        let missingKey = """
        { "status": 1, "product": { "brands": "Ferrero", "quantity": "400 g" } }
        """
        let blankName = """
        { "status": 1, "product": { "product_name": "   " } }
        """
        XCTAssertNil(OpenFoodFactsService.parseProductInfo(from: data(missingKey)))
        XCTAssertNil(OpenFoodFactsService.parseProductInfo(from: data(blankName)))
    }

    func test_parseProductInfo_malformedJSON_returnsNil() {
        XCTAssertNil(OpenFoodFactsService.parseProductInfo(from: data("not json at all")))
        XCTAssertNil(OpenFoodFactsService.parseProductInfo(from: Data()))
    }
}
