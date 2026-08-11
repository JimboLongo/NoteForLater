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
            .onAppear {
                HabitNotificationService.shared.requestAuthorization()
                // Reminders are one-shot over a short rolling window (see
                // HabitNotificationService), not repeating — this keeps
                // that window topped up every time the Habits tab opens.
                for habit in habits {
                    HabitNotificationService.shared.reschedule(habit)
                }
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

/// Page 1: every habit, with one tappable circle per occurrence for today
/// — a habit only counts as complete once every circle is filled — plus a
/// menu for the day-level Excused/Missed overrides. Ordered like a queue of
/// what's coming up next: each habit's nearest still-unresolved reminder,
/// today first (skipping reminders already resolved for the day) then
/// rolling forward to its next applicable day. That order is debounced —
/// it only re-shuffles after 5 seconds with no further taps, so the list
/// doesn't jump around mid-interaction — while the circles themselves still
/// update immediately. Dragging to manually reorder wouldn't survive an
/// algorithmic order, so it's not offered here.
struct HabitsTodayView: View {
    let habits: [Habit]
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
    @Query private var todayLogs: [HabitLog]

    /// Each habit's streak/max-streak, cached instead of recomputed (a full
    /// history walk) on every render — refreshed on appear.
    @State private var cachedStats: [UUID: HabitStats] = [:]
    /// Same refresh-on-appear caching as `cachedStats`, for the Rolling 30
    /// figure shown alongside streak on each habit's title card.
    @State private var cachedRolling: [UUID: HabitRollingStats] = [:]

    init(habits: [Habit]) {
        self.habits = habits
        let today = Calendar.current.startOfDay(for: .now)
        _todayLogs = Query(filter: #Predicate<HabitLog> { $0.date == today })
    }

    private var liveSortedHabits: [Habit] {
        habits.sorted { lhs, rhs in
            let l = lhs.nextReminderDate(calendar: calendar)
            let r = rhs.nextReminderDate(calendar: calendar)
            switch (l, r) {
            case let (l?, r?): return l < r
            case (nil, _): return false
            case (_, nil): return true
            }
        }
    }

    var body: some View {
        // Built once per render and handed down to every row's circles,
        // instead of each circle independently re-scanning that habit's
        // entire log history to find today's entry.
        let todayLogsByHabit = todayLogsByHabit()
        List {
            if habits.isEmpty {
                Text("No habits yet. Tap + to add one.")
                    .foregroundStyle(.secondary)
            }
            ForEach(liveSortedHabits) { habit in
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
                    if habit.isApplicable(on: .now, calendar: calendar) {
                        todayControls(for: habit, todayLog: todayLogsByHabit[habit.id])
                    } else {
                        Text("Not today")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete(perform: deleteHabits)
        }
        .onAppear {
            refreshStats()
        }
    }

    /// Today's log for every habit, keyed off the directly-queried
    /// `todayLogs` (see its declaration) rather than each habit's `logs`
    /// relationship, so this stays live with edits made elsewhere.
    private func todayLogsByHabit() -> [UUID: HabitLog] {
        var result: [UUID: HabitLog] = [:]
        for log in todayLogs {
            if let habitID = log.habit?.id {
                result[habitID] = log
            }
        }
        return result
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
    private func todayControls(for habit: Habit, todayLog: HabitLog?) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<habit.timesPerDay, id: \.self) { index in
                occurrenceCircle(habit: habit, index: index, todayLog: todayLog)
            }
        }
    }

    /// A checkbox for this one occurrence (index 0 = BrushTeeth.1, index 1
    /// = BrushTeeth.2, ...) — tapping toggles just that circle between
    /// complete and unselected, exactly mirroring what the matching
    /// scheduled block's own complete circle does from the Schedule tab
    /// (see `toggleOccurrence`), so the two stay in sync no matter which
    /// side you check it off from. Missed/excused overrides still only
    /// live on the habit's own calendar (`HabitDetailView`).
    private func occurrenceCircle(habit: Habit, index: Int, todayLog: HabitLog?) -> some View {
        let status = todayLog?.occurrenceStatus(index) ?? .none
        return Button {
            toggleOccurrence(habit: habit, index: index, todayLog: todayLog)
        } label: {
            Circle()
                .fill(fillColor(for: status))
                .frame(width: 36, height: 36)
                .overlay {
                    occurrenceIcon(for: status)
                }
        }
        .buttonStyle(.plain)
    }

    /// Toggles one occurrence between complete and unselected, keeping its
    /// matching `ScheduledBlock.isCompleted` (if that occurrence made it
    /// onto today's calendar) in sync, and drops that occurrence's own
    /// reminder notification when it's completed ahead of time — the same
    /// three effects `ScheduleReviewViewModel.toggleComplete` produces
    /// from the calendar side, just triggered from this circle instead.
    private func toggleOccurrence(habit: Habit, index: Int, todayLog: HabitLog?) {
        let today = calendar.startOfDay(for: .now)
        let log = todayLog ?? {
            let newLog = HabitLog(habit: habit, date: today)
            modelContext.insert(newLog)
            return newLog
        }()
        let isNowComplete = log.occurrenceStatus(index) != .complete
        log.setOccurrence(index, to: isNowComplete ? .complete : .none)

        if let block = (habit.scheduledBlocks ?? []).first(where: {
            $0.habitOccurrenceIndex == index && calendar.isDate($0.date, inSameDayAs: today)
        }) {
            block.isCompleted = isNowComplete
        }

        HabitNotificationService.shared.reschedule(habit)
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
        let ordered = liveSortedHabits
        for index in offsets {
            let habit = ordered[index]
            HabitNotificationService.shared.cancelAll(for: habit)
            modelContext.delete(habit)
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
