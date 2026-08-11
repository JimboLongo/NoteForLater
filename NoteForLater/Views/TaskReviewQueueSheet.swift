import SwiftUI
import SwiftData

/// Task Attribute Review's queue, presented as a single persistent modal —
/// unlike tapping one task (`TaskCardSheet`), advancing here swaps which
/// task `TaskReviewCard` shows in place rather than dismissing and
/// re-presenting a whole new sheet per task. That per-task re-presentation
/// is what made the next card pop up from the bottom (a fresh sheet's
/// default entrance) instead of continuing the Tinder motion, and
/// occasionally made it fail to appear at all. Here the finished card flies
/// off to the right exactly as before, then the next one slides in from the
/// left (see `TaskReviewCard.entersFromLeft`).
struct TaskReviewQueueSheet: View {
    let shelves: [Shelf]
    /// The queue as of when this sheet was asked to present — read only
    /// once, in `.onAppear` (see `hasStarted`). Seeding `@State` straight
    /// from `init` instead would bake in whatever this was at construction
    /// time, which can run before `InboxView` finishes populating it,
    /// making the very first presentation look empty even though the
    /// passed-in queue was correct by the time it actually appeared.
    let initialQueue: [TaskItem]
    /// Fires when Close is tapped specifically from the "All Caught Up"
    /// screen — not from the toolbar Cancel shown mid-review — so a caller
    /// that wants to keep moving once review is genuinely finished (see
    /// NightlyReviewView, which jumps straight into the Plan step) can
    /// tell that apart from an early bail-out.
    var onAllCaughtUpClose: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    /// Read once, the moment the task queue actually empties out (see
    /// `advance`) — a live `@Query` here would otherwise pull a freshly
    /// created (definitely-unreviewed) tag straight into this run's queue
    /// the instant `addTag` creates it elsewhere in the app.
    @Query(sort: \Tag.name) private var allTags: [Tag]
    @State private var queue: [TaskItem] = []
    @State private var currentTask: TaskItem?
    @State private var snapshot: TaskEditSnapshot?
    @State private var entersFromLeft = false
    @State private var hasStarted = false
    @State private var completeBurstID: Int?
    /// The trailing phase, once every task's been handled — every not-yet-
    /// reviewed tag, one `LocationTagPickerView` at a time (see `advance`).
    @State private var hasStartedTagPhase = false
    @State private var tagQueue: [Tag] = []
    @State private var currentTag: Tag?

    init(shelves: [Shelf], queue: [TaskItem], onAllCaughtUpClose: (() -> Void)? = nil) {
        self.shelves = shelves
        self.initialQueue = queue
        self.onAllCaughtUpClose = onAllCaughtUpClose
    }

    var body: some View {
        NavigationStack {
            Group {
                if let currentTask {
                    TaskReviewCard(
                        task: currentTask,
                        shelves: shelves,
                        onDiscard: {
                            modelContext.delete(currentTask)
                            advance()
                        },
                        onSkip: advance,
                        onMove: { shelf in
                            currentTask.shelf = shelf
                            currentTask.estimatedMinutes = shelf.resolvedDuration(candidateMinutes: currentTask.estimatedMinutes)
                            if !shelf.effectiveTracksDuration {
                                currentTask.isDivisible = false
                                currentTask.minimumSegmentMinutes = 0
                            }
                            if !shelf.effectiveTracksDueDates {
                                currentTask.dueDate = nil
                            }
                            if !shelf.effectiveTracksNextStep {
                                currentTask.nextStep = ""
                            }
                            if !shelf.effectiveTracksPriority {
                                currentTask.priority = .unset
                            }
                            // Eligible Schedules is already seeded (all
                            // the shelf's enabled rules on by default) the
                            // moment this shelf was first previewed — see
                            // `shelfRow` — and any toggled off since then
                            // should stick, so this no longer re-seeds it.
                            advance()
                        },
                        onNext: advance,
                        isExcludedFromAttributeReview: currentTask.attributeReviewExcluded,
                        onToggleExcludeFromAttributeReview: { currentTask.attributeReviewExcluded.toggle() },
                        entersFromLeft: entersFromLeft
                    )
                    .id(currentTask.id)
                    .padding(.top, 4)
                } else if hasStartedTagPhase && currentTag == nil && tagQueue.isEmpty {
                    ContentUnavailableView {
                        Label("All Caught Up", systemImage: "checkmark.circle")
                    } description: {
                        Text("Every shelf task has its details filled in, and every tag's been reviewed.")
                    }
                    .safeAreaInset(edge: .bottom) {
                        Button("Close", action: closeAfterAllCaughtUp)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal)
                            .padding(.bottom, 24)
                    }
                } else {
                    // Nothing to show here itself — either mid-transition
                    // into the tag phase, or a tag's own screen is up as a
                    // sheet on top of this (see `.sheet(item: $currentTag)`
                    // below). Showing "All Caught Up" in this window would
                    // flash behind it.
                    Color.clear
                }
            }
            .sheet(item: $currentTag, onDismiss: advanceTag) { tag in
                LocationTagPickerView(tagName: tag.name)
            }
            .overlay {
                if let completeBurstID {
                    CompletionBurstView().id(completeBurstID)
                        .allowsHitTesting(false)
                }
            }
            .toolbar {
                if currentTask != nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: cancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Mark Complete", action: markComplete)
                            .tint(.green)
                    }
                }
            }
            .onAppear {
                guard !hasStarted else { return }
                hasStarted = true
                var queue = initialQueue
                currentTask = queue.isEmpty ? nil : queue.removeFirst()
                self.queue = queue
                if let currentTask {
                    snapshot = TaskEditSnapshot(currentTask)
                } else {
                    startTagPhaseIfNeeded()
                }
            }
        }
    }

    /// Only Cancel rolls the current card back — everything already
    /// advanced past this session stays saved, since each card's edits
    /// commit straight to the model as they're made.
    private func cancel() {
        if let currentTask {
            snapshot?.restore(into: currentTask)
        }
        dismiss()
    }

    /// Nothing to roll back here — there's no `currentTask` left by the
    /// time "All Caught Up" is showing — so this just gives the caller a
    /// chance to react to review actually finishing before dismissing.
    private func closeAfterAllCaughtUp() {
        onAllCaughtUpClose?()
        dismiss()
    }

    private func markComplete() {
        currentTask?.markComplete(in: modelContext)
        completeBurstID = (completeBurstID ?? 0) + 1
        // Let the burst actually play before the card flies off to the
        // next task — advancing immediately would tear it down unseen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            advance()
        }
    }

    private func advance() {
        entersFromLeft = true
        guard queue.isEmpty else {
            currentTask = queue.removeFirst()
            snapshot = currentTask.map(TaskEditSnapshot.init)
            return
        }
        currentTask = nil
        snapshot = nil
        startTagPhaseIfNeeded()
    }

    /// Seeds `tagQueue` from whatever's still unreviewed the moment the
    /// task queue actually empties (only once — see `hasStartedTagPhase`),
    /// then presents the first one.
    private func startTagPhaseIfNeeded() {
        if !hasStartedTagPhase {
            hasStartedTagPhase = true
            tagQueue = allTags.filter { !$0.isReviewed }
        }
        advanceTag()
    }

    private func advanceTag() {
        currentTag = tagQueue.isEmpty ? nil : tagQueue.removeFirst()
    }
}

/// A little celebratory pop for Mark Complete — a ring of dots flings
/// outward and fades. Purely decorative (`allowsHitTesting(false)` at the
/// call site), replayed each tap by re-mounting via `.id()`.
private struct CompletionBurstView: View {
    private static let colors: [Color] = [.green, .mint, .teal, .yellow]

    var body: some View {
        ZStack {
            ForEach(0..<12, id: \.self) { i in
                BurstParticle(angle: Double(i) / 12 * 2 * .pi, color: Self.colors[i % Self.colors.count])
            }
        }
        .frame(width: 1, height: 1)
    }

    private struct BurstParticle: View {
        let angle: Double
        let color: Color
        @State private var traveled = false

        var body: some View {
            Circle()
                .fill(color)
                .frame(width: 16, height: 16)
                .offset(
                    x: traveled ? cos(angle) * 160 : 0,
                    y: traveled ? sin(angle) * 160 : 0
                )
                .scaleEffect(traveled ? 0.3 : 1)
                .opacity(traveled ? 0 : 1)
                .onAppear {
                    withAnimation(.easeOut(duration: 0.5)) {
                        traveled = true
                    }
                }
        }
    }
}

#Preview {
    let shelf = Shelf(name: "To-Do List", systemImage: "checklist")
    return TaskReviewQueueSheet(shelves: [shelf], queue: [TaskItem(title: "Sample task", shelf: shelf)])
        .modelContainer(for: [TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self, Habit.self, HabitLog.self], inMemory: true)
}
