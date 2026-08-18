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
                HStack {
                    Text("Start")
                    Spacer()
                    QuarterHourDatePicker(date: startTimeBinding)
                }
                HStack {
                    Text("End")
                    Spacer()
                    QuarterHourDatePicker(date: endTimeBinding)
                }
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
        // Every rule that references this schedule (on any shelf) shares
        // its window — a save here can change what any of them actually
        // means, even though nothing about the rules themselves changed.
        ScheduleDirtyState.shared.isDirty = true
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

/// Wraps `UIDatePicker` directly (rather than SwiftUI's `DatePicker`) since
/// SwiftUI exposes no way to set `minuteInterval` — this is the only way to
/// make the popover wheel itself only offer :00/:15/:30/:45, instead of
/// snapping an arbitrary-minute selection after the fact.
private struct QuarterHourDatePicker: UIViewRepresentable {
    @Binding var date: Date

    func makeUIView(context: Context) -> UIDatePicker {
        let picker = UIDatePicker()
        picker.datePickerMode = .time
        picker.preferredDatePickerStyle = .compact
        picker.minuteInterval = 15
        picker.date = date
        picker.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return picker
    }

    func updateUIView(_ uiView: UIDatePicker, context: Context) {
        if uiView.date != date {
            uiView.date = date
        }
    }

    /// Without this, SwiftUI sizes the representable off `intrinsicContentSize`
    /// — which for a `.compact`-style `UIDatePicker` can still read as zero
    /// the first time SwiftUI asks (before UIKit's own internal layout pass
    /// has run), rendering it invisible. Asking the picker to fit itself
    /// directly sidesteps that timing gap.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIDatePicker, context: Context) -> CGSize? {
        uiView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: QuarterHourDatePicker
        init(_ parent: QuarterHourDatePicker) { self.parent = parent }
        @objc func changed(_ sender: UIDatePicker) {
            parent.date = sender.date
        }
    }
}
