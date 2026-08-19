import SwiftUI
import SwiftData

/// The day's schedule as a real visual timeline — hour gridlines down the
/// left, calendar events and proposed blocks positioned by actual time,
/// eligible-hours windows outlined behind everything so a drop target is
/// visible before you let go. This is the only way `ScheduleReviewView`
/// shows a day now (the old List, with swipe actions and native reorder,
/// has been fully replaced — everything it could do is reachable here via
/// tap or drag instead):
///
///   - Hold-and-drag an unlocked block/event (a brief hold first, same as
///     the empty-slot gesture below — see `LongPressDragGesture.swift` for
///     why this needed a real UIKit gesture recognizer, not pure SwiftUI
///     `Gesture` composition): it snaps to 15-minute slots live as you
///     move it, and on release `ScheduleReviewViewModel.reorderTimeline`
///     repacks every unlocked entry back-to-back around where it landed —
///     the same reflow the List's Edit-mode drag used to do, just driven
///     by a real time-grid instead of a row reorder.
///   - Tap a calendar event: edit its title/time/notes, or toggle locked
///     (locked events can't be dragged and are excluded from the reflow).
///   - Tap a proposed task block: See Task Card (opens the full task
///     editor), Adjust Scheduled Time if it's divisible (a slider to
///     shrink this block, leaving the freed time back on the shelf), and
///     Replace Task — opens the unscheduled queue to pick a specific
///     replacement, or its Auto button to swap in the next-best one
///     instead. Delete's always there too, though
///     swiping the block left does the same thing directly. Marking
///     complete is the tap-circle on the card itself, not a menu item.
///     A habit block (no task behind it) only ever offers Delete.
///   - Long-press an open slot: pick an unscheduled to-do, from a
///     full-screen sheet, to drop in right there.
/// Composes the day's actual grid (`DayTimelineSegment`, one instance, or
/// two split at noon) with the untimed habit-occurrence lists around it —
/// this is the piece `ScheduleReviewView`/`NightlyReviewView` actually
/// hold onto. Owns the single shared `ScrollView` all of that content
/// lives inside (so it all scrolls together as one continuous page) and
/// the scroll-position/viewport state each segment needs a slice of,
/// since only one physical ScrollView exists no matter how many segments
/// are showing.
struct DayTimelineGridView: View {
    let rows: [DayTimelineRow]
    let eligibleHoursWindows: [EligibleHoursWindow]
    let targetDate: Date
    let lockedStore: LockedEventsStore
    let viewModel: ScheduleReviewViewModel
    let isToday: Bool
    let allTasks: [TaskItem]
    /// For presenting `TaskCardSheet` (See Task Card) with somewhere to
    /// move a task to.
    let allShelves: [Shelf]
    /// For the Morning/Midday/Evening untimed habit-occurrence lists (see
    /// `habitOccurrenceSection`) — a specific-time habit's own occurrence
    /// still comes through `rows` like any other block; this is only for
    /// the AM/Midday/PM ones, which never get a `ScheduledBlock` at all
    /// (see `AISchedulingService.placeHabitsAndRecurringTasks`).
    let allHabits: [Habit]
    let onSaveEvent: (CalendarEventSummary) -> Void
    let onDeleteBlock: (ScheduledBlock) -> Void
    /// Opens `ReplacementPickerSheet` — a specific pick from the list, or
    /// its Auto button, both handled there (see `ScheduleReviewView`).
    let onPickReplacement: (ScheduledBlock) -> Void
    /// Off by default so a caller that doesn't offer the toggle at all
    /// (`NightlyReviewView`, currently) doesn't need to pass anything —
    /// see `DayTimelineSegment.isCollapsingEmptyPeriods` for what this
    /// actually does.
    var isCollapsingEmptyPeriods: Bool = false
    /// Bumped to force every segment to drop its own manually-expanded
    /// gaps (see `DayTimelineSegment.manuallyExpandedGapKeys`) and fall
    /// back to the default collapsed state — used when the toolbar
    /// button is tapped while every gap has already been individually
    /// expanded, so `isCollapsingEmptyPeriods` itself has nothing to
    /// toggle (it's already `true`) but the day still needs to actually
    /// re-collapse.
    var collapseResetToken: Int = 0
    /// Reports whether *any* segment currently has at least one gap
    /// actually shown collapsed — false once every gap's been manually
    /// expanded away, even with `isCollapsingEmptyPeriods` still on. Lets
    /// `ScheduleReviewView`'s toolbar button fall back to showing the
    /// "collapse" icon in that case, rather than reading as broken
    /// because tapping "expand" again does nothing (there'd be nothing
    /// left to expand).
    var onCollapsedGapChange: (Bool) -> Void = { _ in }

    private let pointsPerMinute: CGFloat = 1.6

    /// Drives the initial scroll-to-roughly-now on appear, and — while a
    /// segment's own empty-slot hold is active — scrolling the pressed
    /// time up toward the top. Shared across every segment since there's
    /// only one physical ScrollView.
    @State private var scrollPosition = ScrollPosition()
    /// The ScrollView's own viewport height, used to clamp how far a
    /// segment's `updateEmptySlot` can scroll the pressed time toward the
    /// top.
    @State private var viewportHeight: CGFloat = 0
    /// The ScrollView's current scroll offset — read continuously so a
    /// segment's own auto-scroll-while-dragging loop (see
    /// `DayTimelineSegment.startAutoScroll`) always knows where the
    /// visible viewport actually sits right now, not just how tall it is.
    @State private var scrollOffsetY: CGFloat = 0
    /// Measured heights of the variable-height sections stacked around
    /// the grid segment(s) — each segment needs to know how much content
    /// sits above its own ZStack to translate a grid-local touch/scroll
    /// position into the shared ScrollView's own content-space
    /// coordinates (see `DayTimelineSegment.precedingContentHeight`).
    @State private var twoMinuteSectionHeight: CGFloat = 0
    @State private var amSectionHeight: CGFloat = 0
    @State private var middaySectionHeight: CGFloat = 0
    /// One per possible segment — whichever's actually showing sets this
    /// true while it has its own drag or empty-slot hold in progress,
    /// which is what actually disables the single shared ScrollView (see
    /// `body`); the other(s) just stay false.
    @State private var isMorningInteracting = false
    @State private var isAfternoonInteracting = false
    @State private var isSingleInteracting = false
    /// One per possible segment, mirroring the `isXInteracting` trio above
    /// — whichever's actually showing reports whether it currently has a
    /// gap collapsed; `hasAnyCollapsedGap` (fed to `onCollapsedGapChange`)
    /// just ORs whichever of these are in play.
    @State private var morningHasCollapsedGap = false
    @State private var afternoonHasCollapsedGap = false
    @State private var singleHasCollapsedGap = false
    /// Bumped by `toggleHabitOccurrence` right after it mutates a
    /// `HabitLog` — a plain `@State` write always forces this view's
    /// `body` to re-run, which is what actually guarantees the tapped
    /// row's checkmark/fade/strikethrough shows up the instant you tap it
    /// rather than waiting on SwiftData's own change notification for a
    /// freshly-inserted (today's first occurrence toggled) or otherwise
    /// not-directly-`@Query`'d `HabitLog` to propagate.
    @State private var habitOccurrenceRefreshTick = 0
    @Environment(\.modelContext) private var modelContext

    private func minutesSinceMidnight(_ date: Date) -> Int {
        let startOfDay = Calendar.current.startOfDay(for: date)
        return Int(date.timeIntervalSince(startOfDay) / 60)
    }

    /// Only the hours actually relevant to this day are rendered/scrollable
    /// — derived from the day's own first and last items (blocks and
    /// calendar events alike, whatever's actually in `rows`), each edge
    /// rounded out to its own whole hour: the earliest item's start hour
    /// (minutes dropped, so 9:30 still starts the grid at 9, not 10), and
    /// the latest item's end hour rounded up (so 4:15 still reaches 5).
    /// At a minimum though, the grid always opens wide enough to show
    /// every enabled `EligibleHoursWindow`, and every enabled
    /// SchedulingRule across every shelf, that applies to this day's
    /// weekday — in full, even one with nothing on the calendar in it yet
    /// (a shelf's own 11am–6pm window, say) — otherwise an eligible-hours
    /// outline (drawn by `DayTimelineSegment`, "a drop target visible
    /// before you let go") would sit clipped at whatever edge the rows
    /// alone happened to stop at, and a shelf's own window wouldn't be
    /// visible at all until something actually landed in it. Rows can
    /// still widen the range further past either kind of window on
    /// either side; this only ever raises the floor, never lowers it.
    /// Falls back to the full day when there's nothing — no rows, no
    /// enabled windows or rules — to derive a range from.
    private var visibleHourRange: (start: Int, end: Int) {
        var startHour = 24
        var endHour = 0
        var hasBound = false

        for row in rows {
            hasBound = true
            startHour = min(startHour, minutesSinceMidnight(row.startTime) / 60)
            let endMinutes = minutesSinceMidnight(row.startTime) + row.durationMinutes
            endHour = max(endHour, Int(ceil(Double(endMinutes) / 60)))
        }

        let weekday = Calendar.current.component(.weekday, from: targetDate)
        for window in eligibleHoursWindows where window.isEnabled && window.daysOfWeek.contains(weekday) {
            hasBound = true
            startHour = min(startHour, window.startHour)
            endHour = max(endHour, window.endMinute > 0 ? window.endHour + 1 : window.endHour)
        }

        // Same "at a minimum, show the full window" treatment as Eligible
        // Hours above, but for every enabled SchedulingRule across every
        // shelf that applies to today — a shelf's own window (e.g. 11am–
        // 6pm) should still be visible on a day nothing's actually landed
        // in it yet, not just once something has.
        for rule in allShelves.flatMap({ $0.schedulingRules ?? [] })
        where rule.isEnabled && rule.namedSchedule != nil && rule.effectiveDaysOfWeek.contains(weekday) {
            hasBound = true
            startHour = min(startHour, rule.effectiveStartHour)
            endHour = max(endHour, rule.effectiveEndMinute > 0 ? rule.effectiveEndHour + 1 : rule.effectiveEndHour)
        }

        guard hasBound else { return (0, 24) }

        startHour = max(0, min(startHour, 23))
        endHour = max(startHour + 1, min(24, endHour))
        return (startHour, endHour)
    }

    /// `range` is in quarter-hour units (see `morningRange`) — the only
    /// range this is ever called with.
    private func dayHeight(for range: (start: Int, end: Int)) -> CGFloat {
        CGFloat(range.end - range.start) * 15 * pointsPerMinute
    }

    private struct OpenHabitOccurrence: Identifiable {
        let id: String
        let habit: Habit
        let index: Int
        /// So the row can show checked/faded/struck-through instead of
        /// disappearing the instant it's tapped — same as a Specific-Time
        /// habit's own calendar block, which stays visible (just faded)
        /// until Nightly Review actually sweeps it, rather than vanishing
        /// on tap.
        let isCompleted: Bool
    }

    /// Every occurrence today whose own `HabitOccurrenceTimeMode` is
    /// `mode` and isn't missed/excused — habits sorted by `sortOrder`,
    /// occurrences within a habit in index order. Includes an already-
    /// complete occurrence (see `isCompleted`) so it can still render,
    /// checked; only missed/excused ones (resolved a different way, with
    /// no toggle-back UI here) are actually left out.
    ///
    /// `Habit.log(on:)` linearly scans that habit's *entire* log
    /// history to find today's entry — this used to call it indirectly
    /// (via `occurrenceStatus(_:on:calendar:)`) once per occurrence
    /// index, redoing that same scan up to `timesPerDay` times over for
    /// one habit. Looked up once per habit instead, since every index
    /// below needs the exact same day's log — this is what actually
    /// made checking off several habits in a row feel laggy on a habit
    /// with a lot of history built up: every tap re-renders this (and
    /// its two sibling calls, for the other two modes) across *every*
    /// habit, not just the one tapped.
    private func openHabitOccurrences(mode: HabitOccurrenceTimeMode) -> [OpenHabitOccurrence] {
        let calendar = Calendar.current
        var result: [OpenHabitOccurrence] = []
        for habit in allHabits.sorted(by: { $0.sortOrder < $1.sortOrder }) where habit.isApplicable(on: targetDate, calendar: calendar) {
            let log = habit.log(on: targetDate, calendar: calendar)
            for index in 0..<max(habit.timesPerDay, 1) {
                guard habit.timeMode(for: index) == mode else { continue }
                let status = log?.occurrenceStatus(index) ?? .none
                guard status == .none || status == .complete else { continue }
                result.append(OpenHabitOccurrence(id: "\(habit.id).\(index)", habit: habit, index: index, isCompleted: status == .complete))
            }
        }
        return result
    }

    private var amOccurrences: [OpenHabitOccurrence] { openHabitOccurrences(mode: .am) }
    private var middayOccurrences: [OpenHabitOccurrence] { openHabitOccurrences(mode: .midday) }
    private var pmOccurrences: [OpenHabitOccurrence] { openHabitOccurrences(mode: .pm) }

    /// The same three lists as `amOccurrences`/`middayOccurrences`/
    /// `pmOccurrences` above, computed together exactly once — those three
    /// stay as-is for `scrollToRoughlyNow`'s occasional (`.onAppear`-only)
    /// use of `isSplitAtNoon`, but `body` used to call through them (and
    /// `isSplitAtNoon`, which calls `middayOccurrences` again internally)
    /// four separate times per body pass, redoing the same per-habit scan
    /// each time.
    private struct OpenHabitOccurrenceLists {
        let am: [OpenHabitOccurrence]
        let midday: [OpenHabitOccurrence]
        let pm: [OpenHabitOccurrence]
        /// Same rule as the standalone `isSplitAtNoon`: the day only
        /// splits when there's a Midday occurrence to show between the
        /// halves.
        var isSplitAtNoon: Bool { !midday.isEmpty }
    }

    private func computeOpenHabitOccurrenceLists() -> OpenHabitOccurrenceLists {
        OpenHabitOccurrenceLists(
            am: openHabitOccurrences(mode: .am),
            midday: openHabitOccurrences(mode: .midday),
            pm: openHabitOccurrences(mode: .pm)
        )
    }

    /// The calendar only actually splits in two when there's a Midday
    /// occurrence to show between the halves — a day with no Midday
    /// habits renders as the single continuous grid it always has.
    private var isSplitAtNoon: Bool { !middayOccurrences.isEmpty }

    /// Where the day actually splits for Midday habits, in minutes since
    /// midnight — noon by default, but pushed later to clear any row
    /// already in progress at that point (an 11am–12:45pm task, say)
    /// instead of cutting through it, since a row lands wholly in
    /// whichever half it *starts* in (see `morningRows`) and would
    /// otherwise render past the morning segment's own bottom edge,
    /// overlapping the Midday section below it. Iterates to a fixed
    /// point so a chain of back-to-back straddling rows (one pushes past
    /// noon, the next starts right where that one ends, and so on) all
    /// get cleared, not just the first. Rounded up to the nearest 15
    /// minutes at the end — the grid itself (`DayTimelineSegment`'s
    /// `quarterRange`) only ever renders/drags in 15-minute increments,
    /// so the split stays on that same grid rather than landing on some
    /// arbitrary minute a stray non-15-aligned event happened to end on.
    private var middaySplitMinutes: Int {
        var split = 12 * 60
        var changed = true
        while changed {
            changed = false
            for row in rows {
                let start = minutesSinceMidnight(row.startTime)
                let end = start + row.durationMinutes
                if start < split, end > split {
                    split = end
                    changed = true
                }
            }
        }
        let remainder = split % 15
        return remainder == 0 ? split : split + (15 - remainder)
    }

    /// `middaySplitMinutes` in 15-minute units — `DayTimelineSegment`'s
    /// `quarterRange` (and everything derived from it: `dayHeight`,
    /// gridlines, row placement) works in quarter-hours rather than whole
    /// hours specifically so a split like 12:45 renders exactly there
    /// instead of rounding out to the next full hour.
    private var middaySplitQuarter: Int { middaySplitMinutes / 15 }

    /// The one boundary `morningRange.end` and `afternoonRange.start`
    /// both use — computed exactly once so the two halves can never
    /// drift apart the way clamping each range independently against
    /// `visibleHourRange` used to risk: if the split landed right at
    /// `visibleHourRange`'s own end (nothing today past noon, say),
    /// `afternoonRange` clamping itself to "at least one quarter before
    /// the end" pulled its *start* a quarter-hour earlier than
    /// `morningRange`'s *end* ever moved, splitting the grid at two
    /// different times instead of one. Not clamped to `visibleHourRange`
    /// at all here — `morningRange`/`afternoonRange` below handle the
    /// degenerate "not enough room" case themselves, by extending their
    /// own *outer* edge outward instead of ever moving this shared one.
    private var middaySplitBoundaryQuarter: Int { middaySplitQuarter }

    /// At least one quarter-hour tall even in the degenerate case where
    /// the split lands at or before the visible range's own start (e.g.
    /// the whole day's own content starts right at noon but a Midday
    /// habit still needs a Morning section above it) — extends the
    /// *start* earlier rather than ever moving `middaySplitBoundaryQuarter`.
    /// In quarter-hour units, like every `*Range` a `DayTimelineSegment`
    /// is given.
    private var morningRange: (start: Int, end: Int) { morningRange(hourRange: visibleHourRange) }

    /// Same idea as `morningRange`, extending the *end* later instead —
    /// e.g. every item today is before noon but a Midday habit still
    /// needs its own section and grid below the morning one.
    private var afternoonRange: (start: Int, end: Int) { afternoonRange(hourRange: visibleHourRange) }

    /// `morningRange`/`afternoonRange` above, factored to take an
    /// already-computed `visibleHourRange` — `body` computes it once per
    /// pass and threads it through here, instead of each of these (plus
    /// the single-segment branch) recomputing it. `visibleHourRange`
    /// walks every row, every eligible-hours window, and every
    /// `SchedulingRule` across every shelf, so it was running six times
    /// per pass. The property forms above stay for `scrollToRoughlyNow`,
    /// which runs `.onAppear` only and can afford its own call.
    private func morningRange(hourRange: (start: Int, end: Int)) -> (start: Int, end: Int) {
        let startQuarter = hourRange.start * 4
        let end = middaySplitBoundaryQuarter
        return (start: min(startQuarter, end - 1), end: end)
    }

    private func afternoonRange(hourRange: (start: Int, end: Int)) -> (start: Int, end: Int) {
        let endQuarter = hourRange.end * 4
        let start = middaySplitBoundaryQuarter
        return (start: start, end: max(endQuarter, start + 1))
    }

    /// Split by each row's own start time against `middaySplitMinutes` —
    /// a row that straddles noon (an 11:30am–1pm event, say) lands
    /// wholly in whichever half it *starts* in rather than being split
    /// into two rendered pieces; rare enough in practice not to be worth
    /// the added complexity of an actual split render. Using the pushed-
    /// out split rather than noon itself is what keeps a *later* row
    /// (one starting between noon and the pushed-out split) out of the
    /// morning segment it'd otherwise wrongly qualify for.
    private var morningRows: [DayTimelineRow] {
        rows.filter { minutesSinceMidnight($0.startTime) < middaySplitMinutes }
    }

    private var afternoonRows: [DayTimelineRow] {
        rows.filter { minutesSinceMidnight($0.startTime) >= middaySplitMinutes }
    }

    @ViewBuilder
    var body: some View {
        let occurrenceLists = computeOpenHabitOccurrenceLists()
        let hourRange = visibleHourRange
        let morningQuarterRange = morningRange(hourRange: hourRange)
        let afternoonQuarterRange = afternoonRange(hourRange: hourRange)
        ScrollView {
            VStack(spacing: 0) {
                twoMinuteTasksSection
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { newValue in
                        twoMinuteSectionHeight = newValue
                    }
                habitOccurrenceSection(title: "Morning Habits", occurrences: occurrenceLists.am)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { newValue in
                        amSectionHeight = newValue
                    }

                if occurrenceLists.isSplitAtNoon {
                    DayTimelineSegment(
                        rows: morningRows,
                        quarterRange: morningQuarterRange,
                        eligibleHoursWindows: eligibleHoursWindows,
                        targetDate: targetDate,
                        lockedStore: lockedStore,
                        viewModel: viewModel,
                        isToday: isToday,
                        allTasks: allTasks,
                        allShelves: allShelves,
                        onSaveEvent: onSaveEvent,
                        onDeleteBlock: onDeleteBlock,
                        onPickReplacement: onPickReplacement,
                        precedingContentHeight: twoMinuteSectionHeight + amSectionHeight,
                        scrollPosition: $scrollPosition,
                        viewportHeight: viewportHeight,
                        scrollOffsetY: scrollOffsetY,
                        isInteracting: $isMorningInteracting,
                        isCollapsingEmptyPeriods: isCollapsingEmptyPeriods,
                        collapseResetToken: collapseResetToken,
                        hasCollapsedGap: $morningHasCollapsedGap
                    )

                    habitOccurrenceSection(title: "Midday Habits", occurrences: occurrenceLists.midday)
                        // Extra breathing room specifically here — sitting
                        // directly between the two grid segments, this one
                        // reads as squeezed against both without it, unlike
                        // Morning/Evening which only ever border the grid
                        // on one side.
                        .padding(.vertical, 14)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { newValue in
                            middaySectionHeight = newValue
                        }

                    DayTimelineSegment(
                        rows: afternoonRows,
                        quarterRange: afternoonQuarterRange,
                        eligibleHoursWindows: eligibleHoursWindows,
                        targetDate: targetDate,
                        lockedStore: lockedStore,
                        viewModel: viewModel,
                        isToday: isToday,
                        allTasks: allTasks,
                        allShelves: allShelves,
                        onSaveEvent: onSaveEvent,
                        onDeleteBlock: onDeleteBlock,
                        onPickReplacement: onPickReplacement,
                        precedingContentHeight: twoMinuteSectionHeight + amSectionHeight + dayHeight(for: morningQuarterRange) + middaySectionHeight,
                        scrollPosition: $scrollPosition,
                        viewportHeight: viewportHeight,
                        scrollOffsetY: scrollOffsetY,
                        isInteracting: $isAfternoonInteracting,
                        isCollapsingEmptyPeriods: isCollapsingEmptyPeriods,
                        collapseResetToken: collapseResetToken,
                        hasCollapsedGap: $afternoonHasCollapsedGap
                    )
                } else {
                    DayTimelineSegment(
                        rows: rows,
                        quarterRange: (start: hourRange.start * 4, end: hourRange.end * 4),
                        eligibleHoursWindows: eligibleHoursWindows,
                        targetDate: targetDate,
                        lockedStore: lockedStore,
                        viewModel: viewModel,
                        isToday: isToday,
                        allTasks: allTasks,
                        allShelves: allShelves,
                        onSaveEvent: onSaveEvent,
                        onDeleteBlock: onDeleteBlock,
                        onPickReplacement: onPickReplacement,
                        precedingContentHeight: twoMinuteSectionHeight + amSectionHeight,
                        scrollPosition: $scrollPosition,
                        viewportHeight: viewportHeight,
                        scrollOffsetY: scrollOffsetY,
                        isInteracting: $isSingleInteracting,
                        isCollapsingEmptyPeriods: isCollapsingEmptyPeriods,
                        collapseResetToken: collapseResetToken,
                        hasCollapsedGap: $singleHasCollapsedGap
                    )
                }

                habitOccurrenceSection(title: "Evening Habits", occurrences: occurrenceLists.pm)
                    .padding(.top, 14)
            }
        }
        // Every hour label sits offset 6pt *above* its own gridline (see
        // `DayTimelineSegment.hourGrid`) so the label straddles the line
        // the way a real calendar's does — invisible for every hour after
        // the first since there's scrollable content above to absorb the
        // overflow, but the very top label of each segment has nothing
        // above it, so without this its top few points get clipped by the
        // ScrollView's own bounds.
        .scrollClipDisabled()
        .scrollDisabled(isMorningInteracting || isAfternoonInteracting || isSingleInteracting)
        .onChange(of: morningHasCollapsedGap || afternoonHasCollapsedGap || singleHasCollapsedGap, initial: true) { _, newValue in
            onCollapsedGapChange(newValue)
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.containerSize.height
        } action: { _, newValue in
            viewportHeight = newValue
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y
        } action: { _, newValue in
            scrollOffsetY = newValue
        }
        .onAppear {
            scrollToRoughlyNow()
        }
    }

    /// Scrolls to roughly an hour before the earliest thing on the
    /// calendar today, same "roughly now" hint the single-grid version
    /// always gave — now also picking the right segment (and its own
    /// cumulative offset into the shared ScrollView) when the day's split
    /// for Midday habits (see `middaySplitQuarter`).
    private func scrollToRoughlyNow() {
        let calendar = Calendar.current
        let earliestHour = rows.map { calendar.component(.hour, from: $0.startTime) }.min() ?? 7
        let whole = visibleHourRange
        let targetHour = max(whole.start, earliestHour - 1)
        let targetQuarter = targetHour * 4
        let headerHeight = twoMinuteSectionHeight + amSectionHeight
        if isSplitAtNoon, targetQuarter >= middaySplitQuarter {
            let offset = headerHeight + dayHeight(for: morningRange) + middaySectionHeight
                + CGFloat(targetQuarter - afternoonRange.start) * 15 * pointsPerMinute
            scrollPosition.scrollTo(y: offset)
        } else {
            let range = isSplitAtNoon ? morningRange : (start: whole.start * 4, end: whole.end * 4)
            let offset = headerHeight + CGFloat(targetQuarter - range.start) * 15 * pointsPerMinute
            scrollPosition.scrollTo(y: offset)
        }
    }

    /// The 2-Minute Task shelf's tasks, shown as a plain checklist above
    /// the grid rather than as calendar blocks — see
    /// `AISchedulingService`'s doc comment on why these never get a
    /// start/end time. Lives inside this ScrollView's own content (see
    /// `body`) so it scrolls away with the rest of the day instead of
    /// staying pinned above it, and uses a fully opaque background — a
    /// translucent tint here read as washed-out against the grid's own
    /// hairline gridlines right below it. A task whose `startDate` hasn't
    /// arrived yet (see `TaskItem.isEligibleToStart`) stays off this list
    /// entirely, the same as it stays off the calendar. Tapping a row
    /// toggles completion right here, live (no separate sheet) — a
    /// completed one stays visible, faded and struck through, rather than
    /// disappearing, so it reads the same as a completed calendar block.
    @ViewBuilder
    private var twoMinuteTasksSection: some View {
        if let shelf = allShelves.first(where: { $0.isTwoMinuteTasks }) {
            let visible = (shelf.tasks ?? [])
                .filter { $0.isEligibleToStart(on: targetDate) }
                .sorted { $0.createdAt < $1.createdAt }
            if !visible.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 5) {
                        Image(systemName: shelf.systemImage)
                            .font(.caption)
                        Text(shelf.name)
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)

                    VStack(spacing: 6) {
                        ForEach(visible) { task in
                            Button {
                                task.setCompleted(!task.isCompleted, in: modelContext)
                            } label: {
                                HStack(spacing: 10) {
                                    // Same checkmark-circle look
                                    // `DayTimelineSegment.completeCircle`
                                    // uses for a calendar block.
                                    ZStack {
                                        Circle()
                                            .fill(task.isCompleted ? Color.green : Color.clear)
                                            .overlay(Circle().strokeBorder(task.isCompleted ? Color.green : Color.secondary.opacity(0.7), lineWidth: 1.5))
                                        if task.isCompleted {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 8, weight: .bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    .frame(width: 15, height: 15)
                                    Text(task.title)
                                        .foregroundStyle(.primary)
                                        .strikethrough(task.isCompleted)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .opacity(task.isCompleted ? 0.5 : 1)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(shelf.flattenedColor(opacity: 0.3))
                .padding(.bottom, 10)
            }
        }
    }

    /// One of the Morning/Midday/Evening lists — every still-open habit
    /// occurrence whose `HabitOccurrenceTimeMode` puts it in this section,
    /// as a plain check-off row (no calendar time at all). Same visual
    /// shape as `twoMinuteTasksSection` — a neutral background here since
    /// a habit has no shelf color of its own — but a checked row stays
    /// visible (checkmark filled, name faded/struck through), same as a
    /// Specific-Time habit's own calendar block, rather than disappearing
    /// the instant it's tapped.
    @ViewBuilder
    private func habitOccurrenceSection(title: String, occurrences: [OpenHabitOccurrence]) -> some View {
        if !occurrences.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                VStack(spacing: 12) {
                    ForEach(occurrences) { occurrence in
                        Button {
                            toggleHabitOccurrence(habit: occurrence.habit, index: occurrence.index, isCompleted: occurrence.isCompleted)
                        } label: {
                            HStack(spacing: 10) {
                                // Same checkmark-circle look
                                // `DayTimelineSegment.completeCircle` uses
                                // for a calendar block, so a habit reads
                                // the same way whether it's timed or not.
                                ZStack {
                                    Circle()
                                        .fill(occurrence.isCompleted ? Color.green : Color.clear)
                                        .overlay(Circle().strokeBorder(occurrence.isCompleted ? Color.green : Color.secondary.opacity(0.7), lineWidth: 1.5))
                                    if occurrence.isCompleted {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                                .frame(width: 15, height: 15)
                                // Same title font a Specific-Time habit's
                                // own calendar block uses (see
                                // `DayTimelineSegment.blockContent`), so an
                                // AM/Midday/PM occurrence reads as the same
                                // kind of thing, just without a time.
                                Text(occurrence.habit.name)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .strikethrough(occurrence.isCompleted)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .opacity(occurrence.isCompleted ? 0.5 : 1)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Same tint a habit's own calendar block uses — `Color
            // .accentColor.opacity(0.35)` — flattened to a solid color
            // the same way `twoMinuteTasksSection` is, so it reads as
            // opaque rather than washed-out.
            .background(Shelf.flatten(.accentColor, opacity: 0.35))
            .padding(.bottom, 10)
        }
    }

    /// Mirrors `HabitsView.toggleOccurrence`'s completion side (both
    /// directions — checking and un-checking) — an AM/Midday/PM
    /// occurrence never has a `ScheduledBlock` to keep in sync (see
    /// `AISchedulingService.placeHabitsAndRecurringTasks`), so there's
    /// nothing here beyond the log itself.
    private func toggleHabitOccurrence(habit: Habit, index: Int, isCompleted: Bool) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: targetDate)
        let log = habit.log(on: today, calendar: calendar) ?? {
            let newLog = HabitLog(habit: habit, date: today)
            modelContext.insert(newLog)
            return newLog
        }()
        log.setOccurrence(index, to: isCompleted ? .none : .complete)
        habitOccurrenceRefreshTick += 1
        HabitStatsRefreshCoordinator.shared.habitLogsChanged()
    }
}

/// The actual hour-gridline-and-blocks timeline for one contiguous hour
/// range — either the whole day, or one half of it split at noon by a
/// Midday habit occurrence (see `DayTimelineGridView`). Every drag/swipe/
/// tap gesture and its own sheets (event edit, task card, divisible
/// adjust, habit detail, empty-slot candidates, block actions) live here,
/// entirely self-contained per instance — two segments on screen at once
/// never share or interfere with each other's interaction state, only the
/// single ScrollView they both sit inside (see `scrollPosition`/
/// `viewportHeight`/`isInteracting`, all owned by the parent and threaded
/// in here).
private struct DayTimelineSegment: View {
    let rows: [DayTimelineRow]
    /// Explicit rather than derived — the parent decides whether this is
    /// the whole day or one half of a Midday split. Quarter-hour units
    /// (15 minutes each), not whole hours — a Midday split lands wherever
    /// the day's own content needs it to (12:45, say — see
    /// `DayTimelineGridView.middaySplitQuarter`), not just on the hour.
    let quarterRange: (start: Int, end: Int)
    let eligibleHoursWindows: [EligibleHoursWindow]
    let targetDate: Date
    let lockedStore: LockedEventsStore
    let viewModel: ScheduleReviewViewModel
    let isToday: Bool
    let allTasks: [TaskItem]
    let allShelves: [Shelf]
    let onSaveEvent: (CalendarEventSummary) -> Void
    let onDeleteBlock: (ScheduledBlock) -> Void
    let onPickReplacement: (ScheduledBlock) -> Void
    /// How much content sits above this segment's own ZStack inside the
    /// shared ScrollView — the parent's running total of every section
    /// (and, for the second segment of a split day, the first segment's
    /// own height too) stacked above it. Needed to translate this
    /// segment's grid-local touch/scroll math into the ScrollView's own
    /// content-space coordinates, the same reasoning
    /// `twoMinuteSectionHeight` originally existed for.
    let precedingContentHeight: CGFloat
    @Binding var scrollPosition: ScrollPosition
    let viewportHeight: CGFloat
    /// The shared ScrollView's current scroll offset — see
    /// `startAutoScroll`.
    let scrollOffsetY: CGFloat
    /// Set true while this segment has its own drag or empty-slot hold in
    /// progress — the parent disables the single shared ScrollView based
    /// on this (see `DayTimelineGridView.body`).
    @Binding var isInteracting: Bool
    /// When on, a stretch of `quarterRange` with nothing in it (and
    /// nothing within `collapseBufferQuarters` of it) collapses down to a
    /// single compact divider instead of rendering every empty
    /// quarter-hour at full height — see `displaySegments`. Dragging a
    /// block and long-press-to-insert are disabled whenever
    /// `hasAnyGapSegment` is true (see `dragGesture`/`emptySlotGesture`),
    /// since only then does the compacted space lack an inverse
    /// (pixel → time) mapping — this flag alone isn't enough to gate on,
    /// since it can stay on with every individual gap manually expanded
    /// back to nothing actually collapsed (see `manuallyExpandedGapKeys`).
    let isCollapsingEmptyPeriods: Bool
    /// Bumped by the parent to force `manuallyExpandedGapKeys` back to
    /// empty — see `DayTimelineGridView.collapseResetToken`.
    let collapseResetToken: Int
    /// Kept in sync with `hasAnyGapSegment` — see
    /// `DayTimelineGridView.onCollapsedGapChange`.
    @Binding var hasCollapsedGap: Bool

    private let pointsPerMinute: CGFloat = 1.6
    private let hourLabelWidth: CGFloat = 52
    /// Below this rendered height, a block's title-above-time layout
    /// doesn't fit both lines without clipping — see `blockContent`.
    private let compactBlockHeightThreshold: CGFloat = 34
    private let contentTrailingPadding: CGFloat = 12
    /// Both the live drag preview and the final committed drop use this —
    /// dragging visibly steps between 15-minute slots instead of floating
    /// freely, so it reads as "snapping into a timeslot" rather than a
    /// smooth, arbitrary-time drag.
    private let snapMinutes: Int = 15
    /// How far left a proposed block has to be swiped, in points, before
    /// releasing removes it from the schedule instead of springing back.
    private let swipeDeleteThreshold: CGFloat = -80
    /// How far right a block has to be dragged, in points, before dropping
    /// it onto another entry means "put these side by side" instead of the
    /// default "push that one down" — see `dragGesture`/`commitDrop`.
    private let sideBySideDragThreshold: CGFloat = 40

    @State private var draggingRowID: String?
    @State private var dragTranslation: CGFloat = 0
    /// The live drag point's grid-local Y, updated on every
    /// `dragGesture` change — read by the auto-scroll loop (see
    /// `startAutoScroll`) to know how close the finger is to the visible
    /// viewport's top/bottom edge right now, independent of whether the
    /// finger itself is still moving.
    @State private var dragPointY: CGFloat?
    /// The running loop that nudges `scrollPosition` while `dragPointY`
    /// sits within an edge zone of the viewport — started when a block
    /// drag begins, stopped the moment it ends or cancels. A `Task`
    /// rather than a `Timer` since it only ever needs to run while this
    /// view (and the drag) is alive, and cancellation is automatic.
    @State private var autoScrollTask: Task<Void, Never>?
    /// The touch's Y at the moment its `LongPressDragGesture` began (i.e.
    /// once the hold threshold was met) — `dragTranslation` is measured
    /// relative to this, since the underlying `UILongPressGestureRecognizer`
    /// reports absolute location, not a translation the way SwiftUI's own
    /// `DragGesture` does.
    @State private var dragOriginY: CGFloat?
    /// Same idea as `dragOriginY`/`dragTranslation`, but horizontal and
    /// unsnapped — purely a "how far right has this been dragged" signal
    /// for `commitDrop` to decide side-by-side vs. push-down, plus a bit of
    /// live visual feedback (the card actually slides with the finger).
    @State private var dragOriginX: CGFloat?
    @State private var dragTranslationX: CGFloat = 0
    /// The proposed block currently being swiped left to remove from the
    /// schedule — `swipeTranslationX` is its live horizontal offset (always
    /// `<= 0`; the row snaps back to `0` if released short of the delete
    /// threshold, or animates fully off-screen and calls `onDeleteBlock` if
    /// released past it).
    @State private var swipingRowID: String?
    @State private var swipeTranslationX: CGFloat = 0
    @State private var editingEvent: CalendarEventSummary?
    @State private var actionsTargetBlock: ScheduledBlock?
    /// Tapping a habit's block goes straight to its own detail screen
    /// (streaks, rolling stats, calendar) rather than the tap-menu a task
    /// block gets — a habit isn't a schedule-only concept the way a task
    /// block is, so it makes more sense to land you where the rest of its
    /// history lives.
    @State private var habitDetailTarget: Habit?
    /// "See Task Card" from a proposed block's tap menu.
    @State private var taskCardTarget: TaskItem?
    /// "Adjust Scheduled Time" from a divisible task's tap menu.
    @State private var divisibleAdjustTarget: ScheduledBlock?
    /// Set once a long-press on an open slot succeeds — presents the
    /// full-screen candidates sheet (see the `.sheet` in `body`) and
    /// supplies the time it'll insert at.
    @State private var emptySlotTime: Date?
    /// True only while the empty-slot hold has actually succeeded and the
    /// finger's still down — combined with `draggingRowID`, controls when
    /// the shared ScrollView is disabled (via `isInteracting`).
    @State private var isEmptySlotArmed = false
    /// Raw gap keys (see `DisplaySegment.gapKey`) that have been manually
    /// expanded by tapping their collapsed divider — checked in
    /// `displaySegments` so only that specific gap stays expanded, not
    /// every gap on the day.
    @State private var manuallyExpandedGapKeys = Set<Int>()

    private var visibleStartMinutes: Int { quarterRange.start * 15 }

    /// One contiguous run of `quarterRange`, either rendered at its real
    /// size (`isGap == false`) or collapsed to `compactGapHeight`
    /// (`isGap == true`) — see `displaySegments`.
    private struct DisplaySegment {
        let startQuarter: Int
        /// Exclusive.
        let endQuarter: Int
        let isGap: Bool
        /// How much free time this segment's divider labels, in minutes.
        /// For a collapsed gap this is the *raw* stretch of free time
        /// (before `collapseBufferQuarters` trims a sliver off each edge
        /// into its own always-visible segment) — otherwise a 1-hour raw
        /// gap flanked by events on both sides would only ever show
        /// "30m free" once the buffer's been carved out of it.
        let rawGapMinutes: Int
        /// Identifies the underlying raw gap this segment came from
        /// (its un-buffered start quarter) — tapping a collapsed divider
        /// records this key in `manuallyExpandedGapKeys` so *only* that
        /// gap expands, not every gap on the day.
        let gapKey: Int
        var quarterCount: Int { endQuarter - startQuarter }
    }

    /// How many quarter-hours of real content get kept expanded right at
    /// the edge of a collapsed gap, so a block never reads as jammed
    /// directly against the divider. Kept small relative to
    /// `minCollapsibleGapQuarters` — a big buffer on both edges of an
    /// exactly-one-hour gap would eat the whole thing and leave nothing
    /// left to actually collapse.
    private static let collapseBufferQuarters = 1
    /// A gap has to be at least this long (its raw length, before the
    /// buffer above trims its edges) to bother collapsing — "compact any
    /// free slot of an hour or more."
    private static let minCollapsibleGapQuarters = 4
    private static let compactGapHeight: CGFloat = 40

    /// `quarterRange` broken into alternating populated/gap runs when
    /// `isCollapsingEmptyPeriods` is on — a single run covering the whole
    /// range otherwise. This (and `heightForSegment`/`displayOffset(forMinutes:)`,
    /// both derived from it) is the one model both `hourGrid`'s rendering
    /// and every row's own position are built from, so the two can never
    /// disagree about where a gap actually is.
    private var displaySegments: [DisplaySegment] {
        guard isCollapsingEmptyPeriods else {
            return [DisplaySegment(startQuarter: quarterRange.start, endQuarter: quarterRange.end, isGap: false, rawGapMinutes: 0, gapKey: quarterRange.start)]
        }
        var populated = Set<Int>()
        for row in rows {
            let startQuarter = minutesSinceMidnight(row.startTime) / 15
            let endQuarter = Int(ceil(Double(minutesSinceMidnight(row.startTime) + row.durationMinutes) / 15))
            for quarter in startQuarter..<max(startQuarter + 1, endQuarter) {
                populated.insert(quarter)
            }
        }
        guard !populated.isEmpty else {
            let rawLength = quarterRange.end - quarterRange.start
            let isGap = rawLength >= Self.minCollapsibleGapQuarters && !manuallyExpandedGapKeys.contains(quarterRange.start)
            return [DisplaySegment(startQuarter: quarterRange.start, endQuarter: quarterRange.end, isGap: isGap, rawGapMinutes: rawLength * 15, gapKey: quarterRange.start)]
        }
        var segments: [DisplaySegment] = []
        var cursor = quarterRange.start
        while cursor < quarterRange.end {
            if populated.contains(cursor) {
                var end = cursor + 1
                while end < quarterRange.end, populated.contains(end) {
                    end += 1
                }
                segments.append(DisplaySegment(startQuarter: cursor, endQuarter: end, isGap: false, rawGapMinutes: 0, gapKey: cursor))
                cursor = end
                continue
            }
            var end = cursor + 1
            while end < quarterRange.end, !populated.contains(end) {
                end += 1
            }
            // Raw free run is [cursor, end). `end`'s own quarter is
            // populated whenever end < quarterRange.end (the inner loop
            // above only stops early for that reason) — same logic for
            // whether a populated quarter precedes `cursor`.
            let hasLeadingNeighbor = cursor > quarterRange.start
            let hasTrailingNeighbor = end < quarterRange.end
            let rawLength = end - cursor
            let gapKey = cursor
            if rawLength >= Self.minCollapsibleGapQuarters, !manuallyExpandedGapKeys.contains(gapKey) {
                let bufferStart = hasLeadingNeighbor ? min(cursor + Self.collapseBufferQuarters, end) : cursor
                let bufferEnd = hasTrailingNeighbor ? max(end - Self.collapseBufferQuarters, bufferStart) : end
                if bufferStart > cursor {
                    segments.append(DisplaySegment(startQuarter: cursor, endQuarter: bufferStart, isGap: false, rawGapMinutes: 0, gapKey: gapKey))
                }
                segments.append(DisplaySegment(startQuarter: bufferStart, endQuarter: bufferEnd, isGap: true, rawGapMinutes: rawLength * 15, gapKey: gapKey))
                if bufferEnd < end {
                    segments.append(DisplaySegment(startQuarter: bufferEnd, endQuarter: end, isGap: false, rawGapMinutes: 0, gapKey: gapKey))
                }
            } else {
                segments.append(DisplaySegment(startQuarter: cursor, endQuarter: end, isGap: false, rawGapMinutes: rawLength * 15, gapKey: gapKey))
            }
            cursor = end
        }
        return segments
    }

    private func heightForSegment(_ segment: DisplaySegment) -> CGFloat {
        segment.isGap ? Self.compactGapHeight : CGFloat(segment.quarterCount) * 15 * pointsPerMinute
    }

    private var dayHeight: CGFloat {
        displaySegments.reduce(0) { $0 + heightForSegment($1) }
    }

    /// Whether this segment currently has at least one gap actually shown
    /// collapsed — false once every one of its gaps has been manually
    /// expanded away (or there were never any long enough to collapse in
    /// the first place). Fed up to `hasCollapsedGap`.
    private var hasAnyGapSegment: Bool {
        displaySegments.contains(where: \.isGap)
    }

    /// The collapsed gap segment (if any) currently rendered at grid-local
    /// `y` — used to auto-expand whichever gap a block gets dragged onto,
    /// so dragging works everywhere instead of being blocked outright by
    /// `hasAnyGapSegment` any time a collapsed gap exists anywhere on the
    /// day.
    private func gapSegment(atY y: CGFloat) -> DisplaySegment? {
        var offset: CGFloat = 0
        for segment in displaySegments {
            let height = heightForSegment(segment)
            if y < offset + height {
                return segment.isGap ? segment : nil
            }
            offset += height
        }
        return nil
    }

    /// Maps a real minute-of-day to its Y offset in the (possibly
    /// collapsed) rendered timeline — what every row's own `baseOffset`
    /// is actually built from. A minute inside a collapsed gap can't
    /// happen in practice (a gap is by definition empty of rows), but
    /// clamps to that gap's own top edge rather than guessing if it ever
    /// did.
    private func displayOffset(forMinutes minutes: Int) -> CGFloat {
        guard isCollapsingEmptyPeriods else {
            return CGFloat(minutes - visibleStartMinutes) * pointsPerMinute
        }
        var offset: CGFloat = 0
        for segment in displaySegments {
            let segmentEndMinutes = segment.endQuarter * 15
            if minutes < segmentEndMinutes {
                guard !segment.isGap else { return offset }
                let segmentStartMinutes = segment.startQuarter * 15
                return offset + CGFloat(minutes - segmentStartMinutes) * pointsPerMinute
            }
            offset += heightForSegment(segment)
        }
        return offset
    }

    /// Side-by-side layout for genuinely overlapping rows (a habit and an
    /// event at the same time, two back-to-back-but-not-quite blocks,
    /// etc.) — every `DayTimelineRow`, whatever it is, gets a column index
    /// and the total column count of whichever cluster of mutually-
    /// overlapping rows it belongs to, so nothing ever draws directly on
    /// top of something else. Two rows that merely touch (one ends
    /// exactly when the next starts) are *not* overlapping — they still
    /// each get the full width, same as the zero-gap rendering elsewhere
    /// in this view already assumes.
    ///
    /// Standard calendar-layout algorithm: walk rows sorted by start time,
    /// grouping any whose start falls before the running max end-time of
    /// the cluster so far (so A and C both cluster with B even if A and C
    /// don't directly overlap each other); within each cluster, greedily
    /// place each row in the first column whose previous occupant has
    /// already ended, opening a new column only when nothing already open
    /// is free yet — the cluster's column *count* is then applied to
    /// every row in it, not just the ones actively colliding pairwise.
    private var columnAssignments: [String: (column: Int, count: Int)] {
        let sorted = rows.sorted { $0.startTime < $1.startTime }
        var result: [String: (column: Int, count: Int)] = [:]
        var cluster: [DayTimelineRow] = []
        var clusterEnd = Date.distantPast

        func flushCluster() {
            guard !cluster.isEmpty else { return }
            var columnEndTimes: [Date] = []
            for row in cluster {
                let column = columnEndTimes.firstIndex(where: { $0 <= row.startTime }) ?? columnEndTimes.count
                if column == columnEndTimes.count {
                    columnEndTimes.append(row.endTime)
                } else {
                    columnEndTimes[column] = row.endTime
                }
                result[row.id] = (column: column, count: 0) // count filled in below
            }
            let count = columnEndTimes.count
            for row in cluster {
                result[row.id]?.count = count
            }
            cluster = []
        }

        for row in sorted {
            if cluster.isEmpty || row.startTime < clusterEnd {
                cluster.append(row)
                clusterEnd = max(clusterEnd, row.endTime)
            } else {
                flushCluster()
                cluster = [row]
                clusterEnd = row.endTime
            }
        }
        flushCluster()
        return result
    }

    /// A hairline of breathing room trimmed off the bottom of a row that's
    /// capped by another one starting right where it ends (see
    /// `maxRowHeight`) — otherwise two back-to-back blocks would render
    /// edge-to-edge with no visible separation between their cards.
    private let adjacentRowGap: CGFloat = 3

    /// How tall `row` is allowed to render before it would visually reach
    /// into a block that starts at or after `row`'s own real end time —
    /// i.e. the room between `row.startTime` and the next such block's
    /// start, minus `adjacentRowGap`, in points. `.infinity` when nothing
    /// follows it that closely (the 24pt readability floor in `rowView`
    /// then applies unopposed). A concurrent block that starts *during*
    /// `row` (handled instead by `columnAssignments`, side by side) is
    /// deliberately not a candidate here — only ones starting at/after
    /// `row.endTime` are.
    private func maxRowHeight(for row: DayTimelineRow) -> CGFloat {
        guard let nextStart = rows
            .filter({ $0.id != row.id && $0.startTime >= row.endTime })
            .map(\.startTime)
            .min()
        else { return .infinity }
        let minutes = minutesSinceMidnight(nextStart) - minutesSinceMidnight(row.startTime)
        return CGFloat(minutes) * pointsPerMinute - adjacentRowGap
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            hourGrid
            eligibleHoursOverlay
            // Drawn before the rows, so a press on an actual block or
            // event hits that row's own gesture first — this only ever
            // fires for genuinely open space.
            // Long-press-to-insert needs an inverse (pixel → time)
            // mapping this view deliberately doesn't build for the
            // collapsed timeline — see `isCollapsingEmptyPeriods`. Gated
            // on `hasAnyGapSegment`, not the raw toggle: once every gap's
            // been manually expanded away, the mapping is 1:1 again even
            // though `isCollapsingEmptyPeriods` itself is still on, and
            // gating on the toggle alone left this permanently disabled
            // in that state with nothing on screen to explain why.
            if !hasAnyGapSegment {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .gesture(emptySlotGesture)
            }
            ForEach(rows) { row in
                rowView(for: row)
            }
        }
        .frame(height: dayHeight)
        .padding(.trailing, contentTrailingPadding)
        .onChange(of: draggingRowID) { _, newValue in
            isInteracting = (newValue != nil) || isEmptySlotArmed
        }
        // Manually-expanded gaps otherwise stick around forever — once a
        // gap's key is in `manuallyExpandedGapKeys` nothing normally clears
        // it, so re-collapsing the whole day and turning collapsing back
        // on would leave that one gap permanently stuck open, reading as
        // if the toolbar toggle had stopped working for it. Turning
        // collapsing off is the natural "reset" moment — everything's
        // already fully expanded at that point anyway.
        .onChange(of: isCollapsingEmptyPeriods) { _, newValue in
            if !newValue {
                manuallyExpandedGapKeys.removeAll()
            }
        }
        // Bumped specifically for the case above's counterpart: every gap
        // manually expanded away while `isCollapsingEmptyPeriods` stayed
        // on the whole time, so there's no `false` transition to piggyback
        // a reset on — the toolbar button bumps this token instead.
        .onChange(of: collapseResetToken) { _, _ in
            manuallyExpandedGapKeys.removeAll()
        }
        .onChange(of: hasAnyGapSegment, initial: true) { _, newValue in
            hasCollapsedGap = newValue
        }
        .onChange(of: isEmptySlotArmed) { _, newValue in
            isInteracting = newValue || (draggingRowID != nil)
        }
        .sheet(item: $editingEvent) { event in
            EventEditSheet(
                event: event,
                isLocked: lockedStore.isLocked(event.id),
                onToggleLock: { lockedStore.toggle(event.id) },
                onSave: { updated in
                    onSaveEvent(updated)
                    editingEvent = nil
                }
            )
        }
        .sheet(item: $taskCardTarget) { task in
            TaskCardSheet(task: task, shelves: allShelves.filter { !$0.isKitchen })
        }
        .sheet(item: $divisibleAdjustTarget) { block in
            DivisibleAdjustSheet(block: block)
        }
        .sheet(item: $habitDetailTarget) { habit in
            NavigationStack {
                HabitDetailView(habit: habit)
                    .toolbar {
                        // HabitDetailView normally relies on a NavigationStack's
                        // own back chevron (it's usually pushed, not
                        // presented) — this sheet gets a fresh stack with no
                        // history, so it needs its own explicit way to close.
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { habitDetailTarget = nil }
                        }
                    }
            }
        }
        .sheet(isPresented: Binding(
            get: { emptySlotTime != nil },
            set: { if !$0 { emptySlotTime = nil } }
        )) {
            if let emptySlotTime {
                EmptySlotPickerSheet(
                    time: emptySlotTime,
                    candidates: viewModel.replacementCandidates(from: allTasks, for: .freeSlot(startTime: emptySlotTime, includingInbox: true)),
                    onPick: { task in
                        viewModel.insertBlock(for: task, startTime: emptySlotTime)
                        self.emptySlotTime = nil
                    }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        }
        .confirmationDialog(
            actionsTargetBlock?.displayTitle ?? "",
            isPresented: Binding(get: { actionsTargetBlock != nil }, set: { if !$0 { actionsTargetBlock = nil } }),
            titleVisibility: .visible
        ) {
            if let block = actionsTargetBlock {
                blockActionButtons(for: block)
            }
        }
    }

    /// See `LongPressDragGesture.swift` for why this is a real UIKit
    /// gesture recognizer rather than a SwiftUI `Gesture` composition.
    private var emptySlotGesture: LongPressDragGesture {
        LongPressDragGesture(
            minimumDuration: 0.3,
            onBegan: { point in
                isEmptySlotArmed = true
                updateEmptySlot(at: point.y, animated: true)
            },
            onChanged: { point in
                updateEmptySlot(at: point.y, animated: false)
            },
            onEnded: { _ in
                isEmptySlotArmed = false
            },
            onCancelled: {
                isEmptySlotArmed = false
            }
        )
    }

    /// Snaps a pressed content-space `y` to the nearest 15-minute slot and,
    /// if it's genuinely open, sets `emptySlotTime` — which presents the
    /// half-height candidates sheet (see `body`) — and scrolls that time to
    /// the midpoint of the calendar's still-visible top half (a quarter of
    /// the way down the full screen, since the sheet covers the bottom
    /// half).
    private func updateEmptySlot(at y: CGFloat, animated: Bool) {
        let minutes = y / pointsPerMinute + CGFloat(visibleStartMinutes)
        let startOfDay = Calendar.current.startOfDay(for: targetDate)
        let rawTime = startOfDay.addingTimeInterval(Double(minutes) * 60)
        let snapped = snappedTime(rawTime)
        let occupied = rows.contains { snapped >= $0.startTime && snapped < $0.endTime }
        guard !occupied else { return }
        emptySlotTime = snapped
        // `y` itself is grid-local (the gesture lives inside this
        // segment's own ZStack, untouched by whatever's stacked above it)
        // but `scrollPosition.scrollTo` works in the shared ScrollView's
        // own content space, which starts `precedingContentHeight` earlier
        // — see that property's doc comment.
        let maxOffset = max(0, precedingContentHeight + dayHeight - viewportHeight)
        let target = min(max(0, precedingContentHeight + y - viewportHeight / 4), maxOffset)
        if animated {
            withAnimation(.easeOut(duration: 0.25)) {
                scrollPosition.scrollTo(y: target)
            }
        } else {
            scrollPosition.scrollTo(y: target)
        }
    }

    @ViewBuilder
    private func blockActionButtons(for block: ScheduledBlock) -> some View {
        if let task = block.task {
            Button("See Task Card") { taskCardTarget = task }
            if task.isDivisible {
                Button("Adjust Scheduled Time") { divisibleAdjustTarget = block }
            }
            Button("Replace Task") { onPickReplacement(block) }
        }
        Button("Delete", role: .destructive) { onDeleteBlock(block) }
        Button("Cancel", role: .cancel) {}
    }

    /// One row per quarter-hour in `quarterRange` — a whole-hour boundary
    /// (`quarter % 4 == 0`) gets the bold "7 PM"-style label, the other
    /// three get a lighter ":15"/":30"/":45". Every rendered row labels
    /// its own top edge — without something more, the *bottom* edge of
    /// the very last row goes unlabeled, so a range padded to end at 8pm
    /// visually reads as stopping at 7:45 (the last label you actually
    /// see), even though the row itself does reach 8pm. The trailing
    /// label below closes that off: one more label+gridline pinned to
    /// `quarterRange.end`'s boundary, positioned but not sized into
    /// `dayHeight` (a pure anchor, not a new content row) — this is also
    /// what lets a Midday split land on a quarter-hour like 12:45 instead
    /// of only ever a whole hour: `quarterRange.end` needn't be a
    /// multiple of 4.
    private var hourGrid: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(Array(displaySegments.enumerated()), id: \.offset) { _, segment in
                    if segment.isGap {
                        collapsedGapRow(segment)
                            .frame(height: Self.compactGapHeight, alignment: .center)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(segment.startQuarter..<segment.endQuarter, id: \.self) { quarter in
                                gridLine(forQuarter: quarter)
                                    .frame(height: 15 * pointsPerMinute, alignment: .top)
                                    .id(quarter)
                            }
                        }
                    }
                }
            }
            gridLine(forQuarter: quarterRange.end)
                .offset(y: dayHeight)
        }
    }

    /// The compact divider shown in place of a collapsed empty stretch —
    /// tapping it expands just that one gap (recorded in
    /// `manuallyExpandedGapKeys` by `gapKey`), leaving every other
    /// collapsed gap on the day untouched.
    private func collapsedGapRow(_ segment: DisplaySegment) -> some View {
        Button {
            manuallyExpandedGapKeys.insert(segment.gapKey)
        } label: {
            HStack(spacing: 6) {
                Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 1)
                Text(freeTimeLabel(forMinutes: segment.rawGapMinutes))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, hourLabelWidth + 8)
        .padding(.trailing, contentTrailingPadding)
    }

    private func freeTimeLabel(forMinutes minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        if hours > 0, mins > 0 { return "\(hours)h \(mins)m free" }
        if hours > 0 { return "\(hours)h free" }
        return "\(mins)m free"
    }

    /// One label+gridline for a given quarter-hour boundary — bold and
    /// hour-labeled ("7 PM") on the hour itself, lighter and minute-
    /// labeled (":15") otherwise. Shared by `hourGrid`'s per-row loop and
    /// its own trailing boundary line so the two never drift out of sync.
    private func gridLine(forQuarter quarter: Int) -> some View {
        let isWholeHour = quarter % 4 == 0
        return HStack(alignment: .top, spacing: 8) {
            Group {
                if isWholeHour {
                    Text(hourLabel(quarter / 4))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text(":\((quarter % 4) * 15)")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary.opacity(0.6))
                }
            }
            .frame(width: hourLabelWidth, alignment: .trailing)
            .offset(y: isWholeHour ? -6 : -4)
            Rectangle()
                .fill(Color.secondary.opacity(isWholeHour ? 0.15 : 0.08))
                .frame(height: 1)
                .offset(y: -0.5)
        }
    }

    /// Enabled windows that apply to `targetDate`'s weekday, outlined so a
    /// drag has a visible target before you let go — hidden while any gap
    /// is actually shown collapsed, since dragging is disabled then
    /// anyway (see `hasAnyGapSegment`) and a window spanning a collapsed
    /// gap has no single real position to draw it at.
    @ViewBuilder
    private var eligibleHoursOverlay: some View {
        if !hasAnyGapSegment {
        let weekday = Calendar.current.component(.weekday, from: targetDate)
        ForEach(eligibleHoursWindows.filter { $0.isEnabled && $0.daysOfWeek.contains(weekday) }) { window in
            let startMinutes = window.startHour * 60 + window.startMinute
            let endMinutes = window.endHour * 60 + window.endMinute
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                )
                .frame(height: CGFloat(max(0, endMinutes - startMinutes)) * pointsPerMinute)
                .frame(maxWidth: .infinity)
                .padding(.leading, hourLabelWidth + 8)
                .padding(.trailing, 4)
                .offset(y: CGFloat(startMinutes - visibleStartMinutes) * pointsPerMinute)
                .allowsHitTesting(false)
        }
        }
    }

    @ViewBuilder
    private func rowView(for row: DayTimelineRow) -> some View {
        // The 24pt floor below keeps very short blocks readable, but
        // without a ceiling it would render past this row's own real end
        // time — visibly overlapping a block that starts right where this
        // one actually ends (e.g. one ends at 7am, the next starts at
        // 7am). Capping to the next block's start closes that gap.
        let naturalHeight = max(24, CGFloat(row.durationMinutes) * pointsPerMinute)
        let heightPts: CGFloat = max(10, min(naturalHeight, maxRowHeight(for: row)))
        let isLocked = isLockedRow(row)
        let isDragging = draggingRowID == row.id
        let isSwiping = swipingRowID == row.id
        let swipeX = isSwiping ? min(0, swipeTranslationX) : 0
        let baseOffset: CGFloat = displayOffset(forMinutes: minutesSinceMidnight(row.startTime))

        // What the in-progress drag (if any) would actually do to *this*
        // row if released right now — the pushed-down (default) or
        // paired-up-side-by-side (rightward drag) preview, purely visual
        // until the drag actually ends; see `liveDragPreview`.
        let preview = liveDragPreview
        let previewOffset = previewPushOffset(for: row, preview: preview)
        let liveOffset: CGFloat = baseOffset + (isDragging ? dragTranslation : 0) + previewOffset
        let shadowOpacity: Double = isDragging ? 0.2 : 0
        // Genuinely overlapping rows (a habit and an event at the same
        // time, say) split the width between them instead of drawing on
        // top of each other — see `columnAssignments`. A row that doesn't
        // overlap anything gets column 0 of 1, i.e. its full usual width.
        // A live side-by-side preview temporarily overrides this for the
        // dragged row and its target, so the eventual split is visible
        // before the drop is ever actually committed.
        let layout = previewLayout(for: row, preview: preview)

        GeometryReader { geo in
            let columnGap: CGFloat = layout.count > 1 ? 4 : 0
            let colWidth = max((geo.size.width - columnGap * CGFloat(layout.count - 1)) / CGFloat(max(layout.count, 1)), 0)
            let colOffset = CGFloat(layout.column) * (colWidth + columnGap)

            ZStack(alignment: .trailing) {
                if isSwiping && swipeX < -1 {
                    swipeDeleteBackground(height: heightPts)
                }

                // The card body keeps showing its real, still-saved time
                // while dragging — only the floating label above it
                // previews the drop target — and updates to the new time
                // itself once the drop actually commits (`row.startTime`
                // changing is what does that).
                blockContent(for: row, isLocked: isLocked, height: heightPts)
                    .overlay(alignment: .top) {
                        if isDragging {
                            dragTimeLabel(for: row)
                                .offset(y: -24)
                        }
                    }
                    .zIndex(isDragging ? 1 : 0)
                    .shadow(color: .black.opacity(shadowOpacity), radius: 6, y: 3)
                    .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.8), value: isDragging)
            }
            .frame(width: colWidth, alignment: .trailing)
            // Only the rightward half of the horizontal drag is shown —
            // that's the direction with a meaning ("put these side by
            // side," see `commitDrop`), so this is the affordance that
            // tells you you've dragged far enough for it to register.
            .offset(x: colOffset + swipeX + (isDragging ? max(0, dragTranslationX) : 0))
        }
        .frame(height: heightPts)
        .padding(.leading, hourLabelWidth + 8)
        .padding(.trailing, 4)
        .offset(y: liveOffset)
        // Smooths another row's preview reacting to the drag (pushed down,
        // or resized into a side-by-side half) — the dragged row itself
        // already tracks the finger 1:1 every frame, so it's excluded here
        // to avoid lagging behind the touch.
        .animation(isDragging ? nil : .interactiveSpring(response: 0.3, dampingFraction: 0.8), value: previewOffset)
        .animation(isDragging ? nil : .interactiveSpring(response: 0.3, dampingFraction: 0.8), value: layout.count)
        // Each gesture's own `isEnabled: !isLocked` (not a conditional
        // `.gesture(...)` attachment) is what actually disables the
        // underlying `UILongPressGestureRecognizer`/pan recognizer,
        // removing it from this row's touch path entirely rather than
        // leaving it attached-but-inert. That matters specifically for a
        // habit row's own `completeCircle`/lock-icon taps (see their
        // `.highPriorityGesture` comments): even with
        // `shouldRecognizeSimultaneouslyWith` unconditionally `true`, a
        // still-*attached* `LongPressDragGesture` was enough to make
        // those nested taps visibly wait before registering. A
        // permanently-locked-as-habit row never needs either of these at
        // all (see `isLockedRow`) — "the only thing you can do with a
        // habit on the calendar is mark it complete" — so disabling them
        // outright is both the correct behavior and what actually made
        // the checkmark feel instant again.
        .gesture(dragGesture(for: row, isLocked: isLocked))
        .gesture(swipeGesture(for: row))
        .onTapGesture { handleTap(on: row) }
    }

    /// Revealed behind a proposed block as it's swiped left — a trash icon
    /// on a red background, matching the block's own height so it never
    /// peeks out top or bottom.
    private func swipeDeleteBackground(height: CGFloat) -> some View {
        HStack {
            Spacer()
            Image(systemName: "trash.fill")
                .foregroundStyle(.white)
                .padding(.trailing, 14)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 8).fill(.red))
    }

    /// Floats above the dragged card showing where it'll actually land —
    /// the card body itself stays on the original time until the drop
    /// commits.
    private func dragTimeLabel(for row: DayTimelineRow) -> some View {
        let start = draggedStart(for: row)
        let end = start.addingTimeInterval(TimeInterval(row.durationMinutes * 60))
        return Text(timeRangeText(start, end))
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.accentColor))
    }

    private func handleTap(on row: DayTimelineRow) {
        switch row {
        case .event(let event):
            editingEvent = event
        case .proposed(let block):
            if let habit = block.habit {
                habitDetailTarget = habit
            } else {
                actionsTargetBlock = block
            }
        }
    }

    /// Three pure-SwiftUI `Gesture` compositions were tried and rejected
    /// before this — a bare `DragGesture`, `LongPressGesture.sequenced
    /// (before: DragGesture(minimumDistance: 0))`, and independently-
    /// masked arm/track gestures — each either fought the ScrollView's own
    /// pan (blocking scroll outright) or broke touch continuity (needing
    /// the finger lifted and pressed again between the hold and the drag).
    /// This is a documented, hard SwiftUI limitation: the `Gesture`
    /// protocol has no way to tell the system "recognize alongside the
    /// ScrollView's pan," but real `UIGestureRecognizerDelegate` does — see
    /// `LongPressDragGesture.swift`, which wraps an actual
    /// `UILongPressGestureRecognizer` and unconditionally returns `true`
    /// from `shouldRecognizeSimultaneouslyWith`.
    private func dragGesture(for row: DayTimelineRow, isLocked: Bool) -> LongPressDragGesture {
        LongPressDragGesture(
            // Shorter than the empty-slot version (0.3s) — blocks cover
            // most of a busy day, so this is the far more common target.
            minimumDuration: 0.22,
            isEnabled: !isLocked,
            onBegan: { point in
                // Also blocked while the empty-slot candidates card is
                // open, or this row is already mid-swipe — otherwise you
                // could pick up an unrelated block right out from under
                // it, or start a vertical move partway through a delete
                // swipe. Dragging into a collapsed gap is fine — see
                // `gapSegment(atY:)` in `onChanged` below, which expands
                // one the moment the drag actually reaches it.
                guard !isLocked, emptySlotTime == nil, swipingRowID == nil else { return }
                draggingRowID = row.id
                dragOriginY = point.y
                dragOriginX = point.x
                dragPointY = point.y
                startAutoScroll()
            },
            onChanged: { point in
                guard draggingRowID == row.id, let dragOriginY, let dragOriginX else { return }
                dragTranslation = snappedTranslation(point.y - dragOriginY, for: row)
                dragTranslationX = point.x - dragOriginX
                dragPointY = point.y
                if let gap = gapSegment(atY: point.y) {
                    manuallyExpandedGapKeys.insert(gap.gapKey)
                }
            },
            onEnded: { _ in
                guard draggingRowID == row.id else { return }
                // Reuses the already-snapped live value rather than
                // re-deriving from the raw point, so the committed time
                // exactly matches what was last shown. A meaningful
                // rightward drag means "put these side by side" instead of
                // the default "push the other one down."
                commitDrop(of: row, newStart: draggedStart(for: row), preferSideBySide: dragTranslationX > sideBySideDragThreshold)
                draggingRowID = nil
                dragTranslation = 0
                dragOriginY = nil
                dragTranslationX = 0
                dragOriginX = nil
                stopAutoScroll()
            },
            onCancelled: {
                guard draggingRowID == row.id else { return }
                draggingRowID = nil
                dragTranslation = 0
                dragOriginY = nil
                dragTranslationX = 0
                dragOriginX = nil
                stopAutoScroll()
            }
        )
    }

    /// Nudges `scrollPosition` on a ~60fps loop for as long as
    /// `dragPointY` sits within `edgeZone` points of the visible
    /// viewport's top or bottom edge — the closer to the edge, the faster
    /// it scrolls, capped at `maxSpeed` points/tick right at the edge
    /// itself. Runs independent of finger movement (a `LongPressDragGesture`
    /// only calls `onChanged` when the touch actually moves), which is
    /// what lets holding still right at the edge keep scrolling instead of
    /// stalling. Programmatic `scrollPosition.scrollTo` calls go through
    /// fine even though the shared ScrollView is `.scrollDisabled` for the
    /// whole duration of a drag (see `DayTimelineGridView.body`) — only
    /// user-driven scrolling is blocked, and `updateEmptySlot` already
    /// relies on that same fact.
    private func startAutoScroll() {
        autoScrollTask?.cancel()
        // Captured into locals before the `Task` starts rather than read
        // as `self.foo` from inside its loop — `self` is a struct, and the
        // closure below keeps whatever copy of it existed the moment this
        // method ran for the entire lifetime of the drag, since nothing
        // ever re-creates the `Task` on a later re-render the way a
        // gesture's own synchronous callbacks get rebound each time.
        // `currentOffset` tracks our own progress locally rather than
        // re-reading `scrollOffsetY` for the same reason — this loop is
        // the only thing moving the scroll position during a drag (the
        // ScrollView itself is `.scrollDisabled`), so it's the only
        // source of truth that actually needs to stay live.
        let edgeZone: CGFloat = 70
        let maxSpeed: CGFloat = 14
        let preceding = precedingContentHeight
        let viewport = viewportHeight
        let maxOffset = max(0, precedingContentHeight + dayHeight - viewportHeight)
        var currentOffset = scrollOffsetY
        autoScrollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 16_000_000)
                guard !Task.isCancelled, let pointY = dragPointY else { continue }
                let contentY = preceding + pointY
                let distanceFromTop = contentY - currentOffset
                let distanceFromBottom = (currentOffset + viewport) - contentY
                var delta: CGFloat = 0
                if distanceFromTop < edgeZone {
                    delta = -maxSpeed * (edgeZone - max(0, distanceFromTop)) / edgeZone
                } else if distanceFromBottom < edgeZone {
                    delta = maxSpeed * (edgeZone - max(0, distanceFromBottom)) / edgeZone
                }
                guard delta != 0 else { continue }
                let newOffset = min(max(0, currentOffset + delta), maxOffset)
                guard newOffset != currentOffset else { continue }
                currentOffset = newOffset
                scrollPosition.scrollTo(y: newOffset)
            }
        }
    }

    private func stopAutoScroll() {
        autoScrollTask?.cancel()
        autoScrollTask = nil
        dragPointY = nil
    }

    /// Swipe-left-to-remove for a proposed block — ignored entirely for
    /// calendar events, for a locked block (locking protects it from this
    /// the same way it protects it from being dragged or reflowed — see
    /// `isLockedRow`, which a habit block always counts as too: the only
    /// thing you can do with one on the calendar is mark it complete),
    /// and for movement that isn't horizontally dominant (so it never
    /// fights a vertical scroll; see `PanSwipeGesture`'s doc comment).
    /// Past `swipeDeleteThreshold`, releasing removes the block from the
    /// schedule via `onDeleteBlock` — the same "unschedule, leave the slot
    /// open" action already reachable from the tap menu's Delete button,
    /// just reachable directly by swiping now.
    private func swipeGesture(for row: DayTimelineRow) -> PanSwipeGesture {
        PanSwipeGesture(
            isEnabled: !isLockedRow(row),
            onChanged: { translation in
                guard case .proposed = row, !isLockedRow(row), draggingRowID == nil, emptySlotTime == nil else { return }
                guard abs(translation.x) > abs(translation.y), translation.x < 0 else {
                    if swipingRowID == row.id {
                        swipingRowID = nil
                        swipeTranslationX = 0
                    }
                    return
                }
                swipingRowID = row.id
                swipeTranslationX = translation.x
            },
            onEnded: { translation in
                guard case .proposed(let block) = row, swipingRowID == row.id else { return }
                if translation.x < swipeDeleteThreshold {
                    commitSwipeDelete(of: block)
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        swipeTranslationX = 0
                    }
                    swipingRowID = nil
                }
            },
            onCancelled: {
                guard swipingRowID == row.id else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    swipeTranslationX = 0
                }
                swipingRowID = nil
            }
        )
    }

    /// Slides the block the rest of the way off-screen, then hands off to
    /// `onDeleteBlock` once that animation's had time to actually play —
    /// `rows` updating (removing this one) happens on the caller's side,
    /// so committing immediately would cut the slide-away short.
    private func commitSwipeDelete(of block: ScheduledBlock) {
        withAnimation(.easeIn(duration: 0.2)) {
            swipeTranslationX = -500
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            onDeleteBlock(block)
            swipingRowID = nil
            swipeTranslationX = 0
        }
    }

    /// Snaps to the dragged row's new *absolute* clock time (nearest
    /// `snapMinutes` mark, e.g. :00/:15/:30/:45) rather than just rounding
    /// the raw pixel delta — otherwise a block that started at an
    /// off-grid time (9:07, say, from an imported calendar event) would
    /// only ever drag to other off-grid times 15 minutes apart (9:07,
    /// 9:22, ...) instead of landing on the grid itself.
    private func snappedTranslation(_ raw: CGFloat, for row: DayTimelineRow) -> CGFloat {
        let rawMinutes = Double(raw / pointsPerMinute)
        let candidateStart = row.startTime.addingTimeInterval(rawMinutes * 60)
        let snappedStart = snappedTime(candidateStart)
        let snappedMinutes = snappedStart.timeIntervalSince(row.startTime) / 60
        return CGFloat(snappedMinutes) * pointsPerMinute
    }

    /// Rounds an absolute time to the nearest `snapMinutes` — used for a
    /// tap on an open slot, where there's no existing time to offset from.
    private func snappedTime(_ date: Date) -> Date {
        let startOfDay = Calendar.current.startOfDay(for: date)
        let minutes = date.timeIntervalSince(startOfDay) / 60
        let snappedMinutes = (minutes / Double(snapMinutes)).rounded() * Double(snapMinutes)
        return startOfDay.addingTimeInterval(snappedMinutes * 60)
    }

    /// `row.startTime` shifted by the current live (already-snapped) drag
    /// translation — what this row's start time would be if dropped right
    /// now.
    private func draggedStart(for row: DayTimelineRow) -> Date {
        let minutes = Double(dragTranslation / pointsPerMinute)
        return row.startTime.addingTimeInterval(minutes * 60)
    }

    /// Hands off to `ScheduleReviewViewModel.moveEntry`, which pins the
    /// dragged entry at `newStart` and only shifts genuinely-overlapping
    /// unlocked neighbors — everything else keeps its exact time, so
    /// dropping back into a gap you didn't actually change looks like
    /// nothing happened, rather than silently repacking the whole day.
    /// `preferSideBySide` (a meaningful rightward drag at release — see
    /// `dragGesture`) changes what happens to whichever unlocked entry the
    /// drop time actually conflicts with: normally it's rippled out of the
    /// way (pushed later); side-by-side instead pins just that one entry
    /// in place, so the two end up genuinely overlapping in time and
    /// `columnAssignments` renders them split side by side, same as any
    /// other pair of naturally-concurrent entries.
    private func commitDrop(of draggedRow: DayTimelineRow, newStart: Date, preferSideBySide: Bool) {
        // `moveEntry` already keeps unlocked entries from overlapping each
        // other (it ripples them out of the way), but a locked event can't
        // be shifted the same way — without this, dropping directly onto
        // one would just sit on top of it.
        let adjustedStart = clampedStart(
            newStart,
            duration: TimeInterval(draggedRow.durationMinutes * 60),
            excluding: draggedRow.id
        )

        let draggedRef: ScheduleReviewViewModel.TimelineEntryRef
        switch draggedRow {
        case .event(let event): draggedRef = .event(event.id)
        case .proposed(let block): draggedRef = .block(block.id)
        }
        var unlockedOrder: [ScheduleReviewViewModel.TimelineEntryRef] = rows.compactMap { entry in
            switch entry {
            case .event(let event):
                return lockedStore.isLocked(event.id) ? nil : .event(event.id)
            case .proposed(let block):
                return block.isLocked ? nil : .block(block.id)
            }
        }
        if preferSideBySide,
           let target = conflictingRow(for: draggedRow, at: adjustedStart) {
            let targetRef: ScheduleReviewViewModel.TimelineEntryRef
            switch target {
            case .event(let event): targetRef = .event(event.id)
            case .proposed(let block): targetRef = .block(block.id)
            }
            unlockedOrder.removeAll { $0 == targetRef }
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            viewModel.moveEntry(draggedRef, to: adjustedStart, among: unlockedOrder)
        }
    }

    /// If dropping at `start` (for `duration` seconds) would overlap a
    /// locked event, nudges it to whichever edge of that conflict —
    /// finishing just as it starts, or starting just as it ends — is
    /// closer to where it was actually dropped, rather than letting it
    /// land on top. Only checks the first conflict found; two locked
    /// events packed back-to-back with no gap between them is an edge case
    /// this doesn't fully resolve, but that's rare in practice.
    private func clampedStart(_ start: Date, duration: TimeInterval, excluding rowID: String) -> Date {
        let end = start.addingTimeInterval(duration)
        guard let conflict = rows.first(where: { row in
            row.id != rowID && isLockedRow(row) && start < row.endTime && end > row.startTime
        }) else {
            return start
        }
        let beforeStart = conflict.startTime.addingTimeInterval(-duration)
        let afterStart = conflict.endTime
        let distanceBefore = abs(start.timeIntervalSince(beforeStart))
        let distanceAfter = abs(start.timeIntervalSince(afterStart))
        return distanceBefore <= distanceAfter ? beforeStart : afterStart
    }

    /// The first unlocked row (other than `draggedRow` itself) that would
    /// genuinely overlap a drop at `start` — the thing that either gets
    /// pushed later (the default) or paired up side by side with it. Used
    /// both to actually commit the drop and, live, to preview it.
    private func conflictingRow(for draggedRow: DayTimelineRow, at start: Date) -> DayTimelineRow? {
        let end = start.addingTimeInterval(TimeInterval(draggedRow.durationMinutes * 60))
        return rows.first { other in
            other.id != draggedRow.id && !isLockedRow(other) && start < other.endTime && end > other.startTime
        }
    }

    /// While a drag is in progress, what it would actually do if released
    /// right now — purely derived from the live drag state, so every row
    /// can preview the outcome (the target sliding down or left) without
    /// any of it being committed until `commitDrop` actually runs.
    private var liveDragPreview: (targetID: String, isSideBySide: Bool)? {
        guard let draggingRowID, let draggedRow = rows.first(where: { $0.id == draggingRowID }) else { return nil }
        guard let target = conflictingRow(for: draggedRow, at: draggedStart(for: draggedRow)) else { return nil }
        return (target.id, dragTranslationX > sideBySideDragThreshold)
    }

    /// How far down `row` should preview-shift to stay clear of the
    /// dragged block's current live position — 0 unless `row` is the
    /// live-preview push-down target. A plain (non-`@ViewBuilder`) helper
    /// so the `if`/`guard` chain here doesn't get mistaken for view
    /// content by `rowView`'s own builder context.
    private func previewPushOffset(for row: DayTimelineRow, preview: (targetID: String, isSideBySide: Bool)?) -> CGFloat {
        guard preview?.targetID == row.id, preview?.isSideBySide == false,
              let draggingRowID, let draggedRow = rows.first(where: { $0.id == draggingRowID }) else { return 0 }
        let draggedLiveEnd = draggedStart(for: draggedRow).addingTimeInterval(TimeInterval(draggedRow.durationMinutes * 60))
        guard draggedLiveEnd > row.startTime else { return 0 }
        return CGFloat(minutesSinceMidnight(draggedLiveEnd) - minutesSinceMidnight(row.startTime)) * pointsPerMinute
    }

    /// `row`'s column layout, live-overridden to preview a side-by-side
    /// split (dragged row on the right, its target on the left) while a
    /// rightward drag hovers over that target — otherwise just its normal
    /// `columnAssignments` slot.
    private func previewLayout(for row: DayTimelineRow, preview: (targetID: String, isSideBySide: Bool)?) -> (column: Int, count: Int) {
        if preview?.targetID == row.id, preview?.isSideBySide == true {
            return (column: 0, count: 2)
        }
        if draggingRowID == row.id, preview?.isSideBySide == true {
            return (column: 1, count: 2)
        }
        return columnAssignments[row.id] ?? (column: 0, count: 1)
    }

    /// A habit-linked block counts as locked here regardless of its own
    /// `isLocked` flag — the only thing you can do with a habit on the
    /// calendar is mark it complete (see `completeCircle`/`handleTap`),
    /// so it should never be draggable itself, nor rippled out of the
    /// way by some *other* block's drag landing on its slot (this same
    /// flag is what both `dragGesture`'s onBegan guard and
    /// `clampedStart`/`conflictingRow`'s ripple logic key off of).
    private func isLockedRow(_ row: DayTimelineRow) -> Bool {
        switch row {
        case .event(let event):
            return lockedStore.isLocked(event.id)
        case .proposed(let block):
            return block.isLocked || block.habit != nil
        }
    }

    /// `height` is applied here, before the background fill, so the
    /// colored rectangle actually reaches the full slot height instead of
    /// only wrapping its (usually shorter) text content — otherwise two
    /// back-to-back blocks with no real gap between their times would
    /// still show a visible gap between their backgrounds.
    @ViewBuilder
    private func blockContent(for row: DayTimelineRow, isLocked: Bool, height: CGFloat) -> some View {
        // Below this, the title-above-time stack doesn't fit two lines
        // without clipping — switch to title-beside-time on one line
        // instead of letting the bottom line get cut off.
        let isCompact = height < compactBlockHeightThreshold
        switch row {
        case .event(let event):
            Group {
                if isCompact {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(event.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text(timeRangeText(event.start, event.end))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(2)
                        Text(timeRangeText(event.start, event.end))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: isCompact ? .leading : .topLeading)
            .frame(height: height, alignment: isCompact ? .center : .top)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.22)))
            .overlay(alignment: .topTrailing) {
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .padding(5)
                }
            }
        case .proposed(let block):
            Group {
                // "(Est Duration)" flags a guessed duration (the task
                // itself never had one set — see
                // `ScheduledBlock.isEstimatedDuration`) so it reads as an
                // estimate, not a real commitment. Dropped in the compact
                // one-line layout — there's no room for it there anyway.
                if isCompact {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(block.displayTitle)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .strikethrough(block.isCompleted)
                        Text(timeRangeText(block.startTime, block.endTime))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(block.displayTitle)
                            .font(.caption.weight(.semibold))
                            .lineLimit(2)
                            .strikethrough(block.isCompleted)
                        (Text(timeRangeText(block.startTime, block.endTime))
                            + Text(block.isEstimatedDuration ? " (Est Duration)" : "").italic())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: isCompact ? .leading : .topLeading)
            .frame(height: height, alignment: isCompact ? .center : .top)
            .background(RoundedRectangle(cornerRadius: 8).fill((block.task?.shelf?.color ?? Color.accentColor).opacity(0.35)))
            // Same shelf color, just faded — a completed block reads as
            // "done" at a glance without needing to check the icon.
            // Locking no longer fades it (only the lock icon itself turns
            // green to show the state). The icon overlay below is outside
            // this `.opacity`, so it stays fully legible regardless.
            .opacity(block.isCompleted ? 0.5 : 1)
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 8) {
                    // Same circle style as `OverdueBlocksReviewList`'s
                    // selection circle — tapping it toggles `isCompleted`
                    // directly (no separate confirm step needed here, one
                    // task at a time rather than a batch).
                    completeCircle(for: block)
                    // Always visible for a task block (unlike the
                    // calendar-event lock icon above, which only shows
                    // once locked) so there's always something to tap —
                    // locking a task protects it from being pushed around
                    // by another block's drag (`isLockedRow`/
                    // `unlockedOrder`) and from being cleared by
                    // "Regenerate Schedule" (`regenerateFromNow`). Green
                    // (same as the complete checkmark) once locked, so the
                    // two states read the same way at a glance. Omitted
                    // entirely for a habit block — that's already always
                    // treated as locked (see `isLockedRow`), so a toggle
                    // here would just be a dead control that can't
                    // actually be turned off: the only thing you can do
                    // with a habit on the calendar is mark it complete.
                    if block.task != nil {
                        Image(systemName: block.isLocked ? "lock.fill" : "lock.open")
                            .font(.caption2)
                            .foregroundStyle(block.isLocked ? Color.green : Color.secondary.opacity(0.7))
                            .padding(5)
                            .contentShape(Rectangle())
                            // `.highPriorityGesture`, not `.onTapGesture` —
                            // see `completeCircle`'s matching comment just
                            // below.
                            .highPriorityGesture(
                                TapGesture().onEnded {
                                    block.isLocked.toggle()
                                }
                            )
                    }
                }
                .padding(2)
            }
        }
    }

    /// Empty outline when incomplete, green fill + white checkmark when
    /// complete — same look as `OverdueBlocksReviewList`'s selection
    /// circle, just sized for the card and wired straight to `isCompleted`
    /// instead of a batch selection.
    private func completeCircle(for block: ScheduledBlock) -> some View {
        ZStack {
            Circle()
                .fill(block.isCompleted ? Color.green : Color.clear)
                .overlay(Circle().strokeBorder(block.isCompleted ? Color.green : Color.secondary.opacity(0.7), lineWidth: 1.5))
            if block.isCompleted {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 15, height: 15)
        .padding(5)
        .contentShape(Rectangle())
        // `rowView` attaches `dragGesture(for:isLocked:)` — a real
        // `minimumDuration: 0.22` `LongPressDragGesture` — to the whole
        // row this circle sits inside. A plain `.onTapGesture` here loses
        // to that ancestor `.gesture(...)` by SwiftUI's default priority
        // rules, so the tap has to wait for the long-press to actually
        // fail (up to the full 0.22s) before it's even allowed to
        // register — `.highPriorityGesture` is what makes this circle's
        // own tap win immediately instead, which is what actually fixed
        // the felt delay tapping a habit complete on the calendar. A
        // genuine long-press-and-drag still works exactly as before: it
        // never satisfies a `TapGesture`'s own release-within-a-beat
        // criteria in the first place, so there's nothing for this to
        // preempt.
        .highPriorityGesture(
            TapGesture().onEnded {
                // Routed through the view model rather than toggling
                // `isCompleted` directly — a habit-backed block needs its
                // Habit Tracker log kept in sync too (see
                // `ScheduleReviewViewModel.toggleComplete`).
                viewModel.toggleComplete(block)
            }
        )
    }

    private func minutesSinceMidnight(_ date: Date) -> Int {
        let startOfDay = Calendar.current.startOfDay(for: date)
        return Int(date.timeIntervalSince(startOfDay) / 60)
    }

    private func hourLabel(_ hour: Int) -> String {
        let date = Calendar.current.date(from: DateComponents(hour: hour)) ?? .now
        let formatter = DateFormatter()
        formatter.dateFormat = "h a"
        return formatter.string(from: date)
    }

    private func timeRangeText(_ start: Date, _ end: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return "\(formatter.string(from: start)) \u{2013} \(formatter.string(from: end))"
    }

}

/// Reached by "Adjust Scheduled Time" on a divisible task's block — shrinks
/// just this block, handing the freed time back to the task itself (see
/// `save()`) rather than deleting anything, so the rest still shows up as
/// unscheduled and eligible to be picked up again by a future generate.
private struct DivisibleAdjustSheet: View {
    let block: ScheduledBlock

    @Environment(\.dismiss) private var dismiss
    @State private var minutes: Int

    init(block: ScheduledBlock) {
        self.block = block
        _minutes = State(initialValue: block.durationMinutes)
    }

    /// Counts down from the full scheduled duration in steps of the
    /// task's own divisible segment size — e.g. a 2 hour block divisible
    /// into 30 minute parts offers 2h, 1h30m, 1h, 30m, matching how much
    /// of it can actually be peeled off and handed back as unscheduled.
    private var options: [Int] {
        let step = max(block.task?.minimumSegmentMinutes ?? 5, 5)
        var values: [Int] = []
        var remaining = block.durationMinutes
        while remaining >= step {
            values.append(remaining)
            remaining -= step
        }
        return values.isEmpty ? [block.durationMinutes] : values
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Duration", selection: $minutes) {
                        ForEach(options, id: \.self) { option in
                            Text(TaskItem.durationLabel(for: option)).tag(option)
                        }
                    }
                    .pickerStyle(.wheel)
                    .labelsHidden()
                } footer: {
                    Text("Shortens this block on the calendar. The time you take off goes back onto \(block.displayTitle) as still unscheduled, ready to be picked up again by a future generate.")
                }
            }
            .navigationTitle("Adjust Scheduled Time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
        }
    }

    private func save() {
        let freedMinutes = block.durationMinutes - minutes
        if freedMinutes > 0, let task = block.task {
            task.estimatedMinutes += freedMinutes
            task.isScheduled = false
        }
        block.endTime = block.startTime.addingTimeInterval(TimeInterval(minutes * 60))
        dismiss()
    }
}

/// Reached by tapping a calendar event on the grid — edit title/time/notes,
/// or toggle locked (locked events can't be dragged and are excluded from
/// the reflow when other entries move).
private struct EventEditSheet: View {
    let event: CalendarEventSummary
    let isLocked: Bool
    let onToggleLock: () -> Void
    let onSave: (CalendarEventSummary) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var start: Date
    @State private var end: Date
    @State private var notes: String

    init(event: CalendarEventSummary, isLocked: Bool, onToggleLock: @escaping () -> Void, onSave: @escaping (CalendarEventSummary) -> Void) {
        self.event = event
        self.isLocked = isLocked
        self.onToggleLock = onToggleLock
        self.onSave = onSave
        _title = State(initialValue: event.title)
        _start = State(initialValue: event.start)
        _end = State(initialValue: event.end)
        _notes = State(initialValue: event.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Title", text: $title)
                }
                Section("Time") {
                    DatePicker("Start", selection: $start, displayedComponents: [.date, .hourAndMinute])
                    DatePicker("End", selection: $end, displayedComponents: [.date, .hourAndMinute])
                }
                Section("Details") {
                    TextField("Notes", text: $notes, axis: .vertical)
                }
            }
            .navigationTitle("Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onToggleLock) {
                        Image(systemName: isLocked ? "lock.fill" : "lock.open")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Save", action: save)
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        onSave(CalendarEventSummary(id: event.id, title: title, start: start, end: end, notes: notes.isEmpty ? nil : notes))
    }
}

/// Reached by long-pressing an open slot on the grid — a full-screen list
/// of unscheduled to-dos to drop in right there, grouped by shelf (due-date
/// first within each) with Inbox last.
private struct EmptySlotPickerSheet: View {
    let time: Date
    let candidates: [TaskItem]
    let onPick: (TaskItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var isAddingNewTask = false
    @State private var newTaskTitle = ""
    @FocusState private var isNewTaskTitleFocused: Bool

    private struct ShelfGroup: Identifiable {
        let id: String
        let title: String
        let tasks: [TaskItem]
        let color: Color
    }

    /// One group per shelf (sorted by the shelf's own `sortOrder`, tasks
    /// within it due-date-first then no-due-date), with a final "Inbox"
    /// group for tasks that aren't on any shelf. Each group carries its
    /// shelf's color, same as the blocks on the grid itself use to tint
    /// their background — Inbox gets a neutral gray since it has none.
    private var groups: [ShelfGroup] {
        let byShelf = Dictionary(grouping: candidates) { $0.shelf?.id }
        func dueDateFirst(_ lhs: TaskItem, _ rhs: TaskItem) -> Bool {
            switch (lhs.dueDate, rhs.dueDate) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return false
            }
        }
        let shelfGroups = byShelf.values
            .compactMap { tasks -> ShelfGroup? in
                guard let shelf = tasks.first?.shelf else { return nil }
                return ShelfGroup(id: shelf.id.uuidString, title: shelf.name, tasks: tasks.sorted(by: dueDateFirst), color: shelf.color)
            }
            .sorted { ($0.tasks.first?.shelf?.sortOrder ?? 0) < ($1.tasks.first?.shelf?.sortOrder ?? 0) }
        let inboxTasks = (byShelf[nil] ?? []).sorted(by: dueDateFirst)
        return inboxTasks.isEmpty ? shelfGroups : shelfGroups + [ShelfGroup(id: "inbox", title: "Inbox", tasks: inboxTasks, color: .secondary)]
    }

    private var timeText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: time)
    }

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                    ContentUnavailableView("Nothing to Schedule", systemImage: "tray", description: Text("No unscheduled to-dos available."))
                } else {
                    List {
                        ForEach(groups) { group in
                            Section {
                                ForEach(group.tasks) { task in
                                    Button {
                                        onPick(task)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(task.title)
                                                .font(.body.weight(.medium))
                                                .foregroundStyle(.primary)
                                            Text("\(task.durationLabel) \u{00B7} \(task.priority.label)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 2)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .listRowBackground(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(group.color.opacity(0.15))
                                            .padding(.vertical, 2)
                                    )
                                    .listRowSeparator(.hidden)
                                }
                            } header: {
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(group.color)
                                        .frame(width: 6, height: 6)
                                    Text(group.title)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(timeText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isAddingNewTask = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $isAddingNewTask) {
                NavigationStack {
                    Form {
                        TextField("Task title", text: $newTaskTitle)
                            .focused($isNewTaskTitleFocused)
                            .submitLabel(.done)
                            .onSubmit(addNewTask)
                    }
                    .navigationTitle("New Task")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { isAddingNewTask = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Add", action: addNewTask)
                                .disabled(newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .onAppear { isNewTaskTitleFocused = true }
                }
                .presentationDetents([.height(180)])
            }
        }
    }

    /// Creates the task straight into the Inbox (unsorted — same as a
    /// plain Inbox capture), then immediately picks it for this slot the
    /// same way tapping an existing candidate would, so "add a new task"
    /// here means "schedule something new right now," not a detour to go
    /// create it somewhere else first and come back.
    private func addNewTask() {
        let trimmed = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let task = TaskItem(title: trimmed, shelf: nil)
        modelContext.insert(task)
        isAddingNewTask = false
        newTaskTitle = ""
        onPick(task)
    }
}
