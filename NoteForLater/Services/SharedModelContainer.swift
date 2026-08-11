import SwiftData

/// A process-wide handle on the app's ModelContainer, for code that runs
/// outside any SwiftUI view's environment — App Intents (Shortcuts, Siri,
/// Back Tap) chief among them, which have no `@Environment(\.modelContext)`
/// to reach into. Set once from `NoteForLaterApp.init()`, mirroring how
/// `LocationMonitoringService` already gets its own direct handle for
/// background region-entry callbacks.
enum SharedModelContainer {
    static var current: ModelContainer?
}
