import Foundation
import SwiftData

/// How a rule decides how much to pull into a given window.
enum FillStrategy: String, Codable, CaseIterable, Identifiable {
    /// Pack as many eligible tasks as fit, bounded only by the window itself.
    case fillToFit
    /// Stop once the total scheduled time reaches `maxTotalMinutes`.
    case maxDuration
    /// Pull at most `maxTaskCount` tasks, each capped to `maxMinutesPerTask`.
    case maxTaskCount

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fillToFit: return "Fill to Fit"
        case .maxDuration: return "Max Total Duration"
        case .maxTaskCount: return "Max Task Count"
        }
    }
}

/// One "pull window" for a shelf: which days, what time range, and how much
/// to pull into it. A shelf can have several — e.g. Personal To-Do might
/// have a weekday-evening rule, a weekend rule, and a lunch-break rule, all
/// with different windows and fill strategies. A shelf with no enabled
/// rules is never touched by the AI Scheduler.
@Model
final class SchedulingRule {
    var id: UUID
    var shelf: Shelf?
    var name: String = ""
    var sortOrder: Int = 0
    var isEnabled: Bool = true

    /// Optional reference to a reusable day/time window (see NamedSchedule)
    /// managed from the Schedules tab. When set, it supplies the effective
    /// window below instead of this rule's own `daysOfWeek`/hour fields —
    /// those stay around as the storage for a one-off "Custom" window.
    @Relationship(deleteRule: .nullify) var namedSchedule: NamedSchedule?

    /// Calendar weekday numbering: 1 = Sunday ... 7 = Saturday, matching
    /// `Calendar.component(.weekday, from:)`.
    var daysOfWeek: [Int] = [2, 3, 4, 5, 6]

    var startHour: Int = 9
    var startMinute: Int = 0
    var endHour: Int = 17
    var endMinute: Int = 0

    var fillStrategyRaw: String = FillStrategy.fillToFit.rawValue
    var maxTotalMinutes: Int = 120
    var maxTaskCount: Int = 2
    var maxMinutesPerTask: Int = 15
    /// Max Total Duration's own optional secondary cap — off by default so
    /// an existing rule's behavior doesn't silently change. When on, the
    /// window still stops filling once `maxTotalMinutes` is reached same
    /// as before, but now also stops once `maxTaskCount` tasks have been
    /// placed, whichever comes first — the same `maxTaskCount` field the
    /// Max Task Count strategy uses, just optionally applied here too.
    var maxDurationTaskCountEnabled: Bool = false

    init(
        shelf: Shelf,
        name: String = "",
        daysOfWeek: [Int] = [2, 3, 4, 5, 6],
        startHour: Int = 9,
        startMinute: Int = 0,
        endHour: Int = 17,
        endMinute: Int = 0,
        fillStrategy: FillStrategy = .fillToFit,
        maxTotalMinutes: Int = 120,
        maxTaskCount: Int = 2,
        maxMinutesPerTask: Int = 15,
        maxDurationTaskCountEnabled: Bool = false,
        sortOrder: Int = 0,
        isEnabled: Bool = true
    ) {
        self.id = UUID()
        self.shelf = shelf
        self.name = name
        self.daysOfWeek = daysOfWeek
        self.startHour = startHour
        self.startMinute = startMinute
        self.endHour = endHour
        self.endMinute = endMinute
        self.fillStrategyRaw = fillStrategy.rawValue
        self.maxTotalMinutes = maxTotalMinutes
        self.maxTaskCount = maxTaskCount
        self.maxMinutesPerTask = maxMinutesPerTask
        self.maxDurationTaskCountEnabled = maxDurationTaskCountEnabled
        self.sortOrder = sortOrder
        self.isEnabled = isEnabled
    }

    var fillStrategy: FillStrategy {
        get { FillStrategy(rawValue: fillStrategyRaw) ?? .fillToFit }
        set { fillStrategyRaw = newValue.rawValue }
    }

    /// The window actually used for scheduling: a linked NamedSchedule's
    /// window if there is one, otherwise this rule's own stored fields.
    var effectiveDaysOfWeek: [Int] { namedSchedule?.daysOfWeek ?? daysOfWeek }
    var effectiveStartHour: Int { namedSchedule?.startHour ?? startHour }
    var effectiveStartMinute: Int { namedSchedule?.startMinute ?? startMinute }
    var effectiveEndHour: Int { namedSchedule?.endHour ?? endHour }
    var effectiveEndMinute: Int { namedSchedule?.endMinute ?? endMinute }

    /// This rule's custom name if it has one, otherwise the linked
    /// NamedSchedule's name — used anywhere a single label is needed.
    var displayName: String {
        name.isEmpty ? (namedSchedule?.name ?? "") : name
    }

    /// Whether this rule could ever place something needing `minutesNeeded`
    /// at all, given its divisibility and this rule's fill-strategy cap —
    /// independent of the per-task "Eligible Schedules" checkbox. A
    /// non-divisible item longer than what the rule could ever hand it
    /// (a single-task cap, or the rule's whole budget) can never actually
    /// be pulled by this rule no matter how that checkbox is set. Takes
    /// plain values rather than a TaskItem so it also works for an
    /// unsorted task that hasn't been routed to a shelf yet (see
    /// NightlyReviewView's TaskReviewCard).
    func canEverFit(minutesNeeded: Int, isDivisible: Bool) -> Bool {
        switch fillStrategy {
        case .fillToFit:
            return true
        case .maxDuration:
            return isDivisible || minutesNeeded <= maxTotalMinutes
        case .maxTaskCount:
            return isDivisible || minutesNeeded <= maxMinutesPerTask
        }
    }

    static let dayLabels: [(weekday: Int, short: String)] = [
        (2, "Mon"), (3, "Tue"), (4, "Wed"), (5, "Thu"), (6, "Fri"), (7, "Sat"), (1, "Sun")
    ]

    /// e.g. "Mon–Fri 9:00 AM–5:00 PM · Fill to Fit"
    var summary: String {
        Self.summaryText(
            daysOfWeek: effectiveDaysOfWeek,
            startHour: effectiveStartHour, startMinute: effectiveStartMinute,
            endHour: effectiveEndHour, endMinute: effectiveEndMinute,
            fillStrategy: fillStrategy,
            maxTotalMinutes: maxTotalMinutes,
            maxTaskCount: maxTaskCount,
            maxMinutesPerTask: maxMinutesPerTask,
            maxDurationTaskCountEnabled: maxDurationTaskCountEnabled
        )
    }

    /// Same formatting as `summary`, but callable against a draft that
    /// hasn't been saved to the model yet (see SchedulingRuleEditView).
    static func summaryText(
        daysOfWeek: [Int],
        startHour: Int, startMinute: Int,
        endHour: Int, endMinute: Int,
        fillStrategy: FillStrategy,
        maxTotalMinutes: Int,
        maxTaskCount: Int,
        maxMinutesPerTask: Int,
        maxDurationTaskCountEnabled: Bool = false
    ) -> String {
        let dayTimeText = dayAndTimeText(daysOfWeek: daysOfWeek, startHour: startHour, startMinute: startMinute, endHour: endHour, endMinute: endMinute)

        let strategyText: String
        switch fillStrategy {
        case .fillToFit: strategyText = "Fill to fit"
        case .maxDuration:
            let durationText = "Up to \(TaskItem.durationLabel(for: maxTotalMinutes))"
            strategyText = maxDurationTaskCountEnabled
                ? "\(durationText), ≤\(maxTaskCount) task\(maxTaskCount == 1 ? "" : "s")"
                : durationText
        case .maxTaskCount: strategyText = "Up to \(maxTaskCount) task\(maxTaskCount == 1 ? "" : "s"), ≤\(maxMinutesPerTask) min each"
        }
        return "\(dayTimeText) · \(strategyText)"
    }

    /// "Mon–Fri 9:00 AM–5:00 PM", shared with EligibleHoursWindow.
    static func dayAndTimeText(daysOfWeek: [Int], startHour: Int, startMinute: Int, endHour: Int, endMinute: Int) -> String {
        let days = dayLabels.filter { daysOfWeek.contains($0.weekday) }.map(\.short)
        let dayText = compactDayRanges(days)
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        let calendar = Calendar.current
        let start = calendar.date(bySettingHour: startHour, minute: startMinute, second: 0, of: .now) ?? .now
        let end = calendar.date(bySettingHour: endHour, minute: endMinute, second: 0, of: .now) ?? .now
        let timeText = "\(timeFormatter.string(from: start))–\(timeFormatter.string(from: end))"
        return "\(dayText) \(timeText)"
    }

    static func compactDayRanges(_ shortLabels: [String]) -> String {
        guard !shortLabels.isEmpty else { return "No days" }
        if shortLabels.count == 7 { return "Every day" }
        if shortLabels == ["Mon", "Tue", "Wed", "Thu", "Fri"] { return "Mon–Fri" }
        if shortLabels == ["Sat", "Sun"] { return "Sat–Sun" }
        return shortLabels.joined(separator: ", ")
    }
}
