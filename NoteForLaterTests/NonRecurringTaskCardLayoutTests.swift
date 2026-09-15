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
        TaskItem(title: title)
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
        XCTAssertEqual(TaskReviewCard.nonRecurringTimeSummaryText(task: task), "Not selected")
    }

    func test_nonRecurringTimeDecidedNo_readsNone_andDoesNotReportMissing() {
        let task = makeTask()
        task.durationDecided = true
        task.durationAnsweredYes = false
        task.estimatedMinutes = 0

        XCTAssertTrue(TaskReviewCard.isDurationConfigured(task: task, shelf: nil))
        XCTAssertEqual(TaskReviewCard.nonRecurringTimeSummaryText(task: task), "None")
        XCTAssertFalse(task.missingAttributeNames(consideringShelf: nil).contains("Duration"))
    }

    func test_nonRecurringTimeDecidedYes_readsDurationLabel() {
        let task = makeTask()
        task.durationDecided = true
        task.durationAnsweredYes = true
        task.estimatedMinutes = 30
        // 30 minutes is splittable (into 15s) — Divisible genuinely needs
        // its own answer here, same as the recurring row's own "Time" row.
        task.isDivisibleDecided = true
        task.isDivisible = false

        XCTAssertTrue(TaskReviewCard.isDurationConfigured(task: task, shelf: nil))
        XCTAssertEqual(TaskReviewCard.nonRecurringTimeSummaryText(task: task), "30 min")
    }

    func test_nonRecurringTimeUnconfigured_whenDivisibleAnsweredYesButSegmentNotPicked() {
        let task = makeTask()
        task.durationDecided = true
        task.durationAnsweredYes = true
        task.estimatedMinutes = 30
        task.isDivisibleDecided = true
        task.isDivisible = true
        task.minimumSegmentMinutes = 0

        XCTAssertFalse(TaskReviewCard.isDurationConfigured(task: task, shelf: nil))
        XCTAssertTrue(task.missingAttributeNames(consideringShelf: nil).contains("Divisible"))
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
        task.durationDecided = true
        task.durationAnsweredYes = true
        task.estimatedMinutes = 30
        task.isDivisibleDecided = true
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
        task.durationDecided = false
        task.durationAnsweredYes = false
        task.estimatedMinutes = 0
        task.isDivisibleDecided = false
        task.isDivisible = false
        task.minimumSegmentMinutes = 0
        task.startDate = nil
        task.startDatePicked = false

        snapshot.restore(into: task)

        XCTAssertTrue(task.dueDateDecided)
        XCTAssertEqual(task.dueDate, Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 17)))
        XCTAssertTrue(task.dueDatePicked)
        XCTAssertEqual(task.priority, .high)
        XCTAssertTrue(task.durationDecided)
        XCTAssertTrue(task.durationAnsweredYes)
        XCTAssertEqual(task.estimatedMinutes, 30)
        XCTAssertTrue(task.isDivisibleDecided)
        XCTAssertTrue(task.isDivisible)
        XCTAssertEqual(task.minimumSegmentMinutes, 15)
        XCTAssertEqual(task.startDate, Calendar.current.startOfDay(for: .now))
        XCTAssertTrue(task.startDatePicked)
    }
}
