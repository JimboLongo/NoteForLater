import SwiftUI

/// Live "mark complete" review for scheduled blocks from today or an
/// earlier day — grouped by day (oldest first) so a backlog spanning
/// several days still reads clearly. Shared between Nightly Review's
/// "Review Schedule" step and the standalone "Review Previous Events"
/// sheet offered when regenerating a schedule with overdue blocks left
/// over (see `ScheduleReviewViewModel.reviewableBlocks`
/// /`hasIncompletePastBlocks`).
///
/// Every row's circle directly reflects `block.isCompleted` and toggles
/// it immediately on tap — no separate "select, then confirm" step.
/// Checking one off marks it complete, fills the circle green, fades the
/// row, and strikes the title through; tapping it again undoes all of
/// that. `onDone`, if the caller supplies it, is a `.topBarTrailing`
/// toolbar item this view contributes itself (so it lands correctly in
/// whichever ancestor `NavigationStack` hosts it) for whatever "I'm done
/// reviewing" means to that caller — Nightly Review's Today step doesn't
/// need one (its own bottom nav bar already advances), the Regenerate
/// flow's sheet uses it to dismiss and kick off `regenerateFromNow`.
struct OverdueBlocksReviewList: View {
    let blocks: [ScheduledBlock]
    /// Fired immediately, every time a row's circle is tapped — the
    /// caller flips that block's completion (and everything that goes
    /// with it: task/habit sync, Task Stats) via the same logic the
    /// calendar's own tap-to-complete circle uses
    /// (`ScheduleReviewViewModel.toggleComplete`).
    let onToggle: (ScheduledBlock) -> Void
    var onDone: (() -> Void)? = nil

    private struct DayGroup: Identifiable {
        let day: Date
        var id: Date { day }
        let blocks: [ScheduledBlock]
    }

    private var groupedByDay: [DayGroup] {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: blocks) { calendar.startOfDay(for: $0.date) }
        return byDay
            .map { DayGroup(day: $0.key, blocks: $0.value.sorted { $0.startTime < $1.startTime }) }
            .sorted { $0.day < $1.day }
    }

    var body: some View {
        List {
            if blocks.isEmpty {
                Text("Nothing to review.")
                    .foregroundStyle(.secondary)
            }
            ForEach(groupedByDay) { group in
                Section(dayLabel(group.day)) {
                    ForEach(group.blocks) { block in
                        row(for: block)
                    }
                }
            }
        }
        .toolbar {
            if let onDone {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDone)
                }
            }
        }
    }

    private func row(for block: ScheduledBlock) -> some View {
        HStack(alignment: .top, spacing: 12) {
            selectionCircle(isSelected: block.isCompleted)
                .contentShape(Rectangle())
                .padding(.vertical, 4)
                .onTapGesture { onToggle(block) }
            VStack(alignment: .leading) {
                Text(timeRangeText(block))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(block.displayTitle)
                    .strikethrough(block.isCompleted)
            }
            Spacer()
            if block.isLocked {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(block.isCompleted ? 0.5 : 1)
        .listRowBackground((block.task?.shelf?.color ?? Color.clear).opacity(0.2))
    }

    private func selectionCircle(isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .fill(isSelected ? Color.green : Color.clear)
                .overlay(Circle().strokeBorder(isSelected ? Color.green : Color.secondary.opacity(0.5), lineWidth: 1.5))
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 22, height: 22)
    }

    private func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter.string(from: day)
    }

    private func timeRangeText(_ block: ScheduledBlock) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return "\(formatter.string(from: block.startTime)) - \(formatter.string(from: block.endTime))"
    }
}
