import Foundation

/// Deducts a completed recipe's ingredients from matching Pantry items.
/// Pure with respect to matching/arithmetic (fully covered by
/// `PantryDeductionServiceTests`), but it does mutate the `TaskItem`s
/// passed in directly — those need to be live, model-context-backed
/// instances for the deduction to actually persist, same convention as
/// `MealSuggestionService.missingIngredients` taking real `Recipe` values
/// rather than snapshots.
enum PantryDeductionService {
    /// For each of `recipe.ingredients`: parse it, find the one pantry
    /// item whose name whole-word-matches the parsed ingredient name (via
    /// `MealSuggestionService`'s shared tokenizer — not reimplemented
    /// here), and subtract, clamped at zero. Every failure mode is a
    /// silent no-op, not a warning — this app's Meals feature was
    /// explicitly scoped that way: no parseable quantity, no matching
    /// pantry item, more than one matching pantry item (ambiguous — the
    /// first match is used rather than guessing which one is "right"),
    /// or a unit that can't convert (a cross-system pair, e.g. recipe
    /// `cup` against a pantry item measured in `g` — see
    /// `RecipeIngredientParser.convert`) all just mean that one
    /// ingredient's line is skipped.
    ///
    /// Two different pantry shapes, handled differently — see
    /// `TaskItem.quantity`'s own doc comment for why:
    /// - **Packaged** (`packageSize`/`unit` both set): `quantity` counts
    ///   packages, not a raw amount, so what's actually subtracted is the
    ///   recipe's need converted into *packages* (`neededInPackageUnit /
    ///   packageSize`), not the raw amount itself. A 12 oz item at
    ///   `quantity == 1` losing 6 oz to a recipe becomes `quantity == 0.5`
    ///   — half a package — not `6`.
    /// - **Bare count** (`packageSize == nil`, `unit == nil`): `quantity`
    ///   is the raw count of individual items ("12 eggs"), compared
    ///   directly against the recipe's own bare-count need with no
    ///   package math at all.
    static func deduct(recipe: Recipe, pantryItems: [TaskItem]) {
        for line in recipe.ingredients {
            let parsed = RecipeIngredientParser.parse(line)
            guard let neededQuantity = parsed.quantity else { continue }
            guard let match = matchingPantryItem(forIngredientName: parsed.name, in: pantryItems) else { continue }

            if let packageSize = match.packageSize, packageSize > 0, let pantryUnit = match.unit {
                guard let recipeUnit = parsed.unit,
                      let neededInPackageUnit = RecipeIngredientParser.convert(neededQuantity, from: recipeUnit, to: pantryUnit) else { continue }
                let packagesNeeded = neededInPackageUnit / packageSize
                match.quantity = max(0, match.quantity - packagesNeeded)
            } else if match.packageSize == nil, match.unit == nil, parsed.unit == nil {
                // Bare counts on both sides ("2 eggs" against a pantry
                // item with no package concept at all) — compare
                // directly, no conversion or package math needed.
                match.quantity = max(0, match.quantity - neededQuantity)
            }
            // Otherwise: a real unit on one side with nothing to convert
            // it through on the other (a count against a weight/volume,
            // or a real unit with no recorded package size) — not
            // comparable, skip rather than guess.
        }
    }

    /// The first pantry item whose name appears as a whole-word run inside
    /// `ingredientName` — same direction `MealSuggestionService
    /// .missingIngredients` already uses (pantry item name is the needle,
    /// ingredient text is the haystack), reusing its tokenizer rather than
    /// growing a second one.
    private static func matchingPantryItem(forIngredientName ingredientName: String, in pantryItems: [TaskItem]) -> TaskItem? {
        let ingredientWords = MealSuggestionService.normalizedWords(ingredientName)
        return pantryItems.first { item in
            let itemWords = MealSuggestionService.normalizedWords(item.title)
            guard !itemWords.isEmpty else { return false }
            return MealSuggestionService.containsWholeWordRun(itemWords, in: ingredientWords)
        }
    }
}
