import SwiftUI
import SwiftData

/// Review screen for a single day's schedule, navigable to any day via the
/// chevrons (default: tomorrow).
///
///   - On today: swipe LEFT to mark complete, swipe RIGHT to push to
///     another day (unschedules it for a future night to pick up).
///   - On any other day:
///     - Swipe LEFT  -> delete it, slot goes back to open (task requeued).
///     - Swipe RIGHT -> auto-replace with the next-best queued to-do.
///     - Long-press  -> pick a specific replacement from the unscheduled
///       queue; the bumped task goes back into the queue.
///   - Editing an already-approved block (either swipe action, on a
///     non-today day) drops it back to "proposed" — re-tapping Approve All
///     pushes the change to the same calendar event instead of a new one.
struct ScheduleReviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TaskItem.createdAt) private var allTasks: [TaskItem]
    @Query(sort: \Shelf.sortOrder) private var allShelves: [Shelf]
    @Query private var allBlocks: [ScheduledBlock]
    @Query private var calendarSubscriptions: [CalendarSubscription]
    @Query private var eligibleHoursWindows: [EligibleHoursWindow]

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
            .navigationTitle(dayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await changeDate(by: -1) }
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Approve All") {
                        viewModel?.approveAll()
                    }
                    .disabled((viewModel?.blocks.isEmpty) ?? true)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await changeDate(by: 1) }
                    } label: {
                        Image(systemName: "chevron.right")
                    }
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
            ProgressView("Building schedule...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if timelineRows(viewModel: viewModel).isEmpty {
                    Text("Nothing on the calendar yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(timelineRows(viewModel: viewModel)) { row in
                    switch row {
                    case .event(let event):
                        CalendarEventRow(event: event)
                    case .proposed(let block):
                        if isToday {
                            TodayBlockRow(block: block)
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button {
                                        viewModel.markComplete(block)
                                    } label: {
                                        Label("Complete", systemImage: "checkmark.circle.fill")
                                    }
                                    .tint(.green)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button {
                                        viewModel.pushToAnotherDay(block)
                                    } label: {
                                        Label("Push", systemImage: "arrow.uturn.forward.circle.fill")
                                    }
                                    .tint(.blue)
                                }
                        } else {
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

                if viewModel.blocks.isEmpty {
                    Section {
                        Button("Generate Schedule") {
                            Task { await viewModel.generateProposedSchedule(shelves: allShelves, eligibleHoursWindows: eligibleHoursWindows) }
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                    }
                    .listRowBackground(Color.clear)
                }
            }
        }
    }

    private func timelineRows(viewModel: ScheduleReviewViewModel) -> [DayTimelineRow] {
        let eventRows = viewModel.calendarEvents.map(DayTimelineRow.event)
        let proposedRows = viewModel.blocks.map(DayTimelineRow.proposed)
        return (eventRows + proposedRows).sorted { $0.startTime < $1.startTime }
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
        Task { await vm.loadCalendarEvents() }
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
    }

    private var dayTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        let date = viewModel?.targetDate ?? Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
        let dateText = formatter.string(from: date)
        return isToday ? "Today · \(dateText)" : dateText
    }
}

/// A single row in the day's merged timeline: either an existing calendar
/// event (read-only) or a proposed/approved task block.
private enum DayTimelineRow: Identifiable {
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
}

/// Existing calendar event, shown with its real title; tap for the full
/// details (time, description) Google has for it.
private struct CalendarEventRow: View {
    let event: CalendarEventSummary
    @State private var showingDetail = false

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading) {
                Text(timeRangeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(event.title)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { showingDetail = true }
        .sheet(isPresented: $showingDetail) {
            NavigationStack {
                Form {
                    Section("Title") { Text(event.title) }
                    Section("Time") { Text(timeRangeText) }
                    if let notes = event.notes, !notes.isEmpty {
                        Section("Details") { Text(notes) }
                    }
                }
                .navigationTitle("Event")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showingDetail = false }
                    }
                }
            }
        }
    }

    private var timeRangeText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return "\(formatter.string(from: event.start)) - \(formatter.string(from: event.end))"
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

/// Today's row: shows completed state instead of approval state, since by
/// today a block is either already approved or about to be pushed anyway.
private struct TodayBlockRow: View {
    let block: ScheduledBlock

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading) {
                Text(timeRangeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(block.task?.title ?? "Open slot")
                    .font(.body)
                    .strikethrough(block.isCompleted)
                    .foregroundStyle(block.isCompleted ? .secondary : .primary)
            }
            Spacer()
            if block.isCompleted {
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
        .modelContainer(for: [InboxItem.self, TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, LocationTag.self], inMemory: true)
}
