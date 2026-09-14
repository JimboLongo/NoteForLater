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
}
