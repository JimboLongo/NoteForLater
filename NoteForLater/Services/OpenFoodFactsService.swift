import Foundation

/// Looks up a product's name from its UPC via the free, keyless Open Food
/// Facts API — used by `ReceiptImportView` to turn a barcode `ReceiptLineParser
/// .upc(in:)` found on a receipt line into a real product name, instead of
/// (or before) falling back to that line's own OCR text.
enum OpenFoodFactsService {
    /// `https://world.openfoodfacts.org/api/v0/product/{upc}.json`'s shape:
    /// `status == 1` means found, with a `product` object; `status == 0`
    /// means not found, and `product` is typically absent entirely.
    private struct Response: Decodable {
        let status: Int
        let product: Product?

        struct Product: Decodable {
            let productName: String?
            enum CodingKeys: String, CodingKey {
                case productName = "product_name"
            }
        }
    }

    /// Pure — no network, no `throws`. This is the seam tests use: hand it
    /// bytes shaped like a real response (found, not-found, or garbage)
    /// and check what comes back, without touching the network at all.
    /// Returns `nil` for anything short of "found, with a real name" —
    /// `status == 0`, a missing/blank `product_name`, or JSON that doesn't
    /// decode at all are all the same "no answer" to the caller.
    static func parseProductName(from data: Data) -> String? {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        guard response.status == 1 else { return nil }
        let name = response.product?.productName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty else { return nil }
        return name
    }

    /// A short request timeout of its own, separate from the shared
    /// session's default — a receipt can have a couple dozen lines, each
    /// firing its own lookup (see `ReceiptImportView.scan(_:)`'s
    /// `withTaskGroup`), and one slow/hanging line shouldn't hold up the
    /// whole scan for as long as `URLSession.shared`'s much longer default
    /// would let it.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        return URLSession(configuration: configuration)
    }()

    /// Never throws — every failure mode (malformed UPC never reaches
    /// here in practice since `ReceiptLineParser.upc(in:)` already
    /// constrains the shape, but a right-length non-product code, a
    /// timeout, no connectivity, or a decode failure) collapses to the
    /// same `nil`, which is exactly the one signal `ReceiptImportView`
    /// needs to fall back to `ReceiptLineParser.cleanedItemName` instead.
    static func lookupProductName(upc: String) async -> String? {
        guard let url = URL(string: "https://world.openfoodfacts.org/api/v0/product/\(upc).json") else { return nil }
        guard let (data, response) = try? await session.data(from: url) else { return nil }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
        return parseProductName(from: data)
    }
}
