import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Shelf.sortOrder) private var shelves: [Shelf]

    var body: some View {
        TabView {
            InboxView()
                .tabItem { Label("Inbox", systemImage: "tray") }

            ForEach(pinnedShelves) { shelf in
                ShelfListView(shelf: shelf)
                    .tabItem { Label(shelf.name, systemImage: shelf.systemImage) }
            }

            ScheduleReviewView()
                .tabItem { Label("Schedule", systemImage: "calendar") }

            ShelvesView()
                .tabItem { Label("Shelves", systemImage: "square.stack.3d.up") }

            MoreView(unpinnedShelves: unpinnedShelves)
                .tabItem { Label("More", systemImage: "ellipsis.circle") }
        }
        .onAppear(perform: seedDefaultShelvesIfNeeded)
    }

    private var pinnedShelves: [Shelf] {
        shelves.filter(\.showsInTabBar)
    }

    private var unpinnedShelves: [Shelf] {
        shelves.filter { !$0.showsInTabBar }
    }

    private func seedDefaultShelvesIfNeeded() {
        guard shelves.isEmpty else { return }
        for shelf in Shelf.defaultSeedShelves() {
            modelContext.insert(shelf)
        }
    }
}

/// Groups shelves not pinned to the tab bar, plus Settings, so the tab bar
/// doesn't get crowded. (Shelf management itself has its own tab.)
struct MoreView: View {
    let unpinnedShelves: [Shelf]

    var body: some View {
        NavigationStack {
            List {
                Section("Shelves") {
                    if unpinnedShelves.isEmpty {
                        Text("All shelves are pinned to the tab bar.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(unpinnedShelves) { shelf in
                        NavigationLink {
                            ShelfListView(shelf: shelf)
                        } label: {
                            Label(shelf.name, systemImage: shelf.systemImage)
                        }
                    }
                }
                Section {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .navigationTitle("More")
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [InboxItem.self, TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self], inMemory: true)
}
