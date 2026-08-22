import SwiftUI
import SwiftData

/// A single reusable list for any user-defined shelf (To-Do List, Stuff to
/// Buy, Future Project, Reference, or anything the user adds from the
/// Shelves screen). Pushed inside the Shelves tab's own NavigationStack —
/// tap a task to edit it, tap the gear to edit the shelf itself
/// (name/icon/color/AI-Scheduler eligibility).
struct ShelfListView: View {
    let shelf: Shelf
    /// Defaults to the shelf's own name — overridden by `KitchenView` when
    /// embedding this as the Pantry pane, where the shelf itself is named
    /// "The Kitchen" but this specific pane should read "Pantry" instead.
    let displayName: String

    @Environment(\.modelContext) private var modelContext
    @Query private var allTasks: [TaskItem]
    @Query(sort: \Shelf.sortOrder) private var allShelves: [Shelf]
    @State private var draftTitle = ""
    @State private var speechCapture = SpeechCaptureService()
    @State private var isShowingReceiptImporter = false
    @State private var isShowingBarcodeScanner = false
    @State private var selectedTask: TaskItem?
    @State private var scrollProxy: ScrollViewProxy?
    @FocusState private var isCaptureFocused: Bool

    /// Move targets offered on a task's Tinder card — same convention as
    /// the Attribute Review flows: the Kitchen shelf holds Pantry
    /// ingredients (and Cookbook recipes), not tasks, so it's never a
    /// routing destination.
    private var routableShelves: [Shelf] {
        allShelves.filter { !$0.isKitchen }
    }

    init(shelf: Shelf, displayName: String? = nil) {
        self.shelf = shelf
        self.displayName = displayName ?? shelf.name
        let shelfID = shelf.id
        _allTasks = Query(
            filter: #Predicate<TaskItem> { $0.shelf?.id == shelfID },
            sort: \TaskItem.createdAt,
            // Oldest first everywhere — what's been sitting longest reads
            // at the top, and matches `AISchedulingService.taskOrdering`,
            // which pulls the oldest eligible task first too.
            order: .forward
        )
    }

    /// `allTasks`, minus tasks completed *without* a calendar block behind
    /// them — that's the older Task Attribute Review "Mark Complete" path,
    /// which has no later cleanup step, so hiding it immediately is still
    /// correct there. A task completed *on the calendar* keeps its
    /// `scheduledBlocks` entry until Night Time Review actually purges it
    /// (see `ScheduleReviewViewModel.purgeCompletedBlocks`), so it stays
    /// visible here (faded, struck through — see `TaskRow`) the whole
    /// time in between, instead of vanishing the instant it's checked off.
    private var visibleTasks: [TaskItem] {
        allTasks
            .filter { !$0.isCompleted || !($0.scheduledBlocks ?? []).isEmpty }
            .sorted { sortDate(for: $0) < sortDate(for: $1) }
    }

    /// A recurring task sorts by its own next occurrence (soonest first)
    /// rather than `createdAt` — otherwise it'd sit wherever it happened
    /// to be added instead of where it's actually coming up next. A
    /// recurring task with nothing left coming (past `recurrenceEndDate`)
    /// sorts to the very end rather than fighting for a spot among what's
    /// still upcoming. Every other task keeps the query's own oldest-first
    /// `createdAt` order.
    private func sortDate(for task: TaskItem) -> Date {
        guard task.isRecurring else { return task.createdAt }
        return task.nextRecurringOccurrenceDate() ?? .distantFuture
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if visibleTasks.isEmpty {
                    Text("Nothing here yet.")
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
                ForEach(visibleTasks) { task in
                    Button {
                        selectedTask = task
                    } label: {
                        TaskRow(task: task, showsScheduledBadge: shelf.hasEnabledSchedulingRules, showsPantryAge: shelf.isKitchen)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(shelf.flattenedColor(opacity: 0.28))
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            modelContext.delete(task)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        if shelf.isKitchen {
                            Button {
                                task.createdAt = .now
                            } label: {
                                Label("Re-up", systemImage: "arrow.clockwise")
                            }
                            .tint(.green)
                        }
                    }
                }
            }
            .task { scrollProxy = proxy }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(shelf.flattenedColor(opacity: 0.22))
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .top) {
            VStack(spacing: 0) {
                header
                captureBar
            }
            .background(shelf.flattenedColor(opacity: 0.2))
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: speechCapture.transcript) { _, newValue in
            draftTitle = newValue
        }
        .sheet(item: $selectedTask) { task in
            TaskCardSheet(task: task, shelves: routableShelves)
        }
    }

    /// In-content header (not the system nav bar, which is hidden entirely
    /// — see `.toolbar(.hidden, for: .navigationBar)` above — so this sits
    /// flush with the top of the screen instead of below a reserved bar).
    /// Living in-content also means it's part of the same sliding page as
    /// the list and capture bar: swiping between shelves in
    /// ShelfCarouselView moves the colored title bar right along with the
    /// content underneath it, instead of it cross-fading on its own.
    private var header: some View {
        HStack {
            Text(displayName)
                .font(.title2.weight(.bold))
                .lineLimit(1)
            Spacer()
            if shelf.isKitchen {
                Button {
                    isShowingBarcodeScanner = true
                } label: {
                    Image(systemName: "barcode.viewfinder")
                }
                .padding(.trailing, 4)
                Button {
                    isShowingReceiptImporter = true
                } label: {
                    Image(systemName: "camera.viewfinder")
                }
                .padding(.trailing, 4)
            }
            NavigationLink {
                ShelfEditView(shelf: shelf)
            } label: {
                Image(systemName: "gearshape")
            }
        }
        .padding(.horizontal)
        .padding(.top, 24)
        .padding(.bottom, 4)
        .sheet(isPresented: $isShowingReceiptImporter) {
            ReceiptImportView(shelf: shelf)
        }
        .fullScreenCover(isPresented: $isShowingBarcodeScanner) {
            BarcodeScannerView(shelf: shelf)
        }
    }

    /// Same capture affordance as the Inbox tab — text field, mic
    /// dictation, add button — just wired to insert straight onto this
    /// shelf instead of into the Inbox.
    private var captureBar: some View {
        HStack {
            TextField("Add to \(displayName)", text: $draftTitle, axis: .vertical)
                .submitLabel(.done)
                .onSubmit(addTask)
                .focused($isCaptureFocused)
                .frame(minHeight: 42)
                .onChange(of: draftTitle) { _, newValue in
                    guard newValue.hasSuffix("\n") else { return }
                    draftTitle = String(newValue.dropLast())
                    addTask()
                }
            Button {
                speechCapture.toggle()
            } label: {
                Image(systemName: speechCapture.isRecording ? "mic.fill" : "mic")
                    .foregroundStyle(speechCapture.isRecording ? .red : .accentColor)
                    .symbolEffect(.pulse, isActive: speechCapture.isRecording)
            }
            Button(action: addTask) {
                Image(systemName: "plus.circle.fill")
                    .font(.title)
            }
            .padding(.leading, 12)
            .disabled(draftTitle.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func addTask() {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let task = TaskItem(title: trimmed, shelf: shelf)
        modelContext.insert(task)
        draftTitle = ""
        isCaptureFocused = false
        // Pantry reads oldest-first, so a new item lands at the bottom;
        // every other shelf reads newest-first, so it lands at the top.
        let anchor: UnitPoint = shelf.isKitchen ? .bottom : .top
        DispatchQueue.main.async {
            withAnimation {
                scrollProxy?.scrollTo(task.id, anchor: anchor)
            }
        }
    }
}

/// Not `private` — reused as-is by `InboxView`'s live search so a task
/// result reads exactly like its own card back on its actual shelf, not a
/// stripped-down summary of it.
struct TaskRow: View {
    let task: TaskItem
    let showsScheduledBadge: Bool
    var showsPantryAge: Bool = false

    /// "Wed. Aug 12, 2026" — the scheduled badge's date text.
    private static let scheduledDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE. MMM d, yyyy"
        return formatter
    }()

    /// "(Today)", "(Tomorrow)", "(In 3 Days)", "(2 Days Ago)" — sits under
    /// the scheduled date badge as a faster-to-parse relative read on it.
    private static func relativeDayLabel(for date: Date) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: .now),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
        switch days {
        case 0: return "(Today)"
        case 1: return "(Tomorrow)"
        case -1: return "(Yesterday)"
        case let d where d > 1: return "(In \(d) Days)"
        default: return "(\(abs(days)) Days Ago)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(task.title)
                    .font(.body)
                    .strikethrough(task.isCompleted)
                Spacer()
                if showsScheduledBadge && task.isScheduled,
                   let scheduledDate = (task.scheduledBlocks ?? []).min(by: { $0.startTime < $1.startTime })?.date {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(Self.scheduledDateFormatter.string(from: scheduledDate))
                            .font(.caption2)
                            .foregroundStyle(.green)
                        Text(Self.relativeDayLabel(for: scheduledDate))
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
            }
            if !task.notes.isEmpty {
                Text(task.notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !task.nextStep.isEmpty {
                Label(task.nextStep, systemImage: "arrow.turn.down.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if showsPantryAge {
                Label(pantryAgeText, systemImage: "calendar")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    Label(addedAgeText, systemImage: "hourglass")
                    // A recurring task's own `dueDate` is just its
                    // recurrence anchor (see `TaskItem.hasRecurringOccurrence`)
                    // — once that anchor's passed, showing it here reads as
                    // a stale/wrong date. `nextRecurringOccurrenceDate()` is
                    // the same "soonest still-ahead occurrence" this list is
                    // already sorted by (see `ShelfListView.sortDate`), so
                    // the date shown here always matches the date it's
                    // ordered by.
                    if let previewDate = task.isRecurring ? task.nextRecurringOccurrenceDate() : task.dueDate {
                        Label(previewDate.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                    }
                    if task.estimatedMinutes > 0 {
                        Label(task.durationLabel, systemImage: "clock")
                    }
                    if task.pushedCount > 0 {
                        Label(pushedCountText, systemImage: "arrow.uturn.forward")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if !task.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
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
        }
        .padding(.vertical, 2)
        // Faded, on top of the title's strikethrough — a task marked
        // complete on the calendar (see
        // `ScheduleReviewViewModel.toggleComplete`) reads as "settled"
        // right here on the shelf too, until the next regenerate purges
        // it for good.
        .opacity(task.isCompleted ? 0.5 : 1)
    }

    /// `createdAt` is set the moment a task first exists, whether it landed
    /// straight on a shelf or came in through the Inbox first — so this
    /// reads as "days since added" either way, with no separate
    /// inbox-vs-shelf timestamp needed.
    private var daysSinceAdded: Int {
        max(0, Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: task.createdAt),
            to: Calendar.current.startOfDay(for: .now)
        ).day ?? 0)
    }

    private var addedAgeText: String {
        switch daysSinceAdded {
        case 0: return "Added today"
        case 1: return "Added 1 day ago"
        default: return "Added \(daysSinceAdded) days ago"
        }
    }

    /// Matches the same "Pushed N time(s)" wording `TaskReviewCard` shows
    /// on the Tinder-card header, just condensed to fit alongside the
    /// other caption-sized badges here.
    private var pushedCountText: String {
        "Pushed \(task.pushedCount)×"
    }

    private var pantryAgeText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return "Added \(formatter.string(from: task.createdAt)) \u{00B7} \(daysSinceAdded) day\(daysSinceAdded == 1 ? "" : "s") in Pantry"
    }
}

#Preview {
    let shelf = Shelf(name: "To-Do List", systemImage: "checklist")
    return NavigationStack {
        ShelfListView(shelf: shelf)
    }
    .modelContainer(for: [TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self, Habit.self, HabitLog.self], inMemory: true)
}
