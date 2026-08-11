import Foundation
import UserNotifications

/// Schedules the single daily "time for your Nightly Review" local
/// notification — mirrors HabitNotificationService's
/// authorize/reschedule shape but for one fixed identifier instead of a
/// per-habit prefix. Tapping it is handled in AppDelegate, which sets
/// NightlyReviewLaunchState.shared.pendingReview.
final class NightlyReviewNotificationService {
    static let shared = NightlyReviewNotificationService()
    static let identifier = "com.jimbo.NoteForLater.nightlyReview"

    private init() {}

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func reschedule(isEnabled: Bool, minutesOfDay: Int) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        guard isEnabled else { return }

        var components = DateComponents()
        components.hour = minutesOfDay / 60
        components.minute = minutesOfDay % 60

        let content = UNMutableNotificationContent()
        content.title = "Nightly Review"
        content.body = "Review today, sort your Inbox, and approve tomorrow's plan."
        content.sound = .default

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: Self.identifier, content: content, trigger: trigger)
        center.add(request)
    }
}
