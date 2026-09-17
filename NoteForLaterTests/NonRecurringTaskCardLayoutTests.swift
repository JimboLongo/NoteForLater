import XCTest
import SwiftData
@testable import NoteForLater

/// Coverage for the compact non-recurring task card (`TaskReviewCard
/// .cardScrollBody`'s `else` branch) — the same "each row shows its answer,
/// not its controls" redesign `RecurringTaskCardLayoutTests` covers for the
/// recurring card, applied here to "Due"/"Starts"/"Time"/"Priority".
/// `TaskReviewCard` itself isn't constructible here for the same reason
/// noted there — this exercises the pulled-out `internal` predicates and
/// summary-text functions instead.
final class NonRecurringTaskCardLayoutTests: XCTestCase {
    private func makeTask(title: String = "Buy groceries") -> TaskItem {
        let task = TaskItem(title: title)
        // Next Step answered ("None") so it drops out of the seeding
        // question entirely. It became the *first* row in `scrollBodyOrder`
        // when it moved out of `cardHeader`, so an unanswered one would seed
        // open ahead of whatever each test below is actually about. Answered
        // here rather than letting every expectation shift by one row; that
        // it seeds first when unanswered is pinned separately.
        task.nextStepDecided = true
        return task
    }

    // MARK: - "Due" row: the undecided-vs-decided-as-none distinction

    /// A fresh task has never touched "Has due date" at all.
    func test_dueUndecided_readsNotSelected_andReportsMissing() {
        let task = makeTask()

        XCTAssertFalse(TaskReviewCard.isDueConfigured(task: task, shelf: nil))
        XCTAssertEqual(TaskReviewCard.dueSummaryText(task: task, shelf: nil), "Not selected")
        XCTAssertTrue(task.missingAttributeNames(consideringShelf: nil).contains("Due Date"))
    }

    /// The moment right after tapping "Yes" and before a real date is
    /// picked — `dueDate` already holds the `.now` placeholder
    /// `dueDateAnswer`'s `set` seeds it with, but `dueDatePicked` is still
    /// false. Must read the same as fully undecided, not as a real date.
    func test_dueDecidedYesButNotYetPicked_readsNotSelected_andReportsMissing() {
        let task = makeTask()
        task.dueDateDecided = true
        task.dueDate = .now
        task.dueDatePicked = false

        XCTAssertFalse(TaskReviewCard.isDueConfigured(task: task, shelf: nil))
        XCTAssertEqual(TaskReviewCard.dueSummaryText(task: task, shelf: nil), "Not selected")
        XCTAssertTrue(task.missingAttributeNames(consideringShelf: nil).contains("Due Date"))
    }

    /// Fail-then-pass target — this is exactly the state a "collapse
    /// undecided and none into one display bucket" bug would get wrong:
    /// a real, explicit "no due date" answer, not an absence of one.
    func test_dueDecidedAsNone_readsNone_andDoesNotReportMissing() {
        let task = makeTask()
        task.dueDateDecided = true
        task.dueDate = nil
        task.dueDatePicked = false

        XCTAssertTrue(TaskReviewCard.isDueConfigured(task: task, shelf: nil))
        XCTAssertEqual(TaskReviewCard.dueSummaryText(task: task, shelf: nil), "None")
        XCTAssertFalse(task.missingAttributeNames(consideringShelf: nil).contains("Due Date"))
    }

    func test_dueDecidedAndPicked_readsTheDate() {
        let task = makeTask()
        task.dueDateDecided = true
        task.dueDate = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 17))
        task.dueDatePicked = true

        XCTAssertTrue(TaskReviewCard.isDueConfigured(task: task, shelf: nil))
        XCTAssertEqual(TaskReviewCard.dueSummaryText(task: task, shelf: nil), "Thu, Sep 17, 2026")
    }

    // MARK: - "Time" row (non-recurring): Duration + Divisible, same three states

    func test_nonRecurringTimeUndecided_readsNotSelected() {
        let task = makeTask()

        XCTAssertFalse(TaskReviewCard.isDurationConfigured(task: task, shelf: nil))
        XCTAssertEqual(TaskReviewCard.durationSummaryText(task: task), "Not selected")
    }

    func test_nonRecurringTimeDecidedNo_readsNone_andDoesNotReportMissing() {
        let task = makeTask()
        task.durationPicked = true
        task.estimatedMinutes = 0

        XCTAssertTrue(TaskReviewCard.isDurationConfigured(task: task, shelf: nil))
        XCTAssertEqual(TaskReviewCard.durationSummaryText(task: task), "None")
        XCTAssertFalse(task.missingAttributeNames(consideringShelf: nil).contains("Duration"))
    }

    func test_nonRecurringTimeDecidedYes_readsDurationLabel() {
        let task = makeTask()
        task.durationPicked = true
        task.estimatedMinutes = 30
        // 30 minutes is splittable (into 15s) — Divisible genuinely needs
        // its own answer here, same as the recurring row's own "Time" row.
        task.divisiblePicked = true
        task.isDivisible = false

        XCTAssertTrue(TaskReviewCard.isDurationConfigured(task: task, shelf: nil))
        XCTAssertEqual(TaskReviewCard.durationSummaryText(task: task), "30 min")
    }

    /// Replaces a test for the old "Divisible answered Yes but no segment
    /// size picked yet" state, which the single-wheel redesign made
    /// unreachable: `TaskItem.selectDivisibleSegment` is now the only way
    /// to answer, and it derives `isDivisible` from the segment value
    /// (`minutes > 0`), so "divisible with no segment" can't be produced.
    /// What remains worth asserting is the live half of that case — a
    /// splittable duration whose Divisible question hasn't been touched
    /// at all is still unconfigured and still reported missing.
    func test_divisibleUnconfigured_whenAtOrAboveThresholdButUntouched() {
        let task = makeTask()
        task.durationPicked = true
        task.estimatedMinutes = 60
        XCTAssertTrue(TaskReviewCard.showsDivisibleRow(task: task), "sanity: 60 minutes shows the Divisible row")

        XCTAssertTrue(TaskReviewCard.isDurationConfigured(task: task, shelf: nil), "Duration is its own row now and is answered")
        XCTAssertFalse(TaskReviewCard.isDivisibleConfigured(task: task, shelf: nil))
        XCTAssertTrue(task.missingAttributeNames(consideringShelf: nil).contains("Divisible"))
    }

    /// The counterpart short-circuit: a duration with no valid segment
    /// size at all leaves the wheel with "Not Divisible" as its only
    /// option, so Divisible isn't a real question and must not be flagged
    /// — even completely untouched.
    func test_divisibleNotMissing_whenDurationHasNoValidSegments() {
        let task = makeTask()
        task.durationPicked = true
        task.estimatedMinutes = 70
        XCTAssertTrue(TaskItem.validSegmentOptions(for: 70).isEmpty, "sanity: 70 clears the hour bar but has no valid segment size")

        XCTAssertFalse(task.missingAttributeNames(consideringShelf: nil).contains("Divisible"))
        XCTAssertTrue(TaskReviewCard.isDurationConfigured(task: task, shelf: nil))
    }

    // MARK: - "Priority" row: a value row, not a Yes/No pair

    /// Same four-case `Priority` enum as before this row existed — this
    /// only changes how it's displayed/edited, not the stored type.
    func test_priorityUnset_readsNotSelected_andReportsMissing() {
        let task = makeTask()

        XCTAssertFalse(TaskReviewCard.isPriorityConfigured(task: task, shelf: nil))
        XCTAssertEqual(TaskReviewCard.prioritySummaryText(task: task), "Not selected")
        XCTAssertTrue(task.missingAttributeNames(consideringShelf: nil).contains("Priority"))
    }

    func test_priorityHigh_readsHigh() {
        let task = makeTask()
        task.priority = .high

        XCTAssertTrue(TaskReviewCard.isPriorityConfigured(task: task, shelf: nil))
        XCTAssertEqual(TaskReviewCard.prioritySummaryText(task: task), "High")
    }

    /// `.low` and legacy/AI-ranked `.medium` both read as "Low" — neither
    /// is reachable/distinguishable from this row's own control, exactly
    /// like the Yes/No toggle it replaced.
    func test_priorityLowOrMedium_readsLow() {
        let task = makeTask()
        task.priority = .low
        XCTAssertEqual(TaskReviewCard.prioritySummaryText(task: task), "Low")

        task.priority = .medium
        XCTAssertEqual(TaskReviewCard.prioritySummaryText(task: task), "Low")
    }

    // MARK: - Start Date is optional metadata for a non-recurring task, not a required one

    /// Unlike a recurring task's anchor, an unset Start Date is a
    /// legitimate, complete answer for a non-recurring one — it must
    /// never surface in `missingAttributeNames` regardless of
    /// `startDatePicked`.
    func test_nonRecurringTask_startDateNeverReportsMissing() {
        let task = makeTask()
        XCTAssertFalse(task.missingAttributeNames(consideringShelf: nil).contains("Start Date"))

        task.setStartDate(.now)
        XCTAssertFalse(task.missingAttributeNames(consideringShelf: nil).contains("Start Date"))
    }

    // MARK: - Fail-then-pass target: `TaskEditSnapshot` round-trips every non-recurring field this restructure touches

    func test_taskEditSnapshot_roundTripsEveryNonRecurringCardField() {
        let task = TaskItem(title: "Original", estimatedMinutes: 10)
        task.dueDateDecided = true
        task.dueDate = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 17))
        task.dueDatePicked = true
        task.priority = .high
        task.durationPicked = true
        task.estimatedMinutes = 30
        task.divisiblePicked = true
        task.isDivisible = true
        task.minimumSegmentMinutes = 15
        task.startDate = Calendar.current.startOfDay(for: .now)
        task.startDatePicked = true

        let snapshot = TaskEditSnapshot(task)

        // Scramble every field, including into the other two states
        // "Due" itself distinguishes (decided-as-none here).
        task.dueDateDecided = true
        task.dueDate = nil
        task.dueDatePicked = false
        task.priority = .unset
        task.durationPicked = false
        task.durationPicked = true
        task.estimatedMinutes = 0
        task.divisiblePicked = false
        task.isDivisible = false
        task.minimumSegmentMinutes = 0
        task.startDate = nil
        task.startDatePicked = false

        snapshot.restore(into: task)

        XCTAssertTrue(task.dueDateDecided)
        XCTAssertEqual(task.dueDate, Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 17)))
        XCTAssertTrue(task.dueDatePicked)
        XCTAssertEqual(task.priority, .high)
        XCTAssertTrue(task.durationPicked)
        XCTAssertTrue(task.durationPicked)
        XCTAssertEqual(task.estimatedMinutes, 30)
        XCTAssertTrue(task.divisiblePicked)
        XCTAssertTrue(task.isDivisible)
        XCTAssertEqual(task.minimumSegmentMinutes, 15)
        XCTAssertEqual(task.startDate, Calendar.current.startOfDay(for: .now))
        XCTAssertTrue(task.startDatePicked)
    }

    // MARK: - Auto-collapse: initialExpandedRow (non-recurring)

    func test_initialExpandedRow_nonRecurring_freshTask_seedsDue() {
        let task = makeTask()

        XCTAssertEqual(TaskReviewCard.initialExpandedRow(task: task, shelf: nil, segmentOptions: []), .due)
    }

    /// Due answered as a real "No" (decided-as-none, not just absent) —
    /// must be treated as fully answered and skipped past. Lands on
    /// `.time`, not `.canStartBy`: `startDateMissing` is `isRecurring &&
    /// !startDatePicked` — Start Date is never actually a gate for a
    /// non-recurring task at all, so `.canStartBy` is always pre-configured
    /// and never itself the seed here.
    func test_initialExpandedRow_nonRecurring_dueAnsweredNo_seedsDuration() {
        let task = makeTask()
        task.dueDateDecided = true
        task.dueDate = nil

        XCTAssertEqual(TaskReviewCard.initialExpandedRow(task: task, shelf: nil, segmentOptions: []), .duration)
    }

    func test_initialExpandedRow_nonRecurring_everythingAnswered_seedsNil() {
        let task = makeTask()
        task.dueDateDecided = true
        task.dueDate = nil
        task.startDatePicked = true
        task.durationPicked = true
        task.priority = .low

        XCTAssertNil(TaskReviewCard.initialExpandedRow(task: task, shelf: nil, segmentOptions: []))
    }

    // MARK: - Auto-collapse: Priority is a single-control row, collapses on either answer

    func test_priorityUnconfigured_thenConfiguredEitherWay() {
        let task = makeTask()
        XCTAssertFalse(TaskReviewCard.isPriorityConfigured(task: task, shelf: nil))

        task.priority = .low
        XCTAssertTrue(TaskReviewCard.isPriorityConfigured(task: task, shelf: nil), "'No' (low) is just as complete an answer as 'Yes' (high) — nothing further to pick either way")

        task.priority = .unset
        task.priority = .high
        XCTAssertTrue(TaskReviewCard.isPriorityConfigured(task: task, shelf: nil))
    }

    // MARK: - Auto-collapse: Due "No" is a complete, terminal answer

    /// "No" needs no calendar tap to follow it (unlike "Yes") — proving
    /// it alone satisfies `isDueConfigured`, which is what lets it
    /// self-collapse the row without waiting on any further control.
    func test_dueAnsweredNo_isFullyConfigured_noFurtherPickNeeded() {
        let task = makeTask()
        task.dueDateDecided = true
        task.dueDate = nil
        task.dueDatePicked = false

        XCTAssertTrue(TaskReviewCard.isDueConfigured(task: task, shelf: nil))
    }

    // MARK: - Auto-collapse: initialExpandedRows — new vs. existing task

    /// A brand-new non-recurring task opens with every row expanded at
    /// once, regardless of anything already answered.
    func test_initialExpandedRows_nonRecurring_newTask_seedsEveryRow_evenIfSomeAlreadyAnswered() {
        let task = makeTask()
        task.priority = .high // already answered — must not shrink the seeded set

        let rows = TaskReviewCard.initialExpandedRows(task: task, shelf: nil, segmentOptions: [], isNewlyCreated: true)

        XCTAssertEqual(rows, [.nextStep, .due, .canStartBy, .duration, .priority])
    }

    /// A reopened, fully-configured non-recurring task opens fully
    /// collapsed.
    func test_initialExpandedRows_nonRecurring_existingTask_fullyConfigured_seedsNothing() {
        let task = makeTask()
        task.dueDateDecided = true
        task.dueDate = nil
        task.durationPicked = true
        task.priority = .low

        let rows = TaskReviewCard.initialExpandedRows(task: task, shelf: nil, segmentOptions: [], isNewlyCreated: false)

        XCTAssertTrue(rows.isEmpty)
    }

    /// A reopened task with exactly one field left unanswered opens with
    /// only that field expanded.
    func test_initialExpandedRows_nonRecurring_existingTask_oneUnanswered_seedsOnlyThatRow() {
        let task = makeTask()
        task.dueDateDecided = true
        task.dueDate = nil
        task.durationPicked = true
        // Priority left unanswered.

        let rows = TaskReviewCard.initialExpandedRows(task: task, shelf: nil, segmentOptions: [], isNewlyCreated: false)

        XCTAssertEqual(rows, [.priority])
    }

    /// Filling in Priority on a new task would collapse only that row —
    /// same mechanism as the recurring-card equivalent test.
    func test_fillingPriorityOnNewTask_wouldCollapseOnlyPriority() {
        let task = makeTask()
        let seeded = TaskReviewCard.initialExpandedRows(task: task, shelf: nil, segmentOptions: [], isNewlyCreated: true)
        XCTAssertEqual(seeded, [.nextStep, .due, .canStartBy, .duration, .priority])

        task.priority = .high

        XCTAssertTrue(TaskReviewCard.isPriorityConfigured(task: task, shelf: nil), "this is the condition the Priority toggle's self-collapse checks before removing just .priority from expandedRows")
    }
}
