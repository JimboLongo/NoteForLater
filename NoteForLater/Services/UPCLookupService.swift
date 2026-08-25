import Foundation
import SwiftData

/// Checks the user-taught `UPCBank` before ever reaching for Open Food
/// Facts — a UPC manually entered once (via `UnmatchedUPCsEditorView`)
/// resolves instantly and offline from then on, with no repeat network
/// lookup for a code Open Food Facts already told us it doesn't know.
///
/// Both functions take `modelContext` explicitly rather than reading one
/// implicitly — there's no ambient/global `ModelContext` outside a
/// SwiftUI view's own `@Environment` to reach for, the same reason
/// `SharedModelContainer` exists for this app's other non-view call
/// sites.
enum UPCLookupService {
    /// Pure SwiftData read, no network — `nil` for a UPC never taught to
    /// the bank.
    static func checkUPCBank(upc: String, in modelContext: ModelContext) -> OpenFoodFactsService.ProductInfo? {
        let descriptor = FetchDescriptor<UPCBank>(predicate: #Predicate { $0.upc == upc })
        guard let entry = try? modelContext.fetch(descriptor).first else { return nil }
        return OpenFoodFactsService.ProductInfo(name: entry.name, brand: entry.brand, size: entry.size)
    }

    /// Bank first, Open Food Facts second — a manually-taught entry is
    /// authoritative (the user corrected it for a reason) and free, so
    /// there's no reason to also spend a network round-trip re-confirming
    /// it. This is the simple two-outcome form `BarcodeScannerView` and
    /// `ReceiptImportView` already use via `OpenFoodFactsService
    /// .lookupProductInfo` — `ReceiptOCRScannerView` checks the bank
    /// separately instead of through this, since it needs to keep its
    /// own rate-limit-aware `lookupProductInfoDetailed` path for anything
    /// not already banked.
    static func lookupProductInfo(upc: String, in modelContext: ModelContext) async -> OpenFoodFactsService.ProductInfo? {
        if let banked = checkUPCBank(upc: upc, in: modelContext) {
            return banked
        }
        return await OpenFoodFactsService.lookupProductInfo(upc: upc)
    }
}
