import SwiftUI
import SwiftData

/// The Kitchen shelf's own screen — a segmented switch between Pantry
/// (ingredients on hand, same concept as the plain shelf list, just
/// styled for it — see `ShelfListView`'s `showsPantryAge`), Cookbook
/// (saved recipes — see `CookbookView`), and Meals (recipes ranked by how
/// many ingredients are still missing from the Pantry — see `MealsView`).
/// Reached the same way any other shelf is, via `ShelfCarouselView`, which
/// routes here instead of the plain `ShelfListView` whenever
/// `shelf.isKitchen`.
struct KitchenView: View {
    let shelf: Shelf
    @State private var selectedPane: Pane = .pantry

    private enum Pane: String, CaseIterable {
        case pantry = "Pantry"
        case cookbook = "Cookbook"
        case meals = "Meals"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedPane) {
                ForEach(Pane.allCases, id: \.self) { pane in
                    Text(pane.rawValue).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .tint(shelf.color)
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)
            // Same tint `ShelfListView` gives its own header — flows
            // straight into the pane underneath instead of a plain bar
            // sitting on top of it.
            .background(shelf.flattenedColor(opacity: 0.2))

            switch selectedPane {
            case .pantry:
                ShelfListView(shelf: shelf, displayName: "Pantry")
            case .cookbook:
                CookbookView(shelf: shelf)
            case .meals:
                MealsView(shelf: shelf)
            }
        }
    }
}

#Preview {
    let shelf = Shelf(name: "The Kitchen", systemImage: "refrigerator")
    shelf.isKitchen = true
    return NavigationStack {
        KitchenView(shelf: shelf)
    }
    .modelContainer(for: [TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self, Habit.self, HabitLog.self, Recipe.self], inMemory: true)
}
