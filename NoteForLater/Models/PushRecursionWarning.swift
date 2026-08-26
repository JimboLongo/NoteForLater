import Foundation
import SwiftData

/// A loud, persisted record of `RippleSchedulingService` giving up on a
/// push — either it hit `RippleSchedulingService.maxDepth` chasing a
/// chain of tasks bumping each other to make room, or a task genuinely
/// has no eligible day left to land on. Both are meant to be rare (the
/// depth cap in particular exists only to stop a mutual-bump cycle
/// between two tasks from looping forever), but when either happens a
/// task silently fails to get placed — the exact "Stirfry recipes never
/// actually lands anywhere" bug this whole mechanism exists to fix. A
/// `DiagFileLog` line alone isn't enough for that: nothing reads the
/// diagnostic file unprompted, so this also needs a row `ScheduleReviewView`
/// can query and show a real banner for, the same way `UnplacedTask`
/// drives the existing "Won't Fit" banner.
///
/// `taskID`/`taskTitle` follow the same "copied, not a relationship"
/// convention `TaskCompletionRecord.taskID`/`RecurringTaskLog.taskID`
/// already use — the title is a snapshot so the banner still reads
/// sensibly even if the task itself is later deleted.
@Model
final class PushRecursionWarning {
    var id: UUID
    var taskID: UUID
    var taskTitle: String
    var message: String
    var createdAt: Date

    init(taskID: UUID, taskTitle: String, message: String, createdAt: Date = .now) {
        self.id = UUID()
        self.taskID = taskID
        self.taskTitle = taskTitle
        self.message = message
        self.createdAt = createdAt
    }
}
