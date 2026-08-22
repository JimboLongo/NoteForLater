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

    /// Open Food Facts' own API docs ask anonymous clients to identify
    /// themselves with a descriptive `User-Agent` rather than whatever
    /// generic one `URLSession` sends by default — an unidentified client
    /// is exactly what their rate limiter treats least generously, which
    /// is what turned a receipt with a couple dozen UPCs into a cascade
    /// of HTTP 429s (see the diag logging this call site added earlier).
    private static let userAgent = "NoteForLater/1.0 (+https://github.com/JimboLongo/NoteForLater)"

    /// The three genuinely different things a lookup can come back with —
    /// distinct from a bare `ProductInfo?` specifically so a caller can
    /// tell "this UPC isn't a real product" apart from "we don't know yet,
    /// Open Food Facts turned us away for going too fast." Conflating
    /// those two into the same `nil` is what let a transient HTTP 429
    /// permanently poison `ReceiptOCRScannerView`'s per-UPC cache as if
    /// the product genuinely didn't exist.
    enum LookupOutcome {
        case found(ProductInfo)
        case notFound
        case rateLimited
    }

    /// Every path — success and each distinct failure — writes to
    /// `DiagFileLog`, temporarily, to debug real UPCs coming back red in
    /// the receipt scanner despite looking like valid product codes.
    /// `parseProductInfo` alone can't explain a failure like that (it's
    /// pure and already covered by tests against hand-built JSON) — what's
    /// actually in question is what Open Food Facts' live API returns for
    /// these specific codes, which only a real request against it can show.
    ///
    /// `await requestRateLimiter.acquire()` gates every request through a
    /// single, session-wide pace (see `RequestRateLimiter`) — the
    /// `User-Agent` header alone wasn't enough to stop the 429 cascade
    /// during a continuous multi-second OCR scan, since nothing was
    /// actually capping how many requests per *second* left the device in
    /// total, only how many any one call site fired at once.
    static func lookupProductInfoDetailed(upc: String) async -> LookupOutcome {
        guard let url = URL(string: "https://world.openfoodfacts.org/api/v0/product/\(upc).json") else {
            DiagFileLog.write("OpenFoodFacts upc=\(upc): invalid URL")
            return .notFound
        }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        await requestRateLimiter.acquire()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            let timedOut = (error as? URLError)?.code == .timedOut
            DiagFileLog.write("OpenFoodFacts upc=\(upc): request failed, timedOut=\(timedOut), error=\(error.localizedDescription)")
            return .notFound
        }

        guard let http = response as? HTTPURLResponse else {
            DiagFileLog.write("OpenFoodFacts upc=\(upc): non-HTTP response")
            return .notFound
        }
        if http.statusCode == 429 {
            DiagFileLog.write("OpenFoodFacts upc=\(upc): HTTP 429, rate limited")
            return .rateLimited
        }
        guard (200...299).contains(http.statusCode) else {
            DiagFileLog.write("OpenFoodFacts upc=\(upc): HTTP \(http.statusCode), body=\(Self.truncatedBody(data))")
            return .notFound
        }

        guard let info = parseProductInfo(from: data) else {
            DiagFileLog.write("OpenFoodFacts upc=\(upc): HTTP \(http.statusCode) but parse failed, body=\(Self.truncatedBody(data))")
            return .notFound
        }

        DiagFileLog.write("OpenFoodFacts upc=\(upc): found name=\(info.name) brand=\(info.brand ?? "nil") size=\(info.size ?? "nil")")
        return .found(info)
    }

    /// The simple form every caller but `ReceiptOCRScannerView` actually
    /// wants — `BarcodeScannerView` and `ReceiptImportView` both only ever
    /// needed "did this resolve," never the rate-limited/not-found
    /// distinction, so they're left on this unchanged rather than made to
    /// handle a three-case outcome they have no use for.
    static func lookupProductInfo(upc: String) async -> ProductInfo? {
        if case .found(let info) = await lookupProductInfoDetailed(upc: upc) {
            return info
        }
        return nil
    }

    /// Capped so one absurdly large product entry (a long ingredients
    /// list, embedded image URLs) doesn't dominate the diag log — 3000
    /// characters is enough to see `status`, `product_name`, `brands`,
    /// and `quantity` even in a large real response.
    private static func truncatedBody(_ data: Data, limit: Int = 3000) -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            return "<non-UTF8 body, \(data.count) bytes>"
        }
        guard text.count > limit else { return text }
        return "\(text.prefix(limit))... [truncated, \(text.count) chars total]"
    }

    /// One process-wide limiter shared by every call to
    /// `lookupProductInfoDetailed` — 2 requests/second, conservative
    /// enough that a full receipt's worth of UPCs trickles out over
    /// several seconds instead of firing all at once, which is what
    /// tripped Open Food Facts' own limiter in the first place.
    private static let requestRateLimiter = RequestRateLimiter(maxTokens: 2, refillInterval: .milliseconds(500))

    /// A token-bucket rate limiter: `maxTokens` requests can fire
    /// immediately, then one more token becomes available every
    /// `refillInterval` — the same shape as the `DispatchSemaphore`
    /// token-bucket originally asked for, but built as an `actor` with
    /// `await`ed continuations instead.
    ///
    /// `DispatchSemaphore.wait()` blocks whatever thread calls it until a
    /// token is free; called from inside `async` code (as every caller
    /// here is), that ties up one of Swift Concurrency's small, fixed
    /// pool of cooperative threads for however long the rate limiter
    /// makes it wait — the exact same risk already flagged and avoided
    /// for the per-frame concurrency cap, just relocated to this new
    /// choke point instead of removed. An actor lets a caller `await
    /// acquire()` and have its `Task` suspend with no thread held at all,
    /// so a receipt with two dozen queued-up lookups doesn't leave two
    /// dozen threads blocked while they wait their turn.
    private actor RequestRateLimiter {
        private var availableTokens: Int
        private let maxTokens: Int
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(maxTokens: Int, refillInterval: Duration) {
            self.maxTokens = maxTokens
            self.availableTokens = maxTokens
            Task { [weak self] in
                while true {
                    try? await Task.sleep(for: refillInterval)
                    guard let self else { return }
                    await self.refillOneToken()
                }
            }
        }

        /// Suspends until a token is available, then consumes it —
        /// callers never see a thread blocked, just their own `Task`
        /// paused until `refillOneToken` hands them a continuation.
        func acquire() async {
            if availableTokens > 0 {
                availableTokens -= 1
                return
            }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        private func refillOneToken() {
            guard availableTokens < maxTokens else { return }
            if let next = waiters.first {
                // Handed straight to the oldest waiter rather than
                // incrementing `availableTokens` and letting it sit —
                // otherwise a fresh `acquire()` call from a *different*
                // task could race in and grab this token ahead of
                // whoever has been waiting longest.
                waiters.removeFirst()
                next.resume()
            } else {
                availableTokens += 1
            }
        }
    }
}
