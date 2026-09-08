import SwiftUI
import SwiftData

/// The "Habits" tab: two pages — Today (mark each habit Yes/No/Excused for
/// today) and Stats (every habit's numbers at a glance) — switched via the
/// segmented control at top. Deliberately NOT a swipeable
/// `TabView(.page)`: that wraps its pages in a persistent UIScrollView pan
/// gesture recognizer which, in this app, has repeatedly been found to
/// swallow touches on whatever gets pushed on top of it from a List row's
/// NavigationLink inside a page (see ShelfCarouselView's history) — up to
/// and including the system back button becoming totally unresponsive on
/// HabitDetailView. A plain conditional switch has no such ancestor
/// gesture, so pushed destinations stay fully interactive.
struct HabitsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Habit.sortOrder) private var habits: [Habit]

    @State private var selectedPage = 0
    @State private var newHabit: Habit?
    @State private var isShowingImporter = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("View", selection: $selectedPage.animation()) {
                    Text("Today").tag(0)
                    Text("Stats").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)

                if selectedPage == 0 {
                    HabitsTodayView(habits: habits)
                } else {
                    HabitsStatsView(habits: habits)
                }
            }
            .navigationTitle("Habits")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingImporter = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        addHabit()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $newHabit) { habit in
                NavigationStack {
                    HabitEditView(habit: habit, focusNameOnAppear: true)
                }
            }
            .sheet(isPresented: $isShowingImporter) {
                HabitImportView()
            }
        }
    }

    private func addHabit() {
        let nextOrder = (habits.map(\.sortOrder).max() ?? -1) + 1
        let habit = Habit(name: "", sortOrder: nextOrder)
        modelContext.insert(habit)
        newHabit = habit
    }
}

/// Page 1: every habit, with one tappable circle per occurrence for the
/// currently selected day (defaults to today; navigate with the chevrons)
/// — a habit only counts as complete once every circle is filled. Tapping
/// a circle cycles that occurrence through all four states: none →
/// complete → missed → excused → none (`OccurrenceStatus.next`) — the
/// Habits tab used to only offer complete/unselected here, leaving
/// missed/excused reachable solely from a habit's own detail calendar;
/// now every state is reachable from either place, through the same
/// `logOrCreate` write funnel.
///
/// Ordered by each habit's own fixed `Habit.todayOrderKey` (frequency,
/// then occurrence-0 time of day, then a stable tiebreak) — deliberately
/// static, unlike the old "what's coming up next" queue this replaced:
/// nothing about a habit's *configuration* changes when a circle gets
/// tapped, so the order never needs to debounce against that the way the
/// old `displayedHabits` snapshot did. `cachedStats`/`cachedRolling`
/// still debounce via `HabitStatsRefreshCoordinator` — recomputing every
/// habit's full history walk on every tap is the actual expensive part,
/// unrelated to ordering.
///
/// The day-specific list (`HabitsTodayDayList`, below) is a child view
/// re-created via `.id(selectedDate)` whenever the selected day changes —
/// see that type's own doc comment for why (`@Query` predicates can't be
/// mutated after `init`).
struct HabitsTodayView: View {
    let habits: [Habit]
    @Environment(\.modelContext) private var modelContext
    private let calendar = Calendar.current

    @State private var selectedDate = Calendar.current.startOfDay(for: .now)
    /// Each habit's streak/max-streak, cached instead of recomputed (a full
    /// history walk) on every render — refreshed on appear, and again by
    /// `refreshCoordinator`'s idle tick. Owned here, not by the per-day
    /// child, and passed straight through to it: these are relative to
    /// real "now" (a streak as of right now), not to whichever day
    /// happens to be selected, so navigating days must not recompute them.
    @State private var cachedStats: [UUID: HabitStats] = [:]
    /// Same caching as `cachedStats`, for the Rolling 30 figure shown
    /// alongside streak on each habit's title card.
    @State private var cachedRolling: [UUID: HabitRollingStats] = [:]
    @State private var refreshCoordinator = HabitStatsRefreshCoordinator.shared

    /// A future day can be viewed (so you can see what's coming, or what
    /// a habit's schedule looks like ahead) but not edited — there's
    /// nothing to mark complete/missed/excused about a day that hasn't
    /// happened yet.
    private var canEditSelectedDate: Bool {
        selectedDate <= calendar.startOfDay(for: .now)
    }

    private var sortedHabits: [Habit] {
        habits.sorted { $0.todayOrderKey < $1.todayOrderKey }
    }

    var body: some View {
        VStack(spacing: 0) {
            dateNavigationHeader
            HabitsTodayDayList(
                habits: sortedHabits,
                selectedDate: selectedDate,
                canEdit: canEditSelectedDate,
                cachedStats: cachedStats,
                cachedRolling: cachedRolling
            )
            .id(selectedDate)
        }
        .onAppear { refreshStats() }
        // A habit added/deleted/reordered elsewhere should reflect right
        // away — the idle debounce below is specifically about not
        // paying for a full history recompute on every single tap, not
        // about hiding a structural change like this.
        .onChange(of: habits) { _, _ in refreshStats() }
        .onChange(of: refreshCoordinator.idleRefreshTick) { _, _ in refreshStats() }
    }

    private var dateNavigationHeader: some View {
        HStack {
            Button {
                selectedDate = calendar.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 32)
            }
            Spacer()
            Text(dateHeaderLabel)
                .font(.headline)
            Spacer()
            Button {
                selectedDate = calendar.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 44, height: 32)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    private static let dateHeaderFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter
    }()

    private var dateHeaderLabel: String {
        if calendar.isDateInToday(selectedDate) { return "Today" }
        if calendar.isDateInYesterday(selectedDate) { return "Yesterday" }
        if calendar.isDateInTomorrow(selectedDate) { return "Tomorrow" }
        return Self.dateHeaderFormatter.string(from: selectedDate)
    }

    private func refreshStats() {
        for habit in habits {
            cachedStats[habit.id] = habit.stats(calendar: calendar)
            cachedRolling[habit.id] = rollingStats(for: habit)
        }
    }

    /// Same trailing-30-day-window math HabitDetailView shows on its stats
    /// grid, just computed from the `logs` relationship directly (filtered
    /// to the window in memory) instead of a separate date-bounded `@Query`
    /// per habit — there's no per-row query scope here, this runs for
    /// every habit at once from `refreshStats()`.
    private func rollingStats(for habit: Habit) -> HabitRollingStats {
        let windowStart = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: .now)) ?? .now
        let windowLogs = (habit.logs ?? []).filter { $0.date >= windowStart }
        let logsByDay = habit.logsByDay(from: windowLogs, calendar: calendar)
        return computeHabitRollingStats(
            status: { day in habit.status(on: day, asOf: .now, calendar: calendar, logsByDay: logsByDay) },
            schedule: { habit.isApplicable(on: $0, calendar: calendar) },
            creationDate: habit.startDate,
            today: .now,
            threshold: habit.missThreshold,
            calendar: calendar
        )
    }
}

/// The actual per-day row list. A child view rather than part of
/// `HabitsTodayView` itself specifically so `.id(selectedDate)` on the
/// parent can force a fresh `init` — and therefore a freshly-baked
/// `@Query` predicate — every time the selected day changes: SwiftData
/// `@Query` predicates are fixed at `init` and can't be mutated
/// afterward, so a plain `@State selectedDate` on its own can't drive
/// which day's logs get fetched. Tearing down and rebuilding this whole
/// list on every day change costs a fresh fetch and resets scroll
/// position — an accepted tradeoff for keeping `@Query`'s live
/// cross-screen observation (a completion made on the Calendar tab or a
/// habit's own detail calendar still shows up here the instant it
/// happens, same as the original single-day `todayLogs` query did — a
/// manual `context.fetch` driven by `.task(id:)` would only pick that up
/// once `HabitStatsRefreshCoordinator`'s 3-second idle tick fired,
/// regressing exactly the cross-screen immediacy the original query
/// existed for).
private struct HabitsTodayDayList: View {
    let habits: [Habit]
    let selectedDate: Date
    let canEdit: Bool
    let cachedStats: [UUID: HabitStats]
    let cachedRolling: [UUID: HabitRollingStats]

    @Environment(\.modelContext) private var modelContext
    private let calendar = Calendar.current

    /// Queried directly (rather than read off `habit.logs`) so a
    /// completion made elsewhere — most notably tapping a block's complete
    /// circle on the Schedule tab — shows up on this screen the instant it
    /// happens. SwiftData's `@Query` reliably observes changes to the
    /// fetched type itself; it does not reliably re-fire just because a
    /// *related* model (a `HabitLog` reached only via `Habit.logs`)
    /// changed, which is what made the checkmark here lag behind a
    /// same-day edit made on another screen.
    @Query private var selectedDateLogs: [HabitLog]

    init(habits: [Habit], selectedDate: Date, canEdit: Bool, cachedStats: [UUID: HabitStats], cachedRolling: [UUID: HabitRollingStats]) {
        self.habits = habits
        self.selectedDate = selectedDate
        self.canEdit = canEdit
        self.cachedStats = cachedStats
        self.cachedRolling = cachedRolling
        let day = selectedDate
        _selectedDateLogs = Query(filter: #Predicate<HabitLog> { $0.date == day })
    }

    var body: some View {
        // Built once per render and handed down to every row's circles,
        // instead of each circle independently re-scanning that habit's
        // entire log history to find this day's entry.
        let logsByHabit = logsByHabit()
        List {
            if habits.isEmpty {
                Text("No habits yet. Tap + to add one.")
                    .foregroundStyle(.secondary)
            }
            ForEach(habits) { habit in
                HStack {
                    NavigationLink {
                        HabitDetailView(habit: habit)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(habit.name)
                                .fixedSize(horizontal: false, vertical: true)
                            streakLine(for: habit)
                                .font(.caption2)
                                .lineLimit(1)
                            rollingLine(for: habit)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: 198, alignment: .leading)
                    Spacer(minLength: 8)
                    if habit.isApplicable(on: selectedDate, calendar: calendar) {
                        dayControls(for: habit, log: logsByHabit[habit.id])
                    } else {
                        Text("Not this day")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete(perform: deleteHabits)
        }
    }

    /// This day's log for every habit, keyed off the directly-queried
    /// `selectedDateLogs` (see its declaration) rather than each habit's
    /// `logs` relationship, so this stays live with edits made elsewhere.
    private func logsByHabit() -> [UUID: HabitLog] {
        var result: [UUID: HabitLog] = [:]
        for log in selectedDateLogs {
            if let habitID = log.habit?.id {
                result[habitID] = log
            }
        }
        return result
    }

    private func streakLine(for habit: Habit) -> Text {
        let stats = cachedStats[habit.id] ?? HabitStats(currentStreak: 0, maxStreak: 0, mtdPercent: nil, ltdPercent: nil)
        return Text("Streak ").foregroundStyle(.secondary)
            + Text(stats.currentStreakDisplay).foregroundStyle(streakColor(stats.currentStreak))
            + Text(" · Max ").foregroundStyle(.secondary)
            + Text(stats.maxStreakDisplay).foregroundStyle(streakColor(stats.maxStreak))
    }

    private func rollingLine(for habit: Habit) -> Text {
        let rolling = cachedRolling[habit.id]
        return Text("Rolling 30: ").foregroundStyle(.secondary)
            + Text(rolling?.rolling30Display ?? "—").foregroundStyle(.primary)
    }

    private func streakColor(_ value: Int) -> Color {
        if value > 0 { return .green }
        if value < 0 { return .red }
        return .secondary
    }

    @ViewBuilder
    private func dayControls(for habit: Habit, log: HabitLog?) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<habit.timesPerDay, id: \.self) { index in
                occurrenceCircle(habit: habit, index: index, log: log)
            }
        }
    }

    /// A checkbox for this one occurrence (index 0 = BrushTeeth.1, index 1
    /// = BrushTeeth.2, ...) — tapping cycles it through all four states
    /// (`OccurrenceStatus.next`: none → complete → missed → excused →
    /// none), mirroring what a habit's own detail calendar already lets
    /// you do per-day, just per-occurrence and reachable without leaving
    /// this screen. The matching scheduled block's own complete circle
    /// (Schedule tab) only ever shows complete-or-not, but stays in sync
    /// either way — see `toggleOccurrence`. Disabled (and dimmed) for a
    /// future day — see `canEdit`.
    private func occurrenceCircle(habit: Habit, index: Int, log: HabitLog?) -> some View {
        let status = log?.occurrenceStatus(index) ?? .none
        return Button {
            toggleOccurrence(habit: habit, index: index)
        } label: {
            Circle()
                .fill(fillColor(for: status))
                .frame(width: 36, height: 36)
                .overlay {
                    occurrenceIcon(for: status)
                }
        }
        .buttonStyle(.plain)
        .disabled(!canEdit)
        .opacity(canEdit ? 1 : 0.5)
    }

    /// Cycles one occurrence to its next state, keeping its matching
    /// `ScheduledBlock.isCompleted` (if that occurrence made it onto that
    /// day's calendar) in sync — `true` only for `.complete`, `false` for
    /// every other state including `.missed`/`.excused`, same rule
    /// `HabitDetailView.setDay` already uses (a block's own `isCompleted`
    /// is a single boolean; it was never able to distinguish missed from
    /// excused, and nothing downstream reads it expecting to — the
    /// `HabitLog` occurrence arrays are what's authoritative for which of
    /// the two it actually is).
    private func toggleOccurrence(habit: Habit, index: Int) {
        guard canEdit else { return }
        habit.cycleOccurrence(index, on: selectedDate, context: modelContext, calendar: calendar)
        HabitStatsRefreshCoordinator.shared.habitLogsChanged()
    }

    private func fillColor(for status: OccurrenceStatus) -> Color {
        switch status {
        case .none: return Color.secondary.opacity(0.15)
        case .complete: return .green.opacity(0.6)
        case .missed: return .red.opacity(0.55)
        case .excused: return .gray.opacity(0.4)
        }
    }

    @ViewBuilder
    private func occurrenceIcon(for status: OccurrenceStatus) -> some View {
        switch status {
        case .none:
            EmptyView()
        case .complete:
            Image(systemName: "checkmark")
                .font(.callout)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
        case .missed:
            Image(systemName: "xmark")
                .font(.callout)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
        case .excused:
            Image(systemName: "xmark")
                .font(.callout)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
        }
    }

    private func deleteHabits(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(habits[index])
        }
    }
}

/// Page 2: every habit's Current Streak, Max Streak, MTD %, and LTD % in one
/// list, sorted by current streak (best first).
struct HabitsStatsView: View {
    let habits: [Habit]

    private var sortedHabits: [Habit] {
        habits.sorted { $0.currentStreak() > $1.currentStreak() }
    }

    var body: some View {
        List {
            if habits.isEmpty {
                Text("No habits yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(sortedHabits) { habit in
                let stats = habit.stats()
                NavigationLink {
                    HabitDetailView(habit: habit)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(habit.name)
                            .font(.headline)
                        HStack {
                            statItem("Streak", stats.currentStreakDisplay, color: streakColor(stats.currentStreak))
                            statItem("Max", stats.maxStreakDisplay, color: streakColor(stats.maxStreak))
                            statItem("MTD", stats.mtdPercentDisplay, color: .primary)
                            statItem("LTD", stats.ltdPercentDisplay, color: .primary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func statItem(_ label: String, _ value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func streakColor(_ value: Int) -> Color {
        if value > 0 { return .green }
        if value < 0 { return .red }
        return .primary
    }
}

#Preview {
    HabitsView()
        .modelContainer(for: [TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self, Habit.self, HabitLog.self], inMemory: true)
}
