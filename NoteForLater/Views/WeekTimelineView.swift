import SwiftUI

/// Zoomed-out overview of a week's already-placed blocks — reached by
/// tapping the zoom-out button on the day timeline (see
/// `ScheduleReviewView`). Shows only real `ScheduledBlock`s (task and
/// habit blocks with a specific time), not externally-synced calendar
/// events. A block can be dragged to a new day/time (see `commitDrag`),
/// tapped for the same Replace/Delete/Complete actions the day view
/// offers (see `blockActionButtons`), or a day's header/empty space
/// tapped to jump into the full day view for that date.
struct WeekTimelineView: View {
    let allBlocks: [ScheduledBlock]
    let allTasks: [TaskItem]
    let viewModel: ScheduleReviewViewModel
    let onSelectDay: (Date) -> Void

    @State private var weekAnchorDate: Date
    /// Same collapse-empty-periods concept as `DayTimelineGridView`, just
    /// against the *union* of all seven days at once — a time range only
    /// collapses when nothing on any day of the week falls in it, since
    /// every column shares one vertical axis here. Turning this off
    /// clears `manuallyExpandedGapKeys` too, same as the day view.
    @State private var isCollapsingEmptyPeriods = false
    @State private var manuallyExpandedGapKeys = Set<Int>()
    /// The ScrollView's own on-screen height (see `body`'s background
    /// `GeometryReader`) — `contentHeight` uses whichever of this or
    /// `weekHeight` is bigger, so the grid always fills the visible area
    /// with no blank strip below it once collapsing shrinks the real
    /// content shorter than the screen, while a taller (expanded) week
    /// still just scrolls exactly as before.
    @State private var availableHeight: CGFloat = 0
    /// Total on-screen width of the 7 day columns (excludes the time
    /// gutter) — see `body`'s second background `GeometryReader` — used
    /// to turn a drag's horizontal translation into "how many days over."
    @State private var columnsWidth: CGFloat = 0

    @State private var draggingBlockID: UUID?
    @State private var dragTranslation: CGSize = .zero
    @State private var actionMenuBlock: ScheduledBlock?
    @State private var replacementPickerBlock: ScheduledBlock?

    init(allBlocks: [ScheduledBlock], allTasks: [TaskItem], viewModel: ScheduleReviewViewModel, initialAnchorDate: Date, onSelectDay: @escaping (Date) -> Void) {
        self.allBlocks = allBlocks
        self.allTasks = allTasks
        self.viewModel = viewModel
        self.onSelectDay = onSelectDay
        _weekAnchorDate = State(initialValue: initialAnchorDate)
    }

    private let calendar = Calendar.current
    // 6 AM to 10 PM covers the vast majority of placed blocks without
    // forcing a scroll just to see the week's shape at a glance —
    // outliers before/after are still reachable by scrolling.
    private let visibleStartHour = 6
    private let visibleEndHour = 22
    private let pointsPerMinute: CGFloat = 0.6
    private let gutterWidth: CGFloat = 32

    private var weekDays: [Date] {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: weekAnchorDate) else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: interval.start) }
    }

    // MARK: - Collapsible segments (shared across every day column)

    /// One contiguous run of the visible quarter-hour range, either its
    /// real size (`isGap == false`) or collapsed to `compactGapHeight`
    /// (`isGap == true`) — mirrors `DayTimelineGridView.DisplaySegment`,
    /// just built from every day's blocks at once instead of one day's
    /// rows.
    private struct DisplaySegment: Identifiable {
        let startQuarter: Int
        /// Exclusive.
        let endQuarter: Int
        let isGap: Bool
        let rawGapMinutes: Int
        let gapKey: Int
        var id: Int { gapKey }
        var quarterCount: Int { endQuarter - startQuarter }
    }

    private static let collapseBufferQuarters = 1
    private static let minCollapsibleGapQuarters = 4
    private static let compactGapHeight: CGFloat = 28

    private var quarterRange: (start: Int, end: Int) {
        (visibleStartHour * 4, visibleEndHour * 4)
    }

    private var weekBlocks: [ScheduledBlock] {
        allBlocks.filter { block in weekDays.contains { calendar.isDate($0, inSameDayAs: block.date) } }
    }

    /// `quarterRange` broken into alternating populated/gap runs when
    /// `isCollapsingEmptyPeriods` is on — "populated" here means at least
    /// one day in the visible week has something scheduled in that
    /// quarter-hour, not just the day being rendered right now.
    private var displaySegments: [DisplaySegment] {
        guard isCollapsingEmptyPeriods else {
            return [DisplaySegment(startQuarter: quarterRange.start, endQuarter: quarterRange.end, isGap: false, rawGapMinutes: 0, gapKey: quarterRange.start)]
        }
        var populated = Set<Int>()
        for block in weekBlocks {
            let startQuarter = minutesSinceMidnight(block.startTime) / 15
            let endQuarter = Int(ceil(Double(minutesSinceMidnight(block.startTime) + block.durationMinutes) / 15))
            let clampedStart = max(quarterRange.start, startQuarter)
            let clampedEnd = min(quarterRange.end, max(startQuarter + 1, endQuarter))
            guard clampedStart < clampedEnd else { continue }
            for quarter in clampedStart..<clampedEnd {
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

    private var weekHeight: CGFloat {
        displaySegments.reduce(0) { $0 + heightForSegment($1) }
    }

    /// What the gutter and every day column actually size themselves
    /// to — never shorter than the real content (`weekHeight`, so a tall
    /// expanded week still scrolls normally), but stretched to fill the
    /// visible ScrollView area when collapsing (or just a light week)
    /// leaves the real content shorter than the screen.
    private var contentHeight: CGFloat {
        max(weekHeight, availableHeight)
    }

    private var isEffectivelyCollapsed: Bool {
        isCollapsingEmptyPeriods && displaySegments.contains(where: \.isGap)
    }

    /// Maps an absolute minute-of-day to its Y offset in the (possibly
    /// collapsed) rendered grid — every gridline, hour label, and block
    /// across every column is positioned from this same function, so
    /// none of them can ever disagree about where a gap actually is.
    private func displayOffset(forMinutes minutes: Int) -> CGFloat {
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

    /// The inverse of `displayOffset` — maps a Y in the rendered grid
    /// back to an absolute minute-of-day, for turning a drag's live
    /// position into a drop time. A Y landing inside a collapsed gap
    /// resolves to that gap's own start rather than anywhere mid-gap
    /// (there's no real time granularity to recover from a compacted
    /// stretch), and `commitDrag` expands the gap live while it's being
    /// dragged over so this case barely comes up in practice.
    private func minutes(forOffset y: CGFloat) -> Int {
        var offset: CGFloat = 0
        for segment in displaySegments {
            let height = heightForSegment(segment)
            if y < offset + height {
                if segment.isGap { return segment.startQuarter * 15 }
                let withinSegment = y - offset
                return segment.startQuarter * 15 + Int((withinSegment / pointsPerMinute).rounded())
            }
            offset += height
        }
        return quarterRange.end * 15
    }

    // MARK: - Drag to a new day/time

    private func canDrag(_ block: ScheduledBlock) -> Bool {
        !block.isLocked && block.habit == nil && !block.isCompleted
    }

    /// Live-expands whatever collapsed gap the drag is currently hovering
    /// over — same idea as the day view auto-expanding a collapsed gap a
    /// block gets dragged onto, so dropping into one isn't blocked just
    /// because it's visually compacted.
    private func expandGapIfHovering(atOffsetY y: CGFloat) {
        var offset: CGFloat = 0
        for segment in displaySegments {
            let height = heightForSegment(segment)
            if y < offset + height {
                if segment.isGap {
                    manuallyExpandedGapKeys.insert(segment.gapKey)
                }
                return
            }
            offset += height
        }
    }

    private func dragGesture(for block: ScheduledBlock) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .onChanged { value in
                guard canDrag(block) else { return }
                draggingBlockID = block.id
                dragTranslation = value.translation
                let startMinutes = minutesSinceMidnight(block.startTime)
                let topOffset = displayOffset(forMinutes: max(quarterRange.start * 15, startMinutes))
                expandGapIfHovering(atOffsetY: topOffset + value.translation.height)
            }
            .onEnded { value in
                guard canDrag(block) else { return }
                commitDrag(for: block, translation: value.translation)
                draggingBlockID = nil
                dragTranslation = .zero
            }
    }

    /// A plain relocate — new day, new time, same duration — with no
    /// reflow of anything else on either the old or new day. See
    /// `ScheduleReviewViewModel.moveBlock`'s doc comment for why this
    /// view deliberately doesn't try to replicate the day timeline's
    /// full ripple-reflow drag.
    private func commitDrag(for block: ScheduledBlock, translation: CGSize) {
        guard columnsWidth > 0, !weekDays.isEmpty else { return }
        let columnWidth = columnsWidth / CGFloat(weekDays.count)
        let deltaColumns = Int((translation.width / columnWidth).rounded())
        let originalIndex = weekDays.firstIndex { calendar.isDate($0, inSameDayAs: block.date) } ?? 0
        let targetIndex = min(max(0, originalIndex + deltaColumns), weekDays.count - 1)
        let targetDay = weekDays[targetIndex]

        let startMinutes = minutesSinceMidnight(block.startTime)
        let originalTopOffset = displayOffset(forMinutes: max(quarterRange.start * 15, startMinutes))
        let droppedMinutes = minutes(forOffset: originalTopOffset + translation.height)
        let snappedMinutes = max(0, min(1440 - block.durationMinutes, (droppedMinutes / 15) * 15))

        viewModel.moveBlock(block, toDayStart: calendar.startOfDay(for: targetDay), startMinutes: snappedMinutes)
        manuallyExpandedGapKeys.removeAll()
    }

    // MARK: - Tap actions

    @ViewBuilder
    private func blockActionButtons(for block: ScheduledBlock) -> some View {
        Button("View Day") { onSelectDay(block.date) }
        if block.task != nil, !block.isLocked {
            Button("Replace Task") { replacementPickerBlock = block }
        }
        Button(block.isCompleted ? "Mark Incomplete" : "Mark Complete") {
            viewModel.toggleComplete(block)
        }
        if !block.isLocked {
            Button("Delete", role: .destructive) { viewModel.deleteBlock(block) }
        }
        Button("Cancel", role: .cancel) {}
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            weekHeaderBar
            dayHeaderRow
            Divider()
            ScrollView(.vertical, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    HStack(alignment: .top, spacing: 0) {
                        timeGutter
                        ForEach(weekDays, id: \.self) { day in
                            dayColumn(for: day)
                        }
                    }
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear { columnsWidth = geo.size.width - gutterWidth }
                                .onChange(of: geo.size.width) { _, newValue in columnsWidth = newValue - gutterWidth }
                        }
                    )
                    ForEach(displaySegments.filter(\.isGap)) { segment in
                        collapsedGapRow(segment)
                            .frame(height: Self.compactGapHeight)
                            .frame(maxWidth: .infinity)
                            .offset(y: displayOffset(forMinutes: segment.startQuarter * 15))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)
            }
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { availableHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, newValue in availableHeight = newValue }
                }
            )
        }
        .safeAreaInset(edge: .bottom) {
            weekSwiper
        }
        .confirmationDialog(
            actionMenuBlock?.displayTitle ?? "",
            isPresented: Binding(
                get: { actionMenuBlock != nil },
                set: { if !$0 { actionMenuBlock = nil } }
            ),
            presenting: actionMenuBlock
        ) { block in
            blockActionButtons(for: block)
        }
        .sheet(item: $replacementPickerBlock) { block in
            ReplacementPickerSheet(
                candidates: viewModel.replacementCandidates(from: allTasks, for: .occupiedBlock(block)),
                onPick: { chosen in
                    viewModel.manualReplace(block, with: chosen)
                    replacementPickerBlock = nil
                },
                onAuto: {
                    viewModel.autoReplace(block, candidatePool: allTasks)
                    replacementPickerBlock = nil
                },
                onSwap: { chosen in
                    viewModel.swapBlocks(block, with: chosen)
                    replacementPickerBlock = nil
                }
            )
        }
    }

    private var weekHeaderBar: some View {
        ZStack {
            Text(weekRangeText)
                .font(.title3.weight(.bold))

            HStack {
                collapseEmptyPeriodsButton
                Spacer()
            }
        }
        // Pinned rather than left to hug its content — a small
        // icon-only button's minimum tap-target sizing can otherwise
        // pull the whole bar taller than the title text alone needs.
        .frame(height: 32)
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var collapseEmptyPeriodsButton: some View {
        Button {
            if isEffectivelyCollapsed {
                isCollapsingEmptyPeriods = false
                manuallyExpandedGapKeys.removeAll()
            } else {
                isCollapsingEmptyPeriods = true
                manuallyExpandedGapKeys.removeAll()
            }
        } label: {
            Image(systemName: isEffectivelyCollapsed ? "arrow.up.and.down.and.arrow.left.and.right" : "arrow.down.right.and.arrow.up.left")
        }
        .accessibilityLabel(isEffectivelyCollapsed ? "Expand Empty Periods" : "Collapse Empty Periods")
    }

    private var weekRangeText: String {
        guard let first = weekDays.first, let last = weekDays.last else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = calendar.component(.year, from: first) == calendar.component(.year, from: .now) ? "MMM d" : "MMM d, yyyy"
        let yearFormatter = DateFormatter()
        yearFormatter.dateFormat = "MMM d, yyyy"
        return "\(formatter.string(from: first)) – \(yearFormatter.string(from: last))"
    }

    private var dayHeaderRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutterWidth)
            ForEach(weekDays, id: \.self) { day in
                Button {
                    onSelectDay(day)
                } label: {
                    VStack(spacing: 2) {
                        Text(weekdayShortLabel(for: day))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(dayNumberLabel(for: day))
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 26, height: 26)
                            .background(
                                Circle().fill(calendar.isDateInToday(day) ? Color.accentColor : Color.clear)
                            )
                            .foregroundStyle(calendar.isDateInToday(day) ? Color.white : Color.primary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        // Pinned for the same reason as `weekHeaderBar` — the day
        // circle alone is 26pt, but a button that small can otherwise
        // claim more layout height than its content actually needs.
        .frame(height: 46)
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    private var timeGutter: some View {
        ZStack(alignment: .topTrailing) {
            ForEach(hoursToLabel, id: \.self) { hour in
                Text(hourLabel(hour))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .offset(y: displayOffset(forMinutes: hour * 60) - 6)
            }
        }
        .frame(width: gutterWidth, height: contentHeight, alignment: .topTrailing)
        .padding(.trailing, 4)
    }

    /// Every even hour that isn't currently sitting inside a collapsed
    /// gap — a label for a stretch of time that's been compacted away
    /// would just land on top of (or past) the collapsed divider itself.
    private var hoursToLabel: [Int] {
        stride(from: visibleStartHour, through: visibleEndHour, by: 2).filter { hour in
            !(segment(forMinute: hour * 60)?.isGap ?? false)
        }
    }

    private func segment(forMinute minute: Int) -> DisplaySegment? {
        displaySegments.first { minute >= $0.startQuarter * 15 && minute < $0.endQuarter * 15 }
    }

    private func dayColumn(for day: Date) -> some View {
        let dayBlocks = allBlocks.filter { calendar.isDate($0.date, inSameDayAs: day) }
        // Raised above its sibling columns only while it's the one
        // holding the actively-dragged block — a block dragged toward a
        // later/earlier day visually slides past its own column's edge
        // (nothing here clips it), and without this it would render
        // *underneath* whichever neighboring column it's currently
        // hovering over instead of on top of it.
        let isDraggingFromThisColumn = draggingBlockID != nil && dayBlocks.contains { $0.id == draggingBlockID }
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(calendar.isDateInToday(day) ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06))
            ForEach(hoursToLabel, id: \.self) { hour in
                Divider()
                    .offset(y: displayOffset(forMinutes: hour * 60))
            }
            ForEach(dayBlocks) { block in
                blockView(for: block)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: contentHeight)
        .zIndex(isDraggingFromThisColumn ? 10 : 0)
        .contentShape(Rectangle())
        .onTapGesture { onSelectDay(day) }
    }

    private func blockView(for block: ScheduledBlock) -> some View {
        let color = block.task?.shelf?.color ?? Color.accentColor
        let startMinutes = minutesSinceMidnight(block.startTime)
        let endMinutes = minutesSinceMidnight(block.endTime)
        let topOffset = displayOffset(forMinutes: max(quarterRange.start * 15, startMinutes))
        let bottomOffset = displayOffset(forMinutes: min(quarterRange.end * 15, endMinutes))
        let clampedHeight = max(3, bottomOffset - topOffset)
        let isDragging = draggingBlockID == block.id
        let liveTranslation = isDragging ? dragTranslation : .zero
        // Only tries a second line once there's actually room for one —
        // a short block just clips to its single line rather than
        // overflowing into whatever's below it.
        return Text(block.displayTitle)
            .font(.system(size: 6, weight: .medium))
            .strikethrough(block.isCompleted)
            .lineLimit(clampedHeight > 16 ? 2 : 1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 2)
            .padding(.top, 1)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: clampedHeight, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(block.isCompleted ? 0.35 : 0.75)))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .shadow(color: .black.opacity(isDragging ? 0.35 : 0), radius: 4, y: 2)
            .scaleEffect(isDragging ? 1.12 : 1)
            .offset(x: liveTranslation.width, y: topOffset + liveTranslation.height)
            .padding(.horizontal, 1)
            .gesture(dragGesture(for: block))
            .onTapGesture { actionMenuBlock = block }
    }

    private func collapsedGapRow(_ segment: DisplaySegment) -> some View {
        Button {
            manuallyExpandedGapKeys.insert(segment.gapKey)
        } label: {
            HStack(spacing: 6) {
                Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 1)
                Text(freeTimeLabel(forMinutes: segment.rawGapMinutes))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, gutterWidth + 4)
    }

    private func freeTimeLabel(forMinutes minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        if hours > 0, mins > 0 { return "\(hours)h \(mins)m free" }
        if hours > 0 { return "\(hours)h free" }
        return "\(mins)m free"
    }

    private func minutesSinceMidnight(_ date: Date) -> Int {
        let startOfDay = calendar.startOfDay(for: date)
        return Int(date.timeIntervalSince(startOfDay) / 60)
    }

    private func weekdayShortLabel(for day: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter.string(from: day)
    }

    private func dayNumberLabel(for day: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter.string(from: day)
    }

    private func hourLabel(_ hour: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h a"
        let date = calendar.date(bySettingHour: hour % 24, minute: 0, second: 0, of: .now) ?? .now
        return formatter.string(from: date)
    }

    private var weekSwiper: some View {
        HStack {
            Button {
                shiftWeek(by: -1)
            } label: {
                Label("Previous Week", systemImage: "chevron.left")
                    .font(.subheadline.weight(.semibold))
                    .frame(height: 44)
            }

            Spacer()

            if !calendar.isDate(weekAnchorDate, equalTo: .now, toGranularity: .weekOfYear) {
                Button("This Week") {
                    weekAnchorDate = .now
                }
                .font(.subheadline.weight(.semibold))
                .frame(height: 44)
            }

            Spacer()

            Button {
                shiftWeek(by: 1)
            } label: {
                HStack(spacing: 4) {
                    Text("Next Week")
                    Image(systemName: "chevron.right")
                }
                .font(.subheadline.weight(.semibold))
                .frame(height: 44)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func shiftWeek(by weeks: Int) {
        weekAnchorDate = calendar.date(byAdding: .weekOfYear, value: weeks, to: weekAnchorDate) ?? weekAnchorDate
    }
}
