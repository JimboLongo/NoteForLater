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
    @Query private var allBlocks: [ScheduledBlock]
    @Query(sort: \Habit.sortOrder) private var allHabits: [Habit]

    @State private var selectedTab: AppTab = .inbox
    @State private var quickAction = QuickActionService.shared
    @State private var nightlyReviewLaunchState = NightlyReviewLaunchState.shared
    @State private var dailyDigestLaunchState = DailyDigestLaunchState.shared
    @State private var dailyDigestSettings = DailyDigestSettings.shared
    @State private var moreNavigationPath = NavigationPath()
    @State private var inboxNavigationPath = NavigationPath()
    @State private var inboxResetToken = 0
    @State private var shelvesNavigationPath = NavigationPath()

    var body: some View {
        TabView(selection: selectedTabBinding) {
            HabitsView()
                .tabItem { Label("Habits", systemImage: "checkmark.seal") }
                .tag(AppTab.habits)

            NavigationStack(path: $inboxNavigationPath) {
                ShelfCarouselView(shelves: shelves, initialPage: .inbox, resetToken: inboxResetToken)
            }
            .tabItem { Label("Inbox", systemImage: "tray") }
            .tag(AppTab.inbox)

            ScheduleReviewView()
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag(AppTab.calendar)

            ShelvesView(navigationPath: $shelvesNavigationPath)
                .tabItem { Label("Shelves", systemImage: "square.stack.3d.up") }
                .tag(AppTab.shelves)

            MoreView(navigationPath: $moreNavigationPath)
                .tabItem { Label("More", systemImage: "ellipsis.circle") }
                .tag(AppTab.more)
        }
        .onAppear {
            seedDefaultShelvesIfNeeded()
            LocationMonitoringService.shared.syncRegions(with: tags)
            DailyDigestNotificationService.shared.reschedule(habits: allHabits, blocks: allBlocks)
        }
        .onChange(of: tags) { _, newValue in
            LocationMonitoringService.shared.syncRegions(with: newValue)
        }
        .onChange(of: shelves) { _, _ in
            seedDefaultShelvesIfNeeded()
        }
        .onChange(of: allBlocks) { _, newValue in
            DailyDigestNotificationService.shared.reschedule(habits: allHabits, blocks: newValue)
        }
        .onChange(of: allHabits) { _, newValue in
            DailyDigestNotificationService.shared.reschedule(habits: newValue, blocks: allBlocks)
        }
        .onChange(of: dailyDigestSettings.isEnabled) { _, _ in
            DailyDigestNotificationService.shared.reschedule(habits: allHabits, blocks: allBlocks)
        }
        .onChange(of: dailyDigestSettings.minutesOfDay) { _, _ in
            DailyDigestNotificationService.shared.reschedule(habits: allHabits, blocks: allBlocks)
        }
        .onChange(of: quickAction.pendingQuickAdd) { _, isPending in
            if isPending { selectedTab = .inbox }
        }
        .fullScreenCover(isPresented: nightlyReviewPresentedBinding) {
            NightlyReviewView()
        }
        .sheet(isPresented: dailyDigestCheckInPresentedBinding) {
            DailyDigestCheckInView()
        }
    }

    private var nightlyReviewPresentedBinding: Binding<Bool> {
        Binding(
            get: { nightlyReviewLaunchState.pendingReview },
            set: { nightlyReviewLaunchState.pendingReview = $0 }
        )
    }

    private var dailyDigestCheckInPresentedBinding: Binding<Bool> {
        Binding(
            get: { dailyDigestLaunchState.pendingCheckIn },
            set: { dailyDigestLaunchState.pendingCheckIn = $0 }
        )
    }

    /// A plain `.onChange(of: selectedTab)` only fires when the value
    /// actually changes, so re-tapping the More or Inbox tab while already
    /// on it (the exact case that needs resetting) wouldn't trigger
    /// anything. TabView invokes this binding's setter on every tap
    /// regardless of whether the tag is already selected, so resetting
    /// here — any time that tab is (re-)selected — covers both arriving at
    /// it and tapping it again while already there. For Inbox, that means
    /// popping any pushed detail view back to the carousel *and* snapping
    /// the carousel itself back to the Inbox page (in case a swipe had
    /// moved it onto a shelf).
    private var selectedTabBinding: Binding<AppTab> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                if newValue == .more {
                    moreNavigationPath = NavigationPath()
                }
                if newValue == .inbox {
                    inboxNavigationPath = NavigationPath()
                    inboxResetToken += 1
                }
                if newValue == .shelves {
                    shelvesNavigationPath = NavigationPath()
                }
                selectedTab = newValue
            }
        )
    }

    private func seedDefaultShelvesIfNeeded() {
        if shelves.isEmpty {
            for shelf in Shelf.defaultSeedShelves() {
                modelContext.insert(shelf)
            }
        }
        seedSpecialShelvesIfNeeded()
    }

    /// The 2-Minute Task and Recurring Tasks shelves are permanent — no
    /// Settings toggle decides whether they exist anymore, they just
    /// always do, the same way `ShelvesView.deleteShelves` already
    /// refuses to ever delete one. Runs alongside the regular default-seed
    /// pass (`.onAppear`/whenever `shelves` changes — see `body`), so a
    /// shelf that somehow goes missing (e.g. `SettingsView.clearAllData`
    /// wiping every shelf) comes right back rather than staying gone.
    private func seedSpecialShelvesIfNeeded() {
        var nextOrder = (shelves.map(\.sortOrder).max() ?? -1) + 1
        if !shelves.contains(where: { $0.isTwoMinuteTasks }) {
            let shelf = Shelf(name: "2-Minute Tasks", systemImage: "2.circle.fill", sortOrder: nextOrder)
            shelf.isTwoMinuteTasks = true
            modelContext.insert(shelf)
            nextOrder += 1
        }
        if !shelves.contains(where: { $0.isRecurringTasks }) {
            let shelf = Shelf(name: "Recurring Tasks", systemImage: "arrow.triangle.2.circlepath", sortOrder: nextOrder)
            shelf.isRecurringTasks = true
            modelContext.insert(shelf)
        }
    }
}

/// Tags, Schedules, and Settings — everything not among the 5 fixed tabs.
struct MoreView: View {
    @Binding var navigationPath: NavigationPath
    @State private var isShowingTutorial = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                Button {
                    isShowingTutorial = true
                } label: {
                    Label("Tutorial", systemImage: "sparkles")
                }
                .foregroundStyle(.primary)
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
                    TaskStatsView()
                } label: {
                    Label("Task Stats", systemImage: "chart.bar")
                }
                NavigationLink {
                    SettingsView()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            .navigationTitle("More")
            .sheet(isPresented: $isShowingTutorial) {
                TutorialView()
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self, Habit.self, HabitLog.self], inMemory: true)
}
