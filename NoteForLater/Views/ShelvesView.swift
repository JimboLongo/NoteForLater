import SwiftUI
import SwiftData

/// Dedicated screen for managing shelves: add new ones, tap in to edit a
/// shelf's name/icon, reorder them, and delete ones you no longer need.
/// Whether a shelf shows up in the bottom tab bar and whether it's eligible
/// for the AI Scheduler are configured per-shelf in ShelfEditView.
struct ShelvesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Shelf.sortOrder) private var shelves: [Shelf]

    @State private var showsCannotDeleteAlert = false

    var body: some View {
        List {
            Section {
                ForEach(shelves) { shelf in
                    NavigationLink {
                        ShelfEditView(shelf: shelf)
                    } label: {
                        HStack {
                            Label(shelf.name, systemImage: shelf.systemImage)
                            Spacer()
                            if shelf.showsInTabBar {
                                Text("In Tab Bar")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete(perform: deleteShelves)
                .onMove(perform: moveShelves)

                Button {
                    addShelf()
                } label: {
                    Label("Add Shelf", systemImage: "plus.circle.fill")
                }
            } footer: {
                Text("Tap a shelf to rename it, change its icon, pin it to the tab bar, or make it eligible for the AI Scheduler.")
            }
        }
        .navigationTitle("Shelves")
        .toolbar { EditButton() }
        .alert("Can't Delete Shelf", isPresented: $showsCannotDeleteAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Move or delete the tasks on this shelf first.")
        }
    }

    private func addShelf() {
        let nextOrder = (shelves.map(\.sortOrder).max() ?? -1) + 1
        let shelf = Shelf(name: "New Shelf", systemImage: "tray", sortOrder: nextOrder)
        modelContext.insert(shelf)
    }

    private func deleteShelves(at offsets: IndexSet) {
        for index in offsets {
            let shelf = shelves[index]
            if let tasks = shelf.tasks, !tasks.isEmpty {
                showsCannotDeleteAlert = true
                continue
            }
            modelContext.delete(shelf)
        }
    }

    private func moveShelves(from source: IndexSet, to destination: Int) {
        var reordered = shelves
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, shelf) in reordered.enumerated() {
            shelf.sortOrder = index
        }
    }
}

#Preview {
    NavigationStack {
        ShelvesView()
    }
    .modelContainer(for: [InboxItem.self, TaskItem.self, ScheduledBlock.self, Shelf.self], inMemory: true)
}
