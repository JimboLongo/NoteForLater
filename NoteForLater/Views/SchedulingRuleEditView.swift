import SwiftUI
import SwiftData

/// Configures how a shelf pulls from a schedule it's already been assigned
/// (see ShelfEditView's "Assigned Schedules" — the window itself comes from
/// the NamedSchedule picked there and isn't editable here). This view just
/// sets the fill strategy (fill to fit / cap total time / cap task count
/// with a per-task time cap). Edits a local draft — nothing is written back
/// to the model until Save is tapped.
struct SchedulingRuleEditView: View {
    let rule: SchedulingRule
    @Environment(\.dismiss) private var dismiss

    @State private var isEnabled: Bool
    @State private var fillStrategy: FillStrategy
    @State private var maxTotalMinutes: Int
    @State private var maxTaskCount: Int
    @State private var maxMinutesPerTask: Int
    @State private var maxDurationTaskCountEnabled: Bool

    init(rule: SchedulingRule) {
        self.rule = rule
        _isEnabled = State(initialValue: rule.isEnabled)
        _fillStrategy = State(initialValue: rule.fillStrategy)
        _maxTotalMinutes = State(initialValue: rule.maxTotalMinutes)
        _maxTaskCount = State(initialValue: rule.maxTaskCount)
        _maxMinutesPerTask = State(initialValue: rule.maxMinutesPerTask)
        _maxDurationTaskCountEnabled = State(initialValue: rule.maxDurationTaskCountEnabled)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enabled", isOn: $isEnabled)
            }

            Section("Schedule") {
                if let schedule = rule.namedSchedule {
                    LabeledContent(schedule.name, value: schedule.dayAndTimeText)
                } else {
                    Text("No schedule assigned — remove this and add it again from the shelf's Assigned Schedules section.")
                        .foregroundStyle(.secondary)
                }
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
                    Toggle("Limit number of tasks", isOn: $maxDurationTaskCountEnabled.animation())
                    if maxDurationTaskCountEnabled {
                        Stepper("Up to \(maxTaskCount) task\(maxTaskCount == 1 ? "" : "s")", value: $maxTaskCount, in: 1...10)
                    }
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
        .navigationTitle(rule.displayName.isEmpty ? "Pull Schedule" : rule.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Save") { save() }
            }
        }
    }

    private var previewSummary: String {
        SchedulingRule.summaryText(
            daysOfWeek: rule.effectiveDaysOfWeek,
            startHour: rule.effectiveStartHour,
            startMinute: rule.effectiveStartMinute,
            endHour: rule.effectiveEndHour,
            endMinute: rule.effectiveEndMinute,
            fillStrategy: fillStrategy,
            maxTotalMinutes: maxTotalMinutes,
            maxTaskCount: maxTaskCount,
            maxMinutesPerTask: maxMinutesPerTask,
            maxDurationTaskCountEnabled: maxDurationTaskCountEnabled
        )
    }

    private func save() {
        rule.isEnabled = isEnabled
        rule.fillStrategy = fillStrategy
        rule.maxTotalMinutes = maxTotalMinutes
        rule.maxTaskCount = maxTaskCount
        rule.maxMinutesPerTask = maxMinutesPerTask
        rule.maxDurationTaskCountEnabled = maxDurationTaskCountEnabled
        dismiss()
    }
}

struct DayToggleChip: View {
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
    .modelContainer(for: [TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self, Habit.self, HabitLog.self], inMemory: true)
}
