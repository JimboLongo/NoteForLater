import Foundation
import UserNotifications

/// Schedules the "here's what's still open today" local notifications — up
/// to `DailyDigestSettings.slotCount` times a day, each listing every
/// still-incomplete habit occurrence and scheduled task for that day.
/// Replaces the old per-habit and per-block "starting soon" reminders
/// entirely (see their removal) — this is the only local notification left
/// that speaks to habit/task progress, and tapping one opens
/// `DailyDigestCheckInView` (see AppDelegate / DailyDigestLaunchState) to
/// mark things off right there.
///
/// One-shot per day × slot, not a repeating trigger — same reasoning as
/// the old HabitNotificationService: content varies day to day (what's
/// still open), which a repeating trigger can't express. Content is baked
/// in at scheduling time (a local notification can't compute anything at
/// fire time), so it only ever reflects what was still open the last time
/// `reschedule` ran — kept fresh the same way the old per-block reminders
/// were, by rebuilding from scratch on every relevant data change (see
/// ContentView's `.onChange`s) rather than at fire time.
final class DailyDigestNotificationService {
    static let shared = DailyDigestNotificationService()
    static let identifierPrefix = "com.jimbo.NoteForLater.dailyDigest"

    /// Same reasoning as the old HabitNotificationService.rollingWindowDays
    /// — kept short so a full rebuild on every change stays well under
    /// iOS's 64-pending cap (up to `DailyDigestSettings.slotCount` requests
    /// per day in this window).
    private let windowDays = 3

    private init() {}

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Rebuilds every pending digest notification from scratch — call any
    /// time the settings change or the underlying habits/blocks do (see
    /// ContentView's `.onChange`s).
    func reschedule(habits: [Habit], blocks: [ScheduledBlock]) {
        let center = UNUserNotificationCenter.current()
        let prefix = Self.identifierPrefix
        center.getPendingNotificationRequests { requests in
            let staleIDs = requests.map(\.identifier).filter { $0.hasPrefix(prefix) }
            center.removePendingNotificationRequests(withIdentifiers: staleIDs)

            let settings = DailyDigestSettings.shared
            guard settings.isEnabled else { return }

            let calendar = Calendar.current
            let now = Date.now
            let today = calendar.startOfDay(for: now)

            for dayOffset in 0..<self.windowDays {
                guard let day = calendar.date(byAdding: .day, value: dayOffset, to: today) else { continue }
                let dayKey = calendar.dateComponents([.year, .month, .day], from: day)
                let openTitles = self.openItemTitles(for: day, habits: habits, blocks: blocks, calendar: calendar)
                guard !openTitles.isEmpty else { continue }

                for (slotIndex, minutesOfDay) in settings.minutesOfDay.enumerated() {
                    var components = dayKey
                    components.hour = minutesOfDay / 60
                    components.minute = minutesOfDay % 60
                    guard let fireDate = calendar.date(from: components), fireDate > now else { continue }

                    let content = UNMutableNotificationContent()
                    content.title = openTitles.count == 1 ? "1 thing still open today" : "\(openTitles.count) things still open today"
                    // Every item, not just the first few — nothing here
                    // truncates with "...and N more". iOS sizes the
                    // expanded/long-press notification view to fit
                    // whatever's in `body`, so the full list is what
                    // makes everything actually visible there.
                    content.body = openTitles.joined(separator: "\n")
                    content.sound = .default

                    let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                    let dateID = "\(dayKey.year ?? 0)-\(dayKey.month ?? 0)-\(dayKey.day ?? 0)"
                    let request = UNNotificationRequest(identifier: "\(prefix).\(dateID).\(slotIndex)", content: content, trigger: trigger)
                    center.add(request)
                }
            }
        }
    }

    /// Every still-incomplete habit occurrence and scheduled task on `day`,
    /// as display titles — habits first (in `sortOrder`), then tasks by
    /// start time. A habit contributes once per unresolved occurrence
    /// still ahead for the day (not already complete/missed/excused,
    /// whether or not it's even made it onto the calendar yet); a
    /// habit-backed block is skipped here since its habit occurrence
    /// already covers it — only task-backed blocks are named.
    private func openItemTitles(for day: Date, habits: [Habit], blocks: [ScheduledBlock], calendar: Calendar) -> [String] {
        var titles: [String] = []
        for habit in habits.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            guard habit.isApplicable(on: day, calendar: calendar) else { continue }
            for occurrenceIndex in 0..<max(habit.timesPerDay, 1) {
                guard habit.occurrenceStatus(occurrenceIndex, on: day, calendar: calendar) == .none else { continue }
                titles.append(habit.name)
            }
        }
        let dayTasks = blocks
            .filter { $0.task != nil && !$0.isCompleted && calendar.isDate($0.date, inSameDayAs: day) }
            .sorted { $0.startTime < $1.startTime }
        titles.append(contentsOf: dayTasks.map(\.displayTitle))
        return titles
    }
}
