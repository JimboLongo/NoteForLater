import SwiftUI
import SwiftData

/// The brain dump. Type it, hit return, sort it later — or right now via
/// the pen picker.
struct InboxView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \InboxItem.createdAt, order: .reverse) private var items: [InboxItem]

    @State private var viewModel: InboxViewModel?
    @State private var draftText: String = ""
    @State private var itemBeingRouted: InboxItem?

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
            .sheet(item: $itemBeingRouted) { item in
                PenPickerSheet(itemText: item.text) { pen in
                    viewModel?.route(item, to: pen)
                    itemBeingRouted = nil
                }
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
}

/// Tap an inbox item, pick which holding pen it belongs in.
private struct PenPickerSheet: View {
    let itemText: String
    let onPick: (HoldingPen) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(itemText).font(.headline)
                }
                Section("Send to...") {
                    ForEach(HoldingPen.allCases) { pen in
                        Button {
                            onPick(pen)
                        } label: {
                            Label(pen.rawValue, systemImage: pen.systemImage)
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
        .modelContainer(for: [InboxItem.self, TaskItem.self, ScheduledBlock.self], inMemory: true)
}
