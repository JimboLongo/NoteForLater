import Foundation
import SwiftData

/// A task, sorted or not. `shelf == nil` means it's sitting unsorted in
/// the Inbox; everything else about it — attributes, tags, scheduling
/// eligibility — works identically either way. Only tasks on a shelf with
/// an enabled SchedulingRule are candidates for auto-scheduling.
@Model
final class TaskItem {
    var id: UUID
    var title: String
    var notes: String
    var createdAt: Date

    /// Set when this task came from a Gmail sync rather than manual
    /// typing, so re-syncing doesn't create duplicates for mail already
    /// imported — checked across every task, not just unsorted ones,
    /// since a synced item stays tagged after it's routed to a shelf.
    var sourceGmailMessageID: String?

    var dueDate: Date?
    /// Whether "Has due date" has actually been answered (either way) —
    /// `dueDate == nil` alone can't tell "never asked" apart from
    /// "explicitly no due date," so this tracks the answer separately.
    /// See `YesNoToggle`.
    var dueDateDecided: Bool = false
    /// True once a real date has actually been picked, for the "Yes" case
    /// only — `dueDate` gets auto-filled to `.now` the moment "Has due
    /// date" flips to Yes (so the picker has something sensible to show),
    /// which would otherwise look complete despite nobody having chosen a
    /// date yet. Irrelevant when the answer is "No" (`dueDate == nil`
    /// already says everything there).
    var dueDatePicked: Bool = false
    /// The earliest day this task may land on the calendar — `nil` means
    /// no restriction (the card's picker just shows today until touched;
    /// there's no separate Yes/No question the way `dueDate` has, so `nil`
    /// only ever means "never touched," not "explicitly none"). Distinct
    /// from `dueDate` (a deadline, not a floor): a task can have either,
    /// both, or neither. `AISchedulingService` excludes a task from a
    /// given day's candidate packing whenever that day falls before this
    /// one, the same way `isScheduled` already excludes an already-placed
    /// task.
    var startDate: Date?
    /// True once Start Date has actually been set through `setStartDate(_:)`
    /// — `startDate == nil` alone can't tell "never touched" apart from a
    /// hypothetical "explicitly cleared," and more importantly the Start
    /// Date control's own display previously fell back to showing today
    /// for an untouched task, making a deliberate choice of today
    /// indistinguishable from no choice at all. See `setStartDate(_:)`.
    var startDatePicked: Bool = false
    var nextStep: String = ""
    /// Whether "Has next step" has actually been answered (either way) —
    /// same shape as `dueDateDecided`: a bare `nextStep == ""` can't tell
    /// "never decided" apart from "deliberately none," so a task with no
    /// next step needed was flagged incomplete forever with no way to
    /// resolve it. See `YesNoToggle`.
    var nextStepDecided: Bool = false
    /// Which pill "Has next step" landed on, independent of `nextStep` —
    /// the same reason Duration used to carry a second flag before it
    /// collapsed to one wheel (see `durationPicked`): Yes can be selected
    /// before any text is actually typed, and No clears `nextStep` back
    /// to `""`. Without this, "Yes, nothing typed yet" and "No" would
    /// both collapse to `nextStep.isEmpty`, making them indistinguishable.
    /// Only meaningful when `nextStepDecided` is true.
    var nextStepAnsweredYes: Bool = false
    /// 0 means "no duration set" — see `durationLabel(for:)`. The user's
    /// stated size; never written by the scheduler. Compare against
    /// `remainingMinutes` for what's actually left to place.
    var estimatedMinutes: Int = 0
    /// What's left to place — initialized to `estimatedMinutes`, decremented
    /// by `AISchedulingService.pack()` as segments of a divisible task get
    /// placed, and restored by `ScheduleReviewViewModel
    /// .clearIncompletePastBlocks` when a partial placement is freed back
    /// up. Kept separate from `estimatedMinutes` so a partially-scheduled
    /// divisible task doesn't have its own stated duration silently shrink
    /// — the task card always shows `estimatedMinutes`, with "X of Y
    /// scheduled" once this drops below it.
    var remainingMinutes: Int = 0
    /// Whether Duration has actually been answered — the one flag that
    /// distinguishes "never touched" from "deliberately None," since
    /// `estimatedMinutes == 0` is itself a real, choosable answer
    /// (the wheel's "None" option, meaning *don't schedule this* — see
    /// `SchedulingRule.fitStatus`'s `.needsDuration`). Same `...Picked`
    /// convention as `startDatePicked`/`dueDatePicked`/
    /// `recurrenceIntervalPicked`.
    ///
    /// Renamed from `durationDecided` when Duration collapsed from a
    /// Yes/No-pills-plus-wheel pair into a single wheel;
    /// `@Attribute(originalName:)` keeps it mapped to that same column so
    /// existing answers survive the rename (see `docs/session-handoff.md`'s
    /// SwiftData trap entry). The old `durationAnsweredYes` half lives on
    /// only as `legacyDurationAnsweredYes` below, read once by the
    /// migration that reconciles the two.
    @Attribute(originalName: "durationDecided")
    var durationPicked: Bool = false
    /// The retired Yes/No half of the old two-question Duration control.
    /// Written only by code that no longer exists; read exactly once, by
    /// `NoteForLaterApp.migrateDurationDivisibleToSingleWheelIfNeeded`,
    /// to tell the one pair of old states apart that `estimatedMinutes`
    /// alone can't: "said Yes but never picked a value" (still
    /// unanswered) versus "said No" (deliberately None). Both have
    /// `estimatedMinutes == 0`. Dead weight after that migration runs —
    /// left in place rather than removed, since removing it later is a
    /// no-risk cleanup and re-adding it after shipping without it would
    /// not recover lost data.
    @Attribute(originalName: "durationAnsweredYes")
    var legacyDurationAnsweredYes: Bool = false
    var tags: [String] = []
    var priorityRaw: String = Priority.unset.rawValue
    var isScheduled: Bool = false
    /// The pre-three-state `isCompleted: Bool` column, kept alive under a
    /// new Swift name so its data survives the schema change instead of
    /// being silently discarded — `@Attribute(originalName:)` keeps this
    /// mapped to the same underlying storage the old stored `isCompleted`
    /// used, so a lightweight migration doesn't touch it at all. Written
    /// once, by the old code, before this property existed; never written
    /// again after that. Read exactly once, by `NoteForLaterApp
    /// .migrateIncompleteBlocksAndMealsToThreeStateIfNeeded`, to seed
    /// `status` correctly for data that predates it — **without this,
    /// every historically-completed task would silently read back as
    /// never-completed** the moment `statusRaw` (a brand-new column with
    /// no historical data of its own) took over as the source of truth.
    /// Confirmed empirically (a throwaway SwiftData migration probe, not
    /// assumed) before relying on it: a stored property that becomes
    /// computed loses its old column's data on the very first open with
    /// the new schema unless the old column is kept mapped like this.
    /// Dead weight after the migration runs — left in place rather than
    /// removed, since removing it later is a no-risk cleanup and adding
    /// it back after shipping without it would not recover lost data.
    @Attribute(originalName: "isCompleted")
    var legacyIsCompleted: Bool = false
    /// Set the moment `NoteForLaterApp
    /// .migrateIncompleteBlocksAndMealsToThreeStateIfNeeded` derives this
    /// row's `status` from `legacyIsCompleted` — checked *before* deriving,
    /// not just recorded after, so a second invocation (the one realistic
    /// path: that function's own `UserDefaults` completion flag failing to
    /// persist after a successful `context.save()` — a crash in that
    /// narrow window) skips this row entirely rather than re-deriving it.
    /// Re-deriving would silently reclassify a row the app has touched
    /// since — including a task the user deliberately cycled back to
    /// `.none` — because `.none` is indistinguishable from "not yet
    /// migrated" by itself. Committed in the *same* `context.save()` call
    /// as the `status` write it guards, so SwiftData's transaction
    /// guarantee (all-or-nothing) means the two can never land out of
    /// sync: either both persist or neither does. Permanent dead weight
    /// after that one save succeeds, same as `legacyIsCompleted`.
    var hasMigratedThreeState: Bool = false
    /// Backing storage for `status` — see `OccurrenceStatus`'s own doc
    /// comment. Defaults to `.none`'s raw value so a pre-migration row
    /// (no `statusRaw` column at all yet) reads as untouched until
    /// `migrateIncompleteBlocksAndMealsToThreeStateIfNeeded` seeds it from
    /// `legacyIsCompleted` — matching the old `isCompleted: Bool`'s own
    /// default of `false` in the meantime.
    var statusRaw: String = OccurrenceStatus.none.rawValue
    /// The task's own three-state completion — `.missed` is reachable
    /// for any task now, not only a recurring occurrence's day-scoped
    /// one (that's still `RecurringTaskLog`, untouched). Never writes
    /// `.excused` — see `OccurrenceStatus.cycledExcludingExcused`, the
    /// one shared cycle this and `ScheduledBlock`/`MealSelection` all
    /// use.
    var status: OccurrenceStatus {
        get { OccurrenceStatus(rawValue: statusRaw) ?? .none }
        set { statusRaw = newValue.rawValue }
    }
    /// `statusRaw` is the only real storage — this and `status` are both
    /// just views onto it, so there's nothing to keep in sync and
    /// nothing that can drift out of sync. Stays fully settable
    /// (`get`/`set`, not get-only) so every existing call site
    /// (`task.isCompleted = true`, `setCompleted`, shelf swipe actions,
    /// `DailyDigestCheckInView`, ...) keeps compiling and working
    /// unchanged — none of them need to know a third state exists.
    ///
    /// The one deliberate, load-bearing consequence: **setting `false`
    /// always lands on `.none`, never preserves `.missed`.** A bare bool
    /// write has no way to express three states, so it can only ever
    /// mean "not complete, undecided" — not "reassert whatever
    /// missed-ness was already there." Only code that's aware of the
    /// three-state cycle can ever produce `.missed` at all (it writes
    /// `.status` directly), so this only ever collapses a state nothing
    /// *un*-aware of `.missed` could have meant to preserve in the first
    /// place. Setting `true` is unambiguous either way.
    var isCompleted: Bool {
        get { status == .complete }
        set { status = newValue ? .complete : .none }
    }
    /// True only between "Next" on the Nightly Review Today step and the
    /// push that follows — see `NightlyReviewView.advance()`'s
    /// today→inbox transition. Not durable state on a surviving task:
    /// every stamped task is reset to `false` by the end of that same
    /// batch, whether it was completed (deleted outright, if
    /// non-recurring) or freed back up as an ordinary incomplete
    /// candidate.
    ///
    /// Diagnostic only — nothing reads this field. The actual freeze
    /// (what makes the batch immune to the async-gap/midnight-drift
    /// hazard this was meant to solve) comes from `reviewedBlocks`/
    /// `frozenCutoff`/`frozenAllBlocks`, local `let`s captured
    /// synchronously in `advance()` before its `Task {}` starts. Those
    /// locals are what's actually load-bearing; this field just makes a
    /// stamped task visibly identifiable (e.g. in the debugger or a
    /// future inspector UI) while it's mid-batch. Do not wire it into
    /// `reviewableBlocks` or any other live query — that would create a
    /// second, redundant source of truth for something the locals
    /// already answer correctly.
    var isNightlyReviewed: Bool = false
    /// How many times a scheduled block for this task has been deleted off
    /// the calendar (swipe-to-delete, the Delete action, or "Assume Not
    /// Completed" sweeping it up) — a running count of how often this task
    /// gets bumped rather than actually done, not reset by rescheduling.
    var pushedCount: Int = 0
    /// Opts this task out of Task Attribute Review and Nightly Review's
    /// attribute-cleanup step for a chosen number of days, even while
    /// `isMissingAttributes` is true — a temporary escape hatch for a task
    /// you've decided not to think about right now, rather than a
    /// permanent silence. Compare against `.now` (see
    /// `isSnoozedFromAttributeReview`) rather than deleting this once it
    /// passes, so the last snooze length picked stays visible if it's
    /// ever snoozed again.
    var attributeReviewSnoozedUntil: Date?

    var isSnoozedFromAttributeReview: Bool {
        guard let attributeReviewSnoozedUntil else { return false }
        return attributeReviewSnoozedUntil > .now
    }

    /// "Remind Me In" — only ever shown on the card for a shelf with
    /// `Shelf.effectiveTracksFutureReminder` on. `0` means no reminder is
    /// set. See `applyRemindIn`, which turns this + `remindInUnit` into
    /// the actual `attributeReviewSnoozedUntil` date that hides the task
    /// from the attribute-review queue until it's up — the exact same
    /// mechanism the Snooze action already uses, just driven by a
    /// persistent count/unit pair on the card instead of a one-off pick
    /// made during review.
    var remindInCount: Int = 0
    var remindInUnitRaw: String = RecurrenceUnit.days.rawValue
    var remindInUnit: RecurrenceUnit {
        get { RecurrenceUnit(rawValue: remindInUnitRaw) ?? .days }
        set { remindInUnitRaw = newValue.rawValue }
    }

    /// Recomputes `attributeReviewSnoozedUntil` from `remindInCount`/
    /// `remindInUnit`, anchored to `referenceDate` — called whenever
    /// either wheel changes on the task card. `remindInCount <= 0` clears
    /// the reminder (and any snooze it was driving) entirely.
    func applyRemindIn(referenceDate: Date = .now, calendar: Calendar = .current) {
        guard remindInCount > 0 else {
            attributeReviewSnoozedUntil = nil
            return
        }
        let component: Calendar.Component
        switch remindInUnit {
        case .days: component = .day
        case .weeks: component = .weekOfYear
        case .months: component = .month
        }
        attributeReviewSnoozedUntil = calendar.date(byAdding: component, value: remindInCount, to: referenceDate)
    }

    /// Whether this task belongs in the attribute-review queue purely
    /// because its "Remind Me In" timer is up — independent of
    /// `isMissingAttributes`, since a reminder can be set on an otherwise
    /// fully-filled-out task that just needs a future second look.
    var isDueForFutureReminder: Bool {
        remindInCount > 0 && !isSnoozedFromAttributeReview
    }

    /// Whether this task repeats — toggleable from "Recurring?" at the top
    /// of any task card, on any shelf. The anchor point — the first
    /// occurrence, and the time-of-day every later occurrence reuses — is
    /// `dueDate` itself; there's no separate "start date" field.
    /// `AISchedulingService.placeHabitsAndRecurringTasks` is what actually
    /// turns this into calendar blocks, one per occurrence day, computed
    /// fresh from `hasRecurringOccurrence`/`recurringOccurrenceTime` rather
    /// than stored anywhere.
    var isRecurring: Bool = false
    /// The "every X" in "every X days/weeks/months" — always >= 1.
    var recurrenceIntervalCount: Int = 1
    var recurrenceUnitRaw: String = RecurrenceUnit.days.rawValue
    /// Whether "Every" (the interval count + unit pair above) has
    /// actually been deliberately set — same "picked" shape
    /// `startDatePicked`/`dueDatePicked` already use. `recurrenceIntervalCount`/
    /// `recurrenceUnitRaw` start on real, storable defaults ("every 1
    /// day"), not an obviously-incomplete placeholder, so without this a
    /// fresh recurring task would silently sit on that default forever
    /// with nothing prompting it to be confirmed. See `startDateMissing`'s
    /// doc comment for the same reasoning applied to Start Date.
    var recurrenceIntervalPicked: Bool = false
    /// nil means "indefinitely."
    var recurrenceEndDate: Date?
    /// Reuses `HabitOccurrenceTimeMode` rather than a second, parallel
    /// enum — `.specific` means exactly today's existing behavior (placed
    /// on the calendar at its own clock time, via
    /// `recurringOccurrenceTime`); `.am`/`.midday`/`.pm` means this
    /// occurrence never gets a `ScheduledBlock` at all (see
    /// `AISchedulingService.placeHabitsAndRecurringTasks`'s skip, mirrored
    /// from the habit one) and instead shows as a plain check-off item in
    /// that part of the day (see `DayTimelineGridView`), completion
    /// tracked in `RecurringTaskLog` rather than a block's own
    /// `isCompleted` — a recurring task has no single, one-time
    /// completion state the way a plain block does, the same reason
    /// habits needed `HabitLog` instead of reusing `ScheduledBlock` for
    /// this.
    ///
    /// Defaults to `.midday` — a genuinely untimed placement, not a
    /// silently-timed one — so a fresh recurring task's "Time" row reads
    /// a real, sensible value ("Midday") the instant it's expanded,
    /// instead of an empty-feeling "Specific Time" with the clock
    /// sitting on whatever `recurrenceTimeOfDayMinutes` happens to
    /// default to. This only affects a `TaskItem` constructed after this
    /// change — an already-persisted row keeps whatever concrete value
    /// SwiftData already wrote for it, the same way every stored-property
    /// default here only ever governs brand new rows going forward.
    var recurrenceTimeModeRaw: String = HabitOccurrenceTimeMode.midday.rawValue
    /// Whether "Time" (AM/Midday/PM/Specific, above) has actually been
    /// deliberately set — `.midday` is `recurrenceTimeModeRaw`'s real
    /// stored default, not evidence anyone chose it. Same "picked" shape
    /// as `recurrenceIntervalPicked`.
    var recurrenceTimeModePicked: Bool = false
    /// Whether a missed occurrence of this recurring task gets carried
    /// forward onto future days at all — default `true` matches every
    /// task's behavior before this existed (an opt-out, not an opt-in).
    /// `false` means a missed occurrence just stays missed on its own day
    /// and waits for the next natural recurrence: no
    /// `PushedRecurringOccurrence` gets created for it
    /// (`ScheduleReviewViewModel.pushRecurringOccurrenceIfNeeded` no-ops),
    /// and it's excluded from the display-only carry-forward projection
    /// (`.carriedForwardRecurringTaskIDs`) too. See
    /// `PushedRecurringOccurrence`'s own doc comment for how this
    /// interacts with `recurrenceEndDate`.
    var isPushable: Bool = true
    /// The Specific-Time occurrence's own clock time, minutes since
    /// midnight — same representation `Habit.idealTimesOfDay` already
    /// uses for the identical concept. `nil` means "never explicitly
    /// set" (a recurring task created before this field existed, or one
    /// that's never opened the Specific Time picker) — `recurringOccurrenceTime`
    /// falls back to `dueDate`'s own time-of-day for those, so nothing
    /// already placed moves until this is actually touched. Deliberately
    /// separate from `dueDate`: before this existed, the time picker
    /// would have had nowhere else to write except the recurrence
    /// anchor itself, silently repurposing a date field as a time store
    /// and coupling two questions ("which day does this pattern start
    /// on" and "what time does it land at") that don't need to be one.
    var recurrenceTimeOfDayMinutes: Int?

    /// Which evaluator `hasRecurringOccurrence` uses for this task — see
    /// `RecurrenceMode`'s own doc comment. Defaults to `.specificDate`,
    /// so every recurring task that existed before this field did keeps
    /// running through the exact same, unmodified date math.
    var recurrenceModeRaw: String = RecurrenceMode.specificDate.rawValue
    /// The Relative Date pattern's shape — only meaningful when
    /// `recurrenceMode == .relativeDate`. See `RelativeRecurrenceScope`.
    var relativeRecurrenceScopeRaw: String = RelativeRecurrenceScope.dayOfMonth.rawValue
    /// The Relative Date pattern's position within the month — only
    /// meaningful when `recurrenceMode == .relativeDate`. For
    /// `.dayOfMonth` only `.first`/`.last` are ever offered in the UI;
    /// `.weekdayOfMonth` offers all five. See `RelativeRecurrenceOrdinal`.
    var relativeRecurrenceOrdinalRaw: Int = RelativeRecurrenceOrdinal.first.rawValue
    /// The Relative Date pattern's weekday, `Calendar.Component.weekday`
    /// numbering (1 = Sunday ... 7 = Saturday) — only meaningful when
    /// `relativeRecurrenceScope == .weekdayOfMonth`. `nil` until the
    /// weekday picker is actually touched.
    var relativeRecurrenceWeekday: Int?
    /// Whether the Relative Date pattern (scope/ordinal/weekday above)
    /// has actually been deliberately configured — same "picked" shape
    /// `recurrenceIntervalPicked`/`recurrenceTimeModePicked` already use.
    /// `relativeRecurrenceScopeRaw`/`relativeRecurrenceOrdinalRaw` start
    /// on real, storable defaults ("Day of Month, First" — i.e. "the 1st
    /// of the month"), not an obviously-incomplete placeholder, so
    /// without this a fresh Relative Date task would silently sit on
    /// that default with nothing prompting it to be confirmed.
    var relativeRecurrencePicked: Bool = false

    var recurrenceUnit: RecurrenceUnit {
        get { RecurrenceUnit(rawValue: recurrenceUnitRaw) ?? .days }
        set { recurrenceUnitRaw = newValue.rawValue }
    }

    var recurrenceTimeMode: HabitOccurrenceTimeMode {
        get { HabitOccurrenceTimeMode(rawValue: recurrenceTimeModeRaw) ?? .specific }
        set { recurrenceTimeModeRaw = newValue.rawValue }
    }

    var recurrenceMode: RecurrenceMode {
        get { RecurrenceMode(rawValue: recurrenceModeRaw) ?? .specificDate }
        set { recurrenceModeRaw = newValue.rawValue }
    }

    var relativeRecurrenceScope: RelativeRecurrenceScope {
        get { RelativeRecurrenceScope(rawValue: relativeRecurrenceScopeRaw) ?? .dayOfMonth }
        set { relativeRecurrenceScopeRaw = newValue.rawValue }
    }

    var relativeRecurrenceOrdinal: RelativeRecurrenceOrdinal {
        get { RelativeRecurrenceOrdinal(rawValue: relativeRecurrenceOrdinalRaw) ?? .first }
        set { relativeRecurrenceOrdinalRaw = newValue.rawValue }
    }

    /// `recurrenceTimeOfDayMinutes` if explicitly set, else derived from
    /// `dueDate`'s own time-of-day (the pre-picker behavior, kept as a
    /// fallback so an existing recurring task keeps placing exactly
    /// where it always has), else 9am if there's no anchor at all yet
    /// (mirrors `makeRecurring`'s own default anchor time). This is what
    /// the Specific Time picker actually displays and what
    /// `recurringOccurrenceTime` reads — one fallback chain, not two
    /// copies of it.
    var effectiveRecurrenceTimeOfDayMinutes: Int {
        if let recurrenceTimeOfDayMinutes { return recurrenceTimeOfDayMinutes }
        guard let dueDate else { return 9 * 60 }
        let components = Calendar.current.dateComponents([.hour, .minute], from: dueDate)
        return (components.hour ?? 9) * 60 + (components.minute ?? 0)
    }

    /// Whether an occurrence of this recurring task lands on `date`'s
    /// calendar day. One public entry point regardless of
    /// `recurrenceMode` — every real caller (`AISchedulingService`,
    /// `ScheduleReviewViewModel`'s projection/carry-forward/sweep code,
    /// `PushedRecurringOccurrence.advanceOneHop`, `DayTimelineGridView`,
    /// `ShelfListView`, and this type's own
    /// `next`/`previousRecurringOccurrenceDate` walks) only ever calls
    /// this, never `hasSpecificDateOccurrence`/`hasRelativeDateOccurrence`
    /// directly — so there is exactly one "is today an occurrence"
    /// answer per task, not two implementations that could silently
    /// disagree. The guards here (anchor exists, interval positive, floor,
    /// end-date cutoff) are mode-agnostic and apply before either branch
    /// runs; `date` is compared by calendar day only — see
    /// `recurringOccurrenceTime` for the actual time an occurrence lands
    /// at.
    func hasRecurringOccurrence(on date: Date, calendar: Calendar = .current) -> Bool {
        guard isRecurring, recurrenceIntervalCount > 0, let anchor = dueDate else { return false }
        let day = calendar.startOfDay(for: date)
        let anchorDay = calendar.startOfDay(for: anchor)
        guard day >= anchorDay else { return false }
        if let end = recurrenceEndDate, day > calendar.startOfDay(for: end) { return false }

        switch recurrenceMode {
        case .specificDate:
            return hasSpecificDateOccurrence(day: day, anchorDay: anchorDay, calendar: calendar)
        case .relativeDate:
            return hasRelativeDateOccurrence(day: day, anchorDay: anchorDay, calendar: calendar)
        }
    }

    /// The original interval+unit+anchor evaluator — stepping forward
    /// from `anchorDay` by `recurrenceIntervalCount` `recurrenceUnit`s at
    /// a time. Unmodified body from before `RecurrenceMode` existed,
    /// just extracted out of `hasRecurringOccurrence` so it sits behind
    /// the mode switch instead of being the only behavior.
    private func hasSpecificDateOccurrence(day: Date, anchorDay: Date, calendar: Calendar) -> Bool {
        switch recurrenceUnit {
        case .days:
            guard let deltaDays = calendar.dateComponents([.day], from: anchorDay, to: day).day else { return false }
            return deltaDays % recurrenceIntervalCount == 0
        case .weeks:
            guard let deltaDays = calendar.dateComponents([.day], from: anchorDay, to: day).day else { return false }
            return deltaDays % (recurrenceIntervalCount * 7) == 0
        case .months:
            guard let deltaMonths = calendar.dateComponents([.month], from: anchorDay, to: day).month,
                  deltaMonths % recurrenceIntervalCount == 0,
                  let expected = calendar.date(byAdding: .month, value: deltaMonths, to: anchorDay)
            else { return false }
            // Same day-of-month as the anchor — a short month clamps the
            // added date to its own last day (Foundation's own Calendar
            // behavior), so e.g. a Jan 31 anchor lands on Feb 28/29
            // rather than never firing that month at all.
            return calendar.isDate(expected, inSameDayAs: day)
        }
    }

    /// The Relative Date evaluator — "the 1st"/"the last day" of the
    /// month, or "the first/second/third/fourth/last <weekday>" of the
    /// month, every `recurrenceIntervalCount` months (unit is implicitly
    /// months here; `recurrenceUnit` itself is never read by this
    /// branch). Month-interval check first, then a pattern check scoped
    /// to `day`'s own month.
    ///
    /// The month-interval check counts **month buckets** (year×12 +
    /// month), not `calendar.dateComponents([.month], from:to:).month`
    /// the way `hasSpecificDateOccurrence`'s `.months` case does — that
    /// only works there because a Specific Date candidate always shares
    /// the anchor's exact day-of-month by construction, so there's no
    /// partial-month ambiguity. A Relative Date candidate's day-of-month
    /// is whatever the pattern lands on and is usually *different* from
    /// the anchor's, and `dateComponents([.month], from:to:)` computes
    /// *whole elapsed months* (age-in-months style) — e.g. Jan 3 2026 to
    /// Jan 2 2027 comes back as 11, not 12, because the day-of-month
    /// hasn't yet reached the anniversary. Bucket-counting instead
    /// treats every January as month-bucket 0 (mod 12) regardless of
    /// which day within it, which is the actual "every N months, on this
    /// pattern" meaning.
    ///
    /// **Invariant this relies on: every pattern this function can
    /// express resolves to exactly one real day in every month, with no
    /// skip or fallback logic anywhere below.** "The 1st" and "the last
    /// day" always exist — `Calendar.range(of:in:for:)` already accounts
    /// for month length and leap years, so there's nothing to special-
    /// case for February. First through Fourth `<weekday>` always exist
    /// too: every month is at least 28 days (4 full weeks), so every
    /// weekday occurs at least 4 times in every month, no exceptions.
    /// Only a hypothetical "5th `<weekday>`" would sometimes be missing
    /// (some months have 5 Saturdays, most don't) — that ordinal is
    /// deliberately not offered (`RelativeRecurrenceOrdinal` stops at
    /// `.fourth`/`.last`) specifically so this invariant holds. Anyone
    /// adding a new `RelativeRecurrenceScope`, or extending the ordinal
    /// range, must keep this invariant holding or this function needs
    /// real skip/fallback logic it doesn't have today.
    ///
    /// The `.weekOfMonth` trick: consecutive occurrences of the same
    /// weekday are always exactly 7 days apart, which always crosses
    /// exactly one week boundary — so they land in consecutive
    /// `weekOfMonth` values (1, 2, 3, 4, sometimes 5) regardless of
    /// `calendar.firstWeekday`. That's what makes "the Nth `<weekday>`
    /// of the month" an O(1) component read rather than a scan.
    private func hasRelativeDateOccurrence(day: Date, anchorDay: Date, calendar: Calendar) -> Bool {
        let anchorParts = calendar.dateComponents([.year, .month], from: anchorDay)
        let dayParts = calendar.dateComponents([.year, .month], from: day)
        guard let anchorYear = anchorParts.year, let anchorMonth = anchorParts.month,
              let dayYear = dayParts.year, let dayMonth = dayParts.month
        else { return false }
        let deltaMonths = (dayYear - anchorYear) * 12 + (dayMonth - anchorMonth)
        guard deltaMonths >= 0, deltaMonths % recurrenceIntervalCount == 0 else { return false }

        switch relativeRecurrenceScope {
        case .dayOfMonth:
            let dayOfMonth = calendar.component(.day, from: day)
            if relativeRecurrenceOrdinal == .last {
                let daysInMonth = calendar.range(of: .day, in: .month, for: day)?.count ?? dayOfMonth
                return dayOfMonth == daysInMonth
            }
            // Only `.first`/`.last` are ever offered for this scope (see
            // `RelativeRecurrenceScope.dayOfMonth`'s own doc comment) —
            // anything else collapses to "the 1st" rather than matching
            // nothing, in case an invalid combination ever slips through.
            return dayOfMonth == 1
        case .weekdayOfMonth:
            guard let weekday = relativeRecurrenceWeekday,
                  calendar.component(.weekday, from: day) == weekday
            else { return false }
            if relativeRecurrenceOrdinal == .last {
                guard let weekLater = calendar.date(byAdding: .day, value: 7, to: day) else { return false }
                return calendar.component(.month, from: weekLater) != calendar.component(.month, from: day)
            }
            return calendar.component(.weekOfMonth, from: day) == relativeRecurrenceOrdinal.rawValue
        }
    }

    /// Whether this task is allowed to land on `date` at all, per its own
    /// `startDate` — `true` when there's no `startDate` set. Checked by
    /// `AISchedulingService` before ever considering a task as a
    /// candidate for a given day's packing.
    func isEligibleToStart(on date: Date, calendar: Calendar = .current) -> Bool {
        guard let startDate else { return true }
        return calendar.startOfDay(for: date) >= calendar.startOfDay(for: startDate)
    }

    /// The time an occurrence landing on `date` should actually be placed
    /// at — `effectiveRecurrenceTimeOfDayMinutes`, applied onto `date`'s
    /// calendar day. Still requires an anchor (`dueDate`) to exist at
    /// all, same as before this had its own field — a recurring task
    /// with no anchor yet has nothing to place regardless of what time
    /// it would land at (see `hasRecurringOccurrence`, which every real
    /// caller already checks first).
    func recurringOccurrenceTime(on date: Date, calendar: Calendar = .current) -> Date? {
        guard dueDate != nil else { return nil }
        let minutes = effectiveRecurrenceTimeOfDayMinutes
        return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: date)
    }

    /// Moves every future, not-yet-completed block already generated for
    /// this task's Specific-Time occurrence onto its current time-of-day
    /// — called whenever the time picker changes, so an edit follows
    /// through to what's already on the calendar instead of only
    /// applying to occurrences placed from here on. Keeps each block's
    /// own date, just updates its clock time (preserving duration).
    ///
    /// Updates in place rather than deleting and re-placing
    /// (`HabitEditView.removeStaleBlocks`'s approach for the identical
    /// habit-side question): a recurring task's real blocks can already
    /// be generated up to ~44 days out
    /// (`AISchedulingService`'s own population horizon), and deleting
    /// all of them would need a full regenerate to refill anything past
    /// today — changing one field shouldn't require that. Doesn't
    /// collision-check against anything else already on those days,
    /// same as a manual drag-to-retime of a single block wouldn't
    /// either — this is a deliberate, explicit edit, not a placement
    /// decision. A past or already-completed block is left alone (it's
    /// history). An approved block drops back to "proposed" so the next
    /// Approve All actually pushes the corrected time to Google
    /// Calendar, same reasoning `syncScheduledBlockDuration` already
    /// uses for a duration edit. `today` is a parameter (defaulting to
    /// `.now`) purely for testability — production callers never
    /// override it.
    func retimeFutureSpecificOccurrences(today: Date = .now, calendar: Calendar = .current) {
        guard recurrenceTimeMode == .specific else { return }
        let today = calendar.startOfDay(for: today)
        let minutes = effectiveRecurrenceTimeOfDayMinutes
        for block in (scheduledBlocks ?? []) where !block.isCompleted && block.date >= today {
            guard let newStart = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: block.date) else { continue }
            let duration = block.endTime.timeIntervalSince(block.startTime)
            block.startTime = newStart
            block.endTime = newStart.addingTimeInterval(duration)
            if block.approvalStatus == .approved {
                block.approvalStatus = .proposed
            }
        }
    }

    /// The recurring-task counterpart to `Habit.cycleOccurrence` — same
    /// "log is truth, a linked block is a mirror" shape, but a shorter
    /// cycle: `none -> complete -> missed -> none`. No `.excused` — a
    /// recurring task isn't excusable the way a habit occurrence is,
    /// there's no notion of "this one didn't need to happen."
    ///
    /// Both `recurrenceTimeMode`s go through this identically —
    /// Specific-Time's own `ScheduledBlock.isCompleted` is kept as a
    /// display mirror only, exactly like a habit-linked block already
    /// is, never the source of truth. This closes the orphaned-
    /// completion gap in docs/session-handoff.md, where a projected
    /// Specific-Time completion (written to `RecurringTaskLog`, the only
    /// store that existed before a real block was generated) used to get
    /// silently lost once a real block appeared, since block creation
    /// never consulted the log. See `AISchedulingService
    /// .placeHabitsAndRecurringTasks`'s block-creation path for the other
    /// half of that fix — seeding a fresh block's `isCompleted` from this
    /// same log.
    @discardableResult
    func cycleRecurringOccurrence(on date: Date, context: ModelContext, calendar: Calendar = .current) -> OccurrenceStatus {
        let log = RecurringTaskLog.logOrCreate(taskID: id, on: date, context: context, calendar: calendar)
        let next = log.status.cycledExcludingExcused
        log.status = next
        log.lastModified = .now
        if let block = (scheduledBlocks ?? []).first(where: { calendar.isDate($0.date, inSameDayAs: date) }) {
            // `.status`, not `.isCompleted` — the block is still only a
            // *mirror* of this log (unchanged: `RecurringTaskLog` stays
            // the source of truth for a recurring task's occurrence),
            // but writing the real status directly lets that mirror
            // preserve `.missed` distinctly from `.none` too, instead of
            // collapsing both to `isCompleted == false` the way the old
            // plain-bool write here necessarily did.
            block.status = next
        }
        if next == .complete {
            TaskCompletionRecord.upsert(for: self, in: context)
        } else {
            TaskCompletionRecord.remove(for: self, in: context)
        }
        return next
    }

    /// The plain (not day-scoped) completion cycle — 2-Minute tasks, and
    /// any other task's own completion where there's no `ScheduledBlock`
    /// driving it, cycle through here instead of a two-way `setCompleted`
    /// toggle. Same shared `cycledExcludingExcused` cycle
    /// `cycleRecurringOccurrence` uses, applied directly to this task's
    /// own `status` — a non-recurring task has no separate day-scoped log
    /// the way a recurring occurrence does; the task itself already *is*
    /// the one, not-date-scoped occurrence.
    ///
    /// Mirrors onto `scheduledBlocks` the same way `setCompleted` already
    /// does, for the same reason — harmless no-op for a 2-Minute task
    /// (never has one), correct if some other caller ever cycles a task
    /// that does. A task *with* a block is still expected to have its
    /// completion driven from the block's own circle
    /// (`ScheduleReviewViewModel.toggleComplete`, which mirrors block →
    /// task, the opposite direction) — this method is for the surfaces
    /// where the task itself is the only thing to cycle.
    @discardableResult
    func cycleCompletion(in context: ModelContext) -> OccurrenceStatus {
        let next = status.cycledExcludingExcused
        status = next
        for block in scheduledBlocks ?? [] {
            block.status = next
        }
        if next == .complete {
            TaskCompletionRecord.upsert(for: self, in: context)
        } else {
            TaskCompletionRecord.remove(for: self, in: context)
        }
        return next
    }

    /// The next date (today or later) this recurring task has an
    /// occurrence on, walking forward day by day — used to sort recurring
    /// tasks by soonest-first on their shelf (see `ShelfListView`). `nil`
    /// if nothing's coming (not recurring, or `recurrenceEndDate` has
    /// already passed). Capped at a year out so a stray misconfiguration
    /// can't loop indefinitely.
    func nextRecurringOccurrenceDate(asOf referenceDate: Date = .now, calendar: Calendar = .current) -> Date? {
        guard isRecurring else { return nil }
        var cursor = calendar.startOfDay(for: referenceDate)
        for _ in 0..<366 {
            if hasRecurringOccurrence(on: cursor, calendar: calendar) {
                return recurringOccurrenceTime(on: cursor, calendar: calendar)
            }
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor
        }
        return nil
    }

    /// The most recent day (on or before `referenceDate`) this recurring
    /// task has an occurrence on, walking backward day by day — the
    /// mirror of `nextRecurringOccurrenceDate`. Capped at `scanDays`
    /// (default 400, same floor `ScheduleReviewViewModel
    /// .openHabitOccurrencesForReview` already uses for the identical
    /// concern) so an old daily task can't mean an unbounded walk back to
    /// its own anchor. `nil` if nothing recurring lands in that whole
    /// window (recurrence started after `referenceDate`, or the scan
    /// reached `scanDays` back without finding one).
    func previousRecurringOccurrenceDate(onOrBefore referenceDate: Date, scanDays: Int = 400, calendar: Calendar = .current) -> Date? {
        guard isRecurring, let anchor = dueDate else { return nil }
        let referenceDay = calendar.startOfDay(for: referenceDate)
        let anchorDay = calendar.startOfDay(for: anchor)
        guard referenceDay >= anchorDay else { return nil }
        let floor = max(anchorDay, calendar.date(byAdding: .day, value: -scanDays, to: referenceDay) ?? anchorDay)
        var cursor = referenceDay
        while cursor >= floor {
            if hasRecurringOccurrence(on: cursor, calendar: calendar) { return cursor }
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return nil
    }

    /// "Oct 14" — short enough to sit as supporting detail alongside
    /// `recurrenceSummary`. Same "MMM d" pattern
    /// `ShelfListView.TaskRow.pantryAgeText` already uses for a short
    /// date, kept consistent rather than inventing a second one.
    private static let recurrenceEndDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    /// "Every day" / "Every 3 days" / "Every week" / "Every 2 months",
    /// optionally "... until Oct 14" once `recurrenceEndDate` is set —
    /// `nil` for a non-recurring task. Lives here rather than inline in
    /// whichever view first wanted it (`ShelfListView.TaskRow`) since it's
    /// exactly the kind of plain-string derivation other screens will
    /// want too, and there's no shared helper for it anywhere yet. Drops
    /// the "1" for a 1x interval ("Every day", not "Every 1 day") —
    /// `RecurrenceUnit.label(for:)` already handles the singular/plural
    /// noun; this only decides whether the count itself is worth saying.
    var recurrenceSummary: String? {
        guard isRecurring else { return nil }
        let countPrefix = recurrenceIntervalCount == 1 ? "" : "\(recurrenceIntervalCount) "
        var summary: String
        switch recurrenceMode {
        case .specificDate:
            summary = "Every \(countPrefix)\(recurrenceUnit.label(for: recurrenceIntervalCount))"
        case .relativeDate:
            let unitWord = recurrenceIntervalCount == 1 ? "month" : "months"
            let patternPhrase: String
            switch relativeRecurrenceScope {
            case .dayOfMonth:
                patternPhrase = relativeRecurrenceOrdinal == .last ? "the last day" : "the 1st"
            case .weekdayOfMonth:
                let weekdayName = Self.weekdaySymbol(for: relativeRecurrenceWeekday ?? 1)
                patternPhrase = "the \(relativeRecurrenceOrdinal.label.lowercased()) \(weekdayName)"
            }
            summary = "Every \(countPrefix)\(unitWord) on \(patternPhrase)"
        }
        if let recurrenceEndDate {
            summary += " until \(Self.recurrenceEndDateFormatter.string(from: recurrenceEndDate))"
        }
        return summary
    }

    /// "Monthly · 4th Saturday" / "Every 2 months · last day" / "Daily" /
    /// "Every 3 days" — a genuinely separate property from
    /// `recurrenceSummary`, not a "short" flag on it: `TaskReviewCard`'s
    /// collapsed "Repeats" row needs this one line-limited to fit inside
    /// a fixed-height row (a wrapped value there breaks the layout, not
    /// just looks bad), while `ShelfListView.recurrenceLine` keeps
    /// showing the long form on the shelf card, where wrapping isn't a
    /// hazard — a shared formatter with a "short" toggle would couple two
    /// call sites that should be free to reword independently. Never
    /// includes the end-date suffix `recurrenceSummary` appends — "Ends"
    /// is its own row now, so repeating that here would be redundant, not
    /// just long. Ordinals are numerals ("4th"), not words ("fourth") —
    /// `RelativeRecurrenceOrdinal.shortOrdinalLabel`, not `.label`, which
    /// stays full words for the Position picker's own menu.
    var recurrenceShortSummary: String? {
        guard isRecurring else { return nil }
        switch recurrenceMode {
        case .specificDate:
            return recurrenceIntervalCount == 1
                ? Self.shortFrequencyWord(for: recurrenceUnit)
                : "Every \(recurrenceIntervalCount) \(recurrenceUnit.label(for: recurrenceIntervalCount))"
        case .relativeDate:
            let frequency = recurrenceIntervalCount == 1 ? "Monthly" : "Every \(recurrenceIntervalCount) months"
            let detail: String
            switch relativeRecurrenceScope {
            case .dayOfMonth:
                detail = relativeRecurrenceOrdinal == .last ? "last day" : "1st"
            case .weekdayOfMonth:
                let weekdayName = Self.weekdaySymbol(for: relativeRecurrenceWeekday ?? 1)
                detail = "\(relativeRecurrenceOrdinal.shortOrdinalLabel) \(weekdayName)"
            }
            return "\(frequency) · \(detail)"
        }
    }

    /// "Daily"/"Weekly"/"Monthly" — the 1x-interval word
    /// `recurrenceShortSummary` uses for Specific Date; a >1 interval
    /// uses "Every N \(unit)" instead (`RecurrenceUnit.label(for:)`
    /// already has the singular/plural noun, no separate short word
    /// needed there).
    private static func shortFrequencyWord(for unit: RecurrenceUnit) -> String {
        switch unit {
        case .days: return "Daily"
        case .weeks: return "Weekly"
        case .months: return "Monthly"
        }
    }

    /// "Sunday"..."Saturday" for `Calendar.Component.weekday`'s own
    /// numbering (1 = Sunday ... 7 = Saturday) — `weekdaySymbols` is
    /// indexed the same way starting at 0, so `weekday - 1` lines up
    /// directly. Clamped defensively since this only ever backs display
    /// text, never a control flow decision.
    private static func weekdaySymbol(for weekday: Int, calendar: Calendar = .current) -> String {
        let symbols = calendar.weekdaySymbols
        let index = max(0, min(symbols.count - 1, weekday - 1))
        return symbols[index]
    }

    /// Turns this task recurring — deliberately *without* auto-filling an
    /// anchor (`startDate`/`dueDate`) anymore. A new recurring task starts
    /// with Start Date at "Not Selected," so it has to be consciously set
    /// before this can actually place anywhere: `hasRecurringOccurrence`/
    /// `recurringOccurrenceTime`/`nextRecurringOccurrenceDate` all require
    /// `dueDate` and simply return false/nil without it (no crash — a
    /// recurring task with no anchor just never places on the calendar
    /// and never shows a next-occurrence date, which `ShelfListView`'s own
    /// `recurrenceLine` already falls back to the frequency alone for).
    /// `dueDateMissing` excludes a recurring task outright (it asks Start
    /// Date instead, never "Due Date"), so leaving the anchor unset here
    /// doesn't mislabel it as missing something it was never asked.
    ///
    /// If `startDate` is *already* set — a task that had one before
    /// recurring was turned on, or an already-recurring task cycling
    /// through this again — that's kept and synced onto `dueDate` (same
    /// "preserve the existing time-of-day, don't reset it to 9am" logic
    /// `combiningDate`'s inline version originally had), rather than
    /// silently losing it.
    ///
    /// **This is the only way `isRecurring` should ever be set to
    /// `true`.** Setting `task.isRecurring = true` directly, without
    /// this, skips the `dueDateDecided`/`dueDatePicked` sync above for a
    /// task that already has a `startDate` — a small inconsistency, but
    /// the next new task-creation path that needs a recurring default
    /// should still call this rather than the bare flag, so there's one
    /// place this logic lives.
    func makeRecurring(calendar: Calendar = .current) {
        isRecurring = true
        guard let day = startDate else { return }
        syncDueDate(toAnchorDay: day, calendar: calendar)
    }

    /// Single entry point for setting Start Date from the UI — writes
    /// `startDate` and marks it `startDatePicked`, distinguishing "the
    /// user deliberately chose this day (even if it's today)" from "never
    /// touched" (`startDatePicked == false`), which is what lets the
    /// Start Date control display "Not Selected" instead of silently
    /// showing today for an untouched task. For a recurring task, Start
    /// Date doubles as the recurrence anchor, so this keeps `dueDate` in
    /// sync exactly the way `makeRecurring()` already does when a
    /// `startDate` is already present — same shared helper, so the two
    /// paths can't drift apart.
    func setStartDate(_ date: Date, calendar: Calendar = .current) {
        let day = calendar.startOfDay(for: date)
        startDate = day
        startDatePicked = true
        guard isRecurring else { return }
        syncDueDate(toAnchorDay: day, calendar: calendar)
    }

    /// Clears Start Date back to "never touched" — the popover's explicit
    /// "Clear" affordance, symmetric with `setStartDate(_:)`. For a
    /// recurring task, since Start Date doubles as the recurrence anchor,
    /// this also clears `dueDate` back to unset rather than leaving a
    /// stale anchor behind: an already-recurring task loses its
    /// placement on the calendar entirely until Start Date is picked
    /// again, same as a brand new one that's never had it set.
    func clearStartDate() {
        startDate = nil
        startDatePicked = false
        guard isRecurring else { return }
        dueDate = nil
        dueDateDecided = false
        dueDatePicked = false
    }

    /// Folds `day` onto `dueDate`'s existing time-of-day (or 9am if there
    /// isn't one yet) and marks the due date as decided/picked — the
    /// anchor-sync body shared by `makeRecurring()` and `setStartDate(_:)`
    /// so a recurring task's `dueDate` stays consistent regardless of
    /// which of those two paths last touched `startDate`.
    private func syncDueDate(toAnchorDay day: Date, calendar: Calendar) {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        let timeSource = dueDate ?? (calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day)
        let timeComponents = calendar.dateComponents([.hour, .minute], from: timeSource)
        components.hour = timeComponents.hour
        components.minute = timeComponents.minute
        components.second = 0
        dueDate = calendar.date(from: components) ?? day
        dueDateDecided = true
        dueDatePicked = true
    }

    /// Builds a new task for direct capture straight onto `shelf` — what
    /// `ShelfListView`'s own capture bar (`addTask()`) uses. Defaults
    /// `isRecurring` on via `makeRecurring()` when `shelf` is the
    /// Recurring Tasks shelf (`Shelf.isRecurringTasks`) — a default, not
    /// a lock, freely toggled off afterward from the task's own card.
    ///
    /// Same treatment for the 2-Minute Tasks shelf (`Shelf.isTwoMinuteTasks`):
    /// duration defaults to "≤2 min" (`estimatedMinutes == 2`, the same
    /// sentinel value the Duration wheel's own top option already uses)
    /// rather than being left unanswered. Duration is scheduling-inert
    /// for this shelf either way — `AISchedulingService` never places one
    /// of its tasks onto the calendar at all — but the field stays
    /// visible and editable (unlike Divisible/Priority, which are hidden
    /// outright for this shelf — Divisible by duration (see
    /// `divisibleMinimumDurationMinutes`), Priority by shelf (see
    /// `Shelf.effectiveTracksPriority`)): there's a real case for jotting an
    /// actual duration here even though nothing schedules against it,
    /// where there isn't one for splitting a ≤2-minute task or ranking it
    /// against others that never compete for calendar time at all.
    /// Without this default, a task landing here would otherwise sit
    /// flagged as missing an attribute the shelf's own visible Duration
    /// row asks for. Gated on `effectiveTracksDuration` so this does
    /// nothing on the (unusual) case where duration tracking has been
    /// turned off for this shelf entirely — matching how `TaskCardSheet
    /// .onMove` already treats other tracked-attribute defaults
    /// elsewhere. `durationPicked`/`divisiblePicked` are set alongside
    /// their values, not left for the values alone to imply — the
    /// same picked-flag-with-its-value discipline `makeRecurring()`'s own
    /// extraction exists to keep a single call site responsible for,
    /// rather than risking a value that looks set but still reports
    /// missing. `remainingMinutes` is set too: `TaskItem.init` above
    /// already fixed it at `estimatedMinutes`' default (`0`) before this
    /// runs, and nothing else re-syncs it.
    ///
    /// Only ever applied here, at creation. Moving an *existing* task
    /// onto either shelf later — `InboxViewModel.route`, or either card's
    /// `onMove` handler — never calls this, so a task moved in from
    /// elsewhere keeps whatever it already was, not auto-set.
    static func makeForDirectCapture(title: String, shelf: Shelf) -> TaskItem {
        let task = TaskItem(title: title, shelf: shelf)
        if shelf.isRecurringTasks {
            task.makeRecurring()
        }
        if shelf.isTwoMinuteTasks, shelf.effectiveTracksDuration {
            task.estimatedMinutes = 2
            task.remainingMinutes = 2
            task.durationPicked = true
            // Divisible is deliberately *not* pre-answered here. At 2
            // minutes the row doesn't exist and isn't reported missing
            // (see `divisibleMinimumDurationMinutes`), so there's nothing
            // to answer — and pre-marking it would mean that raising the
            // duration to an hour reveals a Divisible row already reading
            // "Not Divisible", as though it had been chosen. It should
            // read "Not selected", because it hasn't been.
        }
        return task
    }

    /// Deletes `task` along with every record keyed to it that plain
    /// `context.delete(task)` leaves behind. `scheduledBlocks`
    /// *nullifies* rather than deletes (`.nullify` — see that
    /// relationship's own declaration), so those need an explicit
    /// delete; `RecurringTaskLog`/`PushedRecurringOccurrence`/
    /// `TaskCompletionRecord` all key by a copied `taskID`, not a
    /// `@Relationship`, specifically so they survive the task being
    /// edited or deleted elsewhere (see each type's own doc comment) —
    /// which means nothing cleans them up on its own once deletion is
    /// actually what's wanted.
    ///
    /// `task.tags` needs nothing further here: it's a plain `[String]`
    /// stored directly on the task, not a separate per-task association
    /// row, so it goes with the object. The *shared* `Tag` catalog
    /// entries a session might have created (`TaskReviewCard.addTag()`)
    /// are deliberately left alone — see `Tag`'s own doc comment: that's
    /// app-wide vocabulary ("every tag name ever attached to a task or
    /// inbox item"), not this task's data, and other tasks may already
    /// be reading it.
    ///
    /// Operates on whatever's actually associated with `task.id` right
    /// now, not a diff of what this session touched — a `ScheduledBlock`
    /// from auto-placement or a manual calendar drag gets cleaned up
    /// exactly the same as one the card's own controls created, since a
    /// task that's being deleted because it was never saved shouldn't
    /// leave anything behind regardless of how that state came to exist.
    static func deleteCascading(_ task: TaskItem, in context: ModelContext) {
        let taskID = task.id
        for block in task.scheduledBlocks ?? [] {
            context.delete(block)
        }
        let logs = (try? context.fetch(FetchDescriptor<RecurringTaskLog>(
            predicate: #Predicate { $0.taskID == taskID }
        ))) ?? []
        for log in logs {
            context.delete(log)
        }
        let pushedOccurrences = (try? context.fetch(FetchDescriptor<PushedRecurringOccurrence>(
            predicate: #Predicate { $0.taskID == taskID }
        ))) ?? []
        for occurrence in pushedOccurrences {
            context.delete(occurrence)
        }
        let completionRecords = (try? context.fetch(FetchDescriptor<TaskCompletionRecord>(
            predicate: #Predicate { $0.taskID == taskID }
        ))) ?? []
        for record in completionRecords {
            context.delete(record)
        }
        context.delete(task)
    }

    /// The soonest day *after* `date` where at least one of this task's
    /// own opted-into, fits-it rules actually runs — the non-recurring
    /// counterpart to `nextRecurringOccurrenceDate`, used by
    /// `RippleSchedulingService` to guarantee an incomplete task
    /// genuinely lands somewhere instead of being freed up to maybe get
    /// picked up by a future general regenerate walk (see
    /// `ScheduleReviewViewModel.guaranteePlacement`'s own doc comment for
    /// the "Stirfry recipes never actually lands anywhere" bug this
    /// exists to fix). Deliberately checks `isEffectivelyEligible`, not
    /// just `isEligible` — a rule the user opted into but that can never
    /// actually fit this task's duration isn't a real candidate day.
    /// `nil` if nothing qualifies within the search horizon (no enabled,
    /// fitting rule at all, or every one of them is capped at a handful
    /// of days a year) — capped at 60 days rather than
    /// `nextRecurringOccurrenceDate`'s full year, since an ordinary
    /// task's rule is a recurring weekly window, not a once-a-year
    /// anchor, so 60 days is already many cycles of any realistic
    /// schedule.
    func nextEligibleDay(after date: Date, calendar: Calendar = .current) -> Date? {
        let rules = (shelf?.schedulingRules ?? []).filter { $0.isEnabled && isEffectivelyEligible(for: $0) }
        guard !rules.isEmpty else { return nil }
        var cursor = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date
        for _ in 0..<60 {
            let weekday = calendar.component(.weekday, from: cursor)
            if rules.contains(where: { $0.effectiveDaysOfWeek.contains(weekday) }) {
                return cursor
            }
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor
        }
        return nil
    }

    /// Whether the AI Scheduler may split this task across multiple blocks
    /// (different times/slots the same day) if it doesn't fit in one
    /// contiguous window. Each piece is at least `minimumSegmentMinutes`.
    var isDivisible: Bool = false
    /// `0` means "Not Divisible" — a real answer (the wheel's first
    /// option), not an absence of one. `divisiblePicked` is what carries
    /// whether it's been answered at all.
    var minimumSegmentMinutes: Int = 0
    /// Same role as `durationPicked`, for Divisible: distinguishes "never
    /// touched" from "deliberately Not Divisible," since both leave
    /// `minimumSegmentMinutes == 0`. Renamed from `isDivisibleDecided`
    /// with `@Attribute(originalName:)` keeping its column — see
    /// `durationPicked`'s own doc comment. Needs no `legacy...` companion
    /// the way Duration did: the state its old partner flag carried
    /// (`isDivisible`) is a *kept* field, so the migration can read it
    /// directly.
    @Attribute(originalName: "isDivisibleDecided")
    var divisiblePicked: Bool = false
    /// Set once `NoteForLaterApp.migrateDurationDivisibleToSingleWheelIfNeeded`
    /// has reconciled this row's Duration/Divisible flags — checked
    /// *before* reconciling, so a second invocation skips the row rather
    /// than re-deriving it. Committed in the same `context.save()` as the
    /// flags it guards, so the two can never land out of sync the way the
    /// migration's own `UserDefaults` completion flag and the data store
    /// can. Same shape and reasoning as
    /// `ScheduledBlock.hasMigratedThreeState`.
    var hasMigratedSingleWheel: Bool = false

    /// The chunk sizes worth offering as a minimum segment, in general —
    /// not a uniform step, just the values that make sense to a person.
    /// `validSegmentOptions(for:)` is what any UI should actually show.
    static let segmentOptionCandidates = [15, 30, 45, 60, 90, 120, 240]

    /// Below this, a task is never split and the Divisible question is
    /// never asked — splitting something shorter than an hour buys
    /// nothing worth the fragmentation. `>=`, so a task of exactly 60
    /// minutes *is* divisible-eligible; 59 is not.
    static let divisibleMinimumDurationMinutes = 60

    /// Whether this task may **actually** be split right now — the one
    /// predicate every scheduling decision asks, rather than reading
    /// `isDivisible` raw.
    ///
    /// `isDivisible` is the user's stored *intent*; this is whether that
    /// intent currently applies. They diverge whenever the duration sits
    /// below `divisibleMinimumDurationMinutes`: the stored value is kept
    /// (so raising the duration again restores exactly what was there —
    /// see `validateDivisibility`'s own early return) but nothing acts on
    /// it while it's dormant. Writers and the edit snapshot keep using
    /// `isDivisible` directly; they're recording intent, not asking
    /// whether it holds.
    var isEffectivelyDivisible: Bool {
        isDivisible && estimatedMinutes >= Self.divisibleMinimumDurationMinutes
    }

    /// Which of `segmentOptionCandidates` evenly divide `minutes` and are
    /// strictly smaller than it.
    ///
    /// Strictly smaller because a segment the size of the whole task is
    /// what "not divisible" already means. Evenly dividing because the
    /// packer only ever takes whole multiples of the segment size (see
    /// `AISchedulingService.place`) — offering 45 for a 60-minute task
    /// would guarantee a 15-minute remainder that no slot is allowed to
    /// accept, stranding the task permanently.
    ///
    /// Empty for durations with no divisor in the list at all (25, 50,
    /// 100…). Callers must disable divisibility in that case rather than
    /// showing an empty picker.
    static func validSegmentOptions(for minutes: Int) -> [Int] {
        guard minutes > 0 else { return [] }
        return segmentOptionCandidates.filter { $0 < minutes && minutes % $0 == 0 }
    }

    /// Minutes currently accounted for by this task's own incomplete
    /// blocks. Completed blocks are excluded deliberately — their time
    /// was genuinely spent, not merely reserved.
    var placedMinutes: Int {
        (scheduledBlocks ?? [])
            .filter { !$0.isCompleted }
            .reduce(0) { $0 + Int($1.endTime.timeIntervalSince($1.startTime) / 60) }
    }

    /// What `remainingMinutes` *should* be, given the blocks this task
    /// actually holds — or `nil` when it should be left exactly as it is.
    ///
    /// Repairs the damage from the delete-without-restore leak (see
    /// `ScheduleReviewViewModel.removeBlock`), which destroyed minutes
    /// permanently whenever a block was swept by the rule trim, swiped
    /// away, or freed by a replace.
    ///
    /// Three cases, and the first one matters most:
    ///
    /// - **Blocks already cover the estimate → `nil`, leave alone.** This
    ///   is an ordinary fully-scheduled task; `remainingMinutes == 0` is
    ///   correct for it. Resetting it would re-offer work already sitting
    ///   on the calendar and double-schedule it.
    /// - **No blocks → the full estimate.** Nothing is placed, so nothing
    ///   is owed against it. The lost time isn't recoverable from block
    ///   durations here (there are none), so the whole estimate is the
    ///   only safe answer.
    /// - **Partial blocks → estimate minus placed.** Exactly the time not
    ///   yet on the calendar.
    ///
    /// Returns `nil` for anything completed, recurring (those never drain
    /// `remainingMinutes` at all), or without a duration, and for values
    /// already correct.
    func repairedRemainingMinutes() -> Int? {
        guard !isCompleted, !isRecurring, estimatedMinutes > 0 else { return nil }
        let placed = placedMinutes
        guard placed < estimatedMinutes else { return nil }
        let repaired = estimatedMinutes - placed
        return repaired == remainingMinutes ? nil : repaired
    }

    /// The single place Duration is answered from the card's wheel —
    /// writes the value and `durationPicked` together, unconditionally,
    /// so a value can never be left looking set while still reporting
    /// missing. Same discipline (and same reason) as
    /// `TaskReviewCard.selectRecurrenceUnit` and friends. `0` is a real
    /// selection ("None"), not a no-op — it marks Duration answered just
    /// as any other value does.
    ///
    /// Re-syncs `remainingMinutes` and re-validates divisibility, both of
    /// which a duration edit can invalidate: `remainingMinutes` is
    /// clamped so it never exceeds the new estimate, and a segment size
    /// chosen against the old duration may no longer divide the new one
    /// (see `validateDivisibility`).
    static func selectDuration(_ minutes: Int, on task: TaskItem) {
        task.estimatedMinutes = max(0, minutes)
        task.durationPicked = true
        task.remainingMinutes = min(task.remainingMinutes, task.estimatedMinutes)
        if task.remainingMinutes <= 0 { task.remainingMinutes = task.estimatedMinutes }
        task.validateDivisibility()
        task.syncScheduledBlockDuration()
    }

    /// The single place Divisible is answered from the card's wheel —
    /// `0` means "Not Divisible," anything else is a real minimum segment
    /// size. Keeps `isDivisible` and `minimumSegmentMinutes` consistent
    /// in one named place rather than at each call site (the two are
    /// separate stored fields because the scheduler reads `isDivisible`
    /// directly in many places; collapsing it into a computed
    /// `minimumSegmentMinutes > 0` would be the stored→computed SwiftData
    /// trap documented in `docs/session-handoff.md`). Sets
    /// `divisiblePicked` alongside, same reasoning as `selectDuration`.
    static func selectDivisibleSegment(_ minutes: Int, on task: TaskItem) {
        task.isDivisible = minutes > 0
        task.minimumSegmentMinutes = max(0, minutes)
        task.divisiblePicked = true
    }

    /// Forces `isDivisible`/`minimumSegmentMinutes` into a state the
    /// packer can actually satisfy. Call after **any** write to
    /// `estimatedMinutes` or `isDivisible` — notably shelf moves, which
    /// rewrite the duration via `Shelf.resolvedDuration(candidateMinutes:)`
    /// without the user touching the divisibility controls at all.
    ///
    /// Single definition on the model rather than repeated at each call
    /// site, for the same reason `isSchedulableBacklog` is: several
    /// screens write these fields, and a rule enforced in only some of
    /// them isn't an invariant.
    ///
    /// Snaps **down** to the largest valid divisor rather than up, so a
    /// task never silently ends up chunked more coarsely than the user
    /// asked for. Returns whether anything actually changed, so a caller
    /// can surface the change instead of applying it invisibly.
    @discardableResult
    func validateDivisibility() -> Bool {
        let previousDivisible = isDivisible
        let previousSegment = minimumSegmentMinutes

        guard isDivisible else {
            minimumSegmentMinutes = 0
            return previousSegment != 0
        }

        // Below the threshold the stored value is dormant — every
        // scheduling read goes through `isEffectivelyDivisible`, which is
        // already false here — so there's no invariant left for this
        // function to protect and no reason to destroy the value. Leaving
        // it intact is what makes a dip below an hour non-destructive:
        // raise the duration back and the segment size is still there.
        // Without this, a drop to e.g. 2 minutes would hit the
        // `options.isEmpty` branch below and clear it permanently.
        guard estimatedMinutes >= TaskItem.divisibleMinimumDurationMinutes else { return false }

        let options = TaskItem.validSegmentOptions(for: estimatedMinutes)
        if options.isEmpty {
            // Nothing can divide this duration evenly — divisibility is
            // not expressible, so it's cleared rather than left pointing
            // at a segment size the packer would refuse to honor.
            isDivisible = false
            minimumSegmentMinutes = 0
        } else if !options.contains(minimumSegmentMinutes) {
            minimumSegmentMinutes = options.last ?? 0
        }
        return isDivisible != previousDivisible || minimumSegmentMinutes != previousSegment
    }

    /// SchedulingRule IDs (from this task's shelf) that this task IS
    /// eligible to be pulled by — opt-in, not opt-out: empty (the default)
    /// means eligible for none of the shelf's rules until the user
    /// explicitly checks one, matching every other attribute starting
    /// unselected. A rule added to the shelf later is NOT automatically
    /// eligible — it has to be checked too.
    var includedSchedulingRuleIDs: [UUID] = []

    var shelf: Shelf?

    /// To-many, not to-one — a divisible task can legitimately have more
    /// than one block at once (its segments, possibly on different days),
    /// so a single task holding one fixed `scheduledBlock` was the root
    /// cause of a real crash: once a divisible task's leftover minutes got
    /// a second block on a later day, SwiftData's to-one inverse rejected
    /// the second block outright ("This relationship already has a value
    /// but it's not the target").
    @Relationship(deleteRule: .nullify, inverse: \ScheduledBlock.task)
    var scheduledBlocks: [ScheduledBlock]? = []

    /// Pantry inventory tracking — meaningful only for a Kitchen-shelf
    /// Pantry item (see `KitchenView`); every other task ignores all
    /// three of these. `0`/`nil` are the defaults for every Pantry item
    /// added before this existed (or added without ever setting these) —
    /// `PantryDeductionService` deducting against that is a correct
    /// no-op ("we don't know how much we have, so there's nothing to
    /// subtract from"), not a bug, and there's no migration backfill for
    /// the same reason the scheduling spec's own no-backfill precedent
    /// gives: it's indistinguishable from genuinely having none, and
    /// guessing would be worse than admitting it's unknown.
    ///
    /// `quantity` counts *packages*, not a raw amount — "0.5" means half
    /// of one container used, "1.5" means one full container plus a
    /// half-used one. `packageSize`/`unit` describe what one whole
    /// package actually is (12 and "oz" for a 12 oz tub of sour cream),
    /// fixed per product rather than changing as it's used up. Buying
    /// another of the same product adds 1 to `quantity`, it never
    /// changes `packageSize` — see `ReceiptImportView.addSelectedItems`,
    /// which merges into an existing pantry item's `quantity` instead of
    /// inserting a duplicate row when the same product is added again.
    ///
    /// A bare-count item (a dozen eggs, an onion — nothing meaningfully
    /// "packaged") has `packageSize == nil` and `unit == nil`; `quantity`
    /// is then the raw count of individual items, not a package fraction
    /// — `PantryDeductionService` reads the two shapes differently for
    /// exactly this reason.
    ///
    /// All three are `Double`/optional-`Double`, not `Int` — a recipe's
    /// own parsed quantities are commonly fractional (½ cup, 1.5 lb), and
    /// forcing an integer would mean rounding at every deduction,
    /// compounding drift over repeated cooking for no real benefit.
    var quantity: Double = 0
    /// The size of one whole package, in `unit` — `nil` for a bare-count
    /// item (see `quantity`'s doc comment) or one added without any
    /// known size (manually typed, or OCR text with no structured size
    /// data to parse).
    var packageSize: Double?
    /// One of `RecipeIngredientParser`'s canonical unit strings (`tbsp`,
    /// `tsp`, `oz`, `cup`, `lb`, `g`, `ml`), or `nil` for a bare count
    /// ("12 eggs" — no unit at all, just a number of items).
    var unit: String?
    /// The brand name, if a UPC lookup found one — display-only, never
    /// read by `PantryDeductionService`'s matching (that's still
    /// whole-word against `title` alone, unaffected by this). `title`
    /// itself is just the bare product name ("Sour Cream") — brand and
    /// size are kept out of it entirely and shown as their own subtitle
    /// in `ShelfListView.TaskRow` instead of baked into one string.
    var brand: String?

    init(
        title: String,
        notes: String = "",
        shelf: Shelf? = nil,
        sourceGmailMessageID: String? = nil,
        dueDate: Date? = nil,
        nextStep: String = "",
        estimatedMinutes: Int = 0,
        tags: [String] = [],
        priority: Priority = .unset,
        createdAt: Date = .now,
        isDivisible: Bool = false,
        minimumSegmentMinutes: Int = 0
    ) {
        self.id = UUID()
        self.title = title
        self.notes = notes
        self.shelf = shelf
        self.sourceGmailMessageID = sourceGmailMessageID
        self.createdAt = createdAt
        self.dueDate = dueDate
        self.nextStep = nextStep
        self.estimatedMinutes = estimatedMinutes
        self.remainingMinutes = estimatedMinutes
        self.tags = tags
        self.priorityRaw = priority.rawValue
        self.isScheduled = false
        self.isDivisible = isDivisible
        self.minimumSegmentMinutes = minimumSegmentMinutes
    }

    var priority: Priority {
        get { Priority(rawValue: priorityRaw) ?? .unset }
        set { priorityRaw = newValue.rawValue }
    }

    func isEligible(for rule: SchedulingRule) -> Bool {
        includedSchedulingRuleIDs.contains(rule.id)
    }

    func setEligible(_ eligible: Bool, for rule: SchedulingRule) {
        if eligible {
            if !includedSchedulingRuleIDs.contains(rule.id) {
                includedSchedulingRuleIDs.append(rule.id)
            }
        } else {
            includedSchedulingRuleIDs.removeAll { $0 == rule.id }
        }
    }

    /// This task's own three properties handed to `rule.fitStatus` — the
    /// convenience every read site actually wants instead of repeating
    /// the same triple of arguments.
    func fitStatus(for rule: SchedulingRule) -> SchedulingFitStatus {
        rule.fitStatus(estimatedMinutes: estimatedMinutes, isDivisible: isDivisible, minimumSegmentMinutes: minimumSegmentMinutes)
    }

    /// The one thing the scheduler (and anything else deciding whether
    /// this task can actually be placed) should read instead of raw
    /// `isEligible(for:)` — both the user's own opt-in *and* a real check
    /// that the task could ever fit. Explicitly toggled eligible for a
    /// rule it can't currently fit still reads `isEligible == true` (see
    /// `isEligible(for:)`) — that's the user's stored choice, unchanged —
    /// but is never `isEffectivelyEligible` until it also fits. Nothing
    /// here ever writes to `includedSchedulingRuleIDs`; a fit failure is
    /// read-only, so loosening the rule later (or the task's own
    /// duration/segment changing) makes this flip back to `true` with no
    /// user action needed — the toggle itself was never touched.
    func isEffectivelyEligible(for rule: SchedulingRule) -> Bool {
        isEligible(for: rule) && rule.canEverFit(estimatedMinutes: estimatedMinutes, isDivisible: isDivisible, minimumSegmentMinutes: minimumSegmentMinutes)
    }

    /// The effective deadline instant — midnight at the end of
    /// `dueDate`'s own calendar day, not the literal time-of-day
    /// `dueDate` happens to carry. `dueDate` almost never carries a
    /// time the user actually chose as a deadline: it auto-fills to
    /// `.now` the instant "Has due date" flips to Yes (see
    /// `dueDatePicked`'s own doc comment), and even a genuinely picked
    /// date typically comes from a date-only picker that leaves that
    /// same incidental time-of-day attached underneath. "Due Friday"
    /// means anytime Friday, not the literal minute the field happened
    /// to get its value — so the deadline this measures against is a
    /// whole day, not an instant. Every at-risk computation below reads
    /// this instead of `dueDate` directly, for the same reason.
    private func endOfDueDate(calendar: Calendar) -> Date? {
        guard let dueDate else { return nil }
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: dueDate))
    }

    /// Minutes of headroom before `dueDate`'s own day becomes
    /// mathematically impossible to hit — negative once there's no
    /// longer enough calendar time left for whatever's still unplaced
    /// (`remainingMinutes`), regardless of whether any specific rule
    /// window actually has room. `nil` when there's no due date at all
    /// (nothing to measure against). `date` is the day being evaluated
    /// from — during a multi-day walk (`AISchedulingService
    /// .taskOrdering`) that's the day currently being packed, not
    /// necessarily `.now`, so ordering on an out day reflects how much
    /// room is left as of *that* day, not today's.
    func slack(asOf date: Date = .now, calendar: Calendar = .current) -> Int? {
        guard let deadline = endOfDueDate(calendar: calendar) else { return nil }
        let minutesUntilDue = Int(deadline.timeIntervalSince(date) / 60)
        return minutesUntilDue - remainingMinutes
    }

    /// A task is at risk in one of two distinct ways, both surfaced the
    /// same way on the task card:
    /// - Still has unplaced work (`remainingMinutes > 0`) and no longer
    ///   enough raw calendar time left to place it before `dueDate`'s
    ///   own day ends (`slack(asOf:) < 0`) — the forward-looking case,
    ///   purely mathematical, no simulation of actual rule-window
    ///   contention.
    /// - Already has an active (not completed) block that ends after
    ///   `dueDate`'s own day — the packer placed it, just too late.
    ///   This is a fact already sitting in `scheduledBlocks`, not
    ///   something slack alone can see: a fully-placed task
    ///   (`remainingMinutes == 0`) always reads as healthy under slack
    ///   math, even when what it was placed *into* blows straight past
    ///   the deadline. This is the more common real-world case — the
    ///   packer did its job, the result just doesn't satisfy the
    ///   deadline — so it can't be left out.
    ///
    /// Skipped entirely — always `false` — while `dueDatePicked` is
    /// still `false`: `dueDate` auto-fills to `.now` the instant "Has
    /// due date" flips to Yes, purely so the date picker has something
    /// to show, before anyone's actually chosen a real deadline.
    /// Without this, a task the user hasn't gotten to yet would flag
    /// itself at risk (and, via `AISchedulingService.taskOrdering`,
    /// jump the queue ahead of every task with a real, deliberately
    /// tight deadline) off a placeholder value nobody chose.
    ///
    /// Neither branch accounts for actual future rule-window contention
    /// (a task that's mathematically fine today but will lose a
    /// bidding war for capacity next week) — that's a real gap, deferred
    /// to Nightly Review's own post-regeneration audit (§7.1) rather
    /// than simulated here.
    func isAtRisk(asOf date: Date = .now, calendar: Calendar = .current) -> Bool {
        guard dueDatePicked else { return false }
        if remainingMinutes > 0, let slack = slack(asOf: date, calendar: calendar), slack < 0 {
            return true
        }
        guard let deadline = endOfDueDate(calendar: calendar) else { return false }
        return (scheduledBlocks ?? []).contains { !$0.isCompleted && $0.endTime > deadline }
    }

    /// Names the actual reason `isAtRisk` is true, for the task card's
    /// own badge — checked in order: already scheduled past the
    /// deadline first (the concrete, already-happened case), then past
    /// due with nothing scheduled at all, then whichever `fitStatus`
    /// explains why none of this shelf's enabled rules can currently
    /// take it. Reads `fitStatus` rather than `includedSchedulingRuleIDs
    /// .isEmpty` deliberately — a task with schedules toggled on that
    /// all evaluate to `.exceedsConstraint` (or `.needsDuration`/
    /// `.needsMinimumSegment`) has real rules selected; reporting "no
    /// eligible schedule" for that case would name the wrong blocker.
    /// `nil` when the task isn't at risk at all (including the
    /// `dueDatePicked == false` case `isAtRisk` itself skips). Takes
    /// `asOf`/`calendar` (defaults matching `slack`/`isAtRisk`) rather
    /// than hardcoding real wall-clock time internally — both so the
    /// "past due" check below stays consistent with whatever moment
    /// `isAtRisk` itself was evaluated against, and so this is actually
    /// testable against a fixed date rather than only ever reflecting
    /// whenever the test happens to run.
    func atRiskBlocker(asOf date: Date = .now, calendar: Calendar = .current) -> String? {
        guard isAtRisk(asOf: date, calendar: calendar) else { return nil }
        let deadline = endOfDueDate(calendar: calendar)
        if let deadline, (scheduledBlocks ?? []).contains(where: { !$0.isCompleted && $0.endTime > deadline }) {
            return "Scheduled past its due date"
        }
        if let deadline, deadline < date {
            return "Past due"
        }
        // Two separate axes: whether this task has actually toggled
        // itself eligible for a given rule at all (`isEligible`, the
        // stored user choice), and whether that rule could ever take it
        // (`fitStatus`, independent of the toggle). Conflating them was
        // the exact bug being corrected here — a task with real rules
        // toggled on that all fail their own fit check needs the fit
        // reason named, not "no eligible schedule."
        let toggledRules = (shelf?.schedulingRules ?? []).filter { $0.isEnabled && isEligible(for: $0) }
        guard !toggledRules.isEmpty else { return "No eligible schedule" }
        let statuses = toggledRules.map { fitStatus(for: $0) }
        // `.fits` present among the toggled rules means this task IS
        // effectively eligible for at least one of them — nothing about
        // its own attributes is blocking it, so whatever kept it
        // unplaced is real window/capacity contention, not a
        // configuration problem.
        if statuses.contains(.fits) { return "Insufficient capacity" }
        if statuses.contains(.exceedsConstraint) { return "Exceeds every eligible schedule's time constraint" }
        if statuses.contains(.needsMinimumSegment) { return "Set a minimum segment first" }
        if statuses.contains(.needsDuration) { return "Set a duration first" }
        return "No eligible schedule"
    }

    /// Marks this task complete with the exact same effects as checking
    /// it off on the calendar (see `ScheduleReviewViewModel.toggleComplete`)
    /// — every active scheduled block behind it is marked complete too,
    /// and its Task Stats contribution is recorded. Shared so every "Mark
    /// Complete" entry point (a task card's button, Task Attribute
    /// Review, the calendar itself) stays consistent.
    func markComplete(in modelContext: ModelContext) {
        setCompleted(true, in: modelContext)
    }

    /// Shared by every "mark complete" entry point (the calendar's
    /// tap-to-complete circle, a task card's Mark Complete button, Task
    /// Attribute Review's) — and, going the other way, by that same Mark
    /// Complete button tapped again on an already-completed task, which
    /// un-marks it everywhere at once: the task itself, every one of its
    /// scheduled blocks (so the calendar's own circle un-checks too), and
    /// its `TaskCompletionRecord` stats snapshot.
    func setCompleted(_ completed: Bool, in modelContext: ModelContext) {
        isCompleted = completed
        for block in scheduledBlocks ?? [] {
            block.isCompleted = completed
        }
        if completed {
            TaskCompletionRecord.upsert(for: self, in: modelContext)
        } else {
            TaskCompletionRecord.remove(for: self, in: modelContext)
        }
    }

    /// Keeps an already-scheduled block's calendar time in sync with this
    /// task's own `estimatedMinutes` — same `startTime`, `endTime`
    /// stretched or shrunk to match whatever the duration currently is.
    /// Only when there's exactly one active (incomplete) block: a
    /// divisible task mid-split across several blocks has no single
    /// well-defined block to resize, so those are left alone. Dropped
    /// back to "proposed" if the block was already approved, so the next
    /// Approve All actually pushes the corrected time to Google Calendar
    /// instead of leaving the stale one live. Called both when a
    /// duration edit is made (`TaskReviewCard`'s Duration picker) and
    /// when one's rolled back (`TaskEditSnapshot.restore`, on Cancel) —
    /// either way, the calendar should always reflect whatever
    /// `estimatedMinutes` currently says.
    func syncScheduledBlockDuration() {
        let activeBlocks = (scheduledBlocks ?? []).filter { !$0.isCompleted }
        guard activeBlocks.count == 1, let block = activeBlocks.first, estimatedMinutes > 0 else { return }
        block.endTime = block.startTime.addingTimeInterval(TimeInterval(estimatedMinutes * 60))
        block.isEstimatedDuration = false
        if block.approvalStatus == .approved {
            block.approvalStatus = .proposed
        }
    }

    /// 0 is the "no duration" sentinel — used by shelves with duration
    /// tracking off (see `Shelf.hasDefaultDuration`) — rather than making
    /// `estimatedMinutes` optional and rippling `?? `s through every call
    /// site. It also already means "never scheduled": AISchedulingService's
    /// packer skips anything with `minutesNeeded <= 0`.
    static func durationLabel(for minutes: Int) -> String {
        guard minutes > 0 else { return "Not Selected" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) hr" : "\(hours)h \(remainder)m"
    }

    var durationLabel: String { Self.durationLabel(for: estimatedMinutes) }

    /// True if "Has due date" is Yes but no real date has been chosen yet
    /// — just the `.now` auto-fill sitting there unconfirmed. False (not
    /// missing) once a date's actually picked, once the answer is an
    /// explicit "No" (`dueDate == nil`), or once `shelf` doesn't track due
    /// dates at all — matching where the Due Date row itself is shown.
    /// Takes an explicit shelf (rather than always reading `self.shelf`) so
    /// `TaskReviewCard` can ask "what would still be missing on the shelf
    /// I'm previewing" before a move actually commits.
    ///
    /// Also false outright for a recurring task — it's never asked "Has
    /// due date" at all (`recurringSection` replaces that whole question
    /// with Start Date, a deliberately-optional anchor now that
    /// `makeRecurring()` no longer auto-fills one — see its own doc
    /// comment). Without this exclusion, a fresh recurring task with no
    /// anchor yet would read as "missing Due Date," a question it was
    /// never actually shown. See `startDateMissing` for the question a
    /// recurring task is asked instead.
    private func dueDateMissing(on shelf: Shelf?) -> Bool {
        guard CardRow.due.isShown(task: self, shelf: shelf) else { return false }
        return !dueDateDecided || (dueDate != nil && !dueDatePicked)
    }

    /// The inverse of `dueDateMissing` — only ever applies to a recurring
    /// task, which is asked Start Date instead of "Has due date." Without
    /// this, a fresh recurring task with no anchor set (the deliberate
    /// starting state — see `TaskItem.makeRecurring`'s doc comment) would
    /// silently sit unscheduled forever with nothing prompting it to be
    /// finished, rather than surfacing in the attribute review the way an
    /// ordinary task's missing due date does.
    private func startDateMissing(on shelf: Shelf?) -> Bool {
        guard CardRow.canStartBy.isShown(task: self, shelf: shelf) else { return false }
        // Always shown, but only ever *required* for a recurring task —
        // the recurrence anchor there, optional metadata otherwise.
        // `.shown` is a precondition for missing, not a promise of it
        // (see `CardRow.Visibility`).
        return isRecurring && !startDatePicked
    }

    /// Same reasoning as `startDateMissing`, for "Every" — a recurring
    /// task's interval/unit pair starts on a real, storable default
    /// ("every 1 day"), not a placeholder, so only `recurrenceIntervalPicked`
    /// can tell "never touched" apart from "deliberately every 1 day."
    private func recurrenceIntervalMissing(on shelf: Shelf?) -> Bool {
        guard CardRow.repeats.isShown(task: self, shelf: shelf) else { return false }
        return !recurrenceIntervalPicked
    }

    /// Same reasoning again, for "Time" (AM/Midday/PM/Specific) — `.specific`
    /// is `recurrenceTimeModeRaw`'s real stored default, not evidence
    /// anyone chose it.
    private func recurrenceTimeModeMissing(on shelf: Shelf?) -> Bool {
        guard CardRow.timeMode.isShown(task: self, shelf: shelf) else { return false }
        return !recurrenceTimeModePicked
    }

    /// Only applies when `recurrenceUnit == .months` — daily/weekly
    /// recurrence never asks this question at all, since "on the 1st" or
    /// "the last Saturday" only mean something once a month. Gated on
    /// `recurrenceUnit`, not `recurrenceMode` (a prior version of this
    /// check) — `TaskReviewCard`'s combined "On the" row can resolve to
    /// *either* mode (the "Same day" choice sets `.specificDate`, "First
    /// day"/"Last day"/a weekday set `.relativeDate`), so `recurrenceMode`
    /// alone can no longer tell "never touched this question" apart from
    /// "deliberately chose Same day" — `recurrenceMode == .specificDate`
    /// is what *both* of those states look like. `relativeRecurrencePicked`
    /// is still the one flag both branches share, exactly as before: "Day
    /// of Month, First" (i.e. "the 1st of the month") is a real, storable
    /// default, not a placeholder, so only this flag can tell "never
    /// touched" apart from "deliberately the 1st."
    private func relativeRecurrenceMissing(on shelf: Shelf?) -> Bool {
        // "Pattern" is asked inside the Repeats row, so it shares that
        // row's visibility rather than having one of its own.
        guard CardRow.repeats.isShown(task: self, shelf: shelf) else { return false }
        return recurrenceUnit == .months && !relativeRecurrencePicked
    }

    /// True if "Has next step" is Yes but nothing's actually been typed,
    /// unless `shelf` doesn't track it at all — matching where the Next
    /// Step field is shown/hidden. Same shape as `durationMissing`: false
    /// once real text exists, once the answer is an explicit "No"
    /// (`nextStep` is `""` by design, not by omission), or once the shelf
    /// doesn't track this attribute. The shelf-level gate above and the
    /// task-level "No" answer are independent — a task explicitly
    /// toggled off stays not-missing even if it later moves to a shelf
    /// that tracks Next Step, and a shelf that doesn't track it never
    /// looks at `nextStepDecided`/`nextStepAnsweredYes` at all.
    private func nextStepMissing(on shelf: Shelf?) -> Bool {
        guard CardRow.nextStep.isShown(task: self, shelf: shelf) else { return false }
        return !nextStepDecided || (nextStepAnsweredYes && nextStep.isEmpty)
    }

    /// True if Priority is unset, unless `shelf` doesn't track it at all —
    /// matching where the Priority section is shown/faded. Also false
    /// outright for a recurring task: High Priority isn't offered to a
    /// repeating task at all (see `TaskReviewCard`'s Priority row), same
    /// shelf-level short-circuit shape as the untracked-attribute case
    /// above, just gated on the task instead of the shelf.
    private func priorityMissing(on shelf: Shelf?) -> Bool {
        guard CardRow.priority.isShown(task: self, shelf: shelf) else { return false }
        return priority == .unset
    }

    /// True for a recurring task using AM/Midday/PM instead of Specific
    /// Time — an untimed occurrence never gets a calendar block, so
    /// Duration and Divisible are meaningless for it, not just
    /// unanswered. Shared by `durationMissing`/`divisibleMissing` so
    /// neither flags a question the card doesn't ask.
    ///
    /// `internal`, not `private`, so the card's own row-visibility
    /// predicates (`TaskReviewCard.showsDurationRow`/`.showsDivisibleRow`)
    /// read this exact definition rather than restating it. They
    /// restating it separately is what let the two drift apart in the
    /// first place — the rows kept rendering for an untimed recurring
    /// task after Duration/Divisible were flattened out of the "Time"
    /// row, while this guard went on correctly reporting them
    /// not-missing.
    var recurringAndUntimed: Bool {
        isRecurring && recurrenceTimeMode != .specific
    }

    /// True only if Duration has never been answered at all. `0` minutes
    /// ("None") is a real answer, not an absence of one — see
    /// `durationPicked`. False (not missing) once anything at all has
    /// been chosen from the wheel, "None" included.
    private func durationMissing(on shelf: Shelf?) -> Bool {
        guard CardRow.duration.isShown(task: self, shelf: shelf) else { return false }
        return !durationPicked
    }

    /// True if `shelf` has scheduling rules to weigh in on and nothing's
    /// been picked yet. Unlike due date/duration, there's no separate
    /// "decided" flag here — an empty selection always means incomplete,
    /// since "eligible for none of these" isn't a real answer a task can
    /// land on.
    private func eligibleSchedulesMissing(on shelf: Shelf?) -> Bool {
        guard CardRow.eligibleSchedules.isShown(task: self, shelf: shelf) else { return false }
        return includedSchedulingRuleIDs.isEmpty
    }

    /// Same shape as `durationMissing` — true only if Divisible has never
    /// been answered. "Not Divisible" (`minimumSegmentMinutes == 0`) is a
    /// real answer, not an absence of one. Only tracked on shelves that
    /// offer Divisible at all, matching where the row itself is shown.
    ///
    /// Also never missing when this task's own duration admits no valid
    /// segment size (`validSegmentOptions` empty — a duration of 2, or
    /// any prime/indivisible one): the wheel would then have exactly one
    /// selectable option, "Not Divisible," and a question with a single
    /// possible answer isn't a real question to flag as unanswered. That
    /// check previously lived only as an ad-hoc condition inside
    /// `TaskReviewCard.isDurationConfigured`; folding it in here means
    /// the card and the missing-badge agree by construction rather than
    /// by both remembering to special-case it.
    private func divisibleMissing(on shelf: Shelf?) -> Bool {
        // Every reason this row might not apply — untimed recurring,
        // a shelf that doesn't track duration, a duration under the
        // hour threshold, a duration nothing evenly divides — lives in
        // `CardRow.divisible`'s own visibility rule, shared with the
        // card so the row and this check can't disagree.
        guard CardRow.divisible.isShown(task: self, shelf: shelf) else { return false }
        return !divisiblePicked
    }

    /// Flagged for the Nightly Review's attribute-cleanup pass — true if
    /// ANY of next step, due date, priority, duration, divisible (when the
    /// shelf actually tracks duration), or eligible schedules (when the
    /// shelf actually has any) is still incomplete. Tags don't count
    /// either way.
    var isMissingAttributes: Bool {
        !missingAttributeNames(consideringShelf: shelf).isEmpty
    }

    /// Same criteria as `isMissingAttributes`, spelled out by name — so a
    /// "remaining attributes" reminder can say exactly what's left instead
    /// of just that something is. Defaults to this task's actual shelf;
    /// `TaskReviewCard`'s "Remaining Attributes" summary passes the
    /// currently-previewed shelf instead, so tapping a shelf that doesn't
    /// track (say) Next Step immediately drops it from the list, without
    /// waiting for the move to actually commit.
    var missingAttributeNames: [String] {
        missingAttributeNames(consideringShelf: shelf)
    }

    func missingAttributeNames(consideringShelf shelf: Shelf?) -> [String] {
        var missing: [String] = []
        if nextStepMissing(on: shelf) { missing.append("Next Step") }
        if dueDateMissing(on: shelf) { missing.append("Due Date") }
        if startDateMissing(on: shelf) { missing.append("Start Date") }
        if recurrenceIntervalMissing(on: shelf) { missing.append("Every") }
        if recurrenceTimeModeMissing(on: shelf) { missing.append("Time") }
        if relativeRecurrenceMissing(on: shelf) { missing.append("Pattern") }
        if priorityMissing(on: shelf) { missing.append("Priority") }
        if durationMissing(on: shelf) { missing.append("Duration") }
        if divisibleMissing(on: shelf) { missing.append("Divisible") }
        if eligibleSchedulesMissing(on: shelf) { missing.append("Eligible Schedules") }
        return missing
    }
}

/// The Occurrence Time wheels' own conversion between minutes-since-
/// midnight (what `recurrenceTimeOfDayMinutes` actually stores) and
/// hour(1–12)/minute(one of 0/15/30/45)/AM-or-PM (what three plain
/// `Picker(.wheel)`s actually show) — pulled out as its own value type so
/// that conversion is testable independent of SwiftUI, rather than living
/// only inside the wheel picker view's private bindings.
struct QuarterHourClockTime: Equatable {
    var hour12: Int
    var minute: Int
    var isPM: Bool

    init(hour12: Int, minute: Int, isPM: Bool) {
        self.hour12 = hour12
        self.minute = minute
        self.isPM = isPM
    }

    init(minutesSinceMidnight: Int) {
        let hour24 = (minutesSinceMidnight / 60) % 24
        let hour = hour24 % 12
        hour12 = hour == 0 ? 12 : hour
        minute = minutesSinceMidnight % 60
        isPM = hour24 >= 12
    }

    var minutesSinceMidnight: Int {
        let hour24 = (hour12 % 12) + (isPM ? 12 : 0)
        return hour24 * 60 + minute
    }
}
