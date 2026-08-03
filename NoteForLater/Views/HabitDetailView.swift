import SwiftUI
import SwiftData

/// Stats + calendar for one habit. Tap any applicable past-or-today day in
/// the calendar to set it to Yes/No/Excused; excused days are shown but
/// omitted entirely from streak and % complete math.
struct HabitDetailView: View {
    @Bindable var habit: Habit
    @Environment(\.modelContext) private var modelContext
    @State private var displayedMonth: Date = .now
    @State private var pickerDate: Date?

    private let calendar = Calendar.current

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                statsGrid
                calendarSection
            }
            .padding()
        }
        .navigationTitle(habit.name.isEmpty ? "Habit" : habit.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink("Edit") {
                    HabitEditView(habit: habit)
                }
            }
        }
        .confirmationDialog(
            "Mark Day",
            isPresented: Binding(get: { pickerDate != nil }, set: { if !$0 { pickerDate = nil } }),
            presenting: pickerDate
        ) { date in
            Button("Yes") { log(for: date).markAllComplete(timesPerDay: habit.timesPerDay); pickerDate = nil }
            Button("No") { log(for: date).markAllMissed(timesPerDay: habit.timesPerDay); pickerDate = nil }
            Button("Excused") { log(for: date).markAllExcused(timesPerDay: habit.timesPerDay); pickerDate = nil }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            StatTile(title: "Current Streak", value: habit.currentStreakDisplay, color: streakColor(habit.currentStreak()))
            StatTile(title: "Max Streak", value: habit.maxStreakDisplay, color: streakColor(habit.displayMaxStreak()))
            StatTile(title: "MTD % Complete", value: habit.mtdPercentDisplay, color: .primary)
            StatTile(title: "LTD % Complete", value: habit.ltdPercentDisplay, color: .primary)
        }
    }

    private func streakColor(_ value: Int) -> Color {
        if value > 0 { return .green }
        if value < 0 { return .red }
        return .primary
    }

    private var calendarSection: some View {
        VStack(spacing: 12) {
            HStack {
                Button {
                    changeMonth(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                Spacer()
                Text(monthTitle)
                    .font(.headline)
                Spacer()
                Button {
                    changeMonth(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 6) {
                ForEach(Array(calendar.veryShortWeekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(daysInGrid.enumerated()), id: \.offset) { _, day in
                    if let day {
                        dayCell(day)
                    } else {
                        Color.clear.frame(minHeight: 32)
                    }
                }
            }

            legend
        }
    }

    private var legend: some View {
        HStack(spacing: 16) {
            legendItem(color: .green, label: "Yes")
            legendItem(color: .red, label: "No")
            legendItem(color: .orange, label: "Excused")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color.opacity(0.5)).frame(width: 8, height: 8)
            Text(label)
        }
    }

    private func dayCell(_ date: Date) -> some View {
        let isApplicable = habit.isApplicable(on: date, calendar: calendar)
        let isFuture = date > calendar.startOfDay(for: .now)
        let isBeforeStart = date < calendar.startOfDay(for: habit.startDate)
        let canTap = isApplicable && !isFuture && !isBeforeStart
        // nil = pending (today, not yet resolved) — same neutral color as a
        // day that isn't applicable/tappable, not colored like a real miss.
        let status = habit.status(on: date, calendar: calendar)

        return Text("\(calendar.component(.day, from: date))")
            .font(.caption)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(cellColor(status: status, isApplicable: isApplicable, canTap: canTap))
            .foregroundStyle(canTap ? .primary : .secondary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onTapGesture {
                guard canTap else { return }
                pickerDate = date
            }
    }

    private func cellColor(status: HabitCompletionStatus?, isApplicable: Bool, canTap: Bool) -> Color {
        guard isApplicable, canTap, let status else { return Color.secondary.opacity(canTap ? 0.15 : 0.08) }
        switch status {
        case .yes: return .green.opacity(0.35)
        case .no: return .red.opacity(0.2)
        case .excused: return .orange.opacity(0.3)
        }
    }

    private var daysInGrid: [Date?] {
        guard
            let monthInterval = calendar.dateInterval(of: .month, for: displayedMonth),
            let daysInMonth = calendar.range(of: .day, in: .month, for: displayedMonth)?.count
        else { return [] }

        let firstDay = monthInterval.start
        let leadingBlanks = calendar.component(.weekday, from: firstDay) - 1

        var result: [Date?] = Array(repeating: nil, count: leadingBlanks)
        for dayOffset in 0..<daysInMonth {
            if let date = calendar.date(byAdding: .day, value: dayOffset, to: firstDay) {
                result.append(date)
            }
        }
        return result
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: displayedMonth)
    }

    private func changeMonth(by value: Int) {
        displayedMonth = calendar.date(byAdding: .month, value: value, to: displayedMonth) ?? displayedMonth
    }

    /// Finds today's/this day's log, creating and inserting one if needed.
    private func log(for date: Date) -> HabitLog {
        if let existing = habit.log(on: date, calendar: calendar) {
            return existing
        }
        let newLog = HabitLog(habit: habit, date: calendar.startOfDay(for: date))
        modelContext.insert(newLog)
        return newLog
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    var color: Color = .primary

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    NavigationStack {
        HabitDetailView(habit: Habit(name: "Drink Water", timesPerDay: 4))
    }
    .modelContainer(for: [InboxItem.self, TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self, Habit.self, HabitLog.self], inMemory: true)
}
