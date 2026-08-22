import Foundation

/// Turns raw OCR'd receipt text lines into candidate pantry item names —
/// pure string logic, no Vision/UIKit types, so it's unit-testable
/// independent of actually running OCR. Receipts are messy (prices, tax
/// lines, payment method, store boilerplate), so this is inherently a
/// heuristic, not a guarantee — the caller shows the result as a
/// checkable preview list rather than importing it blind.
enum ReceiptLineParser {
    /// Lines containing any of these (case-insensitive) are receipt
    /// boilerplate, not purchased items.
    private static let nonItemKeywords = [
        "subtotal", "total", "sales tax", " tax ", "cash", "change due",
        "debit", "credit", "visa", "mastercard", "amex", "discover",
        "balance", "tender", "approved", "auth code", "ref #", "ref#",
        "card #", "card#", "receipt", "thank you", "cashier", "store #",
        "member", "savings", "coupon", "www.", ".com", "survey"
    ]

    /// Every non-empty cleaned line from `lines`, in order.
    static func candidateItems(from lines: [String]) -> [String] {
        lines.compactMap(cleanedItemName)
    }

    /// Strips a trailing price (e.g. "2.99", "$2.99", "2.99 T") and a
    /// leading UPC/SKU-style numeric code, then filters out anything left
    /// that doesn't look like a purchasable item name — pure punctuation,
    /// pure digits, or known boilerplate.
    static func cleanedItemName(from rawLine: String) -> String? {
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }

        let lowercased = line.lowercased()
        guard !nonItemKeywords.contains(where: { lowercased.contains($0) }) else { return nil }

        if let range = line.range(of: #"\$?\d+\.\d{2}\s*[A-Za-z]?$"#, options: .regularExpression) {
            line.removeSubrange(range)
            line = line.trimmingCharacters(in: .whitespaces)
        }

        if let range = line.range(of: #"^\d{6,}\s+"#, options: .regularExpression) {
            line.removeSubrange(range)
            line = line.trimmingCharacters(in: .whitespaces)
        }

        guard line.count > 1, line.contains(where: { $0.isLetter }) else { return nil }
        return line
    }

    /// The first UPC-length digit run anywhere in `rawLine`, or `nil` if
    /// none exists — the digit run `cleanedItemName` above strips as noise
    /// from the *start* of a line, kept here instead so the caller can try
    /// an Open Food Facts lookup before falling back to that stripping.
    /// 8–12 digits covers UPC-A (12) and EAN-8 (8); a 13-digit EAN-13
    /// barcode is out of this range by design — it falls through to the
    /// usual line-parsing path instead of a lookup, same as any other line
    /// with no matching digit run.
    ///
    /// Searched across the whole line, not just a leading anchor —
    /// `cleanedItemName`'s stripping regex only looks at the start because
    /// that's the one shape it needs to remove, but a printed barcode can
    /// sit anywhere in a line (or alone on its own line) depending on the
    /// receipt format.
    static func upc(in rawLine: String) -> String? {
        guard let range = rawLine.range(of: #"\b\d{8,12}\b"#, options: .regularExpression) else { return nil }
        return String(rawLine[range])
    }
}
