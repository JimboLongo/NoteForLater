import XCTest
@testable import NoteForLater

final class RecipeIngredientParserTests: XCTestCase {
    // MARK: - Quantity extraction

    func test_parse_wholeNumberWithUnit() {
        let parsed = RecipeIngredientParser.parse("3 tbsp unsalted butter, softened")
        XCTAssertEqual(parsed.quantity, 3)
        XCTAssertEqual(parsed.unit, "tbsp")
        XCTAssertEqual(parsed.name, "unsalted butter, softened")
    }

    func test_parse_simpleFraction() {
        let parsed = RecipeIngredientParser.parse("1/2 tsp salt")
        XCTAssertEqual(parsed.quantity, 0.5)
        XCTAssertEqual(parsed.unit, "tsp")
        XCTAssertEqual(parsed.name, "salt")
    }

    func test_parse_mixedNumber() {
        let parsed = RecipeIngredientParser.parse("1 1/2 cups all-purpose flour")
        XCTAssertEqual(parsed.quantity, 1.5)
        XCTAssertEqual(parsed.unit, "cup")
        XCTAssertEqual(parsed.name, "all-purpose flour")
    }

    func test_parse_bareUnicodeFraction() {
        let parsed = RecipeIngredientParser.parse("½ cup milk")
        XCTAssertEqual(parsed.quantity, 0.5)
        XCTAssertEqual(parsed.unit, "cup")
        XCTAssertEqual(parsed.name, "milk")
    }

    func test_parse_wholeNumberPlusUnicodeFraction() {
        let parsed = RecipeIngredientParser.parse("1½ cups sugar")
        XCTAssertEqual(parsed.quantity, 1.5)
        XCTAssertEqual(parsed.unit, "cup")
        XCTAssertEqual(parsed.name, "sugar")
    }

    /// The bare-count case — extremely common in real recipes ("2 large
    /// eggs", "1 onion, diced") and not one of the seven listed units.
    /// `unit == nil` here means count, not a parse failure.
    func test_parse_noUnit_isBareCount() {
        let parsed = RecipeIngredientParser.parse("2 large eggs")
        XCTAssertEqual(parsed.quantity, 2)
        XCTAssertNil(parsed.unit)
        XCTAssertEqual(parsed.name, "large eggs")
    }

    /// No leading quantity at all — the whole line becomes the name, with
    /// nothing to deduct.
    func test_parse_noQuantity_returnsNilQuantityAndFullLineAsName() {
        let parsed = RecipeIngredientParser.parse("Salt and pepper to taste")
        XCTAssertNil(parsed.quantity)
        XCTAssertNil(parsed.unit)
        XCTAssertEqual(parsed.name, "Salt and pepper to taste")
    }

    // MARK: - Unit alias normalization

    func test_parse_unitAliases_normalizeToCanonicalForm() {
        XCTAssertEqual(RecipeIngredientParser.parse("3 tablespoons olive oil").unit, "tbsp")
        XCTAssertEqual(RecipeIngredientParser.parse("1 pound ground beef").unit, "lb")
        XCTAssertEqual(RecipeIngredientParser.parse("8 ounces cream cheese").unit, "oz")
        XCTAssertEqual(RecipeIngredientParser.parse("2 teaspoons vanilla extract").unit, "tsp")
        XCTAssertEqual(RecipeIngredientParser.parse("400 grams pasta").unit, "g")
        XCTAssertEqual(RecipeIngredientParser.parse("250 milliliters water").unit, "ml")
    }

    // MARK: - Unit conversion

    func test_convert_withinVolumeSystem() {
        XCTAssertEqual(RecipeIngredientParser.convert(1, from: "tbsp", to: "ml") ?? 0, 14.7868, accuracy: 0.0001)
        XCTAssertEqual(RecipeIngredientParser.convert(1, from: "cup", to: "tbsp") ?? 0, 16, accuracy: 0.01)
        XCTAssertEqual(RecipeIngredientParser.convert(3, from: "tsp", to: "tbsp") ?? 0, 1, accuracy: 0.0001)
    }

    func test_convert_withinWeightSystem() {
        XCTAssertEqual(RecipeIngredientParser.convert(1, from: "oz", to: "g") ?? 0, 28.3495, accuracy: 0.0001)
        XCTAssertEqual(RecipeIngredientParser.convert(1, from: "lb", to: "oz") ?? 0, 16, accuracy: 0.01)
    }

    func test_convert_sameUnit_isPassthrough() {
        XCTAssertEqual(RecipeIngredientParser.convert(5, from: "tbsp", to: "tbsp"), 5)
    }

    /// The load-bearing guard: volume and weight are never bridged,
    /// because that needs an ingredient-specific density this app has no
    /// data for.
    func test_convert_acrossVolumeAndWeight_returnsNil() {
        XCTAssertNil(RecipeIngredientParser.convert(1, from: "cup", to: "g"))
        XCTAssertNil(RecipeIngredientParser.convert(1, from: "oz", to: "ml"))
    }
}
