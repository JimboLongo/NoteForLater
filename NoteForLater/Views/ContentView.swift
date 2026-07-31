import SwiftUI
import SwiftData

struct ContentView: View {
    var body: some View {
        TabView {
            InboxView()
                .tabItem { Label("Inbox", systemImage: "tray") }

            HoldingPenListView(pen: .todo)
                .tabItem { Label("To-Do", systemImage: HoldingPen.todo.systemImage) }

            ScheduleReviewView()
                .tabItem { Label("Schedule", systemImage: "calendar") }

            MorePenListView()
                .tabItem { Label("More", systemImage: "ellipsis.circle") }
        }
    }
}

/// Groups the remaining, less-frequently-visited holding pens behind one tab
/// so the tab bar doesn't get crowded.
struct MorePenListView: View {
    var body: some View {
        NavigationStack {
            List {
                ForEach([HoldingPen.shopping, .futureProject, .reference]) { pen in
                    NavigationLink(pen.rawValue) {
                        HoldingPenListView(pen: pen)
                    }
                }
            }
            .navigationTitle("More")
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [InboxItem.self, TaskItem.self, ScheduledBlock.self], inMemory: true)
}
