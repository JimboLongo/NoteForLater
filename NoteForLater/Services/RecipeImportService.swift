import Foundation

enum RecipeImportError: Error, LocalizedError {
    case invalidURL
    case fetchFailed
    case noRecipeFound

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "That doesn't look like a valid URL."
        case .fetchFailed: return "Couldn't load that page."
        case .noRecipeFound: return "Couldn't find a recipe on that page. Try adding it manually instead."
        }
    }
}

/// Pulls a recipe's title/ingredients/instructions out of a URL by reading
/// the page's own schema.org Recipe JSON-LD
/// (`<script type="application/ld+json">`) — the same structured data
/// virtually every modern recipe site (AllRecipes, NYT Cooking, Serious
/// Eats, most food blogs via plugins like WP Recipe Maker) already embeds
/// for Google's recipe rich results, so this works across sites without a
/// site-specific scraper or any third-party dependency.
final class RecipeImportService {
    static let shared = RecipeImportService()
    private init() {}

    func importRecipe(from urlString: String) async throws -> Recipe {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme, scheme.hasPrefix("http") else {
            throw RecipeImportError.invalidURL
        }

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(from: url)
        } catch {
            throw RecipeImportError.fetchFailed
        }

        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw RecipeImportError.fetchFailed
        }

        guard let recipe = Self.parseRecipe(fromHTML: html, sourceURL: trimmed) else {
            throw RecipeImportError.noRecipeFound
        }
        return recipe
    }

    /// Scans every `application/ld+json` block for a schema.org Recipe —
    /// either the object itself, one entry in a top-level array, or one
    /// entry inside an `@graph` array (all three shapes show up in the
    /// wild depending on which JSON-LD library the site used).
    static func parseRecipe(fromHTML html: String, sourceURL: String) -> Recipe? {
        for jsonString in jsonLDBlocks(in: html) {
            guard let data = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            for candidate in recipeCandidates(in: json) {
                if let recipe = recipe(from: candidate, sourceURL: sourceURL) {
                    return recipe
                }
            }
        }
        return nil
    }

    private static func jsonLDBlocks(in html: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: "<script[^>]+type=[\"']application/ld\\+json[\"'][^>]*>(.*?)</script>",
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else { return [] }

        let nsrange = NSRange(html.startIndex..<html.endIndex, in: html)
        var blocks: [String] = []
        regex.enumerateMatches(in: html, range: nsrange) { match, _, _ in
            guard let match, let range = Range(match.range(at: 1), in: html) else { return }
            blocks.append(String(html[range]))
        }
        return blocks
    }

    /// Flattens the object/array/`@graph` shapes down to a list of
    /// candidate dictionaries to check for `@type == "Recipe"`.
    private static func recipeCandidates(in json: Any) -> [[String: Any]] {
        if let dict = json as? [String: Any] {
            var candidates = [dict]
            if let graph = dict["@graph"] as? [[String: Any]] {
                candidates.append(contentsOf: graph)
            }
            return candidates
        }
        if let array = json as? [[String: Any]] {
            return array
        }
        return []
    }

    private static func recipe(from dict: [String: Any], sourceURL: String) -> Recipe? {
        let type = dict["@type"]
        let isRecipe: Bool
        if let typeString = type as? String {
            isRecipe = typeString == "Recipe"
        } else if let typeArray = type as? [String] {
            isRecipe = typeArray.contains("Recipe")
        } else {
            isRecipe = false
        }
        guard isRecipe else { return nil }

        let title = (dict["name"] as? String) ?? "Untitled Recipe"
        let ingredients = (dict["recipeIngredient"] as? [String]) ?? []
        let instructions = parseInstructions(dict["recipeInstructions"])
        let imageURLString = parseImage(dict["image"])

        return Recipe(
            title: title,
            ingredients: ingredients,
            instructions: instructions,
            sourceURLString: sourceURL,
            imageURLString: imageURLString
        )
    }

    /// `recipeInstructions` shows up as a plain string, an array of
    /// strings, or (most commonly) an array of HowToStep objects with
    /// their own `text` field — normalized here into one numbered block.
    private static func parseInstructions(_ value: Any?) -> String {
        if let text = value as? String {
            return text
        }
        if let steps = value as? [Any] {
            let lines = steps.enumerated().compactMap { index, step -> String? in
                if let text = step as? String {
                    return "\(index + 1). \(text)"
                }
                if let dict = step as? [String: Any], let text = dict["text"] as? String {
                    return "\(index + 1). \(text)"
                }
                return nil
            }
            return lines.joined(separator: "\n")
        }
        return ""
    }

    /// `image` shows up as a plain URL string, an array of them, or an
    /// ImageObject with its own `url` field.
    private static func parseImage(_ value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let array = value as? [Any] {
            return parseImage(array.first)
        }
        if let dict = value as? [String: Any] {
            return dict["url"] as? String
        }
        return nil
    }

    /// Parses a recipe pasted as plain text — the shape most recipe
    /// apps' own "Share" action produces when they don't hand you a real
    /// URL (title, blank line, one ingredient per line, blank line,
    /// numbered instructions, an app-attribution footer like "Shared
    /// from CookBook" plus its own homepage link) — rather than the
    /// structured schema.org markup `importRecipe(from:)` reads off a
    /// real web page.
    static func parseRecipe(fromPastedText text: String) -> Recipe? {
        var lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        // Strip a trailing "Shared from ..." attribution line and
        // whatever bare app-homepage URL follows it.
        while let last = lines.last,
              last.isEmpty || last.lowercased().hasPrefix("shared from") || last.lowercased().hasPrefix("http") {
            lines.removeLast()
        }

        guard let titleIndex = lines.firstIndex(where: { !$0.isEmpty }) else { return nil }
        let title = lines[titleIndex]
        let remaining = Array(lines[(titleIndex + 1)...])

        guard let firstStepIndex = remaining.firstIndex(where: isNumberedStepLine) else {
            // No numbered steps found — treat whatever's left as
            // ingredients rather than failing outright.
            let ingredients = remaining.filter { !$0.isEmpty }
            guard !ingredients.isEmpty else { return nil }
            return Recipe(title: title, ingredients: ingredients, instructions: "")
        }

        let ingredients = remaining[..<firstStepIndex].filter { !$0.isEmpty }

        // A step's own text can wrap across multiple lines in the pasted
        // text — anything that isn't itself a new "N. " line gets folded
        // onto the previous step instead of becoming its own line.
        var instructionLines: [String] = []
        for line in remaining[firstStepIndex...] where !line.isEmpty {
            if isNumberedStepLine(line) {
                instructionLines.append(line)
            } else if !instructionLines.isEmpty {
                instructionLines[instructionLines.count - 1] += " " + line
            }
        }

        return Recipe(title: title, ingredients: Array(ingredients), instructions: instructionLines.joined(separator: "\n"))
    }

    private static let numberedStepRegex = try? NSRegularExpression(pattern: "^\\d+\\.\\s+")

    private static func isNumberedStepLine(_ line: String) -> Bool {
        guard let regex = numberedStepRegex else { return false }
        return regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }
}
