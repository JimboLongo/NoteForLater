import XCTest
import SwiftData
@testable import NoteForLater

/// Coverage for the compact recurring-task card redesign (`TaskReviewCard
/// .recurringSection`) — each row shows its composed answer, not its
/// controls, expanding on tap to reveal the real ones. `TaskReviewCard`
/// itself isn't constructible here (its `@Query` properties need a live
/// SwiftUI/SwiftData environment), so this exercises the pulled-out,
/// `internal` predicates the same way `NightlyReviewAutoSkipTests` does
/// for `NightlyReviewView.Step` — see `TaskReviewCard.isRepeatsConfigured`'s
/// own doc comment for why it was loosened from `private`.
final class RecurringTaskCardLayoutTests: XCTestCase {
    private func makeRecurringTask(title: String = "Water the garden") -> TaskItem {
        let shelf = Shelf(name: "Recurring Tasks")
        shelf.isRecurringTasks = true
        return TaskItem.makeForDirectCapture(title: title, shelf: shelf)
    }

    // MARK: - "Repeats" row: collapsed summary + configured-ness

    /// Fresh recurring task: "Every"/"Pattern" never touched — must read
    /// as unconfigured (the row's "Not Selected" state) for both modes.
    func test_repeatsUnconfigured_whenIntervalNeverPicked() {
        let task = makeRecurringTask()

        XCTAssertFalse(TaskReviewCard.isRepeatsConfigured(task: task, shelf: task.shelf))
    }

    /// Specific Date: configured once "Every" is picked — Pattern doesn't
    /// apply to this mode at all, so it must not be required.
    func test_repeatsConfigured_specificDate_onceEveryPicked() {
        let task = makeRecurringTask()
        task.recurrenceIntervalPicked = true

        XCTAssertTrue(TaskReviewCard.isRepeatsConfigured(task: task, shelf: task.shelf))
        XCTAssertEqual(task.recurrenceSummary, "Every day")
    }

    /// Relative Date: "Every" alone isn't enough — the pattern
    /// (scope/ordinal/weekday) must also be picked before this row reads
    /// as configured, since `recurrenceMode == .relativeDate` folds
    /// Pattern into this same row now.
    func test_repeatsUnconfigured_relativeDate_intervalPickedButPatternNot() {
        let task = makeRecurringTask()
        task.recurrenceMode = .relativeDate
        // "Pattern" is only ever asked for a monthly unit — see
        // `TaskItem.relativeRecurrenceMissing`'s own doc comment for why
        // this now gates on `recurrenceUnit`, not `recurrenceMode`.
        task.recurrenceUnit = .months
        task.recurrenceIntervalPicked = true

        XCTAssertFalse(TaskReviewCard.isRepeatsConfigured(task: task, shelf: task.shelf))
    }

    /// Fail-then-pass target: both mode's collapsed summaries, matching
    /// the values actually configured, reusing `TaskItem.recurrenceSummary`
    /// verbatim (no second, differently-worded formatter).
    func test_repeatsSummary_matchesConfiguredValues_bothModes() {
        let specificTask = makeRecurringTask()
        specificTask.recurrenceIntervalPicked = true
        specificTask.recurrenceIntervalCount = 3
        specificTask.recurrenceUnit = .days
        XCTAssertTrue(TaskReviewCard.isRepeatsConfigured(task: specificTask, shelf: specificTask.shelf))
        XCTAssertEqual(specificTask.recurrenceSummary, "Every 3 days")

        let relativeTask = makeRecurringTask()
        relativeTask.recurrenceMode = .relativeDate
        relativeTask.recurrenceIntervalPicked = true
        relativeTask.relativeRecurrencePicked = true
        relativeTask.relativeRecurrenceScope = .weekdayOfMonth
        relativeTask.relativeRecurrenceOrdinal = .first
        relativeTask.relativeRecurrenceWeekday = 7 // Saturday
        XCTAssertTrue(TaskReviewCard.isRepeatsConfigured(task: relativeTask, shelf: relativeTask.shelf))
        XCTAssertEqual(relativeTask.recurrenceSummary, "Every month on the first Saturday")
    }

    // MARK: - "Starts" row

    func test_startsUnconfigured_beforeStartDatePicked() {
        let task = makeRecurringTask()
        XCTAssertFalse(TaskReviewCard.isStartsConfigured(task: task, shelf: task.shelf))
    }

    func test_startsConfigured_onceStartDateSet() {
        let task = makeRecurringTask()
        task.setStartDate(.now)
        XCTAssertTrue(TaskReviewCard.isStartsConfigured(task: task, shelf: task.shelf))
    }

    // MARK: - "Time" row: folds in Duration/Divisible for Specific Time

    func test_timeUnconfigured_beforeModePicked() {
        let task = makeRecurringTask()
        XCTAssertFalse(TaskReviewCard.isTimeConfigured(task: task, shelf: task.shelf, segmentOptions: []))
    }

    /// AM/Midday/PM never needs Duration/Divisible — configured the
    /// moment the mode itself is picked.
    func test_timeConfigured_untimedMode_needsOnlyModePicked() {
        let task = makeRecurringTask()
        task.recurrenceTimeModePicked = true
        task.recurrenceTimeMode = .am

        XCTAssertTrue(TaskReviewCard.isTimeConfigured(task: task, shelf: task.shelf, segmentOptions: []))
    }

    /// Was `test_durationUnconfigured_specific_modePickedButNoDuration`,
    /// asserting Duration **unconfigured** for a mode-picked recurring
    /// task. **Inverted deliberately.**
    ///
    /// Answering the mode fully configures the Mode-only "Time" row — that
    /// half is unchanged. What changed is the second half: Duration is no
    /// longer a question a recurring task is asked, so it can't be
    /// outstanding. `isDurationConfigured` reads `missingAttributeNames`,
    /// which guards on `CardRow` visibility, so a hidden row is never
    /// reported missing — the `.shown ⟺ missable` invariant doing its job.
    func test_recurringTask_modePicked_neverHasDurationOutstanding() {
        let task = makeRecurringTask()
        task.recurrenceTimeModePicked = true
        task.recurrenceTimeMode = .midday

        XCTAssertTrue(TaskReviewCard.isTimeConfigured(task: task, shelf: task.shelf, segmentOptions: []), "Time is Mode-only now")
        XCTAssertTrue(TaskReviewCard.isDurationConfigured(task: task, shelf: task.shelf), "Duration isn't asked of a recurring task")
    }

    /// Mode + duration both picked, duration NOT splittable
    /// (`segmentOptions` empty, e.g. a prime number of minutes) —
    /// Divisible must not be required, since it wouldn't even appear as a
    /// row. Dropped "specific" from the name: the fixture is a plain
    /// recurring task now, and the unsplittable duration is the whole
    /// point of the test.
    func test_timeConfigured_unsplittableDuration_divisibleNotRequired() {
        let task = makeRecurringTask()
        task.recurrenceTimeModePicked = true
        task.recurrenceTimeMode = .midday
        task.durationPicked = true
        task.estimatedMinutes = 7 // no proper divisors — matches `TaskItem.validSegmentOptions`'s own rule

        XCTAssertTrue(TaskItem.validSegmentOptions(for: 7).isEmpty, "sanity: 7 minutes must not be splittable")
        XCTAssertTrue(TaskReviewCard.isTimeConfigured(task: task, shelf: task.shelf, segmentOptions: []))
    }

    /// Was `test_divisibleUnconfigured_specific_splittableDurationNotAnswered`.
    /// **Inverted for the same reason as the Duration test above** —
    /// Divisible is hidden for every recurring task now, so a splittable
    /// duration no longer leaves it outstanding.
    func test_recurringTask_splittableDuration_neverHasDivisibleOutstanding() {
        let task = makeRecurringTask()
        task.recurrenceTimeModePicked = true
        task.recurrenceTimeMode = .midday
        task.durationPicked = true
        task.estimatedMinutes = 60

        XCTAssertEqual(CardRow.divisible.visibility(task: task, shelf: task.shelf), .hidden,
                       "60 minutes would clear the threshold, but recurring hides Divisible outright")
        XCTAssertTrue(TaskReviewCard.isDivisibleConfigured(task: task, shelf: task.shelf),
                      "a hidden row is never outstanding")
    }

    /// Everything answered — mode, duration, and Divisible (explicitly
    /// "No"). Was named "_specific_"; the fixture is a plain recurring
    /// task now and the test is about full configuration, not the mode.
    func test_timeConfigured_fullyAnswered() {
        let task = makeRecurringTask()
        task.recurrenceTimeModePicked = true
        task.recurrenceTimeMode = .midday
        task.durationPicked = true
        task.estimatedMinutes = 30
        task.divisiblePicked = true
        task.isDivisible = false
        let segmentOptions = TaskItem.validSegmentOptions(for: 30)

        XCTAssertTrue(TaskReviewCard.isTimeConfigured(task: task, shelf: task.shelf, segmentOptions: segmentOptions))
    }

    // MARK: - Unconfigured rows still surface in `missingAttributeNames`

    /// Confirms the redesign didn't quietly disconnect the "Not Selected"
    /// display from the attribute-review queue — both must still agree,
    /// since `isRepeatsConfigured`/`isStartsConfigured`/`isTimeConfigured`
    /// are themselves built directly on `missingAttributeNames`.
    func test_unconfiguredTask_stillReportsMissingAttributes() {
        let task = makeRecurringTask()

        let missing = task.missingAttributeNames(consideringShelf: task.shelf)

        XCTAssertTrue(missing.contains("Every"))
        XCTAssertTrue(missing.contains("Start Date"))
        XCTAssertTrue(missing.contains("Time"))
        XCTAssertFalse(TaskReviewCard.isRepeatsConfigured(task: task, shelf: task.shelf))
        XCTAssertFalse(TaskReviewCard.isStartsConfigured(task: task, shelf: task.shelf))
        XCTAssertFalse(TaskReviewCard.isTimeConfigured(task: task, shelf: task.shelf, segmentOptions: []))
    }

    // MARK: - Fail-then-pass target: `TaskEditSnapshot` round-trips every recurring field

    /// Every recurring-related field, set to a distinctive non-default
    /// value, snapshotted, scrambled, then restored — catches exactly the
    /// class of gap this app already found once (`recurrenceTimeModeRaw`
    /// missing from the snapshot, silently breaking Cancel for a Time-
    /// mode edit). A restructuring turn like this one — several fields
    /// moved to new rows, none of them removed from the model — is
    /// precisely when a field could get quietly dropped from the
    /// snapshot without any single existing test catching it, since the
    /// existing tests each check only one or two fields at a time.
    func test_taskEditSnapshot_roundTripsEveryRecurringField() {
        let task = TaskItem(title: "Original", estimatedMinutes: 10)
        task.isRecurring = true
        task.recurrenceMode = .relativeDate
        task.recurrenceIntervalCount = 3
        task.recurrenceUnit = .weeks
        task.recurrenceIntervalPicked = true
        task.relativeRecurrenceScope = .weekdayOfMonth
        task.relativeRecurrenceOrdinal = .last
        task.relativeRecurrenceWeekday = 3
        task.relativeRecurrencePicked = true
        // `.pm` rather than `.specific` — the round-trip is what's under
        // test, and a task can no longer hold Specific Time.
        task.recurrenceTimeMode = .pm
        task.recurrenceTimeModePicked = true
        task.recurrenceTimeOfDayMinutes = 17 * 60 + 45
        task.recurrenceEndDate = Calendar.current.date(byAdding: .month, value: 6, to: .now)
        task.isPushable = false
        task.startDate = Calendar.current.startOfDay(for: .now)
        task.startDatePicked = true
        task.durationPicked = true
        task.estimatedMinutes = 30
        task.divisiblePicked = true
        task.isDivisible = true
        task.minimumSegmentMinutes = 15

        let snapshot = TaskEditSnapshot(task)

        // Scramble every one of those fields to something else entirely.
        task.isRecurring = false
        task.recurrenceMode = .specificDate
        task.recurrenceIntervalCount = 1
        task.recurrenceUnit = .days
        task.recurrenceIntervalPicked = false
        task.relativeRecurrenceScope = .dayOfMonth
        task.relativeRecurrenceOrdinal = .first
        task.relativeRecurrenceWeekday = 1
        task.relativeRecurrencePicked = false
        task.recurrenceTimeMode = .am
        task.recurrenceTimeModePicked = false
        task.recurrenceTimeOfDayMinutes = nil
        task.recurrenceEndDate = nil
        task.isPushable = true
        task.startDate = nil
        task.startDatePicked = false
        task.durationPicked = false
        task.durationPicked = true
        task.estimatedMinutes = 0
        task.divisiblePicked = false
        task.isDivisible = false
        task.minimumSegmentMinutes = 0

        snapshot.restore(into: task)

        XCTAssertTrue(task.isRecurring)
        XCTAssertEqual(task.recurrenceMode, .relativeDate)
        XCTAssertEqual(task.recurrenceIntervalCount, 3)
        XCTAssertEqual(task.recurrenceUnit, .weeks)
        XCTAssertTrue(task.recurrenceIntervalPicked)
        XCTAssertEqual(task.relativeRecurrenceScope, .weekdayOfMonth)
        XCTAssertEqual(task.relativeRecurrenceOrdinal, .last)
        XCTAssertEqual(task.relativeRecurrenceWeekday, 3)
        XCTAssertTrue(task.relativeRecurrencePicked)
        XCTAssertEqual(task.recurrenceTimeMode, .pm)
        XCTAssertTrue(task.recurrenceTimeModePicked)
        XCTAssertEqual(task.recurrenceTimeOfDayMinutes, 17 * 60 + 45)
        XCTAssertNotNil(task.recurrenceEndDate)
        XCTAssertFalse(task.isPushable)
        XCTAssertNotNil(task.startDate)
        XCTAssertTrue(task.startDatePicked)
        XCTAssertTrue(task.durationPicked)
        XCTAssertTrue(task.durationPicked)
        XCTAssertEqual(task.estimatedMinutes, 30)
        XCTAssertTrue(task.divisiblePicked)
        XCTAssertTrue(task.isDivisible)
        XCTAssertEqual(task.minimumSegmentMinutes, 15)
    }

    // MARK: - `TaskItem.recurrenceShortSummary` — the one-line "Repeats" row form

    /// Realistic worst-case length budget: two-ish-digit interval counts
    /// combined with the longest weekday name in English ("Wednesday," 9
    /// characters). Not the theoretical extreme (interval can technically
    /// reach 365 via the Stepper) — an absurd "Every 365 months" is left
    /// to `CollapsibleAnswerRow`'s own `.lineLimit(1)`/`.truncationMode(.tail)`
    /// safety net to ellipsize, not something the formatter itself needs
    /// to shorten further.
    private let shortSummaryCharacterBudget = 32

    func test_shortSummary_specificDate_singleInterval_isJustTheFrequencyWord() {
        let task = makeRecurringTask()
        task.recurrenceIntervalPicked = true

        XCTAssertEqual(task.recurrenceShortSummary, "Daily")
        // `recurrenceUnit` defaults to `.days`; confirm the other two
        // single-interval words explicitly too.
        task.recurrenceUnit = .weeks
        XCTAssertEqual(task.recurrenceShortSummary, "Weekly")
        task.recurrenceUnit = .months
        XCTAssertEqual(task.recurrenceShortSummary, "Monthly")
        task.recurrenceUnit = .days
        task.recurrenceIntervalCount = 1
        XCTAssertEqual(task.recurrenceShortSummary, "Daily")
    }

    func test_shortSummary_specificDate_multiInterval_usesEveryNForm() {
        let task = makeRecurringTask()
        task.recurrenceIntervalPicked = true
        task.recurrenceIntervalCount = 3
        task.recurrenceUnit = .days

        XCTAssertEqual(task.recurrenceShortSummary, "Every 3 days")
    }

    func test_shortSummary_relativeDate_dayOfMonth_last() {
        let task = makeRecurringTask()
        task.recurrenceMode = .relativeDate
        task.recurrenceIntervalPicked = true
        task.relativeRecurrencePicked = true
        task.relativeRecurrenceScope = .dayOfMonth
        task.relativeRecurrenceOrdinal = .last

        XCTAssertEqual(task.recurrenceShortSummary, "Monthly · last day")
    }

    func test_shortSummary_relativeDate_dayOfMonth_first() {
        let task = makeRecurringTask()
        task.recurrenceMode = .relativeDate
        task.recurrenceIntervalPicked = true
        task.relativeRecurrencePicked = true
        task.relativeRecurrenceScope = .dayOfMonth
        task.relativeRecurrenceOrdinal = .first

        XCTAssertEqual(task.recurrenceShortSummary, "Monthly · 1st")
    }

    /// The user's own named example — "Monthly · 4th Saturday" — with an
    /// interval > 1 too, matching "Every 2 months · last day" 's shape.
    func test_shortSummary_relativeDate_weekdayOfMonth_usesNumeralOrdinal() {
        let task = makeRecurringTask()
        task.recurrenceMode = .relativeDate
        task.recurrenceIntervalPicked = true
        task.relativeRecurrencePicked = true
        task.relativeRecurrenceScope = .weekdayOfMonth
        task.relativeRecurrenceOrdinal = .fourth
        task.relativeRecurrenceWeekday = 7 // Saturday

        XCTAssertEqual(task.recurrenceShortSummary, "Monthly · 4th Saturday")

        task.recurrenceIntervalCount = 2
        task.relativeRecurrenceOrdinal = .last
        task.relativeRecurrenceScope = .dayOfMonth
        XCTAssertEqual(task.recurrenceShortSummary, "Every 2 months · last day")
    }

    /// Fail-then-pass target: never includes the "fourth"/"first" word
    /// form — always the numeral.
    func test_shortSummary_neverUsesWordOrdinals() {
        let task = makeRecurringTask()
        task.recurrenceMode = .relativeDate
        task.recurrenceIntervalPicked = true
        task.relativeRecurrencePicked = true
        task.relativeRecurrenceScope = .weekdayOfMonth
        task.relativeRecurrenceWeekday = 3 // Tuesday

        for ordinal: RelativeRecurrenceOrdinal in [.first, .second, .third, .fourth] {
            task.relativeRecurrenceOrdinal = ordinal
            let summary = task.recurrenceShortSummary ?? ""
            XCTAssertFalse(summary.contains(ordinal.label), "must not contain the word form '\(ordinal.label)': \(summary)")
        }
    }

    /// Every representative pattern combination — both modes, every
    /// scope, the longest weekday name, and a realistic multi-digit
    /// interval — stays within the character budget and produces a
    /// single line (no newline characters at all, the literal meaning of
    /// "one line" at the string level; `CollapsibleAnswerRow`'s
    /// `.lineLimit(1)` is what enforces it visually on top of this).
    func test_shortSummary_everyPatternType_staysUnderCharacterBudget_andIsSingleLine() {
        let task = makeRecurringTask()
        task.recurrenceIntervalPicked = true
        task.relativeRecurrencePicked = true

        var summaries: [String] = []

        task.recurrenceMode = .specificDate
        for unit in RecurrenceUnit.allCases {
            task.recurrenceUnit = unit
            task.recurrenceIntervalCount = 1
            summaries.append(task.recurrenceShortSummary!)
            task.recurrenceIntervalCount = 12
            summaries.append(task.recurrenceShortSummary!)
        }

        task.recurrenceMode = .relativeDate
        for scope in RelativeRecurrenceScope.allCases {
            task.relativeRecurrenceScope = scope
            let ordinals: [RelativeRecurrenceOrdinal] = scope == .dayOfMonth ? [.first, .last] : RelativeRecurrenceOrdinal.allCases
            for ordinal in ordinals {
                task.relativeRecurrenceOrdinal = ordinal
                task.relativeRecurrenceWeekday = 4 // Wednesday — the longest weekday name
                task.recurrenceIntervalCount = 1
                summaries.append(task.recurrenceShortSummary!)
                task.recurrenceIntervalCount = 12
                summaries.append(task.recurrenceShortSummary!)
            }
        }

        for summary in summaries {
            XCTAssertFalse(summary.contains("\n"), "must be a single line: \(summary)")
            XCTAssertLessThanOrEqual(summary.count, shortSummaryCharacterBudget, "exceeds the character budget: \(summary)")
        }
    }

    /// The shelf card's own display (`ShelfListView.recurrenceLine`, via
    /// `TaskItem.recurrenceSummary`) must be completely unaffected by
    /// adding the short form alongside it — the long form's wording is
    /// untouched.
    func test_recurrenceSummary_longForm_unaffectedByShortFormAddition() {
        let task = makeRecurringTask()
        task.recurrenceIntervalPicked = true
        task.relativeRecurrencePicked = true
        task.recurrenceMode = .relativeDate
        task.relativeRecurrenceScope = .weekdayOfMonth
        task.relativeRecurrenceOrdinal = .fourth
        task.relativeRecurrenceWeekday = 7

        XCTAssertEqual(task.recurrenceSummary, "Every month on the fourth Saturday")
        XCTAssertEqual(task.recurrenceShortSummary, "Monthly · 4th Saturday")
    }

    // MARK: - Auto-collapse: initialExpandedRow (recurring)

    /// Nothing answered yet — must seed the *first* row in display
    /// order, not just any unconfigured one.
    func test_initialExpandedRow_recurring_freshTask_seedsRepeats() {
        let task = makeRecurringTask()

        XCTAssertEqual(TaskReviewCard.initialExpandedRow(task: task, shelf: task.shelf, segmentOptions: []), .repeats)
    }

    /// Repeats answered, Starts isn't — must skip past the already-
    /// configured row to the next unconfigured one, not stop at the
    /// first row in the list regardless of its state.
    func test_initialExpandedRow_recurring_repeatsAnsweredStartsNot_seedsStarts() {
        let task = makeRecurringTask()
        task.recurrenceIntervalPicked = true

        XCTAssertEqual(TaskReviewCard.initialExpandedRow(task: task, shelf: task.shelf, segmentOptions: []), .canStartBy)
    }

    /// Repeats and Starts both answered, Time isn't.
    func test_initialExpandedRow_recurring_onlyTimeUnanswered_seedsTime() {
        let task = makeRecurringTask()
        task.recurrenceIntervalPicked = true
        task.startDatePicked = true

        XCTAssertEqual(TaskReviewCard.initialExpandedRow(task: task, shelf: task.shelf, segmentOptions: []), .timeMode)
    }

    /// Everything answered — the card must open fully collapsed, and
    /// `.ends` must never be the seed even though "Never" (its default)
    /// technically has no "picked" flag of its own — Ends simply isn't a
    /// candidate at all, matching its pre-existing "never auto-expands"
    /// behavior.
    func test_initialExpandedRow_recurring_everythingAnswered_seedsNil() {
        let task = makeRecurringTask()
        task.recurrenceIntervalPicked = true
        task.startDatePicked = true
        task.recurrenceTimeModePicked = true

        XCTAssertNil(TaskReviewCard.initialExpandedRow(task: task, shelf: task.shelf, segmentOptions: []))
    }

    // MARK: - Auto-collapse: Repeats stays open until every REQUIRED sub-field is picked

    /// `relativeRecurrenceMissing` gates "Pattern" on one flag
    /// (`relativeRecurrencePicked`), not on Position/Weekday individually
    /// — picking "On the" alone (via `selectMonthlyScope`) already
    /// satisfies it, same as `test_repeatsConfigured_specificDate_onceEveryPicked`
    /// already shows for the non-monthly case. This is exactly why the
    /// self-collapse check does **not** live on "On the"'s own
    /// `PickedMenuPicker` call site (see that call site's own comment in
    /// `repeatsExpandedContent`) — checking there would collapse the row
    /// before Day/Position/Weekday, the actually-last-rendered controls
    /// for this branch, have even appeared. Position/Weekday themselves
    /// already have real stored defaults (`RelativeRecurrenceOrdinal`,
    /// `relativeRecurrenceWeekday ?? 1`), same "accepting a default
    /// counts as answering" shape the interval `Stepper`'s own default
    /// does — they're refinements of an already-answered Pattern, not
    /// additional gates on it.
    func test_repeatsConfigured_relativeDate_onceScopePicked_positionWeekdayStillAtDefaults() {
        let task = makeRecurringTask()
        task.recurrenceUnit = .months
        task.recurrenceIntervalPicked = true

        XCTAssertFalse(TaskReviewCard.isRepeatsConfigured(task: task, shelf: task.shelf), "Pattern not yet picked at all")

        TaskReviewCard.selectMonthlyScope(.weekdayOfMonth, on: task)

        XCTAssertTrue(task.relativeRecurrencePicked)
        XCTAssertTrue(TaskReviewCard.isRepeatsConfigured(task: task, shelf: task.shelf), "scope alone answers Pattern — Position/Weekday need no separate pick")
    }

    /// The genuinely still-open case: interval picked, unit is `.months`,
    /// but "On the" itself hasn't been picked yet — the one real gate
    /// `relativeRecurrenceMissing` has. Complements
    /// `test_repeatsUnconfigured_relativeDate_intervalPickedButPatternNot`,
    /// which already covers this same shape.
    func test_repeatsUnconfigured_relativeDate_intervalPickedScopeNot_thenScopeAnswers() {
        let task = makeRecurringTask()
        task.recurrenceUnit = .months
        task.recurrenceIntervalPicked = true

        XCTAssertFalse(TaskReviewCard.isRepeatsConfigured(task: task, shelf: task.shelf))

        TaskReviewCard.selectMonthlyScope(.dayOfMonth, on: task)
        TaskReviewCard.selectDayOfMonthPosition(.sameAsAnchor, on: task)

        XCTAssertTrue(TaskReviewCard.isRepeatsConfigured(task: task, shelf: task.shelf))
    }

    // MARK: - Auto-collapse: accepting an already-current value still answers the row

    /// `PickedMenuPicker` fires its `onSelect` even when re-choosing the
    /// value already showing (see that type's own doc comment) — proving
    /// the *effect* that depends on: calling a `selectXxx` function with
    /// the task's current value must still flip its "picked" flag, which
    /// is what lets the row's self-collapse condition become true purely
    /// from accepting a default, with no value change at all.
    func test_selectRecurrenceUnit_withValueAlreadyCurrent_stillMarksPicked() {
        let task = makeRecurringTask()
        task.recurrenceUnit = .days
        XCTAssertFalse(task.recurrenceIntervalPicked)

        TaskReviewCard.selectRecurrenceUnit(.days, on: task) // same value as already set

        XCTAssertTrue(task.recurrenceIntervalPicked)
        XCTAssertEqual(task.recurrenceUnit, .days, "must not have changed the value, only the picked flag")
        XCTAssertTrue(TaskReviewCard.isRepeatsConfigured(task: task, shelf: task.shelf), "Specific Date mode needs nothing past Every, so accepting the default alone must fully answer this row")
    }

    // MARK: - Auto-collapse: initialExpandedRows — new vs. existing task

    /// A brand-new task (never saved) opens with every row for its mode
    /// expanded at once — not just the unanswered ones, `.ends` included
    /// — regardless of anything already being answered. The card is a
    /// form to work down, not a compact summary to read.
    func test_initialExpandedRows_recurring_newTask_seedsEveryRow_evenIfSomeAlreadyAnswered() {
        let task = makeRecurringTask()
        task.recurrenceIntervalPicked = true // already answered — must not shrink the seeded set

        let rows = TaskReviewCard.initialExpandedRows(task: task, shelf: task.shelf, segmentOptions: [], isNewlyCreated: true)

        XCTAssertEqual(rows, [.repeats, .canStartBy, .timeMode, .ends], "no .duration/.divisible — a fresh recurring task defaults to Midday, which is untimed")
    }

    /// A reopened, already-saved, fully-configured task opens fully
    /// collapsed — the empty set, not just a `nil` single row.
    func test_initialExpandedRows_recurring_existingTask_fullyConfigured_seedsNothing() {
        let task = makeRecurringTask()
        task.recurrenceIntervalPicked = true
        task.startDatePicked = true
        task.recurrenceTimeModePicked = true

        let rows = TaskReviewCard.initialExpandedRows(task: task, shelf: task.shelf, segmentOptions: [], isNewlyCreated: false)

        XCTAssertTrue(rows.isEmpty)
    }

    /// A reopened, already-saved task with exactly one field left
    /// unanswered opens with only that field expanded — `initialExpandedRows`
    /// wrapping `initialExpandedRow` unchanged, per the earlier requirement.
    func test_initialExpandedRows_recurring_existingTask_oneUnanswered_seedsOnlyThatRow() {
        let task = makeRecurringTask()
        task.recurrenceIntervalPicked = true
        // Starts left unanswered.
        task.recurrenceTimeModePicked = true

        let rows = TaskReviewCard.initialExpandedRows(task: task, shelf: task.shelf, segmentOptions: [], isNewlyCreated: false)

        XCTAssertEqual(rows, [.canStartBy])
    }

    /// Filling in a field on a new task collapses only that field — the
    /// same "picked flag flips, isXConfigured reads true" mechanism
    /// self-collapse is conditioned on (`expandedRows.remove(.x)` at each
    /// call site), demonstrated here against a starting set that has
    /// every other row open too. `Set.remove` only ever touches the
    /// element named, so the other three rows being left alone isn't
    /// separately asserted — that's a stdlib guarantee, not new logic.
    func test_fillingRepeatsOnNewTask_wouldCollapseOnlyRepeats() {
        let task = makeRecurringTask()
        let seeded = TaskReviewCard.initialExpandedRows(task: task, shelf: task.shelf, segmentOptions: [], isNewlyCreated: true)
        XCTAssertEqual(seeded, [.repeats, .canStartBy, .timeMode, .ends], "starting point: everything that applies is open — Duration/Divisible don't, since a fresh recurring task is Midday/untimed")

        TaskReviewCard.selectRecurrenceUnit(task.recurrenceUnit, on: task) // answers Repeats (Specific Date needs nothing else)

        XCTAssertTrue(TaskReviewCard.isRepeatsConfigured(task: task, shelf: task.shelf), "this is the condition each self-collapse call site checks before removing just .repeats from expandedRows")
    }

    // MARK: - Untimed recurring: Duration/Divisible rows don't exist

    /// Regression test. Duration and Divisible used to be rendered inside
    /// `timeExpandedContent`'s `recurrenceTimeMode == .specific` branch;
    /// flattening them into their own rows dropped that gate and both
    /// started appearing for AM/Midday/PM recurring tasks, where an
    /// untimed occurrence never gets a calendar block and neither field
    /// means anything.
    ///
    /// Nothing caught it because the existing coverage asserts
    /// `durationMissing`/`divisibleMissing` are false for untimed tasks —
    /// which stayed true the whole time. The *rows* were never asserted.
    /// That gap is the actual lesson: "not reported missing" and "not
    /// shown" were two separate facts with nothing tying them together.
    func test_untimedRecurringTask_hidesDurationAndDivisibleRows() {
        for mode in [HabitOccurrenceTimeMode.am, .midday, .pm] {
            let task = makeRecurringTask()
            task.recurrenceTimeModePicked = true
            task.recurrenceTimeMode = mode
            // A duration that would otherwise clear every other bar —
            // 120 minutes is well past the divisible threshold and has
            // plenty of valid segment sizes.
            TaskItem.selectDuration(120, on: task)

            XCTAssertFalse(TaskReviewCard.showsDurationRow(task: task), "\(mode) must not show a Duration row")
            XCTAssertFalse(TaskReviewCard.showsDivisibleRow(task: task), "\(mode) must not show a Divisible row")
        }
    }

    /// Was `test_specificTimeRecurringTask_showsDurationAndDivisibleRows`,
    /// asserting `showsDurationRow` **true**. **Inverted deliberately.**
    ///
    /// It was "the other side of the same gate": Specific Time was the one
    /// recurring mode that got a calendar block, so it was the one that
    /// needed a length. There is no other side any more — a task can't be
    /// Specific Time, so no recurring task gets a block and none shows
    /// Duration. The gate itself (`recurringAndUntimed`) is unchanged; what
    /// changed is that nothing can land on the other side of it.
    func test_noRecurringTask_showsDurationOrDivisibleRows() {
        let task = makeRecurringTask()
        task.recurrenceTimeModePicked = true
        task.recurrenceTimeMode = .midday
        TaskItem.selectDuration(120, on: task)

        XCTAssertFalse(TaskReviewCard.showsDurationRow(task: task))
        XCTAssertEqual(CardRow.divisible.visibility(task: task, shelf: task.shelf), .hidden)
    }

    /// A non-recurring task has no time-mode concept at all, so the gate
    /// must never suppress its Duration row.
    func test_nonRecurringTask_alwaysShowsDurationRow() {
        let task = TaskItem(title: "Ordinary", estimatedMinutes: 30)

        XCTAssertTrue(TaskReviewCard.showsDurationRow(task: task))
    }

    /// The row-visibility predicate and the missing-check must agree —
    /// this is the pairing whose absence let the regression through.
    func test_untimedRecurring_rowHiddenAndNotReportedMissing_together() {
        let task = makeRecurringTask()
        task.recurrenceTimeModePicked = true
        task.recurrenceTimeMode = .am
        TaskItem.selectDuration(120, on: task)

        let missing = task.missingAttributeNames(consideringShelf: task.shelf)
        XCTAssertFalse(TaskReviewCard.showsDurationRow(task: task))
        XCTAssertFalse(missing.contains("Duration"), "hidden and not-missing must hold together")
        XCTAssertFalse(TaskReviewCard.showsDivisibleRow(task: task))
        XCTAssertFalse(missing.contains("Divisible"))
    }

    /// Seeding must not expand a row that can't render.
    func test_initialExpandedRows_untimedRecurringNewTask_omitsDurationAndDivisible() {
        let task = makeRecurringTask()
        task.recurrenceTimeModePicked = true
        task.recurrenceTimeMode = .am
        TaskItem.selectDuration(120, on: task)

        let rows = TaskReviewCard.initialExpandedRows(
            task: task, shelf: task.shelf, segmentOptions: [], isNewlyCreated: true
        )

        XCTAssertEqual(rows, [.repeats, .canStartBy, .timeMode, .ends])
    }
}
