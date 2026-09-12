import XCTest
@testable import NoteForLater

/// Coverage for making Next Step toggleable off (`TaskItem.nextStepDecided`/
/// `.nextStepAnsweredYes`) — same "decided" shape `dueDateDecided` already
/// established, since a bare `nextStep == ""` couldn't tell "never decided"
/// apart from "deliberately none," permanently flagging a task with no next
/// step needed as incomplete.
///
/// No `ModelContainer` needed — `TaskItem`/`Shelf` can be constructed and
/// read directly, same as `InboxEngagementTests` already does for this kind
/// of pure attribute-state check.
final class TaskAttributeToggleTests: XCTestCase {
    private func makeTask(title: String = "Task", shelf: Shelf? = nil) -> TaskItem {
        TaskItem(title: title, shelf: shelf, estimatedMinutes: 15)
    }

    /// Fail-then-pass target: a task with Next Step explicitly toggled
    /// off must not be reported missing, and must therefore drop out of
    /// the attribute review queue (`InboxView`'s own filter is just
    /// `isMissingAttributes`, so fixing the former is what fixes the
    /// latter — no separate queue-membership check needed).
    func test_nextStepToggledOff_isNotMissing_andDropsFromReviewQueue() {
        let task = makeTask()
        XCTAssertTrue(task.missingAttributeNames.contains("Next Step"), "an undecided next step should start out missing")

        // Every other attribute resolved (same pattern
        // `InboxEngagementTests` uses to build a "fully resolved" task),
        // so this isolates Next Step as the only thing that could still
        // be holding the queue-membership check open.
        task.dueDateDecided = true
        task.durationDecided = true
        task.isDivisibleDecided = true
        task.priority = .low
        XCTAssertTrue(task.isMissingAttributes, "still missing Next Step at this point")

        task.nextStepDecided = true
        task.nextStepAnsweredYes = false
        task.nextStep = ""

        XCTAssertFalse(task.missingAttributeNames.contains("Next Step"), "explicitly toggled off must not read as missing")
        XCTAssertFalse(task.isMissingAttributes, "with nothing else missing, the task must drop out of the review queue")
    }

    func test_togglingBackOn_restoresMissing_whenBlank() {
        let task = makeTask()
        task.nextStepDecided = true
        task.nextStepAnsweredYes = false
        task.nextStep = ""
        XCTAssertFalse(task.missingAttributeNames.contains("Next Step"))

        // Flipping back to "Yes" with nothing typed yet — the same
        // "answered Yes, still blank" state Duration's own toggle can
        // land on.
        task.nextStepAnsweredYes = true

        XCTAssertTrue(task.missingAttributeNames.contains("Next Step"), "Yes with a blank field must read as missing again")
    }

    func test_realNextStepText_isNotMissing() {
        let task = makeTask()
        task.nextStepDecided = true
        task.nextStepAnsweredYes = true
        task.nextStep = "Call the office"

        XCTAssertFalse(task.missingAttributeNames.contains("Next Step"))
    }

    /// The shelf-level gate and the task-level "No" answer are
    /// independent — a shelf that doesn't track Next Step at all must
    /// stay unaffected by whatever `nextStepDecided`/`nextStepAnsweredYes`
    /// happen to say, exactly as it already behaves for due date/duration.
    func test_shelfNotTrackingNextStep_isUnaffectedByDecidedState() {
        let shelf = Shelf(name: "Kitchen")
        shelf.hasNextStep = false
        let task = makeTask(shelf: shelf)

        // Completely undecided — on a shelf that tracked it, this would
        // be missing.
        XCTAssertFalse(task.missingAttributeNames(consideringShelf: shelf).contains("Next Step"), "a shelf that doesn't track Next Step must never call it missing")

        // Decided "No" shouldn't matter either — same answer, same result.
        task.nextStepDecided = true
        task.nextStepAnsweredYes = false
        XCTAssertFalse(task.missingAttributeNames(consideringShelf: shelf).contains("Next Step"))
    }

    /// `ShelfListView.TaskRow`'s own "omit the added-date for a recurring
    /// task" rule — the hourglass label is meaningless once `createdAt`
    /// has nothing to do with the occurrence actually coming up.
    func test_recurringTask_omitsAddedAgeInShelfListRow() {
        let ordinaryTask = makeTask()
        XCTAssertTrue(TaskRow(task: ordinaryTask, showsScheduledBadge: true).showsAddedAge)

        let recurringTask = makeTask()
        recurringTask.isRecurring = true
        XCTAssertFalse(TaskRow(task: recurringTask, showsScheduledBadge: true).showsAddedAge)
    }

    // MARK: - Recurring Tasks shelf defaults new tasks to isRecurring

    /// Fail-then-pass target: a task captured directly onto the Recurring
    /// Tasks shelf (`Shelf.isRecurringTasks`) must default `isRecurring`
    /// on — same factory `ShelfListView.addTask()` actually calls, not a
    /// re-implementation of its logic.
    func test_taskCreatedOnRecurringTasksShelf_defaultsToRecurring() {
        let shelf = Shelf(name: "Recurring Tasks")
        shelf.isRecurringTasks = true

        let task = TaskItem.makeForDirectCapture(title: "Water the garden", shelf: shelf)

        XCTAssertTrue(task.isRecurring)
    }

    func test_taskCreatedOnOrdinaryShelf_doesNotDefaultToRecurring() {
        let shelf = Shelf(name: "Errands")

        let task = TaskItem.makeForDirectCapture(title: "Call the office", shelf: shelf)

        XCTAssertFalse(task.isRecurring)
    }

    /// The default must be a starting point, not a lock — toggling it
    /// back off (what the "Recurring?" toggle on the task's own card
    /// does) has to stick.
    func test_defaultRecurring_canBeToggledOff_andSticks() {
        let shelf = Shelf(name: "Recurring Tasks")
        shelf.isRecurringTasks = true
        let task = TaskItem.makeForDirectCapture(title: "Water the garden", shelf: shelf)
        XCTAssertTrue(task.isRecurring)

        task.isRecurring = false

        XCTAssertFalse(task.isRecurring)
    }

    /// `makeRecurring()` must seed a real anchor, not just flip the flag
    /// — otherwise the task would silently read as "missing Due Date" in
    /// the attribute review queue (see `makeRecurring`'s own doc comment)
    /// instead of surfacing the Start Date question it's actually meant
    /// to ask.
    func test_makeForDirectCapture_seedsAnchor_soDueDateIsNotReportedMissing() {
        let shelf = Shelf(name: "Recurring Tasks")
        shelf.isRecurringTasks = true

        let task = TaskItem.makeForDirectCapture(title: "Water the garden", shelf: shelf)

        XCTAssertNotNil(task.startDate)
        XCTAssertNotNil(task.dueDate)
        XCTAssertFalse(task.missingAttributeNames(consideringShelf: shelf).contains("Due Date"))
    }
}
