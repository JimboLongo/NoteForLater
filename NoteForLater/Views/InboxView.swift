import SwiftUI
import SwiftData

/// The brain dump. Type it, hit return, sort it later — tap an item to fill
/// in its attributes and route it, or use the shelf slider + Submit for
/// quick bulk sorting. Sorted oldest-first so whatever's been sitting
/// longest surfaces at the top.
struct InboxView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \InboxItem.createdAt) private var items: [InboxItem]
    @Query(sort: \Shelf.sortOrder) private var shelves: [Shelf]

    @State private var viewModel: InboxViewModel?
    @State private var draftText: String = ""
    @State private var isShowingImporter = false
    @State private var speechCapture = SpeechCaptureService()

    /// Per-row shelf picked on the slider but not yet submitted, keyed by
    /// InboxItem.id. Nothing here is routed until "Submit" is tapped.
    @State private var pendingShelfSelections: [UUID: Shelf] = [:]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("What's on your mind?", text: $draftText, axis: .vertical)
                            .submitLabel(.done)
                            .onSubmit(addDraft)
                        Button {
                            speechCapture.toggle()
                        } label: {
                            Image(systemName: speechCapture.isRecording ? "mic.fill" : "mic")
                                .foregroundStyle(speechCapture.isRecording ? .red : .accentColor)
                                .symbolEffect(.pulse, isActive: speechCapture.isRecording)
                        }
                        Button(action: addDraft) {
                            Image(systemName: "plus.circle.fill")
                        }
                        .disabled(draftText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let errorMessage = speechCapture.errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section("Unsorted (\(items.count))") {
                    if items.isEmpty {
                        Text("Inbox zero. Nice.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(items) { item in
                        HStack {
                            NavigationLink {
                                InboxItemDetailView(item: item, shelves: shelves) { shelf in
                                    viewModel?.route(item, to: shelf)
                                    pendingShelfSelections[item.id] = nil
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.text)
                                        .lineLimit(2)
                                    Text(daysSittingText(item))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            ShelfSlider(shelves: shelves, selectedShelf: binding(for: item))
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                viewModel?.discard(item)
                                pendingShelfSelections[item.id] = nil
                            } label: {
                                Label("Discard", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                if !pendingShelfSelections.isEmpty {
                    Button {
                        submitPendingRoutes()
                    } label: {
                        Label("Sort \(pendingShelfSelections.count) Tasks to Shelves", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.bar)
                }
            }
            .navigationTitle("Note for Later")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingImporter = true
                    } label: {
                        Image(systemName: "tray.and.arrow.down")
                    }
                }
            }
            .sheet(isPresented: $isShowingImporter) {
                ImportView()
            }
            .onChange(of: speechCapture.transcript) { _, newValue in
                draftText = newValue
            }
            .onAppear {
                if viewModel == nil {
                    viewModel = InboxViewModel(modelContext: modelContext)
                }
            }
        }
    }

    private func addDraft() {
        viewModel?.addItem(draftText)
        draftText = ""
    }

    private func binding(for item: InboxItem) -> Binding<Shelf?> {
        Binding(
            get: { pendingShelfSelections[item.id] },
            set: { pendingShelfSelections[item.id] = $0 }
        )
    }

    private func submitPendingRoutes() {
        for (itemID, shelf) in pendingShelfSelections {
            guard let item = items.first(where: { $0.id == itemID }) else { continue }
            viewModel?.route(item, to: shelf)
        }
        pendingShelfSelections.removeAll()
    }

    private func daysSittingText(_ item: InboxItem) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: item.createdAt),
            to: calendar.startOfDay(for: .now)
        ).day ?? 0
        if days <= 0 { return "Added today" }
        return "\(days) day\(days == 1 ? "" : "s") in inbox"
    }
}

/// Swipeable picker: skip, or swipe through shelves to land on one.
/// Circular — swiping past the last shelf wraps back to Skip, and swiping
/// backward from Skip wraps to the last shelf. Each swipe is a discrete
/// flick to the next/previous option (not a finger-tracked drag), so it
/// reads as a swipe rather than a slow slide. Nothing happens until the
/// item is submitted from the top of the Inbox.
private struct ShelfSlider: View {
    let shelves: [Shelf]
    @Binding var selectedShelf: Shelf?

    @State private var insertionEdge: Edge = .trailing
    @State private var removalEdge: Edge = .leading

    private static let width: CGFloat = 150
    private static let height: CGFloat = 32

    /// index 0 is always "Skip" (nil); shelves follow in order.
    private var items: [Shelf?] { [nil] + shelves.map { $0 } }

    private var currentIndex: Int {
        items.firstIndex { $0?.id == selectedShelf?.id } ?? 0
    }

    var body: some View {
        Text(items[currentIndex]?.name ?? "Skip")
            .id(currentIndex)
            .font(.caption)
            .fontWeight(.medium)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 12)
            .frame(width: Self.width, height: Self.height)
            .transition(.asymmetric(
                insertion: .move(edge: insertionEdge).combined(with: .opacity),
                removal: .move(edge: removalEdge).combined(with: .opacity)
            ))
            .background(Color.secondary.opacity(0.12))
            .clipShape(Capsule())
            .contentShape(Capsule())
            .clipped()
            .gesture(
                DragGesture(minimumDistance: 16)
                    .onEnded { value in
                        if value.translation.width < 0 {
                            step(by: 1)
                        } else if value.translation.width > 0 {
                            step(by: -1)
                        }
                    }
            )
    }

    private func step(by delta: Int) {
        let count = items.count
        let newIndex = ((currentIndex + delta) % count + count) % count
        insertionEdge = delta > 0 ? .trailing : .leading
        removalEdge = delta > 0 ? .leading : .trailing
        withAnimation(.easeInOut(duration: 0.2)) {
            selectedShelf = items[newIndex]
        }
    }
}

#Preview {
    InboxView()
        .modelContainer(for: [InboxItem.self, TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, LocationTag.self], inMemory: true)
}
