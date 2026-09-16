import SwiftUI
import SwiftData

/// Presents a single task's Tinder card — the same `TaskReviewCard` used by
/// the Attribute Review flows (see NightlyReviewView.swift) — outside of
/// any review queue. Reached by tapping a task in its shelf list. Every
/// edit writes straight onto `task` live via its `@Bindable` binding the
/// moment it's made, so Cancel has to actively roll those edits back
/// (see `TaskEditSnapshot`) rather than just dismissing — moving or
/// discarding are the only two actions that are meant to stick.
struct TaskCardSheet: View {
    @Bindable var task: TaskItem
    let shelves: [Shelf]
    /// True only when the caller just created `task` and is presenting
    /// its card for the first time in the same gesture (today, only
    /// `ShelfListView`'s plus button — see its own `PresentedTask`
    /// wrapper for how this stays tied to *this* presentation and can
    /// never leak into a later one). Changes what Cancel does — see
    /// `cancel()` — rather than a new field on `TaskItem` itself: the
    /// model has no reliable "never saved" state to read (a task is
    /// inserted into the context at creation, before this card ever
    /// opens, so there's nothing to detect from the model alone), and a
    /// transient property stored *on* `TaskItem` would need to be
    /// reliably reset on every save path and would persist across
    /// however many times that object gets reused, both directly
    /// exposing this to going stale. A plain caller-supplied flag has
    /// neither problem: it only ever exists for the one presentation the
    /// caller explicitly marked, and reopening the same (now-saved) task
    /// later is a *different* presentation, built fresh, that this
    /// caller never marks — so "was this saved once" doesn't need to be
    /// tracked or flipped anywhere; it falls out of which code path
    /// presented the card at all.
    var isNewlyCreated: Bool = false
    /// Called (in addition to the normal dismiss) when Cancel is tapped —
    /// lets a queue-driven caller like TaskAttributeReviewView tell Cancel
    /// apart from Mark Complete/Move/Discard, all of which should still
    /// just advance to the next task.
    var onCancel: (() -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: TaskEditSnapshot?

    var body: some View {
        NavigationStack {
            TaskReviewCard(
                task: task,
                shelves: shelves,
                onDiscard: {
                    modelContext.delete(task)
                    dismiss()
                },
                onSkip: { dismiss() },
                onMove: { shelf in
                    task.shelf = shelf
                    task.estimatedMinutes = shelf.resolvedDuration(candidateMinutes: task.estimatedMinutes)
                    // Set explicitly rather than relying on `TaskReviewCard`'s
                    // own `.onChange(of: task.estimatedMinutes)` — that's
                    // reliable in practice, but this closure calls `dismiss()`
                    // on the very next line, and a duration reset that only
                    // sometimes lands depending on view-teardown timing isn't
                    // worth the risk when setting it directly costs nothing.
                    task.remainingMinutes = task.estimatedMinutes
                    if !shelf.effectiveTracksDuration {
                        task.isDivisible = false
                        task.minimumSegmentMinutes = 0
                    }
                    // The duration just changed via `resolvedDuration`, which
                    // can invalidate a segment size chosen against the old
                    // one — re-validate rather than leaving the packer a
                    // remainder it can never place.
                    task.validateDivisibility()
                    if !shelf.effectiveTracksDueDates {
                        task.dueDate = nil
                    }
                    if !shelf.effectiveTracksNextStep {
                        task.nextStep = ""
                    }
                    if !shelf.effectiveTracksPriority {
                        task.priority = .unset
                    }
                    // Eligible Schedules is already seeded (all the
                    // shelf's enabled rules on by default) the moment this
                    // shelf was first previewed — see `shelfRow` — and any
                    // toggled off since then should stick, so this no
                    // longer re-seeds it here.
                    dismiss()
                },
                onNext: { dismiss() },
                onSnooze: { days in
                    if let days {
                        task.attributeReviewSnoozedUntil = Calendar.current.date(byAdding: .day, value: days, to: .now)
                    } else {
                        task.attributeReviewSnoozedUntil = nil
                    }
                },
                isNewlyCreated: isNewlyCreated
            )
            .padding(.top, 4)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(task.isCompleted ? "Completed" : "Mark Complete", action: toggleComplete)
                        .buttonStyle(.borderedProminent)
                        .tint(task.isCompleted ? .green : .accentColor)
                }
            }
            .onAppear {
                if snapshot == nil { snapshot = TaskEditSnapshot(task) }
            }
        }
    }

    /// A never-saved task (see `isNewlyCreated`'s own doc comment) is
    /// deleted outright instead of rolled back — otherwise Cancel leaves
    /// an empty shell sitting on the shelf, since the task was already
    /// inserted into the context the moment it was created, before this
    /// card ever opened. `TaskItem.deleteCascading` (not a plain
    /// `modelContext.delete(task)`) so a recurring task configured and
    /// then cancelled doesn't leave orphaned `ScheduledBlock`/
    /// `RecurringTaskLog`/`PushedRecurringOccurrence`/
    /// `TaskCompletionRecord` rows behind — and specifically *not*
    /// `snapshot?.restore(into:)` first: rolling back a value on an
    /// object that's about to be deleted from the context is pointless
    /// at best, and restoring `startDate`/`dueDate`/etc. can themselves
    /// re-trigger scheduling side effects (see `TaskItem.setStartDate`)
    /// that would just have to be torn down again a line later.
    ///
    /// The actual decision is pulled out as `static func cancel` (below)
    /// — taking `task`/`isNewlyCreated`/`snapshot`/`context` explicitly
    /// rather than reading `self.modelContext` — purely so a test can
    /// call it directly. `@Environment(\.modelContext)` only resolves to
    /// a real context inside a live view hierarchy; a bare
    /// `TaskCardSheet(...)` value constructed in a test has no such
    /// thing to read.
    private func cancel() {
        Self.cancel(task: task, isNewlyCreated: isNewlyCreated, snapshot: snapshot, in: modelContext)
        onCancel?()
        dismiss()
    }

    /// `internal`, not `private` — see `cancel()`'s own doc comment for
    /// why.
    static func cancel(task: TaskItem, isNewlyCreated: Bool, snapshot: TaskEditSnapshot?, in context: ModelContext) {
        if isNewlyCreated {
            TaskItem.deleteCascading(task, in: context)
        } else {
            snapshot?.restore(into: task)
        }
    }

    /// Tapping this on an already-completed task un-marks it instead —
    /// everywhere at once, since `TaskItem.setCompleted` clears every one
    /// of its scheduled blocks too, not just the task itself. Dismisses
    /// either way, same as before.
    private func toggleComplete() {
        task.setCompleted(!task.isCompleted, in: modelContext)
        ScheduleDirtyState.shared.isDirty = true
        dismiss()
    }
}

/// Everything editable live on a TaskReviewCard — captured the moment the
/// sheet appears so Cancel can put it all back, since edits otherwise
/// write straight through to the model as they're made. Shared with
/// `TaskReviewQueueSheet`, which needs the same rollback per card.
/// `Equatable` so `TaskReviewCard` can diff against the snapshot taken when
/// a card first appeared to tell "nothing touched yet" (Skip) apart from
/// "something's actually been edited" (Save Changes) — see
/// `TaskReviewCard.hasChanges`.
struct TaskEditSnapshot: Equatable {
    let title: String
    let nextStep: String
    let nextStepDecided: Bool
    let nextStepAnsweredYes: Bool
    let dueDate: Date?
    let dueDateDecided: Bool
    let dueDatePicked: Bool
    let priority: Priority
    let estimatedMinutes: Int
    let remainingMinutes: Int
    let durationPicked: Bool
    let isDivisible: Bool
    let minimumSegmentMinutes: Int
    let divisiblePicked: Bool
    let tags: [String]
    let includedSchedulingRuleIDs: [UUID]
    let attributeReviewSnoozedUntil: Date?
    let remindInCount: Int
    let remindInUnitRaw: String
    let isRecurring: Bool
    let recurrenceIntervalCount: Int
    let recurrenceUnitRaw: String
    let recurrenceIntervalPicked: Bool
    let recurrenceTimeModeRaw: String
    let recurrenceTimeModePicked: Bool
    let recurrenceTimeOfDayMinutes: Int?
    let recurrenceEndDate: Date?
    let isPushable: Bool
    let recurrenceModeRaw: String
    let relativeRecurrenceScopeRaw: String
    let relativeRecurrenceOrdinalRaw: Int
    let relativeRecurrenceWeekday: Int?
    let relativeRecurrencePicked: Bool
    let startDate: Date?
    let startDatePicked: Bool

    init(_ task: TaskItem) {
        title = task.title
        nextStep = task.nextStep
        nextStepDecided = task.nextStepDecided
        nextStepAnsweredYes = task.nextStepAnsweredYes
        dueDate = task.dueDate
        dueDateDecided = task.dueDateDecided
        dueDatePicked = task.dueDatePicked
        priority = task.priority
        estimatedMinutes = task.estimatedMinutes
        remainingMinutes = task.remainingMinutes
        durationPicked = task.durationPicked
        isDivisible = task.isDivisible
        minimumSegmentMinutes = task.minimumSegmentMinutes
        divisiblePicked = task.divisiblePicked
        tags = task.tags
        includedSchedulingRuleIDs = task.includedSchedulingRuleIDs
        attributeReviewSnoozedUntil = task.attributeReviewSnoozedUntil
        remindInCount = task.remindInCount
        remindInUnitRaw = task.remindInUnitRaw
        isRecurring = task.isRecurring
        recurrenceIntervalCount = task.recurrenceIntervalCount
        recurrenceUnitRaw = task.recurrenceUnitRaw
        recurrenceIntervalPicked = task.recurrenceIntervalPicked
        // `recurrenceTimeModeRaw` was missing from this snapshot before
        // now — a pre-existing gap (Cancel wouldn't roll back a Time-mode
        // change) noticed while adding `recurrenceTimeModePicked`, which
        // needs the same rollback treatment for the same reason.
        recurrenceTimeModeRaw = task.recurrenceTimeModeRaw
        recurrenceTimeModePicked = task.recurrenceTimeModePicked
        recurrenceTimeOfDayMinutes = task.recurrenceTimeOfDayMinutes
        recurrenceEndDate = task.recurrenceEndDate
        isPushable = task.isPushable
        recurrenceModeRaw = task.recurrenceModeRaw
        relativeRecurrenceScopeRaw = task.relativeRecurrenceScopeRaw
        relativeRecurrenceOrdinalRaw = task.relativeRecurrenceOrdinalRaw
        relativeRecurrenceWeekday = task.relativeRecurrenceWeekday
        relativeRecurrencePicked = task.relativeRecurrencePicked
        startDate = task.startDate
        startDatePicked = task.startDatePicked
    }

    func restore(into task: TaskItem) {
        task.title = title
        task.nextStep = nextStep
        task.nextStepDecided = nextStepDecided
        task.nextStepAnsweredYes = nextStepAnsweredYes
        task.dueDate = dueDate
        task.dueDateDecided = dueDateDecided
        task.dueDatePicked = dueDatePicked
        task.priority = priority
        task.estimatedMinutes = estimatedMinutes
        task.remainingMinutes = remainingMinutes
        task.durationPicked = durationPicked
        task.isDivisible = isDivisible
        task.minimumSegmentMinutes = minimumSegmentMinutes
        task.divisiblePicked = divisiblePicked
        task.validateDivisibility()
        task.tags = tags
        task.includedSchedulingRuleIDs = includedSchedulingRuleIDs
        task.attributeReviewSnoozedUntil = attributeReviewSnoozedUntil
        task.remindInCount = remindInCount
        task.remindInUnitRaw = remindInUnitRaw
        task.isRecurring = isRecurring
        task.recurrenceIntervalCount = recurrenceIntervalCount
        task.recurrenceUnitRaw = recurrenceUnitRaw
        task.recurrenceIntervalPicked = recurrenceIntervalPicked
        task.recurrenceTimeModeRaw = recurrenceTimeModeRaw
        task.recurrenceTimeModePicked = recurrenceTimeModePicked
        task.recurrenceTimeOfDayMinutes = recurrenceTimeOfDayMinutes
        task.recurrenceEndDate = recurrenceEndDate
        task.isPushable = isPushable
        task.recurrenceModeRaw = recurrenceModeRaw
        task.relativeRecurrenceScopeRaw = relativeRecurrenceScopeRaw
        task.relativeRecurrenceOrdinalRaw = relativeRecurrenceOrdinalRaw
        task.relativeRecurrenceWeekday = relativeRecurrenceWeekday
        task.relativeRecurrencePicked = relativeRecurrencePicked
        task.startDate = startDate
        task.startDatePicked = startDatePicked
        // A duration edit already live-resized any scheduled block behind
        // this task (see `TaskItem.syncScheduledBlockDuration`) — restoring
        // the old `estimatedMinutes` here without also re-syncing would
        // leave that block stretched to the now-discarded value.
        task.syncScheduledBlockDuration()
    }
}

#Preview {
    let shelf = Shelf(name: "To-Do List", systemImage: "checklist")
    return TaskCardSheet(task: TaskItem(title: "Sample task", shelf: shelf), shelves: [shelf])
        .modelContainer(for: [TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self, Habit.self, HabitLog.self], inMemory: true)
}
