import SwiftUI
import SwiftData

// MARK: - Occurrence row models
//
// Shared between `DayTimelineGridView` (which computes the per-mode
// lists) and `OccurrenceSectionView` below (which renders them), so
// these live at file scope rather than nested privately inside either
// one. They were `private` members of `DayTimelineGridView` before the
// sections were split out of it.

struct OpenHabitOccurrence: Identifiable {
    let id: String
    let habit: Habit
    let index: Int
    /// So the row can show checked/missed/excused/untouched instead of
    /// disappearing the instant its state changes — same as a
    /// Specific-Time habit's own calendar block, which stays visible
    /// (just faded) rather than vanishing on tap. Every `OccurrenceStatus`
    /// case is representable here now — see `openHabitOccurrences`'s
    /// own doc comment for why `.excused` had to join `.missed`.
    let status: OccurrenceStatus
    var isCompleted: Bool { status == .complete }
    var isMissed: Bool { status == .missed }
    var isExcused: Bool { status == .excused }
}

/// Same shape as `OpenHabitOccurrence`, for a recurring `TaskItem`
/// occurrence shown as a plain check-off item instead of a calendar
/// block (see `TaskItem.recurrenceTimeMode`) — reads `RecurringTaskLog`
/// where a habit occurrence reads `HabitLog`.
struct OpenRecurringTaskOccurrence: Identifiable {
    let id: String
    let task: TaskItem
    /// The full three-state cycle — see `ProjectedRecurringTaskOccurrence
    /// .status`'s own doc comment.
    let status: OccurrenceStatus
    var isCompleted: Bool { status == .complete }
    var isMissed: Bool { status == .missed }
    /// True when this occurrence is showing on `targetDate` only
    /// because it's being pushed forward from an earlier miss (see
    /// `PushedRecurringOccurrence`), not because today is actually
    /// one of this task's own recurrence days — drives the "Pushed"
    /// indicator in `occurrenceRow`.
    let isPushed: Bool
}

/// One row `habitOccurrenceSection` can show — a habit occurrence or a
/// recurring task occurrence, merged into the same AM/Midday/PM list
/// (see `computeOpenHabitOccurrenceLists`) so the two interleave in
/// one section instead of habits and recurring tasks living in visibly
/// separate lists for the same part of the day.
enum OpenOccurrenceRow: Identifiable {
    case habit(OpenHabitOccurrence)
    case recurringTask(OpenRecurringTaskOccurrence)

    var id: String {
        switch self {
        case .habit(let occurrence): return occurrence.id
        case .recurringTask(let occurrence): return occurrence.id
        }
    }
}

// MARK: - Occurrence sections

/// One Morning / Midday / Evening band of check-off rows sitting above,
/// between, or below the calendar grid — every habit occurrence for that
/// part of the day in one shared box, plus one box per shelf for
/// recurring-task occurrences.
///
/// **Not habits-only, despite the name these sections carry in the
/// spec.** `occurrenceGroups` emits a habit group *and* a group per
/// shelf of recurring tasks, so this view depends on task/shelf data as
/// well as habit data — worth knowing before treating "extract the habit
/// sections" as a clean habits/tasks boundary.
///
/// Split out of `DayTimelineGridView` as the first move of that file's
/// structural split (spec §10 #5, "Half A"). Purely presentational: it
/// receives its already-computed rows and streaks, and reports taps back
/// through closures. The occurrence *lists* are still computed by the
/// parent, which also needs them to decide whether the day splits at
/// noon at all (`isSplitAtNoon`) — moving that computation down here
/// would be the Half B data-flow change, which is deliberately not part
/// of this.
///
/// **Geometry stays the parent's.** Each section's rendered height feeds
/// `DayTimelineSegment.precedingContentHeight` via `.onGeometryChange`
/// at the *call site*, not in here — see `DayTimelineGeometry`. Those
/// heights are summed with the morning grid's own height into a value
/// only the parent can assemble, so the modifier stays attached where
/// the parent applies it. Consequence, stated because it bounds what
/// this split actually buys: the parent still re-renders when a
/// section's *height* changes, just not when only its *contents* do.
///
/// **Both writers stay in the parent too**, passed in as closures rather
/// than moved down here: `cycleRecurringTaskOccurrence` is also wired
/// into all three `DayTimelineSegment` call sites, so it can't live
/// solely in this view, and splitting the habit/task pair across two
/// files for no reason would be worse than keeping them together. They
/// own the `habitOccurrenceRefreshTick` increment that drives the
/// parent's re-render after a tap.
struct OccurrenceSectionView: View {
    let title: String
    let occurrences: [OpenOccurrenceRow]
    /// Computed once per parent body pass — see
    /// `DayTimelineGridView.cachedHabitStreaks`.
    let habitStreaks: [UUID: Int]
    let onToggleHabitOccurrence: (Habit, Int) -> Void
    let onCycleRecurringTaskOccurrence: (TaskItem) -> Void

    @ViewBuilder
    var body: some View {
        let groups = occurrenceGroups(from: occurrences, habitsTitle: title)
        if !groups.isEmpty {
            // Zero spacing — the habit box and each shelf's own recurring-
            // task box sit flush against each other, not as visually
            // separate cards with a gap between them. Each box's own
            // internal `.padding(.vertical, 10)` (see `occurrenceBox`) is
            // untouched, so there's still breathing room *inside* each
            // one — only the space *between* boxes is gone.
            VStack(spacing: 0) {
                ForEach(groups) { group in
                    occurrenceBox(title: group.title, backgroundColor: group.backgroundColor, rows: group.rows)
                }
            }
            .padding(.bottom, 10)
        }
    }

    /// One visually distinct box within a Morning/Midday/Evening section —
    /// either every habit occurrence in that part of the day (one shared
    /// box, blue), or one shelf's recurring task occurrences (its own box,
    /// that shelf's own color) — so a recurring task never reads as
    /// belonging to the habit group it happens to share a time mode with.
    private struct OccurrenceGroup: Identifiable {
        let id: String
        let title: String
        let backgroundColor: Color
        let rows: [OpenOccurrenceRow]
    }

    /// Splits one mode's occurrences (habits and recurring tasks mixed
    /// together, as `computeOpenHabitOccurrenceLists` builds them) back
    /// apart into the boxes `habitOccurrenceSection` actually renders —
    /// habits always first (as one group, titled `habitsTitle`), then one
    /// group per distinct shelf a recurring task in this list belongs to,
    /// in the order each shelf is first encountered. A `Dictionary`-based
    /// grouping alone won't do for that last part — its iteration order
    /// isn't guaranteed, which would make the shelf boxes reorder
    /// themselves from one render to the next for no reason a user could
    /// see.
    private func occurrenceGroups(from occurrences: [OpenOccurrenceRow], habitsTitle: String) -> [OccurrenceGroup] {
        var groups: [OccurrenceGroup] = []

        let habitRows = occurrences.filter { if case .habit = $0 { return true }; return false }
        if !habitRows.isEmpty {
            groups.append(OccurrenceGroup(id: "habits", title: habitsTitle, backgroundColor: Shelf.flatten(.accentColor, opacity: 0.35), rows: habitRows))
        }

        var shelfOrder: [UUID?] = []
        var rowsByShelfID: [UUID?: [OpenOccurrenceRow]] = [:]
        var shelfByID: [UUID?: Shelf?] = [:]
        for row in occurrences {
            guard case .recurringTask(let occurrence) = row else { continue }
            let shelfID = occurrence.task.shelf?.id
            if rowsByShelfID[shelfID] == nil {
                shelfOrder.append(shelfID)
                rowsByShelfID[shelfID] = []
                shelfByID[shelfID] = occurrence.task.shelf
            }
            rowsByShelfID[shelfID, default: []].append(row)
        }
        for shelfID in shelfOrder {
            let shelf = shelfByID[shelfID] ?? nil
            groups.append(OccurrenceGroup(
                id: "shelf-\(shelfID?.uuidString ?? "none")",
                // Falls back to a generic title only for a recurring task
                // with no shelf at all — not a normal state (every shelf
                // list a task can live on has a name), but not one this
                // view should crash or show a blank header over either.
                title: shelf?.name ?? "Recurring Tasks",
                backgroundColor: shelf?.flattenedColor(opacity: 0.35) ?? Color.secondary.opacity(0.35),
                rows: rowsByShelfID[shelfID] ?? []
            ))
        }
        return groups
    }

    /// One rendered box — header plus its own rows plus its own
    /// background — shared by the habit group and every per-shelf
    /// recurring task group so the two read as the exact same *kind* of
    /// thing, just colored and grouped differently. Same visual shape as
    /// `twoMinuteTasksSection` — a checked row stays visible (checkmark
    /// filled, name faded/struck through), same as a Specific-Time
    /// habit's own calendar block, rather than disappearing the instant
    /// it's tapped.
    private func occurrenceBox(title: String, backgroundColor: Color, rows: [OpenOccurrenceRow]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                ForEach(rows) { row in
                    switch row {
                    case .habit(let occurrence):
                        occurrenceRow(name: occurrence.habit.name, isCompleted: occurrence.isCompleted, isMissed: occurrence.isMissed, isExcused: occurrence.isExcused, streak: habitStreaks[occurrence.habit.id]) {
                            onToggleHabitOccurrence(occurrence.habit, occurrence.index)
                        }
                    case .recurringTask(let occurrence):
                        occurrenceRow(name: occurrence.task.title, isCompleted: occurrence.isCompleted, isMissed: occurrence.isMissed, isPushed: occurrence.isPushed) {
                            onCycleRecurringTaskOccurrence(occurrence.task)
                        }
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Same tint a habit's own calendar block uses — `Color.accentColor
        // .opacity(0.35)` — flattened to a solid color the same way
        // `twoMinuteTasksSection` is, so it reads as opaque rather than
        // washed-out. A recurring task's own box uses its shelf's color
        // here instead (see `occurrenceGroups`).
        .background(backgroundColor)
    }

    /// The shared row content for both a habit occurrence and a recurring
    /// task occurrence — same checkmark-circle-plus-title shape either
    /// way, just parameterized by name/completion/tap-action so
    /// `habitOccurrenceSection` doesn't duplicate this markup per kind.
    /// `isPushed` (never true for a habit — only `OpenRecurringTaskOccurrence`
    /// ever sets it) shows a small "Pushed" tag, so it's clear this row is
    /// here because of an earlier miss rather than today being one of
    /// this task's own recurrence days. `isMissed`/`isExcused` (never true
    /// for a recurring task — those have no missed/excused concept, only
    /// `isCompleted`) reuse the exact fill/icon treatment
    /// `HabitsView.fillColor`/`occurrenceIcon` already use for `.missed`/
    /// `.excused`, so a habit reads the same way whether you're looking at
    /// the Habits tab or this calendar.
    private func occurrenceRow(name: String, isCompleted: Bool, isMissed: Bool = false, isExcused: Bool = false, isPushed: Bool = false, streak: Int? = nil, onToggle: @escaping () -> Void) -> some View {
        // Same fill/stroke mapping as `HabitsView.fillColor`, and the same
        // icon mapping as `HabitsView.occurrenceIcon` — kept as plain
        // local values rather than a fifth boolean branch inline below,
        // since a fourth visual state (after complete/missed) is exactly
        // where a chain of ternaries stops being readable.
        let circleColor: Color = isCompleted ? .green : (isMissed ? .red.opacity(0.55) : (isExcused ? .gray.opacity(0.4) : .clear))
        let circleStrokeColor: Color = isCompleted || isMissed || isExcused ? circleColor : .secondary.opacity(0.7)
        return Button(action: onToggle) {
            HStack(spacing: 10) {
                // Same checkmark-circle look
                // `DayTimelineSegment.completeCircle` uses for a calendar
                // block, so an occurrence reads the same way whether it's
                // timed or not.
                ZStack {
                    Circle()
                        .fill(circleColor)
                        .overlay(Circle().strokeBorder(circleStrokeColor, lineWidth: 1.5))
                    if isCompleted {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                    } else if isMissed {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                    } else if isExcused {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 15, height: 15)
                // Same title font a Specific-Time habit's own calendar
                // block uses (see `DayTimelineSegment.blockContent`), so
                // an AM/Midday/PM occurrence reads as the same kind of
                // thing, just without a time. Strikethrough stays tied to
                // completion specifically, not missed — crossed-out reads
                // as "done," which a miss isn't; the red circle alone
                // already carries that distinction.
                Text(name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .strikethrough(isCompleted)
                if let streak {
                    Text(Habit.signedText(streak))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(streakColor(streak))
                }
                if isPushed {
                    Text("Pushed")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2), in: Capsule())
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isCompleted || isMissed || isExcused ? 0.5 : 1)
    }

    /// Same sign-to-color mapping `HabitsView` already uses for its own
    /// streak display — kept consistent rather than reusing that view's
    /// own private helper, which isn't visible from here. Moved here with
    /// `occurrenceRow`, its only caller in the grid — `DayTimelineSegment`
    /// keeps its own separate copy for its own rows.
    private func streakColor(_ value: Int) -> Color {
        if value > 0 { return .green }
        if value < 0 { return .red }
        return .secondary
    }
}
