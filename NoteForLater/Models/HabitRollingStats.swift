import Foundation

/// Rolling 30 / Misses Remaining for the 30-day window ending on some day —
/// pure output, no SwiftData types, so `computeHabitRollingStats` is
/// directly unit-testable. Mirrors `HabitStats`'s role for streak/max
/// streak: the model layer computes this from raw data, the view caches it.
struct HabitRollingStats: Equatable {
    /// Days in the window (habit existed and was scheduled) counted at all.
    let scheduledDays: Int
    let completedDays: Int
    /// completedDays / scheduledDays, or nil if nothing was scheduled in
    /// the window yet (a brand-new, not-yet-applicable habit).
    let rolling30: Double?
    let allowedMisses: Int
    let missesInWindow: Int
    let missesRemaining: Int
    /// The day the oldest miss in the window ages out of it (that miss's
    /// date + 30 days) — nil when there are no misses in the window.
    let recoveryDate: Date?
    /// Whether the habit has existed a full 30 days as of `today` — the
    /// Rolling 30 Record isn't tracked before this (an early perfect week
    /// would otherwise lock in an unrepresentative 100%).
    let isRecordEligible: Bool
    /// 1-based day count since the habit's creation date, capped at 30 —
    /// powers the "Day N of 30" placeholder shown before eligibility.
    let dayOfThirty: Int

    var rolling30Display: String {
        guard let rolling30 else { return "—" }
        return "\(Int((rolling30 * 100).rounded()))% · \(completedDays)/\(scheduledDays)"
    }

    var missesRemainingDisplay: String {
        "\(missesRemaining) miss\(missesRemaining == 1 ? "" : "es") left"
    }
}

/// Computes Rolling 30 / Misses Remaining for the 30 calendar days ending
/// `today`, inclusive.
///   - status: a day's resolved completion status — same semantics as
///     `Habit.status(on:asOf:calendar:logsByDay:)`, including `nil` for a
///     day still pending (today, with at least one occurrence not yet
///     marked complete/missed/excused). Pending and excused days are
///     omitted from `scheduledDays` entirely, same as streak/% math does —
///     an in-progress today never counts against (or for) Rolling 30 until
///     every occurrence is resolved.
///   - schedule: whether the habit is scheduled (applicable) on a given
///     day by its own recurrence pattern alone, e.g. `Habit.isApplicable`.
///     Intersected internally with `creationDate`, so callers don't need
///     to pre-filter by it.
///   - threshold: the fraction of scheduled days that must be completed to
///     stay "on track" (e.g. 0.85) — see `allowedMisses` in the result.
func computeHabitRollingStats(
    status: (Date) -> HabitCompletionStatus?,
    schedule: (Date) -> Bool,
    creationDate: Date,
    today: Date,
    threshold: Double,
    calendar: Calendar = .current
) -> HabitRollingStats {
    let today = calendar.startOfDay(for: today)
    let creationDate = calendar.startOfDay(for: creationDate)

    guard let windowStart = calendar.date(byAdding: .day, value: -29, to: today) else {
        return HabitRollingStats(
            scheduledDays: 0, completedDays: 0, rolling30: nil,
            allowedMisses: 0, missesInWindow: 0, missesRemaining: 0,
            recoveryDate: nil, isRecordEligible: false, dayOfThirty: 1
        )
    }

    var scheduledDays = 0
    var completed = 0
    var missedDates: [Date] = []

    var cursor = windowStart
    while cursor <= today {
        let day = calendar.startOfDay(for: cursor)
        if day >= creationDate, schedule(day), let dayStatus = status(day), dayStatus != .excused {
            scheduledDays += 1
            if dayStatus == .yes {
                completed += 1
            } else {
                missedDates.append(day)
            }
        }
        guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
        cursor = next
    }

    let rolling30: Double? = scheduledDays > 0 ? Double(completed) / Double(scheduledDays) : nil
    let allowedMisses = Int(floor(Double(scheduledDays) * (1 - threshold)))
    let missesInWindow = scheduledDays - completed
    let missesRemaining = max(0, allowedMisses - missesInWindow)
    let recoveryDate = missedDates.first.flatMap { calendar.date(byAdding: .day, value: 30, to: $0) }

    let daysSinceCreation = calendar.dateComponents([.day], from: creationDate, to: today).day ?? 0
    let isRecordEligible = daysSinceCreation >= 29
    let dayOfThirty = min(daysSinceCreation + 1, 30)

    return HabitRollingStats(
        scheduledDays: scheduledDays,
        completedDays: completed,
        rolling30: rolling30,
        allowedMisses: allowedMisses,
        missesInWindow: missesInWindow,
        missesRemaining: missesRemaining,
        recoveryDate: recoveryDate,
        isRecordEligible: isRecordEligible,
        dayOfThirty: dayOfThirty
    )
}

/// A Rolling 30 Record, stored as the raw completed/scheduled counts (not
/// just the fraction) so it can be displayed the same way as the live
/// value — "Record 29/30" — against the window that actually produced it,
/// rather than projecting a percentage onto today's (possibly different)
/// scheduled-day count.
struct HabitRollingRecord: Equatable {
    let completedDays: Int
    let scheduledDays: Int

    var fraction: Double {
        scheduledDays > 0 ? Double(completedDays) / Double(scheduledDays) : 0
    }

    var display: String { "Record \(completedDays)/\(scheduledDays)" }
}

/// The stored Rolling 30 Record only ever moves up — this is that monotonic
/// update in isolation (nil-safe on both sides), so "log a completion, then
/// un-log it" is testable without touching SwiftData: the record computed
/// from the logged state must survive being fed a lower-fraction candidate
/// afterward. A candidate with nothing scheduled never replaces anything.
func nextHabitRolling30Record(current: HabitRollingRecord?, candidate: HabitRollingRecord?) -> HabitRollingRecord? {
    guard let candidate, candidate.scheduledDays > 0 else { return current }
    guard let current else { return candidate }
    return candidate.fraction > current.fraction ? candidate : current
}
