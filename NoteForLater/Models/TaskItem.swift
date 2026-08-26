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
    var nextStep: String = ""
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
    /// Same idea as `dueDateDecided`, for "Has duration."
    var durationDecided: Bool = false
    /// Which pill "Has duration" landed on, independent of
    /// `estimatedMinutes` — needed because Yes can be selected before a
    /// real value's been picked (dropdown starts at 0/"Not Selected"),
    /// and No resets `estimatedMinutes` to that same 0. Without this,
    /// "Yes selected" and "No selected" would both collapse to
    /// `estimatedMinutes == 0`, making it impossible to tell them apart —
    /// switching from No to Yes would look like nothing happened. Only
    /// meaningful when `durationDecided` is true.
    var durationAnsweredYes: Bool = false
    var tags: [String] = []
    var priorityRaw: String = Priority.unset.rawValue
    var isScheduled: Bool = false
    var isCompleted: Bool = false
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
    /// nil means "indefinitely."
    var recurrenceEndDate: Date?
    /// Reuses `HabitOccurrenceTimeMode` rather than a second, parallel
    /// enum — `.specific` means exactly today's existing behavior (placed
    /// on the calendar at `dueDate`'s own time-of-day, via
    /// `recurringOccurrenceTime`); `.am`/`.midday`/`.pm` means this
    /// occurrence never gets a `ScheduledBlock` at all (see
    /// `AISchedulingService.placeHabitsAndRecurringTasks`'s skip, mirrored
    /// from the habit one) and instead shows as a plain check-off item in
    /// that part of the day (see `DayTimelineGridView`), completion
    /// tracked in `RecurringTaskLog` rather than a block's own
    /// `isCompleted` — a recurring task has no single, one-time
    /// completion state the way a plain block does, the same reason
    /// habits needed `HabitLog` instead of reusing `ScheduledBlock` for
    /// this. Defaults to `.specific` so every recurring task that existed
    /// before this field did keeps behaving exactly as it always has.
    var recurrenceTimeModeRaw: String = HabitOccurrenceTimeMode.specific.rawValue

    var recurrenceUnit: RecurrenceUnit {
        get { RecurrenceUnit(rawValue: recurrenceUnitRaw) ?? .days }
        set { recurrenceUnitRaw = newValue.rawValue }
    }

    var recurrenceTimeMode: HabitOccurrenceTimeMode {
        get { HabitOccurrenceTimeMode(rawValue: recurrenceTimeModeRaw) ?? .specific }
        set { recurrenceTimeModeRaw = newValue.rawValue }
    }

    /// Whether an occurrence of this recurring task lands on `date`'s
    /// calendar day — stepping forward from the anchor (`dueDate`'s own
    /// day) by `recurrenceIntervalCount` `recurrenceUnit`s at a time,
    /// forever unless `recurrenceEndDate` cuts it off. `date` is compared
    /// by calendar day only; see `recurringOccurrenceTime` for the actual
    /// time an occurrence should land at.
    func hasRecurringOccurrence(on date: Date, calendar: Calendar = .current) -> Bool {
        guard isRecurring, recurrenceIntervalCount > 0, let anchor = dueDate else { return false }
        let day = calendar.startOfDay(for: date)
        let anchorDay = calendar.startOfDay(for: anchor)
        guard day >= anchorDay else { return false }
        if let end = recurrenceEndDate, day > calendar.startOfDay(for: end) { return false }

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

    /// Whether this task is allowed to land on `date` at all, per its own
    /// `startDate` — `true` when there's no `startDate` set. Checked by
    /// `AISchedulingService` before ever considering a task as a
    /// candidate for a given day's packing.
    func isEligibleToStart(on date: Date, calendar: Calendar = .current) -> Bool {
        guard let startDate else { return true }
        return calendar.startOfDay(for: date) >= calendar.startOfDay(for: startDate)
    }

    /// The time an occurrence landing on `date` should actually be placed
    /// at — always the anchor (`dueDate`)'s own time-of-day, applied onto
    /// `date`'s calendar day.
    func recurringOccurrenceTime(on date: Date, calendar: Calendar = .current) -> Date? {
        guard let anchor = dueDate else { return nil }
        let anchorComponents = calendar.dateComponents([.hour, .minute], from: anchor)
        return calendar.date(bySettingHour: anchorComponents.hour ?? 9, minute: anchorComponents.minute ?? 0, second: 0, of: date)
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
    /// 0 is the "Not Selected" sentinel, same convention as
    /// `estimatedMinutes` — a real minimum has to be actively chosen once
    /// Divisible is Yes.
    var minimumSegmentMinutes: Int = 0
    /// Same idea as `durationDecided` — whether "Divisible" has actually
    /// been answered either way, so the Yes/No pills start unanswered
    /// instead of "No" reading as already picked.
    var isDivisibleDecided: Bool = false

    /// The chunk sizes worth offering as a minimum segment, in general —
    /// not a uniform step, just the values that make sense to a person.
    /// `validSegmentOptions(for:)` is what any UI should actually show.
    static let segmentOptionCandidates = [15, 30, 45, 60, 90, 120, 240]

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
    private func dueDateMissing(on shelf: Shelf?) -> Bool {
        guard shelf?.effectiveTracksDueDates ?? true else { return false }
        return !dueDateDecided || (dueDate != nil && !dueDatePicked)
    }

    /// True if Next Step is blank, unless `shelf` doesn't track it at all —
    /// matching where the Next Step field is shown/hidden.
    private func nextStepMissing(on shelf: Shelf?) -> Bool {
        guard shelf?.effectiveTracksNextStep ?? true else { return false }
        return nextStep.isEmpty
    }

    /// True if Priority is unset, unless `shelf` doesn't track it at all —
    /// matching where the Priority section is shown/faded.
    private func priorityMissing(on shelf: Shelf?) -> Bool {
        guard shelf?.effectiveTracksPriority ?? true else { return false }
        return priority == .unset
    }

    /// True if "Has duration" is Yes but nothing's been picked from the
    /// dropdown yet (still sitting on "Not Selected"). False (not missing)
    /// once a real duration's chosen, or once the answer is an explicit
    /// "No" (`durationAnsweredYes == false`).
    private func durationMissing(on shelf: Shelf?) -> Bool {
        guard shelf?.effectiveTracksDuration ?? true else { return false }
        return !durationDecided || (durationAnsweredYes && estimatedMinutes == 0)
    }

    /// True if `shelf` has scheduling rules to weigh in on and nothing's
    /// been picked yet. Unlike due date/duration, there's no separate
    /// "decided" flag here — an empty selection always means incomplete,
    /// since "eligible for none of these" isn't a real answer a task can
    /// land on.
    private func eligibleSchedulesMissing(on shelf: Shelf?) -> Bool {
        !(shelf?.schedulingRules ?? []).isEmpty && includedSchedulingRuleIDs.isEmpty
    }

    /// Same shape as `durationMissing` — "Divisible" is Yes but the
    /// minimum-segment dropdown is still on "Not Selected." Only tracked
    /// on shelves that track duration at all, matching where the
    /// Divisible row itself is shown.
    private func divisibleMissing(on shelf: Shelf?) -> Bool {
        guard shelf?.effectiveTracksDuration ?? true else { return false }
        return !isDivisibleDecided || (isDivisible && minimumSegmentMinutes == 0)
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
        if priorityMissing(on: shelf) { missing.append("Priority") }
        if durationMissing(on: shelf) { missing.append("Duration") }
        if divisibleMissing(on: shelf) { missing.append("Divisible") }
        if eligibleSchedulesMissing(on: shelf) { missing.append("Eligible Schedules") }
        return missing
    }
}
