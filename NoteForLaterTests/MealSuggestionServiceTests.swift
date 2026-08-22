import XCTest
@testable import NoteForLater

/// `MealSuggestionService` is pure logic — no SwiftUI, no SwiftData
/// persistence needed. A `Recipe` can be constructed directly without a
/// `ModelContext`, same as other model fixtures elsewhere in this suite.
final class MealSuggestionServiceTests: XCTestCase {
    private func recipe(_ ingredients: [String]) -> Recipe {
        Recipe(title: "Test Recipe", ingredients: ingredients)
    }

    func test_missingIngredients_exactMatch_isNotMissing() {
        let r = recipe(["butter", "eggs"])
        let missing = MealSuggestionService.missingIngredients(for: r, pantryItems: ["butter", "eggs"])
        XCTAssertEqual(missing, [])
    }

    /// The real-world case this feature exists for: a pantry item's plain
    /// name ("Butter") matching a recipe site's messy ingredient line.
    func test_missingIngredients_wholeWordFuzzyMatch() {
        let r = recipe(["3 tbsp unsalted butter, softened", "2 cups flour"])
        let missing = MealSuggestionService.missingIngredients(for: r, pantryItems: ["Butter"])
        XCTAssertEqual(missing, ["2 cups flour"], "butter should match despite quantity/prep text around it; flour has no pantry match")
    }

    /// A multi-word pantry item ("Olive Oil") must match as a contiguous
    /// run of whole words, not just both words appearing anywhere.
    func test_missingIngredients_multiWordPantryItemMatchesContiguousRun() {
        let r = recipe(["2 tbsp olive oil", "1 tsp olive brine, oil-cured"])
        let missing = MealSuggestionService.missingIngredients(for: r, pantryItems: ["Olive Oil"])
        XCTAssertEqual(missing, ["1 tsp olive brine, oil-cured"], "\"olive\" and \"oil\" appear but not contiguously, so this one must still be reported missing")
    }

    func test_missingIngredients_noMatch_isMissing() {
        let r = recipe(["3 cups flour", "1 cup sugar"])
        let missing = MealSuggestionService.missingIngredients(for: r, pantryItems: ["butter"])
        XCTAssertEqual(missing, ["3 cups flour", "1 cup sugar"])
    }

    func test_missingIngredients_emptyPantry_everythingIsMissing() {
        let r = recipe(["3 cups flour", "1 cup sugar"])
        let missing = MealSuggestionService.missingIngredients(for: r, pantryItems: [])
        XCTAssertEqual(missing, ["3 cups flour", "1 cup sugar"])
    }

    /// The whole-word guard this design exists for: "egg" must not match
    /// "eggplant" the way plain substring containment would.
    func test_missingIngredients_eggDoesNotMatchEggplant() {
        let r = recipe(["1 large eggplant, sliced"])
        let missing = MealSuggestionService.missingIngredients(for: r, pantryItems: ["egg"])
        XCTAssertEqual(missing, ["1 large eggplant, sliced"], "\"egg\" is a substring of \"eggplant\" but not the same whole word")
    }

    /// The other direction of the same guard, to confirm it isn't
    /// order-dependent: a pantry item that's itself a compound word must
    /// not be satisfied by a shorter ingredient word inside it.
    func test_missingIngredients_eggplantPantryItemDoesNotMatchPlainEgg() {
        let r = recipe(["2 eggs, beaten"])
        let missing = MealSuggestionService.missingIngredients(for: r, pantryItems: ["eggplant"])
        XCTAssertEqual(missing, ["2 eggs, beaten"])
    }

    func test_rankRecipes_sortsByMissingCountAscending() {
        let readyToCook = recipe(["butter", "eggs"])
        let oneMissing = recipe(["butter", "eggs", "flour"])
        let twoMissing = recipe(["butter", "eggs", "flour", "sugar"])
        let ranked = MealSuggestionService.rankRecipes([twoMissing, readyToCook, oneMissing], pantryItems: ["butter", "eggs"])

        XCTAssertEqual(ranked.map(\.missingCount), [0, 1, 2])
        XCTAssertTrue(ranked[0].recipe === readyToCook)
        XCTAssertTrue(ranked[1].recipe === oneMissing)
        XCTAssertTrue(ranked[2].recipe === twoMissing)
    }
}
