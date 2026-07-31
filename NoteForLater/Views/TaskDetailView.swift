import SwiftUI
import SwiftData

/// Full editor for a single task's metadata: due date, next step, duration,
/// and searchable tags. Reached by tapping a task in any holding pen list.
struct TaskDetailView: View {
    @Bindable var task: TaskItem

    @State private var hasDueDate: Bool
    @State private var newTag: String = ""

    private static let durationOptions = [15, 30, 45, 60, 90, 120, 180, 240]

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
            }

            Section("Priority") {
                Picker("Priority", selection: $task.priority) {
                    ForEach(Priority.allCases) { priority in
                        Text(priority.rawValue.capitalized).tag(priority)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Tags") {
                if !task.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(task.tags, id: \.self) { tag in
                                TagChip(text: tag) {
                                    task.tags.removeAll { $0 == tag }
                                }
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
            }

            Section {
                LabeledContent("Date Added", value: task.createdAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .navigationTitle(task.title.isEmpty ? "Task" : task.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func addTag() {
        let trimmed = newTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, !task.tags.contains(trimmed) else {
            newTag = ""
            return
        }
        task.tags.append(trimmed)
        newTag = ""
    }
}

private struct TagChip: View {
    let text: String
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 4) {
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
    NavigationStack {
        TaskDetailView(task: TaskItem(title: "Sample task", holdingPen: .todo))
    }
    .modelContainer(for: [InboxItem.self, TaskItem.self, ScheduledBlock.self], inMemory: true)
}
