import SwiftUI
import SwiftData

/// Full editor for a single task's metadata: due date, next step, duration,
/// and searchable tags. Reached by tapping a task in any holding pen list.
struct TaskDetailView: View {
    @Bindable var task: TaskItem
    @Query(sort: \Tag.name) private var allTags: [Tag]

    @State private var hasDueDate: Bool
    @State private var newTag: String = ""
    @State private var locationTagTarget: TagLocationTarget?
    @State private var isShowingNewTagSheet = false
    @State private var pendingNewTagName = ""

    private static let durationOptions = [15, 30, 45, 60, 90, 120, 180, 240]
    private static let segmentOptions = [5, 10, 15, 20, 30, 45, 60]

    init(task: TaskItem) {
        self.task = task
        _hasDueDate = State(initialValue: task.dueDate != nil)
    }

    var body: some View {
        Form {
            Section("Task") {
                TextField("Title", text: $task.title)
                TextField("Notes", text: $task.notes, axis: .vertical)
            }

            Section("Next Step") {
                TextField("What's the very next action?", text: $task.nextStep, axis: .vertical)
            }

            Section("Due Date") {
                Toggle("Has due date", isOn: $hasDueDate.animation())
                    .onChange(of: hasDueDate) { _, newValue in
                        task.dueDate = newValue ? (task.dueDate ?? .now) : nil
                    }
                if hasDueDate {
                    DatePicker(
                        "Due",
                        selection: Binding(
                            get: { task.dueDate ?? .now },
                            set: { task.dueDate = $0 }
                        ),
                        displayedComponents: [.date]
                    )
                }
            }

            Section("Duration") {
                Picker("Estimated duration", selection: $task.estimatedMinutes) {
                    ForEach(Self.durationOptions, id: \.self) { minutes in
                        Text(TaskItem.durationLabel(for: minutes)).tag(minutes)
                    }
                }
                Toggle("Divisible into segments", isOn: $task.isDivisible)
                if task.isDivisible {
                    Picker("Smallest segment", selection: $task.minimumSegmentMinutes) {
                        ForEach(Self.segmentOptions, id: \.self) { minutes in
                            Text(TaskItem.durationLabel(for: minutes)).tag(minutes)
                        }
                    }
                }
            }

            Section("Priority") {
                Picker("Priority", selection: $task.priority) {
                    ForEach(Priority.allCases) { priority in
                        Text(priority.rawValue.capitalized).tag(priority)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                if !task.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(task.tags, id: \.self) { tag in
                                TagChip(
                                    text: tag,
                                    hasLocation: hasLocation(for: tag),
                                    onTapLocation: { locationTagTarget = TagLocationTarget(name: tag) },
                                    onDelete: { task.tags.removeAll { $0 == tag } }
                                )
                            }
                        }
                    }
                }
                HStack {
                    TextField("Add tag", text: $newTag)
                        .submitLabel(.done)
                        .onSubmit(addTag)
                    Button("Add", action: addTag)
                        .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !tagSuggestions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(tagSuggestions) { tag in
                                Button(tag.name) {
                                    task.tags.append(tag.name)
                                    newTag = ""
                                }
                                .font(.caption)
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            } header: {
                Text("Tags")
            } footer: {
                Text("Tap the pin on a tag to attach a real-world location — you'll get a notification when you're nearby.")
            }

            Section {
                LabeledContent("Date Added", value: task.createdAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .navigationTitle(task.title.isEmpty ? "Task" : task.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $locationTagTarget) { target in
            LocationTagPickerView(tagName: target.name)
        }
        .sheet(isPresented: $isShowingNewTagSheet) {
            NewTagSheet(prefilledName: pendingNewTagName) { name in
                task.tags.append(name)
                newTag = ""
            }
        }
    }

    private func hasLocation(for tagName: String) -> Bool {
        allTags.first { $0.name == tagName }?.hasLocation ?? false
    }

    private var tagSuggestions: [Tag] {
        let query = newTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        return allTags.filter { $0.name.hasPrefix(query) && !task.tags.contains($0.name) }
    }

    private func addTag() {
        let trimmed = newTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, !task.tags.contains(trimmed) else {
            newTag = ""
            return
        }
        if let existing = allTags.first(where: { $0.name == trimmed }) {
            task.tags.append(existing.name)
            newTag = ""
        } else {
            pendingNewTagName = trimmed
            isShowingNewTagSheet = true
        }
    }
}

/// Identifies which tag's location is being edited — plain String isn't
/// Identifiable, and this is shared by TaskDetailView and InboxItemDetailView.
struct TagLocationTarget: Identifiable {
    let name: String
    var id: String { name }
}

struct TagChip: View {
    let text: String
    let hasLocation: Bool
    let onTapLocation: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onTapLocation) {
                Image(systemName: hasLocation ? "mappin.circle.fill" : "mappin.circle")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            Text(text)
                .font(.caption)
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.15))
        .clipShape(Capsule())
    }
}

#Preview {
    let shelf = Shelf(name: "To-Do List", systemImage: "checklist", showsInTabBar: true)
    return NavigationStack {
        TaskDetailView(task: TaskItem(title: "Sample task", shelf: shelf))
    }
    .modelContainer(for: [InboxItem.self, TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, Tag.self], inMemory: true)
}
