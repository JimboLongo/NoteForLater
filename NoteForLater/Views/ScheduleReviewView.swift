import SwiftUI
import SwiftData

/// Nightly review screen: shows tomorrow's AI-proposed schedule.
///
///   - Swipe LEFT on a block  -> delete it, slot goes back to open (task
///     requeued for a future date).
///   - Swipe RIGHT on a block -> auto-replace the task with the next-best
///     queued to-do, keeping the same time slot.
///   - Long-press on a block  -> pick a specific replacement from the
///     unscheduled queue; the bumped task goes back into the queue.
struct ScheduleReviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TaskItem.createdAt) private var allTasks: [TaskItem]
    @Query private var allBlocks: [ScheduledBlock]
    @Query private var calendarSubscriptions: [CalendarSubscription]

    @State private var viewModel: ScheduleReviewViewModel?
    @State private var pickerTarget: ScheduledBlock?

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
            .navigationTitle(tomorrowTitle)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Approve All") {
                        viewModel?.approveAll()
                    }
                    .disabled((viewModel?.blocks.isEmpty) ?? true)
                }
            }
            .onAppear(perform: setupIfNeeded)
            .sheet(item: $pickerTarget) { block in
                if let viewModel {
                    ReplacementPickerSheet(
                        candidates: viewModel.unscheduledCandidates(from: allTasks, excluding: block)
                    ) { chosen in
                        viewModel.manualReplace(block, with: chosen)
                        pickerTarget = nil
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func content(viewModel: ScheduleReviewViewModel) -> some View {
        if viewModel.isGenerating {
            ProgressView("Building tomorrow's schedule...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.blocks.isEmpty {
            VStack(spacing: 16) {
                Text("No proposed schedule yet.")
                    .foregroundStyle(.secondary)
                Button("Generate Tomorrow's Schedule") {
                    Task { await viewModel.generateProposedSchedule(allTasks: allTasks) }
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(viewModel.blocks) { block in
                    ScheduleBlockRow(block: block)
                        .contentShape(Rectangle())
                        .onLongPressGesture {
                            pickerTarget = block
                        }
                        // Swipe left (revealed from the trailing edge): delete.
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                viewModel.deleteBlock(block)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        // Swipe right (revealed from the leading edge): auto-replace.
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                viewModel.autoReplace(block, candidatePool: allTasks)
                            } label: {
                                Label("Replace", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .tint(.orange)
                        }
                }
            }
        }
    }

    private func setupIfNeeded() {
        guard viewModel == nil else { return }
        let enabledIDs = calendarSubscriptions.filter(\.isEnabled).map(\.calendarID)
        calendarService.enabledCalendarIDs = enabledIDs.isEmpty ? ["primary"] : enabledIDs
        let vm = ScheduleReviewViewModel(
            modelContext: modelContext,
            calendarService: calendarService,
            schedulingService: schedulingService
        )
        vm.loadExistingBlocks(allBlocks)
        viewModel = vm
    }

    private var tomorrowTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
        return formatter.string(from: tomorrow)
    }
}

private struct ScheduleBlockRow: View {
    let block: ScheduledBlock

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading) {
                Text(timeRangeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(block.task?.title ?? "Open slot")
                    .font(.body)
            }
            Spacer()
            if block.approvalStatus == .approved {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    private var timeRangeText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return "\(formatter.string(from: block.startTime)) - \(formatter.string(from: block.endTime))"
    }
}

/// Long-press destination: pick exactly which unscheduled to-do should fill this slot.
private struct ReplacementPickerSheet: View {
    let candidates: [TaskItem]
    let onPick: (TaskItem) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if candidates.isEmpty {
                    Text("No unscheduled to-dos available.")
                        .foregroundStyle(.secondary)
                }
                ForEach(candidates) { task in
                    Button {
                        onPick(task)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(task.title)
                            Text("\(task.estimatedMinutes) min · \(task.priority.rawValue.capitalized)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Replace With...")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    ScheduleReviewView()
        .modelContainer(for: [InboxItem.self, TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self], inMemory: true)
}
