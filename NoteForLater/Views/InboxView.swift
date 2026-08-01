import SwiftUI
import SwiftData

/// The brain dump. Type it, hit return, sort it later — tap an item to fill
/// in its attributes and route it, or use the shelf slider + Submit for
/// quick bulk sorting. Sorted oldest-first so whatever's been sitting
/// longest surfaces at the top.
struct InboxView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \InboxItem.createdAt) private var items: [InboxItem]
    @Query(sort: \Shelf.sortOrder) private var shelves: [Shelf]

    @State private var viewModel: InboxViewModel?
    @State private var draftText: String = ""
    @State private var isShowingImporter = false

    /// Per-row shelf picked on the slider but not yet submitted, keyed by
    /// InboxItem.id. Nothing here is routed until "Submit" is tapped.
    @State private var pendingShelfSelections: [UUID: Shelf] = [:]

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

                if !pendingShelfSelections.isEmpty {
                    Section {
                        Button {
                            submitPendingRoutes()
                        } label: {
                            Label("Submit \(pendingShelfSelections.count) to Shelves", systemImage: "checkmark.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .listRowBackground(Color.clear)
                }

                Section("Unsorted (\(items.count))") {
                    if items.isEmpty {
                        Text("Inbox zero. Nice.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(items) { item in
                        HStack {
                            NavigationLink {
                                InboxItemDetailView(item: item, shelves: shelves) { shelf in
                                    viewModel?.route(item, to: shelf)
                                    pendingShelfSelections[item.id] = nil
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.text)
                                        .lineLimit(2)
                                    Text(daysSittingText(item))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            ShelfSlider(shelves: shelves, selectedShelf: binding(for: item))
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                viewModel?.discard(item)
                                pendingShelfSelections[item.id] = nil
                            } label: {
                                Label("Discard", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Note for Later")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingImporter = true
                    } label: {
                        Image(systemName: "tray.and.arrow.down")
                    }
                }
            }
            .sheet(isPresented: $isShowingImporter) {
                ImportView()
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

    private func binding(for item: InboxItem) -> Binding<Shelf?> {
        Binding(
            get: { pendingShelfSelections[item.id] },
            set: { pendingShelfSelections[item.id] = $0 }
        )
    }

    private func submitPendingRoutes() {
        for (itemID, shelf) in pendingShelfSelections {
            guard let item = items.first(where: { $0.id == itemID }) else { continue }
            viewModel?.route(item, to: shelf)
        }
        pendingShelfSelections.removeAll()
    }

    private func daysSittingText(_ item: InboxItem) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: item.createdAt),
            to: calendar.startOfDay(for: .now)
        ).day ?? 0
        if days <= 0 { return "Added today" }
        return "\(days) day\(days == 1 ? "" : "s") in inbox"
    }
}

/// Compact swipeable picker: skip, or swipe to land on a shelf. Nothing
/// happens until the item is submitted from the top of the Inbox.
private struct ShelfSlider: View {
    let shelves: [Shelf]
    @Binding var selectedShelf: Shelf?

    var body: some View {
        TabView(selection: Binding(
            get: { selectedShelf?.id },
            set: { newID in selectedShelf = shelves.first { $0.id == newID } }
        )) {
            Text("Skip")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .tag(nil as UUID?)
            ForEach(shelves) { shelf in
                Text(shelf.name)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 4)
                    .tag(shelf.id as UUID?)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(width: 92, height: 28)
        .background(Color.secondary.opacity(0.12))
        .clipShape(Capsule())
    }
}

#Preview {
    InboxView()
        .modelContainer(for: [InboxItem.self, TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self], inMemory: true)
}
