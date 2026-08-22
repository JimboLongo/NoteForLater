import SwiftUI
import SwiftData
import UIKit
import PhotosUI

/// One OCR'd (or barcode-scanned) candidate line, checkable before it's
/// actually added to the Kitchen shelf's Pantry — OCR/barcode lookups are
/// far less reliable than a well-formed CSV column, so (unlike the
/// file-based imports elsewhere in the app) this shows a review step
/// before anything is inserted. Not `private` — `BarcodeScannerView`
/// constructs these directly and hands them to `ReceiptImportView` via
/// `initialCandidates`, reusing this review/edit/Add UI rather than
/// duplicating it into a second view.
struct ReceiptCandidate: Identifiable {
    /// Where `name` actually came from — a UPC-sourced name is backed by
    /// a real Open Food Facts catalog entry, so it's shown as its own
    /// "confirmed" section with a barcode badge; a line-parsed name is
    /// only ever a best-effort OCR guess, shown separately under
    /// "Unconfirmed" so the two are never mistaken for each other.
    enum Source {
        case upcLookup
        case lineParsing
    }

    let id = UUID()
    /// The editable core name — bound directly to this row's `TextField`.
    /// `brand`/`size` are kept as their own fields rather than baked into
    /// this at creation time, so editing the name never silently discards
    /// them, and a line-parsed row (which never has either) doesn't need
    /// any special-casing here.
    var name: String
    var brand: String?
    var size: String?
    var isSelected: Bool
    var source: Source
}

/// Take a photo of a grocery receipt, OCR it, and add the checked lines to
/// the Kitchen shelf's Pantry as items. Reached only from the Kitchen
/// shelf's own Pantry pane.
struct ReceiptImportView: View {
    let shelf: Shelf
    /// Called after `addSelectedItems()` finishes inserting everything,
    /// instead of this view's own `dismiss()` — `nil` (the plain "present
    /// as a sheet straight from the Pantry" case, unchanged from before
    /// `BarcodeScannerView` existed) means dismissing this view alone
    /// already lands back on the Pantry. `BarcodeScannerView` passes one
    /// instead, because it pushes this view onto *its own* NavigationStack
    /// rather than presenting it directly — this view's `dismiss()` would
    /// only pop back to the live camera screen, not out to the Pantry the
    /// user actually wants to land on after tapping Add.
    var onFinishAdding: (() -> Void)?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var scanService = ReceiptScanService()

    @State private var isShowingCamera = false
    @State private var candidates: [ReceiptCandidate]
    @State private var hasScanned: Bool
    @State private var libraryPickerItem: PhotosPickerItem?

    /// `initialCandidates` is how `BarcodeScannerView` hands off its
    /// scanned-and-looked-up results into this same review/edit/Add UI
    /// instead of duplicating it — non-empty means the empty "Scan a
    /// Receipt" state is skipped entirely and the review list shows
    /// immediately, as if a receipt scan had already produced them.
    init(shelf: Shelf, initialCandidates: [ReceiptCandidate] = [], onFinishAdding: (() -> Void)? = nil) {
        self.shelf = shelf
        self.onFinishAdding = onFinishAdding
        _candidates = State(initialValue: initialCandidates)
        _hasScanned = State(initialValue: !initialCandidates.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Group {
                if scanService.isProcessing {
                    ProgressView("Reading receipt...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !hasScanned {
                    ContentUnavailableView {
                        Label("Scan a Receipt", systemImage: "camera.viewfinder")
                    } description: {
                        Text("Take a photo of a grocery receipt to pull out items for your Kitchen's Pantry.")
                    } actions: {
                        Button("Take Photo") {
                            isShowingCamera = true
                        }
                        .buttonStyle(.borderedProminent)
                        PhotosPicker(selection: $libraryPickerItem, matching: .images) {
                            Text("Choose from Library")
                        }
                    }
                } else {
                    List {
                        if candidates.isEmpty {
                            Text("Couldn't find any items on that receipt. Try a clearer, well-lit photo.")
                                .foregroundStyle(.secondary)
                        }
                        if !confirmedIndices.isEmpty {
                            Section {
                                ForEach(confirmedIndices, id: \.self) { index in
                                    candidateRow($candidates[index])
                                }
                                .onDelete { offsets in
                                    candidates.remove(atOffsets: IndexSet(offsets.map { confirmedIndices[$0] }))
                                }
                            } header: {
                                Text("Confirmed")
                            } footer: {
                                Text("Looked up from a barcode on the receipt — name, brand, and size come straight from the product catalog.")
                            }
                        }
                        if !unconfirmedIndices.isEmpty {
                            Section {
                                ForEach(unconfirmedIndices, id: \.self) { index in
                                    candidateRow($candidates[index])
                                }
                                .onDelete { offsets in
                                    candidates.remove(atOffsets: IndexSet(offsets.map { unconfirmedIndices[$0] }))
                                }
                            } header: {
                                Text("Unconfirmed")
                            } footer: {
                                Text("No barcode found or matched — read straight off the receipt text instead, so double-check these before adding them.")
                            }
                        }
                    }
                    if let errorMessage = scanService.errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal)
                    }
                }
            }
            .navigationTitle("Scan Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if hasScanned {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Retake") {
                            hasScanned = false
                            candidates = []
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Add \(selectedCount)") {
                            addSelectedItems()
                        }
                        .disabled(selectedCount == 0)
                    }
                }
            }
            .fullScreenCover(isPresented: $isShowingCamera) {
                CameraCaptureView(
                    onCapture: { image in
                        isShowingCamera = false
                        Task { await scan(image) }
                    },
                    onCancel: {
                        isShowingCamera = false
                    }
                )
                .ignoresSafeArea()
            }
            .onChange(of: libraryPickerItem) { _, newValue in
                guard let newValue else { return }
                Task {
                    if let data = try? await newValue.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        await scan(image)
                    }
                    libraryPickerItem = nil
                }
            }
        }
    }

    private var selectedCount: Int {
        candidates.filter(\.isSelected).count
    }

    /// Index-based, not a filtered copy of `candidates` itself — `onDelete`
    /// needs to map an offset back to `candidates`' own real index
    /// regardless of which section it came from, and `$candidates[index]`
    /// is what gives `candidateRow` a live, two-way `Binding` into the
    /// original array rather than a disconnected snapshot.
    private var confirmedIndices: [Int] {
        candidates.indices.filter { candidates[$0].source == .upcLookup }
    }

    private var unconfirmedIndices: [Int] {
        candidates.indices.filter { candidates[$0].source == .lineParsing }
    }

    /// Shared by both sections — the only thing that actually differs
    /// between a confirmed and an unconfirmed row is `source`, which this
    /// already reads to decide whether to show the barcode badge and the
    /// brand/size caption.
    private func candidateRow(_ candidate: Binding<ReceiptCandidate>) -> some View {
        Toggle(isOn: candidate.isSelected) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Item", text: candidate.name)
                    let parenthetical = [candidate.wrappedValue.brand, candidate.wrappedValue.size].compactMap { $0 }.joined(separator: ", ")
                    if !parenthetical.isEmpty {
                        Text(parenthetical)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if candidate.wrappedValue.source == .upcLookup {
                    Image(systemName: "barcode.viewfinder")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Found via barcode lookup")
                }
            }
        }
    }

    private func scan(_ image: UIImage) async {
        let lines = await scanService.recognizeLines(in: image)
        candidates = await Self.resolveCandidates(from: lines)
        hasScanned = true
    }

    /// Resolves every OCR'd line concurrently — one Open Food Facts lookup
    /// in flight per line that has a UPC-shaped digit run — then re-sorts
    /// back into the receipt's own original line order. `withTaskGroup`'s
    /// completion order isn't submission order, and a review list that
    /// doesn't match the physical receipt top-to-bottom would be
    /// confusing to check against it.
    private static func resolveCandidates(from lines: [String]) async -> [ReceiptCandidate] {
        await withTaskGroup(of: (Int, ReceiptCandidate?).self) { group in
            for (index, line) in lines.enumerated() {
                group.addTask { (index, await resolveCandidate(from: line)) }
            }
            var indexed: [(index: Int, candidate: ReceiptCandidate)] = []
            for await (index, candidate) in group {
                if let candidate {
                    indexed.append((index, candidate))
                }
            }
            return indexed.sorted { $0.index < $1.index }.map(\.candidate)
        }
    }

    /// One line's UPC-then-line-parsing fallback: try
    /// `ReceiptLineParser.upc(in:)`, then a lookup on it — only reach for
    /// `cleanedItemName` (today's behavior, unchanged) when either comes
    /// back empty. `lookupProductInfo` never throws, so "no UPC found,"
    /// "UPC found but not a real product," and "network/timeout/JSON
    /// failure" all take the same fallback path with no special-casing
    /// needed here.
    private static func resolveCandidate(from line: String) async -> ReceiptCandidate? {
        if let upc = ReceiptLineParser.upc(in: line), let info = await OpenFoodFactsService.lookupProductInfo(upc: upc) {
            return ReceiptCandidate(name: info.name, brand: info.brand, size: info.size, isSelected: true, source: .upcLookup)
        }
        guard let name = ReceiptLineParser.cleanedItemName(from: line) else { return nil }
        return ReceiptCandidate(name: name, brand: nil, size: nil, isSelected: true, source: .lineParsing)
    }

    private func addSelectedItems() {
        // Keyed by title so a product already on the shelf (added by an
        // earlier scan, or just now earlier in this same batch) gets
        // "bought another one" treatment — `quantity += 1` — instead of
        // a duplicate row. Rebuilt as new items are inserted, not just
        // read once up front, so two matching candidates in the same Add
        // tap correctly merge into each other too.
        var existingByTitle = Dictionary(
            (shelf.tasks ?? []).filter { !$0.isCompleted }.map { ($0.title.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for candidate in candidates where candidate.isSelected {
            let trimmed = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()

            if let existing = existingByTitle[key] {
                existing.quantity += 1
                continue
            }

            let task = TaskItem(title: trimmed, shelf: shelf)
            task.brand = candidate.brand
            // `candidate.size` is Open Food Facts' free-text quantity
            // field ("16 oz") — the same shape a recipe ingredient line's
            // leading amount takes, so the existing parser reads it
            // directly with no new logic: fed "16 oz" alone, it returns
            // quantity 16, unit "oz", and an empty (ignored) name. That's
            // the *package size* (a fixed fact about the product), not
            // how many you have — `quantity` is the count of packages,
            // starting at 1 for a just-added item, same as the bare-count
            // case (a line-parsed candidate with no size data at all)
            // also starting at 1 rather than the old default of 0, which
            // read as "I have none of this" for something just bought.
            if let size = candidate.size {
                let parsed = RecipeIngredientParser.parse(size)
                task.packageSize = parsed.quantity
                task.unit = parsed.unit
            }
            task.quantity = 1
            modelContext.insert(task)
            existingByTitle[key] = task
        }
        if let onFinishAdding {
            onFinishAdding()
        } else {
            dismiss()
        }
    }
}

#Preview {
    ReceiptImportView(shelf: Shelf(name: "The Kitchen", systemImage: "refrigerator"))
        .modelContainer(for: [TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self, Habit.self, HabitLog.self], inMemory: true)
}
