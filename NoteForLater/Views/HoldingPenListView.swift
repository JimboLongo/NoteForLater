import SwiftUI
import SwiftData

/// A single reusable list for any of the four holding pens (To-Do List,
/// Stuff to Buy, Future Project, Reference).
struct HoldingPenListView: View {
    let pen: HoldingPen

    @Environment(\.modelContext) private var modelContext
    @Query private var allTasks: [TaskItem]
    @State private var searchText = ""

    init(pen: HoldingPen) {
        self.pen = pen
        let rawValue = pen.rawValue
        _allTasks = Query(
            filter: #Predicate<TaskItem> { $0.holdingPenRaw == rawValue },
            sort: \TaskItem.createdAt,
            order: .reverse
        )
    }

    /// Matches on title or tags so tags act as filterable search keywords.
    private var filteredTasks: [TaskItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return allTasks }
        return allTasks.filter { task in
            task.title.lowercased().contains(query)
                || task.tags.contains { $0.lowercased().contains(query) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if filteredTasks.isEmpty {
                    Text(allTasks.isEmpty ? "Nothing here yet." : "No matches.")
                        .foregroundStyle(.secondary)
                }
                ForEach(filteredTasks) { task in
                    NavigationLink {
                        TaskDetailView(task: task)
                    } label: {
                        TaskRow(task: task, showsScheduledBadge: pen.isSchedulable)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            modelContext.delete(task)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(pen.rawValue)
            .searchable(text: $searchText, prompt: "Search title or tags")
        }
    }
}

private struct TaskRow: View {
    let task: TaskItem
    let showsScheduledBadge: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(task.title).font(.body)
                Spacer()
                if showsScheduledBadge && task.isScheduled {
                    Image(systemName: "calendar.badge.checkmark")
                        .foregroundStyle(.green)
                }
            }
            if !task.notes.isEmpty {
                Text(task.notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !task.nextStep.isEmpty {
                Label(task.nextStep, systemImage: "arrow.turn.down.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 12) {
                if let dueDate = task.dueDate {
                    Label(dueDate.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                }
                Label(task.durationLabel, systemImage: "clock")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            if !task.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(task.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    HoldingPenListView(pen: .todo)
        .modelContainer(for: [InboxItem.self, TaskItem.self, ScheduledBlock.self], inMemory: true)
}
