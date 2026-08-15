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
    /// Drives the "Review Previous Events or Assume Not Completed?" prompt
    /// shown by `regenerateBar` when there's a backlog from before today —
    /// see `ScheduleReviewViewModel.hasIncompletePastBlocks`.
    @State private var showRegeneratePrompt = false
    @State private var showPastReviewSheet = false
    /// Drives the "Review N Items in Inbox?" prompt `regenerateBar` shows
    /// first, before the past-events one — Inbox tasks are never
    /// auto-scheduled (see `AISchedulingService`'s doc comment), so this is
    /// the nudge to go sort them onto a shelf instead of letting them pile
    /// up unseen.
    @State private var showInboxReviewPrompt = false
    @State private var showInboxReviewSheet = false
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

    // AI scheduling itself is still mocked (that's a separate TODO: swap in
    // a real Claude API call). The calendar side is real — it hits Google
    // Calendar directly using whichever account is signed in via Settings.
    private let calendarService: CalendarServiceProtocol = GoogleCalendarService()
    private let schedulingService: AISchedulingServiceProtocol = MockAISchedulingService()

    var body: some View {
        NavigationStack {
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
                regenerateBar
            }
            .safeAreaInset(edge: .bottom) {
                dateSwiper
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Approve All") {
                        viewModel?.approveAll()
                    }
                    .disabled((viewModel?.blocks.isEmpty) ?? true)
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
                        candidates: viewModel.unscheduledCandidates(from: allTasks, excluding: block),
                        onPick: { chosen in
                            viewModel.manualReplace(block, with: chosen)
                            pickerTarget = nil
                        },
                        onAuto: {
                            viewModel.autoReplace(block, candidatePool: allTasks)
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

    private func setupIfNeeded() {
        guard viewModel == nil else { return }
        configureCalendarService()
        let vm = ScheduleReviewViewModel(
            modelContext: modelContext,
            calendarService: calendarService,
            schedulingService: schedulingService
        )
        vm.loadExistingBlocks(allBlocks)
        viewModel = vm
        Task {
            await vm.loadCalendarEvents()
            await vm.autoPlaceHabitsAndRecurringTasks(shelves: allShelves, habits: allHabits, eligibleHoursWindows: eligibleHoursWindows)
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

    private func changeDate(by days: Int) async {
        guard let viewModel else { return }
        let newDate = Calendar.current.date(byAdding: .day, value: days, to: viewModel.targetDate) ?? viewModel.targetDate
        await viewModel.changeTargetDate(to: newDate, existingBlocks: allBlocks)
        await viewModel.autoPlaceHabitsAndRecurringTasks(shelves: allShelves, habits: allHabits, eligibleHoursWindows: eligibleHoursWindows)
    }

    private func goToToday() async {
        guard let viewModel else { return }
        await viewModel.changeTargetDate(to: .now, existingBlocks: allBlocks)
        await viewModel.autoPlaceHabitsAndRecurringTasks(shelves: allShelves, habits: allHabits, eligibleHoursWindows: eligibleHoursWindows)
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
                Spacer()
                collapseEmptyPeriodsButton
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

    /// Unsorted tasks (no shelf) still worth a nudge to sort — mirrors
    /// NightlyReviewView's own Inbox-step filter, so this prompt and that
    /// one agree on what counts as "needs attention."
    private var inboxTasksToReview: [TaskItem] {
        allTasks.filter { $0.shelf == nil && !$0.isSnoozedFromAttributeReview }
    }

    private var routableShelves: [Shelf] {
        allShelves.filter { !$0.isKitchen }
    }

    /// Frozen directly above `dateSwiper` — regenerating rebuilds from
    /// right now forward (see ScheduleReviewViewModel.regenerateFromNow),
    /// not just whatever day happens to be on screen, so this lives
    /// outside the per-day content and toolbar entirely.
    ///
    /// Tapping this runs up to two prompts before it actually regenerates,
    /// each skipped if it has nothing to say: first, whether to sort
    /// what's sitting in the Inbox (never auto-scheduled — see
    /// `AISchedulingService`'s doc comment, so leaving it unreviewed just
    /// means it keeps getting silently skipped every time); then, if
    /// there's a backlog of not-yet-completed blocks from before today,
    /// whether to review them one at a time or assume they're all not
    /// done. Reviewing either one skips straight to actually regenerating
    /// once you're done — dismissing a review sheet by swiping it away
    /// leaves you free to back out without triggering a regenerate you
    /// didn't ask for; only finishing the review (or explicitly skipping)
    /// does.
    private var regenerateBar: some View {
        Button {
            guard viewModel != nil else { return }
            if !inboxTasksToReview.isEmpty {
                showInboxReviewPrompt = true
            } else {
                proceedPastEventsCheck()
            }
        } label: {
            Label(viewModel?.blocks.isEmpty == false ? "Regenerate Schedule" : "Generate Schedule", systemImage: "arrow.clockwise")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(viewModel?.isGenerating ?? true)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .confirmationDialog(
            "You have \(inboxTasksToReview.count) item\(inboxTasksToReview.count == 1 ? "" : "s") in your Inbox. Inbox tasks are never scheduled automatically.",
            isPresented: $showInboxReviewPrompt,
            titleVisibility: .visible
        ) {
            Button("Review Inbox") {
                showInboxReviewSheet = true
            }
            Button("Skip and Generate") {
                proceedPastEventsCheck()
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showInboxReviewSheet, onDismiss: proceedPastEventsCheck) {
            TaskReviewQueueSheet(shelves: routableShelves, queue: inboxTasksToReview)
        }
        .confirmationDialog(
            "You have tasks from previous days that haven't been marked complete.",
            isPresented: $showRegeneratePrompt,
            titleVisibility: .visible
        ) {
            Button("Review Previous Events") {
                showPastReviewSheet = true
            }
            Button("Assume Not Completed") {
                guard let viewModel else { return }
                Task {
                    // Awaited so every stale calendar event is actually
                    // gone before regeneration checks what's free — see
                    // `clearIncompletePastBlocks`'s doc comment.
                    await viewModel.clearIncompletePastBlocks(allBlocks: allBlocks)
                    await viewModel.regenerateFromNow(shelves: allShelves, habits: allHabits, eligibleHoursWindows: eligibleHoursWindows)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showPastReviewSheet) {
            NavigationStack {
                OverdueBlocksReviewList(
                    items: ScheduleReviewViewModel.reviewableBlocks(from: allBlocks).map { .block($0) },
                    onToggle: { item in
                        guard case .block(let block) = item else { return }
                        viewModel?.toggleComplete(block)
                    },
                    onDone: {
                        guard let viewModel else { return }
                        showPastReviewSheet = false
                        Task {
                            // Whatever's left after this review still isn't
                            // marked complete — sweep it the same way "Assume
                            // Not Completed" would, rather than leaving it
                            // stranded on today's (or an earlier day's)
                            // calendar untouched.
                            await viewModel.clearIncompletePastBlocks(allBlocks: allBlocks)
                            await viewModel.regenerateFromNow(shelves: allShelves, habits: allHabits, eligibleHoursWindows: eligibleHoursWindows)
                        }
                    }
                )
                .navigationTitle("Review Previous Events")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    /// The second half of `regenerateBar`'s tap flow, reached once the
    /// Inbox prompt (if it showed at all) is resolved — checks for an
    /// overdue-blocks backlog next, same as before that prompt existed.
    private func proceedPastEventsCheck() {
        guard viewModel != nil else { return }
        if ScheduleReviewViewModel.hasIncompletePastBlocks(in: allBlocks) {
            showRegeneratePrompt = true
        } else {
            runRegenerate()
        }
    }

    private func runRegenerate() {
        guard let viewModel else { return }
        Task {
            await viewModel.regenerateFromNow(shelves: allShelves, habits: allHabits, eligibleHoursWindows: eligibleHoursWindows)
        }
    }

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
    @Environment(\.dismiss) private var dismiss

    private struct ShelfGroup: Identifiable {
        let id: String
        let title: String
        let tasks: [TaskItem]
        let color: Color
    }

    /// Same shelf-grouped, colored, due-date-first layout as
    /// `EmptySlotPickerSheet` (`DayTimelineGridView.swift`) — that sheet
    /// and this one both boil down to "pick an unscheduled to-do to land
    /// on a given time," just reached from a different tap (an open
    /// slot's own "add here" vs. an existing block's "replace"), so they
    /// should read as the same picker rather than one being a flat list.
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
}

#Preview {
    ScheduleReviewView()
        .modelContainer(for: [TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self, Habit.self, HabitLog.self], inMemory: true)
}
