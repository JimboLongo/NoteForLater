import XCTest
@testable import NoteForLater

final class HabitRollingStatsTests: XCTestCase {
    /// A fixed Gregorian calendar in a DST-observing zone, so tests are
    /// reproducible regardless of the machine running them and the DST
    /// test actually exercises a real spring-forward transition.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth))!
    }

    private func daily(_ date: Date) -> Bool { true }

    /// Mon/Wed/Fri only.
    private func mwf(_ date: Date) -> Bool {
        [2, 4, 6].contains(calendar.component(.weekday, from: date))
    }

    /// Adapts a plain completed-days set into the `status:` closure
    /// `computeHabitRollingStats` now takes — every non-member day is a
    /// miss, never pending or excused, matching what these tests actually
    /// exercise (pending/excused are covered at the `Habit.status` layer).
    private func status(from completed: Set<Date>) -> (Date) -> HabitCompletionStatus? {
        { day in completed.contains(day) ? .yes : .no }
    }

    // MARK: - Brand-new habit (< 30 days)

    func testBrandNewHabitIsNotRecordEligibleAndWindowIsClippedToCreation() {
        let created = day(2026, 3, 1)
        let today = day(2026, 3, 12) // 12 calendar days old -> "Day 12 of 30"

        let stats = computeHabitRollingStats(
            status: status(from: []),
            schedule: daily,
            creationDate: created,
            today: today,
            threshold: 0.85,
            calendar: calendar
        )

        XCTAssertFalse(stats.isRecordEligible)
        XCTAssertEqual(stats.dayOfThirty, 12)
        // Only the 12 days since creation (inclusive) count as scheduled,
        // not the full 30-day window.
        XCTAssertEqual(stats.scheduledDays, 12)
    }

    // MARK: - Zero completions

    func testZeroCompletionsGivesZeroRolling30AndNoRecoveryDateOmittedOnlyWhenNoMisses() {
        let created = day(2026, 1, 1)
        let today = day(2026, 3, 1) // well past 30 days, daily habit

        let stats = computeHabitRollingStats(
            status: status(from: []),
            schedule: daily,
            creationDate: created,
            today: today,
            threshold: 0.85,
            calendar: calendar
        )

        XCTAssertEqual(stats.scheduledDays, 30)
        XCTAssertEqual(stats.completedDays, 0)
        XCTAssertEqual(stats.rolling30, 0.0)
        XCTAssertEqual(stats.missesInWindow, 30)
        XCTAssertEqual(stats.missesRemaining, 0)
        XCTAssertNotNil(stats.recoveryDate)
    }

    // MARK: - Perfect 30/30

    func testPerfectWindowGivesFullRolling30AndNoRecoveryDate() {
        let created = day(2026, 1, 1)
        let today = day(2026, 3, 1)
        let windowStart = calendar.date(byAdding: .day, value: -29, to: today)!

        var completed: Set<Date> = []
        var cursor = windowStart
        while cursor <= today {
            completed.insert(calendar.startOfDay(for: cursor))
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }

        let stats = computeHabitRollingStats(
            status: status(from: completed),
            schedule: daily,
            creationDate: created,
            today: today,
            threshold: 0.85,
            calendar: calendar
        )

        XCTAssertEqual(stats.scheduledDays, 30)
        XCTAssertEqual(stats.completedDays, 30)
        XCTAssertEqual(stats.rolling30, 1.0)
        XCTAssertEqual(stats.missesInWindow, 0)
        XCTAssertNil(stats.recoveryDate)
        // allowedMisses = floor(30 * 0.15) = 4, all of it unused.
        XCTAssertEqual(stats.allowedMisses, 4)
        XCTAssertEqual(stats.missesRemaining, 4)
    }

    // MARK: - Non-daily schedule

    func testNonDailyScheduleOnlyCountsApplicableDays() {
        let created = day(2025, 1, 1) // long-lived habit, way past 30 days
        let today = day(2026, 3, 1)

        let stats = computeHabitRollingStats(
            status: status(from: []),
            schedule: mwf,
            creationDate: created,
            today: today,
            threshold: 0.85,
            calendar: calendar
        )

        // A 30-calendar-day window contains 12-13 Mon/Wed/Fri occurrences.
        XCTAssertTrue((12...13).contains(stats.scheduledDays), "expected ~13 MWF days, got \(stats.scheduledDays)")
        XCTAssertEqual(stats.completedDays, 0)
    }

    // MARK: - Exact boundary where remaining hits 0

    func testMissesRemainingHitsExactlyZeroAtTheBoundary() {
        let created = day(2026, 1, 1)
        let today = day(2026, 3, 1)
        let windowStart = calendar.date(byAdding: .day, value: -29, to: today)!

        // threshold 0.85 over 30 scheduled days -> allowedMisses = floor(30*0.15) = 4.
        // Complete every day except exactly 4 -> missesInWindow == allowedMisses -> remaining == 0.
        var completed: Set<Date> = []
        var cursor = windowStart
        var missesLeftToPlant = 4
        while cursor <= today {
            let d = calendar.startOfDay(for: cursor)
            if missesLeftToPlant > 0 {
                missesLeftToPlant -= 1
            } else {
                completed.insert(d)
            }
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }

        let stats = computeHabitRollingStats(
            status: status(from: completed),
            schedule: daily,
            creationDate: created,
            today: today,
            threshold: 0.85,
            calendar: calendar
        )

        XCTAssertEqual(stats.allowedMisses, 4)
        XCTAssertEqual(stats.missesInWindow, 4)
        XCTAssertEqual(stats.missesRemaining, 0)

        // One more miss must not go negative.
        completed.remove(completed.first!)
        let oneMoreMiss = computeHabitRollingStats(
            status: status(from: completed),
            schedule: daily,
            creationDate: created,
            today: today,
            threshold: 0.85,
            calendar: calendar
        )
        XCTAssertEqual(oneMoreMiss.missesRemaining, 0)
    }

    // MARK: - Record must not regress

    func testRecordDoesNotRegressWhenACompletionIsLoggedThenUnlogged() {
        let strongRecord = HabitRollingRecord(completedDays: 29, scheduledDays: 30)
        let afterLogging = nextHabitRolling30Record(current: nil, candidate: strongRecord)
        XCTAssertEqual(afterLogging, strongRecord)

        // Un-logging a completion drops today's window to a weaker fraction...
        let weakerAfterUnlog = HabitRollingRecord(completedDays: 28, scheduledDays: 30)
        let stillRecord = nextHabitRolling30Record(current: afterLogging, candidate: weakerAfterUnlog)

        // ...but the stored record must still reflect the earlier, stronger value.
        XCTAssertEqual(stillRecord, strongRecord)
    }

    func testRecordUpdatesWhenCandidateStrictlyBeats() {
        let weak = HabitRollingRecord(completedDays: 20, scheduledDays: 30)
        let strong = HabitRollingRecord(completedDays: 27, scheduledDays: 30)
        XCTAssertEqual(nextHabitRolling30Record(current: weak, candidate: strong), strong)
    }

    func testRecordIgnoresCandidateWithNothingScheduled() {
        let existing = HabitRollingRecord(completedDays: 10, scheduledDays: 20)
        let emptyCandidate = HabitRollingRecord(completedDays: 0, scheduledDays: 0)
        XCTAssertEqual(nextHabitRolling30Record(current: existing, candidate: emptyCandidate), existing)
    }

    // MARK: - DST transition

    func testWindowSpanningDSTSpringForwardCountsExactlyThirtyCalendarDays() {
        // US spring-forward in 2026 is Sunday, March 8th. A window ending
        // March 12 spans it. If day boundaries were derived by adding
        // 86400 seconds instead of using Calendar, this would silently
        // land on the wrong day around the transition.
        let created = day(2025, 1, 1)
        let today = day(2026, 3, 12)
        let windowStart = calendar.date(byAdding: .day, value: -29, to: today)!
        XCTAssertEqual(calendar.component(.day, from: windowStart), 11)
        XCTAssertEqual(calendar.component(.month, from: windowStart), 2)

        let stats = computeHabitRollingStats(
            status: status(from: []),
            schedule: daily,
            creationDate: created,
            today: today,
            threshold: 0.85,
            calendar: calendar
        )

        // Exactly 30 calendar days counted, DST jump notwithstanding.
        XCTAssertEqual(stats.scheduledDays, 30)
    }

    func testDayOfThirtyAndEligibilityBoundary() {
        let created = day(2026, 1, 1)

        let day29 = computeHabitRollingStats(
            status: status(from: []), schedule: daily, creationDate: created,
            today: day(2026, 1, 29), threshold: 0.85, calendar: calendar
        )
        XCTAssertEqual(day29.dayOfThirty, 29)
        XCTAssertFalse(day29.isRecordEligible)

        let day30 = computeHabitRollingStats(
            status: status(from: []), schedule: daily, creationDate: created,
            today: day(2026, 1, 30), threshold: 0.85, calendar: calendar
        )
        XCTAssertEqual(day30.dayOfThirty, 30)
        XCTAssertTrue(day30.isRecordEligible)
    }
}
