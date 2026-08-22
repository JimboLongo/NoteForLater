import Foundation

/// Looks up a product's name, brand, and size from its UPC via the free,
/// keyless Open Food Facts API — used by `ReceiptImportView` to turn a
/// barcode `ReceiptLineParser.upc(in:)` found on a receipt line into real
/// product info, instead of (or before) falling back to that line's own
/// OCR text.
enum OpenFoodFactsService {
    /// What a receipt row actually shows once identified by barcode.
    /// `brand`/`size` are independently optional — Open Food Facts'
    /// catalog entries are user-contributed, and either field is commonly
    /// missing even when `name` itself is present.
    struct ProductInfo: Equatable {
        let name: String
        let brand: String?
        let size: String?
    }

    /// `https://world.openfoodfacts.org/api/v0/product/{upc}.json`'s shape:
    /// `status == 1` means found, with a `product` object; `status == 0`
    /// means not found, and `product` is typically absent entirely.
    /// `brands` is a comma-separated string when a product lists more than
    /// one brand (co-manufactured/private-label products, mostly);
    /// `quantity` is Open Food Facts' own field for what this app calls
    /// "size" — free text ("16 oz", "500 g"), not a separate number+unit.
    private struct Response: Decodable {
        let status: Int
        let product: Product?

        struct Product: Decodable {
            let productName: String?
            let brands: String?
            let quantity: String?
            enum CodingKeys: String, CodingKey {
                case productName = "product_name"
                case brands
                case quantity
            }
        }
    }

    /// Pure — no network, no `throws`. This is the seam tests use: hand it
    /// bytes shaped like a real response (found, not-found, or garbage)
    /// and check what comes back, without touching the network at all.
    /// Requires a non-blank name to count as a real find; `brand`/`size`
    /// are independently nil-able and never block a successful parse on
    /// their own — `status == 0`, a missing/blank `product_name`, or JSON
    /// that doesn't decode at all are the only things that produce `nil`
    /// overall.
    static func parseProductInfo(from data: Data) -> ProductInfo? {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        guard response.status == 1 else { return nil }
        guard let name = nonBlank(response.product?.productName) else { return nil }

        // Only the first brand — a receipt row has room for one name, not
        // a full co-manufacturer list.
        let firstBrand = response.product?.brands?.split(separator: ",", maxSplits: 1).first.map(String.init)
        let brand = nonBlank(firstBrand)
        let size = nonBlank(response.product?.quantity)

        return ProductInfo(name: name, brand: brand, size: size)
    }

    /// Trims and collapses a blank result to `nil` — shared by every field
    /// above so "present but empty/whitespace-only" is treated the same
    /// as "absent" everywhere, not just for `name`.
    private static func nonBlank(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
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
    static func lookupProductInfo(upc: String) async -> ProductInfo? {
        guard let url = URL(string: "https://world.openfoodfacts.org/api/v0/product/\(upc).json") else { return nil }
        guard let (data, response) = try? await session.data(from: url) else { return nil }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
        return parseProductInfo(from: data)
    }
}
