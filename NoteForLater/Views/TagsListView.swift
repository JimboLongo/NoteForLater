import SwiftUI
import SwiftData

/// The tag box: every tag ever attached to a task or inbox item, plus any
/// created directly here. Tap one to add or edit its location; "+" creates
/// a new tag from scratch via NewTagSheet.
struct TagsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Tag.name) private var tags: [Tag]
    @State private var isShowingNewTag = false

    var body: some View {
        List {
            if tags.isEmpty {
                Text("No tags yet. Tag a task to add one here, or add one directly.")
                    .foregroundStyle(.secondary)
            }
            ForEach(tags) { tag in
                NavigationLink {
                    LocationTagPickerView(tagName: tag.name)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tag.name.capitalized)
                        Text(tag.hasLocation ? (tag.addressLabel.isEmpty ? tag.radiusDescription : "\(tag.addressLabel) · \(tag.radiusDescription)") : "No location")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete(perform: deleteTags)
        }
        .navigationTitle("Tags")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingNewTag = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $isShowingNewTag) {
            NewTagSheet { _ in }
        }
    }

    private func deleteTags(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(tags[index])
        }
    }
}

#Preview {
    NavigationStack {
        TagsListView()
    }
    .modelContainer(for: [InboxItem.self, TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self, Habit.self, HabitLog.self], inMemory: true)
}
