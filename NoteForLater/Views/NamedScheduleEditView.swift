import SwiftUI
import SwiftData

/// Edits one reusable day/time window (e.g. "Work" Mon–Fri 9–5). Draft-and-
/// Save like the other schedule editors — nothing writes back to the model
/// until Save is tapped.
struct NamedScheduleEditView: View {
    let schedule: NamedSchedule
    /// True when this editor was opened straight from "Add Schedule" — puts
    /// the cursor in the Name field immediately so you can start typing.
    var focusNameOnAppear = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isNameFocused: Bool

    @State private var name: String
    @State private var daysOfWeek: [Int]
    @State private var startHour: Int
    @State private var startMinute: Int
    @State private var endHour: Int
    @State private var endMinute: Int

    init(schedule: NamedSchedule, focusNameOnAppear: Bool = false) {
        self.schedule = schedule
        self.focusNameOnAppear = focusNameOnAppear
        _name = State(initialValue: schedule.name)
        _daysOfWeek = State(initialValue: schedule.daysOfWeek)
        _startHour = State(initialValue: schedule.startHour)
        _startMinute = State(initialValue: schedule.startMinute)
        _endHour = State(initialValue: schedule.endHour)
        _endMinute = State(initialValue: schedule.endMinute)
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Schedule name", text: $name)
                    .focused($isNameFocused)
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

            Section("Time Window") {
                DatePicker("Start", selection: startTimeBinding, displayedComponents: [.hourAndMinute])
                DatePicker("End", selection: endTimeBinding, displayedComponents: [.hourAndMinute])
            }

            Section {
                Text(previewText)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Preview")
            } footer: {
                Text("Any shelf's pull schedule can reference this window from the \"Schedule\" picker.")
            }
        }
        .navigationTitle(name.isEmpty ? "Schedule" : name)
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

    private var previewText: String {
        SchedulingRule.dayAndTimeText(
            daysOfWeek: daysOfWeek,
            startHour: startHour, startMinute: startMinute,
            endHour: endHour, endMinute: endMinute
        )
    }

    private func save() {
        schedule.name = name
        schedule.daysOfWeek = daysOfWeek
        schedule.startHour = startHour
        schedule.startMinute = startMinute
        schedule.endHour = endHour
        schedule.endMinute = endMinute
        dismiss()
    }

    private func toggleDay(_ weekday: Int) {
        if daysOfWeek.contains(weekday) {
            daysOfWeek.removeAll { $0 == weekday }
        } else {
            daysOfWeek.append(weekday)
        }
    }

    private var startTimeBinding: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: startHour, minute: startMinute, second: 0, of: .now) ?? .now },
            set: { newValue in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                startHour = components.hour ?? startHour
                startMinute = components.minute ?? startMinute
            }
        )
    }

    private var endTimeBinding: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: endHour, minute: endMinute, second: 0, of: .now) ?? .now },
            set: { newValue in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                endHour = components.hour ?? endHour
                endMinute = components.minute ?? endMinute
            }
        )
    }
}

#Preview {
    NavigationStack {
        NamedScheduleEditView(schedule: NamedSchedule(name: "Work"))
    }
    .modelContainer(for: [TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self, Habit.self, HabitLog.self], inMemory: true)
}
