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
