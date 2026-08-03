import SwiftUI
import SwiftData

enum AppTab: Hashable {
    case habits
    case inbox
    case calendar
    case shelves
    case more
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Shelf.sortOrder) private var shelves: [Shelf]
    @Query private var tags: [Tag]

    @State private var selectedTab: AppTab = .inbox
    @State private var quickAction = QuickActionService.shared
    @State private var moreNavigationPath = NavigationPath()

    var body: some View {
        TabView(selection: selectedTabBinding) {
            HabitsView()
                .tabItem { Label("Habits", systemImage: "checkmark.seal") }
                .tag(AppTab.habits)

            InboxView()
                .tabItem { Label("Inbox", systemImage: "tray") }
                .tag(AppTab.inbox)

            ScheduleReviewView()
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag(AppTab.calendar)

            ShelvesView()
                .tabItem { Label("Shelves", systemImage: "square.stack.3d.up") }
                .tag(AppTab.shelves)

            MoreView(navigationPath: $moreNavigationPath)
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

    /// A plain `.onChange(of: selectedTab)` only fires when the value
    /// actually changes, so re-tapping the More tab while already on it
    /// (the exact case that needs resetting) wouldn't trigger anything.
    /// TabView invokes this binding's setter on every tap regardless of
    /// whether the tag is already selected, so resetting here — any time
    /// More is (re-)selected — covers both arriving at it and tapping it
    /// again while already there.
    private var selectedTabBinding: Binding<AppTab> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                if newValue == .more {
                    moreNavigationPath = NavigationPath()
                }
                selectedTab = newValue
            }
        )
    }

    private func seedDefaultShelvesIfNeeded() {
        guard shelves.isEmpty else { return }
        for shelf in Shelf.defaultSeedShelves() {
            modelContext.insert(shelf)
        }
    }
}

/// Tags, Schedules, and Settings — everything not among the 5 fixed tabs.
struct MoreView: View {
    @Binding var navigationPath: NavigationPath

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                NavigationLink {
                    TagsListView()
                } label: {
                    Label("Tags", systemImage: "tag")
                }
                NavigationLink {
                    SchedulesListView()
                } label: {
                    Label("Schedules", systemImage: "clock.arrow.2.circlepath")
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
        .modelContainer(for: [InboxItem.self, TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self, Habit.self, HabitLog.self], inMemory: true)
}
