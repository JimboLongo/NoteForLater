import AppIntents
import SwiftData

/// Exposes "Add to Inbox" as a Shortcuts/Siri action so it can be wired up
/// to things like a Back Tap gesture (Settings > Accessibility > Touch >
/// Back Tap), a Home Screen/Lock Screen widget, or a Siri phrase — anything
/// that can trigger a Shortcut. Runs with `openAppWhenRun = false`, so a
/// Back Tap can silently drop a note in without switching away from
/// whatever app you were using.
struct AddInboxItemIntent: AppIntent {
    static var title: LocalizedStringResource = "Add to Inbox"
    static var description = IntentDescription("Adds a quick note to NoteForLater's Inbox — build a Shortcut around this to fire it from a Back Tap.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Note")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to Inbox")
    }

    init() {}

    init(text: String) {
        self.text = text
    }

    func perform() async throws -> some IntentResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let container = SharedModelContainer.current else {
            return .result()
        }
        let context = ModelContext(container)
        context.insert(TaskItem(title: trimmed, shelf: nil))
        try? context.save()
        return .result()
    }
}

/// Optional but low-cost: surfaces the intent to Siri with a couple of
/// default phrases and gives it a nicer entry in the Shortcuts app's
/// action gallery. Not required for the Back Tap flow (that works off any
/// Shortcut built around AddInboxItemIntent directly), just extra
/// discoverability.
struct NoteForLaterShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddInboxItemIntent(),
            phrases: [
                "Add to \(.applicationName) inbox",
                "Quick add to \(.applicationName)"
            ],
            shortTitle: "Add to Inbox",
            systemImageName: "tray.and.arrow.down"
        )
    }
}
