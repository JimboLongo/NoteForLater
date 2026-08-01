import SwiftUI
import SwiftData

/// Tap an inbox item to fill in its attributes — due date, next step,
/// duration, tags, priority — before sorting it. Everything set here
/// carries over onto the TaskItem created when it's sent to a shelf.
struct InboxItemDetailView: View {
    @Bindable var item: InboxItem
    let shelves: [Shelf]
    let onRoute: (Shelf) -> Void

    @State private var hasDueDate: Bool
    @State private var newTag: String = ""
    @Environment(\.dismiss) private var dismiss

    private static let durationOptions = [15, 30, 45, 60, 90, 120, 180, 240]
    private static let segmentOptions = [5, 10, 15, 20, 30, 45, 60]

    init(item: InboxItem, shelves: [Shelf], onRoute: @escaping (Shelf) -> Void) {
        self.item = item
        self.shelves = shelves
        self.onRoute = onRoute
        _hasDueDate = State(initialValue: item.dueDate != nil)
    }

    var body: some View {
        Form {
            Section("Text") {
                TextField("What's on your mind?", text: $item.text, axis: .vertical)
            }

            Section("Next Step") {
                TextField("What's the very next action?", text: $item.nextStep, axis: .vertical)
            }

            Section("Due Date") {
                Toggle("Has due date", isOn: $hasDueDate.animation())
                    .onChange(of: hasDueDate) { _, newValue in
                        item.dueDate = newValue ? (item.dueDate ?? .now) : nil
                    }
                if hasDueDate {
                    DatePicker(
                        "Due",
                        selection: Binding(
                            get: { item.dueDate ?? .now },
                            set: { item.dueDate = $0 }
                        ),
                        displayedComponents: [.date]
                    )
                }
            }

            Section("Duration") {
                Picker("Estimated duration", selection: $item.estimatedMinutes) {
                    ForEach(Self.durationOptions, id: \.self) { minutes in
                        Text(TaskItem.durationLabel(for: minutes)).tag(minutes)
                    }
                }
                Toggle("Divisible into segments", isOn: $item.isDivisible)
                if item.isDivisible {
                    Picker("Smallest segment", selection: $item.minimumSegmentMinutes) {
                        ForEach(Self.segmentOptions, id: \.self) { minutes in
                            Text(TaskItem.durationLabel(for: minutes)).tag(minutes)
                        }
                    }
                }
            }

            Section("Priority") {
                Picker("Priority", selection: $item.priority) {
                    ForEach(Priority.allCases) { priority in
                        Text(priority.rawValue.capitalized).tag(priority)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Tags") {
                if !item.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(item.tags, id: \.self) { tag in
                                TagChip(text: tag) {
                                    item.tags.removeAll { $0 == tag }
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
                LabeledContent("Date Added", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
            }

            Section {
                if shelves.isEmpty {
                    Text("No shelves yet. Add one from the Shelves tab.")
                        .foregroundStyle(.secondary)
                }
                ForEach(shelves) { shelf in
                    Button {
                        onRoute(shelf)
                        dismiss()
                    } label: {
                        Label(shelf.name, systemImage: shelf.systemImage)
                    }
                }
            } header: {
                Text("Send to Shelf")
            } footer: {
                Text("Everything above carries over when you send this to a shelf.")
            }
        }
        .navigationTitle(item.text.isEmpty ? "Inbox Item" : item.text)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func addTag() {
        let trimmed = newTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, !item.tags.contains(trimmed) else {
            newTag = ""
            return
        }
        item.tags.append(trimmed)
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
        InboxItemDetailView(item: InboxItem(text: "Sample inbox item"), shelves: [], onRoute: { _ in })
    }
    .modelContainer(for: [InboxItem.self, TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self], inMemory: true)
}
