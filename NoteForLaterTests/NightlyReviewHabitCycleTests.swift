import XCTest
import SwiftData
@testable import NoteForLater

/// Coverage for Nightly Review's habit toggle upgrade: from a binary
/// none/complete toggle to the same four-state cycle (`Habit
/// .cycleOccurrence`) the Habits tab and the day calendar already use.
///
/// The structural problem this had to solve: `openHabitOccurrencesForReview`
/// filters to `status == .none` — the moment a row cycles to `.complete`,
/// it stops matching, so a naive implementation makes the row vanish
/// mid-review as you tap it. Fixed with a frozen snapshot
/// (`NightlyReviewView.frozenTodayHabitOccurrences`, captured once when the
/// Today step is entered) for *which rows render*, while each row's
/// *displayed status* is still re-derived live on every read
/// (`ScheduleReviewViewModel.refreshedHabitReviewOccurrences`) — a display
/// concern layered on top of the filter, not a weakening of it. The filter
/// itself is untouched and still runs fresh, unfrozen, wherever it actually
/// protects something: `markUnresolvedHabitOccurrencesAsMissed`'s sweep
/// calls `openHabitOccurrencesForReview` directly, not through the frozen
/// snapshot — see the spec's "What actually protects the untimed path."
final class NightlyReviewHabitCycleTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth))!
    }

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: Habit.self, HabitLog.self, ScheduledBlock.self, TaskItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    /// `startDate` is the review day itself, deliberately — same reasoning
    /// as `MissedHabitVisibilityAndReviewCutoffTests`'s 9pm-habit test:
    /// `openHabitOccurrencesForReview` scans backward up to 400 days for
    /// *any* unresolved occurrence, so a habit with earlier history would
    /// let an assertion pass for the wrong day's occurrence.
    private func makeHabit(name: String, mode: HabitOccurrenceTimeMode, startDate: Date) -> Habit {
        let habit = Habit(name: name, startDate: startDate, daysOfWeek: [1, 2, 3, 4, 5, 6, 7], idealTimesOfDay: [540])
        habit.occurrenceTimeModesRaw = [mode.rawValue]
        context.insert(habit)
        return habit
    }

    // MARK: - Full four-state cycle

    /// `NightlyReviewView.cycleHabitReviewOccurrence` is a thin delegation
    /// to `Habit.cycleOccurrence` — no logic of its own beyond that, so
    /// this pins the invariant it relies on, same reasoning as the
    /// identical test added for the day calendar's own toggle.
    func test_cycleOccurrence_advancesThroughAllFourStates_andWraps() {
        let reviewDay = day(2026, 9, 9)
        let habit = makeHabit(name: "Read", mode: .midday, startDate: reviewDay)

        let s1 = habit.cycleOccurrence(0, on: reviewDay, context: context, calendar: calendar)
        XCTAssertEqual(s1, .complete)
        let s2 = habit.cycleOccurrence(0, on: reviewDay, context: context, calendar: calendar)
        XCTAssertEqual(s2, .missed)
        let s3 = habit.cycleOccurrence(0, on: reviewDay, context: context, calendar: calendar)
        XCTAssertEqual(s3, .excused)
        let s4 = habit.cycleOccurrence(0, on: reviewDay, context: context, calendar: calendar)
        XCTAssertEqual(s4, .none)
        let s5 = habit.cycleOccurrence(0, on: reviewDay, context: context, calendar: calendar)
        XCTAssertEqual(s5, .complete, "a fifth tap must wrap back around")
    }

    // MARK: - Row stays visible after being cycled

    /// The core fix, verified fail-then-pass: with `ScheduleReviewViewModel
    /// .refreshedHabitReviewOccurrences` temporarily changed to re-apply
    /// the `status == .none` filter (collapsing the frozen-snapshot design
    /// back to "just call the live function again"), this test failed —
    /// the row disappeared the moment it was cycled to `.complete`,
    /// reproducing the exact "vanishes mid-review" bug this change closes.
    /// Restored the real implementation and reran: green. Both via
    /// `xcodebuild test`.
    func test_refreshedHabitReviewOccurrences_rowStaysVisible_afterCycling() {
        let reviewDay = day(2026, 9, 9)
        let habit = makeHabit(name: "Stretch", mode: .midday, startDate: reviewDay)

        // Freeze while still .none — the real entry-time snapshot.
        let frozen = ScheduleReviewViewModel.openHabitOccurrencesForReview(habits: [habit], context: context, upTo: reviewDay.addingTimeInterval(86400))
        XCTAssertEqual(frozen.count, 1, "sanity check: the occurrence must actually be in the frozen snapshot to begin with")

        // Cycle it forward, as a tap would.
        habit.cycleOccurrence(0, on: reviewDay, context: context, calendar: calendar)

        let refreshed = ScheduleReviewViewModel.refreshedHabitReviewOccurrences(frozen: frozen, context: context, calendar: calendar)

        XCTAssertEqual(refreshed.count, 1, "the row must still be there — not filtered back out just because it's no longer .none")
        XCTAssertEqual(refreshed.first?.status, .complete, "and it must show the state it was actually cycled to, not the frozen .none")
    }

    /// The other half of the same guarantee: cycling *again* (complete ->
    /// missed) must keep updating the same row in place, not just survive
    /// the first cycle.
    func test_refreshedHabitReviewOccurrences_rowKeepsUpdating_acrossMultipleCycles() {
        let reviewDay = day(2026, 9, 9)
        let habit = makeHabit(name: "Journal", mode: .midday, startDate: reviewDay)
        let frozen = ScheduleReviewViewModel.openHabitOccurrencesForReview(habits: [habit], context: context, upTo: reviewDay.addingTimeInterval(86400))

        habit.cycleOccurrence(0, on: reviewDay, context: context, calendar: calendar) // -> complete
        habit.cycleOccurrence(0, on: reviewDay, context: context, calendar: calendar) // -> missed

        let refreshed = ScheduleReviewViewModel.refreshedHabitReviewOccurrences(frozen: frozen, context: context, calendar: calendar)

        XCTAssertEqual(refreshed.first?.status, .missed)
    }

    // MARK: - Resolved occurrences don't appear in the next (fresh, unfrozen) review

    func test_openHabitOccurrencesForReview_completedOccurrence_doesNotAppear() {
        let reviewDay = day(2026, 9, 9)
        let habit = makeHabit(name: "Meditate", mode: .midday, startDate: reviewDay)
        habit.cycleOccurrence(0, on: reviewDay, context: context, calendar: calendar) // -> complete

        let result = ScheduleReviewViewModel.openHabitOccurrencesForReview(habits: [habit], context: context, upTo: reviewDay.addingTimeInterval(86400))

        XCTAssertFalse(result.contains { $0.habit.id == habit.id })
    }

    func test_openHabitOccurrencesForReview_missedOccurrence_doesNotAppear() {
        let reviewDay = day(2026, 9, 9)
        let habit = makeHabit(name: "Floss", mode: .midday, startDate: reviewDay)
        habit.cycleOccurrence(0, on: reviewDay, context: context, calendar: calendar) // -> complete
        habit.cycleOccurrence(0, on: reviewDay, context: context, calendar: calendar) // -> missed

        let result = ScheduleReviewViewModel.openHabitOccurrencesForReview(habits: [habit], context: context, upTo: reviewDay.addingTimeInterval(86400))

        XCTAssertFalse(result.contains { $0.habit.id == habit.id })
    }

    func test_openHabitOccurrencesForReview_excusedOccurrence_doesNotAppear() {
        let reviewDay = day(2026, 9, 9)
        let habit = makeHabit(name: "Water plants", mode: .midday, startDate: reviewDay)
        habit.cycleOccurrence(0, on: reviewDay, context: context, calendar: calendar) // -> complete
        habit.cycleOccurrence(0, on: reviewDay, context: context, calendar: calendar) // -> missed
        habit.cycleOccurrence(0, on: reviewDay, context: context, calendar: calendar) // -> excused

        let result = ScheduleReviewViewModel.openHabitOccurrencesForReview(habits: [habit], context: context, upTo: reviewDay.addingTimeInterval(86400))

        XCTAssertFalse(result.contains { $0.habit.id == habit.id })
    }

    // MARK: - The sweep's interaction with an explicit status

    /// The actual protection, per the spec's own warning ("the untimed
    /// path is protected by the `status == .none` filter... NOT by the
    /// guard inside the sweep loop"): an occurrence explicitly set to
    /// `.excused` must never even reach the sweep's candidate list, since
    /// that's what the sweep loop iterates over.
    ///
    /// Verified fail-then-pass: with the filter's guard temporarily
    /// widened to also admit `.excused` (simulating "weakening the filter
    /// to solve the display problem instead of freezing a snapshot" — the
    /// exact wrong fix this task warned against), this test failed — the
    /// excused occurrence appeared in the sweep's own candidate list,
    /// meaning it would have been overwritten. Restored the real filter
    /// and reran: green. Both via `xcodebuild test`.
    func test_excusedOccurrence_neverReachesTheSweepsCandidateList() {
        let reviewDay = day(2026, 9, 9)
        let habit = makeHabit(name: "Take vitamins", mode: .midday, startDate: reviewDay)
        habit.cycleOccurrence(0, on: reviewDay, context: context, calendar: calendar) // -> complete
        habit.cycleOccurrence(0, on: reviewDay, context: context, calendar: calendar) // -> missed
        habit.cycleOccurrence(0, on: reviewDay, context: context, calendar: calendar) // -> excused

        let sweepCandidates = ScheduleReviewViewModel.openHabitOccurrencesForReview(habits: [habit], context: context, upTo: reviewDay.addingTimeInterval(86400))

        XCTAssertFalse(sweepCandidates.contains { $0.habit.id == habit.id }, "an excused occurrence must never reach the sweep's own candidate list")

        // Directly confirm the persisted status is untouched, too — not
        // just absent from the candidate list.
        let status = habit.occurrenceStatus(0, on: reviewDay, context: context, calendar: calendar)
        XCTAssertEqual(status, .excused, "the sweep must never get the chance to overwrite an explicit .excused")
    }

    /// Same question, for a habit explicitly left `.missed` — the end
    /// state should be identical either way, and confirming this also
    /// confirms the sweep can't write `.missed` a second time on top of an
    /// already-`.missed` occurrence (the guard's own `status == .none`
    /// check would reject it even if it somehow reached the loop).
    func test_missedOccurrence_neverReachesTheSweepsCandidateList() {
        let reviewDay = day(2026, 9, 9)
        let habit = makeHabit(name: "Take out trash", mode: .midday, startDate: reviewDay)
        habit.cycleOccurrence(0, on: reviewDay, context: context, calendar: calendar) // -> complete
        habit.cycleOccurrence(0, on: reviewDay, context: context, calendar: calendar) // -> missed

        let sweepCandidates = ScheduleReviewViewModel.openHabitOccurrencesForReview(habits: [habit], context: context, upTo: reviewDay.addingTimeInterval(86400))

        XCTAssertFalse(sweepCandidates.contains { $0.habit.id == habit.id })
        XCTAssertEqual(habit.occurrenceStatus(0, on: reviewDay, context: context, calendar: calendar), .missed)
    }

    /// The other side of the same guarantee: an untouched `.none`
    /// occurrence must still be a sweep candidate, exactly as today — the
    /// filter change (there is none) must not have accidentally started
    /// excluding the case it's actually meant to admit.
    func test_untouchedNoneOccurrence_stillReachesTheSweepsCandidateList() {
        let reviewDay = day(2026, 9, 9)
        let habit = makeHabit(name: "Untouched habit", mode: .midday, startDate: reviewDay)

        let sweepCandidates = ScheduleReviewViewModel.openHabitOccurrencesForReview(habits: [habit], context: context, upTo: reviewDay.addingTimeInterval(86400))

        XCTAssertTrue(sweepCandidates.contains { $0.habit.id == habit.id }, "an untouched .none occurrence must still be swept, same as today")
    }
}
