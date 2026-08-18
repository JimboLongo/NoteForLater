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

    @State private var step: Step = .chooseDay
    /// The day being reviewed — defaults to today, but overridable (e.g.
    /// doing this in the morning for a day that already ended). "Plan
    /// Tomorrow" always means the day right after whichever day this is,
    /// not calendar-tomorrow-from-right-now — reviewing yesterday's
    /// schedule this morning should plan *today*, not tomorrow.
    @State private var reviewDate: Date = Calendar.current.startOfDay(for: .now)
    /// Guards the one-time default-to-Yesterday nudge in `chooseDayStep`'s
    /// `.onAppear` — set the instant that runs, so it never overrides a
    /// choice the user made themselves (including navigating Back to this
    /// step and re-picking Today).
    @State private var hasAppliedDefaultReviewDate = false
    @State private var todayViewModel: ScheduleReviewViewModel?
    @State private var tomorrowViewModel: ScheduleReviewViewModel?
    /// Drives the Inbox step — presenting `TaskReviewQueueSheet` (the same
    /// Task Attribute Review flow reachable from the Inbox screen) rather
    /// than a separate hand-rolled queue, so leaving Today automatically
    /// launches it instead of landing on a bespoke mini-flow that happens
    /// to do almost the same thing.
    @State private var attributeReviewSession: AttributeReviewSession?
    /// Snapshotted the moment the 2-Minute Tasks step is entered (see
    /// `advance()`) rather than computed live off `!task.isCompleted` — so
    /// checking a task off leaves it in the list, strikethrough, instead of
    /// yanking it out from under the user mid-review.
    @State private var twoMinuteReviewTaskIDs: Set<UUID> = []
    /// Every habit occurrence id toggled complete during the Today step —
    /// passed as `alsoInclude` to `openHabitOccurrencesForReview` so
    /// checking one off leaves it in the list, faded and struck through,
    /// the same reasoning as `twoMinuteReviewTaskIDs` just above (and
    /// `ScheduleReviewView`'s own copy of this same pattern) instead of it
    /// vanishing the instant its status leaves `.none`. Reset whenever a
    /// different day gets picked, since it's meaningless for any other one.
    @State private var pastReviewCompletedHabitOccurrenceIDs = Set<String>()
    /// Drives the Plan step's Replace-Task sheet — same
    /// `ReplacementPickerSheet` the regular calendar view uses (see
    /// `ScheduleReviewView`).
    @State private var pickerTarget: ScheduledBlock?
    @State private var lockedStore = LockedEventsStore.shared
    /// Session-local only, never persisted — see §7.1's requirement that
    /// "acknowledge" not be durable state (a persisted ack is one more
    /// flag that can go stale). Resolved the same way extending/clearing
    /// the due date does: the task drops off `atRiskTasks`, just without
    /// touching the task itself.
    @State private var acknowledgedAtRiskTaskIDs: Set<UUID> = []
    @State private var atRiskTaskCardTarget: TaskItem?

    private let calendarService: CalendarServiceProtocol = GoogleCalendarService()
    private let schedulingService: AISchedulingServiceProtocol = MockAISchedulingService()

    private enum Step: Int, CaseIterable {
        case chooseDay, today, inbox, twoMinuteTasks, tomorrow, atRisk

        /// `planDate` is only meaningful for `.tomorrow` — the day right
        /// after whichever day was picked in Choose Day, not
        /// calendar-tomorrow-from-right-now — so its title can name that
        /// day explicitly instead of just saying "Tomorrow".
        func title(planDate: Date) -> String {
            switch self {
            case .chooseDay: return "Which Day?"
            case .today: return "Review Schedule"
            case .inbox: return "Sort Your Inbox"
            case .twoMinuteTasks: return "2-Minute Tasks"
            case .tomorrow:
                let formatter = DateFormatter()
                formatter.dateFormat = "EEE MMMM d, yyyy"
                return "Plan for \(formatter.string(from: planDate))"
            case .atRisk: return "At Risk"
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
                case .twoMinuteTasks: twoMinuteTasksStep
                case .tomorrow: tomorrowStep
                case .atRisk: atRiskStep
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
            .sheet(item: $atRiskTaskCardTarget) { task in
                TaskCardSheet(task: task, shelves: routableInboxShelves)
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
            if step == .atRisk {
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
        let next = Step(rawValue: step.rawValue + 1) ?? .atRisk
        if step == .chooseDay {
            setupViewModels()
        }
        // §7.1: skipped entirely when empty, rather than shown with
        // nothing in it and a "tap Next to continue" — the only step in
        // this flow that behaves this way, since unlike Inbox/2-Minute-
        // Tasks there's nothing actionable to confirm when nothing's at
        // risk.
        if next == .atRisk, atRiskTasks.isEmpty {
            dismiss()
            return
        }
        step = next
        if next == .inbox {
            startAttributeReviewSession()
        }
        if next == .twoMinuteTasks {
            let pending = (twoMinuteShelf?.tasks ?? []).filter { !$0.isCompleted && $0.isEligibleToStart(on: reviewDate) }
            twoMinuteReviewTaskIDs = Set(pending.map(\.id))
        }
        if next == .inbox, let todayViewModel, let tomorrowViewModel {
            // §7.2: this whole batch runs "on Next from the Today step,"
            // i.e. right here on the today→inbox transition, not deferred
            // all the way to the tomorrow handoff below. Freeze exactly
            // what `reviewItems` represented at this exact synchronous
            // moment before anything else (Inbox routing, in particular)
            // can touch it — see `TaskItem.isNightlyReviewed`'s own doc
            // comment for why a live re-derive isn't safe across the
            // async gap below.
            let reviewedBlocks = reviewableBlocks
            let frozenCutoff = reviewCutoff
            let frozenAllBlocks = allBlocks
            for block in reviewedBlocks {
                block.task?.isNightlyReviewed = true
            }
            // Captured now, before `purgeCompletedBlocks` clears each
            // purged block's own `task` reference to nil below — a
            // recurring task survives its block being purged (only a
            // non-recurring one is deleted outright), so it's the one
            // case that needs its stamp explicitly reset afterward.
            let recurringCompletedTasks = reviewedBlocks.filter(\.isCompleted).compactMap(\.task).filter(\.isRecurring)
            let incompleteTasks = reviewedBlocks.filter { !$0.isCompleted }.compactMap(\.task)

            // Any habit occurrence the Today review showed but never got
            // checked off — timed or not — is done being reviewable the
            // moment Today is left behind, so it's marked missed right
            // here, synchronously, before any of the async cleanup below.
            // Deliberately not folded into `clearIncompletePastBlocks`
            // itself (used here too, just below) — that function is also
            // what the plain intra-day Regenerate flow calls, where a
            // passed-but-undone habit should still get a fresh shot later
            // *today*, not be written off; only Nightly Review's own
            // end-of-day handoff means "no more chances left."
            markUnresolvedHabitOccurrencesAsMissed()
            // Closes `reviewDate` out for `ScheduleReviewViewModel
            // .autoPlaceEligibleTasks`'s own live auto-place walk — once
            // tonight's review has actually run, today's remaining free
            // hours stop being fair game for a brand-new task to land on,
            // same as if the day had already ended. Set synchronously,
            // right alongside the habit sweep above, not buried in the
            // Task below — this is the moment today is actually closed,
            // not an incidental side effect of the async cleanup.
            NightlyReviewCompletionState.shared.markReviewed(day: reviewDate)
            Task {
                // Complete → swept from the calendar entirely, same as
                // every other completed block; this is the one place that
                // actually happens (see `purgeCompletedBlocks`) — a plain
                // regenerate leaves a completed block faded in place
                // instead.
                await tomorrowViewModel.purgeCompletedBlocks()
                for task in recurringCompletedTasks {
                    task.isNightlyReviewed = false
                }
                // Incomplete → unscheduled from its stale block so it's a
                // real candidate again, restoring `remainingMinutes`, then
                // un-stamped so it re-enters tomorrow's plan as an
                // ordinary task rather than staying marked as still
                // "mid-review." Uses the frozen cutoff/blocks captured
                // above, not a live re-read, for the same reason the
                // stamping itself happened synchronously before this Task
                // even started.
                await todayViewModel.clearIncompletePastBlocks(allBlocks: frozenAllBlocks, cutoff: frozenCutoff)
                for task in incompleteTasks {
                    task.isNightlyReviewed = false
                }
                // Unconditional — today's (and any prior day's) unfinished
                // tasks were just freed up above, and they need an actual
                // following day to land on. `regenerateFromNow`, not
                // `regenerateSingleDay` (doesn't exist — see §6.3),
                // walking forward until everything schedulable has a real
                // slot. A locked block on a present or future day is
                // never touched by any of this — but a locked *past*
                // incomplete block already was, eleven lines up: §7.3
                // deliberately strips lock protection once a block's own
                // day is over (see `clearIncompletePastBlocks`).
                let completedFully = await tomorrowViewModel.regenerateFromNow(shelves: allShelves, habits: allHabits, eligibleHoursWindows: eligibleHoursWindows)
                if completedFully {
                    ScheduleDirtyState.shared.isDirty = false
                }
            }
        }
        if next == .tomorrow, let tomorrowViewModel {
            // The Inbox step just left can route tasks onto a shelf via
            // `TaskReviewCard.advance()`, which already sets
            // `ScheduleDirtyState.shared.isDirty` (see §6.1) — so this
            // only re-runs the full walk when Inbox routing (or anything
            // else) actually happened. A session with no Inbox routing
            // skips this second walk entirely; the one above already
            // covers everything that mattered.
            if ScheduleDirtyState.shared.isDirty {
                Task {
                    let completedFully = await tomorrowViewModel.regenerateFromNow(shelves: allShelves, habits: allHabits, eligibleHoursWindows: eligibleHoursWindows)
                    if completedFully {
                        ScheduleDirtyState.shared.isDirty = false
                    }
                }
            }
        }
    }

    // MARK: - Step 0: Choose Day

    /// Any incomplete task block or open habit occurrence dated strictly
    /// before today — what decides whether Yesterday is even worth
    /// offering as a choice (see `hasAppliedDefaultReviewDate`'s use of
    /// this) and whether its button is enabled at all.
    private var hasAnythingToReviewBeforeToday: Bool {
        let startOfToday = Calendar.current.startOfDay(for: .now)
        let hasBlocks = allBlocks.contains { !$0.isCompleted && $0.startTime < startOfToday }
        let hasHabits = ScheduleReviewViewModel.hasOpenHabitOccurrences(habits: allHabits, upTo: startOfToday)
        return hasBlocks || hasHabits
    }

    private var chooseDayStep: some View {
        Form {
            Section {
                Button {
                    let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: .now) ?? .now
                    reviewDate = Calendar.current.startOfDay(for: yesterday)
                } label: {
                    HStack {
                        Text("Yesterday")
                            .foregroundStyle(hasAnythingToReviewBeforeToday ? .white : .secondary)
                        Spacer()
                        if Calendar.current.isDateInYesterday(reviewDate) {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .disabled(!hasAnythingToReviewBeforeToday)
                Button {
                    reviewDate = Calendar.current.startOfDay(for: .now)
                } label: {
                    HStack {
                        Text("Today")
                            .foregroundStyle(.white)
                        Spacer()
                        if Calendar.current.isDateInToday(reviewDate) {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
            } header: {
                Text("Which day are you reviewing?")
            } footer: {
                if !hasAnythingToReviewBeforeToday {
                    Text("Nothing left to review from before today.")
                }
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
        .onChange(of: reviewDate) { _, _ in
            pastReviewCompletedHabitOccurrenceIDs = []
        }
        .onAppear {
            // Only ever applied once — after this, whatever the user
            // picked (including manually re-selecting Today) sticks, even
            // if they navigate back to this step later.
            guard !hasAppliedDefaultReviewDate else { return }
            hasAppliedDefaultReviewDate = true
            guard hasAnythingToReviewBeforeToday else { return }
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: .now) ?? .now
            reviewDate = Calendar.current.startOfDay(for: yesterday)
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

    /// Every block (complete or not) up through `reviewCutoff`, plus any
    /// block already marked complete no matter how far out it's dated — a
    /// task knocked out ahead of its scheduled day shouldn't have to wait
    /// for that future day's own review to get checked off here. So a
    /// backlog left over from a busy week doesn't just quietly pile up
    /// unreviewed, but a review for a past day never leaks in an
    /// *incomplete* block from today or later. `markComplete` isn't
    /// actually scoped to `todayViewModel`'s own `targetDate` internally,
    /// so reusing it here for a block from any earlier or later day is safe.
    private var reviewableBlocks: [ScheduledBlock] {
        allBlocks
            .filter { $0.startTime < reviewCutoff || $0.isCompleted }
            .sorted { $0.startTime < $1.startTime }
    }

    /// Blocks and open habit occurrences mixed into one list, organized by
    /// time within each day — see `ReviewItem`/`OverdueBlocksReviewList`.
    private var reviewItems: [ReviewItem] {
        reviewableBlocks.map { .block($0) } + openHabitOccurrencesForReview.map { .habit($0) }
    }

    @ViewBuilder
    private var todayStep: some View {
        if let todayViewModel {
            OverdueBlocksReviewList(items: reviewItems) { item in
                switch item {
                case .block(let block):
                    todayViewModel.toggleComplete(block)
                case .habit(let occurrence):
                    pastReviewCompletedHabitOccurrenceIDs.insert(occurrence.id)
                    toggleHabitReviewOccurrence(habit: occurrence.habit, index: occurrence.index, isCompleted: occurrence.isCompleted, day: occurrence.targetTime)
                }
            }
        } else {
            ProgressView()
        }
    }

    /// An AM/Midday/PM habit occurrence (see `HabitOccurrenceTimeMode`)
    /// never gets a `ScheduledBlock` at all, so it'd otherwise be
    /// invisible to `reviewableBlocks` — a Specific-Time occurrence
    /// doesn't need this, it already shows up as a real block. See
    /// `ScheduleReviewViewModel.openHabitOccurrencesForReview` (this just
    /// supplies `reviewCutoff` — same cutoff `reviewableBlocks` already
    /// uses — and `pastReviewCompletedHabitOccurrenceIDs`, so a just-
    /// checked-off occurrence stays visible, faded and struck through,
    /// instead of vanishing the instant it leaves `.none`).
    private var openHabitOccurrencesForReview: [HabitReviewOccurrence] {
        ScheduleReviewViewModel.openHabitOccurrencesForReview(
            habits: allHabits,
            upTo: reviewCutoff,
            alsoInclude: pastReviewCompletedHabitOccurrenceIDs
        )
    }

    /// Mirrors `DayTimelineGridView.toggleHabitOccurrence` — both
    /// directions (checking and un-checking) — scoped to the occurrence's
    /// own day (`occurrence.targetTime`, backlog or not) rather than
    /// always `reviewDate`, now that `openHabitOccurrencesForReview` can
    /// surface an occurrence from an earlier day.
    private func toggleHabitReviewOccurrence(habit: Habit, index: Int, isCompleted: Bool, day: Date) {
        habitLog(for: habit, on: day).setOccurrence(index, to: isCompleted ? .none : .complete)
        HabitStatsRefreshCoordinator.shared.habitLogsChanged()
    }

    /// Finds (or creates) the `HabitLog` for `habit` on `day` — shared by
    /// `toggleHabitReviewOccurrence` and `markUnresolvedHabitOccurrencesAsMissed`.
    private func habitLog(for habit: Habit, on day: Date) -> HabitLog {
        let calendar = Calendar.current
        let normalizedDay = calendar.startOfDay(for: day)
        if let existing = habit.log(on: normalizedDay, calendar: calendar) {
            return existing
        }
        let newLog = HabitLog(habit: habit, date: normalizedDay)
        modelContext.insert(newLog)
        return newLog
    }

    /// Marks every still-open (`.none`) habit occurrence the Today review
    /// showed — timed (a `reviewableBlocks` habit block left incomplete)
    /// or untimed (`openHabitOccurrencesForReview`) — as missed. See the
    /// call site in `advance()` for why this only happens here rather
    /// than in the shared block-clearing helpers.
    private func markUnresolvedHabitOccurrencesAsMissed() {
        for block in reviewableBlocks {
            guard let habit = block.habit, !block.isCompleted else { continue }
            habitLog(for: habit, on: block.date).setOccurrence(block.habitOccurrenceIndex, to: .missed)
        }
        for occurrence in openHabitOccurrencesForReview where !occurrence.isCompleted {
            habitLog(for: occurrence.habit, on: occurrence.targetTime).setOccurrence(occurrence.index, to: .missed)
        }
        HabitStatsRefreshCoordinator.shared.habitLogsChanged()
    }

    // MARK: - Step 2: Inbox (walks TaskCardSheet, one task at a time)

    private var routableInboxShelves: [Shelf] {
        allShelves.filter { !$0.isKitchen }
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
        // Excludes anything already marked complete — including a task the
        // Today step above just checked off, moments before this queue
        // gets built (see `advance()`) — so finishing something during
        // Today doesn't turn around and ask you to fill in its attributes
        // right after.
        let unsortedTasks = allTasks.filter { $0.shelf == nil && !$0.isCompleted && !$0.isSnoozedFromAttributeReview }
        // A task also lands here once its own "Remind Me In" timer is up
        // (see `TaskItem.isDueForFutureReminder`) — independent of
        // `isMissingAttributes`, since a reminder can be set on an
        // otherwise fully-filled-out task that just needs a future
        // second look.
        let shelfTasks = allTasks.filter {
            $0.shelf != nil && !($0.shelf!.isKitchen) && !$0.isCompleted && !$0.isSnoozedFromAttributeReview
                && ($0.isMissingAttributes || $0.isDueForFutureReminder)
        }
        let queue = unsortedTasks + shelfTasks
        guard !queue.isEmpty else { return }
        attributeReviewSession = AttributeReviewSession(queue: queue)
    }

    // MARK: - Step 3: 2-Minute Tasks

    private var twoMinuteShelf: Shelf? {
        allShelves.first { $0.isTwoMinuteTasks }
    }

    /// The tasks snapshotted into `twoMinuteReviewTaskIDs` when this step
    /// was entered, oldest first — a fixed list for the duration of the
    /// step so checking one off doesn't yank it out from under the user.
    private var twoMinuteReviewTasks: [TaskItem] {
        allTasks
            .filter { twoMinuteReviewTaskIDs.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    @ViewBuilder
    private var twoMinuteTasksStep: some View {
        if twoMinuteShelf == nil {
            ContentUnavailableView {
                Label("No 2-Minute Task Shelf", systemImage: "2.circle")
            } description: {
                Text("Mark a shelf as your permanent 2-Minute Task shelf (from its settings) to use this step.")
            }
        } else if twoMinuteReviewTasks.isEmpty {
            ContentUnavailableView {
                Label("All Clear", systemImage: "checkmark.circle")
            } description: {
                Text("No 2-minute tasks left. Tap Next to continue.")
            }
        } else {
            List {
                Section {
                    ForEach(twoMinuteReviewTasks) { task in
                        twoMinuteTaskRow(task)
                    }
                } footer: {
                    Text("Knock these out right now and check them off. Anything still unchecked goes to the very top of tomorrow's schedule — ahead of everything else, habits included.")
                }
            }
        }
    }

    private func twoMinuteTaskRow(_ task: TaskItem) -> some View {
        HStack(spacing: 12) {
            twoMinuteSelectionCircle(isSelected: task.isCompleted)
                .contentShape(Rectangle())
                .onTapGesture {
                    task.setCompleted(!task.isCompleted, in: modelContext)
                    // A completed 2-minute task shouldn't claim a slot in
                    // tomorrow's schedule (see this step's own footer
                    // text) — a gap in the established per-call-site
                    // pattern (every other `setCompleted`/`markComplete`
                    // call site in the app already sets this; this one
                    // didn't).
                    ScheduleDirtyState.shared.isDirty = true
                }
            Text(task.title)
                .strikethrough(task.isCompleted)
            Spacer()
        }
        .opacity(task.isCompleted ? 0.5 : 1)
    }

    private func twoMinuteSelectionCircle(isSelected: Bool) -> some View {
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

    // MARK: - Step 4: Tomorrow

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
                    targetDate: tomorrowViewModel.targetDate,
                    lockedStore: lockedStore,
                    viewModel: tomorrowViewModel,
                    isToday: Calendar.current.isDateInToday(tomorrowViewModel.targetDate),
                    allTasks: allTasks,
                    allShelves: allShelves,
                    allHabits: allHabits,
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

    // MARK: - Step 5: At Risk

    /// Live, not snapshotted — unlike `twoMinuteReviewTaskIDs`, a task
    /// resolving (extended/cleared due date, or acknowledged) is supposed
    /// to drop off this list immediately, not linger for the rest of the
    /// step. `isAtRisk()` itself already excludes anything without a
    /// real picked due date (§5.3/§4 correction) and anything whose slack
    /// is still non-negative.
    private var atRiskTasks: [TaskItem] {
        allTasks.filter { $0.isAtRisk() && !acknowledgedAtRiskTaskIDs.contains($0.id) }
    }

    @ViewBuilder
    private var atRiskStep: some View {
        if atRiskTasks.isEmpty {
            ContentUnavailableView {
                Label("Nothing At Risk", systemImage: "checkmark.shield")
            } description: {
                Text("Every task with a due date has a real path to get there.")
            }
        } else {
            List {
                Section {
                    ForEach(atRiskTasks) { task in
                        atRiskTaskRow(task)
                    }
                } footer: {
                    Text("These won't make their due date at the current pace. Extend it, clear it, or open the task to see what's actually blocking it.")
                }
            }
        }
    }

    private func atRiskTaskRow(_ task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(task.title)
                .font(.body.weight(.medium))
            if let blocker = task.atRiskBlocker() {
                Label(blocker, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack(spacing: 8) {
                Button("Open") { atRiskTaskCardTarget = task }
                Button("Extend +1 Day") { extendDueDate(task) }
                Button("Clear Due Date") { clearDueDate(task) }
                Button("Acknowledge") { acknowledgedAtRiskTaskIDs.insert(task.id) }
                    .tint(.secondary)
            }
            .buttonStyle(.bordered)
            .font(.caption)
        }
        .padding(.vertical, 4)
    }

    /// Pushes the deadline forward from wherever it currently sits, not
    /// from `.now` — repeated taps keep moving it further out rather than
    /// snapping back to "one day from today" each time. A schedule-
    /// affecting edit per §6.1, so it has to set the dirty flag itself
    /// (see the same pattern at every other Model-mutating View call site
    /// in this file).
    private func extendDueDate(_ task: TaskItem) {
        let calendar = Calendar.current
        task.dueDate = calendar.date(byAdding: .day, value: 1, to: task.dueDate ?? .now)
        ScheduleDirtyState.shared.isDirty = true
    }

    /// Mirrors `dueDateAnswer`'s own "Has due date → No" case exactly
    /// (see `TaskReviewCard`) — the canonical way this app already clears
    /// a due date, just reached from a different screen.
    private func clearDueDate(_ task: TaskItem) {
        task.dueDateDecided = true
        task.dueDate = nil
        task.dueDatePicked = false
        ScheduleDirtyState.shared.isDirty = true
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
    /// `nil` days = clear an existing snooze; otherwise the number of days
    /// from right now to exclude this task from Task Attribute Review and
    /// Nightly Review's attribute-cleanup step.
    let onSnooze: ((Int?) -> Void)?
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
    @State private var isShowingStartDatePicker = false
    @State private var isShowingRecurrenceEndDatePicker = false
    @State private var isShowingSnoozeWheel = false
    @State private var snoozeDays = 1
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

    /// The short, curated list — not every 15-minute increment, just the
    /// sizes actually worth picking from directly. See `durationWheelOptions`
    /// below for why this alone isn't always enough.
    private static let durationOptions = [15, 30, 45, 60, 90, 120, 240, 480]
    /// Not a uniform step — these are the actual chunk sizes worth
    /// offering for a divisible task's minimum segment.
    private static let divisibleSegmentOptions = [15, 30, 45, 60, 90, 120, 240]

    /// `durationOptions`, plus the task's own current value slotted in if
    /// it isn't already one of them — a divisible task's remaining time
    /// after part of it's already been scheduled (4 hours minus a
    /// 30-minute chunk = 3h 30m) is arithmetic, not a pick from the
    /// curated list, and would otherwise land on a value the wheel
    /// doesn't have, which is exactly what broke the picker before.
    /// Keeping the option list short everywhere else while still
    /// guaranteeing the current value is always selectable.
    private var durationWheelOptions: [Int] {
        var options = Self.durationOptions
        if !options.contains(2) {
            options.insert(2, at: 0)
        }
        guard task.estimatedMinutes > 0, !options.contains(task.estimatedMinutes) else {
            return options
        }
        return (options + [task.estimatedMinutes]).sorted()
    }

    init(
        task: TaskItem,
        shelves: [Shelf],
        onDiscard: @escaping () -> Void,
        onSkip: @escaping () -> Void,
        onMove: @escaping (Shelf) -> Void,
        onNext: @escaping () -> Void,
        onSnooze: ((Int?) -> Void)? = nil,
        entersFromLeft: Bool = false
    ) {
        self.task = task
        self.shelves = shelves
        self.onDiscard = onDiscard
        self.onSkip = onSkip
        self.onMove = onMove
        self.onNext = onNext
        self.onSnooze = onSnooze
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
        .onChange(of: task.estimatedMinutes) { _, newValue in
            // A duration edit is a fresh stated size — whatever partial
            // placement `remainingMinutes` was tracking against the *old*
            // size no longer means anything. Attached here (the always-
            // mounted card body) rather than on the Duration Picker
            // itself, which only exists in the view hierarchy while "Yes"
            // is selected and would miss the "No" / untap-"Yes" resets
            // that also write `estimatedMinutes` directly.
            task.remainingMinutes = newValue
        }
    }

    /// The Eligible Schedules row's own subtitle — one distinct caption
    /// per non-`.fits` `SchedulingFitStatus`, naming the actual blocker
    /// instead of a single flat "Exceeds time constraint" that used to
    /// read as permanent (and, for the two "not ready yet" cases, was
    /// simply wrong — nothing about those tasks is actually too big for
    /// anything). `nil` for `.fits` — no caption, toggle just reads
    /// enabled.
    private func eligibleScheduleCaption(for status: SchedulingFitStatus) -> String? {
        switch status {
        case .needsDuration:
            return "Set a duration first."
        case .needsMinimumSegment:
            return "Set a minimum segment first"
        case .exceedsConstraint:
            return "Exceeds time constraint — will re-enable if this changes"
        case .fits:
            return nil
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

    /// Whole days remaining until `until`, rounded up so "snoozed until
    /// 11pm tomorrow" still reads as "1d" rather than "0d" a minute after
    /// snoozing — same rounding `InboxView.snoozeRemainingText` uses.
    private func snoozeDaysRemainingLabel(_ until: Date) -> String {
        let days = max(1, Int(ceil(until.timeIntervalSince(.now) / 86400)))
        return "\(days)d"
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

    /// Same idea as `dueDatesAllowed`, for "Remind Me In" — defaults to
    /// off (rather than on) for a task with no shelf yet, since this is
    /// an opt-in-per-shelf feature (`Shelf.tracksFutureReminder` starts
    /// false) rather than an on-by-default attribute the way the others
    /// are.
    private var futureReminderAllowed: Bool {
        previewedShelf?.effectiveTracksFutureReminder ?? false
    }

    /// Priority collapsed to a plain Yes/No question — `.medium` is still
    /// a storable/orderable value (existing data, and `AISchedulingService`'s
    /// own ranking, both still recognize it), it's just never reachable
    /// from this toggle anymore: "No" answers as `.low`, same as it
    /// always ranked below `.high`.
    private var highPriorityAnswer: Binding<Bool?> {
        Binding(
            get: {
                switch task.priority {
                case .unset: return nil
                case .high: return true
                case .low, .medium: return false
                }
            },
            set: { newValue in
                focusedField = nil
                switch newValue {
                case .some(true): task.priority = .high
                case .some(false): task.priority = .low
                case .none: task.priority = .unset
                }
            }
        )
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

            // Shown wherever this card renders (Task Attribute Review,
            // the standalone task card sheet, the review queue) since
            // they all wrap `TaskReviewCard` — one badge, reused
            // everywhere rather than duplicated per entry point. See
            // `TaskItem.isAtRisk`/`atRiskBlocker` (spec §5.3) — a task
            // that's out of math (or already scheduled past its own
            // deadline) gets named here, not silently left to be
            // noticed only once it's actually missed.
            if let blocker = task.atRiskBlocker() {
                Label("At risk — \(blocker)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
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

    /// Replaces the normal Yes/No Due Date section whenever the top-level
    /// "Recurring?" toggle is on — there's no separate "Has due date"
    /// question, a recurring task always has one, by definition. No date
    /// question here either: Start Date doubles as the anchor every
    /// occurrence steps forward from (`task.dueDate`, kept in sync with
    /// `task.startDate` — see the "Recurring?" toggle and Start Date
    /// picker in `cardScrollBody`), so there's nothing left for this
    /// section to ask beyond the interval/end-date questions below. No
    /// time-of-day question either — every occurrence still lands at a
    /// fixed time on the calendar (see `TaskItem.recurringOccurrenceTime`),
    /// it just isn't user-picked; see `combiningDate(_:withTimeFrom:)`.
    private var recurringSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if task.isRecurring {
                HStack(spacing: 8) {
                    Text("Every")
                        .font(.body)
                        .lineLimit(1)
                        .fixedSize()
                    Spacer()
                    // Same +/- Stepper + dropdown shape as "Remind In" —
                    // `.fixedSize()` keeps both compact on the trailing
                    // side instead of each expanding to fill the row.
                    Stepper(
                        value: Binding(
                            get: { task.recurrenceIntervalCount },
                            set: { task.recurrenceIntervalCount = max(1, $0) }
                        ),
                        in: 1...365
                    ) {
                        Text("\(task.recurrenceIntervalCount)")
                            .font(.subheadline.weight(.semibold))
                            .frame(minWidth: 20)
                    }
                    .fixedSize()

                    Picker("Repeat every", selection: Binding(
                        get: { task.recurrenceUnit },
                        set: { task.recurrenceUnit = $0 }
                    )) {
                        ForEach(RecurrenceUnit.allCases) { unit in
                            Text(unit.label(for: task.recurrenceIntervalCount).capitalized).tag(unit)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }

                Toggle("Ends on a date", isOn: Binding(
                    get: { task.recurrenceEndDate != nil },
                    set: { newValue in
                        task.recurrenceEndDate = newValue
                            ? (task.recurrenceEndDate ?? Calendar.current.date(byAdding: .month, value: 1, to: task.dueDate ?? .now))
                            : nil
                    }
                ))

                if task.recurrenceEndDate != nil {
                    HStack {
                        Text("Until")
                        Spacer()
                        Button {
                            focusedField = nil
                            isShowingRecurrenceEndDatePicker = true
                        } label: {
                            Text((task.recurrenceEndDate ?? .now).formatted(date: .abbreviated, time: .omitted))
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
                        .popover(isPresented: $isShowingRecurrenceEndDatePicker) {
                            DatePicker(
                                "Until",
                                selection: Binding(
                                    get: { task.recurrenceEndDate ?? .now },
                                    set: { task.recurrenceEndDate = $0 }
                                ),
                                in: (task.dueDate ?? .now)...,
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
                } else {
                    Text("Repeats indefinitely.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The stand-in time-of-day a recurring task's anchor gets the first
    /// time it needs one (turning "Recurring?" on, or opening the Date
    /// picker before that's happened) — there's no time picker to ask the
    /// user directly anymore, so this is just a reasonable default rather
    /// than whatever second `.now` happens to land on.
    private static func defaultRecurringAnchorTime(asOf referenceDate: Date = .now) -> Date {
        Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: referenceDate) ?? referenceDate
    }

    /// Folds a newly-picked day (from the date-only picker in
    /// `recurringSection`, which only ever returns midnight of that day)
    /// onto whatever time-of-day the anchor already carried — so picking
    /// a new date never silently resets the time every future occurrence
    /// reuses (see `TaskItem.recurringOccurrenceTime`) back to midnight.
    private static func combiningDate(_ newDay: Date, withTimeFrom existing: Date?) -> Date {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: newDay)
        let timeSource = existing ?? defaultRecurringAnchorTime(asOf: newDay)
        let timeComponents = calendar.dateComponents([.hour, .minute], from: timeSource)
        components.hour = timeComponents.hour
        components.minute = timeComponents.minute
        components.second = 0
        return calendar.date(from: components) ?? newDay
    }

    /// Everything past Next step — due date through Eligible Schedules —
    /// in its own scroll region so a task with a lot filled in never pushes
    /// the header or the action row off-screen.
    private var cardScrollBody: some View {
        ScrollViewReader { scrollProxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
            Divider()

            HStack {
                Text("Start Date")
                Spacer()
                Button {
                    focusedField = nil
                    isShowingStartDatePicker = true
                } label: {
                    Text((task.startDate ?? .now).formatted(date: .complete, time: .omitted))
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
                .popover(isPresented: $isShowingStartDatePicker) {
                    DatePicker(
                        "Start",
                        selection: Binding(
                            get: { task.startDate ?? .now },
                            set: { newValue in
                                task.startDate = newValue
                                // While recurring, Start Date doubles as
                                // the anchor every occurrence steps
                                // forward from — see the "Recurring?"
                                // toggle below — so it stays synced live
                                // if tweaked after the fact, rather than
                                // needing a second date picker.
                                if task.isRecurring {
                                    task.dueDate = Self.combiningDate(newValue, withTimeFrom: task.dueDate)
                                    task.dueDateDecided = true
                                    task.dueDatePicked = true
                                }
                                isShowingStartDatePicker = false
                            }
                        ),
                        in: Calendar.current.startOfDay(for: .now)...,
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

            Toggle("Recurring?", isOn: Binding(
                get: { task.isRecurring },
                set: { newValue in
                    task.isRecurring = newValue
                    if newValue {
                        // Start Date is the anchor here — no separate
                        // date question inside `recurringSection`. Falls
                        // back to today if Start Date was never touched,
                        // same default its own button already shows.
                        let anchorDay = task.startDate ?? Calendar.current.startOfDay(for: .now)
                        task.startDate = anchorDay
                        task.dueDate = Self.combiningDate(anchorDay, withTimeFrom: task.dueDate)
                        task.dueDateDecided = true
                        task.dueDatePicked = true
                        // The Recurring Tasks shelf is the only valid move
                        // target once this is on (see
                        // `eligibleShelvesForMove`) — preview it right
                        // away so every other shelf-gated question (Due
                        // Date, Duration, Priority, Future Reminder, ...)
                        // reflects *that* shelf's own settings immediately,
                        // same as tapping its icon in `shelfRow` would.
                        if let recurringShelf = shelves.first(where: { $0.isRecurringTasks }) {
                            selectedShelf = recurringShelf
                            task.includedSchedulingRuleIDs = (recurringShelf.schedulingRules ?? []).filter(\.isEnabled).map(\.id)
                        }
                    } else if selectedShelf?.isRecurringTasks == true {
                        // Flip side — drop the auto-preview so the card
                        // goes back to reading `task.shelf`'s own settings
                        // (or whatever the user had actually tapped)
                        // instead of staying stuck on the Recurring Tasks
                        // shelf's.
                        selectedShelf = nil
                    }
                }
            ))
            .animation(.easeInOut(duration: 0.15), value: task.isRecurring)

            if task.isRecurring {
                recurringSection
            } else {
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
                                in: Calendar.current.startOfDay(for: .now)...,
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
            }

            YesNoToggle(title: "High Priority?", answer: priorityAllowed ? highPriorityAnswer : .constant(false))
                .padding(.top, 4)
                .disabled(!priorityAllowed)
                .opacity(priorityAllowed ? 1 : 0.4)
                .animation(.easeInOut(duration: 0.15), value: priorityAllowed)

            if futureReminderAllowed {
                HStack(spacing: 8) {
                    Text("Remind In")
                        .font(.body)
                        .lineLimit(1)
                        .fixedSize()
                    Spacer()
                    // +/- Stepper instead of a wheel — a count this small
                    // (0-90) doesn't need a wheel's full sweep, just a way
                    // to nudge it up or down. `.fixedSize()` keeps it (and
                    // the dropdown next to it) from each greedily
                    // expanding to fill the row, so both sit compactly on
                    // the trailing side alongside the label instead of
                    // stacking onto their own lines.
                    Stepper(
                        value: Binding(
                            get: { task.remindInCount },
                            set: { newValue in
                                task.remindInCount = max(0, newValue)
                                task.applyRemindIn()
                            }
                        ),
                        in: 0...90
                    ) {
                        Text("\(task.remindInCount)")
                            .font(.subheadline.weight(.semibold))
                            .frame(minWidth: 20)
                    }
                    .fixedSize()

                    Picker("Unit", selection: Binding(
                        get: { task.remindInUnit },
                        set: { newValue in
                            task.remindInUnit = newValue
                            task.applyRemindIn()
                        }
                    )) {
                        ForEach(RecurrenceUnit.allCases) { unit in
                            Text(unit.label(for: task.remindInCount).capitalized)
                                .tag(unit)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
                .padding(.top, 4)
            }

            VStack(alignment: .leading, spacing: 6) {
                // Forced to "No" (and disabled below) whenever the
                // previewed/actual shelf doesn't track duration — the
                // real stored answer is untouched so it comes back if
                // the shelf preview is cancelled.
                let isYesSelected = durationAllowed && task.durationDecided && task.durationAnsweredYes
                let isNoSelected = !durationAllowed || (task.durationDecided && !task.durationAnsweredYes)

                HStack(spacing: 8) {
                    Text("Duration")

                    Spacer()

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
                            // The wheel needs a value actually in its own
                            // range to show a real selection instead of
                            // landing on nothing.
                            if task.estimatedMinutes <= 0 {
                                task.estimatedMinutes = 2
                            }
                        }
                    } label: {
                        Text("Yes")
                            .font(.subheadline.weight(.semibold))
                            .frame(minWidth: 48)
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
                            .frame(minWidth: 48)
                            .padding(.vertical, 9)
                            .background(isNoSelected ? Color.accentColor : Color.secondary.opacity(0.15))
                            .foregroundStyle(isNoSelected ? Color.white : Color.primary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    if isYesSelected {
                        Picker("Duration", selection: $task.estimatedMinutes) {
                            ForEach(durationWheelOptions, id: \.self) { minutes in
                                Text(minutes == 2 ? "≤2 min" : TaskItem.durationLabel(for: minutes))
                                    .font(.subheadline.weight(.semibold))
                                    .tag(minutes)
                            }
                        }
                        .pickerStyle(.wheel)
                        .labelsHidden()
                        .frame(width: 110, height: 40)
                        .clipped()
                        .onChange(of: task.estimatedMinutes) { _, _ in
                            task.durationDecided = true
                            task.syncScheduledBlockDuration()
                        }
                    }
                }

                // `estimatedMinutes` itself never changes from a partial
                // placement (see `TaskItem.remainingMinutes`) — this is
                // the one place that surfaces the difference, rather than
                // the duration silently reading as the task's full size
                // while some of it is actually still sitting unplaced.
                if isYesSelected, task.remainingMinutes < task.estimatedMinutes {
                    Text("\(TaskItem.durationLabel(for: task.estimatedMinutes - task.remainingMinutes)) of \(TaskItem.durationLabel(for: task.estimatedMinutes)) scheduled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
            .disabled(!durationAllowed)
            .opacity(durationAllowed ? 1 : 0.4)
            .animation(.easeInOut(duration: 0.15), value: task.durationDecided)
            .animation(.easeInOut(duration: 0.15), value: durationAllowed)

            VStack(alignment: .leading, spacing: 6) {
                let isDivisibleYesSelected = durationAllowed && task.isDivisibleDecided && task.isDivisible
                let isDivisibleNoSelected = !durationAllowed || (task.isDivisibleDecided && !task.isDivisible)

                HStack(spacing: 8) {
                    Text("Divisible")

                    Spacer()

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
                            // Same reasoning as the Duration wheel above —
                            // needs a value actually in its own range.
                            if task.minimumSegmentMinutes <= 0 {
                                task.minimumSegmentMinutes = Self.divisibleSegmentOptions.first ?? 15
                            }
                        }
                    } label: {
                        Text("Yes")
                            .font(.subheadline.weight(.semibold))
                            .frame(minWidth: 48)
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
                            .frame(minWidth: 48)
                            .padding(.vertical, 9)
                            .background(isDivisibleNoSelected ? Color.accentColor : Color.secondary.opacity(0.15))
                            .foregroundStyle(isDivisibleNoSelected ? Color.white : Color.primary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    if isDivisibleYesSelected {
                        Picker("Minimum Segment", selection: $task.minimumSegmentMinutes) {
                            ForEach(Self.divisibleSegmentOptions, id: \.self) { minutes in
                                Text(TaskItem.durationLabel(for: minutes))
                                    .font(.subheadline.weight(.semibold))
                                    .tag(minutes)
                            }
                        }
                        .pickerStyle(.wheel)
                        .labelsHidden()
                        .frame(width: 110, height: 40)
                        .clipped()
                    }
                }
            }
            .padding(.top, 4)
            .disabled(!durationAllowed)
            .opacity(durationAllowed ? 1 : 0.4)
            .animation(.easeInOut(duration: 0.15), value: task.isDivisibleDecided)
            .animation(.easeInOut(duration: 0.15), value: durationAllowed)

            // Grouped under one stable id (rather than tagging the
            // suggestions row itself, which only exists conditionally) so
            // `scrollTo("tagSection")` always has something to target —
            // see the `.onChange`s below, which keep this scrolled into
            // view as you type so the pre-populating suggestion chips
            // don't end up hidden below the fold or the keyboard.
            VStack(alignment: .leading, spacing: 10) {
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
                // Autocomplete against the saved tag box — tapping one adds
                // it outright instead of just filling the field in.
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
            }
            .id("tagSection")

            Divider()
            shelfRow

            if let rules = previewedShelf?.schedulingRules, !rules.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Eligible Schedules")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(rules.sorted { $0.sortOrder < $1.sortOrder }) { rule in
                        let status = task.fitStatus(for: rule)
                        let fits = status == .fits
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
                                if let caption = eligibleScheduleCaption(for: status) {
                                    Text(caption)
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
        .onChange(of: focusedField) { _, newValue in
            guard newValue == .tag else { return }
            withAnimation { scrollProxy.scrollTo("tagSection", anchor: .bottom) }
        }
        .onChange(of: newTag) { _, _ in
            guard focusedField == .tag else { return }
            withAnimation { scrollProxy.scrollTo("tagSection", anchor: .bottom) }
        }
        }
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
    /// the task at all. The single shared "commit" point behind every
    /// Save/Save & Move/Save & Submit/Skip variant across every screen
    /// that presents this card (`TaskCardSheet`, `TaskReviewQueueSheet`,
    /// Nightly Review's own Today/Inbox steps) — see §6.1.
    private func advance() {
        let isMoving = selectedShelf != nil && selectedShelf?.id != task.shelf?.id
        if hasChanges || isMoving {
            // A shelf move always counts, even on its own: `hasChanges`
            // deliberately excludes it (see its own doc comment —
            // "merely tapping a shelf to preview it" isn't itself an
            // edit), but actually committing that move here is a real
            // change regardless of whether anything else on the card
            // was touched. A bare Skip/Next with neither is a true
            // no-op and correctly leaves the flag alone.
            ScheduleDirtyState.shared.isDirty = true
        }
        if let selectedShelf, selectedShelf.id != task.shelf?.id {
            onMove(selectedShelf)
        } else if task.isMissingAttributes {
            onSkip()
        } else {
            onNext()
        }
    }

    /// Which of `shelves` `shelfRow` actually offers as a move target. A
    /// recurring task (see `TaskItem.isRecurring`) can only go to the
    /// Recurring Tasks shelf — nowhere else knows how to place its
    /// occurrences on the calendar. A task whose duration is decided at 2
    /// minutes or less can only go to the 2-Minute Task shelf, the one
    /// place that treats it as an untimed checklist item instead of a
    /// calendar block. Outside both of those cases, the two special
    /// shelves are hidden entirely rather than shown as options that
    /// don't actually fit this task.
    private var eligibleShelvesForMove: [Shelf] {
        if task.isRecurring {
            return shelves.filter { $0.isRecurringTasks }
        }
        if task.durationDecided, task.durationAnsweredYes, task.estimatedMinutes > 0, task.estimatedMinutes <= 2 {
            return shelves.filter { $0.isTwoMinuteTasks }
        }
        return shelves.filter { !$0.isTwoMinuteTasks && !$0.isRecurringTasks }
    }

    /// A wrapping grid rather than a horizontal scroll — every shelf is
    /// visible up front instead of some sitting off-screen to the side,
    /// and `.adaptive` columns keep every icon the same evenly-spaced
    /// width whether there's one row or several.
    private var shelfRow: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 16)], alignment: .center, spacing: 12) {
                ForEach(eligibleShelvesForMove) { shelf in
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
                        VStack(spacing: 4) {
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
                            Text(shelf.name)
                                .font(.caption2)
                                .foregroundStyle(isSelected ? shelf.color : .secondary)
                                .multilineTextAlignment(.center)
                                .frame(width: 60)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(shelf.name)
                }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 20)
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
                    ScheduleDirtyState.shared.isDirty = true
                    fly(direction: -1, action: onDiscard)
                }
            } message: {
                Text(task.title.isEmpty ? "This can't be undone." : "\"\(task.title)\" can't be recovered after this.")
            }

            // Available for an unsorted Inbox task too, not just a shelf
            // one — both `InboxView.startAttributeReview` and
            // `NightlyReviewView.startAttributeReviewSession` already
            // filter their unsorted-task queue on
            // `isSnoozedFromAttributeReview` the same way they filter the
            // shelf-task one.
            if let onSnooze {
                Button {
                    focusedField = nil
                    if task.isSnoozedFromAttributeReview {
                        onSnooze(nil)
                        showToast("Un-snoozed")
                    } else {
                        snoozeDays = 1
                        isShowingSnoozeWheel = true
                    }
                } label: {
                    if task.isSnoozedFromAttributeReview {
                        Image(systemName: "zzz")
                            .font(.system(size: 30))
                            .foregroundStyle(Color.gray)
                            .overlay(alignment: .topTrailing) {
                                if let until = task.attributeReviewSnoozedUntil {
                                    Text(snoozeDaysRemainingLabel(until))
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.gray, in: Capsule())
                                        .offset(x: 14, y: -6)
                                }
                            }
                    } else {
                        Image(systemName: "moon.zzz.fill")
                            .font(.system(size: 30))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.black, Color(red: 0.79, green: 0.64, blue: 0.14))
                    }
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isShowingSnoozeWheel) {
                    VStack(spacing: 12) {
                        Text("Snooze for")
                            .font(.headline)
                        Picker("Days", selection: $snoozeDays) {
                            ForEach(1...30, id: \.self) { day in
                                Text("\(day) day\(day == 1 ? "" : "s")").tag(day)
                            }
                        }
                        .pickerStyle(.wheel)
                        .labelsHidden()
                        .frame(height: 140)

                        Button("Snooze") {
                            onSnooze(snoozeDays)
                            isShowingSnoozeWheel = false
                            showToast("Snoozed \(snoozeDays) day\(snoozeDays == 1 ? "" : "s")")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .frame(width: 240)
                    .presentationCompactAdaptation(.popover)
                }
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
