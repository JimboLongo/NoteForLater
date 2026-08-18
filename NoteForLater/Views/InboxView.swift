import SwiftUI
import SwiftData

/// The brain dump. Type it, hit return, sort it later — tap an item to fill
/// in its attributes and route it. Sorted oldest-first so whatever's been
/// sitting longest surfaces at the top. "Unsorted" is just `TaskItem.shelf
/// == nil` — there's no separate model. Content-only (no own
/// NavigationStack) so it can be hosted either as the Inbox tab's root or
/// as a page in ShelfCarouselView.
struct InboxView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<TaskItem> { $0.shelf == nil && !$0.isCompleted }, sort: \TaskItem.createdAt)
    private var items: [TaskItem]
    @Query(sort: \Shelf.sortOrder) private var shelves: [Shelf]
    @Query(sort: \TaskItem.createdAt) private var allTasks: [TaskItem]
    @Query(sort: \Habit.sortOrder) private var allHabits: [Habit]
    @Query(sort: \Tag.name) private var allTags: [Tag]
    @Query private var allTagLinks: [TagLink]

    @State private var viewModel: InboxViewModel?
    @State private var draftText: String = ""
    @State private var isShowingImporter = false
    @State private var speechCapture = SpeechCaptureService()
    @State private var quickAction = QuickActionService.shared
    @State private var nightlyReviewLaunchState = NightlyReviewLaunchState.shared
    @State private var inboxSearchState = InboxSearchState.shared
    @State private var selectedTask: TaskItem?
    @State private var selectedHabit: Habit?
    @State private var scrollProxy: ScrollViewProxy?
    @FocusState private var isCaptureFocused: Bool
    /// Live cross-app search — every task (any shelf, or still in the
    /// Inbox) and every habit, right here instead of behind a separate
    /// screen. Empty means "not searching," which just falls back to the
    /// normal Inbox list below.
    @State private var searchQuery = ""

    /// The Kitchen shelf (Pantry + Cookbook) is never a routing
    /// destination for arbitrary Inbox brain-dumps — Pantry is
    /// ingredients-only, filled by hand or a receipt scan.
    private var routableShelves: [Shelf] {
        shelves.filter { !$0.isKitchen }
    }

    private var trimmedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool {
        !trimmedSearchQuery.isEmpty
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if isSearching {
                    searchResultsContent
                } else {
                    if items.isEmpty {
                        Text("Inbox zero. Nice.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(sortedItems) { item in
                        Button {
                            selectedTask = item
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .lineLimit(2)
                                Text(item.isSnoozedFromAttributeReview ? snoozeRemainingText(item) : daysSittingText(item))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .opacity(item.isSnoozedFromAttributeReview ? 0.5 : 1)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                viewModel?.discard(item)
                            } label: {
                                Label("Discard", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .task { scrollProxy = proxy }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .top) {
            // Hidden entirely while searching — results take over the
            // whole screen instead of sharing it with the capture bar.
            if !isSearching {
                VStack(spacing: 0) {
                    header
                    captureBar
                }
                .background(.bar)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                // Same reasoning as the top inset above — only the search
                // bar itself (still needed to edit/clear the query) stays
                // up while results are showing.
                if !isSearching {
                    Button {
                        nightlyReviewLaunchState.pendingReview = true
                    } label: {
                        Label("Start Nightly Review", systemImage: "moon.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }

                searchBar
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $isShowingImporter) {
            ImportView()
        }
        .sheet(item: $selectedTask) { task in
            TaskCardSheet(task: task, shelves: routableShelves)
        }
        .sheet(item: $selectedHabit) { habit in
            NavigationStack {
                HabitEditView(habit: habit)
            }
        }
        .onChange(of: speechCapture.transcript) { _, newValue in
            draftText = newValue
        }
        .onChange(of: quickAction.pendingQuickAdd) { _, isPending in
            guard isPending else { return }
            isCaptureFocused = true
            quickAction.pendingQuickAdd = false
        }
        .onChange(of: isSearching) { _, newValue in
            inboxSearchState.isSearching = newValue
        }
        .onAppear {
            if viewModel == nil {
                viewModel = InboxViewModel(modelContext: modelContext)
            }
        }
        // Defensive — if this view ever gets torn down mid-search instead
        // of the query being cleared first, this is what keeps
        // ShelfCarouselView's own chevron bar from staying hidden forever.
        .onDisappear {
            inboxSearchState.isSearching = false
        }
    }

    /// In-content header (not the system nav bar, which is hidden entirely
    /// — see `.toolbar(.hidden, for: .navigationBar)` above — so this sits
    /// flush with the top of the screen instead of below a reserved bar).
    /// Living in-content also means it's part of the same sliding page as
    /// the list and capture bar: swiping between Inbox and a shelf in
    /// ShelfCarouselView moves all three together instead of the title
    /// cross-fading separately from the content underneath it.
    private var header: some View {
        HStack {
            Text("Inbox (\(items.count) Task\(items.count == 1 ? "" : "s"))")
                .font(.title2.weight(.bold))
            Spacer()
            Button {
                isShowingImporter = true
            } label: {
                Image(systemName: "tray.and.arrow.down")
            }
        }
        .padding(.horizontal)
        .padding(.top, 24)
        .padding(.bottom, 4)
    }

    /// Custom rather than the system `.searchable` field — that one only
    /// renders docked to a visible navigation bar, and this screen hides
    /// its own entirely (see `header`'s doc comment) in favor of the same
    /// in-content title bar every page here uses.
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search tasks, habits, tags, next steps", text: $searchQuery)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
            if isSearching {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var captureBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Note for later", text: $draftText, axis: .vertical)
                    .submitLabel(.done)
                    .onSubmit(addDraft)
                    .focused($isCaptureFocused)
                    .frame(minHeight: 42)
                    .onChange(of: draftText) { _, newValue in
                        // axis: .vertical sometimes inserts a newline on the
                        // Done key instead of firing onSubmit — catch that here.
                        guard newValue.hasSuffix("\n") else { return }
                        draftText = String(newValue.dropLast())
                        addDraft()
                    }
                Button {
                    speechCapture.toggle()
                } label: {
                    Image(systemName: speechCapture.isRecording ? "mic.fill" : "mic")
                        .foregroundStyle(speechCapture.isRecording ? .red : .accentColor)
                        .symbolEffect(.pulse, isActive: speechCapture.isRecording)
                }
                Button(action: addDraft) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title)
                }
                .padding(.leading, 12)
                .disabled(draftText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let errorMessage = speechCapture.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func addDraft() {
        guard let item = viewModel?.addItem(draftText) else { return }
        draftText = ""
        isCaptureFocused = false
        DispatchQueue.main.async {
            withAnimation {
                scrollProxy?.scrollTo(item.id, anchor: .bottom)
            }
        }
    }

    private func daysSittingText(_ item: TaskItem) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: item.createdAt),
            to: calendar.startOfDay(for: .now)
        ).day ?? 0
        if days <= 0 { return "Added today" }
        return "\(days) day\(days == 1 ? "" : "s") in inbox"
    }

    /// Snoozed items sort to the bottom of the list — still oldest-first
    /// within each group, since `items` itself already arrives sorted that
    /// way and `sorted(by:)` is stable — rather than disappearing outright,
    /// so a snoozed brain-dump doesn't get lost, just deprioritized.
    private var sortedItems: [TaskItem] {
        items.sorted { !$0.isSnoozedFromAttributeReview && $1.isSnoozedFromAttributeReview }
    }

    /// Whole days remaining until `attributeReviewSnoozedUntil`, rounded up
    /// so "snoozed until 11pm tomorrow" still reads as "1 day" rather than
    /// "0 days" a minute after snoozing.
    private func snoozeRemainingText(_ item: TaskItem) -> String {
        guard let until = item.attributeReviewSnoozedUntil else { return "" }
        let seconds = until.timeIntervalSince(.now)
        let days = max(1, Int(ceil(seconds / 86400)))
        return "Snoozed \(days) day\(days == 1 ? "" : "s")"
    }

    // MARK: - Live search

    /// Every task (any shelf, or still unsorted here) and every habit,
    /// matched by name/title, tag, or Next Step — tapping a result opens
    /// the same card/edit screen you'd reach from its actual home
    /// (`TaskCardSheet`/`HabitEditView`), so acting on a match doesn't
    /// require first finding where it actually lives.
    @ViewBuilder
    private var searchResultsContent: some View {
        if matchingHabits.isEmpty && matchingTasks.isEmpty {
            Text("No matches for \"\(trimmedSearchQuery)\".")
                .foregroundStyle(.secondary)
        } else {
            if !matchingHabits.isEmpty {
                Section("Habits") {
                    ForEach(matchingHabits) { habit in
                        Button {
                            selectedHabit = habit
                        } label: {
                            searchResultRow(title: habit.name, source: "Habit")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !matchingTasks.isEmpty {
                Section("Tasks") {
                    ForEach(matchingTasks) { task in
                        Button {
                            selectedTask = task
                        } label: {
                            searchTaskRow(for: task)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(searchRowColor(for: task))
                    }
                }
            }
        }
    }

    private var matchingTasks: [TaskItem] {
        guard isSearching else { return [] }
        let q = trimmedSearchQuery.lowercased()
        let linkedNames = linkedTagNameMatches(for: q)
        return allTasks.filter { task in
            task.title.lowercased().contains(q)
                || task.nextStep.lowercased().contains(q)
                || task.tags.contains { $0.lowercased().contains(q) }
                || task.tags.contains { linkedNames.contains($0.lowercased()) }
        }
    }

    private var matchingHabits: [Habit] {
        guard isSearching else { return [] }
        let q = trimmedSearchQuery.lowercased()
        return allHabits.filter { $0.name.lowercased().contains(q) }
    }

    /// Every tag name a search for `q` should also match, via `TagLink` —
    /// only ever widens the direct substring match above, never narrows
    /// it. `q` matching a `Tag`'s own name at all (the same substring
    /// convention as a task's own tags) is what makes that tag "in play"
    /// for expansion; see `TagLink.expandedSearchTagNames` for the
    /// 1-way/2-way rule itself.
    private func linkedTagNameMatches(for q: String) -> Set<String> {
        let directlyMatchedTags = allTags.filter { $0.name.lowercased().contains(q) }
        var names = Set<String>()
        for tag in directlyMatchedTags {
            for name in TagLink.expandedSearchTagNames(for: tag, allTags: allTags, allLinks: allTagLinks) {
                names.insert(name.lowercased())
            }
        }
        return names
    }

    private func searchResultRow(title: String, source: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// Renders each task exactly as it looks in its actual home list — the
    /// full `TaskRow` card (due date, duration, age, pushed count, tags,
    /// scheduled badge) for a shelf task, or the same minimal
    /// title-plus-"days sitting" row used above for one still unsorted
    /// here — rather than a search-specific summary of either.
    @ViewBuilder
    private func searchTaskRow(for task: TaskItem) -> some View {
        if let shelf = task.shelf {
            TaskRow(task: task, showsScheduledBadge: shelf.hasEnabledSchedulingRules, showsPantryAge: shelf.isKitchen)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).lineLimit(2)
                Text(daysSittingText(task))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Matches `ShelfListView`'s own row tint — same shelf, same color, so
    /// a match reads as "from that shelf" at a glance instead of only via
    /// the label underneath. An unsorted task gets no tint, matching its
    /// row above.
    private func searchRowColor(for task: TaskItem) -> Color {
        task.shelf?.flattenedColor(opacity: 0.28) ?? Color.clear
    }
}

/// Carries Task Attribute Review's queue as part of the `.sheet(item:)`
/// identity itself, so the queue and the decision to present arrive as one
/// atomic value instead of two separately-written `@State` properties.
/// Shared with `NightlyReviewView`, which launches the same review
/// automatically after Today is reviewed.
struct AttributeReviewSession: Identifiable {
    let id = UUID()
    let queue: [TaskItem]
}

#Preview {
    NavigationStack {
        InboxView()
    }
    .modelContainer(for: [TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self, Habit.self, HabitLog.self], inMemory: true)
}
