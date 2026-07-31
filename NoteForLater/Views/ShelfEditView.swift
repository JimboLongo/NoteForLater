import SwiftUI
import SwiftData

/// Per-shelf configuration: display name, icon, whether it's pinned to the
/// bottom tab bar, and whether tasks placed here are eligible for the AI
/// Scheduler to auto-assign onto the calendar.
struct ShelfEditView: View {
    @Bindable var shelf: Shelf

    private static let iconOptions = [
        "checklist", "cart", "lightbulb", "archivebox", "tray",
        "star", "flag", "book", "briefcase", "house",
        "heart", "dollarsign.circle", "airplane", "gift", "wrench.and.screwdriver"
    ]

    private let columns = [GridItem(.adaptive(minimum: 44))]

    var body: some View {
        Form {
            Section("Name") {
                TextField("Shelf name", text: $shelf.name)
            }

            Section("Icon") {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Self.iconOptions, id: \.self) { icon in
                        Button {
                            shelf.systemImage = icon
                        } label: {
                            Image(systemName: icon)
                                .font(.title2)
                                .frame(width: 44, height: 44)
                                .background(icon == shelf.systemImage ? Color.accentColor.opacity(0.2) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                Toggle("Show in Tab Bar", isOn: $shelf.showsInTabBar)
                Toggle("Eligible for AI Scheduler", isOn: $shelf.isEligibleForScheduling)
            } footer: {
                Text("Tasks placed on this shelf can be auto-assigned to open calendar slots by the AI Scheduler.")
            }
        }
        .navigationTitle(shelf.name.isEmpty ? "Shelf" : shelf.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        ShelfEditView(shelf: Shelf(name: "To-Do List", systemImage: "checklist", showsInTabBar: true, isEligibleForScheduling: true))
    }
    .modelContainer(for: [InboxItem.self, TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self], inMemory: true)
}
