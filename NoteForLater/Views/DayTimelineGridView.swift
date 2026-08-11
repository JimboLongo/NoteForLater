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
struct DayTimelineGridView: View {
    let rows: [DayTimelineRow]
    let eligibleHoursWindows: [EligibleHoursWindow]
    /// The reusable day/time windows from Settings > Schedules — narrows
    /// the grid down to `visibleHourRange` instead of showing the full
    /// 24 hours.
    let namedSchedules: [NamedSchedule]
    let targetDate: Date
    let lockedStore: LockedEventsStore
    let viewModel: ScheduleReviewViewModel
    let isToday: Bool
    let allTasks: [TaskItem]
    /// For presenting `TaskCardSheet` (See Task Card) with somewhere to
    /// move a task to.
    let allShelves: [Shelf]
    let onSaveEvent: (CalendarEventSummary) -> Void
    let onDeleteBlock: (ScheduledBlock) -> Void
    /// Opens `ReplacementPickerSheet` — a specific pick from the list, or
    /// its Auto button, both handled there (see `ScheduleReviewView`).
    let onPickReplacement: (ScheduledBlock) -> Void

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
    /// the ScrollView itself is disabled.
    @State private var isEmptySlotArmed = false
    /// Drives the initial scroll-to-roughly-now on appear, and — while an
    /// empty-slot hold is active — scrolling the pressed time up to the
    /// top of the (still partly visible, above the half-height sheet)
    /// calendar.
    @State private var scrollPosition = ScrollPosition()
    /// The ScrollView's own viewport height, used to clamp how far
    /// `updateEmptySlot` can scroll the pressed time toward the top.
    @State private var viewportHeight: CGFloat = 0

    /// Only the hours actually relevant to this day are rendered/scrollable
    /// — derived from whichever `NamedSchedule`s apply to this weekday,
    /// widened if needed to cover anything already on the calendar (a
    /// manually-placed block/event outside every schedule's window never
    /// gets clipped out of view), then padded by an hour on either side of
    /// *that* true range — before the earlier of the eligible hours'
    /// start or the earliest actual appointment, and after the later of
    /// the eligible hours' end or the latest actual appointment — purely
    /// so the grid never starts or ends flush against something. Visual
    /// breathing room only: that padded hour is never itself eligible for
    /// anything, and a drop there behaves exactly as it always has outside
    /// eligible hours. Falls back to the full day if no schedule applies
    /// to this weekday at all and nothing's on the calendar either.
    private var visibleHourRange: (start: Int, end: Int) {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: targetDate)
        let applicable = namedSchedules.filter { $0.daysOfWeek.contains(weekday) }

        var startHour = applicable.isEmpty ? 0 : applicable.map(\.startHour).min()!
        var endHour = applicable.isEmpty ? 24 : applicable.map { $0.endMinute > 0 ? $0.endHour + 1 : $0.endHour }.max()!

        for row in rows {
            startHour = min(startHour, minutesSinceMidnight(row.startTime) / 60)
            let endMinutes = minutesSinceMidnight(row.startTime) + row.durationMinutes
            endHour = max(endHour, Int(ceil(Double(endMinutes) / 60)))
        }

        startHour -= 1
        endHour += 1

        startHour = max(0, min(startHour, 23))
        endHour = max(startHour + 1, min(24, endHour))
        return (startHour, endHour)
    }

    private var visibleStartMinutes: Int { visibleHourRange.start * 60 }

    private var dayHeight: CGFloat { CGFloat(visibleHourRange.end - visibleHourRange.start) * 60 * pointsPerMinute }

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
        ScrollView {
            ZStack(alignment: .topLeading) {
                hourGrid
                eligibleHoursOverlay
                // Drawn before the rows, so a press on an actual
                // block or event hits that row's own gesture first
                // — this only ever fires for genuinely open space.
                Color.clear
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .gesture(emptySlotGesture)
                ForEach(rows) { row in
                    rowView(for: row)
                }
            }
            .frame(height: dayHeight)
            .padding(.trailing, contentTrailingPadding)
        }
        .scrollDisabled(draggingRowID != nil || isEmptySlotArmed)
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.containerSize.height
        } action: { _, newValue in
            viewportHeight = newValue
        }
        .onAppear {
            let earliestHour = rows.map { Calendar.current.component(.hour, from: $0.startTime) }.min() ?? 7
            let targetHour = max(visibleHourRange.start, earliestHour - 1)
            scrollPosition.scrollTo(y: CGFloat(targetHour - visibleHourRange.start) * 60 * pointsPerMinute)
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
            TaskCardSheet(task: task, shelves: allShelves.filter { !$0.isPantry })
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
                    candidates: viewModel.unscheduledCandidatesIncludingInbox(from: allTasks),
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
        let maxOffset = max(0, dayHeight - viewportHeight)
        let target = min(max(0, y - viewportHeight / 4), maxOffset)
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

    /// Every rendered row labels its own top edge (e.g. "7 PM" at the top
    /// of the 7-8pm row) — without something more, the *bottom* edge of
    /// the very last row goes unlabeled, so a range padded to end at 8pm
    /// visually reads as stopping at 7pm (the last label you actually
    /// see), even though the row itself does reach 8pm. The trailing
    /// label below closes that off: one more label+gridline pinned to
    /// `visibleHourRange.end`'s boundary, positioned but not sized into
    /// `dayHeight` (a pure anchor, not a new 60pt content row).
    private var hourGrid: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(visibleHourRange.start..<visibleHourRange.end, id: \.self) { hour in
                    ZStack(alignment: .topLeading) {
                        HStack(alignment: .top, spacing: 8) {
                            Text(hourLabel(hour))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: hourLabelWidth, alignment: .trailing)
                                .offset(y: -6)
                            Rectangle()
                                .fill(Color.secondary.opacity(0.15))
                                .frame(height: 1)
                                .offset(y: -0.5)
                        }
                        ForEach([15, 30, 45], id: \.self) { minute in
                            quarterHourGridline(minute: minute)
                        }
                    }
                    .frame(height: 60 * pointsPerMinute, alignment: .top)
                    .id(hour)
                }
            }
            HStack(alignment: .top, spacing: 8) {
                Text(hourLabel(visibleHourRange.end))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: hourLabelWidth, alignment: .trailing)
                    .offset(y: -6)
                Rectangle()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 1)
                    .offset(y: -0.5)
            }
            .offset(y: CGFloat(visibleHourRange.end - visibleHourRange.start) * 60 * pointsPerMinute)
        }
    }

    /// A lighter, unlabeled-hour-number gridline at :15/:30/:45 within an
    /// hour row, spreading the timeline out into tappable 15-minute
    /// increments instead of one dense 60-minute block.
    private func quarterHourGridline(minute: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(":\(minute)")
                .font(.system(size: 9))
                .foregroundStyle(.secondary.opacity(0.6))
                .frame(width: hourLabelWidth, alignment: .trailing)
                .offset(y: -4)
            Rectangle()
                .fill(Color.secondary.opacity(0.08))
                .frame(height: 1)
                .offset(y: -0.5)
        }
        .offset(y: CGFloat(minute) * pointsPerMinute)
    }

    /// Enabled windows that apply to `targetDate`'s weekday, outlined so a
    /// drag has a visible target before you let go.
    @ViewBuilder
    private var eligibleHoursOverlay: some View {
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
        let baseOffset: CGFloat = CGFloat(minutesSinceMidnight(row.startTime) - visibleStartMinutes) * pointsPerMinute

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
            onBegan: { point in
                // Also blocked while the empty-slot candidates card is
                // open, or this row is already mid-swipe — otherwise you
                // could pick up an unrelated block right out from under
                // it, or start a vertical move partway through a delete
                // swipe.
                guard !isLocked, emptySlotTime == nil, swipingRowID == nil else { return }
                draggingRowID = row.id
                dragOriginY = point.y
                dragOriginX = point.x
            },
            onChanged: { point in
                guard draggingRowID == row.id, let dragOriginY, let dragOriginX else { return }
                dragTranslation = snappedTranslation(point.y - dragOriginY, for: row)
                dragTranslationX = point.x - dragOriginX
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
            },
            onCancelled: {
                guard draggingRowID == row.id else { return }
                draggingRowID = nil
                dragTranslation = 0
                dragOriginY = nil
                dragTranslationX = 0
                dragOriginX = nil
            }
        )
    }

    /// Swipe-left-to-remove for a proposed block — ignored entirely for
    /// calendar events, for a locked block (locking protects it from this
    /// the same way it protects it from being dragged or reflowed), and
    /// for movement that isn't horizontally dominant (so it never fights a
    /// vertical scroll; see `PanSwipeGesture`'s doc comment). Past
    /// `swipeDeleteThreshold`, releasing removes the block from the
    /// schedule via `onDeleteBlock` — the same "unschedule, leave the slot
    /// open" action already reachable from the tap menu's Delete button,
    /// just reachable directly by swiping now.
    private func swipeGesture(for row: DayTimelineRow) -> PanSwipeGesture {
        PanSwipeGesture(
            onChanged: { translation in
                guard case .proposed(let block) = row, !block.isLocked, draggingRowID == nil, emptySlotTime == nil else { return }
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

    private func isLockedRow(_ row: DayTimelineRow) -> Bool {
        switch row {
        case .event(let event):
            return lockedStore.isLocked(event.id)
        case .proposed(let block):
            return block.isLocked
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
                    // Always visible (unlike the calendar-event lock icon
                    // above, which only shows once locked) so there's
                    // always something to tap — locking a task protects it
                    // from being pushed around by another block's drag
                    // (`isLockedRow`/`unlockedOrder`) and from being
                    // cleared by "Regenerate Schedule"
                    // (`regenerateFromNow`). Green (same as the complete
                    // checkmark) once locked, so the two states read the
                    // same way at a glance.
                    Image(systemName: block.isLocked ? "lock.fill" : "lock.open")
                        .font(.caption2)
                        .foregroundStyle(block.isLocked ? Color.green : Color.secondary.opacity(0.7))
                        .padding(5)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            block.isLocked.toggle()
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
        .onTapGesture {
            // Routed through the view model rather than toggling
            // `isCompleted` directly — a habit-backed block needs its
            // Habit Tracker log kept in sync too (see
            // `ScheduleReviewViewModel.toggleComplete`).
            viewModel.toggleComplete(block)
        }
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
