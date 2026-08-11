import SwiftUI
import SwiftData

/// Where a tap in the Shelves list should land: an existing shelf opens a
/// swipeable carousel of every shelf's tasks (ShelfPagerView), starting on
/// the tapped one; a brand-new shelf (no tasks yet) skips straight to its
/// settings instead, per the existing "Add Shelf focuses the name field"
/// behavior.
private enum ShelfDestination: Hashable {
    case tasks(Shelf)
    case settings(Shelf)
}

/// Dedicated screen for managing shelves: add new ones, tap in to see a
/// shelf's tasks, reorder shelves, and delete ones you no longer need.
/// Renaming/icon/color/AI-Scheduler eligibility all live in ShelfEditView,
/// reached from ShelfListView's settings button.
struct ShelvesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Shelf.sortOrder) private var shelves: [Shelf]

    @State private var showsCannotDeleteAlert = false
    @State private var navigationPath = NavigationPath()
    @State private var justAddedShelfID: UUID?

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                Section {
                    ForEach(shelves) { shelf in
                        NavigationLink(value: ShelfDestination.tasks(shelf)) {
                            HStack(spacing: 8) {
                                Image(systemName: shelf.systemImage)
                                    .frame(width: 22, height: 22)
                                Circle()
                                    .fill(shelf.color)
                                    .frame(width: 22, height: 22)
                                Text(shelf.name)
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
                    Text("Tap a shelf to see its tasks — its settings (rename, icon, color, AI Scheduler) are a button away from there.")
                }
            }
            .navigationTitle("Shelves")
            .toolbar { EditButton() }
            .navigationDestination(for: ShelfDestination.self) { destination in
                switch destination {
                case .tasks(let shelf):
                    ShelfCarouselView(shelves: shelves, initialPage: .shelf(shelf))
                case .settings(let shelf):
                    ShelfEditView(shelf: shelf, focusNameOnAppear: shelf.id == justAddedShelfID)
                }
            }
            .alert("Can't Delete Shelf", isPresented: $showsCannotDeleteAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Move or delete the tasks on this shelf first.")
            }
        }
    }

    private func addShelf() {
        let nextOrder = (shelves.map(\.sortOrder).max() ?? -1) + 1
        let shelf = Shelf(name: "New Shelf", systemImage: firstUnusedIcon, sortOrder: nextOrder)
        shelf.colorName = firstUnusedColorName
        modelContext.insert(shelf)
        justAddedShelfID = shelf.id
        navigationPath.append(ShelfDestination.settings(shelf))
    }

    private var firstUnusedIcon: String {
        let used = Set(shelves.map(\.systemImage))
        return Shelf.iconOptions.first { !used.contains($0) } ?? Shelf.iconOptions[0]
    }

    private var firstUnusedColorName: String {
        let used = Set(shelves.map(\.colorName))
        return Shelf.colorPalette.first { !used.contains($0.name) }?.name ?? Shelf.colorPalette[0].name
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
    ShelvesView()
        .modelContainer(for: [TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self, Habit.self, HabitLog.self], inMemory: true)
}
