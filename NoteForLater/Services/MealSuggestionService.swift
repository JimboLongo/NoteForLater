import Foundation

/// Ingredient-matching logic behind Kitchen's Meals feature. No SwiftUI or
/// SwiftData dependency — takes plain `Recipe` values and pantry item name
/// strings, so it's testable without a `ModelContainer` and reusable from
/// anywhere that has both.
enum MealSuggestionService {
    /// Every ingredient line from `recipe.ingredients` with no matching
    /// pantry item, in the recipe's own original order.
    ///
    /// Matching is whole-word, not substring: a pantry item's normalized
    /// words must appear as a contiguous run of whole words inside the
    /// ingredient line's own normalized words. `Recipe.ingredients` lines
    /// are raw, messy text (`"3 tbsp unsalted butter, softened"` off a
    /// site's schema.org markup), while a pantry item's name is a plain
    /// `TaskItem.title` (`"Butter"`) — so exact string equality would
    /// almost never match, and plain substring containment would wrongly
    /// match "egg" against "eggplant". Tokenizing both sides first is what
    /// rules that out, while still matching a multi-word pantry item like
    /// "Olive Oil" against "2 tbsp olive oil".
    static func missingIngredients(for recipe: Recipe, pantryItems: [String]) -> [String] {
        let pantryWordLists = pantryItems.map(normalizedWords).filter { !$0.isEmpty }
        return recipe.ingredients.filter { ingredient in
            let ingredientWords = normalizedWords(ingredient)
            return !pantryWordLists.contains { containsWholeWordRun($0, in: ingredientWords) }
        }
    }

    /// Recipes ranked by how many ingredients are missing, fewest first.
    /// `sorted` is stable, so recipes tied on missing count keep their
    /// input order rather than being re-sorted by anything else, e.g.
    /// title.
    static func rankRecipes(_ recipes: [Recipe], pantryItems: [String]) -> [(recipe: Recipe, missingCount: Int)] {
        recipes
            .map { recipe in (recipe: recipe, missingCount: missingIngredients(for: recipe, pantryItems: pantryItems).count) }
            .sorted { $0.missingCount < $1.missingCount }
    }

    /// Lowercased, punctuation replaced with spaces, split on whitespace —
    /// the shared normalization both a pantry item's name and a recipe's
    /// ingredient line go through before comparison. Replacing (not
    /// stripping) punctuation is what keeps "butter," from fusing with
    /// whatever follows it into one token.
    private static func normalizedWords(_ text: String) -> [String] {
        let lowered = text.lowercased()
        let cleaned = String(lowered.unicodeScalars.map { scalar -> Character in
            (CharacterSet.alphanumerics.contains(scalar) || CharacterSet.whitespaces.contains(scalar)) ? Character(scalar) : " "
        })
        return cleaned.split(separator: " ").map(String.init)
    }

    /// True if `needle` appears as a contiguous run of whole words
    /// somewhere inside `haystack`.
    private static func containsWholeWordRun(_ needle: [String], in haystack: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle {
                return true
            }
        }
        return false
    }
}
