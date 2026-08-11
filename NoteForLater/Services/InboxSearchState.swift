import Observation

/// Whether InboxView's own live search is currently active (non-empty
/// query) — set by InboxView, observed by ShelfCarouselView so its
/// pinned shelf chevron bar can hide itself too while search results are
/// taking over the screen. Mirrors NightlyReviewLaunchState's pattern:
/// a single piece of cross-view UI state that doesn't belong on either
/// view's own model data.
@Observable
final class InboxSearchState {
    static let shared = InboxSearchState()
    var isSearching = false
    private init() {}
}
