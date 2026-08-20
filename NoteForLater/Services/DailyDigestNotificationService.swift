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
    /// Debounces `reschedule` — this rebuild is real cross-process work
    /// (a `UNUserNotificationCenter` round-trip, O(habits × `windowDays`)
    /// on top of that) triggered by ContentView's `.onChange(of: allHabits)`
    /// /`.onChange(of: allBlocks)`, which fires on *every* habit/task
    /// completion anywhere in the app, calendar included. Undebounced,
    /// each additional habit tapped in a row queued up its own overlapping
    /// rebuild competing with whichever were still in flight — which is
    /// what actually made the second and third tap feel progressively
    /// slower than the first, even though this has nothing to do with
    /// rendering the checkmark itself. Cancelling and restarting a
    /// 3-second delay on every call means only the last call in a rapid
    /// burst ever actually runs, once things have gone quiet.
    private var rescheduleTask: Task<Void, Never>?

    private init() {}

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Everything `applyPlan` needs, as plain `Sendable` values — built
    /// once, on the MainActor (see `buildPlan`, the only place that
    /// touches live `Habit`/`ScheduledBlock` objects, which are confined
    /// to that context), so the actual notification-center round-trips
    /// below can run off it without smuggling a SwiftData model across an
    /// isolation boundary.
    private struct DigestPlan: Sendable {
        /// One still-open habit occurrence or task, plus when it was
        /// actually scheduled for — what lets each slot filter down to
        /// just what's overdue *as of that slot's own fire time*, instead
        /// of every open item for the whole day regardless of a 10am
        /// reminder listing something not due until 6pm.
        struct DigestItem: Sendable {
            let title: String
            let minutesOfDay: Int
        }
        struct DayPlan: Sendable {
            let dayKey: DateComponents
            let items: [DigestItem]
        }
        let identifierPrefix: String
        let isEnabled: Bool
        let minutesOfDay: [Int]
        let now: Date
        let days: [DayPlan]
    }

    /// Rebuilds every pending digest notification from scratch — call any
    /// time the settings change or the underlying habits/blocks do (see
    /// ContentView's `.onChange`s). Debounced 3 seconds (see
    /// `rescheduleTask`), and even once it fires, the actual
    /// `UNUserNotificationCenter` round-trips run off the MainActor (see
    /// `applyPlan`) — between the two, a rapid burst of habit/task
    /// completions on the calendar no longer has this competing with it
    /// for the main thread at all, which is what was making a couple of
    /// quick taps in a row feel like it froze.
    func reschedule(habits: [Habit], blocks: [ScheduledBlock]) {
        rescheduleTask?.cancel()
        rescheduleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self else { return }
            let plan = self.buildPlan(habits: habits, blocks: blocks)
            guard !Task.isCancelled else { return }
            await Self.applyPlan(plan)
        }
    }

    private func buildPlan(habits: [Habit], blocks: [ScheduledBlock]) -> DigestPlan {
        let settings = DailyDigestSettings.shared
        let calendar = Calendar.current
        let now = Date.now
        let today = calendar.startOfDay(for: now)
        var days: [DigestPlan.DayPlan] = []
        for dayOffset in 0..<windowDays {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: today) else { continue }
            let dayKey = calendar.dateComponents([.year, .month, .day], from: day)
            let items = openItems(for: day, habits: habits, blocks: blocks, calendar: calendar)
            days.append(DigestPlan.DayPlan(dayKey: dayKey, items: items))
        }
        return DigestPlan(
            identifierPrefix: Self.identifierPrefix,
            isEnabled: settings.isEnabled,
            minutesOfDay: settings.minutesOfDay,
            now: now,
            days: days
        )
    }

    /// The actual `UNUserNotificationCenter` work — deliberately
    /// `nonisolated` (and only ever fed plain `Sendable` data via
    /// `DigestPlan`) so it runs off the MainActor entirely, freeing it up
    /// for UI work for however long these cross-process round-trips take.
    nonisolated private static func applyPlan(_ plan: DigestPlan) async {
        let center = UNUserNotificationCenter.current()
        let prefix = plan.identifierPrefix
        let requests = await center.pendingNotificationRequests()
        let staleIDs = requests.map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: staleIDs)
        guard plan.isEnabled else { return }

        for dayPlan in plan.days {
            guard !dayPlan.items.isEmpty else { continue }

            for (slotIndex, minutesOfDay) in plan.minutesOfDay.enumerated() {
                var components = dayPlan.dayKey
                components.hour = minutesOfDay / 60
                components.minute = minutesOfDay % 60
                guard let fireDate = Calendar.current.date(from: components), fireDate > plan.now else { continue }

                // Only what was actually scheduled for *before* this
                // slot's own fire time — a 10am reminder never lists
                // something not due until 2pm, even though a later slot
                // that same day would.
                let dueTitles = dayPlan.items.filter { $0.minutesOfDay < minutesOfDay }.map(\.title)
                guard !dueTitles.isEmpty else { continue }

                let content = UNMutableNotificationContent()
                content.title = dueTitles.count == 1 ? "1 thing still open" : "\(dueTitles.count) things still open"
                // Every item, not just the first few — nothing here
                // truncates with "...and N more". iOS sizes the
                // expanded/long-press notification view to fit
                // whatever's in `body`, so the full list is what
                // makes everything actually visible there.
                content.body = dueTitles.joined(separator: "\n")
                content.sound = .default

                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                let dateID = "\(dayPlan.dayKey.year ?? 0)-\(dayPlan.dayKey.month ?? 0)-\(dayPlan.dayKey.day ?? 0)"
                let request = UNNotificationRequest(identifier: "\(prefix).\(dateID).\(slotIndex)", content: content, trigger: trigger)
                try? await center.add(request)
            }
        }
    }

    /// Stand-in minutes-since-midnight for an AM/Midday/PM occurrence —
    /// matches `ScheduleReviewViewModel.targetMinutes`/
    /// `openHabitOccurrencesForReview`'s own stand-ins (those don't have a
    /// real time of their own — see `HabitOccurrenceTimeMode`), so a habit
    /// reads as "due" at the same point across the calendar's own review
    /// flows and this digest.
    private func targetMinutes(for habit: Habit, occurrenceIndex: Int) -> Int {
        switch habit.timeMode(for: occurrenceIndex) {
        case .am: return 6 * 60
        case .midday: return 12 * 60
        case .pm: return 21 * 60
        case .specific:
            return occurrenceIndex < habit.idealTimesOfDay.count
                ? habit.idealTimesOfDay[occurrenceIndex]
                : (habit.idealTimesOfDay.last ?? 0)
        }
    }

    /// Every still-incomplete habit occurrence and scheduled task on `day`,
    /// each paired with its own scheduled minute-of-day so a given
    /// reminder slot can filter down to just what's due by *its* fire
    /// time (see `applyPlan`) — habits first (in `sortOrder`), then tasks
    /// by start time. A habit contributes once per unresolved occurrence
    /// still ahead for the day (not already complete/missed/excused,
    /// whether or not it's even made it onto the calendar yet); a
    /// habit-backed block is skipped here since its habit occurrence
    /// already covers it — only task-backed blocks are named.
    ///
    /// `Habit.log(on:)` linearly scans that habit's entire log history —
    /// looked up once per habit here (not once per occurrence index via
    /// `occurrenceStatus(_:on:calendar:)`, which does the same lookup
    /// internally), same fix as `DayTimelineGridView.openHabitOccurrences`
    /// for the same reason.
    private func openItems(for day: Date, habits: [Habit], blocks: [ScheduledBlock], calendar: Calendar) -> [DigestPlan.DigestItem] {
        var items: [DigestPlan.DigestItem] = []
        for habit in habits.sorted(by: { $0.sortOrder < $1.sortOrder }) where habit.isApplicable(on: day, calendar: calendar) {
            let log = habit.logIgnoringPendingInserts(on: day, calendar: calendar)
            for occurrenceIndex in 0..<max(habit.timesPerDay, 1) {
                let status = log?.occurrenceStatus(occurrenceIndex) ?? .none
                guard status == .none else { continue }
                items.append(DigestPlan.DigestItem(title: habit.name, minutesOfDay: targetMinutes(for: habit, occurrenceIndex: occurrenceIndex)))
            }
        }
        let dayTasks = blocks
            .filter { $0.task != nil && !$0.isCompleted && calendar.isDate($0.date, inSameDayAs: day) }
            .sorted { $0.startTime < $1.startTime }
        for block in dayTasks {
            let minutes = calendar.component(.hour, from: block.startTime) * 60 + calendar.component(.minute, from: block.startTime)
            items.append(DigestPlan.DigestItem(title: block.displayTitle, minutesOfDay: minutes))
        }
        return items
    }
}
