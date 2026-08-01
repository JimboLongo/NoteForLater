import SwiftUI
import SwiftData

/// Configures one pull window for a shelf: which days, what time range,
/// and how much to pull in (fill to fit / cap total time / cap task count
/// with a per-task time cap).
struct SchedulingRuleEditView: View {
    @Bindable var rule: SchedulingRule

    var body: some View {
        Form {
            Section {
                Toggle("Enabled", isOn: $rule.isEnabled)
                TextField("Name (optional)", text: $rule.name)
            }

            Section("Days") {
                HStack(spacing: 8) {
                    ForEach(SchedulingRule.dayLabels, id: \.weekday) { day in
                        DayToggleChip(
                            label: day.short,
                            isOn: rule.daysOfWeek.contains(day.weekday)
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
                Picker("Fill Strategy", selection: $rule.fillStrategy) {
                    ForEach(FillStrategy.allCases) { strategy in
                        Text(strategy.label).tag(strategy)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch rule.fillStrategy {
                case .fillToFit:
                    Text("Packs as many tasks as fit in the window, highest priority first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .maxDuration:
                    Stepper("Up to \(TaskItem.durationLabel(for: rule.maxTotalMinutes)) total", value: $rule.maxTotalMinutes, in: 15...480, step: 15)
                case .maxTaskCount:
                    Stepper("Up to \(rule.maxTaskCount) task\(rule.maxTaskCount == 1 ? "" : "s")", value: $rule.maxTaskCount, in: 1...10)
                    Stepper("\(rule.maxMinutesPerTask) min max per task", value: $rule.maxMinutesPerTask, in: 5...240, step: 5)
                }
            }

            Section {
                Text(rule.summary)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Preview")
            }
        }
        .navigationTitle(rule.name.isEmpty ? "Pull Schedule" : rule.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toggleDay(_ weekday: Int) {
        if rule.daysOfWeek.contains(weekday) {
            rule.daysOfWeek.removeAll { $0 == weekday }
        } else {
            rule.daysOfWeek.append(weekday)
        }
    }

    private var startTimeBinding: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: rule.startHour, minute: rule.startMinute, second: 0, of: .now) ?? .now },
            set: { newValue in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                rule.startHour = components.hour ?? rule.startHour
                rule.startMinute = components.minute ?? rule.startMinute
            }
        )
    }

    private var endTimeBinding: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: rule.endHour, minute: rule.endMinute, second: 0, of: .now) ?? .now },
            set: { newValue in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                rule.endHour = components.hour ?? rule.endHour
                rule.endMinute = components.minute ?? rule.endMinute
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
    .modelContainer(for: [InboxItem.self, TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self], inMemory: true)
}
