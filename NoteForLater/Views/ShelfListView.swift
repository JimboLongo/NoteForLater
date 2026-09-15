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
    @State private var isShowingReceiptScanner = false
    @State private var isShowingBarcodeScanner = false
    @State private var selectedTask: PresentedTask?
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

    /// A task that's actually landed on the calendar sorts by that real
    /// slot — same earliest-block lookup `TaskRow`'s own scheduled-date
    /// badge uses — before anything else gets a say, so the shelf order
    /// matches what's actually coming up rather than when the task was
    /// added or (for a recurring one) some future occurrence that isn't
    /// this scheduled instance. A recurring task sorts by its own next
    /// occurrence (soonest first) rather than `createdAt` — otherwise it'd
    /// sit wherever it happened to be added instead of where it's
    /// actually coming up next. A recurring task with nothing left coming
    /// (past `recurrenceEndDate`) sorts to the very end rather than
    /// fighting for a spot among what's still upcoming. Every other task
    /// keeps the query's own oldest-first `createdAt` order.
    private func sortDate(for task: TaskItem) -> Date {
        if task.isScheduled, let earliest = (task.scheduledBlocks ?? []).min(by: { $0.startTime < $1.startTime })?.date {
            return earliest
        }
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
                        selectedTask = PresentedTask(task: task, isNewlyCreated: false)
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
        .sheet(item: $selectedTask) { presented in
            TaskCardSheet(task: presented.task, shelves: routableShelves, isNewlyCreated: presented.isNewlyCreated)
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
                    isShowingReceiptScanner = true
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
        .fullScreenCover(isPresented: $isShowingReceiptScanner) {
            // Live OCR scanning is the default now — the original
            // single-photo flow is still reachable, just one tap further
            // in, via that screen's own "Import from Photo" menu item.
            ReceiptOCRScannerView(shelf: shelf)
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
                .onSubmit { addTask(openCard: false) }
                .focused($isCaptureFocused)
                .frame(minHeight: 42)
                .onChange(of: draftTitle) { _, newValue in
                    guard newValue.hasSuffix("\n") else { return }
                    draftTitle = String(newValue.dropLast())
                    addTask(openCard: false)
                }
            Button {
                speechCapture.toggle()
            } label: {
                Image(systemName: speechCapture.isRecording ? "mic.fill" : "mic")
                    .foregroundStyle(speechCapture.isRecording ? .red : .accentColor)
                    .symbolEffect(.pulse, isActive: speechCapture.isRecording)
            }
            Button {
                addTask(openCard: true)
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title)
            }
            .padding(.leading, 12)
            .disabled(draftTitle.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    /// Enter (both the keyboard's own submit and the vertical-growing
    /// field's own newline-in-text handler, since `axis: .vertical` means
    /// Enter inserts "\n" rather than firing `onSubmit` directly) saves
    /// silently — `openCard: false`. The plus button saves and opens the
    /// task straight into the same `TaskCardSheet` tapping an existing
    /// row already presents (`selectedTask`, below) — one presentation
    /// path, not a second one bolted on for capture. Dismissing the
    /// keyboard first (`isCaptureFocused = false`) before setting
    /// `selectedTask` avoids the two animations — keyboard collapsing,
    /// sheet rising — competing with each other.
    private func addTask(openCard: Bool) {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let task = TaskItem.makeForDirectCapture(title: trimmed, shelf: shelf)
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
            // The scroll above is purely cosmetic once the card is about
            // to cover the screen — still fired so the list is in the
            // right place underneath/behind the sheet once dismissed,
            // but the card itself opens without waiting on it.
            if openCard {
                selectedTask = PresentedTask(task: task, isNewlyCreated: true)
            }
        }
    }
}

/// Bundles a task with whether *this specific presentation* just created
/// it, as one `.sheet(item:)` identity — rather than a second, independent
/// `@State` bool alongside a bare `TaskItem?`, which could fall out of
/// sync with which task is actually showing (e.g. a stale `true` left over
/// from the plus button leaking into the next, unrelated row tap). Built
/// fresh at each of the two call sites that set `selectedTask`, so there's
/// nothing to reset between presentations — see `TaskCardSheet
/// .isNewlyCreated`'s own doc comment for why the flag lives here at all
/// rather than on `TaskItem`.
private struct PresentedTask: Identifiable {
    let task: TaskItem
    let isNewlyCreated: Bool
    var id: TaskItem.ID { task.id }
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

    /// "Sunday" — a recurring task's next occurrence, when it falls
    /// within the next 6 days (see `recurrenceNextOccurrenceLabel`).
    /// Unambiguous on its own at that range: it's necessarily *this*
    /// Sunday, not one several weeks out. Spelled out in full rather
    /// than abbreviated ("Sun") — this is the only thing on the line
    /// besides the frequency, so there's room, and it reads more clearly
    /// than a three-letter abbreviation sitting right next to a spelled-
    /// out frequency ("Every week · Sunday", not "Every week · Sun").
    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter
    }()

    /// "Sunday, Oct 5" — once the next occurrence is more than 6 days
    /// out, a bare weekday could be any of several, so month/day is
    /// added.
    private static let nextOccurrenceFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter
    }()

    /// "Sunday, Jan 3, 2027" — same as `nextOccurrenceFormatter`, plus
    /// the year, for the rarer case where the next occurrence actually
    /// falls in a different calendar year than today (a yearly-recurring
    /// task next landing next year) — "Jan 3" alone reads ambiguously
    /// close to a year boundary.
    private static let nextOccurrenceFormatterWithYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d, yyyy"
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

    /// How many packages are selectable — 0 up through 10 in quarter
    /// steps (41 options). Bounded, not exhaustive: `quantity` counts
    /// packages of a product (see `TaskItem.quantity`'s doc comment), and
    /// realistic pantry stock rarely exceeds a handful of any one thing,
    /// unlike raw ounces/grams which could run into the hundreds.
    private static let quantityOptions: [Double] = stride(from: 0.0, through: 10.0, by: 0.25).map { $0 }

    private static let quantityFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private func formattedQuantity(_ value: Double) -> String {
        Self.quantityFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// "Culture · 8 oz" — brand and package size, read straight from
    /// `TaskItem`'s own structured fields rather than parsed back out of
    /// the title, since the title no longer carries either (see
    /// `ReceiptImportView.addSelectedItems`). `nil` when there's nothing
    /// to show at all — a bare-count or manually-typed item with neither
    /// piece of data doesn't get an empty subtitle line.
    private var pantrySubtitle: String? {
        let sizeText: String? = {
            guard let packageSize = task.packageSize else { return nil }
            let numberText = formattedQuantity(packageSize)
            guard let unit = task.unit, !unit.isEmpty else { return numberText }
            return "\(numberText) \(unit)"
        }()
        let parts = [task.brand, sizeText].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    /// A genuine value picker, not relative +/- actions — "I have half of
    /// this" is a fact you select, not something you'd normally arrive at
    /// by repeatedly tapping +0.25. Brand/size are shown in their own
    /// subtitle (`pantrySubtitle`) rather than baked into the title, so
    /// this only needs to show and set how many packages you have, not
    /// repeat the unit here too.
    private var quantityPicker: some View {
        Picker("Quantity", selection: Binding(
            get: { task.quantity },
            set: { task.quantity = $0 }
        )) {
            ForEach(Self.quantityOptions, id: \.self) { value in
                Text(formattedQuantity(value)).tag(value)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .tint(.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.15), in: Capsule())
        .fixedSize()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if showsPantryAge {
                quantityPicker
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    // `.capitalized` is display-only — the stored title
                    // stays whatever it actually is (usually already a
                    // clean bare name post-scan, but this also normalizes
                    // older ALL-CAPS-from-OCR titles without touching the
                    // data). `.fixedSize` forces full wrapping instead of
                    // letting the `Spacer()`/scheduled-badge siblings
                    // squeeze this down to one truncated line.
                    Text(task.title.capitalized)
                        .font(.body)
                        .strikethrough(task.isCompleted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    // `!task.isRecurring` is load-bearing, not defensive
                    // filler: `isScheduled` is normally reset before a
                    // task can be toggled recurring, but the "Recurring?"
                    // toggle itself doesn't clear it (see that toggle's
                    // own handler in `TaskReviewCard`) — a task scheduled
                    // once, then later switched to recurring, keeps a
                    // stale `isScheduled == true` and a stale block behind
                    // it. Without this guard that stale badge would show
                    // alongside `recurrenceLine`'s own, current date for
                    // the same task. Recurring tasks always defer to
                    // `recurrenceLine` — see its own doc comment.
                    if showsScheduledBadge && task.isScheduled && !task.isRecurring,
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
                if showsPantryAge {
                    // Brand/size and the added-date both on one line
                    // rather than two — `pantrySubtitle` is `nil` for an
                    // item with neither piece of data, in which case this
                    // is just the date on its own.
                    Text([pantrySubtitle, pantryAgeText].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                if !eligibleScheduleNames.isEmpty {
                    Label(eligibleScheduleNames.joined(separator: ", "), systemImage: "calendar.badge.clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // The recurring task's *only* date display on this row —
                // frequency and next occurrence together, one line, not
                // two separate rows the reader has to mentally merge
                // themselves. See `recurrenceLine`'s own doc comment for
                // why the bottom row's date preview and the top-right
                // scheduled badge both stay out of this task's way.
                if let recurrenceLine {
                    Label(recurrenceLine, systemImage: "repeat")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !showsPantryAge {
                    HStack(spacing: 12) {
                        if showsAddedAge {
                            Label(addedAgeText, systemImage: "hourglass")
                        }
                        // Non-recurring only — a recurring task's date
                        // lives entirely in `recurrenceLine` above now;
                        // showing it again here would be the exact
                        // "second date treatment" that line exists to
                        // rule out.
                        if !task.isRecurring, let dueDate = task.dueDate {
                            Label(dueDate.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
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

    /// False for a recurring task — `createdAt` is when the task was
    /// first set up, not anything about the occurrence actually coming
    /// up, so it's just noise there (the next-occurrence label already
    /// carries the date that matters for a recurring task). `internal`
    /// rather than `private` so this is directly testable without
    /// rendering the view.
    var showsAddedAge: Bool { !task.isRecurring }

    /// "Every week · Sunday" — a recurring task's frequency and next
    /// occurrence, combined onto the one line `recurrenceSummary` used
    /// to render alone. `nil` for a non-recurring task (`recurrenceSummary`
    /// is already `nil` there) and for a recurring one with no occurrence
    /// left at all (`nextRecurringOccurrenceDate()` returns `nil` once
    /// `recurrenceEndDate` has passed) — falls back to the frequency
    /// alone rather than hiding the whole line in that case, since "every
    /// week until Dec 31, 2026" is still worth showing on its own.
    ///
    /// This is deliberately the *only* date treatment a recurring task
    /// gets on this row. The scheduled-date badge above
    /// (`showsScheduledBadge && task.isScheduled`) is guarded off
    /// `!task.isRecurring` specifically so the two can never both show
    /// for the same task — see that guard's own comment for the stale-
    /// `isScheduled` case that made this a real risk, not a theoretical
    /// one. The bottom row's own calendar-icon date preview is likewise
    /// non-recurring-only now (see `body`).
    var recurrenceLine: String? {
        guard let recurrenceSummary = task.recurrenceSummary else { return nil }
        guard let nextOccurrence = task.nextRecurringOccurrenceDate() else { return recurrenceSummary }
        return "\(recurrenceSummary) · \(Self.recurrenceNextOccurrenceLabel(for: nextOccurrence))"
    }

    /// Bare short weekday ("Sun") when `date` falls within the next 6
    /// days — unambiguous, since that's necessarily this week's (or
    /// tomorrow's) occurrence of that weekday. Beyond 6 days, a bare
    /// weekday could be any of several out along the pattern, so
    /// month/day is added ("Sun, Oct 5"); the year joins the two only
    /// once `date` actually falls in a different calendar year than
    /// today, since "Oct 5" alone is already unambiguous within the
    /// current year. `today` is a parameter (defaulting to `.now`) purely
    /// for testability — production callers never override it.
    static func recurrenceNextOccurrenceLabel(for date: Date, today: Date = .now, calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: today)
        let targetDay = calendar.startOfDay(for: date)
        let daysAway = calendar.dateComponents([.day], from: today, to: targetDay).day ?? 0
        guard daysAway > 6 else { return weekdayFormatter.string(from: date) }
        let sameYear = calendar.component(.year, from: targetDay) == calendar.component(.year, from: today)
        return (sameYear ? nextOccurrenceFormatter : nextOccurrenceFormatterWithYear).string(from: date)
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

    /// Same eligibility check the full task-edit sheet's "Eligible
    /// Schedules" section uses (`task.isEligible(for: rule)` against
    /// `shelf.schedulingRules`, `NightlyReviewView`'s `rules.sorted { $0
    /// .sortOrder < $1.sortOrder }`) — just the names here, not the
    /// toggle UI, so a glance at the shelf shows which schedules a task
    /// is opted into without opening the full edit sheet.
    private var eligibleScheduleNames: [String] {
        (task.shelf?.schedulingRules ?? [])
            .sorted { $0.sortOrder < $1.sortOrder }
            .filter { task.isEligible(for: $0) }
            .map { $0.displayName.isEmpty ? $0.summary : $0.displayName }
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
