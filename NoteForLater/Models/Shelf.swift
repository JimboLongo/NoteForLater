import Foundation
import SwiftData
import SwiftUI
import UIKit

/// A user-defined bucket that sorted tasks live in (e.g. "To-Do List",
/// "Stuff to Buy"). Unlike the old fixed four-pen setup, shelves are fully
/// user-configurable from the Shelves screen: name, icon, color, and a
/// list of SchedulingRules describing when/how the AI Scheduler should
/// pull tasks from this shelf onto the calendar. A shelf with no enabled
/// rules is never touched by the scheduler — rules ARE the eligibility
/// mechanism, there's no separate flag.
@Model
final class Shelf {
    var id: UUID
    var name: String
    var systemImage: String
    var sortOrder: Int
    var colorName: String = "Terracotta"
    /// Whether tasks on this shelf are duration-tracked at all — off hides
    /// the Duration/Divisible sections on the TaskCard entirely and forces
    /// both to empty; e.g. a Reference shelf full of links has no real
    /// "how long will this take."
    var tracksDuration: Bool = true
    /// Stamped onto a task landing on this shelf (routed from Inbox, moved
    /// here, or added directly) only if it doesn't already have a duration
    /// of its own — see `resolvedDuration`. `0` means no default is set,
    /// same "unset" sentinel `estimatedMinutes` itself uses. Only surfaced
    /// in Settings when `tracksDuration` is on; meaningless otherwise.
    var defaultDurationMinutes: Int = 0
    /// Whether tasks on this shelf are due-date-tracked at all — off hides
    /// the Due Date section on the TaskCard and forces it to empty; e.g. a
    /// Reference shelf of links to read "eventually" has no real deadline.
    var hasDueDates: Bool = true
    /// Whether tasks on this shelf track a Next Step at all — off fades the
    /// Next Step field on the TaskCard and it's no longer required for the
    /// task to count as complete; e.g. a Reference shelf of links has no
    /// actionable next step.
    var hasNextStep: Bool = true
    /// Whether tasks on this shelf track Priority at all — off fades the
    /// Priority section on the TaskCard and it's no longer required for the
    /// task to count as complete.
    var hasPriority: Bool = true
    /// Whether tasks on this shelf can be given a "Remind Me In" — off
    /// hides that question on the TaskCard entirely. On, a task here (or
    /// sent here) can pick a count + `RecurrenceUnit` (Days/Weeks/Months)
    /// that reappears it in the Nightly Review / Inbox attribute-review
    /// queue once that much time has passed — see
    /// `TaskItem.applyRemindIn`/`isDueForFutureReminder`, which reuse the
    /// same "hidden until a date" mechanism the existing Snooze action
    /// already provides.
    var tracksFutureReminder: Bool = false
    /// Marks this as *the* Kitchen shelf (Pantry + Cookbook), created/
    /// removed by the "Meal Planning" toggle in Settings — a flag rather
    /// than matching on name so a rename doesn't silently break its
    /// special handling (excluded from Inbox routing; the one shelf a
    /// receipt scan can import into; routed to `KitchenView` instead of
    /// the plain `ShelfListView`).
    // Renamed from `isPantry` when the Kitchen shelf grew a Cookbook pane
    // alongside Pantry — `originalName` keeps lightweight migration
    // mapping the old stored attribute onto this property, so an existing
    // Pantry shelf doesn't silently lose this flag (and, with it, its
    // whole special routing/exclusion behavior) on first launch post-update.
    @Attribute(originalName: "isPantry")
    var isKitchen: Bool = false
    /// Marks this as *the* 2-Minute Task shelf — a permanent shelf (see
    /// `ShelvesView.deleteShelves`) that gets its own checklist step
    /// during Nightly Review and its own untimed checklist above the
    /// calendar (`ScheduleReviewView.twoMinuteTasksSection`/
    /// `DayTimelineGridView.twoMinuteTasksSection`) — its tasks never get
    /// a start/end time on the calendar itself (see
    /// `AISchedulingService`'s doc comment). Picked from Settings >
    /// Special Shelves rather than auto-detected by name, and kept
    /// unique there (choosing a shelf clears whichever other shelf had
    /// it, and clears `isRecurringTasks` on the same shelf).
    var isTwoMinuteTasks: Bool = false
    /// Marks this as *the* Recurring Tasks shelf — a permanent shelf (see
    /// `ShelvesView.deleteShelves`) whose tasks (see
    /// `TaskItem.isRecurring`) get placed onto the calendar at their own
    /// fixed time on every occurrence day, the same unconditional way a
    /// habit lands at its own target time (see
    /// `AISchedulingService.placeHabitsAndRecurringTasks`) — never
    /// competing for free time against a shelf's rule-packed tasks.
    /// Picked from Settings > Special Shelves, kept unique there the same
    /// way `isTwoMinuteTasks` is.
    var isRecurringTasks: Bool = false

    @Relationship(deleteRule: .nullify, inverse: \TaskItem.shelf)
    var tasks: [TaskItem]? = []

    @Relationship(deleteRule: .cascade, inverse: \SchedulingRule.shelf)
    var schedulingRules: [SchedulingRule]? = []

    init(
        name: String,
        systemImage: String = "tray",
        sortOrder: Int = 0
    ) {
        self.id = UUID()
        self.name = name
        self.systemImage = systemImage
        self.sortOrder = sortOrder
    }

    var hasEnabledSchedulingRules: Bool {
        (schedulingRules ?? []).contains { $0.isEnabled }
    }

    /// Whether duration is actually tracked here — the Kitchen shelf is
    /// forced off unconditionally, regardless of `tracksDuration`'s stored
    /// value, so nothing added to it can end up with a duration even from
    /// stale state (e.g. a Kitchen shelf created before this field existed).
    var effectiveTracksDuration: Bool { !isKitchen && tracksDuration }

    /// Whether due dates are actually tracked here — same Kitchen override
    /// as `effectiveTracksDuration`.
    var effectiveTracksDueDates: Bool { !isKitchen && hasDueDates }

    /// Whether Next Step is actually tracked here — same Kitchen override.
    var effectiveTracksNextStep: Bool { !isKitchen && hasNextStep }

    /// Whether Priority is actually tracked here — same Kitchen override.
    var effectiveTracksPriority: Bool { !isKitchen && hasPriority }

    /// Whether "Remind Me In" is actually tracked here — same Kitchen
    /// override.
    var effectiveTracksFutureReminder: Bool { !isKitchen && tracksFutureReminder }

    /// A task landing on this shelf — routed from the Inbox, or added
    /// directly here — keeps whatever duration it already had; only a task
    /// with *no* duration selected (`candidateMinutes <= 0`) gets stamped
    /// with this shelf's `defaultDurationMinutes` instead (itself `0` if
    /// no default is set, same as leaving it alone). A shelf that doesn't
    /// track duration at all forces 0 regardless of the candidate — that's
    /// an absolute rule, not a fallback. Every insertion call site (Inbox
    /// routing, the shelf's own add bar, receipt import) should route
    /// through this rather than reading `effectiveTracksDuration` itself.
    func resolvedDuration(candidateMinutes: Int) -> Int {
        guard effectiveTracksDuration else { return 0 }
        return candidateMinutes > 0 ? candidateMinutes : defaultDurationMinutes
    }

    var color: Color {
        Shelf.color(for: colorName)
    }

    static func color(for colorName: String) -> Color {
        colorPalette.first { $0.name == colorName }?.color ?? colorPalette[0].color
    }

    /// The same pastel shade `color.opacity(opacity)` always looked like
    /// against the system background, but as a real solid color instead
    /// of an actually-translucent one — so a shelf-color background can
    /// never let scrolled content or an adjacent carousel page show
    /// through it. Adapts to light/dark mode the same way
    /// `.systemBackground` itself does.
    func flattenedColor(opacity: Double) -> Color {
        Self.flatten(color, opacity: opacity)
    }

    /// General-purpose version of `flattenedColor` for any `Color`, not
    /// just a shelf's own — e.g. the Inbox carousel page, which tints
    /// with `.secondary` instead of a shelf color.
    static func flatten(_ color: Color, opacity: Double) -> Color {
        let foreground = UIColor(color)
        return Color(uiColor: UIColor { trait in
            let background = UIColor.systemBackground.resolvedColor(with: trait)
            var fgRed: CGFloat = 0, fgGreen: CGFloat = 0, fgBlue: CGFloat = 0, fgAlpha: CGFloat = 0
            var bgRed: CGFloat = 0, bgGreen: CGFloat = 0, bgBlue: CGFloat = 0, bgAlpha: CGFloat = 0
            foreground.getRed(&fgRed, green: &fgGreen, blue: &fgBlue, alpha: &fgAlpha)
            background.getRed(&bgRed, green: &bgGreen, blue: &bgBlue, alpha: &bgAlpha)
            return UIColor(
                red: fgRed * opacity + bgRed * (1 - opacity),
                green: fgGreen * opacity + bgGreen * (1 - opacity),
                blue: fgBlue * opacity + bgBlue * (1 - opacity),
                alpha: 1
            )
        })
    }

    static let iconOptions = [
        "checklist", "cart", "lightbulb", "archivebox", "tray",
        "star", "flag", "book", "briefcase", "house",
        "heart", "dollarsign.circle", "airplane", "gift", "wrench.and.screwdriver",
        "2.circle.fill", "arrow.triangle.2.circlepath"
    ]

    /// Earth tones plus a handful of blues/greens, all chosen to stay
    /// visually distinct from one another (rather than close variants of
    /// the same hue).
    static let colorPalette: [(name: String, color: Color)] = [
        ("Terracotta", Color(red: 0.886, green: 0.447, blue: 0.357)),
        ("Rust", Color(red: 0.718, green: 0.255, blue: 0.055)),
        ("Ochre", Color(red: 0.800, green: 0.467, blue: 0.133)),
        ("Olive", Color(red: 0.502, green: 0.502, blue: 0.0)),
        ("Sage", Color(red: 0.612, green: 0.686, blue: 0.533)),
        ("Slate", Color(red: 0.416, green: 0.482, blue: 0.545)),
        ("Plum", Color(red: 0.557, green: 0.271, blue: 0.522)),
        ("Clay", Color(red: 0.545, green: 0.369, blue: 0.235)),
        ("Sand", Color(red: 0.761, green: 0.698, blue: 0.502)),
        ("Espresso", Color(red: 0.294, green: 0.212, blue: 0.129)),
        ("Navy", Color(hue: 0.611, saturation: 0.55, brightness: 0.45)),
        ("Denim", Color(hue: 0.589, saturation: 0.40, brightness: 0.60)),
        ("Sky", Color(hue: 0.556, saturation: 0.45, brightness: 0.75)),
        ("Teal", Color(hue: 0.5, saturation: 0.45, brightness: 0.55)),
        ("Forest", Color(hue: 0.389, saturation: 0.40, brightness: 0.45)),
        ("Rose", Color(hue: 0.944, saturation: 0.40, brightness: 0.65))
    ]
}

extension Shelf {
    /// Seeded once on first launch so the app isn't empty out of the box.
    /// Mirrors the four pens the app originally shipped with. No scheduling
    /// rules are seeded — the user opts a shelf into the AI Scheduler by
    /// adding a rule from the Shelves screen.
    static func defaultSeedShelves() -> [Shelf] {
        [
            Shelf(name: "To-Do List", systemImage: "checklist", sortOrder: 0),
            Shelf(name: "Stuff to Buy", systemImage: "cart", sortOrder: 1),
            Shelf(name: "Future Project", systemImage: "lightbulb", sortOrder: 2),
            Shelf(name: "Reference", systemImage: "archivebox", sortOrder: 3)
        ]
    }
}
