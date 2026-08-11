import SwiftUI
import SwiftData

/// Task Stats — every insight `TaskCompletionRecord` can offer, built up
/// from permanent snapshots taken the moment a task is marked complete on
/// the calendar (see `ScheduleReviewViewModel.toggleComplete`), so this
/// still has the full picture even for tasks long since purged from the
/// shelf (`regenerateFromNow` deletes a task still complete the next time
/// a schedule generates).
struct TaskStatsView: View {
    @Query(sort: \TaskCompletionRecord.completedAt, order: .reverse) private var records: [TaskCompletionRecord]

    var body: some View {
        List {
            if records.isEmpty {
                Section {
                    Text("No tasks marked complete yet. Once you check one off on the calendar, its stats show up here.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Overview") {
                    StatRow(label: "Completed Tasks", value: "\(records.count)")
                    StatRow(label: "Completed With No Pushes", value: "\(noPushCount) (\(noPushPercentText))")
                    StatRow(label: "Average Pushes per Task", value: String(format: "%.1f", averagePushes))
                }

                Section("Timing") {
                    StatRow(label: "Average Time to Complete", value: formatDuration(averageInterval))
                    if let fastest {
                        StatRow(label: "Fastest Completion", value: formatDuration(max(0, fastest.completionInterval)), detail: fastest.title)
                    }
                    if let slowest {
                        StatRow(label: "Slowest Completion", value: formatDuration(max(0, slowest.completionInterval)), detail: slowest.title)
                    }
                }

                Section("Recent Activity") {
                    StatRow(label: "Completed Today", value: "\(completedToday)")
                    StatRow(label: "Completed This Week", value: "\(completedThisWeek)")
                    StatRow(label: "Current Streak", value: streakText)
                }

                Section("Highlights") {
                    if let mostPushed, mostPushed.pushedCount > 0 {
                        StatRow(label: "Most Pushed Task", value: "\(mostPushed.pushedCount)×", detail: mostPushed.title)
                    } else {
                        StatRow(label: "Most Pushed Task", value: "—", detail: "Nothing's been pushed yet")
                    }
                    StatRow(label: "Total Pushes Overall", value: "\(totalPushes)")
                }
            }
        }
        .navigationTitle("Task Stats")
    }

    // MARK: - Overview

    private var noPushCount: Int {
        records.filter { $0.pushedCount == 0 }.count
    }

    private var noPushPercentText: String {
        guard !records.isEmpty else { return "0%" }
        let percent = Double(noPushCount) / Double(records.count) * 100
        return String(format: "%.0f%%", percent)
    }

    private var totalPushes: Int {
        records.reduce(0) { $0 + $1.pushedCount }
    }

    private var averagePushes: Double {
        guard !records.isEmpty else { return 0 }
        return Double(totalPushes) / Double(records.count)
    }

    // MARK: - Timing

    private var averageInterval: TimeInterval {
        guard !records.isEmpty else { return 0 }
        let total = records.reduce(0) { $0 + max(0, $1.completionInterval) }
        return total / Double(records.count)
    }

    private var fastest: TaskCompletionRecord? {
        records.min { $0.completionInterval < $1.completionInterval }
    }

    private var slowest: TaskCompletionRecord? {
        records.max { $0.completionInterval < $1.completionInterval }
    }

    // MARK: - Recent activity

    private var completedToday: Int {
        let calendar = Calendar.current
        return records.filter { calendar.isDateInToday($0.completedAt) }.count
    }

    private var completedThisWeek: Int {
        let calendar = Calendar.current
        guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: .now)?.start else { return 0 }
        return records.filter { $0.completedAt >= weekStart }.count
    }

    /// Consecutive days, ending today or yesterday (so a streak isn't
    /// broken just because today hasn't had a completion *yet*), with at
    /// least one completed task each.
    private var streakText: String {
        let calendar = Calendar.current
        let completedDays = Set(records.map { calendar.startOfDay(for: $0.completedAt) })
        guard !completedDays.isEmpty else { return "0 days" }

        var cursor = calendar.startOfDay(for: .now)
        if !completedDays.contains(cursor) {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
            guard completedDays.contains(cursor) else { return "0 days" }
        }
        var streak = 0
        while completedDays.contains(cursor) {
            streak += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        return streak == 1 ? "1 day" : "\(streak) days"
    }

    // MARK: - Highlights

    private var mostPushed: TaskCompletionRecord? {
        records.max { $0.pushedCount < $1.pushedCount }
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let totalMinutes = max(0, Int(interval / 60))
        if totalMinutes < 60 {
            return "\(totalMinutes) min"
        }
        let totalHours = totalMinutes / 60
        if totalHours < 24 {
            let minutes = totalMinutes % 60
            return minutes == 0 ? "\(totalHours)h" : "\(totalHours)h \(minutes)m"
        }
        let days = totalHours / 24
        let hours = totalHours % 24
        return hours == 0 ? "\(days)d" : "\(days)d \(hours)h"
    }
}

private struct StatRow: View {
    let label: String
    let value: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NavigationStack {
        TaskStatsView()
    }
    .modelContainer(for: [TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self, Habit.self, HabitLog.self, TaskCompletionRecord.self], inMemory: true)
}
