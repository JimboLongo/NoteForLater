import Foundation
import SwiftData

/// One force-skip: a Nightly Review step whose engagement timer was
/// deliberately bypassed.
///
/// **A record per skip, not a counter.** Every stat in this app is derived
/// from records — `TaskCompletionRecord`, `TaskMissRecord`,
/// `RecurringTaskLog` — and a bare `Int` could only ever answer "how many".
/// This answers which step, and when, which is what makes a per-step or
/// per-date breakdown possible later without a second migration.
///
/// **`stepName` is a copied string, not the `Step` enum.** Same reasoning as
/// `TaskMissRecord.title`: the record has to survive its source changing.
/// `NightlyReviewView.Step` is reordered and renamed as the review evolves
/// (its own doc comment says reordering it is "this line plus nothing
/// else"), and a stored `rawValue` would silently re-point at a different
/// step the first time that happened.
@Model
final class ForceSkipRecord {
    var id: UUID
    /// The step that was skipped, by its short name — see
    /// `NightlyReviewView.Step.skipLabel`.
    var stepName: String
    var skippedAt: Date

    init(stepName: String, skippedAt: Date = .now) {
        self.id = UUID()
        self.stepName = stepName
        self.skippedAt = skippedAt
    }
}

extension ForceSkipRecord {
    /// **Whether a step's engagement timer is currently bypassed.**
    ///
    /// The whole rule, as a free function over view state — so it is
    /// testable without constructing a timer, which is the thing that
    /// corrupts the heap in a synchronous test (see
    /// `NightlyReviewView`'s warning at the timers' construction site).
    static func isBypassed<S: Hashable>(_ step: S, in skipped: Set<S>) -> Bool {
        skipped.contains(step)
    }

    /// **The one path a force skip takes**, whichever host triggered it.
    ///
    /// Two surfaces can force-skip — Nightly Review's own timer label, and
    /// the Inbox queue sheet's, whose timer gates a button inside the sheet
    /// rather than the review's Next. They are separate hosts because the
    /// controls live in different views; they must not be separate
    /// *implementations*, which is the shape that has drifted repeatedly in
    /// this codebase.
    @discardableResult
    static func record(step: String, in context: ModelContext, at date: Date = .now) -> ForceSkipRecord {
        let record = ForceSkipRecord(stepName: step, skippedAt: date)
        context.insert(record)
        return record
    }

    static func all(in context: ModelContext) -> [ForceSkipRecord] {
        let records = (try? context.fetch(FetchDescriptor<ForceSkipRecord>())) ?? []
        return records.sorted { ($0.skippedAt, $0.id.uuidString) < ($1.skippedAt, $1.id.uuidString) }
    }

    static func count(in context: ModelContext) -> Int {
        (try? context.fetchCount(FetchDescriptor<ForceSkipRecord>())) ?? 0
    }

    /// **The confirmation's wording, built rather than hardcoded per host.**
    ///
    /// On a step whose Next is *also* held by a must-be-marked gate, the
    /// skip bypasses the wait and Next stays disabled anyway. Saying so is
    /// the difference between "this feature is broken" and "this is what I
    /// asked for" — the gates exist so nothing is left unanswered, and the
    /// force skip deliberately does not touch them.
    static func confirmationMessage(stepName: String, alsoBlockedByGate: Bool) -> String {
        let base = "Skip the wait on \(stepName)?"
        guard alsoBlockedByGate else { return base }
        return base + " Next will stay disabled until everything on this step is marked — the force skip bypasses the timer, not the checklist."
    }
}
