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
        self.sortOrder = sortOrder
        self.isEnabled = isEnabled
    }

    var fillStrategy: FillStrategy {
        get { FillStrategy(rawValue: fillStrategyRaw) ?? .fillToFit }
        set { fillStrategyRaw = newValue.rawValue }
    }

    static let dayLabels: [(weekday: Int, short: String)] = [
        (2, "Mon"), (3, "Tue"), (4, "Wed"), (5, "Thu"), (6, "Fri"), (7, "Sat"), (1, "Sun")
    ]

    /// e.g. "Mon–Fri 9:00 AM–5:00 PM · Fill to Fit"
    var summary: String {
        let days = Self.dayLabels.filter { daysOfWeek.contains($0.weekday) }.map(\.short)
        let dayText = Self.compactDayRanges(days)
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        let calendar = Calendar.current
        let start = calendar.date(bySettingHour: startHour, minute: startMinute, second: 0, of: .now) ?? .now
        let end = calendar.date(bySettingHour: endHour, minute: endMinute, second: 0, of: .now) ?? .now
        let timeText = "\(timeFormatter.string(from: start))–\(timeFormatter.string(from: end))"

        let strategyText: String
        switch fillStrategy {
        case .fillToFit: strategyText = "Fill to fit"
        case .maxDuration: strategyText = "Up to \(TaskItem.durationLabel(for: maxTotalMinutes))"
        case .maxTaskCount: strategyText = "Up to \(maxTaskCount) task\(maxTaskCount == 1 ? "" : "s"), ≤\(maxMinutesPerTask) min each"
        }
        return "\(dayText) \(timeText) · \(strategyText)"
    }

    private static func compactDayRanges(_ shortLabels: [String]) -> String {
        guard !shortLabels.isEmpty else { return "No days" }
        if shortLabels.count == 7 { return "Every day" }
        if shortLabels == ["Mon", "Tue", "Wed", "Thu", "Fri"] { return "Mon–Fri" }
        if shortLabels == ["Sat", "Sun"] { return "Sat–Sun" }
        return shortLabels.joined(separator: ", ")
    }
}
