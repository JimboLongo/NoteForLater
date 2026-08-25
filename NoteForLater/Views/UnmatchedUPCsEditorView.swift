import SwiftUI
import SwiftData

/// Shown after "Done Scanning" whenever at least one UPC never resolved
/// to a real product — every UPC from the scan is shown here, though,
/// not just the unmatched ones: an already-matched line is displayed
/// read-only in its own original scan position (see
/// `ReceiptOCRScannerView.upcOrder`), so it's obvious which specific
/// lines were missed relative to what actually succeeded, rather than a
/// bare list of failures with no receipt context around them.
///
/// A saved unmatched entry goes into `UPCBank`, so the exact same UPC
/// resolves instantly next time instead of needing this same manual
/// step again.
struct UnmatchedUPCsEditorView: View {
    let orderedUPCs: [String]
    let foundInfo: [String: OpenFoodFactsService.ProductInfo]
    /// Called once, when either toolbar action is tapped, with a
    /// `ReceiptCandidate` for every *originally unmatched* row the user
    /// actually filled in — a row left blank is simply skipped, not
    /// forced to be completed, same "uncheck/ignore what doesn't apply"
    /// convention `ReceiptImportView`'s own review list already follows.
    /// Never includes an already-matched row's candidate — that one is
    /// already sitting in `ReceiptOCRScannerView.candidates` from
    /// `handleFrame`, so returning it here too would duplicate it.
    /// "Skip All" calls this with an empty array rather than skipping
    /// the call entirely, so the caller can still move on to whatever
    /// candidates it already had.
    let onFinish: ([ReceiptCandidate]) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row]

    private struct Row: Identifiable {
        let id = UUID()
        var upc: String
        /// Fixed at row creation — an already-matched row stays read-only
        /// display for its whole time in this sheet regardless of
        /// anything else changing around it.
        let isMatched: Bool
        var name = ""
        var brand = ""
        var size = ""
        var isLookingUp = false
        /// The UPC value a lookup has already been fired for — guards
        /// `attemptAutoPopulate` against re-querying the same corrected
        /// code twice if `.onChange` happens to fire again with no real
        /// change (or the user retypes back to a value already tried).
        var lastLookedUpUPC: String?
        /// True when this row's *current* UPC equals another row's own
        /// UPC that's already matched — almost always means the same
        /// physical item got scanned twice, or a correction landed on
        /// the wrong (but real) product's code by coincidence. A warning,
        /// not a block: recorded twice may be exactly what happened (two
        /// of the same item bought), so this is surfaced rather than
        /// enforced.
        var isDuplicate = false
    }

    init(orderedUPCs: [String], foundInfo: [String: OpenFoodFactsService.ProductInfo], onFinish: @escaping ([ReceiptCandidate]) -> Void) {
        self.orderedUPCs = orderedUPCs
        self.foundInfo = foundInfo
        self.onFinish = onFinish
        _rows = State(initialValue: orderedUPCs.map { upc in
            if let info = foundInfo[upc] {
                return Row(upc: upc, isMatched: true, name: info.name, brand: info.brand ?? "", size: info.size ?? "")
            } else {
                return Row(upc: upc, isMatched: false)
            }
        })
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($rows) { $row in
                        if row.isMatched {
                            matchedRow(row)
                        } else {
                            unmatchedRow($row)
                                .swipeActions(edge: .trailing) {
                                    // Only unmatched rows get a swipe
                                    // action — an already-matched row has
                                    // no "leave it blank to skip" escape
                                    // hatch to begin with, so letting it
                                    // be swiped away here would just be a
                                    // way to accidentally lose a
                                    // perfectly good scan with no upside.
                                    Button(role: .destructive) {
                                        rows.removeAll { $0.id == row.id }
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                        }
                    }
                } header: {
                    Text("Everything scanned, in order. Matched lines are shown for reference; for an unmatched one, correct the UPC to auto-fill it, enter what you know by hand, leave it blank to skip, or swipe to remove it.")
                }
            }
            .navigationTitle("Review Scanned Items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip All") {
                        onFinish([])
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Save Unmapped") {
                        saveAndFinish()
                    }
                }
            }
        }
    }

    private func matchedRow(_ row: Row) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                let subtitle = [row.brand, row.size].filter { !$0.isEmpty }.joined(separator: " · ")
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func unmatchedRow(_ row: Binding<Row>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                // Editable — a UPC that ended up here is often an OCR
                // misread rather than a genuinely unknown product, so
                // correcting the digits directly (instead of only ever
                // typing the name by hand) gives `attemptAutoPopulate` a
                // real barcode to resolve.
                TextField("UPC", text: row.upc)
                    .keyboardType(.numberPad)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if row.wrappedValue.isLookingUp {
                    ProgressView()
                        .scaleEffect(0.7)
                }
                if row.wrappedValue.isDuplicate {
                    Label("Dupe", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            TextField("Name", text: row.name)
            TextField("Brand (optional)", text: row.brand)
            TextField("Size (optional)", text: row.size)
        }
        .padding(.vertical, 2)
        .onChange(of: row.wrappedValue.upc) { _, newValue in
            attemptAutoPopulate(for: row.wrappedValue.id, upc: newValue)
        }
    }

    /// Fires whenever an unmatched row's UPC field changes.
    ///
    /// The duplicate check runs immediately, on every edit that's a
    /// plausible complete barcode — it's a pure local comparison against
    /// rows already in memory, so there's no reason to wait on a network
    /// round-trip to know whether this UPC already belongs to a matched
    /// row. Recomputed every time rather than only ever set, so editing
    /// further to a UPC that's no longer a duplicate clears the badge
    /// instead of leaving a stale one.
    ///
    /// The actual lookup only fires once the text is plausibly a
    /// *complete* barcode (all digits, one of the standard lengths), so
    /// retyping mid-edit doesn't throw off a lookup per keystroke, and is
    /// checked against `Row.lastLookedUpUPC` so settling back on an
    /// already-tried value (or a duplicate `.onChange` call) doesn't
    /// re-query it. Goes through `UPCLookupService.lookupProductInfo` —
    /// bank first, then Open Food Facts — the same path
    /// `ReceiptOCRScannerView`'s own bank check uses, so a UPC corrected
    /// here benefits from (and contributes to, once saved) the same
    /// taught mappings.
    private func attemptAutoPopulate(for rowID: UUID, upc: String) {
        guard upc.allSatisfy(\.isNumber), [8, 12, 13].contains(upc.count) else { return }
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }

        rows[index].isDuplicate = rows.contains { $0.id != rowID && $0.isMatched && $0.upc == upc }

        guard rows[index].lastLookedUpUPC != upc else { return }
        rows[index].lastLookedUpUPC = upc
        rows[index].isLookingUp = true

        Task {
            let info = await UPCLookupService.lookupProductInfo(upc: upc, in: modelContext)
            // Re-resolved by id, not captured by index — the row may
            // have been swiped away, or the list reordered, while this
            // lookup was in flight.
            guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
            rows[index].isLookingUp = false
            guard let info else { return }

            // Only ever fills a field that's still blank — a name the
            // user already typed by hand is never silently overwritten
            // just because the corrected UPC happened to resolve too.
            if rows[index].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rows[index].name = info.name
            }
            if rows[index].brand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let brand = info.brand {
                rows[index].brand = brand
            }
            if rows[index].size.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let size = info.size {
                rows[index].size = size
            }
        }
    }

    private func saveAndFinish() {
        var newCandidates: [ReceiptCandidate] = []
        for row in rows where !row.isMatched {
            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let brand = row.brand.trimmingCharacters(in: .whitespacesAndNewlines)
            let size = row.size.trimmingCharacters(in: .whitespacesAndNewlines)

            let bankEntry = UPCBank(upc: row.upc, name: name, brand: brand.isEmpty ? nil : brand, size: size.isEmpty ? nil : size)
            modelContext.insert(bankEntry)

            newCandidates.append(ReceiptCandidate(
                name: name,
                brand: brand.isEmpty ? nil : brand,
                size: size.isEmpty ? nil : size,
                isSelected: true,
                source: .upcLookup
            ))
        }
        onFinish(newCandidates)
        dismiss()
    }
}
