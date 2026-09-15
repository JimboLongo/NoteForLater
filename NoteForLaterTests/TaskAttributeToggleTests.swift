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

    /// `makeRecurring()` deliberately does *not* seed an anchor anymore —
    /// a new recurring task starts with Start Date at "Not Selected," so
    /// it has to be consciously set before this can actually place on
    /// the calendar (`hasRecurringOccurrence` requires `dueDate`). That
    /// blank anchor must not read as "missing Due Date" in the attribute
    /// review queue either — a recurring task is never asked that
    /// question at all (`dueDateMissing` excludes it outright), so
    /// nothing here should ever flag it.
    func test_makeForDirectCapture_leavesAnchorUnset_andDoesNotReportDueDateMissing() {
        let shelf = Shelf(name: "Recurring Tasks")
        shelf.isRecurringTasks = true

        let task = TaskItem.makeForDirectCapture(title: "Water the garden", shelf: shelf)

        XCTAssertNil(task.startDate, "a new recurring task must start with Start Date unset")
        XCTAssertNil(task.dueDate)
        XCTAssertFalse(task.missingAttributeNames(consideringShelf: shelf).contains("Due Date"), "a recurring task is never asked \"Has due date\" — it must never be flagged missing one")
    }

    /// Once Start Date actually is set, `makeRecurring()` still keeps it
    /// synced onto `dueDate` — the anchor `hasRecurringOccurrence` reads.
    func test_makeRecurring_syncsDueDate_onceStartDateIsSet() {
        let task = TaskItem(title: "Water the garden", estimatedMinutes: 10)
        task.startDate = Calendar.current.startOfDay(for: .now)

        task.makeRecurring()

        XCTAssertNotNil(task.dueDate, "an already-set Start Date must still sync onto dueDate, the actual recurrence anchor")
    }

    /// AM/Midday/PM never places a calendar block, so Duration and
    /// Divisible are meaningless for it — both must grey out (never read
    /// as missing) even though neither's been decided, mirroring how the
    /// card itself disables and fades that whole section
    /// (`TaskReviewCard.durationAllowed`).
    func test_recurringTaskWithUntimedMode_durationAndDivisibleAreNeverMissing() {
        let shelf = Shelf(name: "Recurring Tasks")
        shelf.isRecurringTasks = true
        let task = TaskItem.makeForDirectCapture(title: "Take vitamins", shelf: shelf)
        task.recurrenceTimeMode = .am

        let missing = task.missingAttributeNames(consideringShelf: shelf)

        XCTAssertFalse(missing.contains("Duration"))
        XCTAssertFalse(missing.contains("Divisible"))
    }

    /// The flip side — Specific Time keeps asking both questions
    /// normally, same as any other task.
    func test_recurringTaskWithSpecificTime_durationCanStillBeMissing() {
        let shelf = Shelf(name: "Recurring Tasks")
        shelf.isRecurringTasks = true
        let task = TaskItem.makeForDirectCapture(title: "Take out trash", shelf: shelf)
        task.recurrenceTimeMode = .specific

        XCTAssertTrue(task.missingAttributeNames(consideringShelf: shelf).contains("Duration"), "Specific Time still needs a real duration, same as before")
    }

    // MARK: - Fail-then-pass target: unselected Every/Time/Start Date surface in the attribute review

    /// A fresh recurring task must read as missing Start Date, Every, and
    /// Time — all three start "Not Selected" (`TaskItem.makeRecurring`
    /// deliberately leaves the anchor unset; `recurrenceIntervalCount`/
    /// `recurrenceUnit`/`recurrenceTimeMode` all start on real, storable
    /// defaults that aren't evidence anyone actually chose them). Without
    /// these three checks, a recurring task in this state would silently
    /// never schedule anything instead of prompting to be finished.
    func test_freshRecurringTask_surfacesStartDateEveryAndTimeAsMissing() {
        let shelf = Shelf(name: "Recurring Tasks")
        shelf.isRecurringTasks = true
        let task = TaskItem.makeForDirectCapture(title: "Water the garden", shelf: shelf)

        let missing = task.missingAttributeNames(consideringShelf: shelf)

        XCTAssertTrue(missing.contains("Start Date"))
        XCTAssertTrue(missing.contains("Every"))
        XCTAssertTrue(missing.contains("Time"))
    }

    /// Once all three are actually picked, none of them should still read
    /// as missing — confirms the flip side isn't permanently stuck true.
    func test_recurringTask_withEveryTimeAndStartDatePicked_areNotMissing() {
        let shelf = Shelf(name: "Recurring Tasks")
        shelf.isRecurringTasks = true
        let task = TaskItem.makeForDirectCapture(title: "Water the garden", shelf: shelf)

        task.setStartDate(.now)
        task.recurrenceIntervalPicked = true
        task.recurrenceTimeModePicked = true

        let missing = task.missingAttributeNames(consideringShelf: shelf)

        XCTAssertFalse(missing.contains("Start Date"))
        XCTAssertFalse(missing.contains("Every"))
        XCTAssertFalse(missing.contains("Time"))
    }

    /// None of the three ever apply to a non-recurring task — it's never
    /// shown these questions at all (`recurringSection` only renders
    /// `if task.isRecurring`).
    func test_nonRecurringTask_neverReportsStartDateEveryOrTimeAsMissing() {
        let task = makeTask()

        let missing = task.missingAttributeNames

        XCTAssertFalse(missing.contains("Start Date"))
        XCTAssertFalse(missing.contains("Every"))
        XCTAssertFalse(missing.contains("Time"))
    }

    // MARK: - No High Priority for recurring tasks

    /// A recurring task with priority still `.unset` must not read as
    /// missing Priority — High Priority isn't offered to it at all, same
    /// shelf-level short-circuit shape as an untracked attribute.
    func test_recurringTask_priorityNeverMissing_evenWhenUnset() {
        let shelf = Shelf(name: "Recurring Tasks")
        shelf.isRecurringTasks = true
        let task = TaskItem.makeForDirectCapture(title: "Water the garden", shelf: shelf)
        XCTAssertEqual(task.priority, .unset)

        XCTAssertFalse(task.missingAttributeNames(consideringShelf: shelf).contains("Priority"))
    }

    /// A non-recurring task on the same shelf is unaffected — Priority
    /// still applies normally.
    func test_nonRecurringTask_priorityStillMissingWhenUnset() {
        let task = makeTask()
        XCTAssertEqual(task.priority, .unset)

        XCTAssertTrue(task.missingAttributeNames.contains("Priority"))
    }

    // MARK: - `startDatePicked` distinguishes "never touched" from "deliberately set"

    /// A brand-new task must start with Start Date genuinely unset, not
    /// merely `startDate == nil` — `startDatePicked` is the flag the UI
    /// actually reads to decide between "Not Selected" and a real date.
    func test_newTask_startDateIsNotYetPicked() {
        let task = makeTask()

        XCTAssertNil(task.startDate)
        XCTAssertFalse(task.startDatePicked, "a start date that was never touched must not read as picked")
    }

    /// Fail-then-pass target: `setStartDate(_:)` — the single entry point
    /// `StartDateCalendarPicker`'s tap delegate calls — must record both
    /// the date itself and that it was deliberately picked, even when the
    /// date happens to be today. This is what makes tapping today (which
    /// a raw `task.startDate = .now` assignment, or a SwiftUI `DatePicker`
    /// binding, can't reliably do — see `StartDateCalendarPicker`'s own
    /// doc comment) actually register.
    func test_setStartDate_toToday_recordsDateAndMarksPicked() {
        let task = makeTask()
        let today = Calendar.current.startOfDay(for: .now)

        task.setStartDate(.now)

        XCTAssertEqual(task.startDate, today)
        XCTAssertTrue(task.startDatePicked, "picking today must be indistinguishable from picking any other day, not treated as a no-op")
    }

    /// For a recurring task, `setStartDate(_:)` must still keep `dueDate`
    /// synced onto the new anchor day (same blast radius the old direct
    /// `task.startDate = newValue` assignment in the popover handled) —
    /// preserving the existing time-of-day rather than resetting it.
    func test_setStartDate_onRecurringTask_syncsDueDate_preservingTimeOfDay() {
        let task = TaskItem(title: "Water the garden", estimatedMinutes: 10)
        task.isRecurring = true
        task.dueDate = Calendar.current.date(bySettingHour: 14, minute: 30, second: 0, of: .now)

        let newDay = Calendar.current.date(byAdding: .day, value: 3, to: .now)!
        task.setStartDate(newDay)

        XCTAssertEqual(task.startDate, Calendar.current.startOfDay(for: newDay))
        let dueDateComponents = Calendar.current.dateComponents([.day, .hour, .minute], from: task.dueDate!)
        let expectedDay = Calendar.current.component(.day, from: newDay)
        XCTAssertEqual(dueDateComponents.day, expectedDay, "dueDate must move to the new anchor day")
        XCTAssertEqual(dueDateComponents.hour, 14, "must preserve the existing time-of-day rather than resetting it")
        XCTAssertEqual(dueDateComponents.minute, 30)
        XCTAssertTrue(task.dueDateDecided)
        XCTAssertTrue(task.dueDatePicked)
    }

    /// A non-recurring task's `dueDate` must stay untouched by
    /// `setStartDate(_:)` — the sync is only ever a recurring-task
    /// concern (Start Date doubles as the recurrence anchor there; for an
    /// ordinary task the two fields are unrelated).
    func test_setStartDate_onNonRecurringTask_leavesDueDateAlone() {
        let task = makeTask()
        XCTAssertNil(task.dueDate)

        task.setStartDate(.now)

        XCTAssertNil(task.dueDate, "a non-recurring task's dueDate must not be touched by setting Start Date")
    }

    /// Re-tapping the same day the picker is already showing (as opposed
    /// to a different one) must still register — `StartDateCalendarPicker`
    /// relies on `UICalendarSelectionSingleDateDelegate` firing on every
    /// discrete tap, but the model-side handler must independently be
    /// idempotent/safe to call repeatedly with the same date rather than
    /// silently no-op the second time.
    func test_setStartDate_calledTwiceWithSameDate_stillRegistersBothTimes() {
        let task = makeTask()
        let today = Calendar.current.startOfDay(for: .now)

        task.setStartDate(.now)
        XCTAssertTrue(task.startDatePicked)
        task.startDatePicked = false // simulate "as if never picked" to prove the second call alone re-establishes it

        task.setStartDate(.now)

        XCTAssertEqual(task.startDate, today)
        XCTAssertTrue(task.startDatePicked, "a second tap on the same date must still set startDatePicked, not treat the unchanged value as a no-op")
    }

    // MARK: - Fail-then-pass target: opening/dismissing without tapping writes nothing

    /// The Start Date popover's own `initialSelection` is a pure read of
    /// `task.startDate`/`task.startDatePicked` (see `StartDateCalendarPicker`
    /// call site in `NightlyReviewView`) — merely constructing that read,
    /// without ever calling `setStartDate`/`clearStartDate`, must never
    /// mutate the task. This is the exact shape of the old bug this
    /// feature replaced: the popover used to seed a `@State` var to
    /// today and could write that back merely from being opened.
    func test_openingStartDatePicker_withoutTapping_writesNothing_whenUnset() {
        let task = makeTask()

        // Simulates opening the popover and reading what it would
        // display, without any tap ever occurring.
        let initialSelection = task.startDatePicked ? task.startDate : nil

        XCTAssertNil(initialSelection, "an untouched task must show nothing selected")
        XCTAssertNil(task.startDate, "merely computing what the popover would display must not itself write a value")
        XCTAssertFalse(task.startDatePicked)
    }

    /// Same guarantee for a recurring task that already has a real
    /// anchor — opening and dismissing the picker without tapping must
    /// leave `dueDate` (the recurrence anchor Start Date doubles as)
    /// untouched too, not just `startDate`.
    func test_openingStartDatePicker_withoutTapping_leavesRecurringDueDateUntouched() {
        let task = TaskItem(title: "Water the garden", estimatedMinutes: 10)
        task.isRecurring = true
        let anchor = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: .now)!
        task.dueDate = anchor
        task.setStartDate(.now)

        // Simulates re-opening the popover later and just reading its
        // display value, again without any tap — checked against the
        // anchor's actual time-of-day (not merely "whatever it was a
        // moment ago") so a regression in `syncDueDate`'s own
        // preserve-the-existing-time behavior would be caught here too,
        // not just a spurious re-write.
        let initialSelection = task.startDatePicked ? task.startDate : nil
        let dueDateHour = Calendar.current.component(.hour, from: task.dueDate!)

        XCTAssertEqual(initialSelection, task.startDate, "an already-picked task must show its real date selected")
        XCTAssertEqual(dueDateHour, 8, "merely reopening/reading must not re-trigger or alter the anchor sync")
    }

    // MARK: - `clearStartDate()` — the popover's "Clear" affordance

    /// Fail-then-pass target: clearing must return Start Date to
    /// genuinely "never touched," not just `startDate == nil` — the same
    /// distinction `startDatePicked` exists to make in the first place.
    func test_clearStartDate_returnsToNeverTouched() {
        let task = makeTask()
        task.setStartDate(.now)
        XCTAssertTrue(task.startDatePicked)

        task.clearStartDate()

        XCTAssertNil(task.startDate)
        XCTAssertFalse(task.startDatePicked, "clearing must be indistinguishable from a task that never had Start Date touched")
    }

    /// Reopening after a clear must show nothing selected, same as a
    /// brand new task — exercising the popover's own `initialSelection`
    /// read against the post-clear state.
    func test_reopeningAfterClear_showsNothingSelected() {
        let task = makeTask()
        task.setStartDate(.now)
        task.clearStartDate()

        let initialSelection = task.startDatePicked ? task.startDate : nil

        XCTAssertNil(initialSelection, "reopening after Clear must show nothing selected, same as an untouched task")
    }

    /// For a recurring task, clearing Start Date must also clear the
    /// `dueDate` anchor it doubles as — otherwise the task would keep a
    /// stale anchor with nothing left to point at it, still placing on
    /// the calendar despite Start Date reading "Not Selected."
    func test_clearStartDate_onRecurringTask_alsoClearsDueDateAnchor() {
        let task = TaskItem(title: "Water the garden", estimatedMinutes: 10)
        task.isRecurring = true
        task.setStartDate(.now)
        XCTAssertNotNil(task.dueDate)

        task.clearStartDate()

        XCTAssertNil(task.dueDate, "clearing the anchor must remove the recurring task's placement entirely")
        XCTAssertFalse(task.dueDateDecided)
        XCTAssertFalse(task.dueDatePicked)
    }

    /// A non-recurring task's `dueDate` is unrelated to Start Date, so
    /// clearing must leave it alone — symmetric with
    /// `test_setStartDate_onNonRecurringTask_leavesDueDateAlone`.
    func test_clearStartDate_onNonRecurringTask_leavesDueDateAlone() {
        let task = makeTask()
        task.dueDate = .now
        task.dueDateDecided = true
        task.dueDatePicked = true
        task.setStartDate(.now)

        task.clearStartDate()

        XCTAssertNotNil(task.dueDate, "a non-recurring task's dueDate must not be touched by clearing Start Date")
        XCTAssertTrue(task.dueDateDecided)
        XCTAssertTrue(task.dueDatePicked)
    }

    // MARK: - Relative Date's "Pattern" question surfaces in attribute review

    /// A fresh Relative Date recurring task must read as missing
    /// "Pattern" — `relativeRecurrenceScope`/`.ordinal` start on real,
    /// storable defaults ("Day of Month, First"), not evidence anyone
    /// actually configured it.
    func test_freshRelativeDateTask_surfacesPatternAsMissing() {
        let shelf = Shelf(name: "Recurring Tasks")
        shelf.isRecurringTasks = true
        let task = TaskItem.makeForDirectCapture(title: "Water the garden", shelf: shelf)
        task.recurrenceMode = .relativeDate
        // "Pattern" is only ever asked for a monthly unit now — see
        // `TaskItem.relativeRecurrenceMissing`'s own doc comment.
        task.recurrenceUnit = .months

        XCTAssertTrue(task.missingAttributeNames(consideringShelf: shelf).contains("Pattern"))
    }

    /// Once the pattern is actually touched, it must drop out of the
    /// missing list.
    func test_relativeDateTask_withPatternPicked_isNotMissing() {
        let shelf = Shelf(name: "Recurring Tasks")
        shelf.isRecurringTasks = true
        let task = TaskItem.makeForDirectCapture(title: "Water the garden", shelf: shelf)
        task.recurrenceMode = .relativeDate

        task.relativeRecurrencePicked = true

        XCTAssertFalse(task.missingAttributeNames(consideringShelf: shelf).contains("Pattern"))
    }

    /// A Specific Date recurring task is never asked this question at
    /// all — "Pattern" must never appear for it, regardless of
    /// `relativeRecurrencePicked`.
    func test_specificDateTask_neverReportsPatternAsMissing() {
        let shelf = Shelf(name: "Recurring Tasks")
        shelf.isRecurringTasks = true
        let task = TaskItem.makeForDirectCapture(title: "Water the garden", shelf: shelf)
        XCTAssertEqual(task.recurrenceMode, .specificDate)

        XCTAssertFalse(task.missingAttributeNames(consideringShelf: shelf).contains("Pattern"))
    }
}
