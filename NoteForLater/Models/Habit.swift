import Foundation
import SwiftData

enum HabitCompletionStatus: String, Codable {
    case yes
    case no
    case excused
}

/// One occurrence's state within a day, cycled by tapping its circle:
/// none → complete → missed → excused → none.
enum OccurrenceStatus {
    case none
    case complete
    case missed
    case excused

    var next: OccurrenceStatus {
        switch self {
        case .none: return .complete
        case .complete: return .missed
        case .missed: return .excused
        case .excused: return .none
        }
    }
}

/// A recurring habit tracked day by day. `daysOfWeek` says which days it
/// applies to; `timesPerDay` and `idealTimesOfDay` (one time-of-day per
/// occurrence, in minutes since midnight) drive how many occurrences get
/// placed on the calendar on each applicable day, and when. Each
/// occurrence is tracked individually (complete/missed/excused/untouched)
/// — see HabitLog.
@Model
final class Habit {
    var id: UUID
    var name: String
    var startDate: Date
    var timesPerDay: Int = 1
    /// Calendar weekday numbering: 1 = Sunday ... 7 = Saturday.
    var daysOfWeek: [Int] = [1, 2, 3, 4, 5, 6, 7]
    /// No longer independently editable or used for any push notification
    /// (habits don't get their own — see the Daily Check-Ins digest in
    /// Settings instead) — `HabitEditView` keeps this mirrored to
    /// `idealTimesOfDay` on every save purely so it doesn't drift stale,
    /// since `HabitImportService` still reads/writes this same shape.
    var reminderTimesOfDay: [Int] = [540]
    /// Minutes since midnight, one per occurrence (count tracks
    /// `timesPerDay`) — what the AI Scheduler actually tries to place the
    /// habit at, when that occurrence's own `timeMode` is `.specific`.
    var idealTimesOfDay: [Int] = [540]
    /// One `HabitOccurrenceTimeMode` raw value per occurrence (count
    /// tracks `timesPerDay`) — see that type's doc comment. An index past
    /// the end (any habit created before this existed, or a new
    /// occurrence added by bumping `timesPerDay` without yet touching
    /// this) reads as `.specific` via `timeMode(for:)`, so nothing
    /// changes behavior until the user actually picks something else.
    var occurrenceTimeModesRaw: [String] = []

    func timeMode(for occurrenceIndex: Int) -> HabitOccurrenceTimeMode {
        guard occurrenceIndex < occurrenceTimeModesRaw.count else { return .specific }
        return HabitOccurrenceTimeMode(rawValue: occurrenceTimeModesRaw[occurrenceIndex]) ?? .specific
    }
    var sortOrder: Int = 0

    /// How long the AI Scheduler should block off for this habit, in
    /// minutes — mirrors `TaskItem.estimatedMinutes`.
    var estimatedMinutes: Int = 15

    /// The fraction of scheduled days in the trailing 30 that must be
    /// completed to stay "on track" for Misses Remaining — e.g. 0.85 means
    /// at most 15% of scheduled days may be missed. User-editable per habit.
    var missThreshold: Double = 0.85
    /// The highest Rolling 30 completion rate ever reached, once the habit
    /// has existed a full 30 days — see `computeHabitRollingStats` and
    /// `nextHabitRolling30Record`. Stored as the raw completed/scheduled
    /// counts (not just a fraction) so "Record 29/30" reflects the window
    /// that actually produced it. Never regresses; refreshed whenever
    /// HabitDetailView recomputes its cached stats (same trigger as
    /// current/max streak, not on every tap).
    var rolling30RecordCompletedDays: Int?
    var rolling30RecordScheduledDays: Int?

    @Relationship(deleteRule: .cascade, inverse: \HabitLog.habit)
    var logs: [HabitLog]? = []

    @Relationship(deleteRule: .nullify, inverse: \ScheduledBlock.habit)
    var scheduledBlocks: [ScheduledBlock]? = []

    init(
        name: String,
        startDate: Date = Calendar.current.startOfDay(for: .now),
        timesPerDay: Int = 1,
        daysOfWeek: [Int] = [1, 2, 3, 4, 5, 6, 7],
        reminderTimesOfDay: [Int] = [540],
        idealTimesOfDay: [Int]? = nil,
        sortOrder: Int = 0
    ) {
        self.id = UUID()
        self.name = name
        self.startDate = Calendar.current.startOfDay(for: startDate)
        self.timesPerDay = timesPerDay
        self.daysOfWeek = daysOfWeek
        self.reminderTimesOfDay = reminderTimesOfDay
        // Defaults to matching `reminderTimesOfDay` one-for-one when the
        // caller doesn't supply its own — a caller that passes a
        // multi-occurrence `reminderTimesOfDay` without also passing
        // `idealTimesOfDay` would otherwise leave this at the property's
        // single-element default, out of sync with `timesPerDay` (see
        // `HabitEditView`, whose per-occurrence rows are driven by this
        // array's own count).
        self.idealTimesOfDay = idealTimesOfDay ?? reminderTimesOfDay
        self.sortOrder = sortOrder
    }

    var daysSummary: String {
        let labels = SchedulingRule.dayLabels.filter { daysOfWeek.contains($0.weekday) }.map(\.short)
        return SchedulingRule.compactDayRanges(labels)
    }

    var summary: String {
        "\(timesPerDay)x/day · \(daysSummary)"
    }

    func isApplicable(on date: Date, calendar: Calendar = .current) -> Bool {
        calendar.startOfDay(for: date) >= calendar.startOfDay(for: startDate)
            && daysOfWeek.contains(calendar.component(.weekday, from: date))
    }

    static func durationLabel(for minutes: Int) -> String {
        TaskItem.durationLabel(for: minutes)
    }

    var durationLabel: String { Self.durationLabel(for: estimatedMinutes) }

    /// Convenience wrapper around the two stored record fields — see
    /// `rolling30RecordCompletedDays`.
    var rolling30Record: HabitRollingRecord? {
        get {
            guard let completed = rolling30RecordCompletedDays, let scheduled = rolling30RecordScheduledDays else { return nil }
            return HabitRollingRecord(completedDays: completed, scheduledDays: scheduled)
        }
        set {
            rolling30RecordCompletedDays = newValue?.completedDays
            rolling30RecordScheduledDays = newValue?.scheduledDays
        }
    }

    func log(on date: Date, calendar: Calendar = .current) -> HabitLog? {
        let day = calendar.startOfDay(for: date)
        return (logs ?? []).first(where: { calendar.isDate($0.date, inSameDayAs: day) })
    }

    func occurrenceStatus(_ index: Int, on date: Date, calendar: Calendar = .current) -> OccurrenceStatus {
        log(on: date, calendar: calendar)?.occurrenceStatus(index) ?? .none
    }

    /// The next target time still ahead of this habit, used to order the
    /// Today list like a queue of "what's coming up next" rather than a
    /// fixed list. Scans forward from today (up to a week) for the
    /// earliest applicable day that still has an unresolved occurrence —
    /// one nobody has marked complete/missed/excused — and returns that
    /// occurrence's own target time: its real `idealTimesOfDay` slot for
    /// a Specific-Time occurrence, or a fixed stand-in time for an AM
    /// (7am), Midday (noon), or PM (9pm) one — those don't have a real
    /// time of their own (see `HabitOccurrenceTimeMode`), but still need
    /// *something* to sort by here. A day with nothing left unresolved
    /// (today, once every occurrence is settled) rolls forward to the
    /// next applicable day, whose occurrences are all unresolved by
    /// definition. Returns nil only if every applicable day in the window
    /// is already fully resolved.
    func nextTargetDate(asOf referenceDate: Date = .now, calendar: Calendar = .current) -> Date? {
        guard timesPerDay > 0 else { return nil }
        var cursor = calendar.startOfDay(for: referenceDate)
        for _ in 0..<7 {
            if isApplicable(on: cursor, calendar: calendar) {
                let dayLog = log(on: cursor, calendar: calendar)
                for index in 0..<max(timesPerDay, 1) {
                    let status = dayLog?.occurrenceStatus(index) ?? .none
                    guard status == .none else { continue }
                    let minutes: Int
                    switch timeMode(for: index) {
                    case .am: minutes = 7 * 60
                    case .midday: minutes = 12 * 60
                    case .pm: minutes = 21 * 60
                    case .specific: minutes = index < idealTimesOfDay.count ? idealTimesOfDay[index] : (idealTimesOfDay.last ?? 0)
                    }
                    return calendar.date(byAdding: .minute, value: minutes, to: cursor)
                }
            }
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor
        }
        return nil
    }

    /// Every log keyed by its (start-of-day) date, built once so a full
    /// history walk (streaks, %, the calendar grid) does a single O(logs)
    /// pass instead of re-scanning the whole `logs` array once per day —
    /// that per-day-linear-scan was the main cost behind a laggy calendar
    /// on habits with much history. Pass `from:` with a `@Query`-fetched
    /// array when you have one (e.g. from the view) — SwiftData serves that
    /// from its own managed fetch/cache path, which is faster in practice
    /// than walking the `logs` relationship array on the model directly.
    func logsByDay(from providedLogs: [HabitLog]? = nil, calendar: Calendar = .current) -> [Date: HabitLog] {
        var result: [Date: HabitLog] = [:]
        for log in providedLogs ?? (logs ?? []) {
            result[calendar.startOfDay(for: log.date)] = log
        }
        return result
    }

    /// Rolls up a day's per-occurrence statuses into one day-level result:
    /// excused override, full completion, or a miss — except for today,
    /// which stays `nil` (pending) until every occurrence has been marked
    /// something (complete, missed, or excused — anything but untouched).
    /// Streaks and Rolling 30 only credit or debit a day once it's actually
    /// done; a same-day miss still counts once the *rest* of today's
    /// occurrences are also resolved, it just doesn't jump the gun while
    /// some are still untouched.
    func status(on date: Date, asOf referenceDate: Date = .now, calendar: Calendar = .current) -> HabitCompletionStatus? {
        status(on: date, asOf: referenceDate, calendar: calendar, logsByDay: logsByDay(calendar: calendar))
    }

    /// Same, but against a `logsByDay` you've already built — use this when
    /// checking many days at once (e.g. rendering a whole month's calendar
    /// grid) so the log list isn't re-scanned per day.
    func status(on date: Date, asOf referenceDate: Date = .now, calendar: Calendar = .current, logsByDay: [Date: HabitLog]) -> HabitCompletionStatus? {
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: referenceDate)
        let isToday = day == today
        let n = max(timesPerDay, 1)
        guard let log = logsByDay[day] else {
            return isToday ? nil : .no
        }

        var completeCount = 0, missedCount = 0, excusedCount = 0
        for index in 0..<n {
            switch log.occurrenceStatus(index) {
            case .complete: completeCount += 1
            case .missed: missedCount += 1
            case .excused: excusedCount += 1
            case .none: break
            }
        }

        // Today stays pending until every occurrence has been marked
        // something — a same-day miss doesn't resolve the day on its own
        // while others are still untouched.
        if isToday, completeCount + missedCount + excusedCount < n {
            return nil
        }

        if excusedCount == n { return .excused }
        if completeCount + excusedCount == n, completeCount > 0 { return .yes }
        return .no
    }

    /// Applicable, countable days from `startDate` through `endDate`
    /// (inclusive), oldest first, with their effective status. Excused days
    /// and pending days are omitted entirely — see `status(on:asOf:)`.
    private func countedDays(through endDate: Date, calendar: Calendar, logsByDay: [Date: HabitLog]) -> [(date: Date, status: HabitCompletionStatus)] {
        var result: [(Date, HabitCompletionStatus)] = []
        var cursor = calendar.startOfDay(for: startDate)
        let end = calendar.startOfDay(for: endDate)
        guard cursor <= end else { return [] }
        while cursor <= end {
            if isApplicable(on: cursor, calendar: calendar),
               let status = status(on: cursor, asOf: endDate, calendar: calendar, logsByDay: logsByDay),
               status != .excused {
                result.append((cursor, status))
            }
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? end.addingTimeInterval(1)
        }
        return result
    }

    /// Positive if the most recent counted day was a hit (and how many in a
    /// row), negative if it was a miss, 0 if there's nothing counted yet.
    func currentStreak(asOf referenceDate: Date = .now, calendar: Calendar = .current) -> Int {
        stats(asOf: referenceDate, calendar: calendar).currentStreak
    }

    /// The max streak to show alongside the current one: the longest hit
    /// streak if you're currently on a hit streak, otherwise the longest
    /// miss streak.
    func displayMaxStreak(asOf referenceDate: Date = .now, calendar: Calendar = .current) -> Int {
        stats(asOf: referenceDate, calendar: calendar).maxStreak
    }

    func mtdPercent(asOf referenceDate: Date = .now, calendar: Calendar = .current) -> Double? {
        stats(asOf: referenceDate, calendar: calendar).mtdPercent
    }

    func ltdPercent(asOf referenceDate: Date = .now, calendar: Calendar = .current) -> Double? {
        stats(asOf: referenceDate, calendar: calendar).ltdPercent
    }

    /// Current streak, max streak, MTD %, and LTD % computed together from
    /// a single shared history walk (one `logsByDay` build, one pass over
    /// applicable days) — call this instead of the individual accessors
    /// when you need more than one of them, which used to mean repeating
    /// the whole history walk once per metric. Pass `logs:` with a
    /// `@Query`-fetched array when you have one — see `logsByDay(from:)`.
    func stats(asOf referenceDate: Date = .now, calendar: Calendar = .current, logs providedLogs: [HabitLog]? = nil) -> HabitStats {
        let logsByDay = logsByDay(from: providedLogs, calendar: calendar)
        let days = countedDays(through: referenceDate, calendar: calendar, logsByDay: logsByDay)

        var current = 0
        if let last = days.last {
            var count = 0
            for entry in days.reversed() {
                guard entry.status == last.status else { break }
                count += 1
            }
            current = last.status == .yes ? count : -count
        }

        var maxYes = 0, maxNo = 0
        var runStatus: HabitCompletionStatus?
        var runLength = 0
        for entry in days {
            if entry.status == runStatus {
                runLength += 1
            } else {
                runStatus = entry.status
                runLength = 1
            }
            if runStatus == .yes {
                maxYes = max(maxYes, runLength)
            } else {
                maxNo = max(maxNo, runLength)
            }
        }
        let maxStreak = current >= 0 ? maxYes : -maxNo

        let monthStart = calendar.dateInterval(of: .month, for: referenceDate)?.start ?? referenceDate
        let mtd = percentComplete(from: monthStart, through: referenceDate, calendar: calendar, logsByDay: logsByDay)
        let ltd = percentComplete(from: startDate, through: referenceDate, calendar: calendar, logsByDay: logsByDay)

        return HabitStats(currentStreak: current, maxStreak: maxStreak, mtdPercent: mtd, ltdPercent: ltd)
    }

    /// % of counted days (excused/pending omitted) marked Yes, over [periodStart, periodEnd].
    private func percentComplete(from periodStart: Date, through periodEnd: Date, calendar: Calendar, logsByDay: [Date: HabitLog]) -> Double? {
        var cursor = calendar.startOfDay(for: max(startDate, periodStart))
        let end = calendar.startOfDay(for: periodEnd)
        guard cursor <= end else { return nil }
        var yesCount = 0
        var totalCount = 0
        while cursor <= end {
            if isApplicable(on: cursor, calendar: calendar),
               let status = status(on: cursor, asOf: periodEnd, calendar: calendar, logsByDay: logsByDay),
               status != .excused {
                totalCount += 1
                if status == .yes { yesCount += 1 }
            }
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? end.addingTimeInterval(1)
        }
        guard totalCount > 0 else { return nil }
        return Double(yesCount) / Double(totalCount) * 100
    }

    static func signedText(_ value: Int) -> String {
        value > 0 ? "+\(value)" : "\(value)"
    }

    static func percentDisplayText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))%"
    }
}

/// Current streak, max streak, MTD %, and LTD % bundled together — see
/// `Habit.stats(asOf:calendar:)`.
struct HabitStats {
    let currentStreak: Int
    let maxStreak: Int
    let mtdPercent: Double?
    let ltdPercent: Double?

    var currentStreakDisplay: String { Habit.signedText(currentStreak) }
    var maxStreakDisplay: String { Habit.signedText(maxStreak) }
    var mtdPercentDisplay: String { Habit.percentDisplayText(mtdPercent) }
    var ltdPercentDisplay: String { Habit.percentDisplayText(ltdPercent) }
}

/// One day's outcome for a habit, tracked per occurrence: each index
/// 0..<timesPerDay is in at most one of `completedOccurrences`,
/// `missedOccurrences`, or `excusedOccurrences` — absence from all three
/// means it's untouched. Tapping an occurrence's circle cycles it through
/// none → complete → missed → excused → none (see `cycleOccurrence`); the
/// day-level status shown elsewhere is rolled up from these by `Habit.status`.
@Model
final class HabitLog {
    var id: UUID
    var habit: Habit?
    var date: Date
    var completedOccurrences: [Int] = []
    var missedOccurrences: [Int] = []
    var excusedOccurrences: [Int] = []

    init(habit: Habit, date: Date) {
        self.id = UUID()
        self.habit = habit
        self.date = Calendar.current.startOfDay(for: date)
    }

    func occurrenceStatus(_ index: Int) -> OccurrenceStatus {
        if completedOccurrences.contains(index) { return .complete }
        if missedOccurrences.contains(index) { return .missed }
        if excusedOccurrences.contains(index) { return .excused }
        return .none
    }

    func cycleOccurrence(_ index: Int) {
        setOccurrence(index, to: occurrenceStatus(index).next)
    }

    func setOccurrence(_ index: Int, to status: OccurrenceStatus) {
        completedOccurrences.removeAll { $0 == index }
        missedOccurrences.removeAll { $0 == index }
        excusedOccurrences.removeAll { $0 == index }
        switch status {
        case .none: break
        case .complete: completedOccurrences.append(index)
        case .missed: missedOccurrences.append(index)
        case .excused: excusedOccurrences.append(index)
        }
    }

    /// Bulk day-level actions (from the calendar's Yes/No/Excused picker,
    /// or the Today page's overflow menu) — set every occurrence at once.
    func markAllComplete(timesPerDay: Int) {
        setAll(to: .complete, timesPerDay: timesPerDay)
    }

    func markAllMissed(timesPerDay: Int) {
        setAll(to: .missed, timesPerDay: timesPerDay)
    }

    func markAllExcused(timesPerDay: Int) {
        setAll(to: .excused, timesPerDay: timesPerDay)
    }

    func resetAll() {
        completedOccurrences = []
        missedOccurrences = []
        excusedOccurrences = []
    }

    /// Sets all three occurrence arrays in exactly one write each — not via
    /// `resetAll()` followed by a per-index loop, which used to fire many
    /// more intermediate (and visibly inconsistent) states than necessary
    /// for a single bulk action.
    func setAll(to status: OccurrenceStatus, timesPerDay: Int) {
        let full = Array(0..<max(timesPerDay, 1))
        completedOccurrences = status == .complete ? full : []
        missedOccurrences = status == .missed ? full : []
        excusedOccurrences = status == .excused ? full : []
    }
}
