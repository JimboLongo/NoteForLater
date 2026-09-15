import Foundation
import SwiftData

/// A recipe picked for a specific day during Nightly Review's Meals step —
/// deliberately standalone, not a `TaskItem`/`ScheduledBlock`. A `TaskItem`
/// would need `shelf == nil` (Inbox) or a real shelf, and both leak into
/// systems that assume that means something else entirely (`InboxView`'s
/// own query, `NightlyReviewView.startAttributeReviewSession`) — this
/// avoids that class of bug by never being a task in the first place.
///
/// `recipeID` is a copied `Recipe.id`, not a `@Relationship` — same
/// "survive the original being edited or deleted" pattern
/// `TaskCompletionRecord.taskID` already uses. `recipeTitle` is a snapshot
/// of `Recipe.title` at selection time, kept alongside the ID because
/// `ScheduledBlock.displayTitle` is a plain computed property with no
/// `ModelContext` to resolve `recipeID` through — the snapshot is what
/// lets the calendar show a name without a lookup. `PantryDeductionService`
/// still resolves the live `Recipe` by `recipeID` for the actual
/// ingredients list, since that has a `ModelContext` in reach and wants
/// current data, not a frozen ingredients snapshot.
@Model
final class MealSelection {
    var id: UUID
    var recipeID: UUID
    var recipeTitle: String
    /// The day this meal is *for* — created a day ahead, during the Meals
    /// step, for `planDate` (tomorrow relative to whichever day is being
    /// reviewed).
    var date: Date
    /// See `TaskItem.legacyIsCompleted`'s doc comment — identical
    /// reasoning and mechanism, applied here so a historically-completed
    /// meal doesn't silently read back as never-completed once
    /// `statusRaw` takes over. Read once by `NoteForLaterApp
    /// .migrateIncompleteBlocksAndMealsToThreeStateIfNeeded`, which also
    /// backfills `hasDeductedPantry` for anything this seeds as
    /// `.complete` — that pantry deduction already happened for real,
    /// under the old code, before either of these properties existed.
    @Attribute(originalName: "isCompleted")
    var legacyIsCompleted: Bool = false
    /// See `TaskItem.hasMigratedThreeState`'s doc comment — identical
    /// reasoning and mechanism, applied here so a second migration
    /// invocation skips an already-migrated meal instead of re-deriving
    /// (and potentially reclassifying) its `status`.
    var hasMigratedThreeState: Bool = false
    /// Backing storage for `status` — see `OccurrenceStatus`'s own doc
    /// comment. Defaults to `.none`'s raw value so a pre-migration row
    /// (no `statusRaw` column at all yet) reads as untouched until
    /// `migrateIncompleteBlocksAndMealsToThreeStateIfNeeded` seeds it from
    /// `legacyIsCompleted` — matching the old `isCompleted: Bool`'s own
    /// default of `false` in the meantime.
    var statusRaw: String = OccurrenceStatus.none.rawValue
    /// This meal's three-state completion — the source of truth;
    /// `ScheduledBlock.status` on its paired block is only ever a mirror
    /// of this (see that property's own doc comment). Never writes
    /// `.excused` — see `OccurrenceStatus.cycledExcludingExcused`.
    var status: OccurrenceStatus {
        get { OccurrenceStatus(rawValue: statusRaw) ?? .none }
        set { statusRaw = newValue.rawValue }
    }
    /// `statusRaw` is the only real storage — see `TaskItem.isCompleted`'s
    /// own doc comment for the full reasoning (identical here): stays
    /// fully settable so every existing call site keeps compiling
    /// unchanged, and setting `false` always lands on `.none`, never
    /// preserves `.missed`.
    var isCompleted: Bool {
        get { status == .complete }
        set { status = newValue ? .complete : .none }
    }
    /// Set the first (and only ever) time `status` transitions into
    /// `.complete` — checked *instead of* the current status before
    /// deducting from the pantry, so cycling Complete → Missed → Complete
    /// deducts exactly once, not twice. Never cleared back to `false`:
    /// there's no restock on leaving `.complete` (the deduction math
    /// clamps ingredient quantities at zero and isn't cleanly
    /// reversible), so once real pantry state has been adjusted for this
    /// meal, it stays adjusted regardless of how the meal's own status
    /// keeps cycling afterward.
    var hasDeductedPantry: Bool = false

    init(recipeID: UUID, recipeTitle: String, date: Date) {
        self.id = UUID()
        self.recipeID = recipeID
        self.recipeTitle = recipeTitle
        self.date = Calendar.current.startOfDay(for: date)
        self.statusRaw = OccurrenceStatus.none.rawValue
        self.hasDeductedPantry = false
    }
}
