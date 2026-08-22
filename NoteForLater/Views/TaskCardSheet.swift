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
                }
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

    private func cancel() {
        snapshot?.restore(into: task)
        onCancel?()
        dismiss()
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
    let dueDate: Date?
    let dueDateDecided: Bool
    let dueDatePicked: Bool
    let priority: Priority
    let estimatedMinutes: Int
    let remainingMinutes: Int
    let durationDecided: Bool
    let durationAnsweredYes: Bool
    let isDivisible: Bool
    let minimumSegmentMinutes: Int
    let isDivisibleDecided: Bool
    let tags: [String]
    let includedSchedulingRuleIDs: [UUID]
    let attributeReviewSnoozedUntil: Date?
    let remindInCount: Int
    let remindInUnitRaw: String
    let isRecurring: Bool
    let recurrenceIntervalCount: Int
    let recurrenceUnitRaw: String
    let recurrenceEndDate: Date?
    let startDate: Date?

    init(_ task: TaskItem) {
        title = task.title
        nextStep = task.nextStep
        dueDate = task.dueDate
        dueDateDecided = task.dueDateDecided
        dueDatePicked = task.dueDatePicked
        priority = task.priority
        estimatedMinutes = task.estimatedMinutes
        remainingMinutes = task.remainingMinutes
        durationDecided = task.durationDecided
        durationAnsweredYes = task.durationAnsweredYes
        isDivisible = task.isDivisible
        minimumSegmentMinutes = task.minimumSegmentMinutes
        isDivisibleDecided = task.isDivisibleDecided
        tags = task.tags
        includedSchedulingRuleIDs = task.includedSchedulingRuleIDs
        attributeReviewSnoozedUntil = task.attributeReviewSnoozedUntil
        remindInCount = task.remindInCount
        remindInUnitRaw = task.remindInUnitRaw
        isRecurring = task.isRecurring
        recurrenceIntervalCount = task.recurrenceIntervalCount
        recurrenceUnitRaw = task.recurrenceUnitRaw
        recurrenceEndDate = task.recurrenceEndDate
        startDate = task.startDate
    }

    func restore(into task: TaskItem) {
        task.title = title
        task.nextStep = nextStep
        task.dueDate = dueDate
        task.dueDateDecided = dueDateDecided
        task.dueDatePicked = dueDatePicked
        task.priority = priority
        task.estimatedMinutes = estimatedMinutes
        task.remainingMinutes = remainingMinutes
        task.durationDecided = durationDecided
        task.durationAnsweredYes = durationAnsweredYes
        task.isDivisible = isDivisible
        task.minimumSegmentMinutes = minimumSegmentMinutes
        task.isDivisibleDecided = isDivisibleDecided
        task.validateDivisibility()
        task.tags = tags
        task.includedSchedulingRuleIDs = includedSchedulingRuleIDs
        task.attributeReviewSnoozedUntil = attributeReviewSnoozedUntil
        task.remindInCount = remindInCount
        task.remindInUnitRaw = remindInUnitRaw
        task.isRecurring = isRecurring
        task.recurrenceIntervalCount = recurrenceIntervalCount
        task.recurrenceUnitRaw = recurrenceUnitRaw
        task.recurrenceEndDate = recurrenceEndDate
        task.startDate = startDate
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
