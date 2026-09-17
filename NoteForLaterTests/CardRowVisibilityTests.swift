import XCTest
@testable import NoteForLater

/// Direct coverage for `CardRow.visibility(task:shelf:)` — the single rule
/// deciding whether a task-card row is shown, greyed, or absent.
///
/// **Why this file exists, specifically.** A regression shipped because
/// Duration and Divisible kept rendering for untimed recurring tasks while
/// the missing-checks correctly reported them not-missing. Nothing caught
/// it: the tests asserted the missing-check, and nothing asserted row
/// visibility at all. Unifying the two rules fixes that instance; this
/// file is what stops the *class* — every hide rule has a test that fails
/// if the row comes back, and every row that can report missing has a test
/// pinning visibility and missing-ness together.
///
/// `visibility` is a pure function over `(TaskItem, Shelf?)`, so none of
/// this needs a rendered view — which is exactly what made the coverage
/// affordable.
final class CardRowVisibilityTests: XCTestCase {

    // MARK: - Fixtures

    private func plainTask(minutes: Int = 0) -> TaskItem {
        TaskItem(title: "T", estimatedMinutes: minutes)
    }

    private func recurringTask(mode: HabitOccurrenceTimeMode = .midday, minutes: Int = 0) -> TaskItem {
        let task = TaskItem(title: "R", estimatedMinutes: minutes)
        task.isRecurring = true
        task.recurrenceTimeMode = mode
        return task
    }

    /// A shelf tracking everything, plus one scheduling rule so
    /// `.eligibleSchedules` has something to show.
    private func trackingShelf() -> Shelf {
        let shelf = Shelf(name: "Errands")
        shelf.tracksFutureReminder = true
        let rule = SchedulingRule(shelf: shelf, fillStrategy: .fillToFit)
        shelf.schedulingRules = [rule]
        return shelf
    }

    private func shelfTracking(
        duration: Bool = true, dueDates: Bool = true,
        nextStep: Bool = true, priority: Bool = true, futureReminder: Bool = true
    ) -> Shelf {
        let shelf = trackingShelf()
        shelf.tracksDuration = duration
        shelf.hasDueDates = dueDates
        shelf.hasNextStep = nextStep
        shelf.hasPriority = priority
        shelf.tracksFutureReminder = futureReminder
        return shelf
    }

    // MARK: - Hide rules: one test per (row, reason), each failing if the row returns

    func test_hidden_recurringOnlyRows_forNonRecurringTask() {
        let task = plainTask()
        let shelf = trackingShelf()
        for row in [CardRow.repeats, .timeMode, .ends, .pushIfMissed] {
            XCTAssertEqual(row.visibility(task: task, shelf: shelf), .hidden, "\(row) must not appear on a non-recurring task")
        }
    }

    func test_hidden_nonRecurringOnlyRows_forRecurringTask() {
        let task = recurringTask()
        let shelf = trackingShelf()
        for row in [CardRow.due, .priority] {
            XCTAssertEqual(row.visibility(task: task, shelf: shelf), .hidden, "\(row) must not appear on a recurring task")
        }
    }

    /// The exact regression that shipped: a recurring occurrence never gets
    /// a calendar block, so it has no duration to state and nothing to
    /// split.
    ///
    /// **This used to be "…forUntimedRecurringTask", and sat beside
    /// `test_shown_durationAndDivisible_forSpecificTimeRecurringTask`
    /// asserting the opposite for the other mode.** That pairing is gone:
    /// Specific Time is no longer a state a task can reach, so "untimed
    /// recurring" and "recurring" are the same set, and the two tests
    /// became the same assertion. Merged rather than left as a duplicate,
    /// and the inversion is deliberate — the old `shown` expectation
    /// described a task kind that no longer exists.
    ///
    /// Driven off `taskSelectableCases` rather than a hand-written mode
    /// list, so adding a mode later can't quietly skip this.
    func test_hidden_durationAndDivisible_forEveryRecurringTask() {
        let shelf = trackingShelf()
        for mode in HabitOccurrenceTimeMode.taskSelectableCases {
            // 120 minutes clears every other bar, so only the mode can hide these.
            let task = recurringTask(mode: mode, minutes: 120)
            XCTAssertEqual(CardRow.duration.visibility(task: task, shelf: shelf), .hidden, "Duration must be hidden for \(mode)")
            XCTAssertEqual(CardRow.divisible.visibility(task: task, shelf: shelf), .hidden, "Divisible must be hidden for \(mode)")
        }
    }

    /// The mode a recurring task may not be in. Pairs with the test above:
    /// that one says every *reachable* mode hides Duration, this one says
    /// the unreachable mode is genuinely unreachable.
    func test_taskSelectableCases_excludesSpecific_butHabitsKeepIt() {
        XCTAssertFalse(HabitOccurrenceTimeMode.taskSelectableCases.contains(.specific))
        XCTAssertEqual(HabitOccurrenceTimeMode.taskSelectableCases, [.am, .midday, .pm])
        XCTAssertTrue(HabitOccurrenceTimeMode.allCases.contains(.specific), "habits still offer all four")
    }

    func test_hidden_divisible_belowTheHourThreshold() {
        let shelf = trackingShelf()
        for minutes in [0, 15, 30, 45, 59] {
            let task = plainTask(minutes: minutes)
            XCTAssertEqual(CardRow.divisible.visibility(task: task, shelf: shelf), .hidden, "\(minutes) min is under the threshold")
        }
        XCTAssertEqual(CardRow.divisible.visibility(task: plainTask(minutes: 60), shelf: shelf), .shown, "exactly 60 shows")
    }

    /// A second, independent reason — 70 clears the hour bar and still has
    /// no evenly-dividing segment size.
    func test_hidden_divisible_whenNoSegmentSizeDividesTheDuration() {
        let task = plainTask(minutes: 70)
        XCTAssertTrue(task.estimatedMinutes >= TaskItem.divisibleMinimumDurationMinutes, "clears the hour bar")
        XCTAssertEqual(CardRow.divisible.visibility(task: task, shelf: trackingShelf()), .hidden)
    }

    func test_hidden_nextStep_priority_remindIn_whenShelfDoesNotTrackThem() {
        let task = plainTask(minutes: 60)
        XCTAssertEqual(CardRow.nextStep.visibility(task: task, shelf: shelfTracking(nextStep: false)), .hidden)
        XCTAssertEqual(CardRow.priority.visibility(task: task, shelf: shelfTracking(priority: false)), .hidden)
        XCTAssertEqual(CardRow.remindIn.visibility(task: task, shelf: shelfTracking(futureReminder: false)), .hidden)
    }

    /// Remind In is the one opt-in-by-default-off flag, so a task with no
    /// shelf yet must not show it — unlike every other row, whose `nil`
    /// shelf defaults to shown.
    func test_hidden_remindIn_forTaskWithNoShelf() {
        XCTAssertEqual(CardRow.remindIn.visibility(task: plainTask(), shelf: nil), .hidden)
    }

    func test_hidden_eligibleSchedules_whenShelfHasNoRules() {
        let shelf = Shelf(name: "No rules")
        shelf.schedulingRules = []
        XCTAssertEqual(CardRow.eligibleSchedules.visibility(task: plainTask(), shelf: shelf), .hidden)
        XCTAssertEqual(CardRow.eligibleSchedules.visibility(task: plainTask(), shelf: trackingShelf()), .shown)
    }

    // MARK: - Greyed, not hidden — and the deliberate asymmetry between the two

    /// Duration stays visible on a shelf that doesn't track duration so
    /// its stored value is still legible; Divisible disappears, having
    /// nothing to show without a duration to divide. Pre-existing
    /// asymmetry, pinned here so it's a decision rather than an accident.
    /// Was `test_greyed_duration_butHidden_divisible_…`, pinning a
    /// deliberate asymmetry: Duration greyed where Divisible hid.
    /// **That asymmetry is gone — both hide now.**
    ///
    /// The old rationale for greying Duration was that it kept a stored
    /// value legible. It doesn't: `Shelf.resolvedDuration` returns 0 for a
    /// non-tracking shelf and both move paths apply it, so the value is
    /// wiped on commit regardless. A row you turned off, can't edit, and
    /// whose value is about to be zeroed is just clutter.
    func test_hidden_durationAndDivisible_whenShelfDoesNotTrackDuration() {
        let task = plainTask(minutes: 120)
        let shelf = shelfTracking(duration: false)

        XCTAssertEqual(CardRow.duration.visibility(task: task, shelf: shelf), .hidden)
        XCTAssertEqual(CardRow.divisible.visibility(task: task, shelf: shelf), .hidden)
    }

    /// The one exception, and it is load-bearing: on the shelf that
    /// Duration's own value selects, the row stays `.shown` — editable, not
    /// merely visible — even with that shelf's Duration toggle off.
    /// Otherwise the task is stranded: duration uneditable, and the shelf
    /// picker already narrowed to 2-Minute shelves only.
    func test_shown_duration_onTheDestinationTriggerShelf_evenWhenUntracked() {
        let task = plainTask(minutes: 2)
        let shelf = shelfTracking(duration: false)
        shelf.isTwoMinuteTasks = true

        XCTAssertEqual(CardRow.duration.visibility(task: task, shelf: shelf), .shown)
    }

    /// Was `test_greyed_due_…`. **Inverted deliberately:** off means gone.
    /// The greyed state only became user-visible when the 2-Minute
    /// hardcoding was removed, and it read as a bug — a row you switched
    /// off that stays on screen and can't be edited.
    func test_hidden_due_whenShelfDoesNotTrackDueDates() {
        XCTAssertEqual(CardRow.due.visibility(task: plainTask(), shelf: shelfTracking(dueDates: false)), .hidden)
    }

    // MARK: - Always-shown rows

    func test_shown_alwaysOfferedRows() {
        for task in [plainTask(), recurringTask()] {
            for row in [CardRow.shelf, .canStartBy] {
                XCTAssertEqual(row.visibility(task: task, shelf: trackingShelf()), .shown, "\(row) is always offered")
            }
        }
    }

    // MARK: - The pairing that stage 1 fell through: visibility ⇄ missing-ness

    /// **Only `.shown` can be reported missing.** Asserted directly for
    /// every row that reports a missing attribute, across the states that
    /// make it non-shown — this is the invariant whose absence let a row
    /// render while its missing-check said otherwise.
    func test_neverMissing_whenRowIsNotShown() {
        let cases: [(name: String, row: CardRow, task: TaskItem, shelf: Shelf?)] = [
            ("Duration", .duration, recurringTask(mode: .am, minutes: 120), trackingShelf()),
            ("Duration", .duration, plainTask(minutes: 120), shelfTracking(duration: false)),
            ("Divisible", .divisible, recurringTask(mode: .am, minutes: 120), trackingShelf()),
            ("Divisible", .divisible, plainTask(minutes: 30), trackingShelf()),
            ("Divisible", .divisible, plainTask(minutes: 70), trackingShelf()),
            ("Divisible", .divisible, plainTask(minutes: 120), shelfTracking(duration: false)),
            ("Due Date", .due, recurringTask(), trackingShelf()),
            ("Due Date", .due, plainTask(), shelfTracking(dueDates: false)),
            ("Priority", .priority, recurringTask(), trackingShelf()),
            ("Priority", .priority, plainTask(), shelfTracking(priority: false)),
            ("Next Step", .nextStep, plainTask(), shelfTracking(nextStep: false)),
            ("Eligible Schedules", .eligibleSchedules, plainTask(), Shelf(name: "No rules")),
            ("Every", .repeats, plainTask(), trackingShelf()),
            ("Time", .timeMode, plainTask(), trackingShelf()),
        ]

        for (name, row, task, shelf) in cases {
            XCTAssertNotEqual(row.visibility(task: task, shelf: shelf), .shown, "fixture must be non-shown for \(name)")
            XCTAssertFalse(
                task.missingAttributeNames(consideringShelf: shelf).contains(name),
                "\(name) is not shown, so it must never be reported missing"
            )
        }
    }

    /// The converse half, so the pairing can't be satisfied by a
    /// predicate that simply never reports anything: when the row *is*
    /// shown and genuinely unanswered, it must be reported.
    func test_missing_whenRowIsShownAndUnanswered() {
        let shelf = trackingShelf()
        let task = plainTask(minutes: 60)

        XCTAssertEqual(CardRow.duration.visibility(task: task, shelf: shelf), .shown)
        XCTAssertEqual(CardRow.divisible.visibility(task: task, shelf: shelf), .shown)
        let missing = task.missingAttributeNames(consideringShelf: shelf)
        XCTAssertTrue(missing.contains("Duration"))
        XCTAssertTrue(missing.contains("Divisible"))
        XCTAssertTrue(missing.contains("Due Date"))
        XCTAssertTrue(missing.contains("Priority"))
        XCTAssertTrue(missing.contains("Next Step"))
        XCTAssertTrue(missing.contains("Eligible Schedules"))
    }

    /// Can Start By is the one row that's always shown yet only ever
    /// *required* for a recurring task — `.shown` is a precondition for
    /// missing, not a promise of it.
    func test_canStartBy_shownButOnlyRequiredForRecurring() {
        let shelf = trackingShelf()
        let plain = plainTask()
        XCTAssertEqual(CardRow.canStartBy.visibility(task: plain, shelf: shelf), .shown)
        XCTAssertFalse(plain.missingAttributeNames(consideringShelf: shelf).contains("Start Date"))

        let recurring = recurringTask()
        XCTAssertEqual(CardRow.canStartBy.visibility(task: recurring, shelf: shelf), .shown)
        XCTAssertTrue(recurring.missingAttributeNames(consideringShelf: shelf).contains("Start Date"))
    }

    // MARK: - Full matrix, as a table

    /// Every row against every task kind on a fully-tracking shelf.
    /// Cheap, and it turns any future visibility change into an explicit
    /// diff in this table rather than a silent behavior shift.
    func test_visibilityMatrix_onAFullyTrackingShelf() {
        let shelf = trackingShelf()
        let plain = plainTask(minutes: 120)
        let recurring = recurringTask(mode: .midday, minutes: 120)

        // (row, plain, recurring)
        //
        // This table had three columns: plain, *Specific-Time* recurring,
        // and untimed recurring. Specific Time is no longer a state a
        // recurring task can be in (`HabitOccurrenceTimeMode
        // .taskSelectableCases`), so that column described a task kind that
        // no longer exists and has been removed rather than left asserting
        // against an unreachable fixture.
        //
        // The two recurring columns had differed on exactly Duration and
        // Divisible — shown for Specific Time, hidden when untimed. Those
        // are now hidden for *every* recurring task, which is the whole
        // user-visible point of the change and is asserted directly in
        // `test_hidden_durationAndDivisible_forEveryRecurringTask` below.
        //
        // Both fixtures sit on an ordinary shelf, so the 2-Minute column is
        // covered separately by the tests below.
        //
        // The `.twoMinuteToggle` row is gone: duration is the single
        // trigger for 2-minute-ness now, so there is no toggle to show.
        let expected: [(CardRow, CardRow.Visibility, CardRow.Visibility)] = [
            (.nextStep,          .shown,  .shown),
            (.recurringToggle,   .shown,  .shown),
            (.canStartBy,        .shown,  .shown),
            (.duration,          .shown,  .hidden),
            (.divisible,         .shown,  .hidden),
            (.tags,              .shown,  .hidden),
            (.shelf,             .shown,  .shown),
            (.eligibleSchedules, .shown,  .shown),
            (.remindIn,          .shown,  .shown),
            (.due,               .shown,  .hidden),
            (.priority,          .shown,  .hidden),
            (.repeats,           .hidden, .shown),
            (.timeMode,          .hidden, .shown),
            (.ends,              .hidden, .shown),
            (.pushIfMissed,      .hidden, .shown),
        ]

        XCTAssertEqual(expected.count, CardRow.allCases.count, "every CardRow case must appear in this table")
        for (row, plainExpected, recurringExpected) in expected {
            XCTAssertEqual(row.visibility(task: plain, shelf: shelf), plainExpected, "\(row) / plain")
            XCTAssertEqual(row.visibility(task: recurring, shelf: shelf), recurringExpected, "\(row) / recurring")
        }
    }

    // MARK: - Render order

    /// The scroll body's row order, asserted as an exact array. Order is
    /// user-visible, so this is a characterization test: if it changes,
    /// the card changed and the diff should say so explicitly.
    func test_scrollBodyOrder_nonRecurring() {
        let task = plainTask(minutes: 120)
        XCTAssertEqual(
            CardRow.scrollBodyOrder(task: task, shelf: trackingShelf()),
            [.recurringToggle, .due, .canStartBy, .duration, .divisible, .priority,
             .remindIn, .tags, .shelf, .eligibleSchedules]
        )
    }

    func test_scrollBodyOrder_recurring() {
        let task = recurringTask(mode: .midday, minutes: 120)
        XCTAssertEqual(
            CardRow.scrollBodyOrder(task: task, shelf: trackingShelf()),
            // No .twoMinuteToggle and no .tags — both hidden for a
            // recurring task (mutual exclusion, and the spec's Tags rule).
            // No .duration or .divisible either: every recurring task is an
            // untimed list item now, so neither row applies to any of them.
            [.recurringToggle, .repeats, .canStartBy, .timeMode,
             .ends, .pushIfMissed, .remindIn, .shelf, .eligibleSchedules]
        )
    }

    /// Hidden rows drop out of the order entirely; greyed rows stay,
    /// because greyed means drawn-but-disabled rather than absent.
    /// Was `test_scrollBodyOrder_dropsHiddenKeepsGreyed`, using Due and
    /// Duration as the greyed examples. Both hide now, so every row a
    /// non-tracking shelf switches off drops out of the order.
    ///
    /// **`.greyed` is currently produced by nothing.** The case still exists
    /// on `CardRow.Visibility` and `scrollBodyOrder` still keeps it, but no
    /// rule returns it and no view renders it differently — it is dead until
    /// something needs "offered but unanswerable" again. Asserted here so
    /// that fact is recorded rather than discovered.
    func test_scrollBodyOrder_dropsEveryRowTheShelfSwitchesOff() {
        let task = plainTask(minutes: 120)
        let shelf = shelfTracking(duration: false, dueDates: false, priority: false, futureReminder: false)
        let order = CardRow.scrollBodyOrder(task: task, shelf: shelf)

        for row in [CardRow.duration, .due, .divisible, .priority, .remindIn] {
            XCTAssertFalse(order.contains(row), "\(row) was switched off, so it must drop out")
        }

        XCTAssertTrue(
            CardRow.allCases.allSatisfy { $0.visibility(task: task, shelf: shelf) != .greyed },
            "nothing produces .greyed today — if this fails, update the comment above rather than this assertion"
        )
    }

    /// Never includes `.nextStep` — that row is drawn in `cardHeader`,
    /// above the scroll body.
    func test_scrollBodyOrder_excludesTheHeaderRow() {
        for task in [plainTask(), recurringTask()] {
            XCTAssertFalse(CardRow.scrollBodyOrder(task: task, shelf: trackingShelf()).contains(.nextStep))
        }
    }

    /// Section grouping is part of the definition, since the attribute
    /// rows and the tail are drawn in stacks with different spacing.
    func test_sectionGrouping_tailIsTheLastFourRows() {
        let order = CardRow.scrollBodyOrder(task: plainTask(minutes: 120), shelf: trackingShelf())
        let tail = order.filter { $0.section == .tail }

        XCTAssertEqual(tail, [.remindIn, .tags, .shelf, .eligibleSchedules])
        XCTAssertEqual(Array(order.suffix(4)), tail, "the tail must actually be at the end")
    }

    // MARK: - Seeding is the same array, not a parallel one

    /// `initialExpandedRow` walks `scrollBodyOrder`, so it can only ever
    /// return a row the card actually draws — the property that used to
    /// need its own test now holds by construction, and this pins it.
    func test_initialExpandedRow_onlyReturnsRowsThatAreDrawnAndExpandable() {
        let shelf = trackingShelf()
        let fixtures = [
            plainTask(), plainTask(minutes: 120),
            recurringTask(mode: .pm, minutes: 120), recurringTask(mode: .am, minutes: 120),
        ]
        for task in fixtures {
            guard let seeded = TaskReviewCard.initialExpandedRow(task: task, shelf: shelf, segmentOptions: []) else { continue }
            let order = CardRow.scrollBodyOrder(task: task, shelf: shelf)
            XCTAssertTrue(order.contains(seeded), "seeded \(seeded) must be a drawn row")
            XCTAssertTrue(seeded.isExpandable, "seeded \(seeded) must be expandable")
        }
    }

    /// A new task seeds exactly the drawn-and-expandable rows — no row
    /// that can't appear, and nothing drawn-and-expandable left out.
    func test_initialExpandedRows_newTask_isExactlyTheDrawnExpandableRows() {
        let shelf = trackingShelf()
        for task in [plainTask(minutes: 120), recurringTask(mode: .pm, minutes: 120), recurringTask(mode: .am, minutes: 120)] {
            let seeded = TaskReviewCard.initialExpandedRows(task: task, shelf: shelf, segmentOptions: [], isNewlyCreated: true)
            let expected = Set(CardRow.scrollBodyOrder(task: task, shelf: shelf).filter(\.isExpandable))
            XCTAssertEqual(seeded, expected)
        }
    }
}
