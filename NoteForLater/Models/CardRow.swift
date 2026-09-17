import Foundation

/// Every row the task card can show, and the single answer to "does this
/// row apply to this task right now."
///
/// **Why this exists.** The card used to answer that question in three
/// places — the recurring branch's row list, the non-recurring branch's,
/// and each attribute's own `...Missing` check on `TaskItem` — and they
/// drifted. Divisible alone had three disagreeing definitions, and a
/// shipped regression came from exactly that: Duration and Divisible kept
/// rendering for untimed recurring tasks while the missing-checks
/// correctly reported them not-missing, because "is this row shown" and
/// "can this row be reported missing" were separate facts with nothing
/// tying them together.
///
/// `visibility(task:shelf:)` is now the one applicability rule. The card
/// renders from it and every `...Missing` check guards on it, so the two
/// cannot disagree again.
///
/// Lives in the model layer, not in `NightlyReviewView`, because
/// `TaskItem.missingAttributeNames` reads it — a view-owned type would
/// make the model depend on the view.
enum CardRow: CaseIterable {
    // Shown for every task.
    case nextStep
    case recurringToggle
    case canStartBy
    case duration
    case divisible
    case tags
    case shelf
    case eligibleSchedules
    case remindIn
    // Non-recurring only.
    case due
    case priority
    // Recurring only.
    case repeats
    case timeMode
    case ends
    case pushIfMissed

    /// Whether a row is offered, offered-but-not-editable, or absent.
    ///
    /// **The rule, stated once rather than inferred per-property:**
    /// - `.hidden` — the question is *meaningless* for this task. Wrong
    ///   task kind (Priority on a recurring task; Repeats on a
    ///   non-recurring one), or an attribute this shelf doesn't deal in
    ///   at all (Next Step on a shelf that doesn't track it).
    /// - `.greyed` — the question *applies* but is currently
    ///   unanswerable, and seeing that it exists is useful. Duration on a
    ///   shelf that doesn't track duration: the stored value is real and
    ///   kept, it just can't be edited from here.
    /// - `.shown` — ordinary.
    ///
    /// **Only `.shown` can be reported missing.** `.greyed` and `.hidden`
    /// both suppress it — a question you can't answer must never be held
    /// against you. The converse does not hold: a row can be `.shown` and
    /// still never missing (Can Start By on a non-recurring task is
    /// optional metadata), so `.shown` is a precondition for missing, not
    /// a promise of it.
    enum Visibility {
        case shown
        case greyed
        case hidden
    }

    func visibility(task: TaskItem, shelf: Shelf?) -> Visibility {
        switch self {
        case .nextStep:
            return (shelf?.effectiveTracksNextStep ?? true) ? .shown : .hidden

        case .recurringToggle:
            // **This is the one remaining `isTwoMinute` check, and it is
            // deliberately not shelf-settings-driven.** Every other row's
            // 2-Minute special-casing was removed in favour of the
            // destination shelf's own tracking toggles; this one is a
            // different kind of rule and must not follow them.
            //
            // It is *mutual exclusion*, enforced in the model: a recurring
            // task must not sit on the 2-Minute shelf (see
            // `TaskItem.repairSpecialShelfExclusivity`/`assignShelf`).
            // Offering Recurring here would let the card propose a
            // combination the model refuses — and no shelf toggle should be
            // able to do that. Field *tracking* says what a shelf cares
            // about; this says what the data model permits.
            return isTwoMinute(shelf: shelf) ? .hidden : .shown

        case .shelf, .canStartBy:
            // Always offered. Can Start By is shown for a non-recurring
            // task too, as optional metadata — it simply never reports
            // missing there (see `TaskItem.startDateMissing`).
            return .shown

        case .tags:
            // A recurring task is one definition read many times rather
            // than a thing you file, so Tags stays hidden there by rule.
            //
            // The 2-Minute half of this is gone: the destination shelf's
            // own `tracksTags` toggle decides now, like any other shelf.
            if task.isRecurring { return .hidden }
            return (shelf?.effectiveTracksTags ?? true) ? .shown : .hidden

        case .duration:
            // An untimed recurring occurrence never gets a calendar
            // block, so it has no duration to state — meaningless, not
            // merely unanswerable.
            //
            // NOTE: once Specific Time is removed as an option for
            // recurring tasks, `recurringAndUntimed` becomes true for
            // *every* recurring task and this single line will hide
            // Duration for all of them — no extra rule needed. That's why
            // there's no `task.isRecurring` clause here despite the card
            // spec saying recurring hides Duration: adding one now would
            // hide it while Specific-Time recurring tasks still need a
            // block length they'd have no way to set.
            if task.recurringAndUntimed { return .hidden }
            // **Never hidden on the shelf Duration itself selects** — see
            // `Shelf.durationIsTheDestinationTrigger`. This exception is now
            // load-bearing rather than vacuous: the fallback below hides, so
            // without it a 2-Minute shelf with Duration switched off would
            // strand the task — the duration uneditable, and the shelf picker
            // already narrowed to 2-Minute shelves only, so no way back.
            //
            // `.shown`, not `.greyed`: it has to stay *editable*, because
            // raising the duration is the way off this shelf.
            if shelf?.durationIsTheDestinationTrigger == true { return .shown }
            // Hidden rather than greyed, matching Due below. The old
            // rationale was that greying kept a stored value legible — but
            // `Shelf.resolvedDuration` returns 0 for a non-tracking shelf and
            // both move paths apply it, so the value is wiped on commit
            // anyway. There is nothing left to keep legible.
            return (shelf?.effectiveTracksDuration ?? true) ? .shown : .hidden

        case .divisible:
            if task.recurringAndUntimed { return .hidden }
            // No 2-Minute check: it rides on `tracksDuration` below and on
            // the ≥60-minute threshold, which already does the real work —
            // a task short enough to select the 2-Minute shelf is far below
            // it. A separate flag would be two things controlling one row.
            // Deliberately `.hidden` rather than `.greyed` where Duration
            // is `.greyed`, reproducing today's behavior exactly. The
            // asymmetry is real and pre-existing: Duration stays visible
            // on a non-tracking shelf so its stored value is legible,
            // while Divisible — which has nothing to show without a
            // duration to divide — disappears. Flagged rather than
            // silently normalized; changing it is a behavior decision,
            // not a refactor.
            guard shelf?.effectiveTracksDuration ?? true else { return .hidden }
            // Too short to split, or no segment size evenly divides it.
            // Two independent reasons: 70 minutes clears the hour bar and
            // still has no valid option.
            guard task.estimatedMinutes >= TaskItem.divisibleMinimumDurationMinutes else { return .hidden }
            guard !TaskItem.validSegmentOptions(for: task.estimatedMinutes).isEmpty else { return .hidden }
            return .shown

        case .due:
            if task.isRecurring { return .hidden }
            // Hidden, not greyed. A row you turned off and still can't edit
            // is clutter; off means gone. (This greyed until the 2-Minute
            // hardcoding was removed, at which point the greyed state became
            // user-visible for the first time and read as a bug.)
            return (shelf?.effectiveTracksDueDates ?? true) ? .shown : .hidden

        case .priority:
            if task.isRecurring { return .hidden }
            return (shelf?.effectiveTracksPriority ?? true) ? .shown : .hidden

        case .eligibleSchedules:
            return (shelf?.schedulingRules ?? []).isEmpty ? .hidden : .shown

        case .remindIn:
            // Opt-in per shelf — `tracksFutureReminder` starts false,
            // unlike every other tracking flag — so this defaults to
            // hidden for a task with no shelf yet.
            return (shelf?.effectiveTracksFutureReminder ?? false) ? .shown : .hidden

        case .repeats, .timeMode, .ends, .pushIfMissed:
            return task.isRecurring ? .shown : .hidden
        }
    }

    /// Convenience for the common guard.
    func isShown(task: TaskItem, shelf: Shelf?) -> Bool {
        visibility(task: task, shelf: shelf) == .shown
    }

    /// Which stack a row is drawn in. The card's scroll body is not one
    /// flat list: the task-attribute rows sit in their own
    /// `VStack(spacing: 14)` while the tail sits in the outer
    /// `VStack(spacing: 10)`. That difference is visible, so the grouping
    /// is part of the definition rather than something the view
    /// reinvents — a single flat `ForEach` would silently re-space the
    /// card.
    enum Section {
        /// The per-task attribute rows, inner stack.
        case attributes
        /// Remind In, Tags, Shelf, Eligible Schedules — outer stack.
        case tail
    }

    var section: Section {
        switch self {
        case .remindIn, .tags, .shelf, .eligibleSchedules: return .tail
        default: return .attributes
        }
    }

    /// Every row the scroll body draws, in draw order, already filtered
    /// to what applies. **This is the one list.** The card renders from
    /// it and `TaskReviewCard.initialExpandedRow` walks it, so "the
    /// expand-seeding order matches the render order" isn't a property
    /// that has to be tested — they are the same array.
    ///
    /// Excludes `.nextStep`, which is drawn in `cardHeader` above the
    /// scroll body rather than among these rows. Its *visibility* still
    /// comes from `CardRow` like everything else; only its position
    /// lives elsewhere.
    ///
    /// `.greyed` rows are included — greyed means drawn-but-disabled, not
    /// absent. Only `.hidden` drops out.
    static func scrollBodyOrder(task: TaskItem, shelf: Shelf?) -> [CardRow] {
        var rows: [CardRow] = [.recurringToggle]
        if task.isRecurring {
            rows += [.repeats, .canStartBy, .timeMode, .duration, .divisible, .ends, .pushIfMissed]
        } else {
            rows += [.due, .canStartBy, .duration, .divisible, .priority]
        }
        rows += [.remindIn, .tags, .shelf, .eligibleSchedules]
        return rows.filter { $0.visibility(task: task, shelf: shelf) != .hidden }
    }

    /// Whether this row collapses to a value and expands to its
    /// controls (`CollapsibleAnswerRow`), as opposed to being drawn as
    /// plain content — the toggle, Tags, Shelf, Eligible Schedules,
    /// Remind In, Push if missed.
    ///
    /// This enum is the expand/collapse identity itself; there is no
    /// second row enum. Two near-identical enums would be new drift on
    /// day one, and a view-owned one would have inverted the dependency
    /// this type exists on the model side to avoid.
    var isExpandable: Bool {
        switch self {
        case .repeats, .canStartBy, .timeMode, .duration, .divisible, .ends, .due, .priority:
            return true
        case .nextStep, .recurringToggle, .tags, .shelf, .eligibleSchedules, .remindIn, .pushIfMissed:
            return false
        }
    }

    /// 2-minute-ness is shelf membership, not a stored task field — see
    /// the stage-3 decision. Everything asking "is this a 2-minute task?"
    /// goes through here so there's one answer.
    private func isTwoMinute(shelf: Shelf?) -> Bool {
        shelf?.isTwoMinuteTasks == true
    }

    /// Clears whatever this row was holding. Called only for rows that a
    /// toggle just *hid*, never on a hand-written list — see
    /// `TaskReviewCard.resetFieldsHidden(by:)`, which computes the set as
    /// (rows shown before − rows shown after). That derivation is the
    /// guard against a toggle clearing something it doesn't own: it can
    /// only reach rows that actually disappeared, and adding a future
    /// `CardRow` can't leave a stale reset list behind.
    ///
    /// Rows with nothing of their own to clear — the toggles themselves,
    /// Shelf, Eligible Schedules — are deliberately no-ops rather than
    /// omitted, so a new case has to make an explicit choice here.
    func resetFields(on task: TaskItem) {
        switch self {
        case .due:
            task.dueDate = nil
            task.dueDateDecided = false
            task.dueDatePicked = false
        case .duration:
            task.estimatedMinutes = 0
            task.remainingMinutes = 0
            task.durationPicked = false
        case .divisible:
            task.isDivisible = false
            task.minimumSegmentMinutes = 0
            task.divisiblePicked = false
        case .priority:
            task.priority = .unset
        case .tags:
            task.tags = []
        case .nextStep:
            task.nextStep = ""
            task.nextStepDecided = false
            task.nextStepAnsweredYes = false
        case .canStartBy:
            task.clearStartDate()
        case .remindIn:
            task.remindInCount = 0
        case .repeats, .timeMode, .ends, .pushIfMissed:
            // Recurrence settings are cleared by `setRecurring(false)`
            // itself, atomically with the flag — not row by row.
            break
        case .recurringToggle, .shelf, .eligibleSchedules:
            break
        }
    }
}
