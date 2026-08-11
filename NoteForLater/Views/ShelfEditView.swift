import SwiftUI
import SwiftData

/// Per-shelf configuration: display name, icon, color, and which reusable
/// Schedules (from More > Schedules) are assigned to this shelf, each with
/// its own fill strategy. A shelf with no enabled assignments is never
/// touched by the AI Scheduler. Name/icon/color are a draft — nothing
/// writes back until Save is tapped. Schedule assignment is immediate
/// (inserting/removing a SchedulingRule), matching how the rest of the app
/// treats structural add/remove actions.
struct ShelfEditView: View {
    let shelf: Shelf
    var focusNameOnAppear = false
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var rules: [SchedulingRule]
    @Query(sort: \NamedSchedule.sortOrder) private var availableSchedules: [NamedSchedule]
    @Query private var allShelves: [Shelf]
    @FocusState private var isNameFocused: Bool

    @State private var name: String
    @State private var systemImage: String
    @State private var colorName: String
    @State private var tracksDuration: Bool
    @State private var defaultDurationMinutes: Int
    @State private var hasDueDates: Bool
    @State private var hasNextStep: Bool
    @State private var hasPriority: Bool

    private let columns = [GridItem(.adaptive(minimum: 44))]
    private static let durationOptions = [0, 5, 15, 30, 45, 60, 90, 120, 240, 480]

    @State private var showingIconPicker = false
    @State private var showingColorPicker = false
    @State private var showingSchedulePicker = false
    @State private var newlyAssignedRule: SchedulingRule?

    init(shelf: Shelf, focusNameOnAppear: Bool = false) {
        self.shelf = shelf
        self.focusNameOnAppear = focusNameOnAppear
        _name = State(initialValue: shelf.name)
        _systemImage = State(initialValue: shelf.systemImage)
        _colorName = State(initialValue: shelf.colorName)
        _tracksDuration = State(initialValue: shelf.tracksDuration)
        _defaultDurationMinutes = State(initialValue: shelf.defaultDurationMinutes)
        _hasDueDates = State(initialValue: shelf.hasDueDates)
        _hasNextStep = State(initialValue: shelf.hasNextStep)
        _hasPriority = State(initialValue: shelf.hasPriority)
        let shelfID = shelf.id
        _rules = Query(
            filter: #Predicate<SchedulingRule> { $0.shelf?.id == shelfID },
            sort: \SchedulingRule.sortOrder
        )
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Shelf name", text: $name)
                    .focused($isNameFocused)
            }

            Section("Icon") {
                Button {
                    showingIconPicker = true
                } label: {
                    HStack {
                        Image(systemName: systemImage)
                            .font(.title2)
                            .frame(width: 36, height: 36)
                            .background(Color.accentColor.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text("Choose Icon")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
            }

            Section("Color") {
                Button {
                    showingColorPicker = true
                } label: {
                    HStack {
                        Circle()
                            .fill(Shelf.color(for: colorName))
                            .frame(width: 28, height: 28)
                        Text("Choose Color")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
            }

            // Pantry items are ingredients, not scheduled tasks — no
            // duration to track and nothing to pull onto the calendar, so
            // neither section applies.
            if !shelf.isPantry {
                Section {
                    Toggle("Tasks Have Next Step?", isOn: $hasNextStep)
                } footer: {
                    Text(hasNextStep
                        ? "Tasks on this shelf ask for a next step."
                        : "Tasks on this shelf skip the next step — that field is hidden on the card.")
                }

                Section {
                    Toggle("Tasks Have Priority?", isOn: $hasPriority)
                } footer: {
                    Text(hasPriority
                        ? "Tasks on this shelf can be marked low/medium/high priority."
                        : "Tasks on this shelf have no priority — that question is hidden on the card.")
                }

                Section {
                    Toggle("Tasks Have Due Dates?", isOn: $hasDueDates)
                } footer: {
                    Text(hasDueDates
                        ? "Tasks on this shelf can have a due date."
                        : "Tasks on this shelf never have a due date — the Due Date question is hidden on the card.")
                }

                Section {
                    Toggle("Tasks Have Durations?", isOn: $tracksDuration)
                } footer: {
                    Text(tracksDuration
                        ? "Tasks on this shelf can have a duration, and can be marked divisible."
                        : "Tasks on this shelf have no duration — the Duration and Divisible questions are hidden on the card.")
                }

                if tracksDuration {
                    Section {
                        Picker("Default Duration", selection: $defaultDurationMinutes) {
                            ForEach(Self.durationOptions, id: \.self) { minutes in
                                Text(TaskItem.durationLabel(for: minutes)).tag(minutes)
                            }
                        }
                    } footer: {
                        Text("Stamped onto a task sent to this shelf only if it doesn't already have a duration selected.")
                    }
                }

                Section {
                    if rules.isEmpty {
                        Text("No schedules assigned yet — this shelf won't be touched by the AI Scheduler until you add one.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(rules) { rule in
                        NavigationLink {
                            SchedulingRuleEditView(rule: rule)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                if !rule.displayName.isEmpty {
                                    Text(rule.displayName)
                                }
                                Text(rule.summary)
                                    .font(rule.displayName.isEmpty ? .body : .caption)
                                    .foregroundStyle(rule.displayName.isEmpty ? .primary : .secondary)
                                if !rule.isEnabled {
                                    Text("Disabled")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                                if rule.namedSchedule == nil {
                                    Text("No Schedule Assigned — won't pull any tasks")
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                    .onDelete(perform: deleteRules)

                    Button {
                        showingSchedulePicker = true
                    } label: {
                        Label("Add Schedule", systemImage: "plus.circle.fill")
                    }
                } header: {
                    Text("Assigned Schedules")
                } footer: {
                    Text("Pick from the reusable schedules in More > Schedules, then set how much this shelf pulls into it — e.g. fill to fit, or up to a max duration or task count.")
                }
            }
        }
        .navigationTitle(name.isEmpty ? "Shelf" : name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Save", action: save)
            }
        }
        .sheet(isPresented: $showingIconPicker) {
            NavigationStack {
                ScrollView {
                    Text("A faded ✕ marks icons already used by another shelf — you can still pick one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.top, 8)
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(Shelf.iconOptions, id: \.self) { icon in
                            Button {
                                systemImage = icon
                                showingIconPicker = false
                            } label: {
                                let isUsedElsewhere = icon != systemImage && iconsUsedByOtherShelves.contains(icon)
                                let iconColor: Color = isUsedElsewhere ? Color.secondary.opacity(0.35) : Color.primary
                                Image(systemName: icon)
                                    .font(.title2)
                                    .foregroundStyle(iconColor)
                                    .frame(width: 44, height: 44)
                                    .background(icon == systemImage ? Color.accentColor.opacity(0.2) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay {
                                        if isUsedElsewhere {
                                            Image(systemName: "xmark")
                                                .font(.title3)
                                                .fontWeight(.bold)
                                                .foregroundStyle(Color.red.opacity(0.75))
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
                .navigationTitle("Choose Icon")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showingIconPicker = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showingColorPicker) {
            NavigationStack {
                ScrollView {
                    Text("A faded ✕ marks colors already used by another shelf — you can still pick one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.top, 8)
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(Shelf.colorPalette, id: \.name) { option in
                            Button {
                                colorName = option.name
                                showingColorPicker = false
                            } label: {
                                Circle()
                                    .fill(option.color)
                                    .frame(width: 44, height: 44)
                                    .overlay {
                                        if option.name == colorName {
                                            Image(systemName: "checkmark")
                                                .font(.headline)
                                                .foregroundStyle(.white)
                                        } else if colorNamesUsedByOtherShelves.contains(option.name) {
                                            Image(systemName: "xmark")
                                                .font(.headline)
                                                .foregroundStyle(.white.opacity(0.6))
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
                .navigationTitle("Choose Color")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showingColorPicker = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showingSchedulePicker) {
            NavigationStack {
                List {
                    if availableSchedules.isEmpty {
                        Text("No schedules yet. Create one in More > Schedules, then come back here to assign it.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(availableSchedules) { schedule in
                        Button {
                            assignSchedule(schedule)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(schedule.name)
                                    .foregroundStyle(.primary)
                                Text(schedule.dayAndTimeText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .navigationTitle("Add Schedule")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingSchedulePicker = false }
                    }
                }
            }
        }
        .sheet(item: $newlyAssignedRule) { rule in
            NavigationStack {
                SchedulingRuleEditView(rule: rule)
            }
        }
        .onAppear {
            if focusNameOnAppear { isNameFocused = true }
        }
    }

    private var colorNamesUsedByOtherShelves: Set<String> {
        Set(allShelves.filter { $0.id != shelf.id }.map(\.colorName))
    }

    private var iconsUsedByOtherShelves: Set<String> {
        Set(allShelves.filter { $0.id != shelf.id }.map(\.systemImage))
    }

    private func save() {
        shelf.name = name
        shelf.systemImage = systemImage
        shelf.colorName = colorName
        shelf.tracksDuration = tracksDuration
        shelf.defaultDurationMinutes = tracksDuration ? defaultDurationMinutes : 0
        shelf.hasDueDates = hasDueDates
        shelf.hasNextStep = hasNextStep
        shelf.hasPriority = hasPriority
        if shelf.isPantry || !tracksDuration {
            // Not just future tasks — turning this off (or this being
            // Pantry, unconditionally) means *nothing* on the shelf has a
            // duration, so clear what's already there too.
            for task in shelf.tasks ?? [] {
                task.estimatedMinutes = 0
                task.isDivisible = false
                task.minimumSegmentMinutes = 0
            }
        }
        if shelf.isPantry || !hasDueDates {
            for task in shelf.tasks ?? [] {
                task.dueDate = nil
            }
        }
        if shelf.isPantry || !hasNextStep {
            for task in shelf.tasks ?? [] {
                task.nextStep = ""
            }
        }
        if shelf.isPantry || !hasPriority {
            for task in shelf.tasks ?? [] {
                task.priority = .unset
            }
        }
        dismiss()
    }

    private func assignSchedule(_ schedule: NamedSchedule) {
        let nextOrder = (rules.map(\.sortOrder).max() ?? -1) + 1
        let rule = SchedulingRule(shelf: shelf, sortOrder: nextOrder)
        rule.namedSchedule = schedule
        modelContext.insert(rule)
        showingSchedulePicker = false
        newlyAssignedRule = rule
    }

    private func deleteRules(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(rules[index])
        }
    }
}

#Preview {
    NavigationStack {
        ShelfEditView(shelf: Shelf(name: "To-Do List", systemImage: "checklist"))
    }
    .modelContainer(for: [TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self, Habit.self, HabitLog.self], inMemory: true)
}
