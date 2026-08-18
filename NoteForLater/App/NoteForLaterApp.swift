import SwiftUI
import SwiftData
import UserNotifications

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
            TagLink.self,
            Recipe.self
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
        Self.renamePantryShelfToKitchenIfNeeded(container: sharedModelContainer)
        Self.unscheduleTwoMinuteTaskBlocksIfNeeded(container: sharedModelContainer)
        Self.cancelLegacyIndividualReminderNotificationsIfNeeded()
        Self.backfillRemainingMinutesIfNeeded(container: sharedModelContainer)
    }

    /// One-time launch migration: `TaskItem.remainingMinutes` is new — a
    /// task that existed before this shipped gets the field's own default
    /// (`0`) on schema migration, not a value derived from its existing
    /// `estimatedMinutes`. Left alone, every pre-existing task would read
    /// as fully consumed ("0 of Y scheduled") the moment this update
    /// lands, even one that was never touched by the scheduler at all.
    /// Backfills every task to `remainingMinutes = estimatedMinutes`
    /// exactly once; a task created after this migration already gets
    /// that from `TaskItem.init` itself.
    private static func backfillRemainingMinutesIfNeeded(container: ModelContainer) {
        let flagKey = "didBackfillRemainingMinutes.v1"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }

        let context = ModelContext(container)
        guard let tasks = try? context.fetch(FetchDescriptor<TaskItem>()) else { return }
        for task in tasks {
            task.remainingMinutes = task.estimatedMinutes
        }
        do {
            try context.save()
            UserDefaults.standard.set(true, forKey: flagKey)
        } catch {
            // Leave the flag unset so this retries next launch instead of
            // silently leaving every existing task's remaining minutes at 0.
        }
    }

    /// One-time launch cleanup: the old per-habit (`HabitNotificationService`)
    /// and per-block (`UpcomingBlockNotificationService`) reminder systems
    /// were removed in favor of the Daily Check-Ins digest
    /// (`DailyDigestNotificationService`), but deleting that Swift code
    /// never un-scheduled whatever individual reminders those two had
    /// already queued with iOS before the removal — a local notification,
    /// once added, keeps existing (and firing) independently of whether
    /// the code that created it still exists, until its own trigger date
    /// or an explicit removal. This sweeps out anything still pending
    /// under either service's old identifier prefix, so someone who had
    /// individual reminders scheduled right before updating doesn't keep
    /// getting them for the rest of that old rolling window on top of the
    /// new digest.
    private static func cancelLegacyIndividualReminderNotificationsIfNeeded() {
        let flagKey = "didCancelLegacyIndividualReminderNotifications.v1"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }

        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let staleIDs = requests
                .map(\.identifier)
                .filter { $0.hasPrefix("com.jimbo.NoteForLater.habit.") || $0.hasPrefix("com.jimbo.NoteForLater.upcomingBlock") }
            center.removePendingNotificationRequests(withIdentifiers: staleIDs)
        }
        // Fired-and-forgotten rather than waiting on the async callback
        // above to set this — `getPendingNotificationRequests` always
        // succeeds (there's no failure case to retry for), so there's
        // nothing worth blocking launch on.
        UserDefaults.standard.set(true, forKey: flagKey)
    }

    /// One-time launch migration: the 2-Minute Task shelf used to jump the
    /// scheduling queue and land at the very front of the day's free
    /// time — in practice, midnight, whenever nothing else occupied the
    /// morning (see `AISchedulingService`'s doc comment on
    /// `placeHabits`). That's gone now — those tasks are an untimed
    /// checklist instead (`ScheduleReviewView.twoMinuteTasksSection`) —
    /// so this sweeps away whatever stray midnight blocks that old
    /// behavior already left on-device, freeing their tasks back up.
    /// Leaves anything already approved (actually pushed to Google
    /// Calendar) alone rather than silently deleting a real calendar
    /// event out from under the user.
    private static func unscheduleTwoMinuteTaskBlocksIfNeeded(container: ModelContainer) {
        let flagKey = "didUnscheduleTwoMinuteTaskBlocks.v1"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }

        let context = ModelContext(container)
        guard let blocks = try? context.fetch(FetchDescriptor<ScheduledBlock>()) else { return }
        for block in blocks where block.approvalStatus != .approved && block.task?.shelf?.isTwoMinuteTasks == true {
            block.task?.isScheduled = false
            block.task = nil
            context.delete(block)
        }
        do {
            try context.save()
            UserDefaults.standard.set(true, forKey: flagKey)
        } catch {
            // Leave the flag unset so this retries next launch instead of
            // silently leaving stray midnight blocks in place.
        }
    }

    /// One-time launch migration: an existing Kitchen shelf (see
    /// `Shelf.isKitchen`, preserved across the `isPantry` rename via
    /// `@Attribute(originalName:)`) still literally named "Pantry" from
    /// before it grew a Cookbook pane gets renamed to "The Kitchen" —
    /// `isKitchen == true` is how it's found rather than matching on the
    /// old name, so this is a no-op for anyone who already renamed their
    /// Pantry shelf to something else.
    private static func renamePantryShelfToKitchenIfNeeded(container: ModelContainer) {
        let flagKey = "didRenamePantryShelfToKitchen.v1"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }

        let context = ModelContext(container)
        guard let shelves = try? context.fetch(FetchDescriptor<Shelf>()) else { return }
        for shelf in shelves where shelf.isKitchen && shelf.name == "Pantry" {
            shelf.name = "The Kitchen"
        }
        do {
            try context.save()
            UserDefaults.standard.set(true, forKey: flagKey)
        } catch {
            // Leave the flag unset so this retries next launch instead of
            // silently leaving the shelf named "Pantry".
        }
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
