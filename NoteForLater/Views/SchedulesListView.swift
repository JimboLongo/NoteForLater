import SwiftUI
import SwiftData

/// The "Schedules" tab: reusable day/time windows (e.g. "Work" Mon–Fri
/// 9–5, "After Work" Mon–Fri 6–9pm) defined once here and referenced by any
/// shelf's pull schedules, instead of redefining the same window per shelf.
struct SchedulesListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \NamedSchedule.sortOrder) private var schedules: [NamedSchedule]
    @State private var newSchedule: NamedSchedule?

    var body: some View {
        List {
            Section {
                if schedules.isEmpty {
                    Text("No reusable schedules yet. Add one, then reference it from any shelf's pull schedule.")
                        .foregroundStyle(.secondary)
                }
                ForEach(schedules) { schedule in
                    NavigationLink {
                        NamedScheduleEditView(schedule: schedule)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(schedule.name)
                            Text(schedule.dayAndTimeText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete(perform: deleteSchedules)
                .onMove(perform: moveSchedules)

                Button {
                    addSchedule()
                } label: {
                    Label("Add Schedule", systemImage: "plus.circle.fill")
                }
            } footer: {
                Text("e.g. \"Work\" Mon–Fri 9–5, \"After Work\" Mon–Fri 6–9pm. Each shelf then just picks a schedule and a fill strategy — fill to fit, a max duration, or a max task count.")
            }
        }
        .navigationTitle("Schedules")
        .toolbar { EditButton() }
        .sheet(item: $newSchedule) { schedule in
            NavigationStack {
                NamedScheduleEditView(schedule: schedule, focusNameOnAppear: true)
            }
        }
    }

    private func addSchedule() {
        let nextOrder = (schedules.map(\.sortOrder).max() ?? -1) + 1
        let schedule = NamedSchedule(name: "", sortOrder: nextOrder)
        modelContext.insert(schedule)
        newSchedule = schedule
    }

    private func deleteSchedules(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(schedules[index])
        }
    }

    private func moveSchedules(from source: IndexSet, to destination: Int) {
        var reordered = schedules
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, schedule) in reordered.enumerated() {
            schedule.sortOrder = index
        }
    }
}

#Preview {
    NavigationStack {
        SchedulesListView()
    }
    .modelContainer(for: [TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self, Habit.self, HabitLog.self], inMemory: true)
}
