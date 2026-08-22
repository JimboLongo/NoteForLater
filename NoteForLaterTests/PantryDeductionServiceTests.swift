import XCTest
@testable import NoteForLater

/// Integration-style: real `Recipe`/`TaskItem` values (no `ModelContext`
/// needed — both can be constructed directly, same as `MealSuggestionServiceTests`
/// already does), feeding the whole recipe -> deduct -> updated-pantry
/// pipeline in one pass rather than just the parsing or matching pieces
/// alone.
///
/// `quantity` counts *packages*, not a raw amount — see `TaskItem
/// .quantity`'s own doc comment. A pantry item at `quantity == 1,
/// packageSize == 12, unit == "oz"` is one full, unopened 12 oz
/// container; losing 6 oz to a recipe leaves `quantity == 0.5`, not `6`.
final class PantryDeductionServiceTests: XCTestCase {
    private func packagedItem(_ title: String, quantity: Double, packageSize: Double, unit: String) -> TaskItem {
        let task = TaskItem(title: title)
        task.quantity = quantity
        task.packageSize = packageSize
        task.unit = unit
        return task
    }

    private func bareCountItem(_ title: String, quantity: Double) -> TaskItem {
        let task = TaskItem(title: title)
        task.quantity = quantity
        return task
    }

    /// The exact worked example this model was designed around: one full
    /// 12 oz tub of sour cream, a recipe needs 6 oz of it, leaving half a
    /// tub — not "6," and not "12 minus 6 = 6 oz remaining" the old
    /// raw-amount model would have produced.
    func test_deduct_packaged_sufficientInventory_leavesFractionOfPackage() {
        let recipe = Recipe(title: "Dip", ingredients: ["6 oz sour cream"])
        let sourCream = packagedItem("Sour Cream", quantity: 1, packageSize: 12, unit: "oz")

        PantryDeductionService.deduct(recipe: recipe, pantryItems: [sourCream])

        XCTAssertEqual(sourCream.quantity, 0.5)
    }

    /// The explicitly-specified behavior: insufficient inventory clamps to
    /// zero, no negative, no warning of any kind raised.
    func test_deduct_packaged_insufficientInventory_clampsToZero() {
        let recipe = Recipe(title: "Toast", ingredients: ["3 tbsp butter"])
        // A tenth of a 16 tbsp package (1.6 tbsp on hand) can't cover 3.
        let butter = packagedItem("Butter", quantity: 0.1, packageSize: 16, unit: "tbsp")

        PantryDeductionService.deduct(recipe: recipe, pantryItems: [butter])

        XCTAssertEqual(butter.quantity, 0)
    }

    /// Already at zero packages stays at zero rather than going negative.
    func test_deduct_packaged_alreadyZero_staysZero() {
        let recipe = Recipe(title: "Cake", ingredients: ["1/2 cup flour"])
        let flour = packagedItem("Flour", quantity: 0, packageSize: 5, unit: "cup")

        PantryDeductionService.deduct(recipe: recipe, pantryItems: [flour])

        XCTAssertEqual(flour.quantity, 0)
    }

    /// No matching pantry item at all — silently skipped, nothing created,
    /// nothing else in the pantry disturbed.
    func test_deduct_noMatchingPantryItem_isSilentNoOp() {
        let recipe = Recipe(title: "Soup", ingredients: ["2 cups chicken broth"])
        let unrelated = packagedItem("Butter", quantity: 1, packageSize: 16, unit: "tbsp")

        PantryDeductionService.deduct(recipe: recipe, pantryItems: [unrelated])

        XCTAssertEqual(unrelated.quantity, 1, "an ingredient with no pantry match must not touch anything else")
    }

    /// A recipe's need converts into the package's own unit before being
    /// turned into a package-fraction — recipe asks for 1 tbsp, the
    /// bottle's package size is stated in ml.
    func test_deduct_packaged_convertsRecipeUnitIntoPackageUnit() {
        let recipe = Recipe(title: "Dressing", ingredients: ["1 tbsp olive oil"])
        let oil = packagedItem("Olive Oil", quantity: 1, packageSize: 500, unit: "ml")

        PantryDeductionService.deduct(recipe: recipe, pantryItems: [oil])

        let expectedPackagesUsed = 14.7868 / 500
        XCTAssertEqual(oil.quantity, 1 - expectedPackagesUsed, accuracy: 0.0001)
    }

    /// Cross-system (recipe volume vs. pantry weight, or vice versa) is
    /// never guessed at — skipped, matching the no-matching-item case.
    func test_deduct_packaged_crossSystemMismatch_isSkipped() {
        let recipe = Recipe(title: "Bread", ingredients: ["1 cup flour"])
        let flour = packagedItem("Flour", quantity: 1, packageSize: 500, unit: "g")

        PantryDeductionService.deduct(recipe: recipe, pantryItems: [flour])

        XCTAssertEqual(flour.quantity, 1)
    }

    /// A packaged pantry item (real unit + package size) against a
    /// bare-count recipe ingredient (no unit at all) — not comparable
    /// either, same as the cross-system case.
    func test_deduct_packagedItemAgainstBareCountIngredient_isSkipped() {
        let recipe = Recipe(title: "Salad", ingredients: ["2 croutons"])
        let croutons = packagedItem("Croutons", quantity: 1, packageSize: 5, unit: "oz")

        PantryDeductionService.deduct(recipe: recipe, pantryItems: [croutons])

        XCTAssertEqual(croutons.quantity, 1)
    }

    /// The bare-count path (no package concept at all — a dozen eggs, an
    /// onion) is unchanged: direct subtraction, no package math.
    func test_deduct_bareCount_subtractsDirectly() {
        let recipe = Recipe(title: "Omelette", ingredients: ["4 eggs"])
        let eggs = bareCountItem("Eggs", quantity: 12)

        PantryDeductionService.deduct(recipe: recipe, pantryItems: [eggs])

        XCTAssertEqual(eggs.quantity, 8)
    }

    /// Bare-count clamps to zero too, same as the packaged case.
    func test_deduct_bareCount_insufficientClampsToZero() {
        let recipe = Recipe(title: "Omelette", ingredients: ["4 eggs"])
        let eggs = bareCountItem("Eggs", quantity: 1)

        PantryDeductionService.deduct(recipe: recipe, pantryItems: [eggs])

        XCTAssertEqual(eggs.quantity, 0)
    }

    /// More than one pantry item matches the same ingredient name — a
    /// genuine duplicate entry, both titled exactly "Butter" (nothing
    /// stops that in this data model) — deduct from the first only, never
    /// split or guess between them. A near-duplicate name like "Butter
    /// (backup)" would NOT actually create this ambiguity: its two-word
    /// tokenization can never whole-word-match a one-word ingredient like
    /// "butter" in the first place, so the fixture has to be a true
    /// duplicate to exercise this path at all.
    func test_deduct_ambiguousMatch_usesFirstOnly() {
        let recipe = Recipe(title: "Pancakes", ingredients: ["2 tbsp butter"])
        let firstButter = packagedItem("Butter", quantity: 1, packageSize: 16, unit: "tbsp")
        let secondButter = packagedItem("Butter", quantity: 1, packageSize: 16, unit: "tbsp")

        PantryDeductionService.deduct(recipe: recipe, pantryItems: [firstButter, secondButter])

        XCTAssertEqual(firstButter.quantity, 1 - (2.0 / 16.0), accuracy: 0.0001)
        XCTAssertEqual(secondButter.quantity, 1, "only the first match should ever be touched")
    }

    /// A full multi-ingredient recipe against a mixed pantry — packaged
    /// and bare-count items together, the actual shape this feature runs
    /// in practice, not just one ingredient at a time.
    func test_deduct_fullRecipe_updatesOnlyMatchedItems() {
        let recipe = Recipe(title: "Dinner", ingredients: [
            "6 oz sour cream",
            "4 eggs",
            "1/2 cup flour",
            "1 onion, diced"
        ])
        let sourCream = packagedItem("Sour Cream", quantity: 1, packageSize: 12, unit: "oz")
        let eggs = bareCountItem("Eggs", quantity: 12)
        let flour = packagedItem("Flour", quantity: 1, packageSize: 5, unit: "cup")
        // No pantry item for onion at all.

        PantryDeductionService.deduct(recipe: recipe, pantryItems: [sourCream, eggs, flour])

        XCTAssertEqual(sourCream.quantity, 0.5)
        XCTAssertEqual(eggs.quantity, 8)
        XCTAssertEqual(flour.quantity, 1 - (0.5 / 5.0), accuracy: 0.0001)
    }
}
