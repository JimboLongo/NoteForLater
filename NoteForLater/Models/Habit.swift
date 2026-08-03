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
/// applies to; `timesPerDay` and `reminderTimesOfDay` (one time-of-day per
/// occurrence, in minutes since midnight) drive how many local reminders
/// get scheduled on each applicable day. Each occurrence is tracked
/// individually (complete/missed/excused/untouched) — see HabitLog.
@Model
final class Habit {
    var id: UUID
    var name: String
    var startDate: Date
    var timesPerDay: Int = 1
    /// Calendar weekday numbering: 1 = Sunday ... 7 = Saturday.
    var daysOfWeek: [Int] = [1, 2, 3, 4, 5, 6, 7]
    /// Minutes since midnight, one per occurrence — count should track `timesPerDay`.
    var reminderTimesOfDay: [Int] = [540]
    var sortOrder: Int = 0

    @Relationship(deleteRule: .cascade, inverse: \HabitLog.habit)
    var logs: [HabitLog]? = []

    init(
        name: String,
        startDate: Date = Calendar.current.startOfDay(for: .now),
        timesPerDay: Int = 1,
        daysOfWeek: [Int] = [1, 2, 3, 4, 5, 6, 7],
        reminderTimesOfDay: [Int] = [540],
        sortOrder: Int = 0
    ) {
        self.id = UUID()
        self.name = name
        self.startDate = Calendar.current.startOfDay(for: startDate)
        self.timesPerDay = timesPerDay
        self.daysOfWeek = daysOfWeek
        self.reminderTimesOfDay = reminderTimesOfDay
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
        daysOfWeek.contains(calendar.component(.weekday, from: date))
    }

    func log(on date: Date, calendar: Calendar = .current) -> HabitLog? {
        let day = calendar.startOfDay(for: date)
        return (logs ?? []).first(where: { calendar.isDate($0.date, inSameDayAs: day) })
    }

    func occurrenceStatus(_ index: Int, on date: Date, calendar: Calendar = .current) -> OccurrenceStatus {
        log(on: date, calendar: calendar)?.occurrenceStatus(index) ?? .none
    }

    /// Rolls up a day's per-occurrence statuses into one day-level result:
    /// excused override, full completion, a definite miss, or nil if it's
    /// still pending — today, with no occurrence marked missed yet, and not
    /// every occurrence resolved. Pending days are omitted from streak/%
    /// math until they're resolved or the day ends and becomes a miss.
    func status(on date: Date, asOf referenceDate: Date = .now, calendar: Calendar = .current) -> HabitCompletionStatus? {
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: referenceDate)
        let isToday = day == today
        let n = max(timesPerDay, 1)
        guard let log = log(on: day, calendar: calendar) else {
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

        // A single explicit miss marks the day right away — no point
        // waiting on the rest of the occurrences.
        if missedCount > 0 { return .no }
        if excusedCount == n { return .excused }
        if completeCount + excusedCount == n, completeCount > 0 { return .yes }
        // Some occurrences are still untouched.
        if isToday { return nil }
        return .no
    }

    /// Applicable, countable days from `startDate` through `endDate`
    /// (inclusive), oldest first, with their effective status. Excused days
    /// and pending days are omitted entirely — see `status(on:asOf:)`.
    private func countedDays(through endDate: Date, calendar: Calendar = .current) -> [(date: Date, status: HabitCompletionStatus)] {
        var result: [(Date, HabitCompletionStatus)] = []
        var cursor = calendar.startOfDay(for: startDate)
        let end = calendar.startOfDay(for: endDate)
        guard cursor <= end else { return [] }
        while cursor <= end {
            if isApplicable(on: cursor, calendar: calendar),
               let status = status(on: cursor, asOf: endDate, calendar: calendar),
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
        let days = countedDays(through: referenceDate, calendar: calendar)
        guard let last = days.last else { return 0 }
        var count = 0
        for entry in days.reversed() {
            guard entry.status == last.status else { break }
            count += 1
        }
        return last.status == .yes ? count : -count
    }

    /// Longest-ever hit streak and longest-ever miss streak, independent of
    /// which one is current.
    func longestStreaks(asOf referenceDate: Date = .now, calendar: Calendar = .current) -> (maxYes: Int, maxNo: Int) {
        let days = countedDays(through: referenceDate, calendar: calendar)
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
        return (maxYes, maxNo)
    }

    /// The max streak to show alongside the current one: the longest hit
    /// streak if you're currently on a hit streak, otherwise the longest
    /// miss streak.
    func displayMaxStreak(asOf referenceDate: Date = .now, calendar: Calendar = .current) -> Int {
        let current = currentStreak(asOf: referenceDate, calendar: calendar)
        let (maxYes, maxNo) = longestStreaks(asOf: referenceDate, calendar: calendar)
        return current >= 0 ? maxYes : -maxNo
    }

    /// % of counted days (excused/pending omitted) marked Yes, over [periodStart, periodEnd].
    func percentComplete(from periodStart: Date, through periodEnd: Date, calendar: Calendar = .current) -> Double? {
        var cursor = calendar.startOfDay(for: max(startDate, periodStart))
        let end = calendar.startOfDay(for: periodEnd)
        guard cursor <= end else { return nil }
        var yesCount = 0
        var totalCount = 0
        while cursor <= end {
            if isApplicable(on: cursor, calendar: calendar),
               let status = status(on: cursor, asOf: periodEnd, calendar: calendar),
               status != .excused {
                totalCount += 1
                if status == .yes { yesCount += 1 }
            }
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? end.addingTimeInterval(1)
        }
        guard totalCount > 0 else { return nil }
        return Double(yesCount) / Double(totalCount) * 100
    }

    func mtdPercent(asOf referenceDate: Date = .now, calendar: Calendar = .current) -> Double? {
        let monthStart = calendar.dateInterval(of: .month, for: referenceDate)?.start ?? referenceDate
        return percentComplete(from: monthStart, through: referenceDate, calendar: calendar)
    }

    func ltdPercent(asOf referenceDate: Date = .now, calendar: Calendar = .current) -> Double? {
        percentComplete(from: startDate, through: referenceDate, calendar: calendar)
    }

    var currentStreakDisplay: String { Self.signedText(currentStreak()) }
    var maxStreakDisplay: String { Self.signedText(displayMaxStreak()) }
    var mtdPercentDisplay: String { Self.percentDisplayText(mtdPercent()) }
    var ltdPercentDisplay: String { Self.percentDisplayText(ltdPercent()) }

    private static func signedText(_ value: Int) -> String {
        value > 0 ? "+\(value)" : "\(value)"
    }

    private static func percentDisplayText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))%"
    }
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

    private func setOccurrence(_ index: Int, to status: OccurrenceStatus) {
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

    private func setAll(to status: OccurrenceStatus, timesPerDay: Int) {
        resetAll()
        for index in 0..<max(timesPerDay, 1) {
            setOccurrence(index, to: status)
        }
    }
}
