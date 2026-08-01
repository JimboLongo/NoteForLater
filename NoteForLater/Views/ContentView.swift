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

            MoreView()
                .tabItem { Label("More", systemImage: "ellipsis.circle") }
        }
        .onAppear(perform: seedDefaultShelvesIfNeeded)
    }

    private var pinnedShelves: [Shelf] {
        shelves.filter(\.showsInTabBar)
    }

    private func seedDefaultShelvesIfNeeded() {
        guard shelves.isEmpty else { return }
        for shelf in Shelf.defaultSeedShelves() {
            modelContext.insert(shelf)
        }
    }
}

/// Just two doors: shelf management (including per-shelf settings) and
/// app-wide Settings.
struct MoreView: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    ShelvesView()
                } label: {
                    Label("Manage Shelves", systemImage: "square.stack.3d.up")
                }
                NavigationLink {
                    SettingsView()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            .navigationTitle("More")
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [InboxItem.self, TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self], inMemory: true)
}
