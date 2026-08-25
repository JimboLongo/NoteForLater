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

/// One row `OverdueBlocksReviewList` can show — a real calendar block, an
/// untimed habit occurrence standing in as if it had a time, or a
/// completed task that never had (or no longer has) a `ScheduledBlock` at
/// all — so all three kinds can be grouped by day and sorted together by
/// time instead of living in separate sections.
enum ReviewItem: Identifiable {
    case block(ScheduledBlock)
    case habit(HabitReviewOccurrence)
    /// A task completion with no live block to represent it — a 2-Minute
    /// Task and the older Task Attribute Review "Mark Complete" path both
    /// leave a task like this, and `ScheduleReviewViewModel
    /// .purgeCompletedBlocks` deletes it outright once Nightly Review's
    /// Today step commits. `TaskCompletionRecord` is the durable trace
    /// that survives the delete. Always shown already-checked and
    /// non-interactive — there's no live `TaskItem` guaranteed to still
    /// exist to toggle back. `isTwoMinuteTask` is what pins it to the
    /// front of its day (see `sortTime`) — supplied by the caller rather
    /// than derived here, since telling a 2-Minute Task's completion
    /// apart from an ordinary one needs a same-session snapshot
    /// (`NightlyReviewView.twoMinuteReviewTaskIDs`) this enum has no way
    /// to reach on its own, especially once the live task backing this
    /// record is gone.
    case completedTask(TaskCompletionRecord, isTwoMinuteTask: Bool)
    /// The meal picked during Nightly Review's Meals step — never has
    /// its own `ScheduledBlock` represented here (`NightlyReviewView
    /// .reviewableBlocks` excludes it deliberately), even though a real,
    /// locked block does exist for it on the calendar — this is the sole
    /// representation, so the two are never shown as two separate rows
    /// for the same meal. `targetTime` is that same block's own
    /// `startTime` (or `MealSelection.date` if the block's since gone
    /// missing) — stand-in-by-necessity, same idea as
    /// `HabitReviewOccurrence.targetTime`, since it's what lets a meal
    /// sort into its correct position among blocks and habits instead of
    /// living in its own separate section.
    case meal(MealSelection, targetTime: Date)

    var id: String {
        switch self {
        case .block(let block): return "block-\(block.id)"
        case .habit(let occurrence): return "habit-\(occurrence.id)"
        case .completedTask(let record, _): return "completedTask-\(record.id)"
        case .meal(let selection, _): return "meal-\(selection.id)"
        }
    }

    fileprivate var day: Date {
        let calendar = Calendar.current
        switch self {
        case .block(let block): return calendar.startOfDay(for: block.date)
        case .habit(let occurrence): return calendar.startOfDay(for: occurrence.targetTime)
        case .completedTask(let record, _): return calendar.startOfDay(for: record.completedAt)
        case .meal(_, let targetTime): return calendar.startOfDay(for: targetTime)
        }
    }

    /// A 2-Minute Task completion — whether it still has a live
    /// `ScheduledBlock` behind it (the `.block` case) or not (the
    /// `.completedTask` case, once that task's gone) — sorts to the very
    /// front of its day regardless of whatever time it happened to be
    /// scheduled or completed at: these read as "already cleared out of
    /// the way," not as competing with the day's actual timed habits and
    /// tasks for a position among them.
    fileprivate var sortTime: Date {
        switch self {
        case .block(let block):
            if block.task?.shelf?.isTwoMinuteTasks == true {
                return Calendar.current.startOfDay(for: block.startTime)
            }
            return block.startTime
        case .habit(let occurrence): return occurrence.targetTime
        case .completedTask(let record, let isTwoMinuteTask):
            if isTwoMinuteTask {
                return Calendar.current.startOfDay(for: record.completedAt)
            }
            return record.completedAt
        case .meal(_, let targetTime): return targetTime
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
/// left over — both mix in untimed habit occurrences the same way, via
/// `ScheduleReviewViewModel.openHabitOccurrencesForReview` alongside
/// `reviewableBlocks`/`hasIncompletePastBlocks` for the blocks themselves.
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
    /// Fired every time a row's circle is tapped. What it actually does
    /// is the caller's choice, not this view's: Nightly Review's Today
    /// step stages the tap in local state and only writes the real model
    /// on Next (see `isEffectivelyCompleted` below), while a caller that
    /// wants the old immediate-write behavior can still flip a block's
    /// completion (`ScheduleReviewViewModel.toggleComplete`) or a habit
    /// occurrence's (`ScheduleReviewViewModel.toggleHabitOccurrence`)
    /// directly from here. Never fired for `.completedTask` — that row
    /// has no live model to toggle.
    let onToggle: (ReviewItem) -> Void
    var onDone: (() -> Void)? = nil
    /// Overrides a row's rendered completion state without reading
    /// `block.isCompleted`/`occurrence.isCompleted` directly — how
    /// Nightly Review's Today step shows a tap as pending-but-reversible
    /// before Next actually commits it. `nil` (the default) falls back
    /// to reading the model directly, unchanged from before this existed.
    var isEffectivelyCompleted: ((ReviewItem) -> Bool)? = nil

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
            blockRow(block, isCompleted: isEffectivelyCompleted?(item) ?? block.isCompleted)
        case .habit(let occurrence):
            habitRow(occurrence, isCompleted: isEffectivelyCompleted?(item) ?? occurrence.isCompleted)
        case .completedTask(let record, _):
            completedTaskRow(record)
        case .meal(let selection, let targetTime):
            mealRow(selection, targetTime: targetTime, isCompleted: isEffectivelyCompleted?(item) ?? selection.isCompleted)
        }
    }

    /// The whole row is the tap target, not just the circle —
    /// `.contentShape(Rectangle())` on the outer `HStack` is what makes
    /// the `Spacer()`'s blank space and the lock icon tappable too, not
    /// just wherever the row happens to draw something.
    private func blockRow(_ block: ScheduledBlock, isCompleted: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            selectionCircle(isSelected: isCompleted)
                .padding(.vertical, 4)
            VStack(alignment: .leading) {
                Text(timeRangeText(block))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(block.displayTitle)
                    .strikethrough(isCompleted)
            }
            Spacer()
            if block.isLocked {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggle(.block(block)) }
        .opacity(isCompleted ? 0.5 : 1)
        .listRowBackground((block.task?.shelf?.color ?? Color.clear).opacity(0.2))
    }

    /// Same full-row tap target as `blockRow`.
    private func habitRow(_ occurrence: HabitReviewOccurrence, isCompleted: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            selectionCircle(isSelected: isCompleted)
                .padding(.vertical, 4)
            VStack(alignment: .leading) {
                Text(occurrence.modeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(occurrence.habit.name)
                    .strikethrough(isCompleted)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggle(.habit(occurrence)) }
        .opacity(isCompleted ? 0.5 : 1)
        .listRowBackground(Shelf.flatten(.accentColor, opacity: 0.2))
    }

    /// Same full-row tap target as `blockRow`/`habitRow` — reconstructs
    /// `.meal(selection, targetTime:)` for the toggle callback rather
    /// than needing the original `ReviewItem` threaded through; `id`
    /// only ever depends on `selection.id`, so passing `targetTime` again
    /// here (rather than the exact value this row was built with)
    /// doesn't change which item the caller ends up toggling.
    private func mealRow(_ selection: MealSelection, targetTime: Date, isCompleted: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            selectionCircle(isSelected: isCompleted)
                .padding(.vertical, 4)
            Text("Cooked: \(selection.recipeTitle)")
                .strikethrough(isCompleted)
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggle(.meal(selection, targetTime: targetTime)) }
        .opacity(isCompleted ? 0.5 : 1)
    }

    /// Read-only — no `onTapGesture` at all. `record`'s underlying task
    /// may well no longer exist (see `ReviewItem.completedTask`), so
    /// there's nothing this row could toggle back even if it wanted to.
    private func completedTaskRow(_ record: TaskCompletionRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            selectionCircle(isSelected: true)
                .padding(.vertical, 4)
            VStack(alignment: .leading) {
                Text("Completed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(record.title)
                    .strikethrough(true)
            }
            Spacer()
        }
        .opacity(0.5)
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
