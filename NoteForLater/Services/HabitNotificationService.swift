import Foundation
import UserNotifications

/// Schedules one-shot local notifications for each applicable-day ×
/// occurrence combination over a short rolling window, instead of one
/// repeating-weekly request per slot — a repeating trigger fires
/// unconditionally every week and can't be told "skip just this Tuesday,"
/// which is exactly what's needed once an occurrence (BrushTeeth.1,
/// BrushTeeth.2, ...) has already been completed early from its calendar
/// block. Re-run (which cancels and rebuilds from scratch) whenever a
/// habit's schedule changes, whenever an occurrence is completed/reset
/// (see `ScheduleReviewViewModel.toggleComplete`), and on a normal
/// foreground refresh (`HabitsView.onAppear`) to keep the window topped up
/// as days roll by.
final class HabitNotificationService {
    static let shared = HabitNotificationService()
    private init() {}

    /// Kept short (not weeks out) so the rebuild-on-every-change design
    /// above stays well under iOS's 64-pending-notification cap even with
    /// several multi-occurrence habits — a foreground refresh well within
    /// this window keeps reminders current for any user who opens the app
    /// at least every few days.
    private let rollingWindowDays = 3

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func reschedule(_ habit: Habit) {
        let center = UNUserNotificationCenter.current()
        let prefix = identifierPrefix(for: habit)
        let calendar = Calendar.current
        let now = Date.now
        let today = calendar.startOfDay(for: now)

        center.getPendingNotificationRequests { requests in
            let staleIDs = requests.map(\.identifier).filter { $0.hasPrefix(prefix) }
            center.removePendingNotificationRequests(withIdentifiers: staleIDs)

            for dayOffset in 0..<self.rollingWindowDays {
                guard let day = calendar.date(byAdding: .day, value: dayOffset, to: today) else { continue }
                guard habit.isApplicable(on: day, calendar: calendar) else { continue }
                let dayKey = calendar.dateComponents([.year, .month, .day], from: day)

                for (index, minutesOfDay) in habit.reminderTimesOfDay.enumerated() {
                    // Already resolved (complete/missed/excused) for this
                    // day — most notably already completed early from its
                    // calendar block — so no reminder is needed.
                    guard habit.occurrenceStatus(index, on: day, calendar: calendar) == .none else { continue }

                    var components = dayKey
                    components.hour = minutesOfDay / 60
                    components.minute = minutesOfDay % 60
                    guard let fireDate = calendar.date(from: components), fireDate > now else { continue }

                    let content = UNMutableNotificationContent()
                    content.title = habit.name.isEmpty ? "Habit reminder" : habit.name
                    content.body = habit.reminderTimesOfDay.count > 1
                        ? "Reminder \(index + 1) of \(habit.reminderTimesOfDay.count)"
                        : "Time for your habit"
                    content.sound = .default

                    let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                    let dateID = "\(dayKey.year ?? 0)-\(dayKey.month ?? 0)-\(dayKey.day ?? 0)"
                    let request = UNNotificationRequest(identifier: "\(prefix).\(dateID).\(index)", content: content, trigger: trigger)
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
