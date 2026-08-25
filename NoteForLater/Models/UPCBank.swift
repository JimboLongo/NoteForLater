import Foundation
import SwiftData

/// A user-taught UPC-to-product mapping, for a barcode Open Food Facts
/// doesn't know about — built up one manual correction at a time via
/// `UnmatchedUPCsEditorView`, and checked before ever reaching for the
/// network (see `UPCLookupService`), so the same UPC never needs a
/// second manual entry once it's been taught once.
@Model
final class UPCBank {
    var id: UUID
    /// The lookup key. `.unique` is a real SwiftData constraint, not
    /// just a naming convention — inserting a second `UPCBank` for a UPC
    /// already banked updates the existing row instead of creating a
    /// duplicate, which matters since `UnmatchedUPCsEditorView` has no
    /// other way to know a code was already taught in an earlier session.
    @Attribute(.unique) var upc: String
    var name: String
    var brand: String?
    var size: String?
    var addedDate: Date

    init(upc: String, name: String, brand: String? = nil, size: String? = nil, addedDate: Date = .now) {
        self.id = UUID()
        self.upc = upc
        self.name = name
        self.brand = brand
        self.size = size
        self.addedDate = addedDate
    }
}
