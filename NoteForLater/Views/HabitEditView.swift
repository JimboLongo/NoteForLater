import SwiftUI
import SwiftData

/// Create/edit a habit's schedule: name, start date, how many times a day,
/// which days it applies to, and — per occurrence — either a specific
/// Target Time on the calendar or an AM/Midday/PM untimed list slot (see
/// `HabitOccurrenceTimeMode`). No separate reminder time anymore — habits
/// don't get their own push notification (see the Daily Check-Ins digest
/// in Settings instead). Draft-and-Save — nothing writes back until Save
/// is tapped.
struct HabitEditView: View {
    let habit: Habit
    var focusNameOnAppear = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @FocusState private var isNameFocused: Bool

    /// Used only to keep today's calendar immediately in sync with an
    /// occurrence's time-mode change on Save (see
    /// `placeNewlySpecificOccurrencesToday`/`removeStaleBlocks`) — habits
    /// place themselves unconditionally regardless of free/busy (see
    /// `AISchedulingService`'s own doc comment), so this never actually
    /// needs a real network fetch; `calendarService` is only here for the
    /// Google Calendar cleanup half of removing a now-stale block.
    private let calendarService: CalendarServiceProtocol = GoogleCalendarService()
    private let schedulingService: AISchedulingServiceProtocol = MockAISchedulingService()

    @State private var name: String
    @State private var startDate: Date
    @State private var timesPerDay: Int
    @State private var daysOfWeek: [Int]
    @State private var idealTimesOfDay: [Int]
    @State private var occurrenceTimeModes: [HabitOccurrenceTimeMode]
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
        // whose `idealTimesOfDay` fell out of sync with `timesPerDay`
        // (e.g. one created without going through this view's own
        // Stepper, which is the only other place they're kept in sync)
        // would otherwise silently hide some occurrences' rows below,
        // since that list is driven by this array's own count.
        var ideal = habit.idealTimesOfDay
        Self.adjustCount(&ideal, to: habit.timesPerDay)
        _idealTimesOfDay = State(initialValue: ideal)
        var modes = (0..<habit.timesPerDay).map { habit.timeMode(for: $0) }
        Self.adjustModeCount(&modes, to: habit.timesPerDay)
        _occurrenceTimeModes = State(initialValue: modes)
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
                        Self.adjustModeCount(&occurrenceTimeModes, to: newValue)
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
                ForEach(idealTimesOfDay.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            if idealTimesOfDay.count > 1 {
                                Text("Occurrence \(index + 1)")
                                    .font(.subheadline.weight(.semibold))
                            }
                            Spacer()
                            Picker("Time", selection: $occurrenceTimeModes[index]) {
                                ForEach(HabitOccurrenceTimeMode.allCases) { mode in
                                    Text(mode.label).tag(mode)
                                }
                            }
                            .pickerStyle(.menu)
                        }

                        if occurrenceTimeModes[index] == .specific {
                            VStack(spacing: 10) {
                                Text("Target Time")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                WrappingTimePicker(minutes: $idealTimesOfDay[index])
                                    .frame(width: 148, height: 100)
                                    .clipped()
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .animation(.easeInOut(duration: 0.15), value: occurrenceTimeModes[index])
                }
            } header: {
                Text("Times")
            } footer: {
                Text("Specific Time places this habit on the calendar at its own Target Time, exactly like before. AM, Midday, or PM instead lists it as a plain check-off item in that part of the day — above the calendar, splitting it at noon, or below it — rather than at a fixed time. Check the Daily Check-Ins digest in Settings if you want a push notification for what's still open.")
            }

            // Duration is only meaningful for a calendar-placed
            // occurrence — an AM/Midday/PM one never gets a start/end
            // time to size in the first place (see
            // `AISchedulingService.placeHabitsAndRecurringTasks`), so
            // this stays hidden entirely unless at least one occurrence
            // is still Specific Time.
            if occurrenceTimeModes.contains(.specific) {
                Section {
                    Picker("Duration", selection: $estimatedMinutes) {
                        ForEach(Self.durationOptions, id: \.self) { minutes in
                            Text(Habit.durationLabel(for: minutes)).tag(minutes)
                        }
                    }
                } header: {
                    Text("Scheduling")
                } footer: {
                    Text("The AI Scheduler blocks off \(Habit.durationLabel(for: estimatedMinutes)) for this habit on any applicable day it isn't done yet, exactly at its first Specific-Time occurrence.")
                }
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

    /// Same idea as `adjustCount`, for `occurrenceTimeModes` — a newly
    /// added occurrence (bumping `timesPerDay` up) defaults to `.specific`
    /// same as every occurrence did before this setting existed.
    private static func adjustModeCount(_ modes: inout [HabitOccurrenceTimeMode], to count: Int) {
        if modes.count < count {
            modes.append(contentsOf: Array(repeating: .specific, count: count - modes.count))
        } else if modes.count > count {
            modes.removeLast(modes.count - count)
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
        // Captured before any of the habit's own stored fields are
        // overwritten below — this is what `removeStaleBlocks` diffs
        // against to find an occurrence that just moved away from
        // Specific Time, or that stayed Specific Time but got a new
        // Target Time.
        let previousModes = (0..<habit.timesPerDay).map { habit.timeMode(for: $0) }
        let previousIdealTimesOfDay = habit.idealTimesOfDay

        habit.name = name
        habit.startDate = Calendar.current.startOfDay(for: startDate)
        habit.timesPerDay = timesPerDay
        habit.daysOfWeek = daysOfWeek
        habit.idealTimesOfDay = idealTimesOfDay
        habit.occurrenceTimeModesRaw = occurrenceTimeModes.map(\.rawValue)
        // No longer independently editable (see this view's doc comment)
        // — kept mirrored to Target Time rather than left frozen at
        // whatever it was last set to, since `reminderTimesOfDay` is
        // still the stored shape `HabitImportService` reads/writes.
        habit.reminderTimesOfDay = idealTimesOfDay
        habit.estimatedMinutes = estimatedMinutes
        habit.missThreshold = missThreshold

        removeStaleBlocks(previousModes: previousModes, previousIdealTimesOfDay: previousIdealTimesOfDay)
        placeNewlySpecificOccurrenceToday()

        dismiss()
    }

    /// Clears out today's-or-later, not-yet-completed blocks for any
    /// occurrence that either just moved *away* from Specific Time, or
    /// *stayed* Specific Time but got a new Target Time — in both cases
    /// the block sitting on the calendar no longer matches what was just
    /// saved, whether that's the wrong kind of slot entirely or just the
    /// old time. Without the latter check, changing only the Target Time
    /// on an occurrence that was already Specific Time left its existing
    /// block untouched — `AISchedulingService.placeHabitsAndRecurringTasks`
    /// only ever fills in a *missing* occurrence (matched by
    /// `habitOccurrenceIndex`), it never moves an existing block to a
    /// changed time — so the habit kept showing up at its old time
    /// indefinitely. A past or already-completed block is left alone
    /// (it's history, not a stale future commitment). An approved block
    /// that had actually been pushed also gets its real Google Calendar
    /// event torn down, fired off in the background so Save doesn't have
    /// to wait on the network for it.
    private func removeStaleBlocks(previousModes: [HabitOccurrenceTimeMode], previousIdealTimesOfDay: [Int]) {
        let today = Calendar.current.startOfDay(for: .now)
        for index in previousModes.indices where index < occurrenceTimeModes.count {
            let movedOffSpecific = previousModes[index] == .specific && occurrenceTimeModes[index] != .specific
            let timeChangedWhileSpecific = previousModes[index] == .specific
                && occurrenceTimeModes[index] == .specific
                && index < previousIdealTimesOfDay.count
                && index < idealTimesOfDay.count
                && previousIdealTimesOfDay[index] != idealTimesOfDay[index]
            guard movedOffSpecific || timeChangedWhileSpecific else { continue }
            let staleBlocks = (habit.scheduledBlocks ?? []).filter {
                $0.habitOccurrenceIndex == index && !$0.isCompleted && $0.date >= today
            }
            for block in staleBlocks {
                if block.approvalStatus == .approved, let eventID = block.googleEventID {
                    Task { try? await calendarService.deleteEvent(eventID: eventID) }
                }
                block.habit = nil
                modelContext.delete(block)
            }
        }
    }

    /// The flip side of `removeStaleBlocks` — an occurrence that just
    /// moved *to* Specific Time, or had its Target Time changed while
    /// staying Specific Time, should show up on today's calendar right
    /// away (at the new time) rather than waiting for the Calendar tab's
    /// own auto-place to happen to run again. Reuses the exact same
    /// placement pass `AISchedulingService` itself opens with; passing empty
    /// shelves/freeSlots/eligibleHoursWindows is safe here since a
    /// habit's own placement never consults any of them (see that
    /// method's doc comment) — only recurring-task placement would, and
    /// there are none to place with `shelves: []`.
    private func placeNewlySpecificOccurrenceToday() {
        let today = Calendar.current.startOfDay(for: .now)
        let (newBlocks, _) = schedulingService.placeHabitsAndRecurringTasks(
            shelves: [],
            habits: [habit],
            freeSlots: [],
            eligibleHoursWindows: [],
            date: today
        )
        for block in newBlocks {
            modelContext.insert(block)
        }
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
