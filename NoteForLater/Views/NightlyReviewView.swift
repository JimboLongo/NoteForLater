import SwiftUI
import SwiftData

/// The nightly wrap-up-and-plan-ahead flow: mark today's schedule
/// complete/not complete, sort what's landed in the Inbox (one item at a
/// time, Tinder-card style), then generate and approve tomorrow's proposed
/// schedule. Reached either by tapping the Nightly Review notification
/// (see NightlyReviewNotificationService / AppDelegate) or "Start Nightly
/// Review Now" in Settings — both just set
/// NightlyReviewLaunchState.shared.pendingReview, which ContentView
/// observes to present this as a full-screen cover.
struct NightlyReviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query private var allBlocks: [ScheduledBlock]
    @Query(sort: \Shelf.sortOrder) private var allShelves: [Shelf]
    @Query(sort: \Habit.sortOrder) private var allHabits: [Habit]
    @Query private var eligibleHoursWindows: [EligibleHoursWindow]
    @Query private var calendarSubscriptions: [CalendarSubscription]
    @Query(sort: \TaskItem.createdAt) private var allTasks: [TaskItem]
    @Query(sort: \NamedSchedule.sortOrder) private var namedSchedules: [NamedSchedule]

    @State private var step: Step = .chooseDay
    /// The day being reviewed — defaults to today, but overridable (e.g.
    /// doing this in the morning for a day that already ended). "Plan
    /// Tomorrow" always means the day right after whichever day this is,
    /// not calendar-tomorrow-from-right-now — reviewing yesterday's
    /// schedule this morning should plan *today*, not tomorrow.
    @State private var reviewDate: Date = Calendar.current.startOfDay(for: .now)
    @State private var todayViewModel: ScheduleReviewViewModel?
    @State private var tomorrowViewModel: ScheduleReviewViewModel?
    /// Drives the Inbox step — presenting `TaskReviewQueueSheet` (the same
    /// Task Attribute Review flow reachable from the Inbox screen) rather
    /// than a separate hand-rolled queue, so leaving Today automatically
    /// launches it instead of landing on a bespoke mini-flow that happens
    /// to do almost the same thing.
    @State private var attributeReviewSession: AttributeReviewSession?
    /// Drives the Plan step's Replace-Task sheet — same
    /// `ReplacementPickerSheet` the regular calendar view uses (see
    /// `ScheduleReviewView`).
    @State private var pickerTarget: ScheduledBlock?
    @State private var lockedStore = LockedEventsStore.shared

    private let calendarService: CalendarServiceProtocol = GoogleCalendarService()
    private let schedulingService: AISchedulingServiceProtocol = MockAISchedulingService()

    private enum Step: Int, CaseIterable {
        case chooseDay, today, inbox, tomorrow

        /// `planDate` is only meaningful for `.tomorrow` — the day right
        /// after whichever day was picked in Choose Day, not
        /// calendar-tomorrow-from-right-now — so its title can name that
        /// day explicitly instead of just saying "Tomorrow".
        func title(planDate: Date) -> String {
            switch self {
            case .chooseDay: return "Which Day?"
            case .today: return "Review Schedule"
            case .inbox: return "Sort Your Inbox"
            case .tomorrow:
                let formatter = DateFormatter()
                formatter.dateFormat = "EEE MMMM d, yyyy"
                return "Plan for \(formatter.string(from: planDate))"
            }
        }
    }

    private var planDate: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: reviewDate) ?? reviewDate
    }

    /// `planDate` is always either real-today or real-tomorrow — it's
    /// `reviewDate` (never later than today) plus one day — so this never
    /// needs the fuller "In N Days"/"N Days Ago" cases another relative-day
    /// label in this app handles.
    private var planRelativeDayLabel: String {
        if Calendar.current.isDateInToday(planDate) { return "Today" }
        return "Tomorrow"
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .chooseDay: chooseDayStep
                case .today: todayStep
                case .inbox: inboxStep
                case .tomorrow: tomorrowStep
                }
            }
            .navigationTitle(step == .tomorrow ? "" : step.title(planDate: planDate))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if step == .tomorrow {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 0) {
                            Text(step.title(planDate: planDate))
                                .font(.headline)
                            Text("(\(planRelativeDayLabel))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                navBar
            }
            .sheet(item: $attributeReviewSession) { session in
                TaskReviewQueueSheet(
                    shelves: routableInboxShelves,
                    queue: session.queue,
                    onAllCaughtUpClose: {
                        // Review actually finished here (not an early
                        // Cancel) — no reason to make the user tap Next
                        // again on the now-redundant Inbox step, so this
                        // jumps straight into the Plan step exactly like
                        // Next would.
                        if step == .inbox { advance() }
                    }
                )
            }
            .sheet(item: $pickerTarget) { block in
                if let tomorrowViewModel {
                    ReplacementPickerSheet(
                        candidates: tomorrowViewModel.unscheduledCandidates(from: allTasks, excluding: block),
                        onPick: { chosen in
                            tomorrowViewModel.manualReplace(block, with: chosen)
                            pickerTarget = nil
                        },
                        onAuto: {
                            tomorrowViewModel.autoReplace(block, candidatePool: allTasks)
                            pickerTarget = nil
                        }
                    )
                }
            }
        }
    }

    private var navBar: some View {
        HStack {
            Button("Close") { dismiss() }
            if step != .chooseDay {
                Button("Back", action: back)
            }
            Spacer()
            if step == .tomorrow {
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Next", action: advance)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func back() {
        step = Step(rawValue: step.rawValue - 1) ?? .chooseDay
    }

    private func advance() {
        let next = Step(rawValue: step.rawValue + 1) ?? .tomorrow
        if step == .chooseDay {
            setupViewModels()
        }
        step = next
        if next == .inbox {
            startAttributeReviewSession()
        }
        if next == .tomorrow, let todayViewModel, let tomorrowViewModel {
            Task {
                // Whatever's still unchecked from the Today step is freed
                // up here — unscheduled from its stale block so it's a
                // candidate again — before the plan below gets generated,
                // so an unfinished task actually gets reconsidered for
                // tomorrow instead of just sitting stuck on a past block
                // nothing ever revisits. Scoped to `reviewCutoff`, not
                // real-now, so this still works when `reviewDate` isn't
                // today.
                await todayViewModel.clearIncompletePastBlocks(allBlocks: allBlocks, cutoff: reviewCutoff)
                // Anything still marked complete — task or habit — gets
                // swept from the calendar entirely right here, same as a
                // completed task: this is the one place that actually
                // happens (see `purgeCompletedBlocks`); a plain regenerate
                // leaves a completed block faded in place instead.
                await tomorrowViewModel.purgeCompletedBlocks()
                if tomorrowViewModel.blocks.isEmpty {
                    await tomorrowViewModel.generateProposedSchedule(shelves: allShelves, habits: allHabits, eligibleHoursWindows: eligibleHoursWindows)
                }
            }
        }
    }

    // MARK: - Step 0: Choose Day

    private var chooseDayStep: some View {
        Form {
            Section {
                Button {
                    reviewDate = Calendar.current.startOfDay(for: .now)
                } label: {
                    HStack {
                        Text("Today")
                        Spacer()
                        if Calendar.current.isDateInToday(reviewDate) {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                Button {
                    let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: .now) ?? .now
                    reviewDate = Calendar.current.startOfDay(for: yesterday)
                } label: {
                    HStack {
                        Text("Yesterday")
                        Spacer()
                        if Calendar.current.isDateInYesterday(reviewDate) {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
            } header: {
                Text("Which day are you reviewing?")
            }

            Section {
                DatePicker(
                    "Other day",
                    selection: Binding(
                        get: { reviewDate },
                        set: { reviewDate = Calendar.current.startOfDay(for: $0) }
                    ),
                    in: ...Date(),
                    displayedComponents: .date
                )
            } footer: {
                Text("Doing this in the morning for a day that already ended? Pick that day here — \"Plan Tomorrow\" will still mean the day right after it.")
            }
        }
    }

    // MARK: - Step 1: Today

    /// Where "reviewable" ends for `reviewDate` — today or any earlier day,
    /// whichever was picked in Choose Day. When `reviewDate` is today, the
    /// cutoff is `.now` itself rather than end-of-day, since a block later
    /// today hasn't happened yet and isn't reviewable; when it's an earlier
    /// day (already fully elapsed), the cutoff is that day's midnight
    /// boundary instead. Shared by `reviewableBlocks` (what the Today step
    /// shows) and `advance()` (what gets freed up for tomorrow's plan once
    /// Today is left behind).
    private var reviewCutoff: Date {
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: reviewDate) ?? reviewDate
        return min(.now, dayEnd)
    }

    /// Every block (complete or not) up through `reviewCutoff`, so a
    /// backlog left over from a busy week doesn't just quietly pile up
    /// unreviewed, but a review for a past day never leaks in blocks from
    /// today or later. `markComplete` isn't actually scoped to
    /// `todayViewModel`'s own `targetDate` internally, so reusing it here
    /// for a block from any earlier day is safe.
    private var reviewableBlocks: [ScheduledBlock] {
        allBlocks
            .filter { $0.startTime < reviewCutoff }
            .sorted { $0.startTime < $1.startTime }
    }

    @ViewBuilder
    private var todayStep: some View {
        if let todayViewModel {
            OverdueBlocksReviewList(blocks: reviewableBlocks) { block in
                todayViewModel.toggleComplete(block)
            }
        } else {
            ProgressView()
        }
    }

    // MARK: - Step 2: Inbox (walks TaskCardSheet, one task at a time)

    private var routableInboxShelves: [Shelf] {
        allShelves.filter { !$0.isPantry }
    }

    /// Leaving Today (see `advance()`) auto-launches `TaskReviewQueueSheet`
    /// over this step, so by the time it's actually visible the review is
    /// usually already done or in progress. This just covers what's left
    /// once that sheet closes: nothing further if the queue was empty or
    /// finished, or a way back in if it was cancelled early or new items
    /// showed up since.
    @ViewBuilder
    private var inboxStep: some View {
        ContentUnavailableView {
            Label("Inbox Reviewed", systemImage: "checkmark.circle")
        } description: {
            Text("Tap Next to continue, or review again below if anything's still unsorted.")
        } actions: {
            Button("Review Again", action: startAttributeReviewSession)
        }
    }

    /// Unsorted tasks first (raw brain-dump capture, oldest-added first),
    /// then shelf tasks still missing details — matches the order
    /// Task Attribute Review's standalone queue used to run in reverse,
    /// but here it's Inbox-sorting-first since that's this flow's job
    /// before "Sort Your Inbox" hands off to Plan Tomorrow. No-ops if
    /// there's nothing to review, so leaving Today doesn't pop an empty
    /// sheet.
    private func startAttributeReviewSession() {
        let unsortedTasks = allTasks.filter { $0.shelf == nil && !$0.attributeReviewExcluded }
        let shelfTasks = allTasks.filter { $0.shelf != nil && !($0.shelf!.isPantry) && $0.isMissingAttributes && !$0.attributeReviewExcluded }
        let queue = unsortedTasks + shelfTasks
        guard !queue.isEmpty else { return }
        attributeReviewSession = AttributeReviewSession(queue: queue)
    }

    // MARK: - Step 3: Tomorrow

    /// Same real time-grid as `ScheduleReviewView` — drag to move, tap to
    /// mark complete/push/delete/replace, tap a calendar event to edit it —
    /// rather than a flat read-only list, so the Plan step is the actual
    /// calendar, not a preview of it.
    @ViewBuilder
    private var tomorrowStep: some View {
        if let tomorrowViewModel {
            if tomorrowViewModel.isGenerating {
                ProgressView("Building tomorrow's schedule...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tomorrowViewModel.blocks.isEmpty {
                ContentUnavailableView {
                    Label("No Schedule Yet", systemImage: "calendar")
                } actions: {
                    Button("Generate Schedule") {
                        Task {
                            await tomorrowViewModel.generateProposedSchedule(shelves: allShelves, habits: allHabits, eligibleHoursWindows: eligibleHoursWindows)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                DayTimelineGridView(
                    rows: ScheduleReviewViewModel.timelineRows(blocks: tomorrowViewModel.blocks, calendarEvents: tomorrowViewModel.calendarEvents),
                    eligibleHoursWindows: eligibleHoursWindows,
                    namedSchedules: namedSchedules,
                    targetDate: tomorrowViewModel.targetDate,
                    lockedStore: lockedStore,
                    viewModel: tomorrowViewModel,
                    isToday: Calendar.current.isDateInToday(tomorrowViewModel.targetDate),
                    allTasks: allTasks,
                    allShelves: allShelves,
                    onSaveEvent: { updated in tomorrowViewModel.saveEventEdit(updated) },
                    onDeleteBlock: { block in tomorrowViewModel.deleteBlock(block) },
                    onPickReplacement: { block in pickerTarget = block }
                )
                .safeAreaInset(edge: .bottom) {
                    Button("Approve All") {
                        tomorrowViewModel.approveAll()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.bar)
                }
            }
        } else {
            ProgressView()
        }
    }

    private func setupViewModels() {
        guard todayViewModel == nil else { return }
        configureCalendarService()

        let today = ScheduleReviewViewModel(
            modelContext: modelContext,
            calendarService: calendarService,
            schedulingService: schedulingService,
            targetDate: reviewDate
        )
        today.loadExistingBlocks(allBlocks)
        todayViewModel = today

        let tomorrowDate = Calendar.current.date(byAdding: .day, value: 1, to: reviewDate) ?? reviewDate
        let tomorrow = ScheduleReviewViewModel(
            modelContext: modelContext,
            calendarService: calendarService,
            schedulingService: schedulingService,
            targetDate: tomorrowDate
        )
        tomorrow.loadExistingBlocks(allBlocks)
        tomorrowViewModel = tomorrow
        // Needed for the Plan step's DayTimelineGridView to tell genuinely
        // external calendar events apart from ones that already round-tripped
        // back from a previously-approved block (see
        // `ScheduleReviewViewModel.timelineRows`).
        Task { await tomorrow.loadCalendarEvents() }
    }

    private func configureCalendarService() {
        let enabledIDs = calendarSubscriptions.filter(\.isEnabled).map(\.calendarID)
        calendarService.enabledCalendarIDs = enabledIDs.isEmpty ? ["primary"] : enabledIDs
        calendarService.workingHours = (
            DateComponents(hour: 0, minute: 0),
            DateComponents(hour: 23, minute: 59)
        )
    }
}

/// A single task shown like a Tinder card: edit its key attributes right
/// on the card, tap a shelf to preview it (reveals that shelf's Eligible
/// Schedules toggles), and the bottom-right action button — the only
/// thing that actually commits anything — always saves whatever's been
/// filled in. Used identically for an unsorted task (Inbox — `shelf ==
/// nil`, any shelf pick counts as "moving" it out) and a shelf task
/// that's missing details (the Attribute Review pass): its label (see
/// `actionButtonInfo`) honestly reflects what happens next — "Save &
/// Submit"/"Save, Move & Submit" when every attribute's answered, see
/// `TaskItem.isMissingAttributes`, or a bare "Save"/"Save & Move" that
/// requeues the card to the back of the queue when something's still
/// missing, so it comes back around. Trash discards it outright.
struct TaskReviewCard: View {
    @Bindable var task: TaskItem
    let shelves: [Shelf]
    let onDiscard: () -> Void
    /// Defers this card without treating it as done — moves it to the
    /// back of the queue. See `actionRow`.
    let onSkip: () -> Void
    let onMove: (Shelf) -> Void
    /// Advances past this card because it's actually done — only
    /// reachable once `task.isMissingAttributes` is false and the task
    /// already has a shelf (an unsorted task wires this to the same
    /// requeue behavior as `onSkip`, since being attribute-complete
    /// doesn't remove it from the Inbox on its own — only a shelf
    /// assignment does).
    let onNext: () -> Void
    /// Only `TaskCardSheet` passes these — nil elsewhere hides the button
    /// entirely, so Nightly Review and Task Attribute Review are unchanged.
    let isExcludedFromAttributeReview: Bool
    let onToggleExcludeFromAttributeReview: (() -> Void)?
    /// True when a queue-cycling caller (`TaskReviewQueueSheet`) swapped
    /// this card in as the next one in line — starts it off-screen to the
    /// left so it slides into place instead of just appearing, completing
    /// the Tinder-style motion the outgoing card's `fly()` already has.
    private let entersFromLeft: Bool

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Tag.name) private var allTags: [Tag]

    @State private var newTag: String = ""
    @State private var dragOffset: CGSize
    /// Tapped once to preview and tap again to confirm moving the task
    /// there.
    @State private var selectedShelf: Shelf?
    @State private var showingDeleteConfirm = false
    @State private var toastMessage: String?
    /// Drives the flash-then-settle sequence: false is the initial "flash"
    /// instant (bright white scrim, oversized/invisible square), true is
    /// the settled state (scrim gone, square at rest). See `showToast`.
    @State private var toastVisible = false
    @State private var isShowingDatePicker = false
    /// Captured once this card's edits settle in after appearing (past any
    /// one-time backfill), so the action button can tell "nothing's been
    /// touched" (Skip) apart from "something's actually been edited" (Save
    /// Changes) — see `hasChanges` and `actionButtonInfo`.
    @State private var originalSnapshot: TaskEditSnapshot?

    private enum Field: Hashable {
        case title, nextStep, tag
    }
    /// Only the three text fields ever grab the keyboard — every other
    /// control dismisses it on tap, see each control's action below.
    @FocusState private var focusedField: Field?

    private static let durationOptions = [0, 5, 15, 30, 45, 60, 90, 120, 240, 480]
    private static let divisibleSegmentOptions = [0, 15, 30, 45, 60, 90]

    init(
        task: TaskItem,
        shelves: [Shelf],
        onDiscard: @escaping () -> Void,
        onSkip: @escaping () -> Void,
        onMove: @escaping (Shelf) -> Void,
        onNext: @escaping () -> Void,
        isExcludedFromAttributeReview: Bool = false,
        onToggleExcludeFromAttributeReview: (() -> Void)? = nil,
        entersFromLeft: Bool = false
    ) {
        self.task = task
        self.shelves = shelves
        self.onDiscard = onDiscard
        self.onSkip = onSkip
        self.onMove = onMove
        self.onNext = onNext
        self.isExcludedFromAttributeReview = isExcludedFromAttributeReview
        self.onToggleExcludeFromAttributeReview = onToggleExcludeFromAttributeReview
        self.entersFromLeft = entersFromLeft
        _dragOffset = State(initialValue: entersFromLeft ? CGSize(width: -500, height: 0) : .zero)
    }

    /// nil until "Has due date" is actually answered either way — see
    /// `YesNoToggle`.
    private var dueDateAnswer: Binding<Bool?> {
        Binding(
            get: { task.dueDateDecided ? (task.dueDate != nil) : nil },
            set: { newValue in
                focusedField = nil
                switch newValue {
                case .some(true):
                    task.dueDateDecided = true
                    task.dueDate = task.dueDate ?? .now
                case .some(false):
                    task.dueDateDecided = true
                    task.dueDate = nil
                    task.dueDatePicked = false
                case .none:
                    task.dueDateDecided = false
                    task.dueDate = nil
                    task.dueDatePicked = false
                }
            }
        )
    }


    var body: some View {
        VStack(spacing: 14) {
            card
            actionRow
        }
        .overlay {
            if let toastMessage {
                Text(toastMessage)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
                    .padding(20)
                    .frame(width: 160, height: 160)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(.quaternary))
                    .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                    .scaleEffect(toastVisible ? 1.0 : 0.96)
                    .opacity(toastVisible ? 1 : 0)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
            }
        }
        .onAppear {
            // Backfill for tasks that already had a real due date before
            // `dueDatePicked` existed. `.onAppear` only fires once for this
            // card's lifetime — unlike `init`, which SwiftUI re-runs on
            // every re-render, which would re-mark a freshly auto-filled
            // "Select Date" as picked the instant any other field changed.
            if task.dueDateDecided, task.dueDate != nil, !task.dueDatePicked {
                task.dueDatePicked = true
            }
            // Same idea for tasks with a real duration already set before
            // `durationAnsweredYes` existed — otherwise it'd read as "No"
            // (dropdown hidden) despite having an actual duration.
            if task.durationDecided, task.estimatedMinutes > 0, !task.durationAnsweredYes {
                task.durationAnsweredYes = true
            }
            // Same idea for tasks already marked divisible with a real
            // minimum segment before `isDivisibleDecided` existed.
            if task.isDivisible, task.minimumSegmentMinutes > 0, !task.isDivisibleDecided {
                task.isDivisibleDecided = true
            }
            if originalSnapshot == nil {
                originalSnapshot = TaskEditSnapshot(task)
            }
            if entersFromLeft {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    dragOffset = .zero
                }
            }
        }
    }

    /// Whether anything's actually been edited since this card appeared —
    /// backfill doesn't count (see `originalSnapshot`), and neither does
    /// merely tapping a shelf to preview it (`selectedShelf` alone, tracked
    /// separately by `actionButtonInfo`).
    private var hasChanges: Bool {
        guard let originalSnapshot else { return false }
        return TaskEditSnapshot(task) != originalSnapshot
    }

    private func showToast(_ message: String) {
        toastVisible = false
        toastMessage = message
        withAnimation(.easeOut(duration: 0.25)) {
            toastVisible = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) {
            withAnimation(.easeOut(duration: 0.3)) {
                toastMessage = nil
                toastVisible = false
            }
        }
    }

    /// The shelf whose color/schedules the card previews — whichever one is
    /// tapped-but-not-yet-confirmed in `shelfRow`, or the task's actual
    /// current shelf otherwise.
    private var previewedShelf: Shelf? {
        selectedShelf ?? task.shelf
    }

    /// Whether Due Date is currently answerable — off the moment a
    /// previewed (or actual) shelf doesn't track due dates, so the section
    /// fades and forces "No" without touching the task's real stored
    /// answer, in case the preview gets cancelled. Real clearing only
    /// happens once the move actually commits (see the `onMove` call sites).
    private var dueDatesAllowed: Bool {
        previewedShelf?.effectiveTracksDueDates ?? true
    }

    /// Same idea as `dueDatesAllowed`, for Duration and Divisible.
    private var durationAllowed: Bool {
        previewedShelf?.effectiveTracksDuration ?? true
    }

    /// Same idea as `dueDatesAllowed`, for the Next Step field.
    private var nextStepAllowed: Bool {
        previewedShelf?.effectiveTracksNextStep ?? true
    }

    /// Same idea as `dueDatesAllowed`, for the Priority section.
    private var priorityAllowed: Bool {
        previewedShelf?.effectiveTracksPriority ?? true
    }

    /// Title + Next step — stays fixed at the top of the card regardless
    /// of how much the rest of it scrolls, since those two are the
    /// identity of the task and should always be in view while editing
    /// anything below them.
    private var cardHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: $task.title, axis: .vertical)
                .font(.title3.weight(.semibold))
                .focused($focusedField, equals: .title)

            if task.pushedCount > 0 {
                Text("Pushed \(task.pushedCount) time\(task.pushedCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if nextStepAllowed {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("Next step", text: $task.nextStep, axis: .vertical)
                        .font(task.nextStep.count > 30 ? .subheadline.weight(.medium) : .body.weight(.medium))
                        .animation(.easeInOut(duration: 0.1), value: task.nextStep.count > 30)
                        .focused($focusedField, equals: .nextStep)
                    // Right next to where you're actually typing — easier
                    // to find in the moment than the accessory Done button
                    // riding above the keyboard itself.
                    if focusedField == .nextStep {
                        Button {
                            focusedField = nil
                        } label: {
                            Image(systemName: "keyboard.chevron.compact.down")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: nextStepAllowed)
        .padding(16)
        .padding(.bottom, 0)
    }

    /// Everything past Next step — due date through Eligible Schedules —
    /// in its own scroll region so a task with a lot filled in never pushes
    /// the header or the action row off-screen.
    private var cardScrollBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
            Divider()

            YesNoToggle(title: "Has due date", answer: dueDatesAllowed ? dueDateAnswer : .constant(false))
                .disabled(!dueDatesAllowed)
                .opacity(dueDatesAllowed ? 1 : 0.4)
                .animation(.easeInOut(duration: 0.15), value: task.dueDateDecided)
                .animation(.easeInOut(duration: 0.15), value: dueDatesAllowed)
            if dueDatesAllowed, dueDateAnswer.wrappedValue == true {
                HStack {
                    Button {
                        focusedField = nil
                        isShowingDatePicker = true
                    } label: {
                        Text(task.dueDatePicked ? (task.dueDate ?? .now).formatted(date: .complete, time: .omitted) : "Select Date")
                            .font(.headline)
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.secondary.opacity(0.15))
                            )
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $isShowingDatePicker) {
                        DatePicker(
                            "Due",
                            selection: Binding(
                                get: { task.dueDate ?? .now },
                                set: { newValue in
                                    task.dueDatePicked = true
                                    task.dueDate = newValue
                                    isShowingDatePicker = false
                                }
                            ),
                            displayedComponents: [.date]
                        )
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .padding(8)
                        .frame(width: 320)
                        .fixedSize(horizontal: false, vertical: true)
                        .presentationCompactAdaptation(.popover)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Priority")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach([Priority.low, .medium, .high]) { priority in
                        // Forced unselected (and disabled below) whenever
                        // the previewed/actual shelf doesn't track
                        // priority — the real stored answer is untouched.
                        let isSelected = priorityAllowed && task.priority == priority
                        Button {
                            focusedField = nil
                            task.priority = isSelected ? .unset : priority
                        } label: {
                            Text(priority.label)
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.15))
                                .foregroundStyle(isSelected ? Color.white : Color.primary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.top, 4)
            .disabled(!priorityAllowed)
            .opacity(priorityAllowed ? 1 : 0.4)
            .animation(.easeInOut(duration: 0.15), value: priorityAllowed)

            VStack(alignment: .leading, spacing: 6) {
                Text("Duration")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    // Forced to "No" (and disabled below) whenever the
                    // previewed/actual shelf doesn't track duration — the
                    // real stored answer is untouched so it comes back if
                    // the shelf preview is cancelled.
                    let isYesSelected = durationAllowed && task.durationDecided && task.durationAnsweredYes
                    let isNoSelected = !durationAllowed || (task.durationDecided && !task.durationAnsweredYes)

                    Button {
                        focusedField = nil
                        if isYesSelected {
                            // Untapping Yes clears back to unanswered
                            // and resets the picker to Not Selected.
                            task.durationDecided = false
                            task.durationAnsweredYes = false
                            task.estimatedMinutes = 0
                        } else {
                            task.durationDecided = true
                            task.durationAnsweredYes = true
                        }
                    } label: {
                        Text("Yes")
                            .font(.subheadline.weight(.semibold))
                            .frame(minWidth: 64)
                            .padding(.vertical, 9)
                            .background(isYesSelected ? Color.accentColor : Color.secondary.opacity(0.15))
                            .foregroundStyle(isYesSelected ? Color.white : Color.primary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        focusedField = nil
                        if isNoSelected {
                            task.durationDecided = false
                        } else {
                            task.durationDecided = true
                            task.durationAnsweredYes = false
                            task.estimatedMinutes = 0
                        }
                    } label: {
                        Text("No")
                            .font(.subheadline.weight(.semibold))
                            .frame(minWidth: 64)
                            .padding(.vertical, 9)
                            .background(isNoSelected ? Color.accentColor : Color.secondary.opacity(0.15))
                            .foregroundStyle(isNoSelected ? Color.white : Color.primary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    if isYesSelected {
                        Picker("Duration", selection: $task.estimatedMinutes) {
                            ForEach(Self.durationOptions, id: \.self) { minutes in
                                Text(TaskItem.durationLabel(for: minutes)).tag(minutes)
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                        .tint(Color.accentColor)
                        .onChange(of: task.estimatedMinutes) { _, _ in
                            focusedField = nil
                            task.durationDecided = true
                            task.syncScheduledBlockDuration()
                        }
                    }
                }
            }
            .padding(.top, 4)
            .disabled(!durationAllowed)
            .opacity(durationAllowed ? 1 : 0.4)
            .animation(.easeInOut(duration: 0.15), value: task.durationDecided)
            .animation(.easeInOut(duration: 0.15), value: durationAllowed)

            VStack(alignment: .leading, spacing: 6) {
                Text("Divisible")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    let isDivisibleYesSelected = durationAllowed && task.isDivisibleDecided && task.isDivisible
                    let isDivisibleNoSelected = !durationAllowed || (task.isDivisibleDecided && !task.isDivisible)

                    Button {
                        focusedField = nil
                        if isDivisibleYesSelected {
                            // Untapping Yes clears back to unanswered
                            // and resets the picker to Not Selected.
                            task.isDivisibleDecided = false
                            task.isDivisible = false
                            task.minimumSegmentMinutes = 0
                        } else {
                            task.isDivisibleDecided = true
                            task.isDivisible = true
                        }
                    } label: {
                        Text("Yes")
                            .font(.subheadline.weight(.semibold))
                            .frame(minWidth: 64)
                            .padding(.vertical, 9)
                            .background(isDivisibleYesSelected ? Color.accentColor : Color.secondary.opacity(0.15))
                            .foregroundStyle(isDivisibleYesSelected ? Color.white : Color.primary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        focusedField = nil
                        if isDivisibleNoSelected {
                            task.isDivisibleDecided = false
                        } else {
                            task.isDivisibleDecided = true
                            task.isDivisible = false
                            task.minimumSegmentMinutes = 0
                        }
                    } label: {
                        Text("No")
                            .font(.subheadline.weight(.semibold))
                            .frame(minWidth: 64)
                            .padding(.vertical, 9)
                            .background(isDivisibleNoSelected ? Color.accentColor : Color.secondary.opacity(0.15))
                            .foregroundStyle(isDivisibleNoSelected ? Color.white : Color.primary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    if isDivisibleYesSelected {
                        Picker("Minimum Segment", selection: $task.minimumSegmentMinutes) {
                            ForEach(Self.divisibleSegmentOptions, id: \.self) { minutes in
                                Text(TaskItem.durationLabel(for: minutes)).tag(minutes)
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                        .tint(Color.accentColor)
                        .onChange(of: task.minimumSegmentMinutes) { _, _ in
                            focusedField = nil
                        }
                    }
                }
            }
            .padding(.top, 4)
            .disabled(!durationAllowed)
            .opacity(durationAllowed ? 1 : 0.4)
            .animation(.easeInOut(duration: 0.15), value: task.isDivisibleDecided)
            .animation(.easeInOut(duration: 0.15), value: durationAllowed)

            if !task.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(task.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                }
            }
            HStack {
                Image(systemName: "tag")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("Add tag", text: $newTag)
                    .submitLabel(.done)
                    .onSubmit(addTag)
                    .font(.subheadline)
                    .focused($focusedField, equals: .tag)
                Button("Add", action: addTag)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            // Autocomplete against the saved tag box — tapping one adds it
            // outright instead of just filling the field in.
            if !tagSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(tagSuggestions) { tag in
                            Button {
                                newTag = tag.name
                                addTag()
                            } label: {
                                Text(tag.name)
                                    .font(.caption2)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.secondary.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Divider()
            shelfRow

            if let rules = previewedShelf?.schedulingRules, !rules.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Eligible Schedules")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(rules.sorted { $0.sortOrder < $1.sortOrder }) { rule in
                        let fits = rule.canEverFit(minutesNeeded: task.estimatedMinutes, isDivisible: task.isDivisible)
                        HStack(spacing: 10) {
                            Toggle(
                                isOn: Binding(
                                    get: { task.isEligible(for: rule) },
                                    set: { focusedField = nil; task.setEligible($0, for: rule) }
                                )
                            ) {
                                EmptyView()
                            }
                            .labelsHidden()
                            .tint(.green)
                            .disabled(!fits)

                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(rule.displayName.isEmpty ? rule.summary : rule.displayName)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    if !rule.displayName.isEmpty {
                                        Text(rule.summary)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                    }
                                }
                                if !fits {
                                    Text("Exceeds time constraint")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer(minLength: 0)
                        }
                        .opacity(fits ? 1 : 0.4)
                    }
                }
            }
            }
            .padding(16)
            .padding(.top, 0)
        }
        .frame(maxHeight: .infinity)
        .scrollDismissesKeyboard(.interactively)
    }

    /// The visible "Tinder card" — a fixed header on top and everything
    /// else scrolling underneath it, sharing one rounded background so it
    /// still reads as a single card. Swipe-to-advance stays on the whole
    /// thing, header included, not just the scrolling part.
    private var card: some View {
        VStack(spacing: 10) {
            cardHeader
            cardScrollBody
        }
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 20).fill((previewedShelf?.color ?? Color.secondary).opacity(0.18)))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.quaternary))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .padding(.horizontal, 24)
        .offset(dragOffset)
        .rotationEffect(.degrees(dragOffset.width / 20))
        .gesture(
            DragGesture()
                .onChanged { value in dragOffset = value.translation }
                .onEnded { value in
                    if abs(value.translation.width) > 120 {
                        fly(direction: value.translation.width > 0 ? 1 : -1, action: advance)
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            dragOffset = .zero
                        }
                    }
                }
        )
    }

    /// What Next/Skip (or a flick either direction) actually does — a
    /// shelf picked in `shelfRow` is only ever committed here, never on
    /// the tap that selected it, so this is the one place that can move
    /// the task at all.
    private func advance() {
        if let selectedShelf, selectedShelf.id != task.shelf?.id {
            onMove(selectedShelf)
        } else if task.isMissingAttributes {
            onSkip()
        } else {
            onNext()
        }
    }

    private var shelfRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(shelves) { shelf in
                    let isCurrent = task.shelf?.id == shelf.id
                    let isSelected = selectedShelf?.id == shelf.id
                    Button {
                        focusedField = nil
                        withAnimation(.easeInOut(duration: 0.15)) {
                            // Tapping the already-selected shelf (or the
                            // current one) clears the pick — just previews,
                            // never moves on its own. Next/Skip is what
                            // actually commits it.
                            if isSelected || isCurrent {
                                selectedShelf = nil
                            } else {
                                selectedShelf = shelf
                                // Defaults every one of the newly-previewed
                                // shelf's enabled rules to on immediately —
                                // matching what actually landing on this
                                // shelf will end up with — so the Eligible
                                // Schedules toggles below read correctly
                                // from the very first tap, and any turned
                                // off here sticks through to the commit
                                // (see `onMove`, which no longer re-seeds
                                // this itself).
                                task.includedSchedulingRuleIDs = (shelf.schedulingRules ?? []).filter(\.isEnabled).map(\.id)
                            }
                        }
                    } label: {
                        Image(systemName: shelf.systemImage)
                            .font(.body)
                            .frame(width: 38, height: 38)
                            .background(shelf.color.opacity(isSelected ? 0.5 : 0.2))
                            .clipShape(Circle())
                            .overlay {
                                if isSelected {
                                    Circle().stroke(shelf.color, lineWidth: 3)
                                } else if isCurrent {
                                    Circle().stroke(shelf.color.opacity(0.6), lineWidth: 1.5)
                                }
                            }
                            .overlay(alignment: .topTrailing) {
                                if isCurrent && !isSelected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.caption2)
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, shelf.color)
                                        .background(Circle().fill(.background))
                                        .offset(x: 2, y: -2)
                                }
                            }
                            .scaleEffect(isSelected ? 1.1 : 1.0)
                            .animation(.easeInOut(duration: 0.15), value: isSelected)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(shelf.name)
                }
            }
            .padding(.vertical, 4)
            .padding(.leading, 20)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 16) {
            Button {
                focusedField = nil
                showingDeleteConfirm = true
            } label: {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .confirmationDialog(
                "Delete this task?",
                isPresented: $showingDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    fly(direction: -1, action: onDiscard)
                }
            } message: {
                Text(task.title.isEmpty ? "This can't be undone." : "\"\(task.title)\" can't be recovered after this.")
            }

            // Silencing only means something once this task has a shelf to
            // be reviewed on — hidden for a plain Inbox task, but reappears
            // the moment one's previewed via `shelfRow`, since committing
            // that move is exactly what makes it apply.
            if let onToggleExcludeFromAttributeReview, task.shelf != nil || selectedShelf != nil {
                Button {
                    focusedField = nil
                    onToggleExcludeFromAttributeReview()
                    showToast(
                        task.attributeReviewExcluded
                            ? "Excluded from Task Attribute Review"
                            : "Included in Task Attribute Review again"
                    )
                } label: {
                    if isExcludedFromAttributeReview {
                        Image(systemName: "bell.slash.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(Color.gray.opacity(0.5))
                    } else {
                        Image(systemName: "bell.circle.fill")
                            .font(.system(size: 36))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.black, Color(red: 0.79, green: 0.64, blue: 0.14))
                    }
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Button {
                focusedField = nil
                fly(direction: 1, action: advance)
            } label: {
                VStack(alignment: .trailing, spacing: 2) {
                    Label(actionButtonInfo.label, systemImage: actionButtonInfo.icon)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(actionButtonInfo.color)
                    if let subtitle = actionButtonInfo.subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
    }

    /// What the action button actually says and does — always matches
    /// `advance()`. Complete attributes always end in "...Submit" (moving
    /// or not); incomplete ones distinguish moving ("Save & Move") from
    /// not, and — only when not moving — whether anything was actually
    /// edited at all ("Skip" if not, "Save Changes" if so), so a card left
    /// untouched reads honestly as skipped rather than implying edits that
    /// never happened.
    private var actionButtonInfo: (label: String, subtitle: String?, icon: String, color: Color) {
        // Against the previewed shelf, not necessarily the task's actual
        // one — so previewing a shelf that (say) doesn't track Next Step
        // drops it from "Remaining Attributes" immediately, matching the
        // section fading/disappearing on the card above.
        let missing = task.missingAttributeNames(consideringShelf: previewedShelf)
        let isComplete = missing.isEmpty
        let isMoving = selectedShelf != nil && selectedShelf?.id != task.shelf?.id
        let remainingText = "Remaining Attributes: \(missing.joined(separator: ", "))"
        if isComplete {
            return isMoving
                ? ("Save, Move & Submit", nil, "arrow.right.circle.fill", selectedShelf!.color)
                : ("Save & Submit", nil, "checkmark.circle.fill", .green)
        }
        if isMoving {
            // Gray like Save Changes/Skip below — only a "...Submit" label
            // (both cases above) gets its own color; every other outcome
            // reads as a neutral, still-incomplete save.
            return ("Save & Move", remainingText, "arrow.right.circle.fill", .secondary)
        }
        return hasChanges
            ? ("Save Changes", remainingText, "arrow.uturn.right.circle.fill", .secondary)
            : ("Skip", remainingText, "arrow.uturn.right.circle.fill", .secondary)
    }

    /// Saved tags matching what's typed so far, minus whatever's already
    /// on this task — tapping one adds it directly rather than just
    /// filling the field in for you to hit Add yourself.
    private var tagSuggestions: [Tag] {
        let trimmed = newTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }
        return allTags.filter { $0.name.lowercased().contains(trimmed) && !task.tags.contains($0.name) }
    }

    private func addTag() {
        focusedField = nil
        let trimmed = newTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, !task.tags.contains(trimmed) else {
            newTag = ""
            return
        }
        task.tags.append(trimmed)
        // A genuinely new name (not already in the tag box) gets added
        // there too — unreviewed by default, so it surfaces at the end of
        // Task Attribute Review until it's dealt with (see
        // `TaskReviewQueueSheet`).
        if !allTags.contains(where: { $0.name.lowercased() == trimmed }) {
            modelContext.insert(Tag(name: trimmed))
        }
        newTag = ""
    }

    /// Flicks the card off-screen in `direction` (-1 left, 1 right), then
    /// performs the real action once the flight animation clears the
    /// screen — the visual "card leaves the stack" beat before the model
    /// actually changes underneath it.
    private func fly(direction: CGFloat, action: @escaping () -> Void) {
        withAnimation(.easeIn(duration: 0.2)) {
            dragOffset = CGSize(width: direction * 500, height: dragOffset.height)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            action()
        }
    }
}

#Preview {
    NightlyReviewView()
        .modelContainer(for: [TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self, Habit.self, HabitLog.self], inMemory: true)
}
