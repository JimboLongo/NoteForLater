import SwiftUI
import SwiftData

/// Configures one pull window for a shelf: which days, what time range,
/// and how much to pull in (fill to fit / cap total time / cap task count
/// with a per-task time cap). Edits a local draft — nothing is written back
/// to the model until Save is tapped.
struct SchedulingRuleEditView: View {
    let rule: SchedulingRule
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var isEnabled: Bool
    @State private var daysOfWeek: [Int]
    @State private var startHour: Int
    @State private var startMinute: Int
    @State private var endHour: Int
    @State private var endMinute: Int
    @State private var fillStrategy: FillStrategy
    @State private var maxTotalMinutes: Int
    @State private var maxTaskCount: Int
    @State private var maxMinutesPerTask: Int

    init(rule: SchedulingRule) {
        self.rule = rule
        _name = State(initialValue: rule.name)
        _isEnabled = State(initialValue: rule.isEnabled)
        _daysOfWeek = State(initialValue: rule.daysOfWeek)
        _startHour = State(initialValue: rule.startHour)
        _startMinute = State(initialValue: rule.startMinute)
        _endHour = State(initialValue: rule.endHour)
        _endMinute = State(initialValue: rule.endMinute)
        _fillStrategy = State(initialValue: rule.fillStrategy)
        _maxTotalMinutes = State(initialValue: rule.maxTotalMinutes)
        _maxTaskCount = State(initialValue: rule.maxTaskCount)
        _maxMinutesPerTask = State(initialValue: rule.maxMinutesPerTask)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enabled", isOn: $isEnabled)
                TextField("Name (optional)", text: $name)
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
                DatePicker(
                    "Start",
                    selection: startTimeBinding,
                    displayedComponents: [.hourAndMinute]
                )
                DatePicker(
                    "End",
                    selection: endTimeBinding,
                    displayedComponents: [.hourAndMinute]
                )
            }

            Section("Fill Strategy") {
                Picker("Fill Strategy", selection: $fillStrategy) {
                    ForEach(FillStrategy.allCases) { strategy in
                        Text(strategy.label).tag(strategy)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch fillStrategy {
                case .fillToFit:
                    Text("Packs as many tasks as fit in the window, highest priority first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .maxDuration:
                    Stepper("Up to \(TaskItem.durationLabel(for: maxTotalMinutes)) total", value: $maxTotalMinutes, in: 15...480, step: 15)
                case .maxTaskCount:
                    Stepper("Up to \(maxTaskCount) task\(maxTaskCount == 1 ? "" : "s")", value: $maxTaskCount, in: 1...10)
                    Stepper("\(maxMinutesPerTask) min max per task", value: $maxMinutesPerTask, in: 5...240, step: 5)
                }
            }

            Section {
                Text(previewSummary)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Preview")
            }
        }
        .navigationTitle(name.isEmpty ? "Pull Schedule" : name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Save") { save() }
            }
        }
    }

    private var previewSummary: String {
        SchedulingRule.summaryText(
            daysOfWeek: daysOfWeek,
            startHour: startHour, startMinute: startMinute,
            endHour: endHour, endMinute: endMinute,
            fillStrategy: fillStrategy,
            maxTotalMinutes: maxTotalMinutes,
            maxTaskCount: maxTaskCount,
            maxMinutesPerTask: maxMinutesPerTask
        )
    }

    private func save() {
        rule.name = name
        rule.isEnabled = isEnabled
        rule.daysOfWeek = daysOfWeek
        rule.startHour = startHour
        rule.startMinute = startMinute
        rule.endHour = endHour
        rule.endMinute = endMinute
        rule.fillStrategy = fillStrategy
        rule.maxTotalMinutes = maxTotalMinutes
        rule.maxTaskCount = maxTaskCount
        rule.maxMinutesPerTask = maxMinutesPerTask
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

private struct DayToggleChip: View {
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
        SchedulingRuleEditView(rule: SchedulingRule(shelf: Shelf(name: "Work")))
    }
    .modelContainer(for: [InboxItem.self, TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, LocationTag.self], inMemory: true)
}
