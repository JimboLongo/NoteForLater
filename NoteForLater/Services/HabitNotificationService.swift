import Foundation
import UserNotifications

/// Schedules a repeating local notification for every (applicable weekday ×
/// reminder time) combination on a habit — e.g. a 4x/day, Mon–Fri habit
/// gets 20 recurring weekly requests. Re-run whenever a habit's schedule
/// changes so stale reminders get cleared first.
final class HabitNotificationService {
    static let shared = HabitNotificationService()
    private init() {}

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func reschedule(_ habit: Habit) {
        let center = UNUserNotificationCenter.current()
        let prefix = identifierPrefix(for: habit)
        center.getPendingNotificationRequests { requests in
            let staleIDs = requests.map(\.identifier).filter { $0.hasPrefix(prefix) }
            center.removePendingNotificationRequests(withIdentifiers: staleIDs)

            for weekday in habit.daysOfWeek {
                for (index, minutesOfDay) in habit.reminderTimesOfDay.enumerated() {
                    var components = DateComponents()
                    components.weekday = weekday
                    components.hour = minutesOfDay / 60
                    components.minute = minutesOfDay % 60

                    let content = UNMutableNotificationContent()
                    content.title = habit.name.isEmpty ? "Habit reminder" : habit.name
                    content.body = habit.reminderTimesOfDay.count > 1
                        ? "Reminder \(index + 1) of \(habit.reminderTimesOfDay.count)"
                        : "Time for your habit"
                    content.sound = .default

                    let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
                    let request = UNNotificationRequest(identifier: "\(prefix).\(weekday).\(index)", content: content, trigger: trigger)
                    center.add(request)
                }
            }
        }
    }

    func cancelAll(for habit: Habit) {
        let center = UNUserNotificationCenter.current()
        let prefix = identifierPrefix(for: habit)
        center.getPendingNotificationRequests { requests in
            let staleIDs = requests.map(\.identifier).filter { $0.hasPrefix(prefix) }
            center.removePendingNotificationRequests(withIdentifiers: staleIDs)
        }
    }

    private func identifierPrefix(for habit: Habit) -> String {
        "com.jimbo.NoteForLater.habit.\(habit.id.uuidString)"
    }
}
