import Foundation
import SwiftData

/// A permanent snapshot taken the moment a task is marked complete —
/// deliberately independent of `TaskItem` (no relationship, just a copied
/// `taskID` for lookup) so the Task Stats page keeps this task's
/// contribution even after the task itself is gone. A task still marked
/// complete the next time Night Time Review runs gets purged from the
/// shelf and calendar entirely (see
/// `ScheduleReviewViewModel.purgeCompletedBlocks`) — this record is what
/// survives that.
@Model
final class TaskCompletionRecord {
    var id: UUID
    /// The originating `TaskItem.id` — used only to find/update this same
    /// record if the task is marked complete again (or un-marked, in
    /// which case the record is deleted) rather than piling up
    /// duplicates for one task completed multiple times.
    var taskID: UUID
    var title: String
    var createdAt: Date
    var completedAt: Date
    var pushedCount: Int

    init(taskID: UUID, title: String, createdAt: Date, completedAt: Date, pushedCount: Int) {
        self.id = UUID()
        self.taskID = taskID
        self.title = title
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.pushedCount = pushedCount
    }

    /// How long the task sat around (created -> done). Can be negative in
    /// theory if a task's `createdAt` was somehow edited after the fact;
    /// stats display should clamp to 0 rather than show something silly.
    var completionInterval: TimeInterval {
        completedAt.timeIntervalSince(createdAt)
    }

    /// Creates (or refreshes, if this task's already been completed and
    /// un-completed before) the permanent stats snapshot for this
    /// completion — shared by every "mark complete" entry point (the
    /// calendar's tap-to-complete circle, a task card's Mark Complete
    /// button, Task Attribute Review's) so they all feed the same stats.
    static func upsert(for task: TaskItem, in modelContext: ModelContext) {
        let taskID = task.id
        let existing = try? modelContext.fetch(FetchDescriptor<TaskCompletionRecord>(
            predicate: #Predicate { $0.taskID == taskID }
        )).first
        if let existing {
            existing.completedAt = .now
            existing.pushedCount = task.pushedCount
        } else {
            modelContext.insert(TaskCompletionRecord(
                taskID: task.id,
                title: task.title,
                createdAt: task.createdAt,
                completedAt: .now,
                pushedCount: task.pushedCount
            ))
        }
    }

    /// Un-completing a task rolls its stats contribution back too, rather
    /// than leaving a stale record behind.
    static func remove(for task: TaskItem, in modelContext: ModelContext) {
        let taskID = task.id
        if let existing = try? modelContext.fetch(FetchDescriptor<TaskCompletionRecord>(
            predicate: #Predicate { $0.taskID == taskID }
        )).first {
            modelContext.delete(existing)
        }
    }
}
