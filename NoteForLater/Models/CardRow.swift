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

        case .recurringToggle, .tags, .shelf, .canStartBy:
            // Always offered. Can Start By is shown for a non-recurring
            // task too, as optional metadata — it simply never reports
            // missing there (see `TaskItem.startDateMissing`).
            return .shown

        case .duration:
            // An untimed recurring occurrence never gets a calendar
            // block, so it has no duration to state — meaningless, not
            // merely unanswerable.
            if task.recurringAndUntimed { return .hidden }
            return (shelf?.effectiveTracksDuration ?? true) ? .shown : .greyed

        case .divisible:
            if task.recurringAndUntimed { return .hidden }
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
            return (shelf?.effectiveTracksDueDates ?? true) ? .shown : .greyed

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
}
