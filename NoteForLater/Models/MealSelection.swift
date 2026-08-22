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
    var isCompleted: Bool = false

    init(recipeID: UUID, recipeTitle: String, date: Date) {
        self.id = UUID()
        self.recipeID = recipeID
        self.recipeTitle = recipeTitle
        self.date = Calendar.current.startOfDay(for: date)
        self.isCompleted = false
    }
}
