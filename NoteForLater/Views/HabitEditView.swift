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
    @Environment(\.modelContext) private var modelContext
    @FocusState private var isNameFocused: Bool

    @State private var name: String
    @State private var startDate: Date
    @State private var timesPerDay: Int
    @State private var daysOfWeek: [Int]
    @State private var idealTimesOfDay: [Int]
    @State private var reminderTimesOfDay: [Int]
    @State private var estimatedMinutes: Int
    @State private var missThreshold: Double

    private static let durationOptions = [5, 10, 15, 20, 30, 45, 60, 90, 120]
    private static let thresholdOptions = [0.6, 0.65, 0.7, 0.75, 0.8, 0.85, 0.9, 0.95, 1.0]

    init(habit: Habit, focusNameOnAppear: Bool = false) {
        self.habit = habit
        self.focusNameOnAppear = focusNameOnAppear
        _name = State(initialValue: habit.name)
        _startDate = State(initialValue: habit.startDate)
        _timesPerDay = State(initialValue: habit.timesPerDay)
        _daysOfWeek = State(initialValue: habit.daysOfWeek)
        // Resized to `timesPerDay` right here, defensively — a habit
        // whose `idealTimesOfDay`/`reminderTimesOfDay` fell out of sync
        // with `timesPerDay` (e.g. one created without going through this
        // view's own Stepper, which is the only other place they're kept
        // in sync) would otherwise silently hide some occurrences' rows
        // below, since that list is driven by these arrays' own counts.
        var ideal = habit.idealTimesOfDay
        var reminders = habit.reminderTimesOfDay
        Self.adjustCount(&ideal, to: habit.timesPerDay)
        Self.adjustCount(&reminders, to: habit.timesPerDay)
        _idealTimesOfDay = State(initialValue: ideal)
        _reminderTimesOfDay = State(initialValue: reminders)
        _estimatedMinutes = State(initialValue: habit.estimatedMinutes)
        _missThreshold = State(initialValue: habit.missThreshold)
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
                        Self.adjustCount(&idealTimesOfDay, to: newValue)
                        Self.adjustCount(&reminderTimesOfDay, to: newValue)
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
                Picker("Duration", selection: $estimatedMinutes) {
                    ForEach(Self.durationOptions, id: \.self) { minutes in
                        Text(Habit.durationLabel(for: minutes)).tag(minutes)
                    }
                }
            } header: {
                Text("Scheduling")
            } footer: {
                Text("The AI Scheduler blocks off \(Habit.durationLabel(for: estimatedMinutes)) for this habit on any applicable day it isn't done yet, exactly at its first Target Time.")
            }

            Section {
                ForEach(idealTimesOfDay.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 4) {
                        if idealTimesOfDay.count > 1 {
                            Text("Occurrence \(index + 1)")
                                .font(.subheadline.weight(.semibold))
                        }

                        HStack(spacing: 24) {
                            VStack(spacing: 10) {
                                Text("Target Time")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                WrappingTimePicker(minutes: $idealTimesOfDay[index])
                                    .frame(width: 148, height: 100)
                                    .clipped()
                            }
                            VStack(spacing: 10) {
                                Text("Reminder Time")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                WrappingTimePicker(minutes: $reminderTimesOfDay[index])
                                    .frame(width: 148, height: 100)
                                    .clipped()
                            }
                            .padding(.leading, 12)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Times")
            } footer: {
                Text("Target Time is exactly when the AI Scheduler places this habit. Reminder Time is when you get notified — they don't have to match.")
            }

            Section {
                Picker("Consistency Threshold", selection: $missThreshold) {
                    ForEach(Self.thresholdOptions, id: \.self) { value in
                        Text("\(Int((value * 100).rounded()))%").tag(value)
                    }
                }
            } header: {
                Text("Misses Remaining")
            } footer: {
                Text("The Rolling 30 stat must stay at or above this to avoid using up your allowed misses for the trailing 30 days.")
            }
        }
        .navigationTitle(name.isEmpty ? "Habit" : name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: cancel)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Save", action: save)
            }
        }
        .onAppear {
            if focusNameOnAppear { isNameFocused = true }
        }
    }

    /// Shared by `idealTimesOfDay` and `reminderTimesOfDay` — both are
    /// one-per-occurrence arrays that need to track `timesPerDay`.
    private static func adjustCount(_ times: inout [Int], to count: Int) {
        if times.count < count {
            let lastMinute = times.last ?? 8 * 60
            let toAdd = count - times.count
            for step in 1...toAdd {
                times.append(min(lastMinute + step * 120, 23 * 60 + 50))
            }
        } else if times.count > count {
            times.removeLast(times.count - count)
        }
    }

    private func toggleDay(_ weekday: Int) {
        if daysOfWeek.contains(weekday) {
            daysOfWeek.removeAll { $0 == weekday }
        } else {
            daysOfWeek.append(weekday)
        }
    }

    /// `focusNameOnAppear` is only ever true for a brand-new habit
    /// (HabitsView inserts it into the model *before* presenting this
    /// sheet, so the name field has something to focus into) — cancelling
    /// that flow deletes the still-blank draft rather than leaving an
    /// orphaned unnamed habit behind. Editing an existing habit just
    /// dismisses: nothing here writes back until `save()` runs anyway.
    private func cancel() {
        if focusNameOnAppear {
            modelContext.delete(habit)
        }
        dismiss()
    }

    private func save() {
        habit.name = name
        habit.startDate = Calendar.current.startOfDay(for: startDate)
        habit.timesPerDay = timesPerDay
        habit.daysOfWeek = daysOfWeek
        habit.idealTimesOfDay = idealTimesOfDay
        habit.reminderTimesOfDay = reminderTimesOfDay
        habit.estimatedMinutes = estimatedMinutes
        habit.missThreshold = missThreshold
        HabitNotificationService.shared.reschedule(habit)
        dismiss()
    }
}

/// A single continuous, wrapping wheel — unlike `UIDatePicker`'s `.wheels`
/// style (always three separate hour/minute/AM-PM columns), this is one
/// `UIPickerView` component listing every 10-minute slot in a day as one
/// formatted row ("3:40 PM"), so scrolling past 11:50 PM lands back on
/// 12:00 AM and vice versa. True infinite scroll isn't a thing UIKit
/// offers, so this fakes it with a large number of repeated cycles of the
/// same 144 rows and lets `didSelectRow`/`scrollToCurrent` work in row-mod
/// space — plenty of room to keep scrolling either direction before
/// hitting a real edge.
private struct WrappingTimePicker: UIViewRepresentable {
    @Binding var minutes: Int

    fileprivate static let slotCount = 24 * 6
    private static let cycles = 200
    fileprivate static let totalRows = slotCount * cycles

    func makeUIView(context: Context) -> UIPickerView {
        let picker = UIPickerView()
        picker.dataSource = context.coordinator
        picker.delegate = context.coordinator
        picker.clipsToBounds = true
        DispatchQueue.main.async {
            context.coordinator.scrollToCurrent(picker, animated: false)
        }
        return picker
    }

    func updateUIView(_ uiView: UIPickerView, context: Context) {
        context.coordinator.parent = self
        // Bounds are 0 at first layout (before SwiftUI assigns the real
        // frame), so `widthForComponent` initially falls back to a guess —
        // reload once real bounds are in so the component actually sizes
        // to fit this specific view instead of clipping/overflowing it.
        // Guarded to fire only once: reloading on every update (which
        // happens on every scroll selection) would visually hiccup.
        if !context.coordinator.hasSizedToBounds && uiView.bounds.width > 0 {
            context.coordinator.hasSizedToBounds = true
            uiView.reloadAllComponents()
        }
        let selectedRow = uiView.selectedRow(inComponent: 0)
        let currentMinutes = (selectedRow % Self.slotCount) * 10
        if currentMinutes != minutes {
            context.coordinator.scrollToCurrent(uiView, animated: false)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIPickerViewDataSource, UIPickerViewDelegate {
        var parent: WrappingTimePicker
        var hasSizedToBounds = false
        init(_ parent: WrappingTimePicker) {
            self.parent = parent
        }

        func numberOfComponents(in pickerView: UIPickerView) -> Int { 1 }

        func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
            WrappingTimePicker.totalRows
        }

        /// UIPickerView does NOT shrink its component to fit its own view
        /// bounds by default — left unset, a single component defaults to
        /// a fixed width wide enough for a full standalone picker, which
        /// overflows and clips when the view itself is squeezed into half
        /// a screen next to another picker. Tying it explicitly to the
        /// view's actual (SwiftUI-assigned) width is what makes it
        /// actually fit.
        func pickerView(_ pickerView: UIPickerView, widthForComponent component: Int) -> CGFloat {
            pickerView.bounds.width > 0 ? pickerView.bounds.width - 4 : 140
        }

        func pickerView(_ pickerView: UIPickerView, rowHeightForComponent component: Int) -> CGFloat {
            32
        }

        func pickerView(_ pickerView: UIPickerView, attributedTitleForRow row: Int, forComponent component: Int) -> NSAttributedString? {
            NSAttributedString(
                string: Self.label(forMinutes: (row % WrappingTimePicker.slotCount) * 10),
                attributes: [.font: UIFont.systemFont(ofSize: 15)]
            )
        }

        func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
            parent.minutes = (row % WrappingTimePicker.slotCount) * 10
        }

        func scrollToCurrent(_ pickerView: UIPickerView, animated: Bool) {
            let slot = parent.minutes / 10
            let middleCycle = (WrappingTimePicker.totalRows / WrappingTimePicker.slotCount) / 2
            let row = middleCycle * WrappingTimePicker.slotCount + slot
            pickerView.selectRow(row, inComponent: 0, animated: animated)
        }

        static func label(forMinutes minutes: Int) -> String {
            let hour24 = minutes / 60
            let minute = minutes % 60
            let period = hour24 < 12 ? "AM" : "PM"
            var hour12 = hour24 % 12
            if hour12 == 0 { hour12 = 12 }
            return String(format: "%d:%02d %@", hour12, minute, period)
        }
    }
}

#Preview {
    NavigationStack {
        HabitEditView(habit: Habit(name: "Drink Water"))
    }
    .modelContainer(for: [TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self, Habit.self, HabitLog.self], inMemory: true)
}
