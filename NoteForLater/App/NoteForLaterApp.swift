import SwiftUI
import SwiftData

@main
struct NoteForLaterApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var sharedModelContainer: ModelContainer = {
        // InboxItem stays in the schema (see its doc comment) purely so this
        // container can still open a pre-existing store — the store predates
        // any SwiftData version tracking, so there's no supported staged
        // migration path to drop an entity from it outright.
        let schema = Schema([
            InboxItem.self,
            TaskItem.self,
            ScheduledBlock.self,
            Shelf.self,
            CalendarSubscription.self,
            SchedulingRule.self,
            EligibleHoursWindow.self,
            Tag.self,
            NamedSchedule.self,
            Habit.self,
            HabitLog.self,
            TaskCompletionRecord.self,
            TagLink.self
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    init() {
        // Region-entry callbacks fire outside any view's environment, so the
        // monitoring service needs its own direct handle on the container.
        LocationMonitoringService.shared.modelContainer = sharedModelContainer
        // Same reason AddInboxItemIntent (Shortcuts/Siri/Back Tap) needs it —
        // App Intents run with no SwiftUI environment to pull a context from.
        SharedModelContainer.current = sharedModelContainer
        Self.migrateLegacyInboxItemsIfNeeded(container: sharedModelContainer)
    }

    /// One-time launch migration: converts every pre-existing InboxItem row
    /// into a shelf-less TaskItem (`shelf == nil` is now what "unsorted"
    /// means) and deletes the InboxItem, so the app never has to touch that
    /// entity again after the first launch on a given device.
    private static func migrateLegacyInboxItemsIfNeeded(container: ModelContainer) {
        let flagKey = "didMigrateInboxItemsToTaskItems.v1"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }

        let context = ModelContext(container)
        guard let legacyItems = try? context.fetch(FetchDescriptor<InboxItem>()) else {
            return
        }
        for item in legacyItems {
            let task = TaskItem(
                title: item.text,
                shelf: nil,
                sourceGmailMessageID: item.sourceGmailMessageID,
                dueDate: item.dueDate,
                nextStep: item.nextStep,
                estimatedMinutes: item.estimatedMinutes,
                tags: item.tags,
                priority: item.priority,
                createdAt: item.createdAt,
                isDivisible: item.isDivisible,
                minimumSegmentMinutes: item.minimumSegmentMinutes
            )
            task.includedSchedulingRuleIDs = item.includedSchedulingRuleIDs
            task.dueDateDecided = item.dueDateDecided
            task.durationDecided = item.durationDecided
            context.insert(task)
            context.delete(item)
        }
        do {
            try context.save()
            UserDefaults.standard.set(true, forKey: flagKey)
        } catch {
            // Leave the flag unset so this retries next launch instead of
            // silently losing whatever didn't convert.
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}

// TODO(Claude Code): Nightly generation trigger.
// This app needs the proposed schedule ready before the user wakes up (or
// the night before, per the spec: "each night it should show me a preview").
// Two complementary pieces to add:
//   1. A local notification scheduled daily (e.g. 8pm) via
//      UNUserNotificationCenter that deep-links into ScheduleReviewView.
//   2. A BGAppRefreshTask (BackgroundTasks framework) registered in this
//      App's init, submitted with an 8pm-ish earliest begin date, that calls
//      ScheduleReviewViewModel.generateProposedSchedule(shelves:) so the
//      schedule is already sitting there waiting when the notification fires.
//      Requires enabling the "Background Modes > Background fetch" /
//      "Background processing" capability and registering the task
//      identifier in Info.plist under BGTaskSchedulerPermittedIdentifiers.
