import SwiftUI
import SwiftData

/// Create/edit a habit's schedule: name, start date, how many times a day,
/// which days it applies to, and one reminder time per occurrence.
/// Draft-and-Save — nothing writes back until Save is tapped, at which
/// point the reminder notifications get rescheduled to match.
struct HabitEditView: View {
    let habit: Habit
    var focusNameOnAppear = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isNameFocused: Bool

    @State private var name: String
    @State private var startDate: Date
    @State private var timesPerDay: Int
    @State private var daysOfWeek: [Int]
    @State private var reminderTimesOfDay: [Int]

    init(habit: Habit, focusNameOnAppear: Bool = false) {
        self.habit = habit
        self.focusNameOnAppear = focusNameOnAppear
        _name = State(initialValue: habit.name)
        _startDate = State(initialValue: habit.startDate)
        _timesPerDay = State(initialValue: habit.timesPerDay)
        _daysOfWeek = State(initialValue: habit.daysOfWeek)
        _reminderTimesOfDay = State(initialValue: habit.reminderTimesOfDay)
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Habit name", text: $name)
                    .focused($isNameFocused)
            }

            Section("Start Date") {
                DatePicker("Start Date", selection: $startDate, displayedComponents: [.date])
            }

            Section {
                Stepper("\(timesPerDay)x per day", value: $timesPerDay, in: 1...10)
                    .onChange(of: timesPerDay) { _, newValue in
                        adjustReminderCount(to: newValue)
                    }
            } header: {
                Text("Frequency")
            }

            Section("Days") {
                HStack(spacing: 8) {
                    ForEach(SchedulingRule.dayLabels, id: \.weekday) { day in
                        DayToggleChip(
                            label: day.short,
                            isOn: daysOfWeek.contains(day.weekday)
                        ) {
                            toggleDay(day.weekday)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }

            Section {
                ForEach(reminderTimesOfDay.indices, id: \.self) { index in
                    DatePicker(
                        "Reminder \(index + 1)",
                        selection: reminderBinding(for: index),
                        displayedComponents: [.hourAndMinute]
                    )
                }
            } header: {
                Text("Reminders")
            } footer: {
                Text("One reminder per occurrence, on each day above.")
            }
        }
        .navigationTitle(name.isEmpty ? "Habit" : name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Save", action: save)
            }
        }
        .onAppear {
            if focusNameOnAppear { isNameFocused = true }
        }
    }

    private func adjustReminderCount(to count: Int) {
        if reminderTimesOfDay.count < count {
            let lastMinute = reminderTimesOfDay.last ?? 8 * 60
            let toAdd = count - reminderTimesOfDay.count
            for step in 1...toAdd {
                reminderTimesOfDay.append(min(lastMinute + step * 120, 23 * 60 + 59))
            }
        } else if reminderTimesOfDay.count > count {
            reminderTimesOfDay.removeLast(reminderTimesOfDay.count - count)
        }
    }

    private func toggleDay(_ weekday: Int) {
        if daysOfWeek.contains(weekday) {
            daysOfWeek.removeAll { $0 == weekday }
        } else {
            daysOfWeek.append(weekday)
        }
    }

    private func reminderBinding(for index: Int) -> Binding<Date> {
        Binding(
            get: {
                let minutes = reminderTimesOfDay[index]
                return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now
            },
            set: { newValue in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                reminderTimesOfDay[index] = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            }
        )
    }

    private func save() {
        habit.name = name
        habit.startDate = Calendar.current.startOfDay(for: startDate)
        habit.timesPerDay = timesPerDay
        habit.daysOfWeek = daysOfWeek
        habit.reminderTimesOfDay = reminderTimesOfDay
        HabitNotificationService.shared.reschedule(habit)
        dismiss()
    }
}

#Preview {
    NavigationStack {
        HabitEditView(habit: Habit(name: "Drink Water"))
    }
    .modelContainer(for: [InboxItem.self, TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self, Habit.self, HabitLog.self], inMemory: true)
}
