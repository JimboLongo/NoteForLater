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

    var recurrenceUnit: RecurrenceUnit {
        get { RecurrenceUnit(rawValue: recurrenceUnitRaw) ?? .days }
        set { recurrenceUnitRaw = newValue.rawValue }
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
