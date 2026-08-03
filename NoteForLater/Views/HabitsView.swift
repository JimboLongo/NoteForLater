import SwiftUI
import SwiftData

/// The "Habits" tab: two swipeable pages — Today (mark each habit
/// Yes/No/Excused for today) and Stats (every habit's numbers at a glance).
/// The segmented control at top is a second way to switch, kept in sync
/// with the swipe.
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

                TabView(selection: $selectedPage) {
                    HabitsTodayView(habits: habits)
                        .tag(0)
                    HabitsStatsView(habits: habits)
                        .tag(1)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
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
/// menu for the day-level Excused/Missed overrides.
struct HabitsTodayView: View {
    let habits: [Habit]
    @Environment(\.modelContext) private var modelContext
    private let calendar = Calendar.current

    var body: some View {
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
                                .lineLimit(1)
                            streakLine(for: habit)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: 180, alignment: .leading)
                    Spacer(minLength: 8)
                    if habit.isApplicable(on: .now, calendar: calendar) {
                        todayControls(for: habit)
                    } else {
                        Text("Not today")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete(perform: deleteHabits)
            .onMove(perform: moveHabits)
        }
    }

    private func streakLine(for habit: Habit) -> Text {
        Text("Streak ").foregroundStyle(.secondary)
            + Text(habit.currentStreakDisplay).foregroundStyle(streakColor(habit.currentStreak()))
            + Text(" · Max ").foregroundStyle(.secondary)
            + Text(habit.maxStreakDisplay).foregroundStyle(streakColor(habit.displayMaxStreak()))
    }

    private func streakColor(_ value: Int) -> Color {
        if value > 0 { return .green }
        if value < 0 { return .red }
        return .secondary
    }

    @ViewBuilder
    private func todayControls(for habit: Habit) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<habit.timesPerDay, id: \.self) { index in
                occurrenceCircle(habit: habit, index: index)
            }
            Menu {
                Button("Mark All Complete") { todayLog(for: habit).markAllComplete(timesPerDay: habit.timesPerDay) }
                Button("Mark All Excused") { todayLog(for: habit).markAllExcused(timesPerDay: habit.timesPerDay) }
                Button("Mark All Missed", role: .destructive) { todayLog(for: habit).markAllMissed(timesPerDay: habit.timesPerDay) }
                Button("Reset") { todayLog(for: habit).resetAll() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Tapping a circle cycles it through none → complete (green) → missed
    /// (red) → excused (greyed X) → none.
    private func occurrenceCircle(habit: Habit, index: Int) -> some View {
        let status = habit.occurrenceStatus(index, on: .now, calendar: calendar)
        return Button {
            todayLog(for: habit).cycleOccurrence(index)
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
            let habit = habits[index]
            HabitNotificationService.shared.cancelAll(for: habit)
            modelContext.delete(habit)
        }
    }

    private func moveHabits(from source: IndexSet, to destination: Int) {
        var reordered = habits
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, habit) in reordered.enumerated() {
            habit.sortOrder = index
        }
    }

    private func todayLog(for habit: Habit) -> HabitLog {
        if let existing = habit.log(on: .now, calendar: calendar) {
            return existing
        }
        let newLog = HabitLog(habit: habit, date: calendar.startOfDay(for: .now))
        modelContext.insert(newLog)
        return newLog
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
                NavigationLink {
                    HabitDetailView(habit: habit)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(habit.name)
                            .font(.headline)
                        HStack {
                            statItem("Streak", habit.currentStreakDisplay, color: streakColor(habit.currentStreak()))
                            statItem("Max", habit.maxStreakDisplay, color: streakColor(habit.displayMaxStreak()))
                            statItem("MTD", habit.mtdPercentDisplay, color: .primary)
                            statItem("LTD", habit.ltdPercentDisplay, color: .primary)
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
        .modelContainer(for: [InboxItem.self, TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self, Habit.self, HabitLog.self], inMemory: true)
}
