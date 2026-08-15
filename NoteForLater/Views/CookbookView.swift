import SwiftUI
import SwiftData

/// The Kitchen shelf's other pane, alongside Pantry — every saved recipe,
/// added from a URL (see `RecipeImportService`) or typed in by hand. Tap
/// one to view/edit it in place.
struct CookbookView: View {
    let shelf: Shelf
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Recipe.title) private var recipes: [Recipe]
    @State private var selectedRecipe: Recipe?
    @State private var isShowingAddRecipe = false

    var body: some View {
        List {
            if recipes.isEmpty {
                Text("No recipes yet. Add one from a URL or type it in by hand.")
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            ForEach(recipes) { recipe in
                Button {
                    selectedRecipe = recipe
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recipe.title)
                        if !recipe.ingredients.isEmpty {
                            Text("\(recipe.ingredients.count) ingredient\(recipe.ingredients.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(shelf.flattenedColor(opacity: 0.28))
            }
            .onDelete(perform: deleteRecipes)
        }
        .listStyle(.plain)
        // Same tint `ShelfListView` gives the Pantry pane — one shelf,
        // one color, regardless of which pane you're looking at.
        .background(shelf.flattenedColor(opacity: 0.22))
        .safeAreaInset(edge: .bottom) {
            Button {
                isShowingAddRecipe = true
            } label: {
                Label("Add Recipe", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .sheet(isPresented: $isShowingAddRecipe) {
            AddRecipeSheet()
        }
        .sheet(item: $selectedRecipe) { recipe in
            RecipeDetailView(recipe: recipe)
        }
    }

    private func deleteRecipes(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(recipes[index])
        }
    }
}

/// Add a recipe either by pointing `RecipeImportService` at a URL (pulls
/// title/ingredients/instructions straight off the page) or by typing
/// everything in by hand — a segmented picker up top switches which.
struct AddRecipeSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    private enum Mode: String, CaseIterable {
        case url = "From URL"
        case pasteText = "Paste Text"
        case manual = "Manual"
    }

    @State private var mode: Mode = .url
    @State private var urlText = ""
    @State private var isImporting = false
    @State private var errorMessage: String?
    /// What a lot of recipe apps' own "Share" action hands you instead of
    /// a real URL — title/ingredients/steps as plain text, plus their own
    /// attribution footer. "Parse" runs `RecipeImportService
    /// .parseRecipe(fromPastedText:)` and lands the result in the Manual
    /// fields below for a look before Save, rather than inserting it
    /// straight away like the URL import does — free-text parsing is
    /// heuristic, so it's worth a glance first.
    @State private var pastedText = ""

    @State private var title = ""
    @State private var ingredientsText = ""
    @State private var instructions = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Add via", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.clear)

                switch mode {
                case .url:
                    Section {
                        TextField("https://...", text: $urlText)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button {
                            importFromURL()
                        } label: {
                            if isImporting {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("Import")
                            }
                        }
                        .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty || isImporting)
                    } header: {
                        Text("Recipe URL")
                    } footer: {
                        Text("Pulls the title, ingredients, and instructions straight off the page, when the site publishes them in a standard recipe format.")
                    }
                case .pasteText:
                    Section {
                        TextField("Paste a shared recipe here", text: $pastedText, axis: .vertical)
                            .lineLimit(8...20)
                        Button("Parse", action: parsePastedText)
                            .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } header: {
                        Text("Pasted Recipe")
                    } footer: {
                        Text("For apps whose Share action gives you plain text instead of a link — Parse fills in the Manual fields below so you can check it before saving.")
                    }
                case .manual:
                    Section("Title") {
                        TextField("Recipe name", text: $title)
                    }
                    Section("Ingredients") {
                        TextField("One ingredient per line", text: $ingredientsText, axis: .vertical)
                            .lineLimit(4...10)
                    }
                    Section("Instructions") {
                        TextField("Steps", text: $instructions, axis: .vertical)
                            .lineLimit(6...20)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if mode == .manual {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Save", action: saveManual)
                            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private func importFromURL() {
        errorMessage = nil
        isImporting = true
        Task {
            do {
                let recipe = try await RecipeImportService.shared.importRecipe(from: urlText)
                modelContext.insert(recipe)
                isImporting = false
                dismiss()
            } catch {
                isImporting = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func parsePastedText() {
        guard let recipe = RecipeImportService.parseRecipe(fromPastedText: pastedText) else {
            errorMessage = "Couldn't make sense of that. Try Manual instead."
            return
        }
        errorMessage = nil
        title = recipe.title
        ingredientsText = recipe.ingredients.joined(separator: "\n")
        instructions = recipe.instructions
        mode = .manual
    }

    private func saveManual() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        let ingredients = ingredientsText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        modelContext.insert(Recipe(title: trimmedTitle, ingredients: ingredients, instructions: instructions))
        dismiss()
    }
}

/// View/edit an existing recipe — every field writes straight through to
/// the model live, same convention as a task card.
struct RecipeDetailView: View {
    @Bindable var recipe: Recipe
    @Environment(\.dismiss) private var dismiss
    @State private var ingredientsText: String

    init(recipe: Recipe) {
        self.recipe = recipe
        _ingredientsText = State(initialValue: recipe.ingredients.joined(separator: "\n"))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Recipe name", text: $recipe.title)
                }
                Section("Ingredients") {
                    TextField("One ingredient per line", text: $ingredientsText, axis: .vertical)
                        .lineLimit(4...15)
                        .onChange(of: ingredientsText) { _, newValue in
                            recipe.ingredients = newValue
                                .split(separator: "\n", omittingEmptySubsequences: true)
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty }
                        }
                }
                Section("Instructions") {
                    TextField("Steps", text: $recipe.instructions, axis: .vertical)
                        .lineLimit(6...30)
                }
                if let url = recipe.sourceURL {
                    Section {
                        Link("View Original Recipe", destination: url)
                    }
                }
            }
            .navigationTitle(recipe.title.isEmpty ? "Recipe" : recipe.title)
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
    CookbookView(shelf: Shelf(name: "The Kitchen", systemImage: "refrigerator"))
        .modelContainer(for: [Shelf.self, Recipe.self], inMemory: true)
}
