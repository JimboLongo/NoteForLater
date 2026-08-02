import SwiftUI
import SwiftData

/// Per-shelf configuration: display name, icon, whether it's pinned to the
/// bottom tab bar, and the SchedulingRules that pull tasks from this shelf
/// onto the calendar. A shelf with no enabled rules is never touched by
/// the AI Scheduler.
struct ShelfEditView: View {
    @Bindable var shelf: Shelf
    @Environment(\.modelContext) private var modelContext
    @Query private var rules: [SchedulingRule]

    private static let iconOptions = [
        "checklist", "cart", "lightbulb", "archivebox", "tray",
        "star", "flag", "book", "briefcase", "house",
        "heart", "dollarsign.circle", "airplane", "gift", "wrench.and.screwdriver"
    ]

    private let columns = [GridItem(.adaptive(minimum: 44))]

    @State private var showingIconPicker = false

    init(shelf: Shelf) {
        self.shelf = shelf
        let shelfID = shelf.id
        _rules = Query(
            filter: #Predicate<SchedulingRule> { $0.shelf?.id == shelfID },
            sort: \SchedulingRule.sortOrder
        )
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Shelf name", text: $shelf.name)
            }

            Section("Icon") {
                Button {
                    showingIconPicker = true
                } label: {
                    HStack {
                        Image(systemName: shelf.systemImage)
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
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
            }

            Section {
                Toggle("Show in Tab Bar", isOn: $shelf.showsInTabBar)
            }

            Section {
                if rules.isEmpty {
                    Text("No pull schedule yet — this shelf won't be touched by the AI Scheduler until you add one.")
                        .foregroundStyle(.secondary)
                }
                ForEach(rules) { rule in
                    NavigationLink {
                        SchedulingRuleEditView(rule: rule)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            if !rule.name.isEmpty {
                                Text(rule.name)
                            }
                            Text(rule.summary)
                                .font(rule.name.isEmpty ? .body : .caption)
                                .foregroundStyle(rule.name.isEmpty ? .primary : .secondary)
                            if !rule.isEnabled {
                                Text("Disabled")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
                .onDelete(perform: deleteRules)

                Button {
                    addRule()
                } label: {
                    Label("Add Pull Schedule", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("Scheduling Rules")
            } footer: {
                Text("Each rule pulls tasks from this shelf into a day/time window on the calendar — e.g. \"Mon–Fri 9–5, fill to fit\" or \"Sat–Sun 9am–9pm, up to 4 hours.\"")
            }
        }
        .navigationTitle(shelf.name.isEmpty ? "Shelf" : shelf.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingIconPicker) {
            NavigationStack {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(Self.iconOptions, id: \.self) { icon in
                            Button {
                                shelf.systemImage = icon
                                showingIconPicker = false
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
    }

    private func addRule() {
        let nextOrder = (rules.map(\.sortOrder).max() ?? -1) + 1
        modelContext.insert(SchedulingRule(shelf: shelf, sortOrder: nextOrder))
    }

    private func deleteRules(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(rules[index])
        }
    }
}

#Preview {
    NavigationStack {
        ShelfEditView(shelf: Shelf(name: "To-Do List", systemImage: "checklist", showsInTabBar: true))
    }
    .modelContainer(for: [InboxItem.self, TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, LocationTag.self], inMemory: true)
}
