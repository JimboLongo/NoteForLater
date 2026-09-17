import XCTest
import SwiftData
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
        task.durationPicked = true
        task.divisiblePicked = true
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

    // MARK: - 2-Minute Tasks shelf: Duration kept + defaulted; Divisible/Priority hidden

    /// The parallel default to `isRecurringTasks` — same call site
    /// (`makeForDirectCapture`), same "picked flag alongside the value"
    /// shape. Duration stays tracked and visible for this shelf (unlike
    /// Divisible/Priority, hidden outright below) — there's a real case
    /// for jotting an actual duration even though nothing schedules
    /// against it, so it's defaulted rather than removed.
    func test_taskCreatedOnTwoMinuteShelf_defaultsToTwoMinuteDuration() {
        let shelf = Shelf(name: "2-Minute Tasks")
        shelf.isTwoMinuteTasks = true

        let task = TaskItem.makeForDirectCapture(title: "Water the plant", shelf: shelf)

        XCTAssertTrue(task.durationPicked)
        XCTAssertTrue(task.durationPicked)
        XCTAssertEqual(task.estimatedMinutes, 2)
        XCTAssertEqual(task.remainingMinutes, 2, "remainingMinutes must be kept in sync too — TaskItem.init already fixed it at 0 before this default runs")
        XCTAssertFalse(task.missingAttributeNames(consideringShelf: shelf).contains("Duration"))
    }

    func test_taskCreatedOnOrdinaryShelf_doesNotDefaultToTwoMinuteDuration() {
        let shelf = Shelf(name: "Errands")

        let task = TaskItem.makeForDirectCapture(title: "Call the office", shelf: shelf)

        XCTAssertFalse(task.durationPicked)
        XCTAssertEqual(task.estimatedMinutes, 0)
    }

    /// A default, not a lock — must still be freely changeable from the
    /// task's own card afterward, same as the recurring default.
    func test_defaultTwoMinuteDuration_canBeChanged_andSticks() {
        let shelf = Shelf(name: "2-Minute Tasks")
        shelf.isTwoMinuteTasks = true
        let task = TaskItem.makeForDirectCapture(title: "Water the plant", shelf: shelf)
        XCTAssertEqual(task.estimatedMinutes, 2)

        task.estimatedMinutes = 45

        XCTAssertEqual(task.estimatedMinutes, 45)
    }

    /// Only ever applied at creation — a plain `TaskItem` construction
    /// followed by a shelf assignment, the shape `InboxViewModel.route`/
    /// either card's `onMove` handler actually uses, must never pick up
    /// this default after the fact.
    func test_movingExistingTaskOntoTwoMinuteShelf_doesNotBackfillDuration() {
        let shelf = Shelf(name: "2-Minute Tasks")
        shelf.isTwoMinuteTasks = true
        let task = TaskItem(title: "Water the plant") // not routed through makeForDirectCapture

        task.shelf = shelf

        XCTAssertFalse(task.durationPicked)
        XCTAssertEqual(task.estimatedMinutes, 0)
    }

    /// If the shelf doesn't actually track duration at all, the field is
    /// disabled/greyed on the card (`TaskReviewCard.durationAllowed`) —
    /// defaulting a value into it anyway would be dead data behind a
    /// control the user can't even reach normally.
    func test_twoMinuteShelfNotTrackingDuration_doesNotDefaultIt() {
        let shelf = Shelf(name: "2-Minute Tasks")
        shelf.isTwoMinuteTasks = true
        shelf.tracksDuration = false

        let task = TaskItem.makeForDirectCapture(title: "Water the plant", shelf: shelf)

        XCTAssertFalse(task.durationPicked)
        XCTAssertEqual(task.estimatedMinutes, 0)
    }

    /// Fail-then-pass target: a 2-Minute task must report Divisible and
    /// Priority as not-missing even fully untouched, while Duration still
    /// gets its real default (asserted separately above) rather than
    /// being excluded the same way. `Shelf.effectiveTracksDivisible`/
    /// `.effectiveTracksPriority` exclude `isTwoMinuteTasks`;
    /// `effectiveTracksDuration` deliberately does not.
    func test_twoMinuteTask_reportsNeitherDivisibleNorPriority_asMissing() {
        let shelf = Shelf(name: "2-Minute Tasks")
        shelf.isTwoMinuteTasks = true
        let task = TaskItem.makeForDirectCapture(title: "Water the plant", shelf: shelf)

        let missing = task.missingAttributeNames(consideringShelf: shelf)

        XCTAssertFalse(missing.contains("Divisible"))
        XCTAssertFalse(missing.contains("Priority"))
    }

    /// The other half of the fail-then-pass pair: the exact same
    /// untouched task, on an ordinary shelf, must still report Divisible
    /// and Priority as missing — proving the 2-Minute exclusion is scoped
    /// to that shelf specifically.
    func test_sameUntouchedTask_onOrdinaryShelf_stillReportsDivisibleAndPriorityAsMissing() {
        let shelf = Shelf(name: "Errands")
        // 30, not 10 — Divisible is only a real question when the
        // duration admits at least one valid segment size (see
        // `TaskItem.divisibleMissing`'s own short-circuit). 10 minutes
        // has none, which would make this assert nothing.
        let task = TaskItem(title: "Water the plant", shelf: shelf, estimatedMinutes: 60)
        XCTAssertTrue(TaskReviewCard.showsDivisibleRow(task: task), "sanity: 60 minutes shows the Divisible row")

        let missing = task.missingAttributeNames(consideringShelf: shelf)

        XCTAssertTrue(missing.contains("Divisible"))
        XCTAssertTrue(missing.contains("Priority"))
    }

    /// A task already carrying real Divisible/Priority answers, moved
    /// onto the 2-Minute shelf, stops reporting them missing — confirms
    /// the exclusion reads live off the *current* shelf, not just a
    /// freshly-created task's starting state. Duration is asserted to
    /// keep being tracked here too, for contrast.
    func test_taskWithRealAnswers_movedOntoTwoMinuteShelf_stopsReportingDivisibleAndPriority() {
        let ordinaryShelf = Shelf(name: "Errands")
        let task = TaskItem(title: "Water the plant", shelf: ordinaryShelf, estimatedMinutes: 10)
        task.durationPicked = true
        task.divisiblePicked = true
        task.isDivisible = false
        task.priority = .high
        let missingBefore = task.missingAttributeNames(consideringShelf: ordinaryShelf)
        XCTAssertFalse(missingBefore.contains("Divisible"), "sanity check: Divisible answered on the ordinary shelf first")
        XCTAssertFalse(missingBefore.contains("Priority"), "sanity check: Priority answered on the ordinary shelf first")

        let twoMinuteShelf = Shelf(name: "2-Minute Tasks")
        twoMinuteShelf.isTwoMinuteTasks = true
        task.shelf = twoMinuteShelf

        let missing = task.missingAttributeNames(consideringShelf: twoMinuteShelf)
        XCTAssertFalse(missing.contains("Divisible"))
        XCTAssertFalse(missing.contains("Priority"))
        XCTAssertFalse(missing.contains("Duration"), "Duration must still be tracked (and already answered) after the move, unlike Divisible/Priority")
    }

    /// `initialExpandedRows`' new-task branch must still seed `.time`
    /// (Duration stays visible) but omit `.priority` for a shelf that
    /// can't render that row at all.
    /// Updated in stage 3: the 2-Minute shelf now hides Duration too
    /// (along with Due, Divisible, Priority and Tags), so only Can Start
    /// By remains expandable.
    func test_initialExpandedRows_newTwoMinuteTask_omitsEverythingTheShelfHides() {
        let shelf = Shelf(name: "2-Minute Tasks")
        shelf.isTwoMinuteTasks = true
        let task = TaskItem.makeForDirectCapture(title: "Water the plant", shelf: shelf)

        let rows = TaskReviewCard.initialExpandedRows(task: task, shelf: shelf, segmentOptions: [], isNewlyCreated: true)

        // Duration is *not* in that hidden list any more: it stays visible
        // on a 2-Minute task because it's the control that puts a task
        // there, and the only way back off.
        XCTAssertEqual(rows, [.canStartBy, .duration], "the 2-Minute shelf hides Due, Divisible, Priority and Tags — but not Duration")
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

    /// Was `test_recurringTaskWithSpecificTime_durationCanStillBeMissing`,
    /// asserting Duration **is** missing. **Inverted deliberately.**
    ///
    /// It was "the flip side": Specific Time was the one recurring mode
    /// that still asked for a duration, because it was the one that got a
    /// calendar block. There is no flip side now — a task can't be
    /// Specific Time, so no recurring task is asked for a duration, and
    /// none can report it missing.
    func test_recurringTask_neverReportsDurationMissing() {
        let shelf = Shelf(name: "Recurring Tasks")
        shelf.isRecurringTasks = true
        for mode in HabitOccurrenceTimeMode.taskSelectableCases {
            let task = TaskItem.makeForDirectCapture(title: "Take out trash", shelf: shelf)
            task.recurrenceTimeMode = mode

            XCTAssertFalse(
                task.missingAttributeNames(consideringShelf: shelf).contains("Duration"),
                "a recurring task has no block to size, so Duration is never outstanding (\(mode))"
            )
        }
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

    // MARK: - Single-wheel Duration/Divisible: picked-flag semantics

    /// Fail-then-pass target: an untouched Duration is missing. `0`
    /// minutes is no longer what "unanswered" looks like — `durationPicked`
    /// is — so this is the assertion that would break if the flag were
    /// dropped in favor of reading the value alone.
    func test_untouchedDuration_reportsMissing() {
        let task = TaskItem(title: "Task", estimatedMinutes: 0)

        XCTAssertFalse(task.durationPicked)
        XCTAssertTrue(task.missingAttributeNames(consideringShelf: nil).contains("Duration"))
    }

    /// Fail-then-pass target: an untouched Divisible is missing, given a
    /// duration that actually admits segment sizes.
    func test_untouchedDivisible_reportsMissing() {
        let task = TaskItem(title: "Task", estimatedMinutes: 60)
        TaskItem.selectDuration(60, on: task)

        XCTAssertFalse(task.divisiblePicked)
        XCTAssertTrue(task.missingAttributeNames(consideringShelf: nil).contains("Divisible"))
    }

    /// Fail-then-pass target, and the bug class that has recurred
    /// repeatedly: selecting the value the wheel is *already* showing
    /// must still count as answering. `selectDuration` writes the flag
    /// unconditionally rather than diffing the value, which is what makes
    /// this hold.
    func test_selectingTheAlreadyShownDuration_stillMarksAnswered() {
        let task = TaskItem(title: "Task", estimatedMinutes: 30)
        XCTAssertFalse(task.durationPicked)

        TaskItem.selectDuration(30, on: task) // same value already in estimatedMinutes

        XCTAssertTrue(task.durationPicked)
        XCTAssertEqual(task.estimatedMinutes, 30, "value unchanged — only the flag flipped")
        XCTAssertFalse(task.missingAttributeNames(consideringShelf: nil).contains("Duration"))
    }

    /// Same for Divisible: re-confirming "Not Divisible" (`0`) on a task
    /// that already reads as not-divisible must still answer it.
    func test_selectingTheAlreadyShownDivisible_stillMarksAnswered() {
        let task = TaskItem(title: "Task", estimatedMinutes: 30)
        TaskItem.selectDuration(30, on: task)
        XCTAssertFalse(task.divisiblePicked)
        XCTAssertFalse(task.isDivisible, "already reads as not-divisible before any answer")

        TaskItem.selectDivisibleSegment(0, on: task)

        XCTAssertTrue(task.divisiblePicked)
        XCTAssertFalse(task.isDivisible)
        XCTAssertFalse(task.missingAttributeNames(consideringShelf: nil).contains("Divisible"))
    }

    /// "None" is a real answer, not an absence of one — picked, not
    /// missing, and still genuinely unschedulable (`fitStatus`
    /// `.needsDuration`), which is the behavior that makes the option
    /// worth keeping at all.
    func test_durationNone_isARealAnswer_butStillUnschedulable() {
        let task = TaskItem(title: "Task", estimatedMinutes: 30)

        TaskItem.selectDuration(0, on: task)

        XCTAssertTrue(task.durationPicked)
        XCTAssertEqual(task.estimatedMinutes, 0)
        XCTAssertFalse(task.missingAttributeNames(consideringShelf: nil).contains("Duration"), "None is answered")
        XCTAssertEqual(TaskReviewCard.durationOptionLabel(for: 0), "None")
    }

    func test_durationOptionLabels() {
        XCTAssertEqual(TaskReviewCard.durationOptionLabel(for: 0), "None")
        XCTAssertEqual(TaskReviewCard.durationOptionLabel(for: 2), "\u{2264}2 min")
        XCTAssertEqual(TaskReviewCard.durationOptionLabel(for: 30), TaskItem.durationLabel(for: 30))
    }

    /// A 2-Minute task's duration admits no segment size, so the wheel
    /// has only "Not Divisible" to offer.
    func test_twoMinuteTask_divisibleWheelHasOnlyNotDivisible() {
        let shelf = Shelf(name: "2-Minute Tasks")
        shelf.isTwoMinuteTasks = true
        let task = TaskItem.makeForDirectCapture(title: "Water the plant", shelf: shelf)

        XCTAssertEqual(task.estimatedMinutes, 2)
        XCTAssertFalse(TaskReviewCard.showsDivisibleRow(task: task), "2 minutes is below the threshold — no row at all")
        XCTAssertFalse(task.divisiblePicked, "and deliberately not pre-answered, so raising the duration reveals \"Not selected\"")
        XCTAssertFalse(task.missingAttributeNames(consideringShelf: shelf).contains("Divisible"))
    }

    // MARK: - Migration: old two-flag states must not reclassify

    /// Runs the real migration against a real container. The four old
    /// Duration states are set up via the *renamed* columns — which is
    /// exactly what an existing store presents them as after the rename
    /// — and each must land on the same missing/not-missing verdict it
    /// had before. **Fail-then-pass target** is the third case: "said Yes
    /// but never picked a value," which was missing before and must stay
    /// missing, and is the only one the migration actually writes.
    func test_migration_allFourDurationStates_doNotReclassify() throws {
        let container = try ModelContainer(
            for: TaskItem.self, Shelf.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        // 1: never answered
        let neverAnswered = TaskItem(title: "never", estimatedMinutes: 0)
        // 2: a real duration
        let realDuration = TaskItem(title: "real", estimatedMinutes: 30)
        realDuration.durationPicked = true
        // 3: said Yes, never picked a value — missing today, must stay missing
        let yesNoValue = TaskItem(title: "yes-no-value", estimatedMinutes: 0)
        yesNoValue.durationPicked = true
        yesNoValue.legacyDurationAnsweredYes = true
        // 4: deliberately no duration — NOT missing today, must stay not-missing
        let deliberatelyNone = TaskItem(title: "none", estimatedMinutes: 0)
        deliberatelyNone.durationPicked = true
        deliberatelyNone.legacyDurationAnsweredYes = false
        for task in [neverAnswered, realDuration, yesNoValue, deliberatelyNone] { context.insert(task) }
        try context.save()

        let flagKey = "didMigrateDurationDivisibleToSingleWheel.v1"
        let hadFlag = UserDefaults.standard.object(forKey: flagKey)
        UserDefaults.standard.removeObject(forKey: flagKey)
        defer {
            if let hadFlag { UserDefaults.standard.set(hadFlag, forKey: flagKey) }
            else { UserDefaults.standard.removeObject(forKey: flagKey) }
        }
        NoteForLaterApp.migrateDurationDivisibleToSingleWheelIfNeeded(container: container)

        func reread(_ id: UUID) throws -> TaskItem {
            try XCTUnwrap(context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first)
        }
        XCTAssertFalse(try reread(neverAnswered.id).durationPicked, "never answered stays unanswered")
        XCTAssertTrue(try reread(realDuration.id).durationPicked, "a real duration stays answered")
        XCTAssertEqual(try reread(realDuration.id).estimatedMinutes, 30, "and keeps its value")
        XCTAssertFalse(try reread(yesNoValue.id).durationPicked, "said Yes with no value was missing before and must stay missing")
        XCTAssertTrue(try reread(deliberatelyNone.id).durationPicked, "deliberately-None was answered before and must stay answered")
        XCTAssertEqual(try reread(deliberatelyNone.id).estimatedMinutes, 0, "reading as the wheel's None option")
    }

    /// The Divisible half, same four cases with `isDivisible` standing in
    /// for the retired `answeredYes`.
    func test_migration_allFourDivisibleStates_doNotReclassify() throws {
        let container = try ModelContainer(
            for: TaskItem.self, Shelf.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        let neverAnswered = TaskItem(title: "never", estimatedMinutes: 30)
        let realSegment = TaskItem(title: "real", estimatedMinutes: 30)
        realSegment.divisiblePicked = true
        realSegment.isDivisible = true
        realSegment.minimumSegmentMinutes = 15
        let yesNoSegment = TaskItem(title: "yes-no-seg", estimatedMinutes: 30)
        yesNoSegment.divisiblePicked = true
        yesNoSegment.isDivisible = true
        yesNoSegment.minimumSegmentMinutes = 0
        let deliberatelyNot = TaskItem(title: "not-divisible", estimatedMinutes: 30)
        deliberatelyNot.divisiblePicked = true
        deliberatelyNot.isDivisible = false
        for task in [neverAnswered, realSegment, yesNoSegment, deliberatelyNot] { context.insert(task) }
        try context.save()

        let flagKey = "didMigrateDurationDivisibleToSingleWheel.v1"
        let hadFlag = UserDefaults.standard.object(forKey: flagKey)
        UserDefaults.standard.removeObject(forKey: flagKey)
        defer {
            if let hadFlag { UserDefaults.standard.set(hadFlag, forKey: flagKey) }
            else { UserDefaults.standard.removeObject(forKey: flagKey) }
        }
        NoteForLaterApp.migrateDurationDivisibleToSingleWheelIfNeeded(container: container)

        func reread(_ id: UUID) throws -> TaskItem {
            try XCTUnwrap(context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first)
        }
        XCTAssertFalse(try reread(neverAnswered.id).divisiblePicked)
        XCTAssertTrue(try reread(realSegment.id).divisiblePicked)
        XCTAssertEqual(try reread(realSegment.id).minimumSegmentMinutes, 15)
        XCTAssertFalse(try reread(yesNoSegment.id).divisiblePicked, "divisible-with-no-segment was missing before and must stay missing")
        XCTAssertTrue(try reread(deliberatelyNot.id).divisiblePicked, "deliberately Not Divisible was answered before and must stay answered")
    }

    /// A second pass must be a true no-op even with the outer
    /// `UserDefaults` flag cleared — the per-row `hasMigratedSingleWheel`
    /// guard is what carries that, so a real answer made *between* the
    /// two passes can't be stomped back.
    func test_migration_runTwice_secondPassIsANoOp() throws {
        let container = try ModelContainer(
            for: TaskItem.self, Shelf.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let task = TaskItem(title: "yes-no-value", estimatedMinutes: 0)
        task.durationPicked = true
        task.legacyDurationAnsweredYes = true
        let taskID = task.id
        context.insert(task)
        try context.save()

        let flagKey = "didMigrateDurationDivisibleToSingleWheel.v1"
        let hadFlag = UserDefaults.standard.object(forKey: flagKey)
        UserDefaults.standard.removeObject(forKey: flagKey)
        defer {
            if let hadFlag { UserDefaults.standard.set(hadFlag, forKey: flagKey) }
            else { UserDefaults.standard.removeObject(forKey: flagKey) }
        }
        NoteForLaterApp.migrateDurationDivisibleToSingleWheelIfNeeded(container: container)

        func reread() throws -> TaskItem {
            try XCTUnwrap(context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })).first)
        }
        XCTAssertFalse(try reread().durationPicked, "first pass corrects it to unanswered")

        // The user then actually answers it, between the two passes.
        let answered = try reread()
        TaskItem.selectDuration(45, on: answered)
        try context.save()

        UserDefaults.standard.removeObject(forKey: flagKey) // simulate the lost flag write
        NoteForLaterApp.migrateDurationDivisibleToSingleWheelIfNeeded(container: container)

        XCTAssertTrue(try reread().durationPicked, "a second pass must not stomp an answer made since the first")
        XCTAssertEqual(try reread().estimatedMinutes, 45)
    }

    // MARK: - The 60-minute Divisible threshold

    /// Fail-then-pass target on the boundary itself. `>=`, not `>`: 59
    /// hides the row, 60 shows it. Both sides asserted so flipping the
    /// comparison in either direction fails.
    func test_divisibleRow_boundaryAtSixtyMinutes() {
        let task = TaskItem(title: "T", estimatedMinutes: 0)

        task.estimatedMinutes = 59
        XCTAssertFalse(TaskReviewCard.showsDivisibleRow(task: task), "59 minutes is below the threshold")

        task.estimatedMinutes = 60
        XCTAssertTrue(TaskReviewCard.showsDivisibleRow(task: task), "exactly 60 is at the threshold and shows")

        task.estimatedMinutes = 120
        XCTAssertTrue(TaskReviewCard.showsDivisibleRow(task: task))
    }

    /// Hidden means not reported missing — at several sub-hour durations,
    /// including ones that *do* have a valid segment size (30 → [15]), so
    /// this can't pass just because of the separate empty-options guard.
    func test_divisibleNotMissing_belowThreshold() {
        for minutes in [2, 15, 30, 45, 59] {
            let task = TaskItem(title: "T", estimatedMinutes: minutes)
            TaskItem.selectDuration(minutes, on: task)
            XCTAssertFalse(
                task.missingAttributeNames(consideringShelf: nil).contains("Divisible"),
                "\(minutes) minutes is below the threshold — Divisible must not be reported missing"
            )
        }
    }

    /// The two guards are independent, not redundant: 70 clears the hour
    /// bar and still has no evenly-dividing segment size, so it must stay
    /// hidden and unreported for the *other* reason.
    func test_divisibleHidden_atOrAboveThresholdButNoValidSegments() {
        let task = TaskItem(title: "T", estimatedMinutes: 70)
        TaskItem.selectDuration(70, on: task)

        XCTAssertTrue(task.estimatedMinutes >= TaskItem.divisibleMinimumDurationMinutes, "clears the hour bar")
        XCTAssertTrue(TaskItem.validSegmentOptions(for: 70).isEmpty, "but nothing divides it")
        XCTAssertFalse(TaskReviewCard.showsDivisibleRow(task: task))
        XCTAssertFalse(task.missingAttributeNames(consideringShelf: nil).contains("Divisible"))
    }

    /// The scheduling half of the threshold: below an hour the packer
    /// must not split, regardless of stored intent.
    func test_isEffectivelyDivisible_followsTheThreshold() {
        let task = TaskItem(title: "T", estimatedMinutes: 120)
        TaskItem.selectDivisibleSegment(30, on: task)
        XCTAssertTrue(task.isEffectivelyDivisible)

        TaskItem.selectDuration(30, on: task)
        XCTAssertTrue(task.isDivisible, "stored intent is retained")
        XCTAssertFalse(task.isEffectivelyDivisible, "but the packer must not split a sub-hour task")
    }

    /// End-to-end retention through the real selector, which is what the
    /// card actually calls: set divisible at 2h, drop to 30 min (row
    /// gone, not missing, not splittable), raise back — the segment size
    /// is still there, unchanged.
    func test_divisibleValue_survivesADipBelowTheThreshold() {
        let task = TaskItem(title: "T", estimatedMinutes: 120)
        TaskItem.selectDuration(120, on: task)
        TaskItem.selectDivisibleSegment(30, on: task)

        TaskItem.selectDuration(30, on: task)
        XCTAssertFalse(TaskReviewCard.showsDivisibleRow(task: task))
        XCTAssertFalse(task.missingAttributeNames(consideringShelf: nil).contains("Divisible"))
        XCTAssertEqual(task.minimumSegmentMinutes, 30, "retained while dormant")

        TaskItem.selectDuration(120, on: task)
        XCTAssertTrue(TaskReviewCard.showsDivisibleRow(task: task))
        XCTAssertEqual(task.minimumSegmentMinutes, 30, "restored unchanged on raising the duration")
        XCTAssertEqual(TaskReviewCard.divisibleSummaryText(task: task), "30 min")
    }

    /// Visibility is dynamic, not decided at creation — the row appears
    /// and disappears as the Duration wheel moves.
    func test_divisibleVisibility_updatesImmediatelyWithDuration() {
        let task = TaskItem(title: "T", estimatedMinutes: 0)
        TaskItem.selectDuration(30, on: task)
        XCTAssertFalse(TaskReviewCard.showsDivisibleRow(task: task))

        TaskItem.selectDuration(60, on: task)
        XCTAssertTrue(TaskReviewCard.showsDivisibleRow(task: task))

        TaskItem.selectDuration(15, on: task)
        XCTAssertFalse(TaskReviewCard.showsDivisibleRow(task: task))
    }

    /// The 2-Minute shelf case end to end: no Divisible at creation, and
    /// raising the duration to an hour reveals it genuinely unanswered
    /// rather than pre-filled.
    func test_twoMinuteTask_raisedToAnHour_revealsDivisibleAsNotSelected() {
        let shelf = Shelf(name: "2-Minute Tasks")
        shelf.isTwoMinuteTasks = true
        let task = TaskItem.makeForDirectCapture(title: "Water the plant", shelf: shelf)
        XCTAssertFalse(TaskReviewCard.showsDivisibleRow(task: task))

        TaskItem.selectDuration(60, on: task)

        // Stage 3 change: while the task is still *on* the 2-Minute
        // shelf, Divisible stays hidden regardless of duration — the
        // shelf hides it, not just the hour threshold. Raising the
        // duration alone no longer reveals it; leaving the shelf does.
        XCTAssertEqual(CardRow.divisible.visibility(task: task, shelf: shelf), .hidden)
        XCTAssertFalse(task.missingAttributeNames(consideringShelf: shelf).contains("Divisible"))

        let ordinary = Shelf(name: "Errands")
        XCTAssertEqual(CardRow.divisible.visibility(task: task, shelf: ordinary), .shown, "off the shelf, the hour threshold governs again")
        XCTAssertEqual(TaskReviewCard.divisibleSummaryText(task: task), "Not selected")
    }

    // MARK: - Recurring toggle side effects (characterization)

    /// **These pin behavior that had no coverage at all.** Sabotaging the
    /// Recurring toggle's body in place — removing the shelf auto-select,
    /// the eligibility seeding, and the toggle-off preview clear — passed
    /// all 518 tests, because the logic lived inside a `Toggle`'s `set:`
    /// closure where nothing could reach it. Gutting
    /// `makeForDirectCapture`'s recurring default in the same run failed
    /// ~43 tests. The difference was reachability, not importance.
    ///
    /// Written against `applyRecurringToggle` immediately after
    /// extracting it verbatim, and before any behavior change, so they
    /// describe what the toggle already did rather than what it should
    /// do. Two asymmetries are pinned deliberately and must not be
    /// "tidied" without a decision: turning on seeds eligible schedules
    /// while turning off does not reset them, and turning off clears the
    /// preview only when the *preview* is the Recurring shelf.

    private func recurringShelfFixture() -> (shelf: Shelf, rule: SchedulingRule) {
        let shelf = Shelf(name: "Recurring Tasks")
        shelf.isRecurringTasks = true
        let rule = SchedulingRule(shelf: shelf, fillStrategy: .fillToFit)
        rule.isEnabled = true
        shelf.schedulingRules = [rule]
        return (shelf, rule)
    }

    func test_recurringToggleOn_setsRecurring_previewsShelf_andSeedsEligibility() {
        let (shelf, rule) = recurringShelfFixture()
        let task = TaskItem(title: "T")
        XCTAssertTrue(task.includedSchedulingRuleIDs.isEmpty)

        let preview = TaskReviewCard.applyRecurringToggle(true, task: task, shelves: [shelf], preview: .none)

        XCTAssertTrue(task.isRecurring)
        XCTAssertEqual(preview.explicitShelf?.id, shelf.id, "the Recurring shelf is previewed immediately")
        XCTAssertEqual(task.includedSchedulingRuleIDs, [rule.id], "its enabled rules are seeded on")
    }

    /// Only *enabled* rules seed.
    func test_recurringToggleOn_seedsOnlyEnabledRules() {
        let (shelf, rule) = recurringShelfFixture()
        let disabled = SchedulingRule(shelf: shelf, fillStrategy: .fillToFit)
        disabled.isEnabled = false
        shelf.schedulingRules = [rule, disabled]
        let task = TaskItem(title: "T")

        _ = TaskReviewCard.applyRecurringToggle(true, task: task, shelves: [shelf], preview: .none)

        XCTAssertEqual(task.includedSchedulingRuleIDs, [rule.id])
    }

    /// No Recurring shelf configured: the flag still flips, and the
    /// existing preview is left exactly as it was.
    func test_recurringToggleOn_withNoRecurringShelf_stillSetsFlagAndKeepsPreview() {
        let other = Shelf(name: "Errands")
        let task = TaskItem(title: "T")

        let preview = TaskReviewCard.applyRecurringToggle(true, task: task, shelves: [other], preview: .shelf(other))

        XCTAssertTrue(task.isRecurring)
        XCTAssertEqual(preview.explicitShelf?.id, other.id)
        XCTAssertTrue(task.includedSchedulingRuleIDs.isEmpty, "nothing to seed without a Recurring shelf")
    }

    func test_recurringToggleOff_clearsFlagAndDropsTheAutoPreview() {
        let (shelf, _) = recurringShelfFixture()
        let task = TaskItem(title: "T")
        task.isRecurring = true

        let preview = TaskReviewCard.applyRecurringToggle(false, task: task, shelves: [shelf], preview: .shelf(shelf))

        XCTAssertFalse(task.isRecurring)
        XCTAssertNil(preview.explicitShelf, "the auto-preview is dropped so the card reads the task's own shelf again")
    }

    /// **Changed deliberately in stage 3; this test was updated, not
    /// deleted.** It previously pinned the opposite: that toggling off
    /// left the Recurring shelf's rule IDs in place.
    ///
    /// That turned out to be a latent bug rather than a design choice.
    /// Those IDs matched no rule on the shelf the card reverted to, so
    /// `eligibleSchedulesMissing` read "answered" (the array is non-empty)
    /// while `TaskItem.isEligible(for:)` returned false for every rule
    /// actually present — a task that looks complete and is eligible for
    /// nothing, which stays invisible until scheduling quietly stops
    /// placing it. The card spec's "shelf auto-switch resets eligible
    /// schedules" therefore wins, and seeding now runs in both
    /// directions.
    func test_recurringToggleOff_resetsEligibilityToTheRevertedShelf() {
        let (recurringShelf, recurringRule) = recurringShelfFixture()
        let ownShelf = Shelf(name: "Errands")
        let ownRule = SchedulingRule(shelf: ownShelf, fillStrategy: .fillToFit)
        ownRule.isEnabled = true
        ownShelf.schedulingRules = [ownRule]

        let task = TaskItem(title: "T", shelf: ownShelf)
        _ = TaskReviewCard.applyRecurringToggle(true, task: task, shelves: [recurringShelf], preview: .none)
        XCTAssertEqual(task.includedSchedulingRuleIDs, [recurringRule.id], "on: seeded from the Recurring shelf")

        _ = TaskReviewCard.applyRecurringToggle(false, task: task, shelves: [recurringShelf], preview: .shelf(recurringShelf))

        XCTAssertEqual(task.includedSchedulingRuleIDs, [ownRule.id], "off: re-seeded from the shelf the card reverted to")
        XCTAssertFalse(task.includedSchedulingRuleIDs.contains(recurringRule.id), "no stale IDs from a shelf the task isn't on")
    }

    /// Asymmetry #2, pinned: turning off leaves a preview of some *other*
    /// shelf alone — it only drops the Recurring one.
    func test_recurringToggleOff_leavesAnUnrelatedPreviewAlone() {
        let (recurring, _) = recurringShelfFixture()
        let other = Shelf(name: "Errands")
        let task = TaskItem(title: "T")
        task.isRecurring = true

        let preview = TaskReviewCard.applyRecurringToggle(false, task: task, shelves: [recurring], preview: .shelf(other))

        XCTAssertEqual(preview.explicitShelf?.id, other.id, "an unrelated preview survives toggle-off")
    }

    /// And the narrower half of the same rule: a task whose *own* shelf
    /// is the Recurring one, with nothing previewed, is untouched —
    /// toggle-off inspects the preview, not the task's shelf.
    func test_recurringToggleOff_withNoPreview_staysNone() {
        let (shelf, _) = recurringShelfFixture()
        let task = TaskItem(title: "T", shelf: shelf)
        task.isRecurring = true

        let preview = TaskReviewCard.applyRecurringToggle(false, task: task, shelves: [shelf], preview: .none)

        XCTAssertNil(preview.explicitShelf)
        XCTAssertEqual(preview.resolved(for: task)?.id, shelf.id, "still resolves to the task's own shelf")
    }

    /// `ShelfPreview` resolution itself: the distinction a plain `Shelf?`
    /// could not express.
    func test_shelfPreview_resolution() {
        let own = Shelf(name: "Own")
        let other = Shelf(name: "Other")
        let task = TaskItem(title: "T", shelf: own)

        XCTAssertEqual(TaskReviewCard.ShelfPreview.none.resolved(for: task)?.id, own.id)
        XCTAssertEqual(TaskReviewCard.ShelfPreview.shelf(other).resolved(for: task)?.id, other.id)
        XCTAssertNil(TaskReviewCard.ShelfPreview.none.explicitShelf, "no preview is not a pick")
    }

    // MARK: - Stage 3: mutual exclusion, enforced in the model

    private func twoMinuteShelfFixture() -> Shelf {
        let shelf = Shelf(name: "2-Minute Tasks")
        shelf.isTwoMinuteTasks = true
        return shelf
    }

    /// Turning Recurring on moves the task off the 2-Minute shelf — the
    /// action just taken wins.
    func test_setRecurringOn_movesOffTheTwoMinuteShelf() {
        let task = TaskItem(title: "T", shelf: twoMinuteShelfFixture())

        task.setRecurring(true)

        XCTAssertTrue(task.isRecurring)
        XCTAssertNil(task.shelf, "a recurring task must not sit on the 2-Minute shelf")
    }

    /// And from the other side: filing onto the 2-Minute shelf clears
    /// recurrence.
    func test_assignTwoMinuteShelf_clearsRecurring() {
        let task = TaskItem(title: "T")
        task.setRecurring(true)
        XCTAssertTrue(task.isRecurring)

        task.assignShelf(twoMinuteShelfFixture())

        XCTAssertFalse(task.isRecurring)
        XCTAssertTrue(task.shelf?.isTwoMinuteTasks == true)
    }

    /// Assigning any ordinary shelf leaves recurrence alone.
    func test_assignOrdinaryShelf_leavesRecurringAlone() {
        let task = TaskItem(title: "T")
        task.setRecurring(true)

        task.assignShelf(Shelf(name: "Errands"))

        XCTAssertTrue(task.isRecurring)
    }

    /// The repair path, where the two arrive together rather than in
    /// sequence: Recurring wins.
    func test_repairSpecialShelfExclusivity_recurringWins() {
        let task = TaskItem(title: "T")
        // Construct the forbidden combination directly, bypassing the
        // guarded setters — this is the state a stale store or a future
        // code path could produce.
        task.isRecurring = true
        task.shelf = twoMinuteShelfFixture()

        TaskItem.repairSpecialShelfExclusivity(task)

        XCTAssertTrue(task.isRecurring, "recurring survives")
        XCTAssertNil(task.shelf, "the 2-minute side gives way")
    }

    func test_repairSpecialShelfExclusivity_leavesValidStatesAlone() {
        let recurringElsewhere = TaskItem(title: "A", shelf: Shelf(name: "Errands"))
        recurringElsewhere.isRecurring = true
        TaskItem.repairSpecialShelfExclusivity(recurringElsewhere)
        XCTAssertNotNil(recurringElsewhere.shelf)

        let twoMinuteNotRecurring = TaskItem(title: "B", shelf: twoMinuteShelfFixture())
        TaskItem.repairSpecialShelfExclusivity(twoMinuteNotRecurring)
        XCTAssertTrue(twoMinuteNotRecurring.shelf?.isTwoMinuteTasks == true, "a plain 2-minute task is untouched")
    }

    /// Recurring isn't offered on a 2-Minute task, so the forbidden
    /// combination isn't reachable from the card.
    ///
    /// **Was `test_togglesAreMutuallyHidden`, asserting both directions.**
    /// The 2-Minute toggle is gone — duration drives the shelf now — so its
    /// half of the assertion went with it. The half kept here is the one
    /// that still guards something: `.recurringToggle` hiding on a 2-Minute
    /// task. Deleting the whole test alongside the toggle would have taken
    /// that with it, and nothing else asserts it.
    func test_recurringToggleHiddenOnATwoMinuteTask() {
        let twoMinute = TaskItem(title: "M")
        XCTAssertEqual(CardRow.recurringToggle.visibility(task: twoMinute, shelf: twoMinuteShelfFixture()), .hidden)
    }

    // MARK: - Stage 3: reset-on-toggle clears exactly what it hid

    /// A task with *every* field populated, so over-reach is visible:
    /// turning 2-Minute on must clear the rows that shelf hides and
    /// nothing else.
    /// **Retargeted from the toggle to the duration trigger.** The
    /// derived reset is unchanged; what changed is what fires it. The
    /// Duration assertion is *inverted* from the old version, and that
    /// inversion is the whole point — see below.
    func test_droppingToTwoMinutes_clearsExactlyTheRowsItHides() {
        let shelf = twoMinuteShelfFixture()
        let task = TaskItem(title: "T", shelf: Shelf(name: "Errands"))
        task.dueDateDecided = true
        task.dueDate = .now
        task.dueDatePicked = true
        TaskItem.selectDuration(120, on: task)
        TaskItem.selectDivisibleSegment(30, on: task)
        task.priority = .high
        task.tags = ["errand"]
        task.nextStepDecided = true
        task.nextStepAnsweredYes = true
        task.nextStep = "Find it"
        task.setStartDate(Calendar.current.startOfDay(for: .now))

        TaskItem.selectDuration(2, on: task)
        _ = TaskReviewCard.applyDurationDrivenShelf(task: task, shelves: [shelf], preview: .none)

        // Hidden by the 2-Minute shelf → cleared.
        XCTAssertFalse(task.dueDateDecided)
        XCTAssertNil(task.dueDate)
        XCTAssertEqual(task.priority, .unset)
        XCTAssertEqual(task.tags, [])
        // Still shown → untouched. This is the over-reach check.
        XCTAssertEqual(task.nextStep, "Find it", "Next Step is still shown, so it must survive")
        XCTAssertTrue(task.nextStepDecided)
        XCTAssertNotNil(task.startDate, "Can Start By is still shown, so it must survive")
        // The one that matters most: the trigger must survive its own
        // consequence. Duration stays visible on a 2-Minute task, so the
        // derived reset can't reach it — if it could, setting 2 minutes
        // would immediately erase the 2 minutes.
        XCTAssertTrue(task.durationPicked, "Duration is the trigger; clearing it would undo the move")
        XCTAssertEqual(task.estimatedMinutes, 2)
        // Divisible also survives, for a different and pre-existing reason:
        // dropping to 2 minutes hides it via the *duration* threshold before
        // the shelf rule runs, so it was already invisible when the reset
        // computed (visible before − visible after) and was never in that
        // set. That matches the documented rule that a divisible value
        // survives a dip below the threshold — see
        // `test_divisibleValue_survivesADipBelowTheThreshold`. The reset
        // clears what the *shelf change* hid, not what the duration did.
        XCTAssertTrue(task.divisiblePicked, "hidden by the duration threshold, not by the shelf move")
    }

    /// Recurring's own reset, same derivation: turning it on hides Due,
    /// Priority and Tags, so those clear and nothing else does.
    func test_recurringToggleOn_clearsExactlyTheRowsItHides() {
        let (shelf, _) = recurringShelfFixture()
        let task = TaskItem(title: "T")
        task.dueDateDecided = true
        task.dueDate = .now
        task.priority = .high
        task.tags = ["errand"]
        task.nextStepDecided = true
        task.nextStep = "Find it"

        _ = TaskReviewCard.applyRecurringToggle(true, task: task, shelves: [shelf], preview: .none)

        XCTAssertFalse(task.dueDateDecided)
        XCTAssertEqual(task.priority, .unset)
        XCTAssertEqual(task.tags, [])
        XCTAssertEqual(task.nextStep, "Find it", "Next Step survives — recurring doesn't hide it")
    }

    // MARK: - Stage 3: the cleared-preview tri-state

    /// Raising the duration on a task that actually lives on the 2-Minute
    /// shelf can't just revert — falling back would resolve to that shelf
    /// again, which the new duration no longer matches. It asks for a
    /// destination instead.
    ///
    /// **Retargeted from `test_twoMinuteToggleOff_onAShelfResident_clearsAndDemandsAChoice`,
    /// not deleted.** Its subject was the toggle; its *coverage* was
    /// `ShelfPreview.cleared` and `needsShelfChoice`, which both survive and
    /// are now reached by the duration rule instead. Same assertions, new
    /// trigger.
    func test_raisingDurationOnAShelfResident_clearsAndDemandsAChoice() {
        let shelf = twoMinuteShelfFixture()
        let task = TaskItem(title: "T", shelf: shelf)
        TaskItem.selectDuration(30, on: task)

        let preview = TaskReviewCard.applyDurationDrivenShelf(task: task, shelves: [shelf], preview: .none)

        XCTAssertTrue(preview.needsShelfChoice)
        XCTAssertNil(preview.resolved(for: task), "resolves to no shelf, not back to the 2-Minute one")
        XCTAssertEqual(preview.shelfChoicePrompt, "No longer a 2-minute task — where should it go?")
    }

    /// The prompt is tied to the reason, not to "any cleared state" — so a
    /// future producer of `.cleared` can't inherit copy claiming the task
    /// stopped being a 2-minute task.
    func test_shelfChoicePrompt_isNilWheneverNoChoiceIsOwed() {
        XCTAssertNil(TaskReviewCard.ShelfPreview.none.shelfChoicePrompt)
        XCTAssertNil(TaskReviewCard.ShelfPreview.shelf(Shelf(name: "Errands")).shelfChoicePrompt)
    }

    /// A task merely *previewing* the shelf reverts to its own — no forced
    /// choice, because falling back can't re-trigger the rule. This is the
    /// full round trip: drop to 2 minutes, then raise it again.
    ///
    /// **Retargeted from `test_twoMinuteToggleOff_onANonResident_revertsWithoutDemandingAChoice`.**
    /// Its coverage — the `.none` fallback resolving to the task's real
    /// shelf — is what makes "raise the duration" a working way out without
    /// any override state, so it had to survive the trigger change.
    func test_loweringThenRaisingDuration_revertsToTheOriginalShelf() {
        let shelf = twoMinuteShelfFixture()
        let own = Shelf(name: "Errands")
        let task = TaskItem(title: "T", shelf: own)

        TaskItem.selectDuration(2, on: task)
        var preview = TaskReviewCard.applyDurationDrivenShelf(task: task, shelves: [shelf], preview: .none)
        XCTAssertTrue(preview.resolved(for: task)?.isTwoMinuteTasks == true, "≤2 min previews the 2-Minute shelf")

        TaskItem.selectDuration(30, on: task)
        preview = TaskReviewCard.applyDurationDrivenShelf(task: task, shelves: [shelf], preview: preview)

        XCTAssertFalse(preview.needsShelfChoice)
        XCTAssertEqual(preview.resolved(for: task)?.id, own.id)
    }

    /// A shelf the *user* picked is never undone by the duration rule —
    /// which is what lets an explicit tap win without a suppression flag.
    func test_durationRule_leavesAUserPickedShelfAlone() {
        let shelf = twoMinuteShelfFixture()
        let picked = Shelf(name: "Personal")
        let task = TaskItem(title: "T", shelf: Shelf(name: "Errands"))
        TaskItem.selectDuration(30, on: task)

        let preview = TaskReviewCard.applyDurationDrivenShelf(
            task: task, shelves: [shelf], preview: .shelf(picked)
        )

        XCTAssertEqual(preview.explicitShelf?.id, picked.id, "not ours to undo")
    }

    // MARK: - Cancel still rolls the reset back

    /// The reset destroys data by design, so Cancel has to undo it.
    /// `TaskEditSnapshot` is captured on appear, before any edit.
    ///
    /// **Retargeted from the toggle.** Its subject was
    /// `applyTwoMinuteToggle`; its coverage is `TaskEditSnapshot.restore`
    /// undoing a derived reset, which is unchanged and still the only thing
    /// standing between a mis-set duration and lost data.
    func test_cancelRestoresEverythingTheDurationDropCleared() {
        let shelf = twoMinuteShelfFixture()
        let task = TaskItem(title: "T", shelf: Shelf(name: "Errands"))
        task.dueDateDecided = true
        task.dueDate = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 17))
        task.dueDatePicked = true
        TaskItem.selectDuration(120, on: task)
        TaskItem.selectDivisibleSegment(30, on: task)
        task.priority = .high
        task.tags = ["errand"]

        let snapshot = TaskEditSnapshot(task)   // as .onAppear does, pre-edit
        TaskItem.selectDuration(2, on: task)
        _ = TaskReviewCard.applyDurationDrivenShelf(task: task, shelves: [shelf], preview: .none)
        XCTAssertEqual(task.priority, .unset, "sanity: the reset happened")

        snapshot.restore(into: task)

        XCTAssertTrue(task.dueDateDecided)
        XCTAssertEqual(task.dueDate, Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 17)))
        XCTAssertTrue(task.durationPicked)
        XCTAssertEqual(task.estimatedMinutes, 120)
        XCTAssertTrue(task.divisiblePicked)
        XCTAssertEqual(task.minimumSegmentMinutes, 30)
        XCTAssertEqual(task.priority, .high)
        XCTAssertEqual(task.tags, ["errand"])
    }

    // MARK: - The duration wheel offers ≤2 min again

    /// **Inverted from `test_durationWheel_dropsTheTwoMinuteOption_…`,
    /// deliberately.** That test asserted ≤2 min was *absent*, because a
    /// separate toggle expressed it. Duration is the single trigger again,
    /// so the wheel has to be able to say it — an option the wheel can't
    /// offer is a shelf the user can't reach.
    func test_durationWheel_offersTheTwoMinuteOption() {
        XCTAssertTrue(TaskReviewCard.durationOptions.contains(2), "≤2 min is how a task reaches the 2-Minute shelf")
        XCTAssertEqual(TaskReviewCard.durationOptions.first, 2, "and it sorts first — it's the shortest")
        XCTAssertEqual(TaskReviewCard.durationOptionLabel(for: 2), "≤2 min")
    }
}
