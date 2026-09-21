import Foundation

/// The pure logic behind Nightly Review's "Which day are you planning?"
/// step (`NightlyReviewView.chooseDayStep`) — pulled out so it's directly
/// unit-testable without constructing a live `NightlyReviewView`, same
/// reasoning as `StepAutoSkip`/`AttributeReviewSession.nextWrapQueue`.
///
/// The mapping this all serves: `reviewDate` keeps its original meaning
/// (the day being closed out) everywhere else in the file — only this
/// step's *labels* changed. "Plan Tomorrow" means `reviewDate` is today;
/// "Plan Today" means `reviewDate` is yesterday (what the "Yesterday"
/// button used to set, under the old "which day are you reviewing?"
/// framing).
enum ChooseDayPlanning {
    enum PlanningChoice {
        case today, tomorrow
    }

    /// Before this hour, the one-time default nudge assumes you're
    /// catching up on a day that already ended and defaults to "Today";
    /// at or after it, assumes the ordinary case (opening this at night
    /// to close today out) and defaults to "Tomorrow". Noon, matching
    /// this app's own existing AM/Midday/PM morning-vs-evening
    /// convention (`HabitOccurrenceTimeMode`) — not tied to backlog
    /// content, since `StepAutoSkip` already makes an empty backlog cost
    /// nothing but a couple of skipped screens either way.
    static let planTodayDefaultCutoffHour = 12

    /// The `reviewDate` a given planning choice sets, evaluated at `now`.
    static func reviewDate(forPlanning choice: PlanningChoice, now: Date, calendar: Calendar) -> Date {
        switch choice {
        case .today:
            let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
            return calendar.startOfDay(for: yesterday)
        case .tomorrow:
            return calendar.startOfDay(for: now)
        }
    }

    /// The day a given choice actually *plans* — `reviewDate` + 1, the same
    /// relationship `NightlyReviewView.planDate` uses. "Plan Today" reviews
    /// yesterday and plans today; "Plan Tomorrow" reviews today and plans
    /// tomorrow.
    static func planDate(forPlanning choice: PlanningChoice, now: Date, calendar: Calendar) -> Date {
        let reviewDate = reviewDate(forPlanning: choice, now: now, calendar: calendar)
        return calendar.date(byAdding: .day, value: 1, to: reviewDate) ?? reviewDate
    }

    /// Which choice the one-time default nudge should apply at `now`.
    static func defaultPlanningChoice(now: Date, calendar: Calendar) -> PlanningChoice {
        calendar.component(.hour, from: now) < planTodayDefaultCutoffHour ? .today : .tomorrow
    }

    /// "Today" or "Tomorrow" — `planDate` (`reviewDate` + 1 day) is
    /// always either real-today or real-tomorrow, so this never needs the
    /// fuller "In N Days" cases another relative-day label in this app
    /// handles.
    static func planRelativeDayLabel(planDate: Date, now: Date, calendar: Calendar) -> String {
        calendar.isDate(planDate, inSameDayAs: calendar.startOfDay(for: now)) ? "Today" : "Tomorrow"
    }

    /// "Sunday, September 13, 2026 (Today)" — the Habits step's own day
    /// section header (`NightlyReviewView.habitsStep`). Long date form
    /// plus a relative suffix, always computed against `now`, never
    /// `reviewDate` — a habit occurrence dated real-today must read
    /// "(Today)" even while planning tomorrow night, not something keyed
    /// off which day is being reviewed.
    ///
    /// Genuinely different output from `ShelfListView.relativeDayLabel`
    /// (a short, parenthetical-only supporting line under a separate date
    /// badge — "(Today)"/"(Tomorrow)"/"(In N Days)"/"(N Days Ago)") rather
    /// than a shared formatter: this is a full section header standing on
    /// its own, with different wording and casing ("N days ago" lowercase
    /// here vs. "N Days Ago" there). The only genuinely common piece is a
    /// one-line day-count calendar computation, not worth threading two
    /// different wording conventions through one shared function for.
    /// `ShelfListView`'s own output is untouched by this.
    ///
    /// Every day `NightlyReviewView.habitsStep` can ever show is bounded
    /// at `reviewDate` itself (`ScheduleReviewViewModel
    /// .allHabitOccurrencesForReview`'s backward scan never reaches
    /// `reviewDate + 1 day` or later), and every path that sets
    /// `reviewDate` (`reviewDate(forPlanning:)`'s two cases, and
    /// `NightlyReviewView.chooseDayStep`'s custom date picker, whose
    /// `planDate` is capped at `startOfDay(now) + 1 day`) keeps it at or
    /// before real today — so a future `day` is not reachable through any
    /// path this app actually offers. Handled explicitly anyway (`"in N
    /// days"`) rather than silently falling through to a nonsensical
    /// negative "N days ago".
    static func habitsStepDayLabel(day: Date, now: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        let dateString = formatter.string(from: day)
        let daysAgo = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: day),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        let relativePart: String
        switch daysAgo {
        case 0: relativePart = "Today"
        case 1: relativePart = "Yesterday"
        case let n where n > 1: relativePart = "\(n) days ago"
        default: relativePart = "in \(-daysAgo) days"
        }
        return "\(dateString) (\(relativePart))"
    }

    /// Always `false` — planning today must always be available;
    /// `hasAnythingToReviewBeforeToday` being `false` just means
    /// `StepAutoSkip` flies through fewer screens, not that this option
    /// should be blocked (disabling it used to read as "you can't plan
    /// today because yesterday was clean," which is backwards). Kept as
    /// an explicit, named, testable decision point — not just an absent
    /// `.disabled` modifier — specifically so a regression that
    /// reintroduces gating on backlog content fails a test instead of
    /// only being caught by eye. The parameter is unused deliberately:
    /// it documents what this is *not* gated on any more, rather than
    /// silently dropping the concept.
    static func isPlanTodayOptionDisabled(hasAnythingToReviewBeforeToday: Bool) -> Bool {
        false
    }

    /// "Fri, Sept 20th (Tomorrow)" — the full date *and* the relative label.
    ///
    /// The buttons used to say only "Today"/"Tomorrow", which is the one
    /// thing you already know. Which actual date that means is the thing
    /// worth showing, and it is the question Choose Day exists to answer —
    /// especially for "Plan Today", which reviews *yesterday*.
    static func planDayButtonLabel(planDate: Date, now: Date, calendar: Calendar) -> String {
        "\(fullDateLabel(planDate, calendar: calendar)) (\(planRelativeDayLabel(planDate: planDate, now: now, calendar: calendar)))"
    }

    /// "Fri, Sept 20th". Ordinal-suffixed day, so it reads the way the date
    /// is said out loud rather than as "Sept 20".
    static func fullDateLabel(_ date: Date, calendar: Calendar) -> String {
        let weekdayMonth = DateFormatter()
        weekdayMonth.calendar = calendar
        weekdayMonth.locale = .autoupdatingCurrent
        weekdayMonth.setLocalizedDateFormatFromTemplate("EEE MMM")
        let day = calendar.component(.day, from: date)
        return "\(weekdayMonth.string(from: date)) \(day)\(ordinalSuffix(for: day))"
    }

    /// 1st / 2nd / 3rd / 4th — with the 11th–13th exception, which is the
    /// part a naive last-digit rule gets wrong.
    static func ordinalSuffix(for day: Int) -> String {
        if (11...13).contains(day % 100) { return "th" }
        switch day % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    /// **Where a miss goes — the one answer, for every surface.**
    ///
    /// `planDate` with the default choice ("the day you would be planning
    /// right now", today before noon and tomorrow after), **floored at the
    /// day after the miss**.
    ///
    /// ⚠️ The floor is the whole point. Without it, marking today's own row
    /// before noon pushes to *today* — the day the row is already on, so
    /// nothing moves and nothing says so. That shipped twice, once for
    /// recurring occurrences and once for 2-Minute tasks, because each
    /// surface derived "the day being planned" for itself.
    ///
    /// **Moved here from `DayTimelineGridView`, and that move is the point.**
    /// It lived on the calendar as `calendarPushDay` while Nightly Review
    /// computed `reviewDate + 1` separately. Those agree for a review of
    /// today and diverge for a back-dated one: reviewing Sept 19 on Sept 21
    /// pushed to Sept 20, already in the past and therefore invisible. One
    /// function called from both surfaces is what makes that unrepresentable
    /// rather than merely fixed once.
    ///
    /// `TwoMinutePush.apply` and `pushRecurringOccurrenceIfNeeded` both
    /// assert on a degenerate pair, so a caller that bypasses this and picks
    /// its own day cannot fail quietly.
    static func pushDay(missedOn missedDay: Date, calendar: Calendar, now: Date = .now) -> Date {
        let planned = planDate(
            forPlanning: defaultPlanningChoice(now: now, calendar: calendar),
            now: now,
            calendar: calendar
        )
        let dayAfterMiss = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: missedDay))
            ?? calendar.startOfDay(for: missedDay)
        return max(calendar.startOfDay(for: planned), dayAfterMiss)
    }
}
