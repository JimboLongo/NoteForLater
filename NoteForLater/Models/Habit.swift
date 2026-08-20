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

    /// ⚠️ `logs` is an **unordered** to-many relationship —
    /// `@Relationship` promises nothing about read-back order, so this
    /// scans from the end as an *empirical bet*, not because any ordering
    /// is guaranteed. Measured on device across 9 habits (up to 53 logs
    /// each): today's log landed 0–3 positions from the end every time,
    /// including index 50–52 of 53. Forward iteration walked the whole
    /// history to find the same entry. If that clustering ever stops
    /// holding, this quietly degrades to a full scan — it stays correct
    /// either way, it just stops being fast.
    ///
    /// ⚠️ `.first` vs `.last` is **not** a no-op in the presence of
    /// duplicates, and duplicates are real: same-day `HabitLog`s exist in
    /// live data today (see the Open Decisions entry in
    /// `docs/NoteForLater-Scheduling-Spec.md`). Nothing enforces
    /// one-per-day. `.last` is chosen deliberately — the most recently
    /// appended log for a day is the one most recently written to, so a
    /// duplicated day reads its newest state rather than a stale earlier
    /// row. That is damage control, not a fix.
    /// The single entry point for "get this habit's log for this day,
    /// creating it if absent" — every write path routes through here.
    ///
    /// **Why this cannot use `log(on:)`.** A `HabitLog` that has been
    /// `insert`ed but not yet saved is *not* reflected in the `logs`
    /// inverse relationship. Measured on device: across bursts of 4, 6 and
    /// 18 taps, `habit.logs` reported **zero** same-day logs before every
    /// single create while a day-scoped fetch reported the true climbing
    /// count (0,1,2,3…). So a relationship-based lookup misses its own
    /// pending insert and creates another log, every tap, until something
    /// saves. That is what produced same-day duplicates across 9 of 11
    /// habits. The relationship is correct again the moment a save lands —
    /// this is a visibility gap, not data loss.
    ///
    /// Fetching sees pending inserts, so the fetch below is the fix. No
    /// save-before-lookup is needed (and was deliberately avoided: it
    /// would put a synchronous save on the tap path).
    func logOrCreate(on date: Date, context: ModelContext, calendar: Calendar = .current, site: String = "unknown") -> HabitLog {
        let day = calendar.startOfDay(for: date)
        let sameDay = Self.sameDayLogs(habitID: id, day: day, context: context, calendar: calendar)
        // If duplicates already exist, prefer the most recently written —
        // `lastModified` exists precisely so this is deterministic instead
        // of depending on unordered relationship position.
        if let existing = sameDay.max(by: { $0.lastModified < $1.lastModified }) {
            return existing
        }
        let before = sameDay.count
        let newLog = HabitLog(habit: self, date: day)
        context.insert(newLog)
        HabitLogDiag.created(site: site, habit: self, day: day, context: context, log: newLog, sameDayBefore: before, calendar: calendar)
        return newLog
    }

    /// Every `HabitLog` this habit has for `day`, found by **fetch** rather
    /// than by traversing `logs` — see `logOrCreate` for why that
    /// distinction is load-bearing.
    ///
    /// `#Predicate` cannot express `Calendar.isDate(_:inSameDayAs:)`, so
    /// the day is bounded as a half-open range `[startOfDay, nextDay)`.
    /// The bounds are captured as plain `let`s first because the predicate
    /// macro can only capture simple values, and the habit is matched in
    /// memory afterwards rather than inside the predicate, since
    /// traversing an optional relationship inside `#Predicate` is exactly
    /// the fragile construct this method exists to avoid.
    static func sameDayLogs(habitID: UUID, day: Date, context: ModelContext, calendar: Calendar = .current) -> [HabitLog] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        let descriptor = FetchDescriptor<HabitLog>(predicate: #Predicate { $0.date >= start && $0.date < end })
        let fetched = (try? context.fetch(descriptor)) ?? []
        return fetched.filter { $0.habit?.id == habitID }
    }

    /// The **safe** read: sees pending, unsaved inserts because it fetches
    /// rather than traversing `logs`.
    ///
    /// ⚠️ Any read that feeds a *write decision* must use this, not
    /// `log(on:)`. This is not a display concern.
    /// `DayTimelineGridView.toggleHabitOccurrence` derives its toggle
    /// **direction** from the occurrence's current status — so a read that
    /// can't see today's pending log reports `.none`, and every tap writes
    /// `.complete` again. Measured: six taps on one occurrence left it
    /// complete when three on/off cycles should have left it not-complete,
    /// and on a day with no saved log it was impossible to un-toggle at
    /// all. A wrong read here corrupts data; it does not merely look stale.
    func log(on date: Date, context: ModelContext, calendar: Calendar = .current) -> HabitLog? {
        let day = calendar.startOfDay(for: date)
        return Self.sameDayLogs(habitID: id, day: day, context: context, calendar: calendar)
            .max(by: { $0.lastModified < $1.lastModified })
    }

    /// Same, for one occurrence's status.
    func occurrenceStatus(_ index: Int, on date: Date, context: ModelContext, calendar: Calendar = .current) -> OccurrenceStatus {
        log(on: date, context: context, calendar: calendar)?.occurrenceStatus(index) ?? .none
    }

    /// ⚠️ **Hazard — cannot see pending inserts.** Traverses the `logs`
    /// inverse relationship, which does not reflect an inserted-but-unsaved
    /// `HabitLog` until a save lands. Use `log(on:context:)` for anything
    /// feeding a write decision; see that method for what goes wrong.
    /// Retained only for callers with no `ModelContext` in reach, and those
    /// should be treated as suspect rather than as legitimate exceptions.
    func log(on date: Date, calendar: Calendar = .current) -> HabitLog? {
        let day = calendar.startOfDay(for: date)
        // TEMP: reverted to `.first` for the (a)-vs-(b) disambiguation run
        // — does a tap go invisible again when the read lands on an empty
        // first row? Restore `.last` (committed state, see df7d494) once
        // that question is answered.
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
/// TEMP instrumentation — duplicate-`HabitLog` investigation. Every one of
/// the six `HabitLog(habit:date:)` construction sites calls this right
/// after inserting, so a pulled log says *which* site created a duplicate
/// and *which* `ModelContext` it was inserted into. The context identity
/// is the point: an object inserted in one context isn't visible through
/// another context's object graph until save-and-merge, which would
/// produce same-day duplicates with no race and no user present. Strip
/// with the rest of the instrumentation.
enum HabitLogDiag {
    static func contextTag(_ context: ModelContext) -> String {
        String(UInt(bitPattern: ObjectIdentifier(context).hashValue) & 0xFFFFFF, radix: 16, uppercase: true)
    }

    static func created(
        site: String,
        habit: Habit,
        day: Date,
        context: ModelContext,
        log: HabitLog,
        sameDayBefore: Int,
        calendar: Calendar = .current
    ) {
        let after = (habit.logs ?? []).filter { calendar.isDate($0.date, inSameDayAs: day) }.count
        let dayLabel = ISO8601DateFormatter().string(from: calendar.startOfDay(for: day)).prefix(10)
        DiagFileLog.write("CREATE site=\(site) ctx=\(contextTag(context)) habit=\(habit.name) day=\(dayLabel) sameDayBefore=\(sameDayBefore) after=\(after) logID=\(log.id.uuidString.prefix(8))")
    }

    /// Same-day count immediately *before* a create, captured by each site
    /// so `created` can report the delta rather than only the result.
    static func sameDayCount(habit: Habit, day: Date, calendar: Calendar = .current) -> Int {
        (habit.logs ?? []).filter { calendar.isDate($0.date, inSameDayAs: day) }.count
    }

    /// Three independent views of the same question — "how many HabitLogs
    /// exist for this habit on this day" — asked three different ways, to
    /// separate *invisible* from *discarded*:
    ///
    /// - `rel`   — via the `habit.logs` inverse relationship (what
    ///             `log(on:)` actually uses).
    /// - `fetch` — via a `FetchDescriptor<HabitLog>` scoped to the day,
    ///             bypassing the relationship entirely.
    /// - `pend`  — how many `HabitLog`s the context currently holds as
    ///             pending inserts.
    ///
    /// fetch sees them but rel doesn't  -> pure visibility bug; the funnel
    ///                                     just needs to fetch, and every
    ///                                     insert is safe.
    /// only pend sees them              -> pending, and something is
    ///                                     preventing the save.
    /// none see them                    -> inserts are being discarded,
    ///                                     which is far more serious and
    ///                                     limits what a repair can
    ///                                     recover.
    static func probe(
        tag: String,
        habit: Habit,
        day: Date,
        context: ModelContext,
        calendar: Calendar = .current
    ) -> String {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        let rel = (habit.logs ?? []).filter { calendar.isDate($0.date, inSameDayAs: start) }.count
        // Relationship predicates are fragile here, so fetch the day and
        // filter by habit identity in memory — the point is only to avoid
        // traversing `habit.logs`.
        let descriptor = FetchDescriptor<HabitLog>(predicate: #Predicate { $0.date >= start && $0.date < end })
        let fetched = (try? context.fetch(descriptor)) ?? []
        let habitID = habit.id
        let fetchCount = fetched.filter { $0.habit?.id == habitID }.count
        let pending = context.insertedModelsArray.compactMap { $0 as? HabitLog }
            .filter { calendar.isDate($0.date, inSameDayAs: start) && $0.habit?.id == habitID }
            .count
        return "\(tag)[rel=\(rel) fetch=\(fetchCount) pend=\(pending) fetchAnyHabit=\(fetched.count)]"
    }
}

@Model
final class HabitLog {
    var id: UUID
    var habit: Habit?
    var date: Date
    var completedOccurrences: [Int] = []
    var missedOccurrences: [Int] = []
    var excusedOccurrences: [Int] = []
    /// When this log's occurrence state was last written. Added because
    /// reconciling duplicate same-day logs was impossible without it —
    /// there was no way to answer "which of these two writes was newer",
    /// and `logs` is unordered so position says nothing either.
    ///
    /// Defaults to `.distantPast` rather than `.now` so rows that predate
    /// this field are *honestly* marked as unknown-age instead of all
    /// claiming to have been written at migration time. The repair
    /// migration therefore cannot use it — it runs on data written before
    /// this existed — but every reconciliation after that can.
    var lastModified: Date = Date.distantPast

    init(habit: Habit, date: Date) {
        self.id = UUID()
        self.habit = habit
        self.date = Calendar.current.startOfDay(for: date)
        self.lastModified = Date()
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
        lastModified = Date()
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
        lastModified = Date()
    }
}

/// The one merge rule for reconciling `HabitLog`s that share a day, used by
/// both the repair migration and `HabitDetailView`'s live dedup so the two
/// can never disagree.
///
/// **Rule: `complete > excused > missed > none`, per occurrence index.**
/// A completion is essentially always a deliberate tap, so losing one is
/// the worse error. `.missed` ranks lowest of the three because
/// `markUnresolvedHabitOccurrencesAsMissed()` writes it *automatically* at
/// Nightly Review, making it the weakest evidence of intent.
///
/// **This deliberately changes shipped behavior.** `deduplicateLogs`
/// previously unioned all three arrays, which resolved as
/// `complete > missed > excused` via `occurrenceStatus`'s check order —
/// and, worse, left an index in two arrays at once, violating this type's
/// own "at most one of the three" contract. That reads correctly through
/// `occurrenceStatus` while silently double-counting in any code touching
/// `missedOccurrences` directly (streak and rolling-30 math). The
/// divergence from the old ordering is intentional, not a regression.
enum HabitLogMerge {
    /// Raw-array reads rather than `occurrenceStatus`, deliberately: a log
    /// already corrupted by the old union can hold an index in two arrays,
    /// and `occurrenceStatus` would report only the first match, hiding
    /// the other status from the merge.
    static func resolvedStatus(for index: Int, across logs: [HabitLog]) -> OccurrenceStatus {
        var hasComplete = false
        var hasExcused = false
        var hasMissed = false
        for log in logs {
            if log.completedOccurrences.contains(index) { hasComplete = true }
            if log.excusedOccurrences.contains(index) { hasExcused = true }
            if log.missedOccurrences.contains(index) { hasMissed = true }
        }
        if hasComplete { return .complete }
        if hasExcused { return .excused }
        if hasMissed { return .missed }
        return .none
    }

    /// Collapses same-day `logs` into one, deleting the rest, and rewrites
    /// the survivor's three arrays as strictly mutually exclusive.
    ///
    /// Safe — and useful — on a single log: it normalises an existing
    /// invariant violation without deleting anything, which is why the
    /// migration can run this over every log rather than only duplicated
    /// days.
    @discardableResult
    static func collapse(_ logs: [HabitLog], context: ModelContext) -> HabitLog? {
        guard let keeper = logs.max(by: { $0.lastModified < $1.lastModified }) ?? logs.first else { return nil }
        // Every index mentioned anywhere, not `0..<timesPerDay` — a habit
        // whose `timesPerDay` was reduced can still carry higher indices,
        // and silently dropping them would discard real completions.
        let indices = Set(logs.flatMap { $0.completedOccurrences + $0.missedOccurrences + $0.excusedOccurrences })
        var completed: [Int] = []
        var missed: [Int] = []
        var excused: [Int] = []
        for index in indices.sorted() {
            switch resolvedStatus(for: index, across: logs) {
            case .complete: completed.append(index)
            case .excused: excused.append(index)
            case .missed: missed.append(index)
            case .none: break
            }
        }
        keeper.completedOccurrences = completed
        keeper.missedOccurrences = missed
        keeper.excusedOccurrences = excused
        for log in logs where log !== keeper {
            context.delete(log)
        }
        return keeper
    }
}
