import SwiftUI

/// A still-open habit occurrence (AM/Midday/PM — see
/// `HabitOccurrenceTimeMode`) being reviewed alongside calendar blocks in
/// `OverdueBlocksReviewList`. Never has a `ScheduledBlock` of its own, so
/// it needs its own stand-in `targetTime` to sort and group by — see
/// `NightlyReviewView.openHabitOccurrencesForReview`, the only place that
/// builds these.
struct HabitReviewOccurrence: Identifiable {
    let id: String
    let habit: Habit
    let index: Int
    let isCompleted: Bool
    /// Stand-in time used purely for sorting/grouping this in among real
    /// blocks — never shown; the row displays `modeLabel` instead (see
    /// `OverdueBlocksReviewList.habitRow`).
    let targetTime: Date
    /// "AM"/"Midday"/"PM" (see `HabitOccurrenceTimeMode.label`) — what
    /// the row actually shows in place of a time, since these occurrences
    /// were never given a real one.
    let modeLabel: String
}

/// One row `OverdueBlocksReviewList` can show — a real calendar block or
/// an untimed habit occurrence standing in as if it had a time, so both
/// kinds can be grouped by day and sorted together by time instead of
/// living in separate sections.
enum ReviewItem: Identifiable {
    case block(ScheduledBlock)
    case habit(HabitReviewOccurrence)

    var id: String {
        switch self {
        case .block(let block): return "block-\(block.id)"
        case .habit(let occurrence): return "habit-\(occurrence.id)"
        }
    }

    fileprivate var day: Date {
        let calendar = Calendar.current
        switch self {
        case .block(let block): return calendar.startOfDay(for: block.date)
        case .habit(let occurrence): return calendar.startOfDay(for: occurrence.targetTime)
        }
    }

    fileprivate var sortTime: Date {
        switch self {
        case .block(let block): return block.startTime
        case .habit(let occurrence): return occurrence.targetTime
        }
    }
}

/// Live "mark complete" review mixing calendar blocks and untimed habit
/// occurrences into one list, grouped by day (oldest first) and sorted by
/// time within each day — so a backlog spanning several days still reads
/// clearly, and a habit due at 6am doesn't get lost in a separate section
/// from the 7am task sitting right after it. Shared between Nightly
/// Review's "Review Schedule" step and the standalone "Review Previous
/// Events" sheet offered when regenerating a schedule with overdue blocks
/// left over (see `ScheduleReviewViewModel.reviewableBlocks`
/// /`hasIncompletePastBlocks`) — the latter never has habit items, it just
/// wraps its blocks as `.block(_)`.
///
/// Every row's circle directly reflects completion and toggles it
/// immediately on tap — no separate "select, then confirm" step. Checking
/// one off marks it complete, fills the circle green, fades the row, and
/// strikes the title through; tapping it again undoes all of that.
/// `onDone`, if the caller supplies it, is a `.topBarTrailing` toolbar
/// item this view contributes itself (so it lands correctly in whichever
/// ancestor `NavigationStack` hosts it) for whatever "I'm done reviewing"
/// means to that caller — Nightly Review's Today step doesn't need one
/// (its own bottom nav bar already advances), the Regenerate flow's sheet
/// uses it to dismiss and kick off `regenerateFromNow`.
struct OverdueBlocksReviewList: View {
    let items: [ReviewItem]
    /// Fired immediately, every time a row's circle is tapped — the
    /// caller switches on the item to flip a block's completion
    /// (`ScheduleReviewViewModel.toggleComplete`) or a habit occurrence's
    /// (`NightlyReviewView.toggleHabitReviewOccurrence`).
    let onToggle: (ReviewItem) -> Void
    var onDone: (() -> Void)? = nil

    private struct DayGroup: Identifiable {
        let day: Date
        var id: Date { day }
        let items: [ReviewItem]
    }

    private var groupedByDay: [DayGroup] {
        let byDay = Dictionary(grouping: items) { $0.day }
        return byDay
            .map { DayGroup(day: $0.key, items: $0.value.sorted { $0.sortTime < $1.sortTime }) }
            .sorted { $0.day < $1.day }
    }

    var body: some View {
        List {
            if items.isEmpty {
                Text("Nothing to review.")
                    .foregroundStyle(.secondary)
            }
            ForEach(groupedByDay) { group in
                Section(dayLabel(group.day)) {
                    ForEach(group.items) { item in
                        row(for: item)
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

    @ViewBuilder
    private func row(for item: ReviewItem) -> some View {
        switch item {
        case .block(let block):
            blockRow(block)
        case .habit(let occurrence):
            habitRow(occurrence)
        }
    }

    private func blockRow(_ block: ScheduledBlock) -> some View {
        HStack(alignment: .top, spacing: 12) {
            selectionCircle(isSelected: block.isCompleted)
                .contentShape(Rectangle())
                .padding(.vertical, 4)
                .onTapGesture { onToggle(.block(block)) }
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

    private func habitRow(_ occurrence: HabitReviewOccurrence) -> some View {
        HStack(alignment: .top, spacing: 12) {
            selectionCircle(isSelected: occurrence.isCompleted)
                .contentShape(Rectangle())
                .padding(.vertical, 4)
                .onTapGesture { onToggle(.habit(occurrence)) }
            VStack(alignment: .leading) {
                Text(occurrence.modeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(occurrence.habit.name)
                    .strikethrough(occurrence.isCompleted)
            }
            Spacer()
        }
        .opacity(occurrence.isCompleted ? 0.5 : 1)
        .listRowBackground(Shelf.flatten(.accentColor, opacity: 0.2))
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
