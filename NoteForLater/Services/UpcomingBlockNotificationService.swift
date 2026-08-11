import Foundation
import UserNotifications

/// Schedules a "starting soon" local notification for every approved
/// scheduled block (task or habit alike), firing
/// `UpcomingReminderSettings.shared.leadMinutes` before its start time.
/// Rebuilt from scratch (cancel everything with this prefix, then re-add)
/// any time the block list or the lead-time setting changes — see
/// ContentView's `.onChange(of: allBlocks)` and `.onChange` of the settings
/// object — so it never drifts from what's actually on the calendar.
/// Independent of `HabitNotificationService`: that one reminds at a habit's
/// own fixed daily reminder time regardless of whether it ever made it
/// onto the calendar; this one is purely "the thing on your calendar is
/// about to start," for tasks and habits alike.
final class UpcomingBlockNotificationService {
    static let shared = UpcomingBlockNotificationService()
    private let prefix = "com.jimbo.NoteForLater.upcomingBlock"

    /// Same reasoning as `HabitNotificationService.rollingWindowDays` — a
    /// full rebuild on every change stays well under iOS's 64-pending cap
    /// only if the window it draws from is kept short, not weeks out.
    private let windowDays = 3

    private init() {}

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func reschedule(blocks: [ScheduledBlock]) {
        let center = UNUserNotificationCenter.current()
        let prefix = self.prefix
        center.getPendingNotificationRequests { requests in
            let staleIDs = requests.map(\.identifier).filter { $0.hasPrefix(prefix) }
            center.removePendingNotificationRequests(withIdentifiers: staleIDs)

            let settings = UpcomingReminderSettings.shared
            guard settings.isEnabled else { return }

            let calendar = Calendar.current
            let now = Date.now
            let horizon = calendar.date(byAdding: .day, value: self.windowDays, to: now) ?? now
            let leadInterval = TimeInterval(settings.leadMinutes * 60)

            for block in blocks {
                guard block.approvalStatus == .approved, !block.isCompleted else { continue }
                guard block.startTime > now, block.startTime < horizon else { continue }
                let fireDate = block.startTime.addingTimeInterval(-leadInterval)
                guard fireDate > now else { continue }

                let content = UNMutableNotificationContent()
                content.title = block.displayTitle
                content.body = "Starting in \(UpcomingReminderSettings.leadLabel(for: settings.leadMinutes))"
                content.sound = .default

                let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireDate)
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                let request = UNNotificationRequest(identifier: "\(prefix).\(block.id.uuidString)", content: content, trigger: trigger)
                center.add(request)
            }
        }
    }
}
