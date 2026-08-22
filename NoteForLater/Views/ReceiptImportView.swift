import SwiftUI
import SwiftData
import UIKit
import PhotosUI

/// One OCR'd candidate line, checkable before it's actually added to the
/// Kitchen shelf's Pantry — OCR is far less reliable than a well-formed
/// CSV column, so (unlike the file-based imports elsewhere in the app)
/// this shows a review step before anything is inserted.
private struct ReceiptCandidate: Identifiable {
    /// Where `name` actually came from — shown as a small badge so a
    /// UPC-sourced name (usually cleaner than OCR text) is easy to tell
    /// apart from a line-parsed one at a glance, and so a wrong-looking
    /// name is easier to debug: was it a bad OCR read, or a bad barcode
    /// lookup?
    enum Source {
        case upcLookup
        case lineParsing
    }

    let id = UUID()
    var name: String
    var isSelected: Bool
    var source: Source
}

/// Take a photo of a grocery receipt, OCR it, and add the checked lines to
/// the Kitchen shelf's Pantry as items. Reached only from the Kitchen
/// shelf's own Pantry pane.
struct ReceiptImportView: View {
    let shelf: Shelf
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var scanService = ReceiptScanService()

    @State private var isShowingCamera = false
    @State private var candidates: [ReceiptCandidate] = []
    @State private var hasScanned = false
    @State private var libraryPickerItem: PhotosPickerItem?

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
                        Section {
                            ForEach($candidates) { $candidate in
                                Toggle(isOn: $candidate.isSelected) {
                                    HStack {
                                        TextField("Item", text: $candidate.name)
                                        if candidate.source == .upcLookup {
                                            Image(systemName: "barcode.viewfinder")
                                                .foregroundStyle(.secondary)
                                                .accessibilityLabel("Found via barcode lookup")
                                        }
                                    }
                                }
                            }
                            .onDelete { offsets in
                                candidates.remove(atOffsets: offsets)
                            }
                        } footer: {
                            if !candidates.isEmpty {
                                Text("Uncheck anything that isn't actually an item — receipts OCR imperfectly. \(Image(systemName: "barcode.viewfinder")) marks a name looked up from a barcode instead of read off the receipt text.")
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
    /// back empty. `lookupProductName` never throws, so "no UPC found,"
    /// "UPC found but not a real product," and "network/timeout/JSON
    /// failure" all take the same fallback path with no special-casing
    /// needed here.
    private static func resolveCandidate(from line: String) async -> ReceiptCandidate? {
        if let upc = ReceiptLineParser.upc(in: line), let productName = await OpenFoodFactsService.lookupProductName(upc: upc) {
            return ReceiptCandidate(name: productName, isSelected: true, source: .upcLookup)
        }
        guard let name = ReceiptLineParser.cleanedItemName(from: line) else { return nil }
        return ReceiptCandidate(name: name, isSelected: true, source: .lineParsing)
    }

    private func addSelectedItems() {
        for candidate in candidates where candidate.isSelected {
            let trimmed = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            modelContext.insert(TaskItem(title: trimmed, shelf: shelf))
        }
        dismiss()
    }
}

#Preview {
    ReceiptImportView(shelf: Shelf(name: "The Kitchen", systemImage: "refrigerator"))
        .modelContainer(for: [TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self, Habit.self, HabitLog.self], inMemory: true)
}
