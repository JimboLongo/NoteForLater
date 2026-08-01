import Foundation
import SwiftData

/// A user-defined bucket that sorted tasks live in (e.g. "To-Do List",
/// "Stuff to Buy"). Unlike the old fixed four-pen setup, shelves are fully
/// user-configurable from the Shelves screen: name, icon, whether they're
/// pinned to the bottom tab bar, and a list of SchedulingRules describing
/// when/how the AI Scheduler should pull tasks from this shelf onto the
/// calendar. A shelf with no enabled rules is never touched by the
/// scheduler — rules ARE the eligibility mechanism, there's no separate flag.
@Model
final class Shelf {
    var id: UUID
    var name: String
    var systemImage: String
    var sortOrder: Int
    var showsInTabBar: Bool = false

    @Relationship(deleteRule: .nullify, inverse: \TaskItem.shelf)
    var tasks: [TaskItem]? = []

    @Relationship(deleteRule: .cascade, inverse: \SchedulingRule.shelf)
    var schedulingRules: [SchedulingRule]? = []

    init(
        name: String,
        systemImage: String = "tray",
        sortOrder: Int = 0,
        showsInTabBar: Bool = false
    ) {
        self.id = UUID()
        self.name = name
        self.systemImage = systemImage
        self.sortOrder = sortOrder
        self.showsInTabBar = showsInTabBar
    }

    var hasEnabledSchedulingRules: Bool {
        (schedulingRules ?? []).contains { $0.isEnabled }
    }
}

extension Shelf {
    /// Seeded once on first launch so the app isn't empty out of the box.
    /// Mirrors the four pens the app originally shipped with. No scheduling
    /// rules are seeded — the user opts a shelf into the AI Scheduler by
    /// adding a rule from the Shelves screen.
    static func defaultSeedShelves() -> [Shelf] {
        [
            Shelf(name: "To-Do List", systemImage: "checklist", sortOrder: 0, showsInTabBar: true),
            Shelf(name: "Stuff to Buy", systemImage: "cart", sortOrder: 1, showsInTabBar: false),
            Shelf(name: "Future Project", systemImage: "lightbulb", sortOrder: 2, showsInTabBar: false),
            Shelf(name: "Reference", systemImage: "archivebox", sortOrder: 3, showsInTabBar: false)
        ]
    }
}
