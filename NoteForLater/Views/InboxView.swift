import SwiftUI
import SwiftData

/// The brain dump. Type it, hit return, sort it later — or right now via
/// the pen picker.
struct InboxView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \InboxItem.createdAt, order: .reverse) private var items: [InboxItem]
    @Query(sort: \Shelf.sortOrder) private var shelves: [Shelf]

    @State private var viewModel: InboxViewModel?
    @State private var draftText: String = ""
    @State private var itemBeingRouted: InboxItem?
    @State private var isShowingImporter = false
    @State private var isSyncingGmail = false
    @State private var isShowingGmailAlert = false
    @State private var gmailSyncMessage = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("What's on your mind?", text: $draftText, axis: .vertical)
                            .submitLabel(.done)
                            .onSubmit(addDraft)
                        Button(action: addDraft) {
                            Image(systemName: "plus.circle.fill")
                        }
                        .disabled(draftText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Section("Unsorted (\(items.count))") {
                    if items.isEmpty {
                        Text("Inbox zero. Nice.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(items) { item in
                        Text(item.text)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    viewModel?.discard(item)
                                } label: {
                                    Label("Discard", systemImage: "trash")
                                }
                            }
                            .onTapGesture { itemBeingRouted = item }
                    }
                }
            }
            .navigationTitle("Note for Later")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            isShowingImporter = true
                        } label: {
                            Label("Import from File...", systemImage: "doc.badge.plus")
                        }
                        Button {
                            syncGmail()
                        } label: {
                            Label("Sync Unread Gmail", systemImage: "envelope.badge")
                        }
                        .disabled(isSyncingGmail)
                    } label: {
                        if isSyncingGmail {
                            ProgressView()
                        } else {
                            Image(systemName: "tray.and.arrow.down")
                        }
                    }
                }
            }
            .sheet(item: $itemBeingRouted) { item in
                ShelfPickerSheet(itemText: item.text, shelves: shelves) { shelf in
                    viewModel?.route(item, to: shelf)
                    itemBeingRouted = nil
                }
            }
            .sheet(isPresented: $isShowingImporter) {
                ImportView()
            }
            .alert("Gmail Sync", isPresented: $isShowingGmailAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(gmailSyncMessage)
            }
            .onAppear {
                if viewModel == nil {
                    viewModel = InboxViewModel(modelContext: modelContext)
                }
            }
        }
    }

    private func addDraft() {
        viewModel?.addItem(draftText)
        draftText = ""
    }

    private func syncGmail() {
        guard let viewModel else { return }
        isSyncingGmail = true
        Task {
            do {
                let count = try await viewModel.syncGmail(existingItems: items, gmailService: GoogleGmailService())
                gmailSyncMessage = count == 0 ? "No new unread emails." : "Imported \(count) email\(count == 1 ? "" : "s")."
            } catch {
                gmailSyncMessage = error.localizedDescription
            }
            isSyncingGmail = false
            isShowingGmailAlert = true
        }
    }
}

/// Tap an inbox item, pick which shelf it belongs on.
private struct ShelfPickerSheet: View {
    let itemText: String
    let shelves: [Shelf]
    let onPick: (Shelf) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(itemText).font(.headline)
                }
                Section("Send to...") {
                    if shelves.isEmpty {
                        Text("No shelves yet. Add one from the More tab.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(shelves) { shelf in
                        Button {
                            onPick(shelf)
                        } label: {
                            Label(shelf.name, systemImage: shelf.systemImage)
                        }
                    }
                }
            }
            .navigationTitle("Sort Item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    InboxView()
        .modelContainer(for: [InboxItem.self, TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self], inMemory: true)
}
