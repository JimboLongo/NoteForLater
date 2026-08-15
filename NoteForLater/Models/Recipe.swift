import Foundation
import SwiftData

/// A Cookbook entry — the Kitchen shelf's other pane, alongside Pantry.
/// Added either by hand or by pointing `RecipeImportService` at a URL,
/// which pulls the title/ingredients/instructions straight off the page's
/// own schema.org Recipe markup.
@Model
final class Recipe {
    var id: UUID
    var title: String
    var ingredients: [String]
    var instructions: String
    /// Kept as a plain string (not `URL`) since SwiftData needs a
    /// straightforwardly codable stored type — `sourceURL` below converts
    /// it back on demand.
    var sourceURLString: String?
    var imageURLString: String?
    var createdAt: Date

    init(
        title: String,
        ingredients: [String] = [],
        instructions: String = "",
        sourceURLString: String? = nil,
        imageURLString: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = UUID()
        self.title = title
        self.ingredients = ingredients
        self.instructions = instructions
        self.sourceURLString = sourceURLString
        self.imageURLString = imageURLString
        self.createdAt = createdAt
    }

    var sourceURL: URL? {
        sourceURLString.flatMap(URL.init(string:))
    }
}
