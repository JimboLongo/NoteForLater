import Foundation

/// Extracts a leading quantity + unit from a raw recipe ingredient line
/// ("3 tbsp unsalted butter, softened") and normalizes units so different
/// recipes' phrasing of the same unit compare equal. Pure string logic —
/// no SwiftData/SwiftUI — same shape as `ReceiptLineParser`.
enum RecipeIngredientParser {
    /// `quantity`/`unit` are both `nil` when the line has no parseable
    /// leading amount at all ("Salt and pepper to taste") — `name` is
    /// still the whole line in that case, just with nothing to deduct.
    /// `unit == nil` with a non-nil `quantity` means a bare count ("2
    /// large eggs"), not a parse failure — there's no seventh unit that
    /// means "just a number," it's the natural nil case.
    struct ParsedIngredient: Equatable {
        let quantity: Double?
        let unit: String?
        let name: String
    }

    /// Every spelling variant that should normalize to each canonical
    /// unit — built into a flat alias -> canonical lookup below.
    private static let unitVariants: [String: [String]] = [
        "tbsp": ["tbsp", "tbsps", "tablespoon", "tablespoons", "tbs"],
        "tsp": ["tsp", "tsps", "teaspoon", "teaspoons"],
        "oz": ["oz", "ozs", "ounce", "ounces"],
        "cup": ["cup", "cups"],
        "lb": ["lb", "lbs", "pound", "pounds"],
        "g": ["g", "gram", "grams"],
        "ml": ["ml", "milliliter", "milliliters", "millilitre", "millilitres"]
    ]

    private static let unitAliases: [String: String] = {
        var map: [String: String] = [:]
        for (canonical, aliases) in unitVariants {
            for alias in aliases {
                map[alias] = canonical
            }
        }
        return map
    }()

    /// Base-unit conversion factors — volume to milliliters, weight to
    /// grams. The two systems are never bridged (see `convert`).
    private static let volumeToMl: [String: Double] = ["tsp": 4.92892, "tbsp": 14.7868, "cup": 236.588, "ml": 1.0]
    private static let weightToGrams: [String: Double] = ["oz": 28.3495, "lb": 453.592, "g": 1.0]

    private static let unicodeFractions: [Character: Double] = [
        "½": 0.5, "¼": 0.25, "¾": 0.75,
        "⅓": 1.0 / 3.0, "⅔": 2.0 / 3.0,
        "⅛": 0.125, "⅜": 0.375, "⅝": 0.625, "⅞": 0.875
    ]

    /// Matches a leading quantity, in priority order: a mixed number with
    /// a slash fraction ("1 1/2"), a bare slash fraction ("1/2"), a whole
    /// number directly followed by a Unicode fraction glyph ("1½"), a bare
    /// Unicode glyph ("½"), or a plain integer/decimal ("2", "1.5").
    /// Order matters — matching the plain-number case first would grab
    /// just the "1" out of "1 1/2" and leave " 1/2 cups" as part of the
    /// name instead of the quantity.
    private static let quantityRegex = try? NSRegularExpression(
        pattern: #"^(\d+\s+\d+/\d+|\d+/\d+|\d+[½¼¾⅓⅔⅛⅜⅝⅞]|[½¼¾⅓⅔⅛⅜⅝⅞]|\d+(?:\.\d+)?)\s*"#
    )

    static func parse(_ rawLine: String) -> ParsedIngredient {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = quantityRegex,
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range, in: line) else {
            return ParsedIngredient(quantity: nil, unit: nil, name: line)
        }

        let quantityText = String(line[range]).trimmingCharacters(in: .whitespaces)
        guard let quantity = parseQuantityText(quantityText) else {
            return ParsedIngredient(quantity: nil, unit: nil, name: line)
        }

        let remainder = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        let (unit, name) = extractUnit(from: remainder)
        return ParsedIngredient(quantity: quantity, unit: unit, name: name)
    }

    /// Turns whatever `quantityRegex` matched into a `Double` — the regex
    /// only ever matches shapes this can handle, so this never needs to
    /// fail on well-formed input, but returns `nil` defensively rather
    /// than force-unwrap.
    private static func parseQuantityText(_ text: String) -> Double? {
        if text.contains(" "), text.contains("/") {
            let parts = text.split(separator: " ")
            guard parts.count == 2, let whole = Double(parts[0]), let frac = parseFraction(String(parts[1])) else { return nil }
            return whole + frac
        }
        if text.contains("/") {
            return parseFraction(text)
        }
        if let lastChar = text.last, let fracValue = unicodeFractions[lastChar] {
            let wholePart = String(text.dropLast())
            guard !wholePart.isEmpty else { return fracValue }
            guard let whole = Double(wholePart) else { return nil }
            return whole + fracValue
        }
        return Double(text)
    }

    private static func parseFraction(_ text: String) -> Double? {
        let parts = text.split(separator: "/")
        guard parts.count == 2, let numerator = Double(parts[0]), let denominator = Double(parts[1]), denominator != 0 else { return nil }
        return numerator / denominator
    }

    /// Splits `remainder` into (unit, name) — the first word is checked
    /// against `unitAliases`; a match consumes it as the unit and leaves
    /// the rest as the name. No match means the whole remainder is the
    /// name and there's no unit — the bare-count case ("2 large eggs").
    private static func extractUnit(from remainder: String) -> (unit: String?, name: String) {
        guard let spaceIndex = remainder.firstIndex(of: " ") else {
            let word = remainder.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if let canonical = unitAliases[word] {
                return (canonical, "")
            }
            return (nil, remainder)
        }
        let firstWord = remainder[remainder.startIndex..<spaceIndex].lowercased().trimmingCharacters(in: .punctuationCharacters)
        if let canonical = unitAliases[firstWord] {
            let rest = remainder[remainder.index(after: spaceIndex)...].trimmingCharacters(in: .whitespaces)
            return (canonical, rest)
        }
        return (nil, remainder)
    }

    /// Converts `quantity` from `fromUnit` to `toUnit` — only within the
    /// same measurement system (volume<->volume via ml, weight<->weight
    /// via g). Returns `nil` across systems (e.g. cup -> g) or when either
    /// side isn't a recognized unit — deliberately never guessed, since a
    /// volume<->weight conversion needs an ingredient-specific density
    /// (flour, sugar, and butter each pack to a different weight per cup)
    /// this app has no data for.
    static func convert(_ quantity: Double, from fromUnit: String, to toUnit: String) -> Double? {
        if fromUnit == toUnit { return quantity }
        if let fromMl = volumeToMl[fromUnit], let toMl = volumeToMl[toUnit] {
            return quantity * fromMl / toMl
        }
        if let fromG = weightToGrams[fromUnit], let toG = weightToGrams[toUnit] {
            return quantity * fromG / toG
        }
        return nil
    }
}
