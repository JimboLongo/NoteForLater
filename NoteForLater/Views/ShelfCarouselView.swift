import SwiftUI
import SwiftData

/// One page in the carousel across Inbox + every shelf. Inbox is treated
/// as if it were "shelf zero" — the anchor at the start of the sequence —
/// so the order reads as Inbox → Shelf 1 → Shelf 2 → ... → Shelf N,
/// circular at both ends.
enum ShelfCarouselPage: Hashable {
    case inbox
    case shelf(Shelf)
}

/// Moves between Inbox and every shelf via a fixed arrow bar pinned right
/// above the tab bar, instead of a full-screen swipe — a full-screen swipe
/// meant any horizontal drag *inside* a page (the shelf-picker pill on an
/// Inbox row, a List row's own swipe actions) had to fight the page-swipe
/// for the gesture, which was never fully reliable. Tapping an arrow (or
/// dragging the label between them) steps to the next/previous page; the
/// arrow bar itself doesn't move, so it stays put while the page content
/// underneath it slides across. Circular at both ends — stepping forward
/// past the last shelf wraps to Inbox, and back past Inbox wraps to the
/// last shelf.
struct ShelfCarouselView: View {
    let shelves: [Shelf]
    /// Bumped by the parent (the Inbox tab re-selecting itself) to jump
    /// this carousel back to the Inbox page — see ContentView's
    /// `selectedTabBinding`.
    var resetToken: Int = 0
    @State private var currentIndex: Int
    @State private var insertionEdge: Edge = .trailing
    @State private var removalEdge: Edge = .leading
    /// Hides `navBar` while InboxView's own live search is taking over the
    /// screen — see `InboxSearchState`'s doc comment.
    @State private var inboxSearchState = InboxSearchState.shared

    init(shelves: [Shelf], initialPage: ShelfCarouselPage, resetToken: Int = 0) {
        self.shelves = shelves
        self.resetToken = resetToken
        let order = Self.buildPages(for: shelves)
        _currentIndex = State(initialValue: order.firstIndex(of: initialPage) ?? 0)
    }

    /// Inbox, then every shelf in sortOrder.
    private static func buildPages(for shelves: [Shelf]) -> [ShelfCarouselPage] {
        [ShelfCarouselPage.inbox] + shelves.map { ShelfCarouselPage.shelf($0) }
    }

    private var pages: [ShelfCarouselPage] { Self.buildPages(for: shelves) }

    private var currentPage: ShelfCarouselPage {
        pages.indices.contains(currentIndex) ? pages[currentIndex] : .inbox
    }

    private var currentTitle: String {
        switch currentPage {
        case .inbox: return "Inbox"
        case .shelf(let shelf): return shelf.name
        }
    }

    private var currentColor: Color {
        switch currentPage {
        case .inbox: return .secondary
        case .shelf(let shelf): return shelf.color
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            content(for: currentPage)
                .id(currentIndex)
                .transition(.asymmetric(
                    insertion: .move(edge: insertionEdge).combined(with: .opacity),
                    removal: .move(edge: removalEdge).combined(with: .opacity)
                ))
            if !inboxSearchState.isSearching {
                navBar
            }
        }
        .onChange(of: resetToken) { _, _ in
            currentIndex = pages.firstIndex(of: .inbox) ?? 0
        }
    }

    @ViewBuilder
    private func content(for page: ShelfCarouselPage) -> some View {
        switch page {
        case .inbox:
            InboxView()
        case .shelf(let shelf):
            ShelfListView(shelf: shelf)
        }
    }

    /// Frozen above the tab bar — not part of the page content above it,
    /// so it never moves while a page transitions in or out. The drag
    /// gesture is on the whole bar (not just the title label), so you can
    /// swipe anywhere on it, not only where you happen to tap precisely —
    /// the chevrons still work as a tap-to-step fallback either way.
    private var navBar: some View {
        HStack {
            Button {
                step(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .frame(width: 32, height: 40)
            }

            Spacer()

            Text(currentTitle)
                .id(currentIndex)
                .font(.headline)
                .lineLimit(1)
                .transition(.opacity)

            Spacer()

            Button {
                step(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.title3.weight(.semibold))
                    .frame(width: 32, height: 40)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Shelf.flatten(currentColor, opacity: 0.25))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 20)
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
        let count = pages.count
        insertionEdge = delta > 0 ? .trailing : .leading
        removalEdge = delta > 0 ? .leading : .trailing
        withAnimation(.easeInOut(duration: 0.2)) {
            currentIndex = ((currentIndex + delta) % count + count) % count
        }
    }
}

#Preview {
    let shelves = [
        Shelf(name: "To-Do List", systemImage: "checklist", sortOrder: 0),
        Shelf(name: "Stuff to Buy", systemImage: "cart", sortOrder: 1),
        Shelf(name: "Reference", systemImage: "archivebox", sortOrder: 2)
    ]
    return NavigationStack {
        ShelfCarouselView(shelves: shelves, initialPage: .inbox)
    }
    .modelContainer(for: [TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self, Habit.self, HabitLog.self], inMemory: true)
}
