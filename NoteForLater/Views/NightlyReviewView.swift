import SwiftUI
import SwiftData
import Combine

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
    /// Which habit occurrences the Today step is reviewing, frozen the
    /// moment the step is entered (`runEntryEffects(for: .today)`) rather
    /// than re-derived on every render. Sourced from `ScheduleReviewViewModel
    /// .allHabitOccurrencesForReview` — the **display** list, every status,
    /// not `.openHabitOccurrencesForReview` (the **operational** list,
    /// `.none` only, what the sweep acts on) — so a habit already resolved
    /// before the step ever opened is part of the frozen set too, not just
    /// the ones still open. Habit rows cycle through the full four-state
    /// sequence via `Habit.cycleOccurrence` (see `cycleHabitReviewOccurrence`),
    /// writing immediately — every row on this step does now (see
    /// `cycleBlockCompletion`/`mealCircleTapped` for the block/meal
    /// counterparts) — the moment a row advances past `.none`, the operational list's
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
    /// Prior start dates for 2-minute tasks pushed this session — see
    /// `TwoMinutePushState`. Session-scoped: a push is committed the moment
    /// it happens, and this only exists so changing your mind restores what
    /// was there before rather than clearing to nil.
    @State private var twoMinutePushState = TwoMinutePushState()
    /// One budget per review session — see `TwoMinuteEngagementTimer`.
    /// Held here, not in the step, so leaving and returning resumes.
    @State private var twoMinuteEngagementTimer = TwoMinuteEngagementTimer()
    @State private var acknowledgedAtRiskTaskIDs: Set<UUID> = []
    @State private var atRiskTaskCardTarget: TaskItem?
    /// Drives the "X is empty — skipped" auto-skip toast (see
    /// `advance()`/`presentSkipToast`) — a separate pair from
    /// `TaskReviewCard`'s own `toastMessage`/`toastVisible` further down
    /// this file; that's a different view struct entirely.
    @State private var skipToastMessage: String?
    @State private var skipToastVisible = false
    /// **Forces a body pass after a write this view's `@Query`s cannot see.**
    ///
    /// `TaskItem.cycleRecurringOccurrence` writes `RecurringTaskLog` and
    /// `TaskCompletionRecord`, and this view queries neither. It also mirrors
    /// onto the occurrence's `ScheduledBlock` — and that mirror, incidentally,
    /// was the only thing that ever invalidated this view, because
    /// `@Query allBlocks` observes it. Stage 4 removed the last recurring-task
    /// block, so the mirror stopped firing and a tap stopped redrawing its own
    /// row: measured at **zero body passes across four consecutive taps**, the
    /// row only catching up 5+ seconds later when something unrelated
    /// invalidated the view.
    ///
    /// Same mechanism `DayTimelineGridView.habitOccurrenceRefreshTick` already
    /// uses for the identical problem on that screen, named the same way on
    /// purpose. A deliberate invalidation rather than a re-added block mirror:
    /// relying on a side effect of a data write is exactly what broke here,
    /// and a future deletion could take it away again just as silently.
    @State private var recurringOccurrenceRefreshTick = 0

    private let calendarService: CalendarServiceProtocol = GoogleCalendarService()
    private let schedulingService: AISchedulingServiceProtocol = MockAISchedulingService()

    /// Internal, not `private` — `autoSkipEligible` needs to be directly
    /// testable (`NightlyReviewViewStepAutoSkipTests`) without constructing
    /// a live `NightlyReviewView`, which its `@Query` properties make
    /// impractical from a unit test. Still only ever referenced as
    /// `NightlyReviewView.Step` from outside this file — nothing about it
    /// is meant for use elsewhere.
    enum Step: Int, CaseIterable, Hashable {
        // `.habits` sits right after `.chooseDay` deliberately — the habit
        // list it shows depends on `reviewDate`, which Choose Day sets, so
        // it can't be literally first, but nothing else in this list
        // depends on anything `.habits` itself produces, so there's no
        // reason to place it any later. This is an `Int`-rawValue enum
        // with no explicit values — inserting a case here renumbers every
        // case declared after it automatically; `advance()`/`back()` do
        // `rawValue +/- 1` arithmetic off whatever the current declaration
        // order is, never a hardcoded number, so that's the only edit this
        // insertion needs. Confirmed nothing persists a raw `Step` value
        // across launches: `step` is a plain `@State`, always starting at
        // `.chooseDay` (see its declaration above), never seeded from
        // `UserDefaults`/SwiftData/anywhere else — grepped the whole app
        // for `Step.rawValue`/`step.rawValue` to confirm the only two
        // reads are `advance()`/`back()`'s own arithmetic, both of which
        // re-derive fresh off the enum's current order every time, never a
        // stored number from a previous run.
        // Order is the declaration order — `advance()`/`back()` do
        // `rawValue ±1` off whatever this says, never a hardcoded number,
        // and nothing persists a raw value across launches (`step` is plain
        // `@State`, always starting at `.chooseDay`). So reordering is this
        // line plus nothing else.
        //
        // Inbox now precedes the 2-Minute step and both precede Review
        // Schedule, so shelf changes made while sorting the Inbox are
        // already in place by the time anything schedules against them.
        // That also separated "arriving at Inbox" from "leaving Review
        // Schedule", which used to be the same edge — see `runExitEffects`.
        case chooseDay, habits, inbox, twoMinuteTasks, today, atRisk, meals, tomorrow

        /// `planDate` is only meaningful for `.meals`/`.tomorrow` — the day
        /// right after whichever day was picked in Choose Day, not
        /// calendar-tomorrow-from-right-now — so its title can name that
        /// day explicitly instead of just saying "Tomorrow".
        func title(planDate: Date) -> String {
            switch self {
            case .chooseDay: return "Which Day?"
            case .habits: return "Habits"
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
            case .habits: return "Habits"
            case .twoMinuteTasks: return "2-Minute Tasks"
            case .today: return "Review Schedule"
            case .inbox: return "Inbox"
            case .atRisk: return "At Risk"
            case .meals: return "Meals"
            case .tomorrow: return "Plan Tomorrow"
            }
        }

        /// What leaving this step commits, if anything.
        ///
        /// Exists so the *anchor* is assertable from a test rather than
        /// only readable in `runExitEffects`. The commit used to hang off
        /// arriving at `.inbox`; it belongs to leaving `.today`, and those
        /// stopped being the same edge when Inbox moved ahead of Review
        /// Schedule.
        enum ExitEffect: Equatable { case commitReviewSchedule }

        var exitEffect: ExitEffect? {
            switch self {
            case .today: return .commitReviewSchedule
            default: return nil
            }
        }

        /// `back()` deliberately runs no exit effects — reversing out of
        /// Review Schedule must not re-commit. Pinned as a constant so the
        /// intent is assertable; `back()` itself passes `onEnter: { _ in }`
        /// and never calls `runExitEffects`.
        static let exitEffectsRunOnAdvanceOnly = true

        /// Steps `advance()`/`back()` are allowed to walk straight past
        /// when they turn out empty — deliberately excludes `.chooseDay`
        /// (never reached as a "next" candidate anyway), `.today` (where
        /// nothing missed gets confirmed — always shown even if sparse),
        /// and `.tomorrow` (the final approval screen — same reasoning).
        /// `.habits` IS eligible, unlike `.today` — with no applicable
        /// habits there's nothing to gate on and no reason to show an
        /// empty screen, unlike `.today`'s "nothing missed gets confirmed"
        /// reasoning which doesn't apply here. See `isStepCurrentlyEmpty`
        /// for what "empty" means for `.habits` specifically, and
        /// `unresolvedHabitOccurrencesForGate` for the separate,
        /// narrower "unresolved" check the Next button actually gates on
        /// — the two are deliberately different conditions: a day where
        /// every habit is already resolved is non-empty (still shown,
        /// mirroring HabitsView) but not gate-blocked.
        static let autoSkipEligible: Set<Step> = [.habits, .twoMinuteTasks, .inbox, .atRisk, .meals]
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
                case .habits: habitsStep
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
            // own comment for exactly what `.today`'s gate counts and why,
            // and `unresolvedHabitOccurrencesForGate`'s for `.habits`' own,
            // separate gate).
            if step == .today, !unresolvedGateReviewItems.isEmpty {
                Button(action: jumpToFirstUnresolvedGateItem) {
                    Label(todayUnresolvedGateMessage, systemImage: "arrow.down.circle")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }
            if step == .habits, !unresolvedHabitOccurrencesForGate.isEmpty {
                Label(habitsUnresolvedGateMessage, systemImage: "arrow.down.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
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
                        .disabled(
                            (step == .today && !unresolvedGateReviewItems.isEmpty)
                            || (step == .habits && !unresolvedHabitOccurrencesForGate.isEmpty)
                            || (step == .twoMinuteTasks && !twoMinuteCanProceed)
                        )
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// **The Today-step Next gate — every task block, meal, and recurring
    /// task occurrence.** Habits used to gate this same step alongside
    /// recurring tasks; they now gate their own, earlier `.habits` step
    /// instead (see `unresolvedHabitOccurrencesForGate`), so this is
    /// scoped to non-habit rows only. Built by filtering `reviewItems` itself (the
    /// same merged, sorted list the step renders — `reviewItems` no longer
    /// contains any `.habit` case at all, so the `.habit` branch below is
    /// unreachable in practice; kept only because `ReviewItem`'s switch
    /// must stay exhaustive, since the enum itself is still used by
    /// `.habit`-producing callers elsewhere), so a row's gate status and
    /// its rendered position always agree, and "jump to first" below lands
    /// on whichever blocking row actually appears first on screen — not a
    /// second, independently-ordered notion of "first."
    ///
    /// **REVERSAL:** non-recurring blocks and meals used to be excluded
    /// here on purpose — the old reasoning (kept below, struck through in
    /// spirit rather than deleted, since the "why not" is worth keeping
    /// as history) was that both only ever exposed a single `isCompleted`
    /// boolean with no "explicitly decided not done" state distinct from
    /// "haven't looked at it yet," so gating on them would trap the
    /// review on any ordinary night with leftover work. That's no longer
    /// true: `ScheduledBlock`/`MealSelection` now carry the same
    /// three-state `status` a recurring task's occurrence does, and
    /// `.missed` is exactly the "explicitly decided not done, resolved"
    /// state that used to be missing — leaving something at `.none`
    /// (never looked at) is the only thing this gate ever blocks on, the
    /// same as it always has for recurring tasks. Cycling to `.missed`
    /// (not just `.complete`) fully satisfies the gate; nothing forces a
    /// false "complete."
    ///
    /// A recurring task cycles through a bounded set of genuine terminal
    /// states (`TaskItem.cycleRecurringOccurrence`'s three) in a bounded
    /// number of taps, and `.none` is the one state that design treats as
    /// "not actually looked at yet," never as an accepted final state —
    /// see the missed sweep this gate makes largely redundant but does not
    /// replace, `pushMissedRecurringOccurrences`/`resolveMissedPastBlocks`.
    /// The same is now true for an ordinary block or meal: `.none` is the
    /// only unresolved state, `.missed` is a real terminal answer, and
    /// `resolveMissedPastBlocks` is the redundant safety net for it, not
    /// this gate's reason to exclude it.
    private var unresolvedGateReviewItems: [ReviewItem] {
        reviewItems.filter { $0.blocksGate(context: modelContext) }
    }

    private var todayUnresolvedGateMessage: String {
        ScheduleReviewViewModel.unresolvedGateMessage(unresolvedHabitCount: 0, unresolvedRecurringTaskCount: unresolvedGateReviewItems.count)
    }

    /// **The Habits-step Next gate.** The counterpart split off from what
    /// used to be `.today`'s combined habits-and-tasks gate — see
    /// `unresolvedGateReviewItems`'s own doc comment for the split.
    /// Filters `openHabitOccurrencesForReview` (this view's frozen-
    /// identity/live-status wrapper — see `frozenTodayHabitOccurrences`'s
    /// doc comment) through `ScheduleReviewViewModel
    /// .unresolvedHabitOccurrences`, the exact same `.none`-only predicate
    /// the old combined gate used for its own habit half, just no longer
    /// mixed in with recurring tasks.
    /// **Backlog only — the review day's own habits don't block Next.**
    ///
    /// A habit due this evening may still legitimately happen; being made
    /// to declare it done or missed at 9pm while planning tomorrow is a
    /// false choice. Earlier days are over, so anything still unresolved
    /// there is genuinely unaddressed.
    ///
    /// Visibility is unchanged: today's occurrences still render on the step
    /// and are still markable. This is a gating change only.
    private var unresolvedHabitOccurrencesForGate: [HabitReviewOccurrence] {
        ScheduleReviewViewModel.backlogHabitOccurrences(openHabitOccurrencesForReview, before: reviewDate)
    }

    private var habitsUnresolvedGateMessage: String {
        ScheduleReviewViewModel.unresolvedGateMessage(unresolvedHabitCount: unresolvedHabitOccurrencesForGate.count, unresolvedRecurringTaskCount: 0)
    }

    /// Scrolls the first blocking row (in the same order the list itself
    /// renders — see `unresolvedGateReviewItems`) into view. Jumps to the
    /// first only; tapping again after resolving it lands on whichever is
    /// first next, which in practice walks the whole blocking set one tap
    /// at a time. `.today`-only — the `.habits` step's own gate message has
    /// no equivalent jump-to-scroll wired up (see `habitsStep`'s own doc
    /// comment for why that's an accepted gap, not an oversight).
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
        // Deliberately the FULL frozen set (every status), not the
        // unresolved subset `unresolvedHabitOccurrencesForGate` gates
        // Next on — matches what `habitsStep` itself renders (see
        // `openHabitOccurrencesForReview`), same "empty means literally
        // nothing to show" contract this whole function documents. This
        // and the gate are answering two different questions that happen
        // to both be about habits: "is there anything to show at all"
        // (this one — no applicable habits means skip the step, there's
        // nothing to render) vs. "is there anything still unresolved"
        // (the gate — a day where every habit is already resolved has
        // real content to display, mirroring HabitsView, so it's not
        // empty here, but it's also not gate-blocked, since nothing's
        // left to mark). Consolidating these onto one list would silently
        // break one of the two cases with no obvious symptom: reading the
        // unresolved-only list here would auto-skip a day whose habits
        // are all already resolved instead of showing them, and reading
        // the full list in the gate would block Next forever on a day
        // with habits, since resolved ones would count as "present" but
        // never "clear."
        case .habits: return openHabitOccurrencesForReview.isEmpty
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
    /// Effects that belong to *leaving* a step, not entering one.
    ///
    /// The Review Schedule commit lives here. It used to hang off
    /// `runEntryEffects(for: .inbox)` — but its own comment always said
    /// what it meant: *"this whole batch runs 'on Next from the Today
    /// step'"*. Arriving at Inbox and leaving Review Schedule were the same
    /// edge only because those steps were adjacent. Reordering separated
    /// them, so the anchor moved to the thing it was always about.
    ///
    /// Keyed to departure rather than arrival deliberately: it now survives
    /// any future reordering, because nothing about it depends on which
    /// step comes next.
    ///
    /// Only `advance()` calls this. `back()` does not — reversing out of
    /// Review Schedule must not re-commit — which is the same reason
    /// `back()` passes `onEnter: { _ in }`. The batch is independently safe
    /// against re-entry either way (see
    /// `NightlyReviewCommitTests.test_runningTwice_doesNotDoublePush`), but
    /// that is a backstop, not the mechanism.
    private func runExitEffects(for current: Step) {
        if current.exitEffect == .commitReviewSchedule, todayViewModel != nil, let tomorrowViewModel {
            // Body lifted verbatim into `ScheduleReviewViewModel
            // .commitTodayStep` / `.finishTodayStepCommit` — see those for
            // what it does and why it had to move (it was unreachable from
            // any test in here, and sabotaging the whole batch failed
            // nothing).
            //
            // The `Task {}` stays unstructured here, exactly as before.
            // That is a latent risk rather than a new one: nothing awaits
            // it, so dismissing the review cannot know it finished. On the
            // open list rather than changed under cover of a move.
            let handoff = ScheduleReviewViewModel.commitTodayStep(
                reviewableBlocks: reviewableBlocks,
                reviewCutoff: reviewCutoff,
                allBlocks: allBlocks,
                allTasks: allTasks,
                reviewDate: reviewDate,
                immediatelyPushedRecurringOccurrenceIDs: &immediatelyPushedRecurringOccurrenceIDs,
                modelContext: modelContext,
                markUnresolvedHabitOccurrencesAsMissed: markUnresolvedHabitOccurrencesAsMissed
            )
            Task {
                await ScheduleReviewViewModel.finishTodayStepCommit(
                    handoff,
                    tomorrowViewModel: tomorrowViewModel,
                    allShelves: allShelves,
                    allHabits: allHabits,
                    eligibleHoursWindows: eligibleHoursWindows,
                    modelContext: modelContext
                )
            }
        }
    }

    private func runEntryEffects(for next: Step) {
        if next == .habits {
            // Frozen exactly once, on entry — see `frozenTodayHabitOccurrences`'s
            // own doc comment for why this can't just be re-derived live on
            // every render the way it used to be. Deliberately
            // `allHabitOccurrencesForReview` (every status), not
            // `openHabitOccurrencesForReview` (`.none` only, what the sweep
            // acts on) — freezing the *filtered* call's result would mean
            // a habit already resolved before the step opened never
            // entered the frozen set in the first place, the exact gap
            // this exists to close. See both functions' own doc comments
            // for the display/operational split. Moved here (from
            // `.today`'s own entry effects) now that habits get their own,
            // earlier step — `reviewDisplayCutoff` only depends on
            // `reviewDate`, already set by Choose Day one step back, so
            // there's no ordering hazard in freezing this before
            // `.twoMinuteTasks`/`.today` run.
            frozenTodayHabitOccurrences = ScheduleReviewViewModel.allHabitOccurrencesForReview(
                habits: allHabits,
                context: modelContext,
                upTo: reviewDisplayCutoff,
                completedSince: NightlyReviewCompletionState.shared.lastClosedReviewDay
            )
        }
        if next == .today {
            // Same freeze, same reasoning, for AM/Midday/PM recurring
            // tasks — see `frozenTodayRecurringTaskOccurrences`'s own doc
            // comment. Recurring tasks still gate/display in `.today`
            // itself, so this stays here (unlike the habit freeze above,
            // which moved to `.habits`).
            frozenTodayRecurringTaskOccurrences = ScheduleReviewViewModel.allRecurringTaskOccurrencesForReview(
                tasks: allTasks,
                context: modelContext,
                upTo: reviewDisplayCutoff,
                completedSince: NightlyReviewCompletionState.shared.lastClosedReviewDay
            )
        }
        if next == .twoMinuteTasks {
            // A push from an earlier night whose day has arrived — clear it
            // before the list is built, so the card stops showing a start
            // date that has already come and gone.
            TwoMinutePushState.clearExpiredPushes(on: twoMinuteShelf?.tasks ?? [], asOf: reviewDate)
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
        }
        if next == .inbox {
            startAttributeReviewSession()
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
        // `StepAutoSkip.advance`, not `walkForward` — it runs the
        // departing step's exit effects first, so the commit batch still
        // sees the step it belongs to before anything moves. That ordering
        // used to live here as a bare line above the walk, where no test
        // could see whether it happened at all.
        let result = StepAutoSkip.advance(
            from: step,
            next: { Step(rawValue: $0.rawValue + 1) ?? .tomorrow },
            isEligible: { Step.autoSkipEligible.contains($0) },
            isEmpty: isStepCurrentlyEmpty,
            onExit: runExitEffects,
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
                        Text(ChooseDayPlanning.planDayButtonLabel(
                            planDate: ChooseDayPlanning.planDate(forPlanning: .today, now: .now, calendar: Calendar.current),
                            now: .now,
                            calendar: Calendar.current
                        ))
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
                        Text(ChooseDayPlanning.planDayButtonLabel(
                            planDate: ChooseDayPlanning.planDate(forPlanning: .tomorrow, now: .now, calendar: Calendar.current),
                            now: .now,
                            calendar: Calendar.current
                        ))
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

    // MARK: - Step 1: Habits (mirrors HabitsView's Today page)

    /// One row `habitsStep` renders — a single habit, grouped with every
    /// other occurrence of it landing on the same `day`, so a habit with
    /// `timesPerDay > 1` still shows as one row with N circles (mirroring
    /// `HabitsTodayDayList`'s own per-habit row shape) rather than one row
    /// per occurrence the way `OverdueBlocksReviewList`'s flattened list
    /// does.
    private struct HabitsStepRow: Identifiable {
        let habit: Habit
        var id: UUID { habit.id }
        let occurrences: [HabitReviewOccurrence]
    }

    /// One day section `habitsStep` renders — plural because backlog
    /// (an occurrence from a day before `reviewDate` still open) can put
    /// more than one day on screen at once, same as `OverdueBlocksReviewList
    /// .groupedByDay` already does for the merged Today list.
    private struct HabitsStepDayGroup: Identifiable {
        let day: Date
        var id: Date { day }
        let rows: [HabitsStepRow]
    }

    /// Groups `openHabitOccurrencesForReview` (this view's frozen-identity/
    /// live-status wrapper — unchanged by this step's move, see
    /// `frozenTodayHabitOccurrences`'s own doc comment) first by day, then
    /// by habit within each day, sorting habit rows by `Habit.todayOrderKey`
    /// — the same fixed ordering (frequency, then occurrence-0 time of
    /// day, then a stable tiebreak) `HabitsTodayDayList.sortedHabits`
    /// already uses, so a habit's position here matches where it'd sit on
    /// the Habits tab for the same day.
    private var groupedHabitOccurrencesForReview: [HabitsStepDayGroup] {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: openHabitOccurrencesForReview) { calendar.startOfDay(for: $0.targetTime) }
        return byDay.map { day, occurrences in
            let byHabit = Dictionary(grouping: occurrences) { $0.habit.id }
            let rows = byHabit.values
                .map { occs in HabitsStepRow(habit: occs[0].habit, occurrences: occs.sorted { $0.index < $1.index }) }
                .sorted { $0.habit.todayOrderKey < $1.habit.todayOrderKey }
            return HabitsStepDayGroup(day: day, rows: rows)
        }.sorted { $0.day < $1.day }
    }

    /// "Sunday, September 13, 2026 (Today)" — see `ChooseDayPlanning
    /// .habitsStepDayLabel`'s own doc comment for the full reasoning
    /// (always relative to real `.now`, never `reviewDate`; why this
    /// isn't a shared formatter with `ShelfListView.relativeDayLabel`;
    /// why a future `day` can't actually reach here). Thin wrapper so the
    /// actual logic is a pure, directly testable function rather than
    /// living only in this `@Query`-bearing view.
    private func habitsStepDayLabel(_ day: Date) -> String {
        ChooseDayPlanning.habitsStepDayLabel(day: day, now: .now, calendar: Calendar.current)
    }

    /// The dedicated Nightly Review step for habits — split out of the old
    /// combined "Review Schedule" (`.today`) step so habits get their own
    /// screen, placed right after Choose Day (see `Step`'s own doc comment
    /// for why there and not literally first). Mirrors `HabitsTodayDayList`'s
    /// presentation (habit name + one circle per occurrence, grouped by
    /// habit, sorted by `todayOrderKey`) rather than reusing
    /// `OverdueBlocksReviewList`'s flattened per-occurrence rows — that
    /// list's whole shape (one row per occurrence, sorted by `sortTime`)
    /// exists to interleave habits among calendar blocks/tasks/meals by
    /// time, which doesn't apply here now that habits stand alone.
    ///
    /// No jump-to-first-unresolved affordance here, unlike `.today`'s
    /// `jumpToFirstUnresolvedGateItem` — this list is grouped by day and
    /// typically short (a handful of habits at most), so scrolling a
    /// specific blocking row into view doesn't carry its weight the way it
    /// does for `.today`'s much longer merged list. The "N habits still
    /// unmarked" message alone (see `navBar`) is enough to say what's
    /// blocking Next.
    private var habitsStep: some View {
        List {
            if groupedHabitOccurrencesForReview.isEmpty {
                Text("No habits to review.")
                    .foregroundStyle(.secondary)
            }
            ForEach(groupedHabitOccurrencesForReview) { group in
                Section {
                    ForEach(group.rows) { row in
                        HStack {
                            Text(row.habit.name)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            HStack(spacing: 6) {
                                ForEach(row.occurrences) { occurrence in
                                    HabitOccurrenceCircleView(status: occurrence.status) {
                                        cycleHabitReviewOccurrence(occurrence)
                                    }
                                }
                            }
                        }
                        // Tighter vertical rhythm than the system default
                        // row — the circle itself (36pt, `HabitOccurrenceCircleView`)
                        // is untouched, still a comfortable tap target;
                        // this only trims the padding *around* it. 4pt
                        // top/bottom keeps the row height at 36 + 4 + 4 =
                        // 44pt, right at Apple's own minimum tap-target
                        // guidance, not below it.
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }
                } header: {
                    // Bigger and visually distinct from the rows beneath
                    // it — `Section(String)`'s own default header style
                    // (small, uppercased, secondary-colored) reads as just
                    // another row at a glance; this is a real heading.
                    // `.textCase(nil)` overrides the system's automatic
                    // uppercasing of Section headers, which would
                    // otherwise mangle the day-of-week/month names.
                    Text(habitsStepDayLabel(group.day))
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                        .textCase(nil)
                        .padding(.vertical, 4)
                }
            }
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
    /// `resolveMissedPastBlocks` and `pushMissedRecurringOccurrences` —
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

    /// Blocks, recurring-task occurrences, completed-with-no-block tasks,
    /// and tonight's meal(s) mixed into one list, organized by time within
    /// each day — see `ReviewItem`/`OverdueBlocksReviewList`. This is what
    /// makes tasks and dinner land in the same order they actually sit on
    /// the calendar, instead of dinner being hardcoded to the top
    /// regardless of its own scheduled time — and, separately, what pins a
    /// 2-Minute Task completion to the very front of its day regardless of
    /// either: `isTwoMinuteTask` is checked against `twoMinuteReviewTaskIDs`
    /// (this session's own snapshot from the step just before this one)
    /// rather than the record's live task, since nothing guarantees that
    /// task is still around by the time this reads it.
    ///
    /// No longer includes habit occurrences — those moved to their own,
    /// earlier `.habits` step (see `habitsStep`). `ReviewItem.habit` still
    /// exists as an enum case and `OverdueBlocksReviewList` still renders
    /// it (both are general-purpose, not owned outright by this step), it
    /// just never gets produced from here anymore.
    private var reviewItems: [ReviewItem] {
        reviewableBlocks.map { .block($0) }
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

    /// Every row on this step writes immediately now — `.block`/`.meal`
    /// included, same as `.habit`/`.recurringTask` already did. A
    /// three-state cycle needs to know which of the three states a row
    /// is *actually* in right now to decide what the next tap produces,
    /// which a staged "pending flip" can never represent for more than
    /// two — the reversibility a staged commit used to give Today-step
    /// taps doesn't apply to a cycle at all: tapping again already *is*
    /// how you reverse it, same as `.habit`/`.recurringTask` always
    /// worked. No `isEffectivelyCompleted` override needed anymore either
    /// — every row now reads its own live status directly (`OverdueBlocksReviewList`'s
    /// default when that closure is omitted).
    @ViewBuilder
    private var todayStep: some View {
        if let todayViewModel {
            OverdueBlocksReviewList(items: reviewItems, onToggle: { item in
                switch item {
                case .habit(let occurrence):
                    // Never actually reached — `reviewItems` no longer
                    // produces `.habit` (habits moved to their own
                    // `.habits` step, see `habitsStep`). Kept only so this
                    // switch stays exhaustive over `ReviewItem`.
                    cycleHabitReviewOccurrence(occurrence)
                case .recurringTask(let occurrence):
                    cycleRecurringTaskReviewOccurrence(occurrence)
                case .meal(let selection, _):
                    mealCircleTapped(selection, viewModel: todayViewModel)
                case .block(let block) where block.task?.isRecurring == true:
                    cycleRecurringTaskReviewOccurrence(block: block)
                case .block(let block):
                    todayViewModel.cycleBlockCompletion(block)
                case .completedTask:
                    // Never actually reached — `completedTaskRow` has no
                    // tap gesture at all (no live model to toggle back).
                    break
                }
            }, scrollTarget: $scrollToReviewItemID)
        } else {
            ProgressView()
        }
    }

    /// The meal counterpart to `ScheduleReviewViewModel
    /// .cycleBlockCompletion`, which the tap actually delegates to — that
    /// function operates on a `ScheduledBlock`, mirroring onto whichever
    /// `MealSelection` it's paired with, not the other way around, so a
    /// tap here needs to find that block first. Falls back to cycling
    /// `selection.status` directly (no pantry-deduction/mirror wiring) in
    /// the one case that block's gone missing — shouldn't normally
    /// happen (`MealSelection`'s own doc comment: always created
    /// alongside its block), but a tap that silently did nothing would be
    /// worse than one that at least updates the selection's own status.
    private func mealCircleTapped(_ selection: MealSelection, viewModel: ScheduleReviewViewModel) {
        if let block = allBlocks.first(where: { $0.mealSelection?.id == selection.id }) {
            viewModel.cycleBlockCompletion(block)
        } else {
            selection.status = selection.status.cycledExcludingExcused
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
        // Read so the dependency is explicit rather than resting on "mutating
        // `@State` invalidates the owning view." It does — but this list is
        // the thing whose freshness the tick exists to guarantee, and an
        // unread tick is one refactor away from looking like dead state.
        _ = recurringOccurrenceRefreshTick
        return ScheduleReviewViewModel.refreshedRecurringTaskReviewOccurrences(frozen: frozenTodayRecurringTaskOccurrences, context: modelContext)
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
        // Nothing this view queries changed — see
        // `recurringOccurrenceRefreshTick`. Both `cycleRecurringTaskReviewOccurrence`
        // overloads funnel through here, so one bump covers both row shapes.
        recurringOccurrenceRefreshTick += 1
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
        ScheduleReviewViewModel.markUnresolvedHabitOccurrencesAsMissed(
            allBlocks: allBlocks,
            allHabits: allHabits,
            reviewCutoff: reviewCutoff,
            reviewDate: reviewDate,
            modelContext: modelContext,
            habitLog: habitLog(for:on:)
        )
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
    /// Unresolved counts over the step's own frozen list — live, so the
    /// timer shortens the moment something is completed.
    private var twoMinuteUnresolvedCounts: (missed: Int, unanswered: Int) {
        let tasks = twoMinuteReviewTasks
        return (tasks.filter { $0.status == .missed }.count,
                tasks.filter { $0.status == .none }.count)
    }

    private var twoMinuteCanProceed: Bool {
        let counts = twoMinuteUnresolvedCounts
        return twoMinuteEngagementTimer.canProceed(missed: counts.missed, unanswered: counts.unanswered)
    }

    /// "1:47", floored at "0:00" — same shape as
    /// `TaskReviewQueueSheet.formattedRemaining`.
    private static func formattedRemaining(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

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
                    Text("Knock these out right now and check them off. Anything still unchecked goes to the very top of \(planRelativeDayLabel.lowercased())'s schedule — ahead of everything else, habits included.")
                }

                if !twoMinuteCanProceed {
                    // Only while there's a wait. Everything complete means
                    // no timer at all, not a timer reading 0:00.
                    Section {
                        let counts = twoMinuteUnresolvedCounts
                        Label(
                            "Wait \(Self.formattedRemaining(twoMinuteEngagementTimer.remaining(missed: counts.missed, unanswered: counts.unanswered))) or finish them",
                            systemImage: "timer"
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            // Ticks only while this step is on screen — the subscription
            // dies with the view, which is what makes leaving and returning
            // resume rather than reset. Same mechanism as the Inbox timer.
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                guard !twoMinuteCanProceed else { return }
                twoMinuteEngagementTimer.tick()
            }
        }
    }

    /// A tap anywhere on the row cycles `task.status` directly and
    /// immediately (`TaskItem.cycleCompletion`) — no staging. Same reason
    /// `.block`/`.meal` rows on the Today step went immediate-write too:
    /// a three-state cycle needs to know which of the three states the
    /// row is *actually* in right now to know what the next tap should
    /// produce, which a staged "pending flip" can't represent for more
    /// than two. `.contentShape(Rectangle())` on the whole `HStack`, not
    /// just the circle, is what makes the title text and the `Spacer()`'s
    /// blank space tappable too.
    private func twoMinuteTaskRow(_ task: TaskItem) -> some View {
        HStack(spacing: 12) {
            twoMinuteSelectionCircle(status: task.status)
            Text(task.title)
                .strikethrough(task.status == .complete)
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Routed through `TwoMinutePushState` so landing on `.missed`
            // pushes the task a day, and leaving `.missed` puts its old
            // start date back.
            twoMinutePushState.cycle(task, reviewDate: reviewDate, context: modelContext)
            ScheduleDirtyState.shared.isDirty = true
        }
        .opacity(task.status == .none ? 1 : 0.5)
    }

    /// Same three-state rendering `OverdueBlocksReviewList
    /// .habitSelectionCircle` uses (green check / red X / empty) — no
    /// `.excused` branch, since `OccurrenceStatus.cycledExcludingExcused`
    /// (what `TaskItem.cycleCompletion` actually cycles through) never
    /// produces it. Kept as its own small copy here rather than exposing
    /// that `private` circle across files for one shared call.
    private func twoMinuteSelectionCircle(status: OccurrenceStatus) -> some View {
        let circleColor: Color = status == .complete ? .green : (status == .missed ? .red.opacity(0.55) : .clear)
        let strokeColor: Color = status == .none ? .secondary.opacity(0.5) : circleColor
        return ZStack {
            Circle()
                .fill(circleColor)
                .overlay(Circle().strokeBorder(strokeColor, lineWidth: 1.5))
            if status == .complete {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
            } else if status == .missed {
                Image(systemName: "xmark")
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
    @State private var shelfPreview: ShelfPreview = .none
    @State private var showingDeleteConfirm = false
    @State private var toastMessage: String?
    /// Drives the flash-then-settle sequence: false is the initial "flash"
    /// instant (bright white scrim, oversized/invisible square), true is
    /// the settled state (scrim gone, square at rest). See `showToast`.
    @State private var toastVisible = false
    @State private var isShowingSnoozeWheel = false
    /// See this type's `init(asOf:)` parameter.
    private let asOf: Date
    @State private var snoozeDays = 1
    /// Which rows are currently expanded — a brand-new, never-saved task
    /// (`isNewlyCreated`) seeds *every* row at once, the card working like
    /// a form you collapse behind you as you go; a reopened, already-saved
    /// task seeds at most one (`initialExpandedRow` — whatever's still
    /// unanswered, `nil`/empty once everything is). See
    /// `initialExpandedRows`. Session-local, never persisted.
    ///
    /// Two different operations touch this set, deliberately kept
    /// distinct: answering a row removes just that row
    /// (`expandedRows.remove(.x)`, at each self-collapse call site below)
    /// — the other still-open rows on a fresh task are untouched, which
    /// is what makes filling one field in collapse only that field.
    /// Explicitly tapping a row's own header to *open* it (the six
    /// `Binding`s just below) instead resets the whole set to that one
    /// row — "opening a row collapses whichever was open before" — so
    /// deliberately jumping ahead still behaves like the single-row
    /// accordion a reopened task already has, even mid-fill-in on a new
    /// one.
    ///
    /// Holds no reference to `task` at all — nothing about expanding,
    /// collapsing, or switching rows can write or clear a model field;
    /// every actual field write happens in the `selectXxx`/`onSelect`
    /// functions that separately, additionally, mutate this.
    @State private var expandedRows: Set<CardRow> = []
    /// Captured once this card's edits settle in after appearing (past any
    /// one-time backfill), so the action button can tell "nothing's been
    /// touched" (Skip) apart from "something's actually been edited" (Save
    /// Changes) — see `hasChanges` and `actionButtonInfo`.
    @State private var originalSnapshot: TaskEditSnapshot?

    /// One `Binding` per row, each a plain view onto `expandedRows` —
    /// `CollapsibleAnswerRow` still takes a `Binding<Bool>`, unchanged.
    /// The `set` here is only ever reached via that row's own header tap
    /// (`CollapsibleAnswerRow`'s `Button` does `isExpanded.toggle()`) —
    /// self-collapse-on-answer bypasses this entirely and edits
    /// `expandedRows` directly, which is what keeps "opening a row
    /// collapses the others" from also firing every time a row answers
    /// itself. Opening (`true`) resets to just this row, matching that
    /// accordion rule; closing (`false`) only ever removes this one row,
    /// same as self-collapse does.
    private func expandedBinding(for row: CardRow) -> Binding<Bool> {
        Binding(
            get: { expandedRows.contains(row) },
            set: { isExpanding in
                if isExpanding {
                    expandedRows = [row]
                } else {
                    expandedRows.remove(row)
                }
            }
        )
    }
    private var isRepeatsExpanded: Binding<Bool> { expandedBinding(for: .repeats) }
    private var isStartsExpanded: Binding<Bool> { expandedBinding(for: .canStartBy) }
    private var isTimeExpanded: Binding<Bool> { expandedBinding(for: .timeMode) }
    private var isEndsExpanded: Binding<Bool> { expandedBinding(for: .ends) }
    /// Set only by tapping **Yes** on Next Step, consumed by the text
    /// field's own `.onAppear`.
    ///
    /// Why a flag rather than setting `focusedField` in the answer's setter:
    /// at that moment the field does not exist yet — it is conditional on
    /// the answer being `true`, so SwiftUI creates it on the *next* render
    /// pass and focus set in the same frame is dropped. Letting the field
    /// claim focus when it appears is the version that sticks, without a
    /// delay to guess at.
    ///
    /// It also gets the *scoping* right, which a `DispatchQueue.main.async`
    /// from the setter would too but an unconditional `.onAppear` would not:
    /// the field also appears when an already-answered row is expanded to
    /// read, and when a new task opens with the row already open. Neither
    /// should grab the keyboard. Only a Yes tap sets this.
    @State private var focusNextStepWhenFieldAppears = false

    private var isNextStepExpanded: Binding<Bool> { expandedBinding(for: .nextStep) }
    private var isDueExpanded: Binding<Bool> { expandedBinding(for: .due) }
    private var isPriorityExpanded: Binding<Bool> { expandedBinding(for: .priority) }
    private var isDurationExpanded: Binding<Bool> { expandedBinding(for: .duration) }
    private var isDivisibleExpanded: Binding<Bool> { expandedBinding(for: .divisible) }

    private enum Field: Hashable {
        case title, nextStep, tag
    }
    /// Only the three text fields ever grab the keyboard — every other
    /// control dismisses it on tap, see each control's action below.
    @FocusState private var focusedField: Field?

    /// The short, curated list — not every 15-minute increment, just the
    /// sizes actually worth picking from directly. See `durationWheelOptions`
    /// below for why this alone isn't always enough.
    static let durationOptions = [2, 15, 30, 45, 60, 90, 120, 240, 480]
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
        // `≤2 min` is back on the list, and is the trigger that moves a
        // task onto the 2-Minute shelf (see `applyDurationDrivenShelf`).
        // It was briefly removed while a separate "2 Minutes or Less?"
        // toggle expressed the same thing; duration is the single trigger
        // again, so the wheel has to be able to say it.
        let options = Self.durationOptions
        guard task.estimatedMinutes > 0, !options.contains(task.estimatedMinutes) else {
            return options
        }
        return (options + [task.estimatedMinutes]).sorted()
    }

    /// Whether "Repeats" (Every + "On the," for a monthly pattern) has
    /// enough answered to show a real summary instead of "Not Selected" —
    /// reads `missingAttributeNames` (the same canonical source
    /// `TaskItem.recurrenceIntervalMissing`/`.relativeRecurrenceMissing`
    /// back) rather than re-deriving the picked-flags by hand, so this
    /// can never drift from what the attribute review actually flags as
    /// missing. `static` (taking `task`/`shelf` explicitly) so `init` can
    /// call it before `self` exists, to seed `isRepeatsExpanded`.
    ///
    /// No longer gates "Pattern" on `task.recurrenceMode == .relativeDate`
    /// — `relativeRecurrenceMissing` itself now gates on `recurrenceUnit
    /// == .months` instead (see that function's own doc comment for why:
    /// the combined "On the" row can resolve to *either* mode, so
    /// `recurrenceMode` alone can no longer distinguish "never touched"
    /// from "deliberately chose Same day"). Checking `missing` directly,
    /// unconditionally, is what stays correct either way.
    ///
    /// `internal`, not `private` — loosened specifically so
    /// `RecurringTaskCardLayoutTests` can exercise the real predicate
    /// directly, same reasoning `NightlyReviewView.Step.autoSkipEligible`
    /// was already loosened for: this view's `@Query` properties make
    /// constructing a live `TaskReviewCard` impractical in a unit test,
    /// but the logic itself takes plain `TaskItem`/`Shelf` values and has
    /// no view state dependency at all.
    static func isRepeatsConfigured(task: TaskItem, shelf: Shelf?) -> Bool {
        let missing = task.missingAttributeNames(consideringShelf: shelf)
        if missing.contains("Every") { return false }
        if missing.contains("Pattern") { return false }
        return true
    }

    static func isStartsConfigured(task: TaskItem, shelf: Shelf?) -> Bool {
        !task.missingAttributeNames(consideringShelf: shelf).contains("Start Date")
    }

    /// Same reasoning as `isRepeatsConfigured`, including why this is
    /// `internal` rather than `private`. For Specific Time, "Time" now
    /// also answers for Duration (and Divisible, when a duration long
    /// enough to split is actually set — same `segmentOptions`/
    /// `TaskItem.validSegmentOptions(for:)` check that decides whether
    /// the Divisible row even appears at all, see `recurringSection`),
    /// since both moved inside this row's expanded content instead of
    /// standing as their own peers.
    /// Mode (and, for Specific Time, the clock) only. Duration and
    /// Divisible used to fold into this row and no longer do — they're
    /// their own top-level rows, each with its own configured-check, so
    /// asking about them here would double-report them.
    static func isTimeConfigured(task: TaskItem, shelf: Shelf?, segmentOptions: [Int]) -> Bool {
        !task.missingAttributeNames(consideringShelf: shelf).contains("Time")
    }

    /// Same reasoning as `isRepeatsConfigured`. `TaskItem.dueDateMissing`
    /// already carries the undecided-vs-decided-as-none distinction this
    /// exists to preserve: undecided (`!dueDateDecided`) or decided-yes-
    /// but-not-yet-picked both count as missing, while decided-as-none
    /// (`dueDateDecided && dueDate == nil`) does not — "None" is a real
    /// answer, not an absence of one. Only ever true for a non-recurring
    /// task (`dueDateMissing` excludes a recurring task outright, which
    /// is asked Start Date instead), but takes no `isRecurring` branch of
    /// its own — there's nothing left to special-case once the canonical
    /// source already does.
    static func isDueConfigured(task: TaskItem, shelf: Shelf?) -> Bool {
        !task.missingAttributeNames(consideringShelf: shelf).contains("Due Date")
    }

    /// The non-recurring "Time" row's own configured-check — Duration
    /// and Divisible only, no recurrence-mode question to fold in (a
    /// non-recurring task has no AM/Midday/PM/Specific concept at all;
    /// the scheduler places it into whatever eligible slot fits, not a
    /// time the task states). Deliberately a separate function from
    /// `isTimeConfigured` rather than a shared one with a branch: that
    /// one's "Time" key and `recurrenceTimeMode` guard are recurring-only
    /// concepts that don't apply here, and reusing it as-is would return
    /// `true` unconditionally (since `missing` never contains "Time" for
    /// a non-recurring task), masking a genuinely unanswered Duration.
    ///
    /// Same `segmentOptions`-gated treatment of "Divisible" as
    /// `isTimeConfigured` — `TaskItem.divisibleMissing` has no guard of
    /// its own for "Duration answered No" (only for an untimed recurring
    /// occurrence), so a task that answered Duration "No" and never
    /// separately touched Divisible would otherwise read as permanently
    /// unconfigured despite Divisible being moot (nothing to split) and
    /// its own control disabled. Ungated when there's a real, splittable
    /// duration — Divisible genuinely needs an answer then, same as the
    /// recurring row.
    /// Delegates to `missingAttributeNames`, same as every other row's
    /// check, so it can't drift from what the badge reports. Note what that
    /// makes true: answering **Yes** and leaving the text empty still counts
    /// as unconfigured — `TaskItem.nextStepMissing` is
    /// `!nextStepDecided || (nextStepAnsweredYes && nextStep.isEmpty)`.
    static func isNextStepConfigured(task: TaskItem, shelf: Shelf?) -> Bool {
        !task.missingAttributeNames(consideringShelf: shelf).contains("Next Step")
    }

    static func isDurationConfigured(task: TaskItem, shelf: Shelf?) -> Bool {
        !task.missingAttributeNames(consideringShelf: shelf).contains("Duration")
    }

    /// Divisible's own configured-check, now that it's a row rather than
    /// part of the Duration/"Time" row. Delegates entirely to
    /// `missingAttributeNames`, which already carries both reasons the
    /// question can be moot — a duration under
    /// `TaskItem.divisibleMinimumDurationMinutes`, and a duration with no
    /// evenly-dividing segment size — so this can't drift from what the
    /// missing badge says.
    static func isDivisibleConfigured(task: TaskItem, shelf: Shelf?) -> Bool {
        !task.missingAttributeNames(consideringShelf: shelf).contains("Divisible")
    }

    /// Whether the Divisible row is shown at all. Hidden below
    /// `TaskItem.divisibleMinimumDurationMinutes` — splitting something
    /// shorter than an hour isn't worth the fragmentation — and hidden
    /// again when nothing evenly divides the duration (70 minutes clears
    /// the hour bar and still has no valid segment size). The same two
    /// conditions `TaskItem.divisibleMissing` short-circuits on, so the
    /// row and the missing badge agree by construction.
    static func showsDivisibleRow(task: TaskItem) -> Bool {
        showsDurationRow(task: task)
            && task.estimatedMinutes >= TaskItem.divisibleMinimumDurationMinutes
            && !TaskItem.validSegmentOptions(for: task.estimatedMinutes).isEmpty
    }

    /// Whether the Duration row is shown at all. Hidden for a recurring
    /// task on AM/Midday/PM — an untimed occurrence never gets a calendar
    /// block, so neither Duration nor Divisible means anything for it.
    /// Reads `TaskItem.recurringAndUntimed`, the same property
    /// `durationMissing`/`divisibleMissing` gate on, so the row and the
    /// missing badge can't disagree.
    ///
    /// This gate used to live implicitly in `timeExpandedContent`'s
    /// `recurrenceTimeMode == .specific` branch, which is where Duration
    /// and Divisible were rendered before they were flattened into their
    /// own rows. Flattening dropped it, and both rows started appearing
    /// for untimed recurring tasks — stated here rather than left to be
    /// rediscovered, since nothing about the row list makes the
    /// dependency obvious.
    static func showsDurationRow(task: TaskItem) -> Bool {
        !task.recurringAndUntimed
    }

    /// Same reasoning as `isRepeatsConfigured`. `TaskItem.priorityMissing`
    /// already excludes a recurring task outright (High Priority isn't
    /// offered to one at all), so this is only ever meaningfully false
    /// for a non-recurring task on a shelf that tracks Priority.
    static func isPriorityConfigured(task: TaskItem, shelf: Shelf?) -> Bool {
        !task.missingAttributeNames(consideringShelf: shelf).contains("Priority")
    }

    /// Which row to seed as the *sole* expanded one for a reopened,
    /// already-saved task — the first unconfigured row, in the same
    /// top-to-bottom order each mode actually renders them, so the row
    /// that opens is always the first thing the eye would hit scrolling
    /// down anyway. `nil` once every row is already configured (the card
    /// opens fully collapsed) — that's not a special case, just what
    /// falling off the end of the list without a match means. Only ever
    /// used for the "existing task" branch of `initialExpandedRows` — a
    /// newly-created task doesn't call this at all, it seeds every row at
    /// once instead.
    ///
    /// `.ends` is deliberately never a candidate here — "Never" is
    /// already a complete answer with nothing to hunt for, so it has no
    /// "unconfigured" state to seed from in the first place. `internal`,
    /// not `private`, for the same direct-testability reasoning as
    /// `isRepeatsConfigured`.
    static func initialExpandedRow(task: TaskItem, shelf: Shelf?, segmentOptions: [Int]) -> CardRow? {
        // Walks the *same* array the card renders from, rather than a
        // parallel hand-written order. "Seeding order matches render
        // order" is therefore not a property that can drift — it's one
        // list read twice. Rows `scrollBodyOrder` already dropped as
        // `.hidden` can't be seeded, which is also what stops an
        // expanded-but-unrenderable row.
        for row in CardRow.scrollBodyOrder(task: task, shelf: shelf) {
            guard row.isExpandable else { continue }
            if !isConfigured(row, task: task, shelf: shelf, segmentOptions: segmentOptions) {
                return row
            }
        }
        return nil
    }

    /// The per-row "has this been answered" check, keyed by row so
    /// `initialExpandedRow` can ask it generically instead of spelling
    /// out a branch per mode.
    static func isConfigured(_ row: CardRow, task: TaskItem, shelf: Shelf?, segmentOptions: [Int]) -> Bool {
        switch row {
        case .nextStep: return isNextStepConfigured(task: task, shelf: shelf)
        case .repeats: return isRepeatsConfigured(task: task, shelf: shelf)
        case .canStartBy: return isStartsConfigured(task: task, shelf: shelf)
        case .timeMode: return isTimeConfigured(task: task, shelf: shelf, segmentOptions: segmentOptions)
        case .duration: return isDurationConfigured(task: task, shelf: shelf)
        case .divisible: return isDivisibleConfigured(task: task, shelf: shelf)
        case .due: return isDueConfigured(task: task, shelf: shelf)
        case .priority: return isPriorityConfigured(task: task, shelf: shelf)
        // "Never" is itself a complete answer, so Ends never seeds open —
        // unchanged from before this walked `scrollBodyOrder`.
        case .ends: return true
        // Non-expandable rows are filtered out before this is reached
        // (`isExpandable`), so nothing here ever seeds them open.
        default: return true
        }
    }

    /// What actually seeds `expandedRows` in `init` — the "never saved
    /// before" split. `isNewlyCreated` is the same flag `TaskCardSheet
    /// .cancel` already uses to decide delete-outright vs. roll-back (see
    /// its own doc comment for why a caller-supplied flag, not a model
    /// field, is the right shape for "never saved" at all) — reused here
    /// rather than inventing a second way to ask the same question.
    ///
    /// A brand-new task seeds *every* row for its mode at once — "the
    /// card is a form to work down," not just whatever happens to be
    /// unanswered — `.ends` included, even though `initialExpandedRow`
    /// never returns it on its own (a fresh task's "Never" default is
    /// still a question worth seeing, not a row to mysteriously
    /// pre-collapse while its three siblings are open). A reopened task
    /// falls back to `initialExpandedRow` unchanged — at most one row,
    /// whatever's still unanswered, matching the behavior that already
    /// shipped before this split existed.
    static func initialExpandedRows(task: TaskItem, shelf: Shelf?, segmentOptions: [Int], isNewlyCreated: Bool) -> Set<CardRow> {
        if isNewlyCreated {
            // Every expandable row the card will actually draw — taken
            // from the render list rather than restated, so a row that
            // can't appear can't be seeded open.
            return Set(CardRow.scrollBodyOrder(task: task, shelf: shelf).filter(\.isExpandable))
        }
        guard let row = initialExpandedRow(task: task, shelf: shelf, segmentOptions: segmentOptions) else { return [] }
        return [row]
    }

    // MARK: - Repeats section: select-and-mark-picked, one function per field

    /// Every one of these pairs with a `PickedMenuPicker` call site in
    /// `repeatsExpandedContent`/`timeExpandedContent` — see that type's
    /// own doc comment for why the pairing exists at all (a `Button`
    /// inside a `Menu` always runs its action, unlike `Picker(selection:)`,
    /// so re-choosing the value already showing still marks it picked).
    /// `internal`, not `private`, for the same direct-testability
    /// reasoning as `isRepeatsConfigured`: each one is called directly by
    /// a test with the option *already equal* to the task's current
    /// value, asserting the "picked" flag flips anyway.
    ///
    /// Relative Date is only ever meaningful monthly (see
    /// `RelativeRecurrenceScope`'s own doc comment) — switching the unit
    /// away from `.months` always forces `recurrenceMode` back to
    /// `.specificDate`, otherwise a task could be left in a genuinely
    /// invalid combination (days/weeks paired with a relative-date
    /// pattern) that `TaskItem.hasRecurringOccurrence` was never written
    /// to dispatch on. Switching *to* `.months` touches nothing else —
    /// whatever `recurrenceMode`/pattern was last set (or its stored
    /// default) is left for the "On the" row to show/confirm.
    static func selectRecurrenceUnit(_ unit: RecurrenceUnit, on task: TaskItem) {
        task.recurrenceUnit = unit
        if unit != .months {
            task.recurrenceMode = .specificDate
        }
        task.recurrenceIntervalPicked = true
    }

    static func selectRecurrenceTimeMode(_ mode: HabitOccurrenceTimeMode, on task: TaskItem) {
        task.recurrenceTimeMode = mode
        task.recurrenceTimeModePicked = true
    }

    /// The "On the" row's own two-way choice — "Day of month" or
    /// "Weekday of month." Both set `recurrenceMode = .relativeDate`
    /// unconditionally: choosing *either* one here is choosing to use a
    /// relative pattern at all, before the day-of-month branch's own
    /// `DayOfMonthPosition` sub-choice (see below) decides whether that
    /// holds — its "Same day" option quietly flips `recurrenceMode` back
    /// to `.specificDate`, reusing the existing Specific Date evaluator
    /// for "recur on the same day-of-month as the anchor" rather than
    /// teaching the Relative Date evaluator a new case for it (per this
    /// change's own scope: the evaluator branches stay exactly as they
    /// are, only how the user selects between them changes).
    static func selectMonthlyScope(_ scope: RelativeRecurrenceScope, on task: TaskItem) {
        task.relativeRecurrenceScope = scope
        task.recurrenceMode = .relativeDate
        task.relativeRecurrencePicked = true
    }

    /// The day-of-month branch's own three-way choice, replacing what
    /// used to be a plain First/Last `RelativeRecurrenceOrdinal` picker.
    /// "Same day" is the one genuinely new pattern this whole redesign
    /// adds — "recur on the same day of the month as the anchor," which
    /// was already fully expressible before (as Specific Date, monthly),
    /// just not reachable from what looked like the day-of-month
    /// question. Deliberately its own small enum rather than stretching
    /// `RelativeRecurrenceOrdinal` to cover it: that type's cases are
    /// evaluator inputs for the Relative Date branch specifically (see
    /// its own doc comment on why it deliberately stops at `.fourth`/
    /// `.last`), and "Same day" isn't a Relative Date pattern at all — it
    /// dispatches to the *other* evaluator branch entirely.
    enum DayOfMonthPosition: CaseIterable, Hashable {
        case first, last, sameAsAnchor

        var label: String {
            switch self {
            case .first: return "First day"
            case .last: return "Last day"
            case .sameAsAnchor: return "Same day"
            }
        }
    }

    /// Derives the day-of-month branch's current choice by reading
    /// `recurrenceMode`/`relativeRecurrenceOrdinal` back — `.specificDate`
    /// (any reason, including "never touched") reads as "Same day," which
    /// is exactly its correct display value regardless of which of those
    /// two the task is actually in, since "Same day" *is* what
    /// `.specificDate` means here. `!relativeRecurrencePicked` (tracked
    /// separately, see `TaskItem.relativeRecurrenceMissing`) is what
    /// tells "never touched" apart from "deliberately Same day" for
    /// missing-attribute purposes — this function only answers "what
    /// should the picker show," not "has this been decided."
    static func dayOfMonthPosition(for task: TaskItem) -> DayOfMonthPosition {
        guard task.recurrenceMode == .relativeDate else { return .sameAsAnchor }
        return task.relativeRecurrenceOrdinal == .last ? .last : .first
    }

    static func selectDayOfMonthPosition(_ position: DayOfMonthPosition, on task: TaskItem) {
        switch position {
        case .first:
            task.recurrenceMode = .relativeDate
            task.relativeRecurrenceOrdinal = .first
        case .last:
            task.recurrenceMode = .relativeDate
            task.relativeRecurrenceOrdinal = .last
        case .sameAsAnchor:
            task.recurrenceMode = .specificDate
        }
        task.relativeRecurrencePicked = true
    }

    /// The weekday-of-month branch's own Position row (First/Second/
    /// Third/Fourth/Last) — `recurrenceMode` is already `.relativeDate`
    /// by the time this is reachable at all (set by `selectMonthlyScope`
    /// when "Weekday of month" was chosen), so this only ever touches the
    /// ordinal itself.
    static func selectRelativeOrdinal(_ ordinal: RelativeRecurrenceOrdinal, on task: TaskItem) {
        task.relativeRecurrenceOrdinal = ordinal
        task.relativeRecurrencePicked = true
    }

    static func selectRelativeWeekday(_ weekday: Int, on task: TaskItem) {
        task.relativeRecurrenceWeekday = weekday
        task.relativeRecurrencePicked = true
    }

    /// Migration for existing rows created before this redesign — called
    /// from `body`'s `.onAppear`, alongside the identically-shaped
    /// backfills for `recurrenceIntervalPicked`/`recurrenceTimeModePicked`
    /// there. `relativeRecurrenceMissing` now gates on `recurrenceUnit ==
    /// .months` (see its own doc comment) rather than only `recurrenceMode
    /// == .relativeDate`, so a pre-existing *Specific Date* monthly task
    /// (the far more common, longstanding case — "Specific Date" predates
    /// "Relative Date" entirely) would otherwise start reading "Pattern"
    /// as missing the first time this ships, despite already being a
    /// fully configured, actively scheduling task. `dueDate != nil` is
    /// the same "this was genuinely configured, not just sitting on
    /// defaults" signal the other two backfills already use.
    ///
    /// Pulled out as its own function (unlike the other two, still
    /// inline) specifically so a test can exercise the migration without
    /// hosting a live view — this is the one this whole redesign's
    /// "existing rows of both modes still evaluate identically" test
    /// needs to call directly.
    static func backfillRelativeRecurrencePickedIfNeeded(_ task: TaskItem) {
        guard task.isRecurring, task.dueDate != nil, task.recurrenceUnit == .months, !task.relativeRecurrencePicked else { return }
        task.relativeRecurrencePicked = true
    }

    /// The card's shelf-preview state. Tapping a shelf, or flipping a
    /// toggle that implies one, only *previews* it — the move itself
    /// happens on commit (see `commitAndAdvance`). An enum rather than a
    /// `Shelf?` because "no preview, fall back to the task's own shelf"
    /// and "explicitly previewing this shelf" are genuinely different
    /// states, and a later one — explicitly previewing *no* shelf — can't
    /// be expressed by `nil` at all without colliding with the first.
    enum ShelfPreview {
        /// Nothing previewed; the card reads the task's own shelf.
        case none
        /// This shelf is previewed, whether tapped or implied by a toggle.
        case shelf(Shelf)
        /// Explicitly previewing *no* shelf — distinct from `.none`,
        /// which falls back to the task's own. Reached by raising a
        /// 2-Minute shelf resident's duration above two minutes: falling
        /// back would resolve to the 2-Minute shelf again, which no longer
        /// matches the duration. The card asks for a destination instead
        /// (see `actionButtonInfo`).
        ///
        /// **Carries its reason rather than relying on there being one
        /// producer.** There is exactly one today, so the prompt could just
        /// assume — but a second producer added later would silently
        /// inherit copy claiming the task stopped being a 2-minute task.
        /// Making the reason explicit forces that future case to say what
        /// it is instead.
        case cleared(Reason)

        enum Reason {
            /// Duration was raised above two minutes on a task living on
            /// the 2-Minute shelf.
            case noLongerTwoMinute
        }

        /// What the card should actually read its shelf-gated questions
        /// from.
        func resolved(for task: TaskItem) -> Shelf? {
            switch self {
            case .none: return task.shelf
            case .shelf(let shelf): return shelf
            case .cleared: return nil
            }
        }

        /// The explicitly-previewed shelf, if any — `nil` when nothing is
        /// previewed. This is what the commit path and the "is moving"
        /// checks read; they care about a deliberate pick, not about
        /// whatever the task already sits on.
        var explicitShelf: Shelf? {
            if case .shelf(let shelf) = self { return shelf }
            return nil
        }

        var isRecurringShelf: Bool { explicitShelf?.isRecurringTasks == true }

        /// True while the user has turned 2-Minute off but not yet said
        /// where the task should go. Blocks commit — see
        /// `actionButtonInfo`.
        var needsShelfChoice: Bool { if case .cleared = self { return true }; return false }

        /// The prompt shown above the shelf grid while a choice is owed,
        /// phrased per reason so it reads as a question rather than an
        /// error. `nil` whenever no choice is owed.
        var shelfChoicePrompt: String? {
            guard case .cleared(let reason) = self else { return nil }
            switch reason {
            case .noLongerTwoMinute: return "No longer a 2-minute task — where should it go?"
            }
        }
    }

    /// Seeds eligible schedules from whichever shelf is now in effect.
    ///
    /// **Behavior change from the extraction commit, deliberate.** That
    /// commit pinned an asymmetry: toggling on seeded eligibility, and
    /// toggling off left the old shelf's rule IDs in place. Those IDs
    /// then matched no rule on the shelf the card had reverted to, so
    /// `eligibleSchedulesMissing` read "answered" while
    /// `TaskItem.isEligible(for:)` returned false for every rule actually
    /// present — a task that looks complete and is eligible for nothing,
    /// which stays invisible until scheduling quietly stops placing it.
    /// A latent bug rather than a design choice, so the card spec's
    /// "shelf auto-switch resets eligible schedules" wins and this now
    /// runs in both directions.
    static func seedEligibleSchedules(task: TaskItem, from shelf: Shelf?) {
        task.includedSchedulingRuleIDs = (shelf?.schedulingRules ?? []).filter(\.isEnabled).map(\.id)
    }

    /// Rows a task currently shows at all (greyed counts — it's visible).
    private static func visibleRows(task: TaskItem, shelf: Shelf?) -> Set<CardRow> {
        Set(CardRow.allCases.filter { $0.visibility(task: task, shelf: shelf) != .hidden })
    }

    /// Runs `mutate`, then clears exactly the rows that disappeared as a
    /// result — computed as (visible before − visible after) rather than
    /// hand-listed.
    ///
    /// That derivation is the point. A hand-written reset list has no
    /// structural tie to what the toggle actually hides, so it can clear
    /// a field the toggle doesn't own, or silently go stale when a row is
    /// added to `CardRow`. Here a toggle can only reach rows that
    /// genuinely vanished.
    private static func applyTogglePreservingOnlyVisibleRows(
        task: TaskItem, preview: ShelfPreview, _ mutate: () -> ShelfPreview
    ) -> ShelfPreview {
        let before = visibleRows(task: task, shelf: preview.resolved(for: task))
        let next = mutate()
        let after = visibleRows(task: task, shelf: next.resolved(for: task))
        for row in before.subtracting(after) { row.resetFields(on: task) }
        return next
    }

    /// What flipping "Recurring?" does beyond setting the flag, as a pure
    /// function of the current state.
    ///
    /// **Extracted out of the `Toggle`'s own `set:` closure so it can be
    /// tested at all.** Sabotaging this body in place passed all 518
    /// tests before the extraction; the same sabotage now fails.
    ///
    /// Asymmetry deliberately retained: toggling off clears the preview
    /// only when the *preview* is the Recurring shelf, not when the
    /// task's own shelf is. `isRecurring` is stored, so unlike derived
    /// 2-minute-ness it can't snap back on, and forcing a shelf choice
    /// here would be a change nothing asked for.
    static func applyRecurringToggle(
        _ isOn: Bool, task: TaskItem, shelves: [Shelf], preview: ShelfPreview
    ) -> ShelfPreview {
        applyTogglePreservingOnlyVisibleRows(task: task, preview: preview) {
            guard isOn else {
                task.setRecurring(false)
                guard preview.isRecurringShelf else { return preview }
                let next = ShelfPreview.none
                seedEligibleSchedules(task: task, from: next.resolved(for: task))
                return next
            }
            // Start Date is the anchor here — see `TaskItem.makeRecurring`
            // for why the flag and anchor are set together. `setRecurring`
            // additionally keeps the 2-Minute exclusion.
            task.setRecurring(true)
            guard let recurringShelf = shelves.first(where: { $0.isRecurringTasks }) else { return preview }
            seedEligibleSchedules(task: task, from: recurringShelf)
            return .shelf(recurringShelf)
        }
    }

    /// Keeps the shelf preview in step with the duration. **Duration is
    /// the single trigger for 2-minute-ness** — there is no toggle.
    ///
    /// Three transitions, and deliberately no fourth:
    /// - **≤2 min, not already on the shelf** → preview the 2-Minute shelf.
    ///   A *preview*, not a move: `onMove` still only fires at commit, so
    ///   the action button reads "Save, Move & Submit" and raising the
    ///   duration again undoes it with nothing written.
    /// - **>2 min, task actually lives on the 2-Minute shelf** → `.cleared`.
    ///   Falling back to its own shelf would resolve to 2-Minute again,
    ///   which the duration no longer matches, so the card asks where it
    ///   should go instead.
    /// - **>2 min, the 2-Minute preview was ours** → back to `.none`, which
    ///   falls back to the shelf the task was on before.
    ///
    /// A preview the *user* picked is never touched — only the one this
    /// rule set. That's what makes an explicit shelf tap win over the
    /// duration rule without needing a suppression flag: the rule simply
    /// has nothing of its own to undo.
    ///
    /// Replaced `applyTwoMinuteToggle`. Two triggers writing one shelf
    /// needed arbitration and, on the losing path, a persisted "user
    /// overrode this" flag — stored 2-minute-ness by another name, which
    /// is what the derived representation exists to avoid.
    static func applyDurationDrivenShelf(
        task: TaskItem, shelves: [Shelf], preview: ShelfPreview
    ) -> ShelfPreview {
        applyTogglePreservingOnlyVisibleRows(task: task, preview: preview) {
            durationDrivenShelf(task: task, shelves: shelves, preview: preview)
        }
    }

    /// The transition itself, wrapped above by the derived reset so landing
    /// on the 2-Minute shelf clears exactly the rows that shelf hides.
    ///
    /// **Duration is safe from that reset by construction**, which is the
    /// point of deriving it rather than listing it: Duration stays *visible*
    /// on a 2-Minute task (see `CardRow.duration`), so it is never in
    /// (visible before − visible after) and cannot be cleared. A
    /// hand-written reset list would have had to remember not to clear the
    /// very value that triggered the move.
    private static func durationDrivenShelf(
        task: TaskItem, shelves: [Shelf], preview: ShelfPreview
    ) -> ShelfPreview {
        let isTwoMinuteDuration = task.durationPicked && task.estimatedMinutes > 0 && task.estimatedMinutes <= 2

        if isTwoMinuteDuration {
            guard task.shelf?.isTwoMinuteTasks != true else { return .none }
            guard let twoMinuteShelf = shelves.first(where: { $0.isTwoMinuteTasks }) else { return preview }
            guard preview.explicitShelf?.id != twoMinuteShelf.id else { return preview }
            // Recurring loses here, matching what the toggle did: the
            // action just taken wins (see
            // `TaskItem.repairSpecialShelfExclusivity`).
            task.isRecurring = false
            seedEligibleSchedules(task: task, from: twoMinuteShelf)
            return .shelf(twoMinuteShelf)
        }

        if task.shelf?.isTwoMinuteTasks == true {
            seedEligibleSchedules(task: task, from: nil)
            return .cleared(.noLongerTwoMinute)
        }
        if preview.explicitShelf?.isTwoMinuteTasks == true {
            seedEligibleSchedules(task: task, from: task.shelf)
            return .none
        }
        return preview
    }

    init(
        task: TaskItem,
        shelves: [Shelf],
        onDiscard: @escaping () -> Void,
        onSkip: @escaping () -> Void,
        onMove: @escaping (Shelf) -> Void,
        onNext: @escaping () -> Void,
        onSnooze: ((Int?) -> Void)? = nil,
        entersFromLeft: Bool = false,
        // Same flag `TaskCardSheet.cancel` already reads — see
        // `initialExpandedRows`'s own doc comment. Defaulted so
        // `TaskReviewQueueSheet`'s call site (no newly-created-task
        // concept at all — every queued task already exists) needs no
        // change.
        isNewlyCreated: Bool = false,
        /// The moment "at risk" is evaluated against. Defaults to real
        /// wall-clock time; injected by the render-baseline tests so a
        /// fixture's appearance can't depend on when the suite happens to
        /// run.
        ///
        /// This is not hypothetical. `tail_recurring`'s baseline went red
        /// with no code change because the card crossed an at-risk
        /// threshold partway through a day — and the determinism check that
        /// blessed these baselines only compared repeat runs minutes apart
        /// and across a rebuild, which cannot see a dependence on time of
        /// day. `TaskItem.atRiskBlocker` already took `asOf` for exactly
        /// this reason; the card just never passed one.
        asOf: Date = .now
    ) {
        self.asOf = asOf
        self.task = task
        self.shelves = shelves
        self.onDiscard = onDiscard
        self.onSkip = onSkip
        self.onMove = onMove
        self.onNext = onNext
        self.onSnooze = onSnooze
        self.entersFromLeft = entersFromLeft
        _dragOffset = State(initialValue: entersFromLeft ? CGSize(width: -500, height: 0) : .zero)
        // Seeded from `task.shelf` directly, not `previewedShelf` —
        // `shelfPreview` (what `previewedShelf` would otherwise prefer)
        // is itself `@State` with no value yet at this point in `init`,
        // and nothing's been previewed before the card has even
        // appeared, so `task.shelf` is exactly what `previewedShelf`
        // would evaluate to here anyway.
        _expandedRows = State(initialValue: Self.initialExpandedRows(
            task: task, shelf: task.shelf,
            segmentOptions: TaskItem.validSegmentOptions(for: task.estimatedMinutes),
            isNewlyCreated: isNewlyCreated
        ))
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
                    // "No" is a complete, terminal answer — nothing
                    // further to pick (unlike "Yes," which only reveals
                    // the calendar; that branch's own real terminal
                    // moment is the calendar tap in `dueExpandedContent`).
                    if isDueConfigured { expandedRows.remove(.due) }
                case .none:
                    task.dueDateDecided = false
                    task.dueDate = nil
                    task.dueDatePicked = false
                }
            }
        )
    }

    /// nil until "Has next step" is actually answered either way — same
    /// shape as `dueDateAnswer`. Untapping Yes (going back to nil) clears
    /// whatever was typed, same as `dueDateAnswer`'s "No" clears
    /// `dueDate` — there's no reason to keep stale text around for a
    /// question that's now unanswered again.
    /// The Yes/No control plus, on Yes, the text field — the same pair that
    /// lived in `cardHeader` before this became an ordinary row.
    ///
    /// Collapse timing differs from every other row and has to: Next Step is
    /// the only question whose answer arrives in two steps. "No" finishes in
    /// one tap and self-collapses in `nextStepAnswer`'s setter; "Yes" opens a
    /// text field, so it collapses when that field loses focus — provided
    /// something was actually typed. Yes-with-empty-text stays open, because
    /// it is still reported missing (see `isNextStepConfigured`) and a row
    /// that collapsed there would read as answered when it isn't.
    @ViewBuilder
    private var nextStepExpandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            YesNoToggle(title: "Has next step", answer: nextStepAnswer)
            if nextStepAnswer.wrappedValue == true {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    // Single-line so Return can dismiss the keyboard. The
                    // `axis: .vertical` that used to be here made Return
                    // insert a newline instead, leaving the toolbar Done as
                    // the only way out.
                    //
                    // The font-shrink rule (`.subheadline` past 30
                    // characters) went with it. It existed to keep a
                    // *wrapped* block compact — more lines, smaller type.
                    // A single-line field doesn't wrap, so shrinking buys a
                    // few more visible characters before it scrolls and
                    // costs legibility on every value; the collapsed row's
                    // summary is what a long value is actually read from,
                    // and that truncates with an ellipsis at full size.
                    TextField("Next step", text: $task.nextStep)
                        .font(.body.weight(.medium))
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                        .focused($focusedField, equals: .nextStep)
                        .onAppear {
                            guard focusNextStepWhenFieldAppears else { return }
                            focusNextStepWhenFieldAppears = false
                            // Setting `focusedField` here — rather than
                            // scrolling directly — keeps the existing
                            // scroll-into-view working: the scroll body
                            // watches `focusedField`, so this takes the same
                            // path a manual tap does instead of bypassing it.
                            focusedField = .nextStep
                        }
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: nextStepAnswer.wrappedValue)
        .id("nextStepSection")
        .onChange(of: focusedField) { previous, current in
            // Blur is this field's "I'm done" moment, the same role a
            // popover dismiss plays for the Specific-Time clock.
            guard previous == .nextStep, current != .nextStep else { return }
            if isNextStepConfigured { expandedRows.remove(.nextStep) }
        }
    }

    private var nextStepAnswer: Binding<Bool?> {
        Binding(
            get: { task.nextStepDecided ? task.nextStepAnsweredYes : nil },
            set: { newValue in
                focusedField = nil
                switch newValue {
                case .some(true):
                    task.nextStepDecided = true
                    task.nextStepAnsweredYes = true
                    // The field is created by this same state change, so it
                    // focuses itself on appear — see
                    // `focusNextStepWhenFieldAppears`.
                    focusNextStepWhenFieldAppears = true
                case .some(false):
                    task.nextStepDecided = true
                    task.nextStepAnsweredYes = false
                    task.nextStep = ""
                    // "No" is a finished answer with nothing left to do, so
                    // it self-collapses immediately — same as Due landing on
                    // "None". "Yes" deliberately does not: the text field is
                    // the rest of the answer, and it collapses on blur below.
                    expandedRows.remove(.nextStep)
                case .none:
                    task.nextStepDecided = false
                    task.nextStepAnsweredYes = false
                    task.nextStep = ""
                }
            }
        )
    }

    /// Formats minutes-since-midnight (e.g. `570` → "9:30 AM") for the
    /// Occurrence Time button's label — routes through `Date` purely
    /// because `DateFormatter`/`.formatted(time:)` only know how to
    /// format a `Date`, not a raw minute count.
    private static func formattedTime(minutesSinceMidnight: Int) -> String {
        let date = Calendar.current.date(bySettingHour: minutesSinceMidnight / 60, minute: minutesSinceMidnight % 60, second: 0, of: .now) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
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
            // The Duration and Divisible backfills that used to sit here
            // are gone: both patched up pre-`...AnsweredYes`/`...Decided`
            // rows, and both questions have since collapsed to a single
            // wheel whose one flag is reconciled at launch instead — see
            // `NoteForLaterApp.migrateDurationDivisibleToSingleWheelIfNeeded`.
            // Leaving them here would have meant two mechanisms writing
            // the same flags on different schedules.
            //
            // Same idea for tasks that already had real next-step text
            // typed before `nextStepDecided` existed — otherwise every
            // one of them would suddenly read as unanswered (and
            // therefore missing) despite already having a next step.
            if !task.nextStep.isEmpty, !task.nextStepDecided {
                task.nextStepDecided = true
                task.nextStepAnsweredYes = true
            }
            // Same idea for tasks that already had a real start date set
            // before `startDatePicked` existed — otherwise it'd suddenly
            // read as "Not Selected" despite already having one.
            if task.startDate != nil, !task.startDatePicked {
                task.startDatePicked = true
            }
            // Same idea for a recurring task that already had a real
            // anchor (`dueDate`) before `recurrenceIntervalPicked`/
            // `recurrenceTimeModePicked` existed — `dueDate` only gets
            // set once a task is genuinely placing on the calendar (see
            // `TaskItem.makeRecurring`), so its presence is proof "Every"
            // and "Time" were already meaningfully configured, not just
            // sitting on their stored defaults.
            if task.isRecurring, task.dueDate != nil {
                if !task.recurrenceIntervalPicked { task.recurrenceIntervalPicked = true }
                if !task.recurrenceTimeModePicked { task.recurrenceTimeModePicked = true }
                Self.backfillRelativeRecurrencePickedIfNeeded(task)
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
    /// merely tapping a shelf to preview it (`shelfPreview` alone, tracked
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
        shelfPreview.resolved(for: task)
    }

    /// Whether Due Date is currently answerable — off the moment a
    /// previewed (or actual) shelf doesn't track due dates, so the section
    /// fades and forces "No" without touching the task's real stored
    /// answer, in case the preview gets cancelled. Real clearing only
    /// happens once the move actually commits (see the `onMove` call sites).
    private var dueDatesAllowed: Bool {
        previewedShelf?.effectiveTracksDueDates ?? true
    }

    /// Same idea as `dueDatesAllowed`, for Duration and Divisible —
    /// shelf-level only (greyed, not hidden, since the preview could
    /// still be cancelled). Both flavors of the "Time" row (recurring and
    /// non-recurring) share this same gate.
    private var durationAllowed: Bool {
        previewedShelf?.effectiveTracksDuration ?? true
    }

    /// Instance wrappers around the `static` configured-checks above,
    /// reading live view state (`previewedShelf`, `segmentOptions`) —
    /// `init` calls the `static` versions directly since `self` isn't
    /// available yet there. See those functions' own doc comments.
    private var isRepeatsConfigured: Bool {
        Self.isRepeatsConfigured(task: task, shelf: previewedShelf)
    }

    private var isStartsConfigured: Bool {
        Self.isStartsConfigured(task: task, shelf: previewedShelf)
    }

    private var isTimeConfigured: Bool {
        Self.isTimeConfigured(task: task, shelf: previewedShelf, segmentOptions: segmentOptions)
    }

    private var isNextStepConfigured: Bool {
        Self.isNextStepConfigured(task: task, shelf: previewedShelf)
    }

    private var isDueConfigured: Bool {
        Self.isDueConfigured(task: task, shelf: previewedShelf)
    }

    private var isDurationConfigured: Bool {
        Self.isDurationConfigured(task: task, shelf: previewedShelf)
    }

    private var isPriorityConfigured: Bool {
        Self.isPriorityConfigured(task: task, shelf: previewedShelf)
    }

    private var isDivisibleConfigured: Bool {
        Self.isDivisibleConfigured(task: task, shelf: previewedShelf)
    }

    private var showsDivisibleRow: Bool {
        durationAllowed && Self.showsDivisibleRow(task: task)
    }

    private var showsDurationRow: Bool {
        Self.showsDurationRow(task: task)
    }

    /// Duration as a single wheel — no Yes/No question in front of it
    /// anymore. Extracted out of `cardScrollBody` so it's reusable both
    /// by the non-recurring card's own "Time" row and embedded directly
    /// inside a recurring task's "Time" row (`recurringSection`).
    ///
    /// `0` is a real, selectable option ("None"), meaning *don't schedule
    /// this* — see `SchedulingRule.fitStatus`'s `.needsDuration`. What
    /// distinguishes it from "never answered" is `task.durationPicked`,
    /// not the value.
    ///
    /// **The sentinel is what makes an untouched wheel answerable.**
    /// `Picker(selection:)` only fires on a genuine value change, so a
    /// wheel already sitting on the value you want can never mark itself
    /// answered — the exact bug this codebase has hit repeatedly (see
    /// `PickedMenuPicker`'s own doc comment for the `Menu` equivalent).
    /// Prepending `durationNotSelectedTag` while `!durationPicked` means
    /// the displayed value is never a valid answer, so *every* selection
    /// is a real change: scrolling to any option, "None" included, fires
    /// and marks it picked. Once picked, the sentinel drops out of the
    /// list and can't be returned to.
    @ViewBuilder
    private var durationControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            // No inline "Duration" label — the `CollapsibleAnswerRow`
            // header this now sits inside supplies both the label and the
            // current value, so repeating it here would double it up.
            Picker("Duration", selection: durationWheelSelection) {
                if !task.durationPicked {
                    Text("Not selected")
                        .font(.subheadline.weight(.semibold))
                        .tag(Self.durationNotSelectedTag)
                }
                ForEach(durationWheelOptions, id: \.self) { minutes in
                    Text(Self.durationOptionLabel(for: minutes))
                        .font(.subheadline.weight(.semibold))
                        .tag(minutes)
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .frame(height: 100)
            .clipped()

            // `estimatedMinutes` itself never changes from a partial
            // placement (see `TaskItem.remainingMinutes`) — this is
            // the one place that surfaces the difference, rather than
            // the duration silently reading as the task's full size
            // while some of it is actually still sitting unplaced.
            if task.durationPicked, task.estimatedMinutes > 0, task.remainingMinutes < task.estimatedMinutes {
                Text("\(TaskItem.durationLabel(for: task.estimatedMinutes - task.remainingMinutes)) of \(TaskItem.durationLabel(for: task.estimatedMinutes)) scheduled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
        .disabled(!durationAllowed)
        .opacity(durationAllowed ? 1 : 0.4)
        .animation(.easeInOut(duration: 0.15), value: task.durationPicked)
        .animation(.easeInOut(duration: 0.15), value: durationAllowed)
    }

    /// The out-of-range value the "Not selected" row carries while
    /// `!durationPicked`/`!divisiblePicked`. Negative so it can never
    /// collide with a real minutes value (`0` is "None"/"Not Divisible",
    /// a genuine answer).
    static let durationNotSelectedTag = -1

    /// "None" for `0`, "≤2 min" for the 2-minute floor, otherwise
    /// `TaskItem.durationLabel`. `internal` for direct testability, same
    /// reasoning as `isRepeatsConfigured`.
    static func durationOptionLabel(for minutes: Int) -> String {
        if minutes <= 0 { return "None" }
        if minutes == 2 { return "≤2 min" }
        return TaskItem.durationLabel(for: minutes)
    }

    /// Routes every wheel change through `TaskItem.selectDuration`, so
    /// the value and `durationPicked` are always written together. The
    /// sentinel is never written back — it only ever appears as the
    /// *current* selection of an unpicked wheel, and selecting it isn't
    /// possible once it's dropped from the list.
    private var durationWheelSelection: Binding<Int> {
        Binding(
            get: { task.durationPicked ? task.estimatedMinutes : Self.durationNotSelectedTag },
            set: { newValue in
                guard newValue != Self.durationNotSelectedTag else { return }
                focusedField = nil
                // Deliberately no self-collapse: a wheel is scrolled,
                // not tapped once, so the first tick isn't a finished
                // answer. Same rule the Divisible wheel and the
                // Specific-Time clock already follow.
                TaskItem.selectDuration(newValue, on: task)
                // Duration drives the shelf — see
                // `applyDurationDrivenShelf`. Runs after the write so it
                // reads the value just set, and only from here: this is
                // the single point the wheel writes duration.
                shelfPreview = Self.applyDurationDrivenShelf(
                    task: task, shelves: shelves, preview: shelfPreview
                )
            }
        )
    }

    /// Divisible as a single wheel, same shape and same sentinel
    /// reasoning as `durationControl` — `0` is "Not Divisible," a real
    /// answer rather than an absence of one.
    ///
    /// Whether this row appears at all is the caller's decision now
    /// (`showsDivisibleRow` — a duration of at least
    /// `TaskItem.divisibleMinimumDurationMinutes` that something evenly
    /// divides), so by the time this renders there's always at least one
    /// real segment size to offer besides "Not Divisible".
    @ViewBuilder
    private var divisibleControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Divisible", selection: divisibleWheelSelection) {
                if !task.divisiblePicked {
                    Text("Not selected")
                        .font(.subheadline.weight(.semibold))
                        .tag(Self.durationNotSelectedTag)
                }
                Text("Not Divisible")
                    .font(.subheadline.weight(.semibold))
                    .tag(0)
                ForEach(segmentOptions, id: \.self) { minutes in
                    Text(TaskItem.durationLabel(for: minutes))
                        .font(.subheadline.weight(.semibold))
                        .tag(minutes)
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .frame(height: 100)
            .clipped()
        }
        .padding(.top, 4)
        .disabled(!durationAllowed)
        .opacity(durationAllowed ? 1 : 0.4)
        .animation(.easeInOut(duration: 0.15), value: task.divisiblePicked)
        .animation(.easeInOut(duration: 0.15), value: durationAllowed)
    }

    /// Same pairing discipline as `durationWheelSelection`, routed
    /// through `TaskItem.selectDivisibleSegment` so `isDivisible` and
    /// `minimumSegmentMinutes` can never disagree.
    private var divisibleWheelSelection: Binding<Int> {
        Binding(
            get: { task.divisiblePicked ? task.minimumSegmentMinutes : Self.durationNotSelectedTag },
            set: { newValue in
                guard newValue != Self.durationNotSelectedTag else { return }
                focusedField = nil
                TaskItem.selectDivisibleSegment(newValue, on: task)
            }
        )
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
                // Terminal either way — no coupled control either
                // answer could still leave mid-adjustment.
                if isPriorityConfigured { expandedRows.remove(.priority) }
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
            if let blocker = task.atRiskBlocker(asOf: asOf) {
                Label("At risk — \(blocker)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
            }

        }
        .padding(16)
        .padding(.bottom, 0)
    }

    /// "Monthly · 4th Saturday" — `TaskItem.recurrenceShortSummary`, the
    /// compact form built specifically so this row fits on one line (see
    /// that property's own doc comment for why it's a genuinely separate
    /// property from `recurrenceSummary`, not a "short" flag on it — the
    /// long form is still exactly what `ShelfListView.recurrenceLine`
    /// shows on the shelf card, untouched by this).
    ///
    /// Shows the *live* value even before it's been "picked" — a fresh
    /// recurring task's real stored default (`recurrenceUnit == .days`,
    /// `recurrenceIntervalCount == 1`) reads "Daily" here, not "Not
    /// Selected", the same way `recurrenceUnit`/`recurrenceIntervalCount`
    /// already showed "1"/"Day" pre-highlighted the moment "Repeats" was
    /// expanded — the collapsed summary was the only place still lying
    /// about it. This is purely cosmetic, though: `isRepeatsConfigured`
    /// (unchanged) still drives the row's italic/secondary "not decided
    /// yet" styling and still gates `missingAttributeNames`, so a task
    /// that's never actually had "Repeats" opened and confirmed still
    /// surfaces as missing — reading "Daily" here is not the same as
    /// being silently, unconfirmedly daily.
    private var repeatsSummaryText: String {
        task.recurrenceShortSummary ?? "Not Selected"
    }

    /// "Thu, Sep 17, 2026" — abbreviated weekday, abbreviated month, no
    /// full spelled-out names, unlike the previous `.complete` style
    /// ("Thursday, September 17, 2026"), which fit only by luck: a longer
    /// weekday/month pair would wrap the row. `Self.abbreviatedDateFormatter`
    /// is shared with `endsSummaryText` — both date-only rows want the
    /// identical compact form, and both are inherently bounded (`EEE`/
    /// `MMM` are fixed-width 3-letter abbreviations in English), so
    /// there's no plausible weekday/month pair that wraps.
    private var startsSummaryText: String {
        task.startDatePicked ? Self.abbreviatedDateFormatter.string(from: task.startDate ?? .now) : "Not Selected"
    }

    /// "9:00 AM" for Specific Time, or the bare mode label
    /// ("AM"/"Midday"/"PM") for an untimed occurrence.
    ///
    /// Just the mode label now. It used to append a duration, and before
    /// that a clock time for Specific Time — both gone: Duration is its own
    /// row, and a task can no longer be Specific Time at all. `.specific`
    /// still has to be handled because `HabitOccurrenceTimeMode` keeps the
    /// case for habits; it renders its label like any other, and is only
    /// reachable by a legacy row the migration hasn't run on yet.
    /// Shows the *live* value even before "Time" has actually been
    /// picked — same reasoning, and same "cosmetic only" guarantee, as
    /// `repeatsSummaryText`'s own doc comment: `recurrenceTimeMode`'s
    /// real stored default is now `.midday`, so a fresh task reads
    /// "Midday" here, not "Not Selected," but `isTimeConfigured`
    /// (unchanged, still gated on `recurrenceTimeModePicked`) is what
    /// actually drives the row's italic styling and
    /// `missingAttributeNames` — this alone doesn't make a task silently,
    /// unconfirmedly Midday.
    private var timeSummaryText: String {
        task.recurrenceTimeMode.label
    }

    /// "Never" is a real, fully-decided answer (see `isEndsExpanded`'s
    /// own doc comment) — never "Not Selected". Same bounded, weekday-
    /// inclusive short date form as `startsSummaryText` — see that
    /// property's own doc comment for why it's safe from wrapping.
    private var endsSummaryText: String {
        task.recurrenceEndDate.map { Self.abbreviatedDateFormatter.string(from: $0) } ?? "Never"
    }

    /// "Thu, Sep 17, 2026" — shared by `startsSummaryText`/`endsSummaryText`,
    /// the two date-only collapsed-row summaries.
    private static let abbreviatedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d, yyyy"
        return formatter
    }()

    /// The non-recurring card's own "Due" row. Three states, not two —
    /// this is the one place collapsing "Has due date" into a single
    /// value row could have silently lost the undecided-vs-decided-as-
    /// none distinction those flags exist for (see `TaskItem
    /// .dueDateMissing`'s own doc comment), so all three are spelled out
    /// explicitly rather than derived from a single optional:
    /// - undecided (`!dueDateDecided`), or decided-yes-but-not-yet-picked
    ///   (`dueDate != nil && !dueDatePicked`, the moment right after
    ///   tapping "Yes" and before a real date is chosen) → "Not selected"
    ///   — `isDueConfigured` is false for both, so both still surface in
    ///   `missingAttributeNames`.
    /// - decided-as-none (`dueDateDecided && dueDate == nil`) → "None",
    ///   a real committed answer, not missing.
    /// - decided-and-picked → the date itself.
    ///
    /// `static`, `internal` (not `private`) — same reasoning as
    /// `isRepeatsConfigured`'s own doc comment: this is exactly the
    /// display logic a "collapse undecided and none into one state" bug
    /// would land in, so it needs to be exercisable directly by a unit
    /// test rather than only inferred from `isDueConfigured`'s boolean.
    static func dueSummaryText(task: TaskItem, shelf: Shelf?) -> String {
        guard isDueConfigured(task: task, shelf: shelf) else { return "Not selected" }
        guard let dueDate = task.dueDate else { return "None" }
        return abbreviatedDateFormatter.string(from: dueDate)
    }

    /// Four states, matching `isNextStepConfigured`:
    /// undecided → "Not Selected"; No → "None" (the same word Due uses for
    /// a deliberate no-answer); Yes with text → the text; **Yes with empty
    /// text → "Not Selected"**, because that is still reported missing and
    /// the row must not look answered when it isn't.
    private var nextStepSummaryText: String {
        guard task.nextStepDecided else { return "Not Selected" }
        guard task.nextStepAnsweredYes else { return "None" }
        return task.nextStep.isEmpty ? "Not Selected" : task.nextStep
    }

    private var dueSummaryText: String {
        Self.dueSummaryText(task: task, shelf: previewedShelf)
    }

    /// The non-recurring card's own "Time" row — Duration and Divisible
    /// only (see `isDurationConfigured`'s own doc comment for why there's
    /// no mode/clock question here the way the recurring row has one).
    /// Same three-state shape and same testability reasoning as
    /// `dueSummaryText`: undecided → "Not selected", decided-no → "None",
    /// decided-yes-with-a-value → the duration itself. Divisible doesn't
    /// factor into the summary any more than it does for the recurring
    /// row's own `timeSummaryText`.
    static func durationSummaryText(task: TaskItem) -> String {
        guard task.durationPicked else { return "Not selected" }
        return durationOptionLabel(for: task.estimatedMinutes)
    }

    private var durationSummaryText: String {
        Self.durationSummaryText(task: task)
    }

    /// "Not Divisible" is a real answer (`minimumSegmentMinutes == 0`),
    /// distinct from never having answered — same shape as
    /// `durationSummaryText`, reading `divisiblePicked` for the
    /// distinction rather than the value.
    static func divisibleSummaryText(task: TaskItem) -> String {
        guard task.divisiblePicked else { return "Not selected" }
        guard task.minimumSegmentMinutes > 0 else { return "Not Divisible" }
        return TaskItem.durationLabel(for: task.minimumSegmentMinutes)
    }

    private var divisibleSummaryText: String {
        Self.divisibleSummaryText(task: task)
    }

    /// "High"/"Low"/"Not selected" — mirrors `highPriorityAnswer`'s own
    /// `get` exactly (`.unset` → nil/"Not selected", `.high` → "High",
    /// `.low`/`.medium` → "Low") rather than calling it directly, since
    /// that binding is instance-only and this needs to be a `static func`
    /// for the same direct-testability reasoning as `dueSummaryText`. The
    /// underlying model is still the same four-case `Priority` enum
    /// (`.unset`/`.low`/`.medium`/`.high`) — this row doesn't change
    /// that, only how it's displayed and edited. `.medium` reads
    /// identically to `.low` here, exactly like today's Yes/No toggle
    /// already treats them — legacy/AI-ranked data can still hold
    /// `.medium`, it's just never reachable or distinguishable from this
    /// control, unchanged from before this row existed.
    static func prioritySummaryText(task: TaskItem) -> String {
        switch task.priority {
        case .unset: return "Not selected"
        case .high: return "High"
        case .low, .medium: return "Low"
        }
    }

    private var prioritySummaryText: String {
        Self.prioritySummaryText(task: task)
    }

    /// Every + (when the unit is months) "On the" — no mode toggle. The
    /// old Specific-Date-vs-Relative-Date split only ever meant something
    /// for a monthly pattern ("Relative Date" was never offered, or
    /// useful, for days/weeks at all — see `RelativeRecurrenceScope`'s
    /// own doc comment); everywhere else it was just noise, one extra
    /// control answering a question the unit picker already answers.
    /// `recurrenceMode` itself is unchanged and still stored — still
    /// exactly the field `TaskItem.hasRecurringOccurrence` dispatches on
    /// (that evaluator dispatch is explicitly out of scope for this
    /// change) — it's just no longer its own direct control. Selecting
    /// "Same day," "First day," "Last day," or a weekday below sets it as
    /// a side effect (see each option's own `static func`), the same way
    /// choosing "Weekday of month" already implied `.relativeDate` before
    /// this redesign, just now covering the "Same day" case too (which
    /// implies `.specificDate`, reusing that evaluator branch instead of
    /// teaching the Relative Date one a new case for it).
    ///
    /// Every control here uses `PickedMenuPicker`, not `Picker(selection:)`
    /// — see that type's own doc comment for why: a native `Picker` only
    /// fires on a genuine value change, so re-confirming a value that's
    /// already the stored default would silently never mark it picked.
    @ViewBuilder
    private var repeatsExpandedContent: some View {
        HStack(spacing: 8) {
            Text("Every")
                .font(.body)
                .lineLimit(1)
                .fixedSize()
            Spacer()
            Stepper(
                value: Binding(
                    get: { task.recurrenceIntervalCount },
                    set: { newValue in
                        task.recurrenceIntervalCount = max(1, newValue)
                        task.recurrenceIntervalPicked = true
                    }
                ),
                in: 1...365
            ) {
                Text("\(task.recurrenceIntervalCount)")
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 20)
            }
            .fixedSize()

            PickedMenuPicker(
                options: RecurrenceUnit.allCases,
                label: { $0.label(for: task.recurrenceIntervalCount).capitalized },
                selection: task.recurrenceUnit
            ) { newUnit in
                Self.selectRecurrenceUnit(newUnit, on: task)
                if isRepeatsConfigured { expandedRows.remove(.repeats) }
            }
            .fixedSize()
        }

        if task.recurrenceUnit == .months {
            // Same "wraps at the widest value" treatment as
            // `CollapsibleAnswerRow` — see that type's own doc comment.
            // This was tightened twice on this exact row before it
            // actually fit on-device (first the row label, "Scope" →
            // "Pattern"; then the picker's own values, "Weekday of
            // month" → "Weekday"), so "On the"/"Day"/"Position"/"Weekday"
            // all keep the belt-and-braces protection even though none
            // of their current values ("Weekday of month," "Wednesday")
            // are any longer than what already measured as fitting.
            HStack {
                Text("On the")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer()
                PickedMenuPicker(
                    options: RelativeRecurrenceScope.allCases,
                    label: { $0.label },
                    selection: task.relativeRecurrenceScope
                ) { newScope in
                    // No self-collapse check here — `relativeRecurrenceMissing`
                    // is a single flag (`relativeRecurrencePicked`, set by
                    // this call) that doesn't distinguish "just chose a
                    // scope" from "also confirmed Day/Position/Weekday,"
                    // so `isRepeatsConfigured` would already read true the
                    // instant this fires — before Day (or Position/
                    // Weekday) has even had a chance to render, let alone
                    // be looked at. Whichever of those renders next is
                    // this row's real last control; the check belongs
                    // there instead.
                    Self.selectMonthlyScope(newScope, on: task)
                }
            }

            if task.relativeRecurrenceScope == .dayOfMonth {
                HStack {
                    Text("Day")
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer()
                    PickedMenuPicker(
                        options: DayOfMonthPosition.allCases,
                        label: { $0.label },
                        selection: Self.dayOfMonthPosition(for: task)
                    ) { newPosition in
                        Self.selectDayOfMonthPosition(newPosition, on: task)
                        if isRepeatsConfigured { expandedRows.remove(.repeats) }
                    }
                }
            } else {
                HStack {
                    Text("Position")
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer()
                    PickedMenuPicker(
                        options: RelativeRecurrenceOrdinal.allCases,
                        label: { $0.label },
                        selection: task.relativeRecurrenceOrdinal
                    ) { newOrdinal in
                        // No self-collapse check — same reasoning as "On
                        // the" above: `isRepeatsConfigured` is already
                        // true the instant a scope was picked, so
                        // checking here would collapse the row before
                        // "Weekday" (rendered right below, still in this
                        // same branch) is ever seen. That control is this
                        // row's real last one.
                        Self.selectRelativeOrdinal(newOrdinal, on: task)
                    }
                }

                HStack {
                    Text("Weekday")
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer()
                    PickedMenuPicker(
                        options: Array(1...7),
                        label: { Calendar.current.weekdaySymbols[$0 - 1] },
                        selection: task.relativeRecurrenceWeekday ?? 1
                    ) { newWeekday in
                        Self.selectRelativeWeekday(newWeekday, on: task)
                        if isRepeatsConfigured { expandedRows.remove(.repeats) }
                    }
                }
            }
        }
    }

    /// `StartDateCalendarPicker` embedded directly rather than behind its
    /// own further popover tap — expanding "Starts" should reveal the
    /// real control immediately, not gate it behind one more reveal.
    /// Picking a date auto-collapses the row (`expandedRows.remove(.canStartBy)`)
    /// — a calendar tap is a discrete, one-shot "I'm done" action, unlike
    /// the Stepper/wheel controls in the other rows, which stay open
    /// through an exploratory adjustment instead of snapping shut after
    /// the first touch.
    @ViewBuilder
    private var startsExpandedContent: some View {
        StartDateCalendarPicker(
            initialSelection: task.startDatePicked ? task.startDate : nil,
            minimumDate: nil
        ) { selectedDate in
            task.setStartDate(selectedDate)
            expandedRows.remove(.canStartBy)
        }

        if task.startDatePicked {
            Button("Clear", role: .destructive) {
                task.clearStartDate()
            }
        }
    }

    /// The "Starts" row itself — shared verbatim by the recurring card
    /// (`recurringSection`) and the non-recurring card (`cardScrollBody`),
    /// since `task.startDate`/`.setStartDate(_:)`/`.clearStartDate()` are
    /// the same field either way, just optional metadata for a
    /// non-recurring task rather than its scheduling anchor. That
    /// difference already falls out of the model for free: `startDateMissing`
    /// only ever applies `isRecurring && ...`, so `isStartsExpanded`'s
    /// auto-expand-if-unconfigured seeding (`init`) naturally never
    /// triggers for a non-recurring task's blank Start Date — an unset
    /// one is a legitimate, complete answer there, not something to chase
    /// the user into filling — with no `isRecurring` branch needed here.
    @ViewBuilder
    private var startsRow: some View {
        CollapsibleAnswerRow(
            label: "Can Start By",
            summary: startsSummaryText,
            isNotSelected: !task.startDatePicked,
            isExpanded: isStartsExpanded,
            onTapHeader: { focusedField = nil }
        ) {
            startsExpandedContent
        }
    }

    /// The non-recurring card's own "Due" row — replaces the old always-
    /// visible "Has due date" `YesNoToggle` plus its separate popover-
    /// triggering button with one row that only reveals them on expand.
    /// `YesNoToggle` itself is reused unchanged (not reinvented) precisely
    /// because it's already the thing that preserves the three-state
    /// distinction this collapse could have lost — tapping the already-
    /// selected pill still answers back to "undecided" exactly as it did
    /// before this was a collapsible row, and `dueDateAnswer`'s own
    /// `Binding` (unchanged) is still the single place that writes
    /// `dueDateDecided`/`dueDate`/`dueDatePicked` together. `Calendar`
    /// picking still floors at today, same as before this row existed —
    /// unlike Start Date (see `StartDateCalendarPicker`'s own doc
    /// comment), nothing about this request asked Due Date to become
    /// backdatable too.
    @ViewBuilder
    private var dueExpandedContent: some View {
        YesNoToggle(title: "Has due date", answer: dueDatesAllowed ? dueDateAnswer : .constant(false))
            .disabled(!dueDatesAllowed)
            .opacity(dueDatesAllowed ? 1 : 0.4)
            .animation(.easeInOut(duration: 0.15), value: task.dueDateDecided)
            .animation(.easeInOut(duration: 0.15), value: dueDatesAllowed)

        if dueDatesAllowed, dueDateAnswer.wrappedValue == true {
            StartDateCalendarPicker(
                initialSelection: task.dueDatePicked ? task.dueDate : nil,
                minimumDate: Calendar.current.startOfDay(for: .now)
            ) { selectedDate in
                task.dueDatePicked = true
                task.dueDate = selectedDate
                expandedRows.remove(.due)
            }
        }
    }

    /// The non-recurring card's own "Priority" row — `YesNoToggle`
    /// unchanged, same reasoning as `dueExpandedContent`: reusing it
    /// keeps `highPriorityAnswer`'s existing tri-state behavior (untap to
    /// go back to unset) rather than rebuilding it.
    @ViewBuilder
    private var priorityExpandedContent: some View {
        YesNoToggle(title: "High Priority?", answer: priorityAllowed ? highPriorityAnswer : .constant(false))
            .disabled(!priorityAllowed)
            .opacity(priorityAllowed ? 1 : 0.4)
            .animation(.easeInOut(duration: 0.15), value: priorityAllowed)
    }

    /// Mode picker, then — for Specific Time only — the clock wheel,
    /// Duration, and Divisible together, exactly the set requirement 2
    /// asks to fold into this row. `durationControl`/`divisibleControl`
    /// are the identical extracted content `nonRecurringTimeExpandedContent`
    /// shows for a non-recurring task's own "Time" row — no second copy
    /// of that Yes/No-pill-plus-wheel logic. Divisible is wrapped in
    /// its own condition here (unlike the standalone version, which
    /// always renders disabled+explained) so it doesn't appear at all
    /// until there's an actual duration long enough to split — the same
    /// `segmentOptions`/`TaskItem.validSegmentOptions(for:)` check that
    /// already decides whether the Divisible *control* accepts "Yes" is
    /// what decides whether the *row* shows up here at all.
    @ViewBuilder
    private var timeExpandedContent: some View {
        HStack {
            Text("Mode")
            Spacer()
            // `PickedMenuPicker`, not `Picker(selection:)` — see that
            // type's own doc comment: re-confirming "Specific Time"
            // while it's already the selection (`recurrenceTimeMode`'s
            // own stored default) would otherwise never fire, leaving
            // `recurrenceTimeModePicked` stuck false.
            PickedMenuPicker(
                // Not `allCases` — a recurring task can't be Specific Time.
                // Habits still offer all four.
                options: HabitOccurrenceTimeMode.taskSelectableCases,
                label: { $0.label },
                selection: task.recurrenceTimeMode
            ) { newMode in
                Self.selectRecurrenceTimeMode(newMode, on: task)
                if isTimeConfigured { expandedRows.remove(.timeMode) }
            }
        }

    }

    @ViewBuilder
    private var endsExpandedContent: some View {
        Toggle("Ends on a date", isOn: Binding(
            get: { task.recurrenceEndDate != nil },
            set: { newValue in
                task.recurrenceEndDate = newValue
                    ? (task.recurrenceEndDate ?? Calendar.current.date(byAdding: .month, value: 1, to: task.dueDate ?? .now))
                    : nil
            }
        ))

        if task.recurrenceEndDate != nil {
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
        }
    }

    /// Replaces the normal Yes/No Due Date section whenever the top-level
    /// "Recurring?" toggle is on — there's no separate "Has due date"
    /// question, a recurring task always has one, by definition. No date
    /// question here either: Start Date doubles as the anchor every
    /// occurrence steps forward from (`task.dueDate`, kept in sync with
    /// `task.startDate` — see `TaskItem.setStartDate(_:)`), so there's
    /// nothing left for this section to ask beyond Repeats/Time/Ends.
    ///
    /// Each row shows its answer, not its controls — the organizing
    /// principle behind this whole layout: a recurring task is
    /// configured once and read many times, so the default (compact,
    /// collapsed) view should optimize for reading, not editing.
    /// `CollapsibleAnswerRow` is the shared shape all four rows use;
    /// `isRepeatsExpanded`/`isStartsExpanded`/`isTimeExpanded` start
    /// collapsed unless that row is unconfigured (seeded in `init`,
    /// since expand state is session-local — never persisted, and never
    /// re-evaluated after the card opens); `isEndsExpanded` always starts
    /// collapsed, since "Never" is itself a complete answer.
    private var recurringSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if task.isRecurring {
                CollapsibleAnswerRow(
                    label: "Repeats",
                    summary: repeatsSummaryText,
                    isNotSelected: !isRepeatsConfigured,
                    isExpanded: isRepeatsExpanded,
                    onTapHeader: { focusedField = nil }
                ) {
                    repeatsExpandedContent
                }

                startsRow

                CollapsibleAnswerRow(
                    label: "Time",
                    summary: timeSummaryText,
                    isNotSelected: !task.recurrenceTimeModePicked,
                    isExpanded: isTimeExpanded,
                    onTapHeader: { focusedField = nil }
                ) {
                    timeExpandedContent
                }

                // Hidden entirely for AM/Midday/PM — an untimed recurring
                // occurrence never gets a calendar block, so it has no
                // duration to state and nothing to split. See
                // `showsDurationRow`. This gate is what was lost when
                // these two moved out of the "Time" row.
                if showsDurationRow {
                    CollapsibleAnswerRow(
                        label: "Duration",
                        summary: durationSummaryText,
                        isNotSelected: !isDurationConfigured,
                        isExpanded: isDurationExpanded,
                        onTapHeader: { focusedField = nil }
                    ) {
                        durationControl
                    }
                }

                // Additionally requires a duration long enough to split
                // that something evenly divides — see `showsDivisibleRow`.
                // Dynamic: changing the Duration wheel adds or removes
                // this row immediately, since it reads
                // `task.estimatedMinutes` on every body pass.
                if showsDivisibleRow {
                    CollapsibleAnswerRow(
                        label: "Divisible",
                        summary: divisibleSummaryText,
                        isNotSelected: !isDivisibleConfigured,
                        isExpanded: isDivisibleExpanded,
                        onTapHeader: { focusedField = nil }
                    ) {
                        divisibleControl
                    }
                }

                CollapsibleAnswerRow(
                    label: "Ends",
                    summary: endsSummaryText,
                    isNotSelected: false,
                    isExpanded: isEndsExpanded,
                    onTapHeader: { focusedField = nil }
                ) {
                    endsExpandedContent
                }

                // Default true — matches every recurring task's behavior
                // before this existed. Turning it off doesn't change
                // anything about a *missed* day itself (still logged
                // `.missed`, same as always); it only stops
                // `PushedRecurringOccurrence` from carrying that miss
                // forward onto future days — see `TaskItem.isPushable`'s
                // own doc comment. Renamed from "Pushable?" — same field,
                // clearer wording.
                Toggle("Push if missed", isOn: $task.isPushable)
                    .padding(.top, 4)
            }
        }
    }


    /// Everything past Next step — due date through Eligible Schedules —
    /// in its own scroll region so a task with a lot filled in never pushes
    /// the header or the action row off-screen.
    private var cardScrollBody: some View {
        ScrollViewReader { scrollProxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
            Divider()

            if CardRow.nextStep.visibility(task: task, shelf: previewedShelf) != .hidden {
                CollapsibleAnswerRow(
                    label: "Next Step",
                    summary: nextStepSummaryText,
                    isNotSelected: !isNextStepConfigured,
                    isExpanded: isNextStepExpanded,
                    onTapHeader: { focusedField = nil }
                ) {
                    nextStepExpandedContent
                }
            }

            if CardRow.recurringToggle.visibility(task: task, shelf: previewedShelf) != .hidden {
                Toggle("Recurring?", isOn: Binding(
                    get: { task.isRecurring },
                    set: { newValue in
                        shelfPreview = Self.applyRecurringToggle(
                            newValue, task: task, shelves: shelves, preview: shelfPreview
                        )
                    }
                ))
                .animation(.easeInOut(duration: 0.15), value: task.isRecurring)
            }

            if task.isRecurring {
                recurringSection
            } else {
                // Same "answer, not controls" shape as `recurringSection`
                // — see this whole section's own header comment. "Due"
                // replaces "Has due date" (Yes/No) plus its separate
                // popover button; "Time" replaces the standalone
                // Duration/Divisible pair; "Priority" replaces "High
                // Priority?" (Yes/No). Hidden entirely (not just greyed)
                // for a recurring task, same as before this was rows —
                // High Priority isn't offered to a repeating task at all
                // (see `TaskItem.priorityMissing`'s matching short-circuit),
                // so the whole `else` branch, Priority included, simply
                // doesn't render rather than needing its own disabled
                // state.
                VStack(alignment: .leading, spacing: 14) {
                    // Gated on `CardRow`, like Tags and the Recurring
                    // toggle above. It was drawn unconditionally before,
                    // which meant `CardRow.due`'s rule — and therefore the
                    // shelf's own Due toggle — had no effect on whether the
                    // row appeared at all. That is precisely the
                    // rule-vs-render drift `CardRow` was created to end, and
                    // it survived here because the row's *missing-check*
                    // consulted `CardRow` while its rendering didn't.
                    if CardRow.due.visibility(task: task, shelf: previewedShelf) != .hidden {
                        CollapsibleAnswerRow(
                            label: "Due",
                            summary: dueSummaryText,
                            isNotSelected: !isDueConfigured,
                            isExpanded: isDueExpanded,
                            onTapHeader: { focusedField = nil }
                        ) {
                            dueExpandedContent
                        }
                    }

                    startsRow

                    // Same `CardRow` gate as Due above, and same reason.
                    // Unlike
                    // Duration and Divisible are their own rows now
                    // rather than folded into a "Time" row — that row
                    // held nothing else for a non-recurring task, so
                    // flattening consumed it. Duration is never hidden
                    // outright for any shelf (see
                    // `Shelf.effectiveTracksDuration`); Divisible hides
                    // by duration and Priority by shelf.

                    if CardRow.duration.visibility(task: task, shelf: previewedShelf) != .hidden {
                        CollapsibleAnswerRow(
                            label: "Duration",
                            summary: durationSummaryText,
                            isNotSelected: !isDurationConfigured,
                            isExpanded: isDurationExpanded,
                            onTapHeader: { focusedField = nil }
                        ) {
                            durationControl
                        }
                    }

                    // Only when the duration is long enough to split and something
                    // evenly divides it — see `showsDivisibleRow`. Dynamic: changing
                    // the Duration wheel adds or removes this row immediately, since
                    // it reads `task.estimatedMinutes` on every body pass.
                    if showsDivisibleRow {
                        CollapsibleAnswerRow(
                            label: "Divisible",
                            summary: divisibleSummaryText,
                            isNotSelected: !isDivisibleConfigured,
                            isExpanded: isDivisibleExpanded,
                            onTapHeader: { focusedField = nil }
                        ) {
                            divisibleControl
                        }
                    }

                    // Same treatment, same reasoning as recurring's own
                    // whole-branch Priority omission just above — 2-Minute
                    // Tasks is a shelf property rather than a task one,
                    // so it's expressed here via `priorityAllowed`
                    // instead of a task-level branch.
                    if priorityAllowed {
                        CollapsibleAnswerRow(
                            label: "Priority",
                            summary: prioritySummaryText,
                            isNotSelected: !isPriorityConfigured,
                            isExpanded: isPriorityExpanded,
                            onTapHeader: { focusedField = nil }
                        ) {
                            priorityExpandedContent
                        }
                    }
                }
            }

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

            // Grouped under one stable id (rather than tagging the
            // suggestions row itself, which only exists conditionally) so
            // `scrollTo("tagSection")` always has something to target —
            // see the `.onChange`s below, which keep this scrolled into
            // view as you type so the pre-populating suggestion chips
            // don't end up hidden below the fold or the keyboard.
            // Hidden outright for a recurring or 2-Minute task — see
            // `CardRow.tags`. A real conditional rather than zero-height
            // styling, so the row leaves the hierarchy and takes its
            // stack spacing with it.
            if CardRow.tags.visibility(task: task, shelf: previewedShelf) != .hidden {
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
            }

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
            // Next Step used to live in the *fixed* header, so focusing it
            // could never scroll it away. It is an ordinary scrolling row
            // now, which reintroduces the problem the tag field already
            // solved: the keyboard covers the bottom of the card, and a
            // field near it ends up typed into blind. Same fix, same
            // anchor — `.bottom` keeps the field just above the keyboard
            // rather than jumping it to the top of the viewport.
            if newValue == .nextStep {
                withAnimation { scrollProxy.scrollTo("nextStepSection", anchor: .bottom) }
            }
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
        let isMoving = shelfPreview.explicitShelf != nil && shelfPreview.explicitShelf?.id != task.shelf?.id
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
        if let previewed = shelfPreview.explicitShelf, previewed.id != task.shelf?.id {
            onMove(previewed)
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
        if task.durationPicked, task.estimatedMinutes > 0, task.estimatedMinutes <= 2 {
            return shelves.filter { $0.isTwoMinuteTasks }
        }
        return shelves.filter { !$0.isTwoMinuteTasks && !$0.isRecurringTasks }
    }

    /// A wrapping grid rather than a horizontal scroll — every shelf is
    /// visible up front instead of some sitting off-screen to the side,
    /// and `.adaptive` columns keep every icon the same evenly-spaced
    /// width whether there's one row or several.
    private var shelfRow: some View {
        VStack(alignment: .leading, spacing: 8) {
        if let prompt = shelfPreview.shelfChoicePrompt {
            // Only while a choice is actually owed, and worded by reason
            // (see `ShelfPreview.shelfChoicePrompt`) so this reads as a
            // question rather than as the generic "Remaining Attributes:
            // Shelf" the action button already shows.
            Text(prompt)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 16)], alignment: .center, spacing: 12) {
                ForEach(eligibleShelvesForMove) { shelf in
                    let isCurrent = task.shelf?.id == shelf.id
                    let isSelected = shelfPreview.explicitShelf?.id == shelf.id
                    Button {
                        focusedField = nil
                        withAnimation(.easeInOut(duration: 0.15)) {
                            // Tapping the already-selected shelf (or the
                            // current one) clears the pick — just previews,
                            // never moves on its own. Next/Skip is what
                            // actually commits it.
                            if isSelected || isCurrent {
                                shelfPreview = .none
                            } else {
                                shelfPreview = .shelf(shelf)
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
        var missing = task.missingAttributeNames(consideringShelf: previewedShelf)
        // Turning 2-Minute off on a task that lives on that shelf leaves
        // it with nowhere to go — committing as-is would silently keep it
        // there and flip the toggle back on next open. Surfaced as a
        // remaining attribute so the card asks rather than guesses.
        //
        // View-level only, deliberately not in
        // `TaskItem.missingAttributeNames`: it's a transient state of
        // *this editing session*, not a property of the task, and putting
        // it in the model would leak into the Nightly Review gate and the
        // Inbox filter for a task that is perfectly well-formed on disk.
        if shelfPreview.needsShelfChoice { missing.append("Shelf") }
        let isComplete = missing.isEmpty
        let isMoving = shelfPreview.explicitShelf != nil && shelfPreview.explicitShelf?.id != task.shelf?.id
        let remainingText = "Remaining Attributes: \(missing.joined(separator: ", "))"
        if isComplete {
            return isMoving
                ? ("Save, Move & Submit", nil, "arrow.right.circle.fill", shelfPreview.explicitShelf!.color)
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

/// One shared control for every menu-style field on the recurring card
/// that also has to mark a "picked" flag the instant it's touched — not
/// gated on the underlying value actually changing. SwiftUI's
/// `Picker(selection:)` only invokes its `Binding`'s `set` on a genuine
/// value change — the same defect class `StartDateCalendarPicker`'s own
/// doc comment describes for `DatePicker` — so re-choosing the option
/// already showing is silently a no-op there: "Repeats" could sit on
/// "Not Selected" forever if the value the user actually wants happens
/// to already be the stored default (e.g. "Days," "Specific Time,"
/// "First"), because tapping it again never fires anything.
///
/// Built from `Menu` + `Button` instead of `Picker` specifically because
/// a `Button`'s `action` always runs on tap — there's nothing to diff,
/// nothing to suppress. One shared shape rather than five near-identical
/// ad-hoc fixes (recurrenceIntervalPicked, recurrenceTimeModePicked, and
/// the relative scope/day-position/ordinal/weekday equivalents, with more
/// likely to accumulate) — every call site's `onSelect` pairs with a
/// small `static func` (e.g. `TaskReviewCard.selectRecurrenceUnit`) that
/// sets the field and its "picked" flag together, unconditionally.
///
/// The value column is also fixed to its widest option's width, so
/// switching selections never visibly resizes it — a "Day of month" →
/// "Day of Week" tap used to make the column jump as the picker's own
/// intrinsic width re-fit to the new string. `measuredWidth` is read
/// from a hidden stack rendering every option at the *same* font this
/// row actually uses (whatever the environment supplies — no font is
/// hardcoded here), via `.background`/`GeometryReader`/`PreferenceKey` —
/// real SwiftUI layout measurement, not a guessed char-count × point-
/// size, so it stays correct across Dynamic Type sizes and any future
/// font change without needing to be re-tuned by hand.
private struct PickedMenuPickerOptionWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct PickedMenuPicker<Option: Hashable>: View {
    let options: [Option]
    let label: (Option) -> String
    let selection: Option
    let onSelect: (Option) -> Void

    @State private var measuredWidth: CGFloat?

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    onSelect(option)
                } label: {
                    if option == selection {
                        Label(label(option), systemImage: "checkmark")
                    } else {
                        Text(label(option))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(label(selection))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: measuredWidth, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Color.accentColor)
        }
        .background(
            ZStack {
                ForEach(options, id: \.self) { option in
                    Text(label(option))
                        .lineLimit(1)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: PickedMenuPickerOptionWidthKey.self, value: geometry.size.width)
                        })
                }
            }
            .hidden()
        )
        .onPreferenceChange(PickedMenuPickerOptionWidthKey.self) { measuredWidth = $0 }
    }
}

/// One row in the compact recurring-task card (`TaskReviewCard
/// .recurringSection`): a label, its composed answer (or "Not Selected"
/// in muted/italic styling when unconfigured), and a chevron — tapping
/// the row expands/collapses `content` inline beneath it. The shared
/// shape behind "Repeats"/"Starts"/"Time"/"Ends" so all four behave
/// identically rather than each row inventing its own reveal mechanics.
/// `onTapHeader` is a small escape hatch for side effects the tap itself
/// should also trigger (`TaskReviewCard` uses it to dismiss the keyboard,
/// same as every other tap target on this card already does) — separate
/// from `isExpanded`'s own toggle so callers with nothing extra to do
/// can just omit it.
///
/// **Belt and braces against wrapping**, on top of every caller already
/// keeping `summary` itself short (`TaskItem.recurrenceShortSummary`, the
/// abbreviated date form, etc.): `label` is `.fixedSize(horizontal:
/// vertical:)` so it always renders at its natural width and never
/// compresses to make room for `summary`, and `summary` gets
/// `.lineLimit(1)` + `.truncationMode(.tail)` so if some future value is
/// ever longer than expected despite that, it ellipsizes instead of
/// wrapping. A clipped value is recoverable — tap the row, the real
/// control underneath still shows the full thing — a wrapped one breaks
/// the row's height and the whole card's rhythm with it.
private struct CollapsibleAnswerRow<Content: View>: View {
    let label: String
    let summary: String
    let isNotSelected: Bool
    @Binding var isExpanded: Bool
    var onTapHeader: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                onTapHeader?()
                isExpanded.toggle()
            } label: {
                HStack {
                    Text(label)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 8)
                    Text(summary)
                        .foregroundStyle(isNotSelected ? .secondary : .primary)
                        .italic(isNotSelected)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content()
                    .padding(.leading, 4)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isExpanded)
    }
}

/// A `UICalendarView` with `UICalendarSelectionSingleDate` rather than
/// SwiftUI's own `DatePicker(.graphical)` — the Start Date popover needs
/// a genuine "nothing selected" state, which a `DatePicker` structurally
/// can't express (it binds to a non-optional `Date`, so it always
/// highlights *something*), and needs every tap to register immediately,
/// including a tap on the day that's already highlighted — which a
/// `DatePicker`'s selection `Binding` won't do, since it only calls its
/// `set` closure on an actual value change. `UICalendarSelectionSingleDate`
/// has neither limitation: `selectedDate` is a genuine `DateComponents?`
/// (`setSelected(nil, animated:)` shows no highlight at all, not a fake
/// stand-in value), and `UICalendarSelectionSingleDateDelegate
/// .dateSelection(_:didSelectDate:)` fires on every discrete tap
/// regardless of prior selection — it's an event callback, not a diffed
/// binding, so re-tapping the same date still fires.
private struct StartDateCalendarPicker: UIViewRepresentable {
    /// nil shows no date highlighted at all — the caller passes this only
    /// when the task's Start Date has actually been picked before (see
    /// `TaskItem.startDatePicked`), never `.now` as a stand-in.
    let initialSelection: Date?
    /// `nil` leaves the calendar fully open in both directions — Start
    /// Date is a backdatable field (a task can start "3 days ago" for a
    /// habit or chore that was already underway before it was entered),
    /// so neither call site passes a lower bound.
    let minimumDate: Date?
    let onSelect: (Date) -> Void

    func makeUIView(context: Context) -> UICalendarView {
        let calendarView = UICalendarView()
        calendarView.calendar = Calendar.current
        calendarView.availableDateRange = DateInterval(start: minimumDate ?? .distantPast, end: .distantFuture)
        let selection = UICalendarSelectionSingleDate(delegate: context.coordinator)
        // `setSelected` only sets state — unlike a real tap, it never
        // invokes the delegate — so seeding an existing Start Date here
        // can't itself trigger `onSelect` and write anything back.
        if let initialSelection {
            selection.setSelected(
                Calendar.current.dateComponents([.year, .month, .day], from: initialSelection),
                animated: false
            )
        }
        calendarView.selectionBehavior = selection
        return calendarView
    }

    // Selection state lives inside the `UICalendarView`/coordinator once
    // created, not re-driven from SwiftUI on every re-render — the
    // popover's content is only built while it's presented, so a fresh
    // `makeUIView` call (with the then-current `initialSelection`) is
    // exactly what happens each time it opens anyway.
    func updateUIView(_ uiView: UICalendarView, context: Context) {}

    // Reports `UICalendarView`'s own real content size back to SwiftUI
    // instead of forcing a guessed `.frame(height:)` — measured, this is
    // a *constant* height regardless of which month is showing (a 6-row
    // month like August 2026 and a 5-row month like February 2026 both
    // measure identically), since `UICalendarView` already reserves
    // max-row space internally to avoid resizing as someone pages
    // between months. A hardcoded height either clips a 6-row month or
    // leaves dead space under a 5-row one; querying the real value here
    // gets both a correct fit *and* "every month renders identically"
    // for free, and keeps adapting correctly if Dynamic Type changes the
    // row height later.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UICalendarView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width
        return uiView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    final class Coordinator: NSObject, UICalendarSelectionSingleDateDelegate {
        let onSelect: (Date) -> Void

        init(onSelect: @escaping (Date) -> Void) {
            self.onSelect = onSelect
        }

        func dateSelection(_ selection: UICalendarSelectionSingleDate, didSelectDate dateComponents: DateComponents?) {
            guard let dateComponents, let date = Calendar.current.date(from: dateComponents) else { return }
            onSelect(date)
        }
    }
}

#Preview {
    NightlyReviewView()
        .modelContainer(for: [TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self, Habit.self, HabitLog.self], inMemory: true)
}
