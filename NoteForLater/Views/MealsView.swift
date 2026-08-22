import SwiftUI
import SwiftData

/// The Kitchen shelf's third pane, alongside Pantry and Cookbook — every
/// saved recipe ranked by how many ingredients are still missing from the
/// Pantry, fewest first, so "what can I make right now" is the default
/// order rather than something you have to work out per recipe. Pantry
/// contents are read straight off the same `TaskItem`s the Pantry pane
/// itself shows — there's no separate ingredient model (see
/// `MealSuggestionService`).
struct MealsView: View {
    let shelf: Shelf
    @Query(sort: \Recipe.title) private var recipes: [Recipe]
    @State private var selectedRecipe: Recipe?
    /// Which rows currently have their missing-ingredient list expanded
    /// inline — independent of `selectedRecipe`, which drives the separate
    /// full detail sheet (instructions + the complete, uncapped list).
    @State private var expandedRecipeIDs: Set<UUID> = []
    /// Inline preview caps at this many ingredients before folding the
    /// rest into an "...and N more" line — the full, uncapped list is
    /// still one info-button tap away via the detail sheet.
    private static let inlinePreviewLimit = 10

    /// Same "still actually in the pantry" filter `ShelfListView.visibleTasks`
    /// applies — a completed pantry task means "used up," not on hand.
    private var pantryItemNames: [String] {
        (shelf.tasks ?? []).filter { !$0.isCompleted }.map(\.title)
    }

    private var ranked: [(recipe: Recipe, missingCount: Int)] {
        MealSuggestionService.rankRecipes(recipes, pantryItems: pantryItemNames)
    }

    var body: some View {
        List {
            if recipes.isEmpty {
                Text("No recipes yet. Add some from the Cookbook tab.")
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            ForEach(ranked, id: \.recipe.id) { entry in
                DisclosureGroup(isExpanded: expansionBinding(for: entry.recipe.id)) {
                    missingIngredientsPreview(for: entry.recipe)
                } label: {
                    row(for: entry)
                }
                .listRowBackground(shelf.flattenedColor(opacity: 0.28))
            }
        }
        .listStyle(.plain)
        .background(shelf.flattenedColor(opacity: 0.22))
        .sheet(item: $selectedRecipe) { recipe in
            MissingIngredientsSheet(recipe: recipe, pantryItemNames: pantryItemNames)
        }
    }

    private func expansionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedRecipeIDs.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    expandedRecipeIDs.insert(id)
                } else {
                    expandedRecipeIDs.remove(id)
                }
            }
        )
    }

    /// The `DisclosureGroup`'s label — tapping anywhere on it (title,
    /// badge, blank space) toggles the inline expand/collapse. The info
    /// button is the one part of this row that deliberately does
    /// something else: it's a real `Button`, so its own tap wins over the
    /// label's, opening the full detail sheet (instructions + the
    /// complete, uncapped missing list) instead of toggling expansion.
    private func row(for entry: (recipe: Recipe, missingCount: Int)) -> some View {
        HStack {
            Text(entry.recipe.title)
            Spacer()
            missingCountBadge(entry.missingCount)
            Button {
                selectedRecipe = entry.recipe
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private func missingIngredientsPreview(for recipe: Recipe) -> some View {
        let missing = MealSuggestionService.missingIngredients(for: recipe, pantryItems: pantryItemNames)
        if missing.isEmpty {
            Label("Everything's in the Pantry.", systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.green)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(missing.prefix(Self.inlinePreviewLimit), id: \.self) { ingredient in
                    Button {
                        // TODO: route to shopping list — no shopping list
                        // feature exists yet (see MealSuggestionService's
                        // doc comment); this is a stub until one does.
                    } label: {
                        Text(ingredient)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if missing.count > Self.inlinePreviewLimit {
                    Text("...and \(missing.count - Self.inlinePreviewLimit) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func missingCountBadge(_ count: Int) -> some View {
        Group {
            if count == 0 {
                Label("Ready to cook", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text("\(count) missing")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }
}

/// What's missing for one recipe, listed against the Pantry as of the
/// moment the sheet opened — same non-live snapshot every other "here's
/// what's true right now" sheet in this app uses, since re-deriving live
/// while the sheet is open would mean a row moving out from under a tap.
private struct MissingIngredientsSheet: View {
    let recipe: Recipe
    let pantryItemNames: [String]
    @Environment(\.dismiss) private var dismiss

    private var missing: [String] {
        MealSuggestionService.missingIngredients(for: recipe, pantryItems: pantryItemNames)
    }

    var body: some View {
        NavigationStack {
            List {
                if missing.isEmpty {
                    Section {
                        Label("Everything's in the Pantry.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                } else {
                    Section {
                        ForEach(missing, id: \.self) { ingredient in
                            Button {
                                // TODO: route to shopping list — no shopping
                                // list feature exists yet (see
                                // MealSuggestionService's doc comment); this
                                // is a stub until one does.
                            } label: {
                                Text(ingredient)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Missing")
                    } footer: {
                        Text("Tap an ingredient to add it to your shopping list.")
                    }
                }
                if !recipe.instructions.isEmpty {
                    Section("Instructions") {
                        Text(recipe.instructions)
                    }
                }
            }
            .navigationTitle(recipe.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    let shelf = Shelf(name: "The Kitchen", systemImage: "refrigerator")
    shelf.isKitchen = true
    return MealsView(shelf: shelf)
        .modelContainer(for: [Shelf.self, TaskItem.self, Recipe.self], inMemory: true)
}
