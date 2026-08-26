import Foundation
import SwiftData

/// Guarantees a task actually lands on the calendar when it's pushed
/// forward, rather than being freed up and hoping a future walk finds it
/// room — the "Stirfry recipes never actually gets scheduled" bug this
/// exists to fix. Shared by two callers that otherwise have nothing in
/// common: `ScheduleReviewViewModel.guaranteePlacement` (an ordinary
/// task marked incomplete in Nightly Review, called from a live view
/// with a `blocks` cache to keep in sync) and `NoteForLaterApp
/// .relocatePlaceholderBlock` (a recurring task's app-launch catch-up
/// walk, called from `init()` before any view exists at all). Neither
/// side can depend on the other's context, so the actual algorithm lives
/// here as plain `ModelContext` operations with no view-model state —
/// each caller re-syncs its own cache afterward if it has one.
enum RippleSchedulingService {
    /// How many times a bump can cascade (one task displacing another,
    /// which displaces a third, ...) before giving up. Exists purely to
    /// stop two tasks that keep landing on each other's slot from
    /// bouncing back and forth forever — normal use should never come
    /// close to this. See `PushRecursionWarning` for what happens when
    /// it's actually hit.
    static let maxDepth = 10

    /// Places `block` — already positioned at the day/time its caller
    /// wants — making room for it without ever moving a **fixed
    /// obstacle**: a locked block, a habit block (regardless of lock —
    /// habits have no "push to another day" concept in this app at all),
    /// or an already-completed one. Everything else on that day ripples
    /// forward to close the gap, same idea `ScheduleReviewViewModel
    /// .moveEntry` already uses for a manual drag, but bounded to this
    /// one calendar day and aware of the same obstacles rather than
    /// assuming a clear path. A ripple that would push something past
    /// midnight doesn't overflow into tomorrow unannounced — that entry
    /// is bumped to *its own* next eligible day instead
    /// (`pushToNextEligibleDay`), freeing the slot outright.
    static func insertWithRipple(_ block: ScheduledBlock, context: ModelContext, depth: Int = 0) {
        guard depth < maxDepth else {
            recordGiveUp(for: block.task, context: context, reason: "Couldn't find room — too many tasks kept bumping each other to make space.")
            return
        }
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: block.date)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) else { return }

        let allBlocks = (try? context.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        let others = allBlocks.filter { calendar.isDate($0.date, inSameDayAs: day) && $0.id != block.id }
        let obstacles = others
            .filter { $0.isLocked || $0.habit != nil || $0.isCompleted }
            .sorted { $0.startTime < $1.startTime }

        // The incoming block must not land on top of a fixed obstacle —
        // route it to just after whichever one it overlaps instead.
        for obstacle in obstacles where block.startTime < obstacle.endTime && obstacle.startTime < block.endTime {
            let duration = block.endTime.timeIntervalSince(block.startTime)
            block.startTime = obstacle.endTime
            block.endTime = obstacle.endTime.addingTimeInterval(duration)
        }

        let movable = others
            .filter { !$0.isLocked && $0.habit == nil && !$0.isCompleted }
            .sorted { $0.startTime < $1.startTime }
        var cursor = block.endTime
        for other in movable {
            guard other.startTime < cursor else {
                cursor = max(cursor, other.endTime)
                continue
            }
            let duration = other.endTime.timeIntervalSince(other.startTime)
            var newStart = cursor
            if let blocking = obstacles.first(where: { newStart < $0.endTime && $0.startTime < newStart.addingTimeInterval(duration) }) {
                newStart = blocking.endTime
            }
            let newEnd = newStart.addingTimeInterval(duration)
            if newEnd > dayEnd {
                // No room left today — the slot this frees up is what
                // lets the rest of the ripple (and the original incoming
                // block) actually fit.
                pushToNextEligibleDay(other, context: context, depth: depth + 1)
                continue
            }
            if other.startTime != newStart {
                other.startTime = newStart
                other.endTime = newEnd
                if other.approvalStatus == .approved { other.approvalStatus = .proposed }
            }
            cursor = newEnd
        }
    }

    /// Moves `block` to the same time-of-day on its task's own next
    /// eligible day — literally tomorrow for a recurring task (matching
    /// `NoteForLaterApp.advanceOneDay`'s own one-day-at-a-time walk), or
    /// the next day `TaskItem.nextEligibleDay` reports for an ordinary
    /// one — then routes it back through `insertWithRipple` so it
    /// actually finds room there too, rather than just relocating on top
    /// of whatever's already on that day. A block with no task at all
    /// (shouldn't happen — the `movable` filter above only ever selects
    /// task-backed blocks) or an already-completed task is left alone.
    private static func pushToNextEligibleDay(_ block: ScheduledBlock, context: ModelContext, depth: Int) {
        guard let task = block.task, !task.isCompleted else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: block.date)
        let nextDay = task.isRecurring
            ? calendar.date(byAdding: .day, value: 1, to: today)
            : task.nextEligibleDay(after: today, calendar: calendar)
        guard let nextDay else {
            recordGiveUp(for: task, context: context, reason: "No eligible day left to push it to within the search window.")
            return
        }
        let timeOfDay = calendar.dateComponents([.hour, .minute], from: block.startTime)
        guard let newStart = calendar.date(bySettingHour: timeOfDay.hour ?? 9, minute: timeOfDay.minute ?? 0, second: 0, of: nextDay) else { return }
        let duration = block.endTime.timeIntervalSince(block.startTime)
        block.date = nextDay
        block.startTime = newStart
        block.endTime = newStart.addingTimeInterval(duration)
        if block.approvalStatus == .approved { block.approvalStatus = .proposed }
        insertWithRipple(block, context: context, depth: depth)
    }

    /// The loud half of giving up — a `DiagFileLog` line alone isn't
    /// enough here, since nothing reads that file unprompted and a task
    /// silently failing to land anywhere is exactly the bug this service
    /// exists to fix. `PushRecursionWarning` is what `ScheduleReviewView`
    /// queries to show a real banner for it. Saved immediately rather
    /// than left for the caller's own later save — if something else in
    /// the same transaction throws afterward, the warning about *why*
    /// still needs to survive.
    private static func recordGiveUp(for task: TaskItem?, context: ModelContext, reason: String) {
        guard let task else { return }
        DiagFileLog.write("RIPPLE GAVE UP taskID=\(task.id) title=\(task.title) reason=\(reason)")
        context.insert(PushRecursionWarning(taskID: task.id, taskTitle: task.title, message: reason))
        try? context.save()
    }
}
