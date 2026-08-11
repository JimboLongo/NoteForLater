import SwiftUI
import SwiftData

/// Configures one global "the AI Scheduler is allowed to run here" window —
/// days + time range, no fill strategy (that's per-shelf). Edits a local
/// draft; nothing is written back until Save is tapped.
struct EligibleHoursEditView: View {
    let window: EligibleHoursWindow
    @Environment(\.dismiss) private var dismiss

    @State private var isEnabled: Bool
    @State private var daysOfWeek: [Int]
    @State private var startHour: Int
    @State private var startMinute: Int
    @State private var endHour: Int
    @State private var endMinute: Int

    init(window: EligibleHoursWindow) {
        self.window = window
        _isEnabled = State(initialValue: window.isEnabled)
        _daysOfWeek = State(initialValue: window.daysOfWeek)
        _startHour = State(initialValue: window.startHour)
        _startMinute = State(initialValue: window.startMinute)
        _endHour = State(initialValue: window.endHour)
        _endMinute = State(initialValue: window.endMinute)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enabled", isOn: $isEnabled)
            }

            Section("Days") {
                HStack(spacing: 8) {
                    ForEach(SchedulingRule.dayLabels, id: \.weekday) { day in
                        DayChip(label: day.short, isOn: daysOfWeek.contains(day.weekday)) {
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
                Text(previewSummary)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Preview")
            }
        }
        .navigationTitle("Eligible Hours")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Save") { save() }
            }
        }
    }

    private var previewSummary: String {
        SchedulingRule.dayAndTimeText(daysOfWeek: daysOfWeek, startHour: startHour, startMinute: startMinute, endHour: endHour, endMinute: endMinute)
    }

    private func save() {
        window.isEnabled = isEnabled
        window.daysOfWeek = daysOfWeek
        window.startHour = startHour
        window.startMinute = startMinute
        window.endHour = endHour
        window.endMinute = endMinute
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

private struct DayChip: View {
    let label: String
    let isOn: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(label)
                .font(.caption)
                .fontWeight(isOn ? .semibold : .regular)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(isOn ? Color.accentColor : Color.secondary.opacity(0.15))
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NavigationStack {
        EligibleHoursEditView(window: EligibleHoursWindow())
    }
    .modelContainer(for: [TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self, Habit.self, HabitLog.self], inMemory: true)
}
