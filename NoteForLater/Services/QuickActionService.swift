import UIKit
import Observation

/// Bridges the Home Screen "long press icon" quick action into SwiftUI.
/// AppDelegate/SceneDelegate hand the tapped shortcut here; ContentView and
/// InboxView both observe `pendingQuickAdd` to jump to the Inbox tab and
/// focus the capture field.
@Observable
final class QuickActionService {
    static let shared = QuickActionService()
    static let quickAddType = "com.jimbo.NoteForLater.quickAdd"

    var pendingQuickAdd = false

    private init() {}

    static func registerShortcutItems() {
        UIApplication.shared.shortcutItems = [
            UIApplicationShortcutItem(
                type: quickAddType,
                localizedTitle: "Quick Add",
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "plus.circle.fill")
            )
        ]
    }

    func handle(_ shortcutItem: UIApplicationShortcutItem) {
        guard shortcutItem.type == Self.quickAddType else { return }
        pendingQuickAdd = true
    }
}
