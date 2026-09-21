import SwiftUI
import SwiftData

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
    /// The full four-state status, not just complete/incomplete — Nightly
    /// Review's habit rows now cycle through the same `none -> complete ->
    /// missed -> excused -> none` sequence the Habits tab and the day
    /// calendar already use (see `NightlyReviewView.cycleHabitReviewOccurrence`),
    /// so a row needs to render all four, not just two.
    let status: OccurrenceStatus
    var isCompleted: Bool { status == .complete }
    var isMissed: Bool { status == .missed }
    var isExcused: Bool { status == .excused }
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
    /// An AM/Midday/PM recurring task occurrence — the task counterpart
    /// to `.habit`, same reason: never has a `ScheduledBlock` of its own.
    /// A Specific-Time recurring task occurrence is NOT this case — it
    /// has a real block, so it stays `.block` (see `blockRow`'s own
    /// comment for how that row goes 3-state for a recurring task).
    case recurringTask(ScheduleReviewViewModel.RecurringTaskReviewOccurrence)
    /// A task completion with no live block to represent it, from the Task
    /// Attribute Review "Mark Complete" path — `ScheduleReviewViewModel
    /// .purgeCompletedBlocks` deletes the task outright once Nightly
    /// Review's Today step commits, and `TaskCompletionRecord` is the
    /// durable trace that survives that delete. Always shown
    /// already-checked and non-interactive: there's no live `TaskItem`
    /// guaranteed to still exist to toggle back.
    ///
    /// REVERSAL: this used to name the 2-Minute step as a second producer
    /// and justified showing its completions here on the grounds that they
    /// would otherwise be invisible. That was wrong twice over — the
    /// 2-Minute step displays them perfectly well on its own, and showing
    /// them again one step later asked the same question twice. They are
    /// filtered now (see `ReviewAnswerLedger`); a 2-Minute completion no
    /// longer reaches this case at all.
    ///
    /// **Inbox completions still do, deliberately** — see
    /// `ReviewAnswerLedger.inboxCompletionsAreEchoedOnToday`.
    ///
    /// `isTwoMinuteTask` survives because it still pins a row to the front
    /// of its day (see `sortTime`) and because the filter is applied by the
    /// caller, not here — this enum cannot reach the session snapshot that
    /// would tell it, especially once the live task is gone.
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
        case .recurringTask(let occurrence): return "recurringTask-\(occurrence.id)"
        case .completedTask(let record, _): return "completedTask-\(record.id)"
        case .meal(let selection, _): return "meal-\(selection.id)"
        }
    }

    /// What this row *is*, for `ReviewAnswerLedger` — the identity a
    /// different step would have answered it under.
    ///
    /// `nil` means the row has no earlier-step counterpart and can never be
    /// a duplicate: a meal is only ever answered on the Meals step and
    /// rendered here, and a bare block with neither task nor habit behind it
    /// has no identity to match on.
    ///
    /// **A habit-backed block keys as its occurrence**, not as a block. That
    /// is what closes the habit route: `reviewableBlocks` does not filter on
    /// `habit`, so a habit answered on the Habits step would otherwise come
    /// back here as a `.block`. The store holds zero habit blocks today, but
    /// that is a fact about one person's data, not about this code.
    var answeredKey: ReviewAnswerKey? {
        switch self {
        case .block(let block):
            if let habit = block.habit {
                return .habitOccurrence(habitID: habit.id, index: block.habitOccurrenceIndex)
            }
            return block.task.map { .task($0.id) }
        case .habit(let occurrence):
            return .habitOccurrence(habitID: occurrence.habit.id, index: occurrence.index)
        case .recurringTask(let occurrence):
            return .task(occurrence.task.id)
        case .completedTask(let record, _):
            return .task(record.taskID)
        case .meal:
            return nil
        }
    }

    /// Whether this row currently blocks the Today step's "Next" gate —
    /// see `NightlyReviewView.unresolvedGateReviewItems`'s own doc
    /// comment for the full reasoning behind what counts as unresolved.
    /// Extracted here, out of that view property's filter closure, so
    /// it's directly testable without a SwiftUI/`@Query` harness — the
    /// same reason `ScheduleReviewViewModel.recurringTaskOccurrenceStatus`
    /// is already a standalone function rather than inline view logic.
    func blocksGate(context: ModelContext, reviewDate: Date, calendar: Calendar = .current) -> Bool {
        switch self {
        case .habit: return false // unreachable — see `unresolvedGateReviewItems`'s own doc comment
        case .recurringTask(let occurrence):
            // **Backlog only**, matching the Habits step's own gate (see
            // `ScheduleReviewViewModel.backlogHabitOccurrences`). A recurring
            // task due this evening may still legitimately happen; being made
            // to declare it done or missed at 9pm while planning tomorrow is
            // a false choice. Earlier days are over, so anything still
            // unresolved there is genuinely unaddressed.
            //
            // Habits got this treatment when their gate was split out; the
            // recurring side kept the old combined rule and never did. The
            // asymmetry was the oversight, not this.
            //
            // Visibility is unchanged: the review date's own occurrences
            // still render and are still markable. Gating only.
            guard occurrence.status == .none else { return false }
            return calendar.startOfDay(for: occurrence.targetTime) < calendar.startOfDay(for: reviewDate)
        case .block(let block):
            // KEPT DESPITE BEING UNREACHABLE FOR NEW DATA — same reason as
            // `ScheduleReviewViewModel.isRecurringTaskOccurrenceComplete`'s
            // own retained branch. The migration keeps past incomplete
            // blocks, and an overdue-review row for one must still read its
            // status from `RecurringTaskLog` rather than falling through to
            // the ordinary `block.status` path below.
            if let task = block.task, task.isRecurring, task.recurrenceTimeMode == .specific {
                return ScheduleReviewViewModel.recurringTaskOccurrenceStatus(task: task, on: block.date, context: context) == .none
            }
            // An ordinary (non-recurring) task block — gated on its own
            // `status` now, same as every other row here.
            return block.status == .none
        case .meal(let selection, _): return selection.status == .none
        case .completedTask: return false
        }
    }

    // `internal` (not `fileprivate`) so `NightlyReviewSortOrderTests` can
    // exercise the real sort logic in `groupedByDay` directly, rather than
    // duplicating it in test code — a duplicated comparator could drift
    // from the real one and pass while the real one regresses.
    var day: Date {
        let calendar = Calendar.current
        switch self {
        case .block(let block): return calendar.startOfDay(for: block.date)
        case .habit(let occurrence): return calendar.startOfDay(for: occurrence.targetTime)
        case .recurringTask(let occurrence): return calendar.startOfDay(for: occurrence.targetTime)
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
    var sortTime: Date {
        switch self {
        case .block(let block):
            if block.task?.shelf?.isTwoMinuteTasks == true {
                return Calendar.current.startOfDay(for: block.startTime)
            }
            return block.startTime
        case .habit(let occurrence): return occurrence.targetTime
        case .recurringTask(let occurrence): return occurrence.targetTime
        case .completedTask(let record, let isTwoMinuteTask):
            if isTwoMinuteTask {
                return Calendar.current.startOfDay(for: record.completedAt)
            }
            return record.completedAt
        case .meal(_, let targetTime): return targetTime
        }
    }

    /// The habit's own `sortOrder` — same field `openHabitOccurrences`
    /// already sorts by — for `.habit` items only; `nil` for everything
    /// else. Purely a same-`sortTime` tiebreak (see `groupedByDay`), so
    /// two AM habits stay in a stable, predictable order regardless of
    /// which one gets cycled — a habit's position must never depend on
    /// its own status, only on its time mode and its place among habits
    /// sharing that mode.
    var habitSortOrder: Int? {
        if case .habit(let occurrence) = self { return occurrence.habit.sortOrder }
        return nil
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
    /// is the caller's choice, not this view's — every row writes
    /// immediately now (Nightly Review's Today step used to stage
    /// `.block`/`.meal` taps and only commit on Next; that's gone, since
    /// a three-state cycle needs each tap to see the row's real, current
    /// status to know what the next one should produce). Never fired for
    /// `.completedTask` — that row has no live model to toggle.
    let onToggle: (ReviewItem) -> Void
    var onDone: (() -> Void)? = nil
    /// Set by the caller to a `ReviewItem.id` to scroll that row into
    /// view (e.g. Nightly Review's "N habits still unmarked" jump-to
    /// button, for a long list where the gate is blocking on a row
    /// that's scrolled off-screen) — reset back to `nil` immediately
    /// after the scroll runs, so setting the same id again still fires
    /// `onChange`. `.constant(nil)` (the default) makes this a no-op for
    /// callers with nothing to jump to.
    var scrollTarget: Binding<String?> = .constant(nil)
    /// Needed only to read a recurring task's live `RecurringTaskLog`
    /// status for a Specific-Time occurrence's `.block` row (see
    /// `blockRow`) — every other row's status already arrives fully
    /// formed on its `ReviewItem`.
    @Environment(\.modelContext) private var modelContext

    // `internal` for the same testability reason as `ReviewItem`'s sort
    // fields above.
    struct DayGroup: Identifiable {
        let day: Date
        var id: Date { day }
        let items: [ReviewItem]
    }

    /// Within a day, everything sorts by `sortTime` alone, regardless of
    /// status — a habit's position must stay fixed while working down the
    /// list, so tapping it complete/missed/excused can never move it
    /// (an earlier version pushed resolved habits to the end of their
    /// day; that made the list shift under the reviewer's finger, which
    /// is worse than a completed item just sitting inline). `sortTime`
    /// for a habit occurrence is a stand-in built from its
    /// `HabitOccurrenceTimeMode` (see `ScheduleReviewViewModel
    /// .targetMinutes`: AM=6am, Midday=noon, PM=9pm), so AM/Midday/PM
    /// order is explicit and deterministic, not incidental. When two
    /// items land on the exact same `sortTime` — two habits sharing a
    /// time mode — `habitSortOrder` breaks the tie using the habit's own
    /// `sortOrder`, the same field `openHabitOccurrences` sorts by, so
    /// two AM habits keep a stable relative order. Non-habit ties (or a
    /// habit tied against a block/meal/completed-task) fall through to
    /// `sorted`'s stability, preserving `items`' own order — the same as
    /// before any of this existed.
    var groupedByDay: [DayGroup] {
        let byDay = Dictionary(grouping: items) { $0.day }
        return byDay
            .map { DayGroup(day: $0.key, items: $0.value.sorted {
                if $0.sortTime != $1.sortTime { return $0.sortTime < $1.sortTime }
                if let lhs = $0.habitSortOrder, let rhs = $1.habitSortOrder { return lhs < rhs }
                return false
            }) }
            .sorted { $0.day < $1.day }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if items.isEmpty {
                    Text("Nothing to review.")
                        .foregroundStyle(.secondary)
                }
                ForEach(groupedByDay) { group in
                    Section(dayLabel(group.day)) {
                        ForEach(group.items) { item in
                            row(for: item)
                                .id(item.id)
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
            .onChange(of: scrollTarget.wrappedValue) { _, target in
                guard let target else { return }
                withAnimation {
                    proxy.scrollTo(target, anchor: .center)
                }
                scrollTarget.wrappedValue = nil
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
        case .recurringTask(let occurrence):
            recurringTaskRow(occurrence)
        case .completedTask(let record, _):
            completedTaskRow(record)
        case .meal(let selection, let targetTime):
            mealRow(selection, targetTime: targetTime)
        }
    }

    /// The whole row is the tap target, not just the circle —
    /// `.contentShape(Rectangle())` on the outer `HStack` is what makes
    /// the `Spacer()`'s blank space and the lock icon tappable too, not
    /// just wherever the row happens to draw something.
    ///
    /// Three-state for every block now, not just a recurring task's own
    /// Specific-Time one — the only difference between the two branches
    /// is *where* the status comes from. A recurring task's block reads
    /// live through `RecurringTaskLog` instead (see `ScheduleReviewViewModel
    /// .recurringTaskOccurrenceStatus`), the same source of truth
    /// `TaskItem.cycleRecurringOccurrence` writes to — `block.status` is
    /// only ever a mirror for this task, never consulted directly here.
    /// An ordinary task block reads `block.status` directly instead — it
    /// *is* the source of truth for that one (see `ScheduledBlock.status`'s
    /// own doc comment). The caller's `onToggle` is what actually decides
    /// which cycle a tap advances (see `NightlyReviewView.todayStep`'s
    /// own `isRecurring` check) — this only decides what to display.
    @ViewBuilder
    private func blockRow(_ block: ScheduledBlock) -> some View {
        let status: OccurrenceStatus = {
            if let task = block.task, task.isRecurring {
                return ScheduleReviewViewModel.recurringTaskOccurrenceStatus(task: task, on: block.date, context: modelContext)
            }
            return block.status
        }()
        HStack(alignment: .top, spacing: 12) {
            habitSelectionCircle(status: status)
                .padding(.vertical, 4)
            VStack(alignment: .leading) {
                Text(timeRangeText(block))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(block.displayTitle)
                    .strikethrough(status == .complete)
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
        .opacity(status == .none ? 1 : 0.5)
        .listRowBackground((block.task?.shelf?.color ?? Color.clear).opacity(0.2))
    }

    /// Same full-row tap target as `blockRow`.
    private func habitRow(_ occurrence: HabitReviewOccurrence) -> some View {
        HStack(alignment: .top, spacing: 12) {
            habitSelectionCircle(status: occurrence.status)
                .padding(.vertical, 4)
            VStack(alignment: .leading) {
                Text(occurrence.modeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Strikethrough stays tied to completion specifically, not
                // missed/excused — same reasoning as `DayTimelineGridView
                // .occurrenceRow`: crossed-out reads as "done," which
                // neither of those is: the circle alone carries that
                // distinction.
                Text(occurrence.habit.name)
                    .strikethrough(occurrence.isCompleted)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggle(.habit(occurrence)) }
        .opacity(occurrence.isCompleted || occurrence.isMissed || occurrence.isExcused ? 0.5 : 1)
        .listRowBackground(Shelf.flatten(.accentColor, opacity: 0.2))
    }

    /// The AM/Midday/PM counterpart to `habitRow` — no `.excused` state,
    /// so the circle only ever renders none/complete/missed, but reuses
    /// the same `habitSelectionCircle` (which already tolerates a status
    /// it doesn't need) rather than a second near-identical circle.
    private func recurringTaskRow(_ occurrence: ScheduleReviewViewModel.RecurringTaskReviewOccurrence) -> some View {
        HStack(alignment: .top, spacing: 12) {
            habitSelectionCircle(status: occurrence.status)
                .padding(.vertical, 4)
            VStack(alignment: .leading) {
                Text(occurrence.modeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(occurrence.task.title)
                    .strikethrough(occurrence.status == .complete)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggle(.recurringTask(occurrence)) }
        .opacity(occurrence.status == .none ? 1 : 0.5)
        .listRowBackground((occurrence.task.shelf?.color ?? Color.accentColor).opacity(0.2))
    }

    /// Same full-row tap target as `blockRow`/`habitRow` — reconstructs
    /// `.meal(selection, targetTime:)` for the toggle callback rather
    /// than needing the original `ReviewItem` threaded through; `id`
    /// only ever depends on `selection.id`, so passing `targetTime` again
    /// here (rather than the exact value this row was built with)
    /// doesn't change which item the caller ends up toggling.
    private func mealRow(_ selection: MealSelection, targetTime: Date) -> some View {
        HStack(alignment: .top, spacing: 12) {
            habitSelectionCircle(status: selection.status)
                .padding(.vertical, 4)
            Text("Cooked: \(selection.recipeTitle)")
                .strikethrough(selection.status == .complete)
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggle(.meal(selection, targetTime: targetTime)) }
        .opacity(selection.status == .none ? 1 : 0.5)
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

    /// Same fill/icon mapping `HabitsView.fillColor`/`occurrenceIcon` and
    /// `DayTimelineGridView.occurrenceRow` already use for the four-state
    /// cycle — reused here rather than invented a third time, so a habit
    /// reads the same way on the Habits tab, the day calendar, and in
    /// Nightly Review.
    private func habitSelectionCircle(status: OccurrenceStatus) -> some View {
        let circleColor: Color = status == .complete ? .green : (status == .missed ? .red.opacity(0.55) : (status == .excused ? .gray.opacity(0.4) : .clear))
        let strokeColor: Color = status == .none ? .secondary.opacity(0.5) : circleColor
        return ZStack {
            Circle()
                .fill(circleColor)
                .overlay(Circle().strokeBorder(strokeColor, lineWidth: 1.5))
            if status == .complete {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
            } else if status == .missed {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
            } else if status == .excused {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 22, height: 22)
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
