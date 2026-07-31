import Foundation
import SwiftData

/// A user-defined bucket that sorted tasks live in (e.g. "To-Do List",
/// "Stuff to Buy"). Unlike the old fixed four-pen setup, shelves are fully
/// user-configurable from the Shelves screen: name, icon, whether they're
/// pinned to the bottom tab bar, and whether tasks placed here are eligible
/// for the AI Scheduler to auto-assign onto the calendar.
@Model
final class Shelf {
    var id: UUID
    var name: String
    var systemImage: String
    var sortOrder: Int
    var showsInTabBar: Bool
    var isEligibleForScheduling: Bool

    @Relationship(deleteRule: .nullify, inverse: \TaskItem.shelf)
    var tasks: [TaskItem]? = []

    init(
        name: String,
        systemImage: String = "tray",
        sortOrder: Int = 0,
        showsInTabBar: Bool = false,
        isEligibleForScheduling: Bool = false
    ) {
        self.id = UUID()
        self.name = name
        self.systemImage = systemImage
        self.sortOrder = sortOrder
        self.showsInTabBar = showsInTabBar
        self.isEligibleForScheduling = isEligibleForScheduling
    }
}

extension Shelf {
    /// Seeded once on first launch so the app isn't empty out of the box.
    /// Mirrors the four pens the app originally shipped with.
    static func defaultSeedShelves() -> [Shelf] {
        [
            Shelf(name: "To-Do List", systemImage: "checklist", sortOrder: 0, showsInTabBar: true, isEligibleForScheduling: true),
            Shelf(name: "Stuff to Buy", systemImage: "cart", sortOrder: 1, showsInTabBar: false, isEligibleForScheduling: false),
            Shelf(name: "Future Project", systemImage: "lightbulb", sortOrder: 2, showsInTabBar: false, isEligibleForScheduling: false),
            Shelf(name: "Reference", systemImage: "archivebox", sortOrder: 3, showsInTabBar: false, isEligibleForScheduling: false)
        ]
    }
}
