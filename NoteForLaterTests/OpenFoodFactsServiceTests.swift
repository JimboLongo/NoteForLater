import XCTest
@testable import NoteForLater

/// `OpenFoodFactsService.parseProductName(from:)` is pure — no network
/// involved, so these hand-build the JSON bytes a real response would
/// contain rather than mocking `URLSession`. `lookupProductName(upc:)`
/// itself (the actual network call) is intentionally untested here, same
/// as this repo's existing convention for its other real HTTP methods
/// (e.g. `GoogleCalendarService`'s calls aren't unit-tested either) —
/// this pure function is the seam that carries all the actual logic worth
/// verifying.
final class OpenFoodFactsServiceTests: XCTestCase {
    private func data(_ json: String) -> Data {
        Data(json.utf8)
    }

    func test_parseProductName_found_returnsTrimmedName() {
        let json = """
        {
            "status": 1,
            "status_verbose": "product found",
            "code": "3017620422003",
            "product": { "product_name": "  Nutella  " }
        }
        """
        XCTAssertEqual(OpenFoodFactsService.parseProductName(from: data(json)), "Nutella")
    }

    func test_parseProductName_notFound_returnsNil() {
        let json = """
        {
            "status": 0,
            "status_verbose": "product not found",
            "code": "00000000"
        }
        """
        XCTAssertNil(OpenFoodFactsService.parseProductName(from: data(json)))
    }

    /// `status == 1` with no usable name at all — a malformed-but-valid
    /// response shape, distinct from `status == 0`. Both must still
    /// collapse to `nil` for the caller.
    func test_parseProductName_foundButNoProductName_returnsNil() {
        let missingKey = """
        { "status": 1, "product": {} }
        """
        let blankName = """
        { "status": 1, "product": { "product_name": "   " } }
        """
        XCTAssertNil(OpenFoodFactsService.parseProductName(from: data(missingKey)))
        XCTAssertNil(OpenFoodFactsService.parseProductName(from: data(blankName)))
    }

    func test_parseProductName_malformedJSON_returnsNil() {
        XCTAssertNil(OpenFoodFactsService.parseProductName(from: data("not json at all")))
        XCTAssertNil(OpenFoodFactsService.parseProductName(from: Data()))
    }
}
