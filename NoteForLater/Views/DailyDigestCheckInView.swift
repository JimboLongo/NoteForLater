import SwiftUI
import SwiftData

/// Presented when a Daily Digest notification is tapped (see AppDelegate /
/// DailyDigestLaunchState) — lists every habit occurrence and scheduled
/// task still open today, each with a tap-to-complete circle, so "mark any
/// complete?" from the notification has somewhere real to land.
struct DailyDigestCheckInView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Habit.sortOrder) private var allHabits: [Habit]
    @Query private var allBlocks: [ScheduledBlock]

    private let calendar = Calendar.current
    private var today: Date { calendar.startOfDay(for: .now) }

    private struct OpenHabitOccurrence: Identifiable {
        let id: String
        let habit: Habit
        let index: Int
    }

    private var openHabitOccurrences: [OpenHabitOccurrence] {
        let applicableHabits = allHabits
            .filter { $0.isApplicable(on: today, calendar: calendar) }
            .sorted { $0.sortOrder < $1.sortOrder }
        var result: [OpenHabitOccurrence] = []
        for habit in applicableHabits {
            for index in 0..<max(habit.timesPerDay, 1) {
                guard habit.occurrenceStatus(index, on: today, calendar: calendar) == .none else { continue }
                result.append(OpenHabitOccurrence(id: "\(habit.id).\(index)", habit: habit, index: index))
            }
        }
        return result
    }

    /// Habit-backed blocks are excluded — that habit's own still-open
    /// occurrence (above) already covers it, so it isn't named twice.
    private var openTaskBlocks: [ScheduledBlock] {
        allBlocks
            .filter { $0.task != nil && !$0.isCompleted && calendar.isDate($0.date, inSameDayAs: today) }
            .sorted { $0.startTime < $1.startTime }
    }

    var body: some View {
        NavigationStack {
            List {
                if openHabitOccurrences.isEmpty && openTaskBlocks.isEmpty {
                    ContentUnavailableView(
                        "All Caught Up",
                        systemImage: "checkmark.circle",
                        description: Text("Nothing left open today.")
                    )
                } else {
                    if !openHabitOccurrences.isEmpty {
                        Section("Habits") {
                            ForEach(openHabitOccurrences) { occurrence in
                                habitRow(occurrence)
                            }
                        }
                    }
                    if !openTaskBlocks.isEmpty {
                        Section("Today") {
                            ForEach(openTaskBlocks) { block in
                                blockRow(block)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Still Open Today")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func habitRow(_ occurrence: OpenHabitOccurrence) -> some View {
        Button {
            toggleHabitOccurrence(habit: occurrence.habit, index: occurrence.index)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
                Text(occurrence.habit.name)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func blockRow(_ block: ScheduledBlock) -> some View {
        Button {
            block.task?.setCompleted(true, in: modelContext)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(block.displayTitle)
                        .foregroundStyle(.primary)
                    Text(timeRangeText(block))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Mirrors `HabitsView.toggleOccurrence` — keeps a matching
    /// `ScheduledBlock.isCompleted`, if that occurrence made it onto
    /// today's calendar, in sync.
    private func toggleHabitOccurrence(habit: Habit, index: Int) {
        let log = habit.log(on: today, calendar: calendar) ?? {
            let newLog = HabitLog(habit: habit, date: today)
            modelContext.insert(newLog)
            return newLog
        }()
        log.setOccurrence(index, to: .complete)
        if let block = (habit.scheduledBlocks ?? []).first(where: {
            $0.habitOccurrenceIndex == index && calendar.isDate($0.date, inSameDayAs: today)
        }) {
            block.isCompleted = true
        }
    }

    private func timeRangeText(_ block: ScheduledBlock) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return "\(formatter.string(from: block.startTime)) - \(formatter.string(from: block.endTime))"
    }
}

#Preview {
    DailyDigestCheckInView()
        .modelContainer(for: [TaskItem.self, ScheduledBlock.self, Shelf.self, Habit.self, HabitLog.self], inMemory: true)
}
