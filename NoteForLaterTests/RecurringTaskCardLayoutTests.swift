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

    /// Specific Time with the mode picked but no duration yet — still
    /// unconfigured, since Duration is now folded into this row.
    func test_timeUnconfigured_specific_modePickedButNoDuration() {
        let task = makeRecurringTask()
        task.recurrenceTimeModePicked = true
        task.recurrenceTimeMode = .specific

        XCTAssertFalse(TaskReviewCard.isTimeConfigured(task: task, shelf: task.shelf, segmentOptions: []))
    }

    /// Specific Time, mode + duration both picked, duration NOT
    /// splittable (`segmentOptions` empty, e.g. a prime number of
    /// minutes) — Divisible must not be required, since it wouldn't even
    /// appear as a row.
    func test_timeConfigured_specific_unsplittableDuration_divisibleNotRequired() {
        let task = makeRecurringTask()
        task.recurrenceTimeModePicked = true
        task.recurrenceTimeMode = .specific
        task.durationDecided = true
        task.durationAnsweredYes = true
        task.estimatedMinutes = 7 // no proper divisors — matches `TaskItem.validSegmentOptions`'s own rule

        XCTAssertTrue(TaskItem.validSegmentOptions(for: 7).isEmpty, "sanity: 7 minutes must not be splittable")
        XCTAssertTrue(TaskReviewCard.isTimeConfigured(task: task, shelf: task.shelf, segmentOptions: []))
    }

    /// Specific Time, mode + duration picked, duration IS splittable, but
    /// Divisible itself hasn't been answered — must read unconfigured,
    /// since the row now appears and asks the question.
    func test_timeUnconfigured_specific_splittableDuration_divisibleNotAnswered() {
        let task = makeRecurringTask()
        task.recurrenceTimeModePicked = true
        task.recurrenceTimeMode = .specific
        task.durationDecided = true
        task.durationAnsweredYes = true
        task.estimatedMinutes = 30
        let segmentOptions = TaskItem.validSegmentOptions(for: 30)

        XCTAssertFalse(segmentOptions.isEmpty, "sanity: 30 minutes must be splittable")
        XCTAssertFalse(TaskReviewCard.isTimeConfigured(task: task, shelf: task.shelf, segmentOptions: segmentOptions))
    }

    /// Full Specific Time configuration — mode, duration, and Divisible
    /// (explicitly answered "No") all decided.
    func test_timeConfigured_specific_fullyAnswered() {
        let task = makeRecurringTask()
        task.recurrenceTimeModePicked = true
        task.recurrenceTimeMode = .specific
        task.durationDecided = true
        task.durationAnsweredYes = true
        task.estimatedMinutes = 30
        task.isDivisibleDecided = true
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
        task.recurrenceTimeMode = .specific
        task.recurrenceTimeModePicked = true
        task.recurrenceTimeOfDayMinutes = 17 * 60 + 45
        task.recurrenceEndDate = Calendar.current.date(byAdding: .month, value: 6, to: .now)
        task.isPushable = false
        task.startDate = Calendar.current.startOfDay(for: .now)
        task.startDatePicked = true
        task.durationDecided = true
        task.durationAnsweredYes = true
        task.estimatedMinutes = 30
        task.isDivisibleDecided = true
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
        task.durationDecided = false
        task.durationAnsweredYes = false
        task.estimatedMinutes = 0
        task.isDivisibleDecided = false
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
        XCTAssertEqual(task.recurrenceTimeMode, .specific)
        XCTAssertTrue(task.recurrenceTimeModePicked)
        XCTAssertEqual(task.recurrenceTimeOfDayMinutes, 17 * 60 + 45)
        XCTAssertNotNil(task.recurrenceEndDate)
        XCTAssertFalse(task.isPushable)
        XCTAssertNotNil(task.startDate)
        XCTAssertTrue(task.startDatePicked)
        XCTAssertTrue(task.durationDecided)
        XCTAssertTrue(task.durationAnsweredYes)
        XCTAssertEqual(task.estimatedMinutes, 30)
        XCTAssertTrue(task.isDivisibleDecided)
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
}
