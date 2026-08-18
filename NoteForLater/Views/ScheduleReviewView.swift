import SwiftUI
import SwiftData

/// Review screen for a single day's schedule, navigable to any day via the
/// chevrons (default: tomorrow). Shown as a real time-grid — see
/// `DayTimelineGridView` — where dragging an unlocked block/event to a new
/// time reflows the rest of the day around it, and tapping one opens its
/// available actions:
///
///   - On today: Mark Complete or Push to Another Day (unschedules it for
///     a future night to pick up).
///   - On any other day: Delete (slot goes back to open, task requeued), or
///     Replace Task — pick a specific replacement from the unscheduled
///     queue, or its Auto button for the next-best queued to-do instead.
///   - Calendar events: edit title/time/notes, or toggle locked (locked
///     events can't be dragged and are excluded from the reflow).
///   - Editing an already-approved block drops it back to "proposed" —
///     re-tapping Approve All pushes the change to the same calendar event
///     instead of a new one.
struct ScheduleReviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TaskItem.createdAt) private var allTasks: [TaskItem]
    @Query(sort: \Shelf.sortOrder) private var allShelves: [Shelf]
    @Query(sort: \Habit.sortOrder) private var allHabits: [Habit]
    @Query private var allBlocks: [ScheduledBlock]
    @Query private var calendarSubscriptions: [CalendarSubscription]
    @Query private var eligibleHoursWindows: [EligibleHoursWindow]

    @State private var viewModel: ScheduleReviewViewModel?
    @State private var pickerTarget: ScheduledBlock?
    @State private var lockedStore = LockedEventsStore.shared
    /// Live horizontal offset of the date header while dragging — follows
    /// your finger during the pull, then springs back to 0 on release
    /// (the push), rather than only reacting once you release past a
    /// threshold.
    @State private var dateDragOffset: CGFloat = 0
    @State private var isCollapsingEmptyPeriods = false
    /// Bumped to force a full re-collapse — see
    /// `DayTimelineGridView.collapseResetToken`.
    @State private var collapseResetToken = 0
    /// Kept in sync via `DayTimelineGridView.onCollapsedGapChange` —
    /// false once every gap's been individually expanded away, even with
    /// `isCollapsingEmptyPeriods` still on. Drives
    /// `collapseEmptyPeriodsButton`'s icon/action so it reads correctly
    /// in that state instead of looking like tapping it does nothing.
    @State private var isAnyPeriodCollapsed = false
    /// Zoomed-out weekly overview — see `WeekTimelineView`. Replaces the
    /// day timeline (and its header/date-swiper) entirely while shown;
    /// tapping a day there jumps back to the day view for that date.
    @State private var isShowingWeekView = false

    // AI scheduling itself is still mocked (that's a separate TODO: swap in
    // a real Claude API call). The calendar side is real — it hits Google
    // Calendar directly using whichever account is signed in via Settings.
    private let calendarService: CalendarServiceProtocol = GoogleCalendarService()
    private let schedulingService: AISchedulingServiceProtocol = MockAISchedulingService()

    var body: some View {
        NavigationStack {
            Group {
                if isShowingWeekView, let viewModel {
                    WeekTimelineView(
                        allBlocks: allBlocks,
                        allTasks: allTasks,
                        viewModel: viewModel,
                        initialAnchorDate: viewModel.targetDate,
                        onSelectDay: { day in Task { await jumpToDay(day) } }
                    )
                } else if isShowingWeekView {
                    ProgressView()
                } else {
                    Group {
                        if let viewModel {
                            content(viewModel: viewModel)
                        } else {
                            ProgressView()
                        }
                    }
                    .safeAreaInset(edge: .top) {
                        header
                    }
                    .safeAreaInset(edge: .bottom) {
                        dateSwiper
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isShowingWeekView {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Approve All") {
                            viewModel?.approveAll()
                        }
                        .disabled((viewModel?.blocks.isEmpty) ?? true)
                    }
                }
            }
            .onAppear(perform: setupIfNeeded)
            // `errorMessage` was already being set on a failed
            // generate/regenerate (a calendar fetch throwing, most
            // likely) but nothing ever surfaced it — a failure looked
            // identical to "nothing changed," with no way to tell the two
            // apart.
            .alert("Couldn't Generate Schedule", isPresented: Binding(
                get: { viewModel?.errorMessage != nil },
                set: { isPresented in if !isPresented { viewModel?.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel?.errorMessage ?? "")
            }
            .sheet(item: $pickerTarget) { block in
                if let viewModel {
                    ReplacementPickerSheet(
                        candidates: viewModel.replaceCandidates(from: allTasks, excluding: block),
                        onPick: { chosen in
                            viewModel.manualReplace(block, with: chosen)
                            pickerTarget = nil
                        },
                        onAuto: {
                            viewModel.autoReplace(block, candidatePool: allTasks)
                            pickerTarget = nil
                        },
                        onSwap: { chosen in
                            viewModel.swapBlocks(block, with: chosen)
                            pickerTarget = nil
                        }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func content(viewModel: ScheduleReviewViewModel) -> some View {
        if viewModel.isGenerating {
            ProgressView("Building schedule...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // The 2-Minute Task shelf's checklist rides inside
            // DayTimelineGridView's own ScrollView now (as its first
            // piece of content, above the grid) rather than sitting
            // outside it here — so it scrolls away with the rest of the
            // timeline instead of staying pinned above it.
            DayTimelineGridView(
                rows: timelineRows(viewModel: viewModel),
                eligibleHoursWindows: eligibleHoursWindows,
                targetDate: viewModel.targetDate,
                lockedStore: lockedStore,
                viewModel: viewModel,
                isToday: isToday,
                allTasks: allTasks,
                allShelves: allShelves,
                allHabits: allHabits,
                onSaveEvent: { updated in viewModel.saveEventEdit(updated) },
                onDeleteBlock: { block in viewModel.deleteBlock(block) },
                onPickReplacement: { block in pickerTarget = block },
                isCollapsingEmptyPeriods: isCollapsingEmptyPeriods,
                collapseResetToken: collapseResetToken,
                onCollapsedGapChange: { isAnyPeriodCollapsed = $0 }
            )
            .refreshable {
                await viewModel.loadCalendarEvents()
            }
        }
    }

    /// A pushed-and-approved block's task shows up both as a proposed row
    /// (locally) and, once Google has it, as a synced calendar event — same
    /// task, two rows. An event whose ID matches a block's googleEventID, or
    /// whose title matches (as a fallback, e.g. if the ID round-trip didn't
    /// happen yet), is still considered app-originated — not a genuinely
    /// external synced event — so it's skipped here and represented only by
    /// its proposed-block row. Everything left in `eventRows` is therefore
    /// genuinely external and defaults to locked (see CalendarEventRow).
    private func timelineRows(viewModel: ScheduleReviewViewModel) -> [DayTimelineRow] {
        ScheduleReviewViewModel.timelineRows(blocks: viewModel.blocks, calendarEvents: viewModel.calendarEvents)
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(viewModel?.targetDate ?? .now)
    }

    /// Runs on every appear, not just the view's first one — a tab switch
    /// away and back (e.g. editing a task's Eligible Schedules over on the
    /// Inbox/Shelves tab, then flipping to Calendar to check it) is the
    /// normal way a change made elsewhere ought to show up here, and
    /// there's no other signal wired up to tell this screen something
    /// changed while it wasn't the one on screen. `loadExistingBlocks`
    /// re-derives `blocks` from the live `allBlocks` query first so
    /// `autoPlaceEligibleTasks`'s own trim/place pass is working from
    /// what's actually in the model, not a stale snapshot from whenever
    /// the ViewModel happened to be created.
    private func setupIfNeeded() {
        if viewModel == nil {
            configureCalendarService()
            viewModel = ScheduleReviewViewModel(
                modelContext: modelContext,
                calendarService: calendarService,
                schedulingService: schedulingService
            )
        }
        guard let vm = viewModel else { return }
        vm.loadExistingBlocks(allBlocks)
        Task {
            await vm.loadCalendarEvents()
            await syncSchedule()
        }
    }

    private func configureCalendarService() {
        let enabledIDs = calendarSubscriptions.filter(\.isEnabled).map(\.calendarID)
        calendarService.enabledCalendarIDs = enabledIDs.isEmpty ? ["primary"] : enabledIDs
        // Full day, not a fixed 8am-9pm business-hours window — individual
        // SchedulingRules define their own windows now, and some (e.g. a
        // 6pm-10pm evening rule) fall outside the old default.
        calendarService.workingHours = (
            DateComponents(hour: 0, minute: 0),
            DateComponents(hour: 23, minute: 59)
        )
    }

    /// The routine per-appear/day-change sync, shared by every call site
    /// below — normally just the light, purely-additive top-up
    /// (`autoPlaceEligibleTasks`), same as always. Escalates to a full
    /// `regenerateFromNow` exactly once whenever `ScheduleDirtyState`
    /// says something happened elsewhere that the additive pass can't
    /// fix on its own (see its own doc comment) — a task that's no
    /// longer eligible for whatever rule originally placed it needs to
    /// actually be cleared and re-walked, not topped up around — then
    /// clears the flag so the next sync goes back to the light path
    /// until something changes again. See spec §6.
    private func syncSchedule() async {
        guard let vm = viewModel else { return }
        if ScheduleDirtyState.shared.isDirty {
            await vm.regenerateFromNow(shelves: allShelves, habits: allHabits, eligibleHoursWindows: eligibleHoursWindows)
            ScheduleDirtyState.shared.isDirty = false
        } else {
            await vm.autoPlaceEligibleTasks(shelves: allShelves, habits: allHabits, eligibleHoursWindows: eligibleHoursWindows)
        }
    }

    private func changeDate(by days: Int) async {
        guard let viewModel else { return }
        let newDate = Calendar.current.date(byAdding: .day, value: days, to: viewModel.targetDate) ?? viewModel.targetDate
        await viewModel.changeTargetDate(to: newDate, existingBlocks: allBlocks)
        await syncSchedule()
    }

    /// Tapping a day (or a block) in `WeekTimelineView` lands here — jumps
    /// the day view straight to that date and switches back to it, same
    /// as `goToToday`/`changeDate` but to an arbitrary target instead of
    /// "now" or a relative offset.
    private func jumpToDay(_ day: Date) async {
        guard let viewModel else { return }
        await viewModel.changeTargetDate(to: day, existingBlocks: allBlocks)
        await syncSchedule()
        isShowingWeekView = false
    }

    private func goToToday() async {
        guard let viewModel else { return }
        await viewModel.changeTargetDate(to: .now, existingBlocks: allBlocks)
        await syncSchedule()
    }

    /// In-content header (not the system nav bar) so the full date reads
    /// as the page's actual title, not a compact nav-bar label — the
    /// chevrons/Approve All/Edit stay in the toolbar above it.
    private var header: some View {
        ZStack {
            VStack(spacing: 2) {
                Text(relativeDayLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                dateStack
                    .frame(maxWidth: .infinity)
                    .clipped()
            }

            HStack {
                collapseEmptyPeriodsButton
                Spacer()
                weekViewButton
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 5)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    // Follows your finger 1:1 while dragging — a real pull,
                    // not just a threshold you tap past.
                    dateDragOffset = value.translation.width
                }
                .onEnded { value in
                    let horizontal = value.translation.width
                    let isHorizontalDrag = abs(horizontal) > abs(value.translation.height)
                    let threshold: CGFloat = 50
                    if isHorizontalDrag, horizontal < -threshold {
                        Task { await changeDate(by: 1) }
                    } else if isHorizontalDrag, horizontal > threshold {
                        Task { await changeDate(by: -1) }
                    }
                    // Whether or not the date changed, the date snaps back
                    // to center — that settle is the "push" half of the
                    // gesture, right on the heels of the pull. Critically
                    // damped (dampingFraction 1) so it eases straight to 0
                    // with no overshoot/bounce past center.
                    withAnimation(.spring(response: 0.3, dampingFraction: 1)) {
                        dateDragOffset = 0
                    }
                }
        )
    }

    /// True only when collapsing is on *and* something's actually shown
    /// collapsed right now — if every gap's been individually tapped
    /// open, this reads as false even though `isCollapsingEmptyPeriods`
    /// itself never changed, so the button falls back to its "collapse"
    /// icon instead of an "expand" icon with nothing left to expand.
    private var isEffectivelyCollapsed: Bool {
        isCollapsingEmptyPeriods && isAnyPeriodCollapsed
    }

    private var collapseEmptyPeriodsButton: some View {
        Button {
            if isEffectivelyCollapsed {
                isCollapsingEmptyPeriods = false
            } else {
                // Also covers the "every gap manually expanded" case:
                // `isCollapsingEmptyPeriods` may already be `true` (so
                // setting it again is a no-op), but bumping the reset
                // token forces every segment to drop its manual
                // expansions and actually re-collapse.
                isCollapsingEmptyPeriods = true
                collapseResetToken += 1
            }
        } label: {
            Image(systemName: isEffectivelyCollapsed ? "arrow.up.and.down.and.arrow.left.and.right" : "arrow.down.right.and.arrow.up.left")
        }
        .accessibilityLabel(isEffectivelyCollapsed ? "Expand Empty Periods" : "Collapse Empty Periods")
    }

    private var weekViewButton: some View {
        Button {
            isShowingWeekView = true
        } label: {
            Image(systemName: "minus.magnifyingglass")
        }
        .accessibilityLabel("Week View")
    }

    /// Frozen above the tab bar, separate from the date/label up top — not
    /// part of any scrolling content, so it never moves.
    private var dateSwiper: some View {
        HStack {
            Button {
                Task { await changeDate(by: -1) }
            } label: {
                Label("Previous Day", systemImage: "chevron.left")
                    .font(.subheadline.weight(.semibold))
                    .frame(height: 44)
            }

            Spacer()

            if !isToday {
                Button {
                    Task { await goToToday() }
                } label: {
                    Text("Go To Today")
                        .font(.subheadline.weight(.semibold))
                        .frame(height: 44)
                }
            }

            Spacer()

            Button {
                Task { await changeDate(by: 1) }
            } label: {
                HStack(spacing: 4) {
                    Text("Next Day")
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

    // Generating/regenerating the schedule, and the Inbox/overdue-events
    // review prompts that used to gate it, now live solely in Nightly
    // Review's own flow (see NightlyReviewView's Inbox and Tomorrow
    // steps) — this tab is view-and-adjust only.

    /// The date the drag would land on, if any, revealed sliding in from
    /// whichever edge you're dragging toward as it happens — not just the
    /// current date moving, but the *next* one visibly arriving behind it.
    /// The outgoing and incoming date always sit exactly this far apart
    /// (it's added to the same offset driving both), so it has to clear
    /// the widest date string ("Wednesday, September 30, 2026" at
    /// `.title3.weight(.bold)`) or the two would overlap for the entire
    /// drag, not just briefly.
    private static let dateSlideDistance: CGFloat = 340
    /// How much drag it takes for the incoming date to reach full opacity —
    /// deliberately shorter than `dateSlideDistance`, which is about
    /// physical separation, not how quickly it should become visible. Using
    /// the same distance for both would mean barely-there opacity for most
    /// of a typical (much shorter) drag.
    private static let dateFadeDistance: CGFloat = 120

    private var dateStack: some View {
        ZStack {
            if dateDragOffset < 0 {
                Text(dateTitle(daysOffset: 1))
                    .offset(x: dateDragOffset + Self.dateSlideDistance)
                    .opacity(min(1, abs(dateDragOffset) / Self.dateFadeDistance))
            } else if dateDragOffset > 0 {
                Text(dateTitle(daysOffset: -1))
                    .offset(x: dateDragOffset - Self.dateSlideDistance)
                    .opacity(min(1, abs(dateDragOffset) / Self.dateFadeDistance))
            }
            Text(fullDateTitle)
                .offset(x: dateDragOffset)
        }
        .font(.title3.weight(.bold))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private var fullDateTitle: String { dateTitle(daysOffset: 0) }

    private func dateTitle(daysOffset: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        let base = viewModel?.targetDate ?? .now
        let date = daysOffset == 0 ? base : (Calendar.current.date(byAdding: .day, value: daysOffset, to: base) ?? base)
        return formatter.string(from: date)
    }

    /// "Today"/"Yesterday"/"Tomorrow" for the three days around now, then
    /// "N Days Ago"/"In N Days" beyond that.
    private var relativeDayLabel: String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let target = calendar.startOfDay(for: viewModel?.targetDate ?? today)
        let days = calendar.dateComponents([.day], from: today, to: target).day ?? 0
        switch days {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case let d where d > 1: return "In \(d) Days"
        default: return "\(-days) Days Ago"
        }
    }
}

/// A single row in the day's merged timeline: either an existing calendar
/// event (read-only) or a proposed/approved task block. Shared with
/// `DayTimelineGridView`, which renders the same rows positioned by actual
/// time instead of as list rows.
enum DayTimelineRow: Identifiable {
    case event(CalendarEventSummary)
    case proposed(ScheduledBlock)

    var id: String {
        switch self {
        case .event(let event): return "event-\(event.id)"
        case .proposed(let block): return "block-\(block.id)"
        }
    }

    var startTime: Date {
        switch self {
        case .event(let event): return event.start
        case .proposed(let block): return block.startTime
        }
    }

    var endTime: Date {
        switch self {
        case .event(let event): return event.end
        case .proposed(let block): return block.endTime
        }
    }

    var durationMinutes: Int {
        max(1, Int(endTime.timeIntervalSince(startTime) / 60))
    }
}

/// Pick an unscheduled to-do — reached from `DayTimelineGridView`'s
/// tap-to-act menu (replace the tapped block) or by tapping an open slot
/// on the grid (add it there). `candidates` already excludes the block's
/// own current task, so both a manual pick and Random are guaranteed to
/// land on something actually different.
struct ReplacementPickerSheet: View {
    let candidates: [TaskItem]
    var title: String = "Replace With..."
    let onPick: (TaskItem) -> Void
    /// The old standalone "Auto-Replace" tap-menu action, folded in here
    /// as this sheet's own Auto button — swaps in the next-best queued
    /// to-do (by priority, then due date; see
    /// `ScheduleReviewViewModel.autoReplace`) instead of a specific pick.
    let onAuto: () -> Void
    /// Only ever offered for a candidate that's already scheduled
    /// somewhere else (see `ScheduleReviewViewModel.replaceCandidates`) —
    /// trades the two tasks' times instead of freeing the candidate's own
    /// slot the way tapping the row itself (`onPick`) does.
    var onSwap: ((TaskItem) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    private struct DayGroup: Identifiable {
        let id: String
        let title: String
        let tasks: [TaskItem]
    }

    private func activeBlock(for task: TaskItem) -> ScheduledBlock? {
        (task.scheduledBlocks ?? []).first { !$0.isCompleted }
    }

    /// One section per day a candidate is currently sitting on, in
    /// chronological order (each day's own tasks sorted by their block's
    /// start time), plus a leading "Unscheduled" section (sorted by due
    /// date, same as before) for candidates with no block at all — day is
    /// the more useful grouping now that Replace/Swap candidates aren't
    /// just unscheduled to-dos anymore (see
    /// `ScheduleReviewViewModel.replaceCandidates`), since which day a
    /// candidate would come *from* is exactly what you're weighing when
    /// picking one.
    private var groups: [DayGroup] {
        let calendar = Calendar.current
        func dueDateFirst(_ lhs: TaskItem, _ rhs: TaskItem) -> Bool {
            switch (lhs.dueDate, rhs.dueDate) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return false
            }
        }

        let unscheduled = candidates.filter { activeBlock(for: $0) == nil }.sorted(by: dueDateFirst)
        let scheduled = candidates.filter { activeBlock(for: $0) != nil }
        let byDay = Dictionary(grouping: scheduled) { calendar.startOfDay(for: activeBlock(for: $0)!.date) }
        let dayGroups = byDay.keys.sorted().map { day -> DayGroup in
            let tasksForDay = (byDay[day] ?? []).sorted { activeBlock(for: $0)!.startTime < activeBlock(for: $1)!.startTime }
            return DayGroup(id: day.timeIntervalSince1970.description, title: dayTitle(for: day), tasks: tasksForDay)
        }

        let unscheduledGroup = unscheduled.isEmpty ? [] : [DayGroup(id: "unscheduled", title: "Unscheduled", tasks: unscheduled)]
        return unscheduledGroup + dayGroups
    }

    private func dayTitle(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter.string(from: day)
    }

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                    ContentUnavailableView("Nothing to Schedule", systemImage: "tray", description: Text("No unscheduled to-dos available."))
                } else {
                    List {
                        ForEach(groups) { group in
                            Section(group.title) {
                                ForEach(group.tasks) { task in
                                    let existingBlock = activeBlock(for: task)
                                    let color = task.shelf?.color ?? .secondary
                                    HStack(spacing: 8) {
                                        Button {
                                            onPick(task)
                                        } label: {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(task.title)
                                                    .font(.body.weight(.medium))
                                                    .foregroundStyle(.primary)
                                                if let existingBlock {
                                                    Text("\(task.shelf?.name ?? "Inbox") \u{00B7} \(timeRangeText(existingBlock.startTime, existingBlock.endTime))")
                                                        .font(.caption)
                                                        .foregroundStyle(.orange)
                                                } else {
                                                    Text("\(task.durationLabel) \u{00B7} \(task.priority.label)")
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)

                                        if existingBlock != nil, let onSwap {
                                            Button {
                                                onSwap(task)
                                            } label: {
                                                Image(systemName: "arrow.left.arrow.right")
                                                    .font(.caption.weight(.semibold))
                                                    .foregroundStyle(Color.accentColor)
                                                    .padding(8)
                                                    .background(Circle().fill(Color.accentColor.opacity(0.18)))
                                            }
                                            .buttonStyle(.plain)
                                            .accessibilityLabel("Swap times with \(task.title)")
                                        }
                                    }
                                    .padding(.vertical, 2)
                                    .listRowBackground(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(color.opacity(0.15))
                                            .padding(.vertical, 2)
                                    )
                                    .listRowSeparator(.hidden)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Auto", action: onAuto)
                }
            }
        }
    }

    /// No day in this one — a candidate row already sits under its own
    /// day's section header (see `groups`), so repeating the day here
    /// would just be noise.
    private func timeRangeText(_ start: Date, _ end: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return "\(formatter.string(from: start))–\(formatter.string(from: end))"
    }
}

#Preview {
    ScheduleReviewView()
        .modelContainer(for: [TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self, Habit.self, HabitLog.self], inMemory: true)
}
