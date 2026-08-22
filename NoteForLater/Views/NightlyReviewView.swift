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
    @Query(sort: \Recipe.title) private var allRecipes: [Recipe]
    @Query private var allMealSelections: [MealSelection]

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
    /// Taps during the Today step are visual-only — this is what actually
    /// makes them reversible before Next. Keyed by `ReviewItem.id` (already
    /// unifies a block's and a habit occurrence's id into one String), so
    /// one set stages both kinds. Membership means "flip the real model
    /// once when Next commits" — see `advance()`'s `next == .inbox` branch,
    /// which replays this set against `reviewItems` and clears it
    /// afterward. Reset whenever a different day gets picked, same as
    /// `twoMinuteReviewTaskIDs`, since a stale entry from another day's
    /// `reviewItems` would never match anything real here anyway.
    @State private var stagedTodayToggleIDs = Set<String>()
    /// Same idea as `stagedTodayToggleIDs`, for the 2-Minute Tasks step —
    /// committed in `advance()`'s `next == .today` branch instead (that
    /// step now runs *before* Today Review, not after it).
    @State private var stagedTwoMinuteToggleIDs = Set<UUID>()
    /// Same staging pattern again, for the `MealSelection` rows on the
    /// Today step — a set, not a single flag, since `todayMealSelections`
    /// can surface more than one at once (a multi-day backlog, same as
    /// `reviewableBlocks` already allows for ordinary blocks). Committed
    /// in `advance()`'s `next == .inbox` branch, same trigger point as
    /// the rest of Today's staged state.
    @State private var stagedMealSelectionIDs = Set<UUID>()
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
        case chooseDay, twoMinuteTasks, today, inbox, atRisk, meals, tomorrow

        /// `planDate` is only meaningful for `.meals`/`.tomorrow` — the day
        /// right after whichever day was picked in Choose Day, not
        /// calendar-tomorrow-from-right-now — so its title can name that
        /// day explicitly instead of just saying "Tomorrow".
        func title(planDate: Date) -> String {
            switch self {
            case .chooseDay: return "Which Day?"
            case .twoMinuteTasks: return "2-Minute Tasks"
            case .today: return "Review Schedule"
            case .inbox: return "Sort Your Inbox"
            case .atRisk: return "At Risk"
            case .meals:
                let formatter = DateFormatter()
                formatter.dateFormat = "EEE MMMM d, yyyy"
                return "Pick a Meal for \(formatter.string(from: planDate))"
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

    private var kitchenShelf: Shelf? {
        allShelves.first { $0.isKitchen }
    }

    /// Same "still actually in the pantry" filter `ShelfListView
    /// .visibleTasks`/`MealsView.pantryItemNames` both apply — a completed
    /// pantry task means "used up," not on hand, so it's excluded from
    /// what deduction is allowed to touch.
    private var kitchenPantryItems: [TaskItem] {
        (kitchenShelf?.tasks ?? []).filter { !$0.isCompleted }
    }

    /// The meal picked (during a *previous* night's Meals step) for
    /// whichever day is being reviewed right now — at most one per day.
    /// Every meal that either belongs to today's review or is still
    /// unresolved from an earlier one — same shape as `reviewableBlocks`'s
    /// own filter (`isCompleted || date <= cutoff`), not just an
    /// exact-day match: a `MealSelection` picked two nights ago and never
    /// checked off shouldn't have to wait for that day's own review to
    /// surface, the same way an overdue block doesn't.
    private var todayMealSelections: [MealSelection] {
        let cutoffDay = Calendar.current.startOfDay(for: reviewDate)
        return allMealSelections.filter { $0.isCompleted || $0.date <= cutoffDay }
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
                case .twoMinuteTasks: twoMinuteTasksStep
                case .today: todayStep
                case .inbox: inboxStep
                case .atRisk: atRiskStep
                case .meals: mealsStep
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
                        candidates: tomorrowViewModel.replacementCandidates(from: allTasks, for: .occupiedBlock(block)),
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
        var next = Step(rawValue: step.rawValue + 1) ?? .tomorrow
        if step == .chooseDay {
            setupViewModels()
        }
        // §7.1: skipped forward, not dismissed — `.atRisk` is no longer
        // the last step (Meals/Tomorrow still follow it), so an empty
        // At-Risk step just advances one further rather than ending the
        // whole review the way it used to when it was the final step.
        if next == .atRisk, atRiskTasks.isEmpty {
            next = Step(rawValue: next.rawValue + 1) ?? .tomorrow
        }
        step = next
        if next == .today {
            // Two-Minute-Tasks-step taps are visual-only — commit them
            // here, on the way out, so Today Review (which now runs right
            // after, not three steps later) can show them as already
            // completed. Moved here from the old twoMinuteTasks->tomorrow
            // transition now that Two-Minute Tasks runs *before* Today
            // Review instead of after it.
            for task in twoMinuteReviewTasks where stagedTwoMinuteToggleIDs.contains(task.id) {
                task.setCompleted(!task.isCompleted, in: modelContext)
                ScheduleDirtyState.shared.isDirty = true
            }
            stagedTwoMinuteToggleIDs = []
        }
        if next == .inbox {
            startAttributeReviewSession()
        }
        if next == .twoMinuteTasks {
            let pending = (twoMinuteShelf?.tasks ?? []).filter { !$0.isCompleted && $0.isEligibleToStart(on: reviewDate) }
            // Also pick up anything completed earlier today (or since the
            // last review closed), before this step's own snapshot: the
            // old `!$0.isCompleted`-only filter hid these permanently —
            // there's no later chance to see them, since a completed
            // 2-minute task never gets a block `reviewableBlocks` could
            // have shown it through instead.
            let since = NightlyReviewCompletionState.shared.lastClosedReviewDay ?? .distantPast
            let completedRecords = (try? modelContext.fetch(FetchDescriptor<TaskCompletionRecord>(
                predicate: #Predicate { $0.completedAt >= since }
            ))) ?? []
            let completedTaskIDs = Set(completedRecords.map(\.taskID))
            let recentlyCompleted = (twoMinuteShelf?.tasks ?? []).filter { completedTaskIDs.contains($0.id) }
            twoMinuteReviewTaskIDs = Set(pending.map(\.id) + recentlyCompleted.map(\.id))
            stagedTwoMinuteToggleIDs = []
        }
        if next == .inbox, let todayViewModel, let tomorrowViewModel {
            // Today-step taps are visual-only (see `stagedTodayToggleIDs`)
            // until right here — replay every staged toggle against the
            // still-real, still-unwritten model, then clear the set. Must
            // run before `reviewedBlocks` is captured just below, since
            // that split (and the missed-habit sweep after it) both read
            // real completion state.
            for item in reviewItems where stagedTodayToggleIDs.contains(item.id) {
                switch item {
                case .block(let block):
                    todayViewModel.toggleComplete(block)
                case .habit(let occurrence):
                    toggleHabitReviewOccurrence(habit: occurrence.habit, index: occurrence.index, isCompleted: occurrence.isCompleted, day: occurrence.targetTime)
                case .completedTask:
                    break
                }
            }
            stagedTodayToggleIDs = []
            // Every meal shown this step (tonight's, plus any earlier
            // unresolved backlog — see `todayMealSelections`) that got
            // staged, committed the same visual-only way as everything
            // else on this step. Committing `true` is the trigger for
            // pantry deduction: resolve the live `Recipe` by `recipeID`
            // (may have been edited/deleted since selection — if so, this
            // silently does nothing, consistent with this feature's whole
            // "no warnings" policy) and hand it to `PantryDeductionService`
            // along with the Kitchen shelf's current pantry items.
            for selection in todayMealSelections where stagedMealSelectionIDs.contains(selection.id) {
                selection.isCompleted.toggle()
                if selection.isCompleted, let recipe = allRecipes.first(where: { $0.id == selection.recipeID }) {
                    PantryDeductionService.deduct(recipe: recipe, pantryItems: kitchenPantryItems)
                }
            }
            stagedMealSelectionIDs = []
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
        let hasHabits = ScheduleReviewViewModel.hasOpenHabitOccurrences(habits: allHabits, context: modelContext, upTo: startOfToday)
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
            stagedTodayToggleIDs = []
            stagedMealSelectionIDs = []
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

    // MARK: - Step 2: Today

    /// Used only for *operational* decisions — actually marking something
    /// missed, or clearing/rescheduling an incomplete block — never for
    /// what the Today step displays (see `reviewDisplayCutoff` for that).
    /// When `reviewDate` is today, this is `.now` itself rather than
    /// end-of-day, since a block later today hasn't happened yet and
    /// can't legitimately be judged "missed" or "not done" until its own
    /// time actually passes; when `reviewDate` is an earlier day (already
    /// fully elapsed), it's that day's midnight boundary instead. Shared
    /// by `markUnresolvedHabitOccurrencesAsMissed` and `advance()` (what
    /// gets frozen as `frozenCutoff`, for `clearIncompletePastBlocks`).
    private var reviewCutoff: Date {
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: reviewDate) ?? reviewDate
        return min(.now, dayEnd)
    }

    /// What the Today step actually *shows* — always the full span of
    /// `reviewDate`, regardless of what time it currently is. A task or
    /// habit later today should be visible in tonight's review the moment
    /// you open it, not only once its own time has technically passed —
    /// unlike `reviewCutoff`, this never clamps to `.now`. Deliberately
    /// kept separate from `reviewCutoff`: `reviewableBlocks` and
    /// `openHabitOccurrencesForReview` both read this one, while anything
    /// that actually *acts* on "is this done or not yet due" — the missed
    /// sweep, the past-block clear — still reads the narrower
    /// `reviewCutoff`, so showing a 9pm habit at 6pm review time never
    /// causes it to be prematurely marked missed or rescheduled off today.
    private var reviewDisplayCutoff: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: reviewDate) ?? reviewDate
    }

    /// Every block (complete or not) up through `reviewDisplayCutoff`,
    /// plus any block already marked complete no matter how far out it's
    /// dated — a task knocked out ahead of its scheduled day shouldn't
    /// have to wait for that future day's own review to get checked off
    /// here. So a backlog left over from a busy week doesn't just quietly
    /// pile up unreviewed, but a review for a past day never leaks in an
    /// *incomplete* block from a day after it. `markComplete` isn't
    /// actually scoped to `todayViewModel`'s own `targetDate` internally,
    /// so reusing it here for a block from any earlier or later day is safe.
    private var reviewableBlocks: [ScheduledBlock] {
        allBlocks
            .filter { $0.startTime < reviewDisplayCutoff || $0.isCompleted }
            .sorted { $0.startTime < $1.startTime }
    }

    /// Blocks, open habit occurrences, and completed-with-no-block tasks
    /// mixed into one list, organized by time within each day — see
    /// `ReviewItem`/`OverdueBlocksReviewList`.
    private var reviewItems: [ReviewItem] {
        reviewableBlocks.map { .block($0) }
            + openHabitOccurrencesForReview.map { .habit($0) }
            + completedTasksWithNoBlock.map { .completedTask($0) }
    }

    /// Task completions with no live `ScheduledBlock` to represent them —
    /// the 2-Minute Task shelf (already shown separately, in its own step)
    /// and the older Task Attribute Review "Mark Complete" path both leave
    /// a task like this, and `purgeCompletedBlocks` deletes it outright the
    /// moment this review's Today step commits. Without this,
    /// `reviewableBlocks` (block-only) never shows it at all, and it's
    /// gone for good the instant Next is tapped. `TaskCompletionRecord` is
    /// the durable trace that survives that delete, so it's sourced from
    /// there rather than from `allTasks` directly — that also covers a
    /// task purged by an *earlier* Nightly Review session that's since
    /// come and gone.
    private var completedTasksWithNoBlock: [TaskCompletionRecord] {
        let since = NightlyReviewCompletionState.shared.lastClosedReviewDay ?? .distantPast
        let records = (try? modelContext.fetch(FetchDescriptor<TaskCompletionRecord>(
            predicate: #Predicate { $0.completedAt >= since }
        ))) ?? []
        let liveTasksByID = Dictionary(uniqueKeysWithValues: allTasks.map { ($0.id, $0) })
        return records.filter { record in
            guard let task = liveTasksByID[record.taskID] else { return true }
            return (task.scheduledBlocks ?? []).isEmpty && task.shelf?.isTwoMinuteTasks != true
        }
    }

    /// A tap here only flips membership in `stagedTodayToggleIDs` — no
    /// model write happens until `advance()` commits the batch on Next
    /// (§ requirement that Today-step taps be visual-only and reversible).
    /// `effectiveCompleted` is what lets the row render that pending state
    /// without touching `block.isCompleted`/`occurrence.isCompleted`.
    @ViewBuilder
    private var todayStep: some View {
        if todayViewModel != nil {
            VStack(spacing: 0) {
                ForEach(todayMealSelections) { selection in
                    mealSelectionRow(selection)
                    Divider()
                }
                OverdueBlocksReviewList(items: reviewItems, onToggle: { item in
                    if stagedTodayToggleIDs.contains(item.id) {
                        stagedTodayToggleIDs.remove(item.id)
                    } else {
                        stagedTodayToggleIDs.insert(item.id)
                    }
                }, isEffectivelyCompleted: effectiveCompleted)
            }
        } else {
            ProgressView()
        }
    }

    /// One row per `todayMealSelections` entry — tonight's meal, plus any
    /// earlier unresolved backlog — staged the same visual-only way as
    /// everything else on this step. See `stagedMealSelectionIDs` and its
    /// commit in `advance()`'s `next == .inbox` branch, which is also what
    /// actually triggers pantry deduction.
    private func mealSelectionRow(_ selection: MealSelection) -> some View {
        let isStaged = stagedMealSelectionIDs.contains(selection.id)
        let isCompleted = isStaged ? !selection.isCompleted : selection.isCompleted
        return HStack(spacing: 12) {
            Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isCompleted ? Color.green : Color.secondary.opacity(0.5))
            Text("Cooked: \(selection.recipeTitle)")
                .strikethrough(isCompleted)
            Spacer()
        }
        .padding()
        .contentShape(Rectangle())
        .onTapGesture {
            if isStaged {
                stagedMealSelectionIDs.remove(selection.id)
            } else {
                stagedMealSelectionIDs.insert(selection.id)
            }
        }
        .opacity(isCompleted ? 0.5 : 1)
    }

    private func effectiveCompleted(for item: ReviewItem) -> Bool {
        let real: Bool
        switch item {
        case .block(let block): real = block.isCompleted
        case .habit(let occurrence): real = occurrence.isCompleted
        case .completedTask: real = true
        }
        return stagedTodayToggleIDs.contains(item.id) ? !real : real
    }

    /// An AM/Midday/PM habit occurrence (see `HabitOccurrenceTimeMode`)
    /// never gets a `ScheduledBlock` at all, so it'd otherwise be
    /// invisible to `reviewableBlocks` — a Specific-Time occurrence
    /// doesn't need this, it already shows up as a real block. See
    /// `ScheduleReviewViewModel.openHabitOccurrencesForReview` (this just
    /// supplies `reviewDisplayCutoff` — same cutoff `reviewableBlocks`
    /// already uses, so a PM habit shows up here the moment the Today
    /// step opens rather than only once its own time has passed — and
    /// `completedSince`, so an occurrence already checked off earlier
    /// today, before this review session ever opened, still shows up here
    /// instead of being invisible until the sweep runs). A same-session
    /// tap never needs its own escape hatch the way `completedSince`
    /// does — see `stagedTodayToggleIDs`/`effectiveCompleted`: the real
    /// status never changes mid-session, so the `.none` filter below
    /// never has anything to exclude yet.
    private var openHabitOccurrencesForReview: [HabitReviewOccurrence] {
        ScheduleReviewViewModel.openHabitOccurrencesForReview(
            habits: allHabits,
            context: modelContext,
            upTo: reviewDisplayCutoff,
            completedSince: NightlyReviewCompletionState.shared.lastClosedReviewDay
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
        habit.logOrCreate(on: day, context: modelContext, calendar: Calendar.current)
    }

    /// Marks every still-open (`.none`) habit occurrence the Today review
    /// showed — timed (a `reviewableBlocks` habit block left incomplete)
    /// or untimed (`openHabitOccurrencesForReview`) — as missed. See the
    /// call site in `advance()` for why this only happens here rather
    /// than in the shared block-clearing helpers.
    private func markUnresolvedHabitOccurrencesAsMissed() {
        // PERMANENT, deliberately — kept when the rest of the
        // duplicate-investigation instrumentation is stripped, for the same
        // reason `DiagFileLog`'s overlap-rejection line is kept.
        //
        // This routine overwrites real user data once a night and leaves no
        // other trace. Without these two counts, "the sweep protected every
        // completion" and "the sweep never ran at all" produce **identical**
        // output — an unchanged miss count — and the first attempt to verify
        // the guard was unfalsifiable for exactly that reason. Every claim
        // ever made about this function before this line existed rested on
        // absence of evidence from a test that had never run.
        //
        // `untimedOccurrences=0` means the run was vacuous and any pass
        // drawn from it is worthless. That is the whole value of the line.
        //
        // Deliberately NOT `reviewableBlocks`/`openHabitOccurrencesForReview`
        // here — those now show the *whole day* regardless of time (see
        // `reviewDisplayCutoff`), so reusing them would mark a habit due
        // later tonight as missed the instant Next is tapped, even though
        // there's still time left today to actually do it. This sweep
        // stays scoped to the narrower, `.now`-based `reviewCutoff`.
        let sweepBlocks = allBlocks.filter { ($0.startTime < reviewCutoff || $0.isCompleted) && $0.habit != nil }
        let sweepOccurrences = ScheduleReviewViewModel.openHabitOccurrencesForReview(
            habits: allHabits,
            context: modelContext,
            upTo: reviewCutoff,
            completedSince: NightlyReviewCompletionState.shared.lastClosedReviewDay
        )
        DiagFileLog.write("SWEEP ENTER reviewDate=\(ISO8601DateFormatter().string(from: reviewDate).prefix(10)) cutoff=\(ISO8601DateFormatter().string(from: reviewCutoff).prefix(19)) habitBlocks=\(sweepBlocks.count) untimedOccurrences=\(sweepOccurrences.count)")
        for block in sweepBlocks {
            guard let habit = block.habit else { continue }
            // The LOG is authoritative; `block.isCompleted` is a mirror
            // written alongside it by every habit-completion path. This
            // loop used to consult only the flag and never the log, so a
            // log saying `.complete` got overwritten with `.missed`
            // whenever the flag had drifted — e.g. `HabitDetailView
            // .setDay`, which writes the log for a whole day and never
            // touches any block.
            //
            // Reading the log also closes the converse (flag `true`, log
            // `.none`, reachable by cycling a day back to unselected in
            // that same calendar): the old flag check skipped those, and
            // nothing else ever swept them, so the occurrence stayed
            // unresolved forever and counted as neither complete nor
            // missed in streak/rolling-30 math.
            //
            // `habitLog(for:on:)` routes through `Habit.logOrCreate`,
            // which FETCHES rather than traversing `habit.logs`, so this
            // sees a pending unsaved completion. Reading it any other way
            // would reintroduce the same blindness one layer up.
            let log = habitLog(for: habit, on: block.date)
            let status = log.occurrenceStatus(block.habitOccurrenceIndex)
            guard status == .none else { continue }
            log.setOccurrence(block.habitOccurrenceIndex, to: .missed)
        }
        for occurrence in sweepOccurrences {
            let log = habitLog(for: occurrence.habit, on: occurrence.targetTime)
            let status = log.occurrenceStatus(occurrence.index)
            guard !occurrence.isCompleted, status == .none else { continue }
            log.setOccurrence(occurrence.index, to: .missed)
        }
        HabitStatsRefreshCoordinator.shared.habitLogsChanged()
    }

    // MARK: - Step 3: Inbox (walks TaskCardSheet, one task at a time)

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

    // MARK: - Step 1: 2-Minute Tasks

    private var twoMinuteShelf: Shelf? {
        allShelves.first { $0.isTwoMinuteTasks }
    }

    /// The tasks snapshotted into `twoMinuteReviewTaskIDs` when this step
    /// was entered, oldest first — a fixed list for the duration of the
    /// step so checking one off doesn't yank it out from under the user.
    /// Now includes tasks already completed before the step was entered
    /// (see `advance()`'s `next == .twoMinuteTasks` branch), not just
    /// still-pending ones.
    private var twoMinuteReviewTasks: [TaskItem] {
        allTasks
            .filter { twoMinuteReviewTaskIDs.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func effectiveTwoMinuteCompleted(_ task: TaskItem) -> Bool {
        stagedTwoMinuteToggleIDs.contains(task.id) ? !task.isCompleted : task.isCompleted
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

    /// A tap anywhere on the row only flips membership in
    /// `stagedTwoMinuteToggleIDs` — the real `setCompleted` write (and the
    /// dirty-flag set that used to sit right here) is deferred to
    /// `advance()`'s `next == .tomorrow` branch, same visual-only-until-
    /// Next rule as the Today step's own rows. `.contentShape(Rectangle())`
    /// on the whole `HStack`, not just the circle, is what makes the title
    /// text and the `Spacer()`'s blank space tappable too.
    private func twoMinuteTaskRow(_ task: TaskItem) -> some View {
        let isCompleted = effectiveTwoMinuteCompleted(task)
        return HStack(spacing: 12) {
            twoMinuteSelectionCircle(isSelected: isCompleted)
            Text(task.title)
                .strikethrough(isCompleted)
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if stagedTwoMinuteToggleIDs.contains(task.id) {
                stagedTwoMinuteToggleIDs.remove(task.id)
            } else {
                stagedTwoMinuteToggleIDs.insert(task.id)
            }
        }
        .opacity(isCompleted ? 0.5 : 1)
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

    // MARK: - Step 5: Meals

    /// Ranked the same way Kitchen's own Meals tab ranks them (fewest
    /// missing ingredients first) — reused, not reimplemented, since
    /// "what can I actually make" is exactly the question this step is
    /// also asking, just with the answer feeding a `MealSelection`
    /// instead of a detail sheet.
    private var rankedRecipesForSelection: [(recipe: Recipe, missingCount: Int)] {
        MealSuggestionService.rankRecipes(allRecipes, pantryItems: kitchenPantryItems.map(\.title))
    }

    /// Already-selected for `planDate`, if any — drives the checkmark
    /// next to whichever recipe was picked, so re-entering this step
    /// (e.g. after Back) shows the existing choice rather than looking
    /// like nothing happened yet.
    private var plannedMealSelection: MealSelection? {
        allMealSelections.first { Calendar.current.isDate($0.date, inSameDayAs: planDate) }
    }

    @ViewBuilder
    private var mealsStep: some View {
        if allRecipes.isEmpty {
            ContentUnavailableView {
                Label("No Recipes Yet", systemImage: "fork.knife")
            } description: {
                Text("Add recipes from the Kitchen shelf's Cookbook tab, then come back here to plan one in.")
            }
        } else {
            List {
                Section {
                    ForEach(rankedRecipesForSelection, id: \.recipe.id) { entry in
                        Button {
                            selectMeal(entry.recipe)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.recipe.title)
                                    if entry.missingCount > 0 {
                                        Text("\(entry.missingCount) missing")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Spacer()
                                if plannedMealSelection?.recipeID == entry.recipe.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Pick a Meal")
                } footer: {
                    Text("Ranked by fewest missing ingredients, same as the Kitchen's own Meals tab. Placed on tomorrow's calendar at 5pm, locked.")
                }
                Section {
                    ForEach(kitchenPantryItems) { task in
                        pantryQuantityRow(task)
                    }
                } header: {
                    Text("Pantry")
                } footer: {
                    Text("Adjust anything that's out of date before picking a meal — deducting on completion reads these quantities.")
                }
            }
        }
    }

    private func pantryQuantityRow(_ task: TaskItem) -> some View {
        HStack {
            Text(task.title)
            Spacer()
            TextField("Qty", value: Binding(
                get: { task.quantity },
                set: { task.quantity = max(0, $0) }
            ), format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 60)
            Text(task.unit ?? "")
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
        }
    }

    /// Creates (or, if one already exists for `planDate`, updates in
    /// place) tomorrow's `MealSelection`, and inserts its 5pm calendar
    /// block. Re-picking after an earlier choice replaces the old block
    /// rather than leaving two — `removeExistingMealBlock` runs first.
    private func selectMeal(_ recipe: Recipe) {
        if let existing = plannedMealSelection {
            existing.recipeID = recipe.id
            existing.recipeTitle = recipe.title
            removeMealBlock(for: existing)
            insertMealBlock(for: existing)
        } else {
            let selection = MealSelection(recipeID: recipe.id, recipeTitle: recipe.title, date: planDate)
            modelContext.insert(selection)
            insertMealBlock(for: selection)
        }
    }

    private func removeMealBlock(for selection: MealSelection) {
        let allBlocksNow = (try? modelContext.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        for block in allBlocksNow where block.mealSelection?.id == selection.id {
            block.mealSelection = nil
            modelContext.delete(block)
        }
    }

    /// Always 5pm on `selection.date`, always locked from the moment it's
    /// created — see `ScheduledBlock.mealSelection`'s doc comment for why
    /// that's what lets a one-time direct insertion (bypassing
    /// `AISchedulingService` entirely) survive every later
    /// `regenerateFromNow` call without being cleared: its sweep removes
    /// any unlocked, unapproved, incomplete future block with no
    /// exception for whether `task`/`habit` is set, so `isLocked` is the
    /// only thing protecting it.
    private func insertMealBlock(for selection: MealSelection) {
        let calendar = Calendar.current
        guard let start = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: selection.date) else { return }
        let end = calendar.date(byAdding: .minute, value: 60, to: start) ?? start
        let block = ScheduledBlock(date: selection.date, startTime: start, endTime: end, task: nil)
        block.isLocked = true
        block.mealSelection = selection
        modelContext.insert(block)
    }

    // MARK: - Step 6: Tomorrow

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

    // MARK: - Step 4: At Risk

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
    /// Segment sizes valid for *this* task's current duration — only
    /// values that evenly divide it, so the packer can never be left with
    /// a remainder too small to place (see `TaskItem.validSegmentOptions`).
    /// Computed, not a static list: it has to track duration edits.
    private var segmentOptions: [Int] {
        TaskItem.validSegmentOptions(for: task.estimatedMinutes)
    }

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
                            // needs a value actually in its own range, and
                            // now also one that evenly divides the task's
                            // duration (see `validSegmentOptions(for:)`).
                            if !segmentOptions.contains(task.minimumSegmentMinutes) {
                                task.minimumSegmentMinutes = segmentOptions.first ?? 0
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
                    .disabled(segmentOptions.isEmpty)
                    .opacity(segmentOptions.isEmpty ? 0.4 : 1)

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

                    if isDivisibleYesSelected, !segmentOptions.isEmpty {
                        Picker("Minimum Segment", selection: $task.minimumSegmentMinutes) {
                            ForEach(segmentOptions, id: \.self) { minutes in
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
                if segmentOptions.isEmpty, task.estimatedMinutes > 0 {
                    // Stated rather than left as a toggle that silently
                    // refuses to turn on — a disabled control with no
                    // reason reads as broken.
                    Text("A \(TaskItem.durationLabel(for: task.estimatedMinutes)) task can't be split into even segments.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
            .onChange(of: task.estimatedMinutes) {
                // Duration edits can invalidate a segment size chosen
                // earlier, including clearing divisibility entirely when
                // the new duration has no divisor at all. Re-validating
                // here (not only on save) means the controls above show
                // that consequence at the moment it happens, rather than
                // the user discovering it later.
                task.validateDivisibility()
            }
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
                        // §9.2: an orphaned rule (its NamedSchedule was
                        // deleted — `.nullify`, by design) would otherwise
                        // render an ordinary-looking window here, via
                        // `summary`'s `effective*` fallbacks, with a live
                        // toggle — while `generateProposedSchedule`'s own
                        // `namedSchedule != nil` filter silently skips it.
                        // That's the §9 trap: it looks scheduled, it never
                        // schedules. Named explicitly and un-toggleable
                        // instead, matching what ShelfEditView's rule list
                        // already does.
                        let isOrphaned = rule.namedSchedule == nil
                        let fits = status == .fits && !isOrphaned
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
                                    Text(isOrphaned ? "No schedule assigned" : (rule.displayName.isEmpty ? rule.summary : rule.displayName))
                                        .font(.subheadline)
                                        .foregroundStyle(isOrphaned ? .red : .primary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    if !isOrphaned, !rule.displayName.isEmpty {
                                        Text(rule.summary)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                    }
                                }
                                if isOrphaned {
                                    Text("Won't pull any tasks until a schedule is reassigned")
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                } else if let caption = eligibleScheduleCaption(for: status) {
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
