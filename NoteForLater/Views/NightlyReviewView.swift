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
    @Query private var allPushedRecurringOccurrences: [PushedRecurringOccurrence]
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
    /// One instance for the whole Nightly Review session — see
    /// `InboxEngagementTimer`'s own doc comment for why it has to be a
    /// single, view-owned instance rather than something
    /// `startAttributeReviewSession()` creates fresh each time it builds
    /// `attributeReviewSession`.
    @State private var inboxEngagementTimer = InboxEngagementTimer()
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
    /// Which habit occurrences the Today step is reviewing, frozen the
    /// moment the step is entered (`runEntryEffects(for: .today)`) rather
    /// than re-derived on every render. Sourced from `ScheduleReviewViewModel
    /// .allHabitOccurrencesForReview` — the **display** list, every status,
    /// not `.openHabitOccurrencesForReview` (the **operational** list,
    /// `.none` only, what the sweep acts on) — so a habit already resolved
    /// before the step ever opened is part of the frozen set too, not just
    /// the ones still open. Habit rows cycle through the full four-state
    /// sequence via `Habit.cycleOccurrence` (see `cycleHabitReviewOccurrence`),
    /// writing immediately rather than staging like `stagedTodayToggleIDs`
    /// — the moment a row advances past `.none`, the operational list's
    /// own `status == .none` filter would otherwise drop it, making the
    /// row vanish mid-cycle with no way to tap it back out. This is a
    /// **display-only** fix layered on top of that filter, not a
    /// replacement for it: the filter still runs fresh, unfrozen,
    /// everywhere it actually protects something —
    /// `markUnresolvedHabitOccurrencesAsMissed`'s own sweep calls
    /// `openHabitOccurrencesForReview` directly and must keep doing so
    /// (see the spec's "What actually protects the untimed path"). This
    /// frozen list only decides which *rows this screen renders*; each
    /// row's own displayed status is still read live (see the
    /// `openHabitOccurrencesForReview` computed property below — same
    /// name as the operational list on purpose, since it's this view's
    /// own display-facing wrapper around the frozen set, not the
    /// operational list itself), so a row correctly shows whichever state
    /// it's actually in right now, not its state at the moment of freezing.
    ///
    /// **Do not "simplify" this by freezing each occurrence's `status`
    /// alongside its identity here.** That's the obvious version of this
    /// fix, and it's wrong: the whole point of freezing is to stop the
    /// filter from dropping a row once it leaves `.none`, not to stop the
    /// row from reflecting what you just tapped. Freeze the status too and
    /// every checkmark goes stale the instant you tap it — you'd see
    /// `.none` right after cycling to `.complete`, since the write landed
    /// in the model but the frozen copy never heard about it. Identity
    /// frozen, status live — that split is deliberate, not an oversight to
    /// clean up later.
    @State private var frozenTodayHabitOccurrences: [HabitReviewOccurrence] = []
    /// Same idea as `frozenTodayHabitOccurrences`, for AM/Midday/PM
    /// recurring task occurrences — populated from `ScheduleReviewViewModel
    /// .allRecurringTaskOccurrencesForReview` (display list, every status),
    /// never `openRecurringTaskOccurrencesForReview` (operational, `.none`
    /// only) for the identical reason `frozenTodayHabitOccurrences` isn't
    /// either. Identity frozen, status read live — same split, same
    /// "do not simplify this back together" warning.
    @State private var frozenTodayRecurringTaskOccurrences: [ScheduleReviewViewModel.RecurringTaskReviewOccurrence] = []
    /// Ids of `PushedRecurringOccurrence` records created by an
    /// interactive missed-tap during this Today step (see `pushIfMissed`),
    /// as opposed to `advance()`'s own batch sweep — tracked so the
    /// one-hop-forward step in `advance()` catches these too, not just the
    /// batch-created ones. See that call site's own comment.
    @State private var immediatelyPushedRecurringOccurrenceIDs: Set<UUID> = []
    /// Set to a `ReviewItem.id` to make `OverdueBlocksReviewList` scroll
    /// that row into view — how `jumpToFirstUnresolvedGateItem` finds a
    /// blocking row in a long list. Self-resets to `nil` after each
    /// scroll (see `OverdueBlocksReviewList.scrollTarget`), so no reset
    /// needed elsewhere.
    @State private var scrollToReviewItemID: String? = nil
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
    /// Drives the "X is empty — skipped" auto-skip toast (see
    /// `advance()`/`presentSkipToast`) — a separate pair from
    /// `TaskReviewCard`'s own `toastMessage`/`toastVisible` further down
    /// this file; that's a different view struct entirely.
    @State private var skipToastMessage: String?
    @State private var skipToastVisible = false

    private let calendarService: CalendarServiceProtocol = GoogleCalendarService()
    private let schedulingService: AISchedulingServiceProtocol = MockAISchedulingService()

    /// Internal, not `private` — `autoSkipEligible` needs to be directly
    /// testable (`NightlyReviewViewStepAutoSkipTests`) without constructing
    /// a live `NightlyReviewView`, which its `@Query` properties make
    /// impractical from a unit test. Still only ever referenced as
    /// `NightlyReviewView.Step` from outside this file — nothing about it
    /// is meant for use elsewhere.
    enum Step: Int, CaseIterable, Hashable {
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

        /// Short, day-independent name for the auto-skip toast — unlike
        /// `title(planDate:)`, never used as a navigation title, so it
        /// doesn't need to be unique or descriptive on its own, just
        /// readable inside "X and Y are empty — skipped."
        var skipLabel: String {
            switch self {
            case .chooseDay: return "Which Day?"
            case .twoMinuteTasks: return "2-Minute Tasks"
            case .today: return "Review Schedule"
            case .inbox: return "Inbox"
            case .atRisk: return "At Risk"
            case .meals: return "Meals"
            case .tomorrow: return "Plan Tomorrow"
            }
        }

        /// Steps `advance()`/`back()` are allowed to walk straight past
        /// when they turn out empty — deliberately excludes `.chooseDay`
        /// (never reached as a "next" candidate anyway), `.today` (where
        /// nothing missed gets confirmed — always shown even if sparse),
        /// and `.tomorrow` (the final approval screen — same reasoning).
        static let autoSkipEligible: Set<Step> = [.twoMinuteTasks, .inbox, .atRisk, .meals]
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
    /// own filter, not just an exact-day match: a `MealSelection` picked
    /// two nights ago and never checked off shouldn't have to wait for
    /// that day's own review to surface, the same way an overdue block
    /// doesn't. See `ScheduleReviewViewModel.todayMealSelections` for the
    /// completed-vs-incomplete date bounding.
    private var todayMealSelections: [MealSelection] {
        ScheduleReviewViewModel.todayMealSelections(
            allMealSelections: allMealSelections,
            cutoffDay: Calendar.current.startOfDay(for: reviewDate),
            completedSinceBound: NightlyReviewCompletionState.shared.completedSinceBound
        )
    }

    private var planRelativeDayLabel: String {
        ChooseDayPlanning.planRelativeDayLabel(planDate: planDate, now: .now, calendar: Calendar.current)
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
            .overlay(alignment: .top) {
                if let skipToastMessage {
                    Text(skipToastMessage)
                        .font(.subheadline.weight(.medium))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(.quaternary))
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                        .padding(.top, 8)
                        .opacity(skipToastVisible ? 1 : 0)
                        .offset(y: skipToastVisible ? 0 : -8)
                        .allowsHitTesting(false)
                }
            }
            .sheet(item: $attributeReviewSession) { session in
                TaskReviewQueueSheet(
                    shelves: routableInboxShelves,
                    queue: session.queue,
                    engagementTimer: session.engagementTimer,
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
        VStack(spacing: 6) {
            // Deliberately its own row, above the buttons, rather than a
            // disabled-Next tooltip — a dead button with no visible reason
            // reads as broken, not gated (see `unresolvedGateReviewItems`'s
            // own comment for exactly what this counts and why).
            if step == .today, !unresolvedGateReviewItems.isEmpty {
                Button(action: jumpToFirstUnresolvedGateItem) {
                    Label(unresolvedGateMessage, systemImage: "arrow.down.circle")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }
            HStack {
                Button("Close") { finishAndDismiss() }
                if step != .chooseDay {
                    Button("Back", action: back)
                }
                Spacer()
                if step == .tomorrow {
                    Button("Done") { finishAndDismiss() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Next", action: advance)
                        .buttonStyle(.borderedProminent)
                        .disabled(step == .today && !unresolvedGateReviewItems.isEmpty)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// **The Today-step Next gate — habits and recurring tasks,
    /// deliberately scoped to exactly those two.** Built by filtering
    /// `reviewItems` itself (the same merged, sorted list the step
    /// renders), so a row's gate status and its rendered position always
    /// agree, and "jump to first" below lands on whichever blocking row
    /// actually appears first on screen — not a second, independently-
    /// ordered notion of "first."
    ///
    /// Non-recurring blocks and meals are **not** part of this gate, and
    /// must not be added to it later without re-litigating this: both
    /// only ever expose a single `isCompleted` boolean with no
    /// "explicitly decided not done" state distinct from "haven't looked
    /// at it yet," and leaving one incomplete is the normal, expected
    /// input the push-forward pipeline is built around — `advance()`
    /// already pushes an incomplete non-recurring task forward
    /// (`guaranteePlacement`) and an incomplete meal just sits in next
    /// time's backlog by design (see `todayMealSelections`). Gating Next
    /// on those being "resolved" would block the review on any ordinary
    /// night with leftover work, with no way to explicitly clear it short
    /// of falsely marking it complete — a permanently uncompletable
    /// review, which is worse than the missed-row problem this gate
    /// exists to solve.
    ///
    /// Habits and recurring tasks are different: both cycle through a
    /// bounded set of genuine terminal states (`Habit.cycleOccurrence`'s
    /// four, `TaskItem.cycleRecurringOccurrence`'s three) in a bounded
    /// number of taps, and `.none` is the one state either design treats
    /// as "not actually looked at yet," never as an accepted final state
    /// — see the missed sweeps this gate makes largely redundant but does
    /// not replace, `markUnresolvedHabitOccurrencesAsMissed` and
    /// `pushMissedRecurringOccurrences`. A recurring task's Specific-Time
    /// occurrence is included here even though it renders as `.block` —
    /// `task.isRecurring` is what tells it apart from an ordinary,
    /// deliberately-ungated block.
    private var unresolvedGateReviewItems: [ReviewItem] {
        reviewItems.filter { item in
            switch item {
            case .habit(let occurrence): return occurrence.status == .none
            case .recurringTask(let occurrence): return occurrence.status == .none
            case .block(let block):
                guard let task = block.task, task.isRecurring, task.recurrenceTimeMode == .specific else { return false }
                return ScheduleReviewViewModel.recurringTaskOccurrenceStatus(task: task, on: block.date, context: modelContext) == .none
            case .completedTask, .meal: return false
            }
        }
    }

    private var unresolvedGateMessage: String {
        let habitCount = unresolvedGateReviewItems.filter { if case .habit = $0 { return true }; return false }.count
        let taskCount = unresolvedGateReviewItems.count - habitCount
        return ScheduleReviewViewModel.unresolvedGateMessage(unresolvedHabitCount: habitCount, unresolvedRecurringTaskCount: taskCount)
    }

    /// Scrolls the first blocking row (in the same order the list itself
    /// renders — see `unresolvedGateReviewItems`) into view. Jumps to the
    /// first only; tapping again after resolving it lands on whichever is
    /// first next, which in practice walks the whole blocking set one tap
    /// at a time.
    private func jumpToFirstUnresolvedGateItem() {
        guard let first = unresolvedGateReviewItems.first else { return }
        scrollToReviewItemID = first.id
    }

    /// Mirrors `advance()`'s forward auto-skip, in reverse: walks backward
    /// past any step that's both auto-skip-eligible and *currently* empty,
    /// so stepping back from a step reached by skipping forward doesn't
    /// immediately drop you onto the very empty step(s) just skipped —
    /// re-checked live via `isStepCurrentlyEmpty`, not a stale record of
    /// what was skipped on the way in, since going back can follow
    /// arbitrary time later than the forward walk that got here. Runs no
    /// entry side effects while walking backward (`onEnter` is a no-op)
    /// — Back has never re-run a step's "entering" work, and re-running
    /// e.g. the staged-toggle commits here would double-apply them.
    /// Floored at `.chooseDay`, which is never eligible, so this can never
    /// loop — same defensive `maxSteps` cap `advance()` uses regardless.
    private func back() {
        let start = Step(rawValue: step.rawValue - 1) ?? .chooseDay
        let result = StepAutoSkip.walkForward(
            from: start,
            next: { Step(rawValue: $0.rawValue - 1) ?? .chooseDay },
            isEligible: { Step.autoSkipEligible.contains($0) },
            isEmpty: isStepCurrentlyEmpty,
            onEnter: { _ in },
            maxSteps: Step.allCases.count
        )
        step = result.landed
    }

    /// Whether `step` currently has nothing to show — mirrors exactly the
    /// condition each step's own view branches on to render its
    /// `ContentUnavailableView` empty state, so a step this reports as
    /// empty is never one that would have shown different content had the
    /// user actually landed on it. Only meaningful for
    /// `Step.autoSkipEligible` members; every other step reports `false`
    /// unconditionally so it's never a candidate to skip regardless of
    /// what it'd otherwise evaluate to.
    ///
    /// For `.twoMinuteTasks`/`.inbox`, this reads state
    /// (`twoMinuteReviewTasks`/`attributeReviewSession`) that's only
    /// accurate *after* that step's own entry effect has run this pass —
    /// `runEntryEffects(for:)` always runs before this is consulted (see
    /// `StepAutoSkip.walkForward`'s doc comment), so it never reads a
    /// stale snapshot left over from further back in the same walk.
    private func isStepCurrentlyEmpty(_ step: Step) -> Bool {
        switch step {
        case .chooseDay, .today, .tomorrow: return false
        case .twoMinuteTasks: return twoMinuteReviewTasks.isEmpty
        case .inbox: return attributeReviewSession == nil
        case .atRisk: return atRiskTasks.isEmpty
        case .meals: return allRecipes.isEmpty
        }
    }

    /// Every per-transition side effect `advance()` used to hang off
    /// `next == <step>` (staged-toggle commits, starting the Inbox review
    /// session, the recurring-occurrence push and `guaranteePlacement`,
    /// the Tomorrow regenerate) — now keyed to run for *any* step this
    /// pass's walk enters, whether it ends up shown or skipped. That's the
    /// whole point of calling this from `StepAutoSkip.walkForward`'s
    /// `onEnter` rather than only for the step the walk finally lands on:
    /// an empty `.inbox` still needs its Today-exit commit batch (staged
    /// toggles, meal completion + pantry deduction, the recurring push,
    /// `guaranteePlacement`) to run, exactly as if the user had tapped
    /// Next onto it and then off again, even though it's never actually
    /// shown on screen.
    private func runEntryEffects(for next: Step) {
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
            // Frozen exactly once, on entry — see `frozenTodayHabitOccurrences`'s
            // own doc comment for why this can't just be re-derived live on
            // every render the way it used to be. Deliberately
            // `allHabitOccurrencesForReview` (every status), not
            // `openHabitOccurrencesForReview` (`.none` only, what the sweep
            // acts on) — freezing the *filtered* call's result would mean
            // a habit already resolved before the step opened never
            // entered the frozen set in the first place, the exact gap
            // this exists to close. See both functions' own doc comments
            // for the display/operational split.
            frozenTodayHabitOccurrences = ScheduleReviewViewModel.allHabitOccurrencesForReview(
                habits: allHabits,
                context: modelContext,
                upTo: reviewDisplayCutoff,
                completedSince: NightlyReviewCompletionState.shared.lastClosedReviewDay
            )
            // Same freeze, same reasoning, for AM/Midday/PM recurring
            // tasks — see `frozenTodayRecurringTaskOccurrences`'s own doc
            // comment.
            frozenTodayRecurringTaskOccurrences = ScheduleReviewViewModel.allRecurringTaskOccurrencesForReview(
                tasks: allTasks,
                context: modelContext,
                upTo: reviewDisplayCutoff,
                completedSince: NightlyReviewCompletionState.shared.lastClosedReviewDay
            )
        }
        if next == .twoMinuteTasks {
            let pending = (twoMinuteShelf?.tasks ?? []).filter { !$0.isCompleted && $0.isEligibleToStart(on: reviewDate) }
            // Also pick up anything completed earlier today (or since the
            // last review closed), before this step's own snapshot: the
            // old `!$0.isCompleted`-only filter hid these permanently —
            // there's no later chance to see them, since a completed
            // 2-minute task never gets a block `reviewableBlocks` could
            // have shown it through instead.
            // Same day-granularity bound as `completedTasksWithNoBlock` —
            // see `NightlyReviewCompletionState.completedSinceBound`'s doc
            // comment for the off-by-one a plain `lastClosedReviewDay`
            // comparison here used to re-introduce.
            let since = NightlyReviewCompletionState.shared.completedSinceBound
            let completedRecords = (try? modelContext.fetch(FetchDescriptor<TaskCompletionRecord>(
                predicate: #Predicate { $0.completedAt >= since }
            ))) ?? []
            let completedTaskIDs = Set(completedRecords.map(\.taskID))
            let recentlyCompleted = (twoMinuteShelf?.tasks ?? []).filter { completedTaskIDs.contains($0.id) }
            twoMinuteReviewTaskIDs = Set(pending.map(\.id) + recentlyCompleted.map(\.id))
            stagedTwoMinuteToggleIDs = []
        }
        if next == .inbox {
            startAttributeReviewSession()
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
                case .habit:
                    // Never actually reached — a `.habit` tap writes
                    // immediately via `cycleHabitReviewOccurrence`
                    // (see `todayStep`), so its id never lands in
                    // `stagedTodayToggleIDs` for this loop's own `where`
                    // clause to match.
                    break
                case .recurringTask:
                    // Never actually reached — same reasoning as `.habit`:
                    // a `.recurringTask` tap writes immediately via
                    // `cycleRecurringTaskReviewOccurrence`.
                    break
                case .completedTask:
                    break
                case .meal:
                    // Never actually reached — a `.meal` tap stages into
                    // `stagedMealSelectionIDs`, not `stagedTodayToggleIDs`
                    // (see `todayStep`), so this loop's own `where`
                    // clause never matches one. Committed separately,
                    // right below, since that commit also needs to
                    // trigger pantry deduction — something neither a
                    // block nor a habit occurrence ever does.
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
            let frozenReviewDate = reviewDate
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

            // A recurring task's own incomplete block is about to be
            // deleted outright by `clearIncompletePastBlocks` below, same
            // as any other stale block, with nothing else stepping in to
            // replace it — captured here, before that happens, so there's
            // something to push forward instead of the occurrence just
            // silently vanishing until its next real recurrence day. Also
            // covers AM/Midday/PM recurring tasks, which never have a
            // block for the state above to capture in the first place (see
            // `ScheduleReviewViewModel.pushMissedRecurringOccurrences`'s own
            // doc comment). Skips any task that's already being pushed (an
            // earlier miss that hasn't resolved yet) — that record's own
            // `currentDate` already points at today, so there's nothing new
            // to record.
            let freshlyPushedRecurringOccurrences = ScheduleReviewViewModel.pushMissedRecurringOccurrences(
                reviewedBlocks: reviewedBlocks, tasks: allTasks, context: modelContext, cutoff: frozenCutoff
            )
            // Immediate-tap-created pushes (see `pushIfMissed`, fired
            // whenever cycling a habit-style row this step landed on
            // `.missed`) aren't in `freshlyPushedRecurringOccurrences` —
            // that only holds records the sweep call just above created
            // itself. Fetched here by id and folded in below so the
            // hop-forward loop treats both origins identically — without
            // this, a tap-created push would sit at today's date, un-
            // hopped, until the next app launch, silently undoing "pushes
            // immediately." A push a later tap in this same session
            // resolved (cycled back past `.missed` to `.complete`) is
            // deleted here instead of hopped — reusing `isAlreadyResolved`,
            // written for exactly this, rather than a second bespoke check.
            let calendarForPushCleanup = Calendar.current
            let tapPushedRecurringOccurrences: [(occurrence: PushedRecurringOccurrence, task: TaskItem, missedDay: Date)] = immediatelyPushedRecurringOccurrenceIDs.compactMap { id in
                guard let occurrence = (try? modelContext.fetch(FetchDescriptor<PushedRecurringOccurrence>(predicate: #Predicate { $0.id == id })))?.first,
                      let task = allTasks.first(where: { $0.id == occurrence.taskID })
                else { return nil }
                if PushedRecurringOccurrence.isAlreadyResolved(occurrence, task: task, calendar: calendarForPushCleanup, context: modelContext) {
                    modelContext.delete(occurrence)
                    return nil
                }
                guard calendarForPushCleanup.isDate(occurrence.currentDate, inSameDayAs: occurrence.originalDate) else { return nil }
                return (occurrence, task, occurrence.originalDate)
            }
            immediatelyPushedRecurringOccurrenceIDs = []
            let allFreshRecurringTaskPushes = freshlyPushedRecurringOccurrences + tapPushedRecurringOccurrences

            // A non-recurring task's own incomplete block is about to be
            // deleted outright by `clearIncompletePastBlocks` below too —
            // captured here, before it's gone, so `guaranteePlacement`
            // in the Task below has the original day/time/duration to
            // rebuild from. Without this, an incomplete task was merely
            // freed up to maybe get picked up by a future general
            // regenerate walk — which is exactly how a task with room
            // genuinely free in its own eligible window could still just
            // never actually land (see `RippleSchedulingService`'s own
            // doc comment for the concrete "Stirfry recipes" bug this
            // fixes).
            let missedNonRecurringPlacements = reviewedBlocks.compactMap { block -> (task: TaskItem, date: Date, startTime: Date, durationMinutes: Int)? in
                guard !block.isCompleted, let task = block.task, !task.isRecurring else { return nil }
                return (task, block.date, block.startTime, block.durationMinutes)
            }

            // Any habit occurrence the Today review showed but never got
            // checked off — timed or not — is done being reviewable the
            // moment Today is left behind, so it's marked missed right
            // here, synchronously, before any of the async cleanup below.
            // Deliberately not folded into `clearIncompletePastBlocks`
            // itself (used here too, just below): a passed-but-undone
            // habit should still get a fresh shot later *today* during an
            // ordinary intra-day Regenerate, not be written off — only
            // Nightly Review's own end-of-day handoff means "no more
            // chances left." (Correcting a stale claim this comment used
            // to make: `clearIncompletePastBlocks` does *not* currently
            // have another caller from any Regenerate flow — grepped while
            // verifying `reviewCutoff`'s widened-cutoff change was safe,
            // confirmed exactly one call site, right below. The design
            // reasoning above still holds regardless — habits and blocks
            // are swept by two genuinely different mechanisms on purpose —
            // it just isn't *currently* enforced by a second caller the
            // way this used to say.)
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
                tomorrowViewModel.purgeCompletedMealSelections()
                tomorrowViewModel.resolveIncompleteMealSelections(reviewDate: frozenReviewDate)
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
                // Guaranteed placement, not left to `regenerateFromNow`
                // below to maybe find room — sets `task.isScheduled =
                // true` on each one, so the general walk's own
                // `!$0.isScheduled` filter (`AISchedulingService.swift`)
                // naturally leaves them alone rather than fighting over
                // the same slot this just claimed.
                for placement in missedNonRecurringPlacements {
                    tomorrowViewModel.guaranteePlacement(for: placement.task, missedDate: placement.date, missedStartTime: placement.startTime, durationMinutes: placement.durationMinutes)
                }
                // Same guarantee as `guaranteePlacement` above, for a
                // recurring miss: rather than leaving the record it just
                // created sitting at today's date until the next app
                // launch's catch-up walk gets to it
                // (`NoteForLaterApp.processPushedRecurringOccurrencesIfNeeded`),
                // hop it forward one day — onto tomorrow — right now, via
                // the exact function that walk uses per day
                // (`PushedRecurringOccurrence.advanceOneHop`). Only ever
                // one hop, for records created by *this* review — a task
                // whose miss dates further back (the review didn't run for
                // several nights) is still left for that launch-time walk
                // to catch all the way up, deliberately: this Task isn't
                // the place to fast-forward stale backlog.
                let calendar = Calendar.current
                for pushed in allFreshRecurringTaskPushes {
                    guard let next = calendar.date(byAdding: .day, value: 1, to: pushed.missedDay) else { continue }
                    PushedRecurringOccurrence.advanceOneHop(pushed.occurrence, task: pushed.task, from: pushed.missedDay, to: next, calendar: calendar, context: modelContext)
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

    /// Builds the "X and Y are empty — skipped" toast body for whatever
    /// `advance()`'s walk actually skipped this pass — one combined
    /// message regardless of how many steps got skipped, never one per
    /// step, so a multi-step skip doesn't stack several toasts on top of
    /// each other.
    private func skipToastMessage(for skipped: [Step]) -> String? {
        guard !skipped.isEmpty else { return nil }
        let names = skipped.map(\.skipLabel)
        let joined: String
        switch names.count {
        case 1: joined = names[0]
        case 2: joined = "\(names[0]) and \(names[1])"
        default: joined = names.dropLast().joined(separator: ", ") + ", and " + names[names.count - 1]
        }
        let verb = names.count == 1 ? "is" : "are"
        return "\(joined) \(verb) empty — skipped"
    }

    /// Non-blocking, self-dismissing — the whole point of auto-skip is
    /// fewer taps, so this must never require one back. Mirrors
    /// `TaskReviewCard.showToast`'s timing/animation shape (this view's
    /// own `skipToastMessage`/`skipToastVisible` are separate state, since
    /// `TaskReviewCard` is a different view further down this file).
    private func presentSkipToast(_ message: String) {
        skipToastVisible = false
        skipToastMessage = message
        withAnimation(.easeOut(duration: 0.25)) {
            skipToastVisible = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            withAnimation(.easeOut(duration: 0.3)) {
                skipToastVisible = false
            }
        }
    }

    private func advance() {
        if step == .chooseDay {
            setupViewModels()
        }
        let start = Step(rawValue: step.rawValue + 1) ?? .tomorrow
        let result = StepAutoSkip.walkForward(
            from: start,
            next: { Step(rawValue: $0.rawValue + 1) ?? .tomorrow },
            isEligible: { Step.autoSkipEligible.contains($0) },
            isEmpty: isStepCurrentlyEmpty,
            onEnter: runEntryEffects,
            maxSteps: Step.allCases.count
        )
        step = result.landed
        if let message = skipToastMessage(for: result.skipped) {
            presentSkipToast(message)
        }
    }

    /// Both "Close" and "Done" route through here rather than calling
    /// `dismiss()` directly — an explicit save first, since neither one
    /// otherwise flushes anything to disk. Most writes this session makes
    /// do eventually reach a real `ScheduledBlock`/`TaskItem` write (task
    /// completions, habit toggles, and so on all mutate live SwiftData
    /// models), but a straight `dismiss()` was relying entirely on
    /// SwiftData's own opportunistic autosave to actually persist that —
    /// which isn't guaranteed to run before the app is later force-quit or
    /// the device locks. Concretely: swiping to delete a block on the
    /// Tomorrow step (`ScheduleReviewViewModel.deleteBlock`) does call
    /// `modelContext.delete(block)` right away, but that deletion was only
    /// ever actually durable if autosave happened to fire in the window
    /// between the swipe and whatever came next — otherwise the block was
    /// still sitting in the store the next time the app launched, exactly
    /// as if the delete had silently not happened at all.
    private func finishAndDismiss() {
        try? modelContext.save()
        dismiss()
    }

    // MARK: - Step 0: Choose Day

    /// Any incomplete task block or open habit occurrence dated strictly
    /// before today. No longer gates the "Today" button in `chooseDayStep`
    /// — see `ChooseDayPlanning.isPlanTodayOptionDisabled`'s own doc
    /// comment for why disabling it on this used to be backwards. Kept in
    /// case something else still wants a plain "is there backlog" read.
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
                    reviewDate = ChooseDayPlanning.reviewDate(forPlanning: .today, now: .now, calendar: Calendar.current)
                } label: {
                    HStack {
                        Text("Today")
                            .foregroundStyle(.white)
                        Spacer()
                        if Calendar.current.isDateInYesterday(reviewDate) {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .disabled(ChooseDayPlanning.isPlanTodayOptionDisabled(hasAnythingToReviewBeforeToday: hasAnythingToReviewBeforeToday))
                Button {
                    reviewDate = ChooseDayPlanning.reviewDate(forPlanning: .tomorrow, now: .now, calendar: Calendar.current)
                } label: {
                    HStack {
                        Text("Tomorrow")
                            .foregroundStyle(.white)
                        Spacer()
                        if Calendar.current.isDateInToday(reviewDate) {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
            } header: {
                Text("Which day are you planning?")
            }

            Section {
                DatePicker(
                    "Plan a different day",
                    selection: Binding(
                        get: { planDate },
                        set: { reviewDate = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: -1, to: $0) ?? $0) }
                    ),
                    in: ...(Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now)) ?? Date()),
                    displayedComponents: .date
                )
            } footer: {
                Text("Catching up on an earlier day? Pick the day you're planning here — it closes out the day right before it, same as Today and Tomorrow above.")
            }
        }
        .onChange(of: reviewDate) { _, _ in
            stagedTodayToggleIDs = []
            stagedMealSelectionIDs = []
            frozenTodayHabitOccurrences = []
            frozenTodayRecurringTaskOccurrences = []
        }
        .onAppear {
            // Only ever applied once — after this, whatever the user
            // picked (including manually re-selecting Tomorrow) sticks,
            // even if they navigate back to this step later.
            guard !hasAppliedDefaultReviewDate else { return }
            hasAppliedDefaultReviewDate = true
            let choice = ChooseDayPlanning.defaultPlanningChoice(now: .now, calendar: Calendar.current)
            reviewDate = ChooseDayPlanning.reviewDate(forPlanning: choice, now: .now, calendar: Calendar.current)
        }
    }

    // MARK: - Step 2: Today

    /// Used only for *operational* decisions — actually marking something
    /// missed, or clearing/rescheduling an incomplete block — never for
    /// what the Today step displays (see `reviewDisplayCutoff` for that,
    /// though the two are now computed identically — see below).
    ///
    /// **Deliberately no longer clamped to `.now`.** This used to be
    /// `min(.now, dayEnd)`, so reviewing at 7pm with `reviewDate` = today
    /// gave a 7pm cutoff — a 9pm habit or task was correctly still
    /// *displayed* (`reviewDisplayCutoff` never clamped), but the sweep
    /// and the past-block clear below both read *this* property, so
    /// neither one ever touched it: it stayed `.none`, showed up again in
    /// the next review, and the cycle repeated forever. That protection
    /// was intentional once — "a block later today hasn't happened yet
    /// and can't legitimately be judged missed until its own time
    /// actually passes" — but it's the wrong call for what this cutoff
    /// actually gates: by the time you're doing the Today→Tomorrow
    /// handoff, the review's own premise is that today is done being
    /// planned, whatever the wall clock says. A 9pm habit not done by the
    /// time you sit down to close out the day out **is** incomplete, full
    /// stop — reviewing early doesn't make it any less so. `reviewDate`
    /// itself already can't be later than today (see `ChooseDayPlanning`/
    /// the "Plan a different day" `DatePicker`'s own upper bound), so this
    /// change only ever widens what's swept on the reviewDate=today path;
    /// every earlier-`reviewDate` path (Plan Today, or the DatePicker's
    /// own "catching up on an earlier day" case) had `dayEnd` already
    /// before `.now` regardless, so the clamp was already inert there —
    /// verified directly, not assumed, by tracing all three ways
    /// `reviewDate` gets set.
    ///
    /// Shared by `markUnresolvedHabitOccurrencesAsMissed`,
    /// `advance()` (what gets frozen as `frozenCutoff`, for both
    /// `clearIncompletePastBlocks` and `pushMissedRecurringOccurrences` —
    /// the latter not originally called out when this cutoff was widened,
    /// found by grepping every reader rather than trusting the two
    /// already-known ones). Widening is correct for all three: each one
    /// exists specifically to resolve "is this actually done," and none of
    /// them should stop early just because the review happened to run
    /// before midnight.
    private var reviewCutoff: Date {
        ScheduleReviewViewModel.nightlyReviewOperationalCutoff(reviewDate: reviewDate)
    }

    /// What the Today step actually *shows* — always the full span of
    /// `reviewDate`, regardless of what time it currently is. Computed
    /// identically to `reviewCutoff` now that the latter no longer clamps
    /// to `.now` — kept as a separate named property rather than merged
    /// into one, since they answer conceptually different questions
    /// ("what should be visible" vs. "what should be treated as settled")
    /// that happened to converge once the review's own premise became
    /// "today is done being planned as of right now, regardless of the
    /// clock" — a future change to either one's semantics shouldn't have
    /// to first re-discover this distinction.
    private var reviewDisplayCutoff: Date {
        ScheduleReviewViewModel.nightlyReviewOperationalCutoff(reviewDate: reviewDate)
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
        // `mealSelection != nil` blocks are excluded here — a meal gets
        // its own `.meal` `ReviewItem` (see `reviewItems`) instead, sorted
        // into the same list by that same block's own `startTime`.
        // Without this exclusion the same meal would show up twice: once
        // correctly, once as a bare "Dinner: X" block row with no pantry-
        // deduction wiring behind its tap at all. See
        // `ScheduleReviewViewModel.reviewableBlocks` for the completed-
        // vs-incomplete date bounding.
        ScheduleReviewViewModel.reviewableBlocks(
            allBlocks: allBlocks,
            reviewDisplayCutoff: reviewDisplayCutoff,
            completedSinceBound: NightlyReviewCompletionState.shared.completedSinceBound
        )
    }

    /// Blocks, open habit occurrences, completed-with-no-block tasks, and
    /// tonight's meal(s) mixed into one list, organized by time within
    /// each day — see `ReviewItem`/`OverdueBlocksReviewList`. This is what
    /// makes habits, tasks, and dinner land in the same order they
    /// actually sit on the calendar, instead of dinner being hardcoded to
    /// the top regardless of its own scheduled time — and, separately,
    /// what pins a 2-Minute Task completion to the very front of its day
    /// regardless of either: `isTwoMinuteTask` is checked against
    /// `twoMinuteReviewTaskIDs` (this session's own snapshot from the
    /// step just before this one) rather than the record's live task,
    /// since nothing guarantees that task is still around by the time
    /// this reads it.
    private var reviewItems: [ReviewItem] {
        reviewableBlocks.map { .block($0) }
            + openHabitOccurrencesForReview.map { .habit($0) }
            + openRecurringTaskOccurrencesForReview.map { .recurringTask($0) }
            + completedTasksWithNoBlock.map { record in
                .completedTask(record, isTwoMinuteTask: twoMinuteReviewTaskIDs.contains(record.taskID))
            }
            + todayMealSelections.map { selection in
                // The real backing block's own `startTime` (see
                // `insertMealBlock`) is what a meal actually sorts
                // by — `MealSelection.date` alone is day-granularity
                // only, with no time-of-day to sort against. Falls back
                // to `selection.date` only if that block's since gone
                // missing somehow, which shouldn't normally happen.
                let targetTime = allBlocks.first { $0.mealSelection?.id == selection.id }?.startTime ?? selection.date
                return .meal(selection, targetTime: targetTime)
            }
    }

    /// Task completions with no live `ScheduledBlock` to represent them —
    /// a 2-Minute Task completed in the step just before this one, and the
    /// older Task Attribute Review "Mark Complete" path, both leave a task
    /// like this, and `purgeCompletedBlocks` deletes it outright the
    /// moment this review's Today step commits. Without this,
    /// `reviewableBlocks` (block-only) never shows it at all, and it's
    /// gone for good the instant Next is tapped. `TaskCompletionRecord` is
    /// the durable trace that survives that delete, so it's sourced from
    /// there rather than from `allTasks` directly — that also covers a
    /// task purged by an *earlier* Nightly Review session that's since
    /// come and gone (and, not incidentally, a 2-Minute Task completed
    /// this same session: `setCompleted` doesn't delete it right away, but
    /// nothing guarantees it's still live by the time this reads —
    /// `reviewItems`'s own `isTwoMinuteTask` flag is what keeps it sorted
    /// to the front regardless, via `twoMinuteReviewTaskIDs` rather than
    /// this task's own, possibly-already-gone `shelf`).
    private var completedTasksWithNoBlock: [TaskCompletionRecord] {
        ScheduleReviewViewModel.completedTasksWithNoBlock(
            tasks: allTasks, context: modelContext,
            completedSince: NightlyReviewCompletionState.shared.lastClosedReviewDay
        )
    }

    /// A tap on a `.block`/`.meal` item only flips membership in
    /// `stagedTodayToggleIDs`/`stagedMealSelectionIDs` — no model write
    /// happens until `advance()` commits the batch on Next (§ requirement
    /// that Today-step taps be visual-only and reversible).
    /// `effectiveCompleted` is what lets those rows render that pending
    /// state without touching the underlying model directly. A `.habit`
    /// tap is different: it writes immediately, via `Habit.cycleOccurrence`
    /// (see `cycleHabitReviewOccurrence`) — there's no staged "pending
    /// flip" for a four-state cycle to represent, since the next tap's
    /// result depends on knowing which of the four states the row is
    /// *actually* in right now.
    @ViewBuilder
    private var todayStep: some View {
        if todayViewModel != nil {
            OverdueBlocksReviewList(items: reviewItems, onToggle: { item in
                switch item {
                case .habit(let occurrence):
                    cycleHabitReviewOccurrence(occurrence)
                case .recurringTask(let occurrence):
                    cycleRecurringTaskReviewOccurrence(occurrence)
                case .meal(let selection, _):
                    if stagedMealSelectionIDs.contains(selection.id) {
                        stagedMealSelectionIDs.remove(selection.id)
                    } else {
                        stagedMealSelectionIDs.insert(selection.id)
                    }
                case .block(let block) where block.task?.isRecurring == true:
                    // A recurring task's Specific-Time block goes through
                    // the same immediate 3-state cycle as `.recurringTask`
                    // above — it's never staged, same reasoning as
                    // `.habit`/`.recurringTask`: the next tap's result
                    // depends on the block's *actual* current status, which
                    // a staged pending-flip can't represent for more than
                    // two states.
                    cycleRecurringTaskReviewOccurrence(block: block)
                case .block, .completedTask:
                    if stagedTodayToggleIDs.contains(item.id) {
                        stagedTodayToggleIDs.remove(item.id)
                    } else {
                        stagedTodayToggleIDs.insert(item.id)
                    }
                }
            }, isEffectivelyCompleted: effectiveCompleted, scrollTarget: $scrollToReviewItemID)
        } else {
            ProgressView()
        }
    }

    /// `.meal` reads/writes `stagedMealSelectionIDs` instead of
    /// `stagedTodayToggleIDs` — see `todayStep`'s own doc comment for why
    /// it needs its own separate staged set. `.habit` is never actually
    /// consulted here — `OverdueBlocksReviewList.row(for:)` reads a habit
    /// occurrence's own live `status` directly instead of going through
    /// `isEffectivelyCompleted` at all, since it's never staged — kept
    /// here only so this `switch` stays exhaustive, returning the same
    /// thing the live value already would.
    private func effectiveCompleted(for item: ReviewItem) -> Bool {
        switch item {
        case .block(let block):
            return stagedTodayToggleIDs.contains(item.id) ? !block.isCompleted : block.isCompleted
        case .habit(let occurrence):
            return occurrence.isCompleted
        case .recurringTask(let occurrence):
            return occurrence.status == .complete
        case .completedTask:
            return true
        case .meal(let selection, _):
            return stagedMealSelectionIDs.contains(selection.id) ? !selection.isCompleted : selection.isCompleted
        }
    }

    /// An AM/Midday/PM habit occurrence (see `HabitOccurrenceTimeMode`)
    /// never gets a `ScheduledBlock` at all, so it'd otherwise be
    /// invisible to `reviewableBlocks` — a Specific-Time occurrence
    /// doesn't need this, it already shows up as a real block.
    ///
    /// Reads from `frozenTodayHabitOccurrences` (which row IDENTITIES are
    /// being reviewed — captured once on entry) rather than calling
    /// `ScheduleReviewViewModel.openHabitOccurrencesForReview` directly on
    /// every render, but each occurrence's `status` is still looked up
    /// fresh, right here, every time this is read — so a row stays put as
    /// you cycle it (the frozen part) while still showing whatever state
    /// it's actually in right now (the live part), rather than the state
    /// it was in at the moment of freezing. `markUnresolvedHabitOccurrencesAsMissed`'s
    /// sweep does **not** go through this — it calls the live, filtered
    /// function directly, which is what actually protects the untimed
    /// path (see the spec's "What actually protects the untimed path");
    /// freezing that call too would remove the filter's protection, not
    /// just its display twitchiness.
    private var openHabitOccurrencesForReview: [HabitReviewOccurrence] {
        ScheduleReviewViewModel.refreshedHabitReviewOccurrences(frozen: frozenTodayHabitOccurrences, context: modelContext)
    }

    /// This view's own display-facing wrapper around
    /// `frozenTodayRecurringTaskOccurrences` — same identity-frozen/
    /// status-live split as `openHabitOccurrencesForReview` above, same
    /// name deliberately (it's this view's wrapper, not the operational
    /// list itself).
    private var openRecurringTaskOccurrencesForReview: [ScheduleReviewViewModel.RecurringTaskReviewOccurrence] {
        ScheduleReviewViewModel.refreshedRecurringTaskReviewOccurrences(frozen: frozenTodayRecurringTaskOccurrences, context: modelContext)
    }

    /// Routes through the exact same four-state cycle
    /// (`none -> complete -> missed -> excused -> none`) the Habits tab
    /// and the day calendar already use — one behavior everywhere, not a
    /// third variant. Writes immediately rather than staging: a 4-state
    /// cycle has no sensible "pending flip" to represent the way a plain
    /// boolean toggle did, since the caller needs to know *which* state a
    /// row is currently showing in order to decide what the next tap
    /// produces — that's the row's own live `status`, not anything staged
    /// here. Scoped to the occurrence's own day (`occurrence.targetTime`,
    /// backlog or not) rather than always `reviewDate`, same as before.
    private func cycleHabitReviewOccurrence(_ occurrence: HabitReviewOccurrence) {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: occurrence.targetTime)
        occurrence.habit.cycleOccurrence(occurrence.index, on: day, context: modelContext, calendar: calendar)
        HabitStatsRefreshCoordinator.shared.habitLogsChanged()
    }

    /// Finds (or creates) the `HabitLog` for `habit` on `day` — shared by
    /// `toggleHabitReviewOccurrence` and `markUnresolvedHabitOccurrencesAsMissed`.
    private func habitLog(for habit: Habit, on day: Date) -> HabitLog {
        habit.logOrCreate(on: day, context: modelContext, calendar: Calendar.current)
    }

    /// The recurring-task counterpart to `cycleHabitReviewOccurrence`, for
    /// an AM/Midday/PM occurrence — routes through `TaskItem
    /// .cycleRecurringOccurrence`, same "write immediately, no staged
    /// pending-flip" reasoning.
    private func cycleRecurringTaskReviewOccurrence(_ occurrence: ScheduleReviewViewModel.RecurringTaskReviewOccurrence) {
        let day = Calendar.current.startOfDay(for: occurrence.targetTime)
        pushIfMissed(task: occurrence.task, day: day)
    }

    /// The Specific-Time counterpart — same cycle, same immediate-push
    /// behavior, different day source (`block.date`, not a stand-in
    /// `targetTime`, since a real block already has one).
    private func cycleRecurringTaskReviewOccurrence(block: ScheduledBlock) {
        guard let task = block.task else { return }
        pushIfMissed(task: task, day: block.date)
    }

    /// Cycles `task`'s occurrence on `day` and, per the "marking missed
    /// pushes immediately" decision, creates the real
    /// `PushedRecurringOccurrence` right here the moment the cycle lands
    /// on `.missed` — not deferred to `advance()`'s commit-time sweep.
    /// Shares `pushRecurringOccurrenceIfNeeded` with that sweep (see its
    /// own doc comment) so the two can never both push the same task.
    ///
    /// Tracks the created record's id in `immediatelyPushedRecurringOccurrenceIDs`
    /// so `advance()`'s own one-hop-forward step (which otherwise only
    /// sees records *it* just created via the batch sweep) also catches
    /// this one — without that, a push created here would sit at today's
    /// date, un-hopped, until the next app launch, silently undoing
    /// "pushes immediately." Does **not** delete the record if the task
    /// later gets cycled back past `.missed` to `.none` within the same
    /// session — see `advance()`'s own comment on why that's handled
    /// there instead, via the already-existing `isAlreadyResolved` check,
    /// rather than reversed eagerly here.
    private func pushIfMissed(task: TaskItem, day: Date) {
        let calendar = Calendar.current
        let next = task.cycleRecurringOccurrence(on: day, context: modelContext, calendar: calendar)
        guard next == .missed else { return }
        if let occurrence = ScheduleReviewViewModel.pushRecurringOccurrenceIfNeeded(task: task, missedDay: day, context: modelContext) {
            immediatelyPushedRecurringOccurrenceIDs.insert(occurrence.id)
        }
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
        // — those are scoped to `reviewDisplayCutoff` (what the step
        // *shows*) rather than `reviewCutoff` (what this sweep *acts* on).
        // The two are computed identically now (see `reviewCutoff`'s own
        // doc comment for why the old `.now`-clamped version got removed —
        // a habit due later tonight is now correctly swept, not protected
        // from it), but this stays reading `reviewCutoff` specifically
        // rather than switching to `reviewDisplayCutoff` directly: they
        // answer different questions that only happen to agree today, and
        // a future divergence between them should change this sweep's
        // behavior by way of `reviewCutoff` actually changing, not
        // silently by way of which property happened to get read here.
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
        // right after. See `AttributeReviewSession.queueCandidates` for
        // the full predicate.
        let queue = AttributeReviewSession.queueCandidates(from: allTasks)
        guard !queue.isEmpty else { return }
        // `inboxEngagementTimer` is the same instance every time this
        // runs — an empty inbox never even reaches this line (the guard
        // above returns first), so a step that auto-skips because there's
        // nothing to review never starts, or is charged against, the
        // engagement floor at all.
        attributeReviewSession = AttributeReviewSession(queue: queue, engagementTimer: inboxEngagementTimer)
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
                    Text("Knock these out right now and check them off. Anything still unchecked goes to the very top of \(planRelativeDayLabel.lowercased())'s schedule — ahead of everything else, habits included.")
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
                    Text("Ranked by fewest missing ingredients, same as the Kitchen's own Meals tab. Placed on \(planRelativeDayLabel.lowercased())'s calendar at 5pm, locked.")
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
            tomorrowViewModel?.deregisterBlock(block)
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
        tomorrowViewModel?.registerInsertedBlock(block)
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
                    materializedRows: ScheduleReviewViewModel.timelineRows(blocks: tomorrowViewModel.blocks, calendarEvents: tomorrowViewModel.calendarEvents),
                    eligibleHoursWindows: eligibleHoursWindows,
                    targetDate: tomorrowViewModel.targetDate,
                    lockedStore: lockedStore,
                    viewModel: tomorrowViewModel,
                    isToday: Calendar.current.isDateInToday(tomorrowViewModel.targetDate),
                    allTasks: allTasks,
                    allPushedRecurringOccurrences: allPushedRecurringOccurrences,
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
    /// section to ask beyond the interval/time-mode/end-date questions
    /// below. No *user-picked* time-of-day question for Specific Time —
    /// that occurrence still lands at a fixed time on the calendar (see
    /// `TaskItem.recurringOccurrenceTime`), taken from Start Date rather
    /// than asked separately here; see `combiningDate(_:withTimeFrom:)`.
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

                // Same AM/Midday/PM/Specific Time choice
                // `HabitEditView`'s own "Times" section offers, reusing
                // the identical `HabitOccurrenceTimeMode` enum — Specific
                // Time is what keeps today's exact behavior (placed on the
                // calendar at Start Date's own time); AM/Midday/PM instead
                // shows this as a plain check-off item alongside habits in
                // that part of the day (see `DayTimelineGridView`,
                // `RecurringTaskLog`), with no calendar block at all.
                HStack {
                    Text("Time")
                    Spacer()
                    Picker("Time", selection: Binding(
                        get: { task.recurrenceTimeMode },
                        set: { task.recurrenceTimeMode = $0 }
                    )) {
                        ForEach(HabitOccurrenceTimeMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
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
