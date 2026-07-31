import SwiftUI
import SwiftData

/// A single reusable list for any of the four holding pens (To-Do List,
/// Stuff to Buy, Future Project, Reference).
struct HoldingPenListView: View {
    let pen: HoldingPen

    @Environment(\.modelContext) private var modelContext
    @Query private var allTasks: [TaskItem]

    init(pen: HoldingPen) {
        self.pen = pen
        let rawValue = pen.rawValue
        _allTasks = Query(
            filter: #Predicate<TaskItem> { $0.holdingPenRaw == rawValue },
            sort: \TaskItem.createdAt,
            order: .reverse
        )
    }

    var body: some View {
        NavigationStack {
            List {
                if allTasks.isEmpty {
                    Text("Nothing here yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(allTasks) { task in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(task.title).font(.body)
                            Spacer()
                            if pen.isSchedulable && task.isScheduled {
                                Image(systemName: "calendar.badge.checkmark")
                                    .foregroundStyle(.green)
                            }
                        }
                        if !task.notes.isEmpty {
                            Text(task.notes)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
        }
    }
}

#Preview {
    HoldingPenListView(pen: .todo)
        .modelContainer(for: [InboxItem.self, TaskItem.self, ScheduledBlock.self], inMemory: true)
}
