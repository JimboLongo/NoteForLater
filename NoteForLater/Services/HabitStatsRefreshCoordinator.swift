import Foundation

/// Coordinates the "recalculate stats, then re-sort" idle debounce shared
/// across every screen a habit occurrence can be marked from — the
/// Calendar tab's block/occurrence checkmarks, the Habits tab's Today list,
/// and a habit's own detail calendar. Whichever mutates a `HabitLog` calls
/// `habitLogsChanged()` right after; anything that shows stats or an order
/// derived from them observes `idleRefreshTick`, bumped once 3 seconds pass
/// with no further calls anywhere. A tap's own visible effect — the
/// checkmark/fade/strikethrough, the day cell's color — always comes from
/// mutating the model directly, and is never gated behind this; only the
/// heavier "recompute streaks and re-sort the list" work waits for things
/// to actually go quiet, so a rapid run of taps never has that competing
/// with the taps themselves for the main thread.
@Observable
final class HabitStatsRefreshCoordinator {
    static let shared = HabitStatsRefreshCoordinator()

    private(set) var idleRefreshTick = 0
    private var debounceTask: Task<Void, Never>?

    private init() {}

    func habitLogsChanged() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.idleRefreshTick += 1
        }
    }
}
