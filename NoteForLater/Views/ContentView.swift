import SwiftUI
import SwiftData

enum AppTab: Hashable {
    case inbox
    case shelf(UUID)
    case schedule
    case shelves
    case more
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Shelf.sortOrder) private var shelves: [Shelf]
    @Query private var tags: [Tag]

    @State private var selectedTab: AppTab = .inbox
    @State private var quickAction = QuickActionService.shared

    var body: some View {
        TabView(selection: $selectedTab) {
            InboxView()
                .tabItem { Label("Inbox", systemImage: "tray") }
                .tag(AppTab.inbox)

            ForEach(pinnedShelves) { shelf in
                ShelfListView(shelf: shelf)
                    .tabItem { Label(shelf.name, systemImage: shelf.systemImage) }
                    .tag(AppTab.shelf(shelf.id))
            }

            ScheduleReviewView()
                .tabItem { Label("Schedule", systemImage: "calendar") }
                .tag(AppTab.schedule)

            ShelvesView()
                .tabItem { Label("Shelves", systemImage: "square.stack.3d.up") }
                .tag(AppTab.shelves)

            MoreView()
                .tabItem { Label("More", systemImage: "ellipsis.circle") }
                .tag(AppTab.more)
        }
        .onAppear {
            seedDefaultShelvesIfNeeded()
            LocationMonitoringService.shared.syncRegions(with: tags)
        }
        .onChange(of: tags) { _, newValue in
            LocationMonitoringService.shared.syncRegions(with: newValue)
        }
        .onChange(of: shelves) { _, _ in
            seedDefaultShelvesIfNeeded()
        }
        .onChange(of: quickAction.pendingQuickAdd) { _, isPending in
            if isPending { selectedTab = .inbox }
        }
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
                    TagsListView()
                } label: {
                    Label("Manage Tags", systemImage: "tag")
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
        .modelContainer(for: [InboxItem.self, TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, Tag.self], inMemory: true)
}
