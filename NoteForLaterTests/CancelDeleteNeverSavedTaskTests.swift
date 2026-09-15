import XCTest
import SwiftData
@testable import NoteForLater

/// Coverage for `TaskCardSheet`'s Cancel behavior: a task that was just
/// created and never saved is deleted outright (along with everything
/// keyed to it) rather than rolled back — otherwise Cancel leaves an empty
/// shell sitting on the shelf, since the task is already inserted into the
/// model context the moment it's created, before its card ever opens.
///
/// `TaskCardSheet` itself isn't constructible here — `@Environment(\
/// .modelContext)` only resolves inside a live view hierarchy — so this
/// calls `TaskCardSheet.cancel(task:isNewlyCreated:snapshot:in:)` directly,
/// the `internal static func` pulled out specifically for this.
final class CancelDeleteNeverSavedTaskTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: TaskItem.self, ScheduledBlock.self, Shelf.self, RecurringTaskLog.self,
            PushedRecurringOccurrence.self, TaskCompletionRecord.self, Tag.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    private func makeTask(shelf: Shelf) -> TaskItem {
        let task = TaskItem(title: "New task", shelf: shelf)
        context.insert(task)
        return task
    }

    // MARK: - Never-saved task: Cancel deletes it and every cascaded record

    /// Fail-then-pass target. A recurring task configured (but never
    /// saved) in the card can produce a `ScheduledBlock`, a
    /// `RecurringTaskLog`, and a `PushedRecurringOccurrence` — all three
    /// keyed by a copied `taskID`, not a `@Relationship`, so nothing
    /// cleans them up automatically (see `TaskItem.deleteCascading`'s own
    /// doc comment). This also stands in for "already interacted with
    /// elsewhere" (e.g. dragged onto the calendar) — the `ScheduledBlock`
    /// here doesn't know or care that it came from the card's own
    /// controls rather than something else; `deleteCascading` cleans up
    /// whatever's actually associated with the task's id, regardless of
    /// origin.
    func test_cancel_neverSavedTask_deletesTaskAndEveryCascadedRecord() throws {
        let shelf = Shelf(name: "Recurring Tasks")
        context.insert(shelf)
        let task = makeTask(shelf: shelf)
        let taskID = task.id

        let block = ScheduledBlock(date: .now, startTime: .now, endTime: .now.addingTimeInterval(1800), task: task)
        context.insert(block)
        let log = RecurringTaskLog(taskID: taskID, date: .now)
        context.insert(log)
        let pushed = PushedRecurringOccurrence(taskID: taskID, originalDate: .now)
        context.insert(pushed)
        let completion = TaskCompletionRecord(taskID: taskID, title: task.title, createdAt: .now, completedAt: .now, pushedCount: 0)
        context.insert(completion)

        TaskCardSheet.cancel(task: task, isNewlyCreated: true, snapshot: nil, in: context)

        XCTAssertNil(try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })).first)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ScheduledBlock>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<RecurringTaskLog>(predicate: #Predicate { $0.taskID == taskID })).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<PushedRecurringOccurrence>(predicate: #Predicate { $0.taskID == taskID })).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<TaskCompletionRecord>(predicate: #Predicate { $0.taskID == taskID })).isEmpty)
    }

    /// A tag typed into a never-saved task's card is deliberately *not*
    /// treated as this task's data to clean up — see `Tag`'s own doc
    /// comment (an app-wide catalog, not a per-task association) and
    /// `TaskItem.deleteCascading`'s. Confirms the catalog entry survives
    /// even though the task that introduced it doesn't.
    func test_cancel_neverSavedTask_leavesSharedTagCatalogEntryAlone() throws {
        let shelf = Shelf(name: "Recurring Tasks")
        context.insert(shelf)
        let task = makeTask(shelf: shelf)
        task.tags = ["errand"]
        context.insert(Tag(name: "errand"))

        TaskCardSheet.cancel(task: task, isNewlyCreated: true, snapshot: nil, in: context)

        let tags = try context.fetch(FetchDescriptor<Tag>())
        XCTAssertEqual(tags.map(\.name), ["errand"])
    }

    // MARK: - Fail-then-pass target: cancelling after a save rolls back, never deletes

    func test_cancel_previouslySavedTask_rollsBackWithoutDeleting() throws {
        let shelf = Shelf(name: "To-Do")
        context.insert(shelf)
        let task = makeTask(shelf: shelf)
        task.priority = .high
        task.nextStep = "Call the vet"
        let snapshot = TaskEditSnapshot(task)

        // Edits made after the snapshot was captured — what a live
        // @Bindable session would have already written straight through.
        task.priority = .unset
        task.nextStep = ""
        let taskID = task.id

        TaskCardSheet.cancel(task: task, isNewlyCreated: false, snapshot: snapshot, in: context)

        let stillExists = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })).first
        XCTAssertNotNil(stillExists, "a previously-saved task must never be deleted by Cancel")
        XCTAssertEqual(task.priority, .high)
        XCTAssertEqual(task.nextStep, "Call the vet")
    }

    // MARK: - Reopening a saved task and cancelling doesn't delete

    /// Same mechanism as the previous test, but framed as the scenario
    /// the request named explicitly: open a task, Cancel, reopen it
    /// later, Cancel again — the second Cancel must still only roll
    /// back. There's nothing *stored* that "flips" between the two
    /// opens — `isNewlyCreated` is supplied fresh by the caller at each
    /// presentation (see that property's own doc comment) — so this
    /// confirms the reopened presentation, correctly marked
    /// `isNewlyCreated: false`, behaves identically to any other
    /// already-saved task.
    func test_reopeningASavedTask_thenCancelling_doesNotDelete() throws {
        let shelf = Shelf(name: "To-Do")
        context.insert(shelf)
        let task = makeTask(shelf: shelf)
        // First presentation: created via the plus button, then actually
        // saved (Move, Mark Complete, or just dismissed via the system
        // swipe — anything other than Cancel). Simulated here by simply
        // never calling `cancel(isNewlyCreated: true, ...)` for it at all.
        task.priority = .high
        let taskID = task.id

        // Second presentation: reopened later by tapping the now-visible
        // row — that call site never marks a task `isNewlyCreated`.
        let reopenSnapshot = TaskEditSnapshot(task)
        task.priority = .unset

        TaskCardSheet.cancel(task: task, isNewlyCreated: false, snapshot: reopenSnapshot, in: context)

        XCTAssertNotNil(try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })).first)
        XCTAssertEqual(task.priority, .high)
    }

    // MARK: - The review queue's own Cancel never deletes

    /// `TaskReviewQueueSheet` doesn't route through `TaskCardSheet` at
    /// all — it drives `TaskReviewCard` directly, and its own `cancel()`
    /// only ever calls `snapshot?.restore(into:)`, with no
    /// `isNewlyCreated`/delete concept anywhere in it (see that file).
    /// There is no shared code path for a behavior change here to leak
    /// into, so nothing there needed to change. What's worth pinning
    /// down on this side is the contract that protects against a future
    /// refactor accidentally wiring the queue through `TaskCardSheet`:
    /// `isNewlyCreated` defaults to `false`, so any caller that doesn't
    /// explicitly opt in — which every current caller except the shelf's
    /// plus button doesn't — gets the safe, roll-back-only behavior.
    func test_isNewlyCreated_defaultsToFalse() throws {
        let shelf = Shelf(name: "To-Do")
        context.insert(shelf)
        let task = makeTask(shelf: shelf)
        task.priority = .high
        let snapshot = TaskEditSnapshot(task)
        task.priority = .unset
        let taskID = task.id

        let sheet = TaskCardSheet(task: task, shelves: [shelf])
        XCTAssertFalse(sheet.isNewlyCreated)

        TaskCardSheet.cancel(task: task, isNewlyCreated: sheet.isNewlyCreated, snapshot: snapshot, in: context)

        XCTAssertNotNil(try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })).first)
    }
}
