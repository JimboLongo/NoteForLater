import Foundation
import SwiftData

/// A single time block on the proposed (or approved) daily schedule.
/// Generated nightly by AISchedulingService for the following day, then
/// reviewed/edited by the user in ScheduleReviewView before it's "live".
@Model
final class ScheduledBlock {
    var id: UUID
    var date: Date          // calendar day this block belongs to
    var startTime: Date
    var endTime: Date
    var approvalStatusRaw: String

    var task: TaskItem?

    init(date: Date, startTime: Date, endTime: Date, task: TaskItem?, approvalStatus: ApprovalStatus = .proposed) {
        self.id = UUID()
        self.date = date
        self.startTime = startTime
        self.endTime = endTime
        self.task = task
        self.approvalStatusRaw = approvalStatus.rawValue
    }

    var approvalStatus: ApprovalStatus {
        get { ApprovalStatus(rawValue: approvalStatusRaw) ?? .proposed }
        set { approvalStatusRaw = newValue.rawValue }
    }

    var durationMinutes: Int {
        Int(endTime.timeIntervalSince(startTime) / 60)
    }
}
