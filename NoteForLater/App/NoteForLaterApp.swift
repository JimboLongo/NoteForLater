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
            Recipe.self,
            MealSelection.self,
            UPCBank.self,
            RecurringTaskLog.self,
            PushedRecurringOccurrence.self
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
        DiagFileLog.markLaunch()
        Self.repairDuplicateHabitLogsIfNeeded(container: sharedModelContainer)
        Self.backfillRemainingMinutesIfNeeded(container: sharedModelContainer)
        Self.repairDrainedRemainingMinutesIfNeeded(container: sharedModelContainer)
        Self.processPushedRecurringOccurrencesIfNeeded(container: sharedModelContainer)
    }

    /// Runs once per calendar day, not once ever — unlike the one-time
    /// repairs above (which each guard on a permanent `UserDefaults`
    /// flag), a `PushedRecurringOccurrence` needs advancing every day it
    /// stays unresolved, so this tracks the *last day it ran* instead and
    /// re-runs whenever that's stale. Catches up on more than one missed
    /// launch at once — `advanceOneDay` below is a loop, not a single
    /// step, so going a week without opening the app still walks each
    /// pushed occurrence the correct number of days forward (or resolves
    /// it early, the moment the walk crosses a real recurrence day)
    /// rather than only ever advancing by one.
    private static func processPushedRecurringOccurrencesIfNeeded(container: ModelContainer) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let lastRunKey = "lastProcessedPushedRecurringOccurrences"
        if let lastRun = UserDefaults.standard.object(forKey: lastRunKey) as? Date,
           calendar.startOfDay(for: lastRun) >= today {
            return
        }

        let context = ModelContext(container)
        guard let pending = try? context.fetch(FetchDescriptor<PushedRecurringOccurrence>(
            predicate: #Predicate { !$0.isCompleted }
        )), !pending.isEmpty else {
            UserDefaults.standard.set(today, forKey: lastRunKey)
            return
        }

        let allTasks = (try? context.fetch(FetchDescriptor<TaskItem>())) ?? []
        let taskByID = Dictionary(uniqueKeysWithValues: allTasks.map { ($0.id, $0) })
        var didChange = false

        for occurrence in pending {
            guard let task = taskByID[occurrence.taskID], task.isRecurring else {
                // The task itself is gone (deleted) or is no longer
                // recurring — nothing left to push forward.
                context.delete(occurrence)
                didChange = true
                continue
            }
            if isAlreadyResolved(occurrence, task: task, calendar: calendar, context: context) {
                context.delete(occurrence)
                didChange = true
                continue
            }
            didChange = advanceOneDay(occurrence, task: task, today: today, calendar: calendar, context: context) || didChange
        }

        guard didChange else {
            UserDefaults.standard.set(today, forKey: lastRunKey)
            return
        }
        do {
            try context.save()
            UserDefaults.standard.set(today, forKey: lastRunKey)
        } catch {
            // Leave the flag unset so this retries next launch rather
            // than silently leaving pushed occurrences stuck on a stale
            // `currentDate`.
        }
    }

    /// True once a real, already-complete representation exists for
    /// `occurrence.currentDate` — a Specific Time block someone checked
    /// off on the calendar, or (AM/Midday/PM) a completed
    /// `RecurringTaskLog` for that day. Checked *before* trying to push
    /// further, so completing the pushed instance through its normal,
    /// already-existing "mark complete" UI is all it takes to resolve the
    /// chain — nothing else needs to know a push was ever in progress.
    private static func isAlreadyResolved(_ occurrence: PushedRecurringOccurrence, task: TaskItem, calendar: Calendar, context: ModelContext) -> Bool {
        if task.recurrenceTimeMode == .specific {
            return (task.scheduledBlocks ?? []).contains {
                calendar.isDate($0.date, inSameDayAs: occurrence.currentDate) && $0.isCompleted
            }
        }
        return RecurringTaskLog.log(taskID: task.id, on: occurrence.currentDate, context: context, calendar: calendar)?.isCompleted ?? false
    }

    /// Walks `occurrence.currentDate` forward one day at a time, up to
    /// (not including) `today` — stopping the instant the next day is a
    /// real recurrence for `task` (deletes `occurrence`; the ordinary
    /// recurrence pattern takes over from there, with `AISchedulingService
    /// .placeHabitsAndRecurringTasks`'s own "already exists" check
    /// preventing a duplicate once a Specific Time block is later
    /// inserted for that same day by the second pass above), or once it
    /// catches up to `today` still unresolved. Returns whether anything
    /// actually changed, so the caller only bothers saving when it did.
    /// Deliberately never consults `recurrenceEndDate` — see
    /// `PushedRecurringOccurrence`'s own doc comment for why an
    /// already-missed occurrence keeps pushing regardless.
    private static func advanceOneDay(_ occurrence: PushedRecurringOccurrence, task: TaskItem, today: Date, calendar: Calendar, context: ModelContext) -> Bool {
        var cursor = calendar.startOfDay(for: occurrence.currentDate)
        var changed = false
        while cursor < today {
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            if task.hasRecurringOccurrence(on: next, calendar: calendar) {
                removePlaceholderBlock(for: task, on: cursor, calendar: calendar, context: context)
                context.delete(occurrence)
                return true
            }
            relocatePlaceholderBlock(for: task, from: cursor, to: next, calendar: calendar, context: context)
            occurrence.currentDate = next
            changed = true
            cursor = next
        }
        return changed
    }

    /// Moves the Specific Time placeholder `ScheduledBlock` for a pushed
    /// occurrence from `oldDate` to `newDate` — or creates it fresh at
    /// `newDate` if none exists yet, which is exactly the case on the very
    /// first push (`clearIncompletePastBlocks` already deleted the
    /// original incomplete block before this ever runs). Either way there
    /// is only ever one block tracking the chain, never one left behind
    /// at every day it passed through. No-op for AM/Midday/PM tasks —
    /// those have no `ScheduledBlock` at all; `DayTimelineGridView` reads
    /// `PushedRecurringOccurrence.currentDate` directly instead.
    private static func relocatePlaceholderBlock(for task: TaskItem, from oldDate: Date, to newDate: Date, calendar: Calendar, context: ModelContext) {
        guard task.recurrenceTimeMode == .specific else { return }
        guard let start = task.recurringOccurrenceTime(on: newDate, calendar: calendar) else { return }
        let minutes = task.estimatedMinutes > 0 ? task.estimatedMinutes : 30
        let end = start.addingTimeInterval(TimeInterval(minutes * 60))
        if let existing = (task.scheduledBlocks ?? []).first(where: { calendar.isDate($0.date, inSameDayAs: oldDate) }) {
            existing.date = calendar.startOfDay(for: newDate)
            existing.startTime = start
            existing.endTime = end
        } else {
            let block = ScheduledBlock(date: newDate, startTime: start, endTime: end, task: task, isEstimatedDuration: task.estimatedMinutes <= 0)
            context.insert(block)
        }
    }

    /// Deletes the Specific Time placeholder block left at `date` once the
    /// chain resolves onto a real recurrence day — the genuine occurrence
    /// for that day is created separately by `AISchedulingService
    /// .placeHabitsAndRecurringTasks`, so the placeholder must go rather
    /// than sit there as a duplicate.
    private static func removePlaceholderBlock(for task: TaskItem, on date: Date, calendar: Calendar, context: ModelContext) {
        guard task.recurrenceTimeMode == .specific else { return }
        if let existing = (task.scheduledBlocks ?? []).first(where: { calendar.isDate($0.date, inSameDayAs: date) }) {
            context.delete(existing)
        }
    }

    /// One-time launch repair for `HabitLog` damage predating the
    /// fetch-based write funnel (`Habit.logOrCreate`). Two distinct
    /// repairs, both via `HabitLogMerge` so this and
    /// `HabitDetailView.deduplicateLogs` can never diverge:
    ///
    /// 1. **Collapse same-day duplicates** into one row under rule 1
    ///    (`complete > excused > missed > none`, mutually exclusive).
    ///    Where a sibling row kept a completion the nightly sweep had
    ///    overwritten with `.missed`, this restores it.
    /// 2. **Normalise single logs whose arrays overlap** — an index in two
    ///    arrays at once, left behind by the old union-based dedup. No
    ///    visible change (`occurrenceStatus` reports the first match either
    ///    way), but streak and rolling-30 math read those arrays directly
    ///    and double-count until it is fixed.
    ///
    /// **Derives its input fresh, immediately before writing.** Never from
    /// any earlier count: `deduplicateLogs` mutates this data whenever a
    /// habit's detail screen opens, and `HabitDetailView.setDay` rewrites a
    /// whole day whenever a day cell is tapped. During this investigation
    /// the store moved twice between measuring and applying — a 12-day
    /// duplicate set became 2 days, and four habits' misses resolved — both
    /// times benignly, both times invisibly. Re-deriving is the only thing
    /// that makes that safe.
    ///
    /// Runs from `init`, before any view exists, so nothing can open a
    /// detail screen and move the store between the derive and the write.
    ///
    /// Once `deduplicateLogs` stops unioning (it has), no new overlaps can
    /// appear, so repair 2 is genuinely one-shot. Repair 1 likewise, now
    /// that the write funnel prevents new duplicates.
    private static func repairDuplicateHabitLogsIfNeeded(container: ModelContainer) {
        let flagKey = "didRepairDuplicateHabitLogs.v1"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }

        let context = ModelContext(container)
        guard let habits = try? context.fetch(FetchDescriptor<Habit>()) else { return }
        let calendar = Calendar.current
        var collapsedDays = 0
        var deletedLogs = 0
        var normalisedLogs = 0

        for habit in habits {
            let byDay = Dictionary(grouping: habit.logs ?? []) { calendar.startOfDay(for: $0.date) }
            for (day, logs) in byDay {
                let dayLabel = ISO8601DateFormatter().string(from: day).prefix(10)
                let hadOverlap = logs.contains { log in
                    let c = Set(log.completedOccurrences)
                    let m = Set(log.missedOccurrences)
                    let e = Set(log.excusedOccurrences)
                    return !c.intersection(m).union(c.intersection(e)).union(m.intersection(e)).isEmpty
                }
                // `collapse` rewrites the survivor's three arrays as
                // mutually exclusive even when there is only one row, which
                // is exactly what repair 2 needs — so both repairs are the
                // same call.
                guard logs.count > 1 || hadOverlap else { continue }
                HabitLogMerge.collapse(logs, context: context)
                if logs.count > 1 {
                    collapsedDays += 1
                    deletedLogs += logs.count - 1
                }
                if hadOverlap { normalisedLogs += 1 }
                DiagFileLog.write("REPAIR \(habit.name) \(dayLabel) rows=\(logs.count) overlap=\(hadOverlap)")
            }
        }

        do {
            try context.save()
            UserDefaults.standard.set(true, forKey: flagKey)
            DiagFileLog.write("REPAIR DONE collapsedDays=\(collapsedDays) deletedLogs=\(deletedLogs) normalisedLogs=\(normalisedLogs)")
        } catch {
            // Flag stays unset so this retries next launch rather than
            // leaving duplicates and overlapping arrays in place.
            DiagFileLog.write("REPAIR FAILED \(error) — will retry next launch")
        }
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

    /// One-time launch repair, deliberately **separate** from
    /// `backfillRemainingMinutesIfNeeded` above rather than folded into
    /// it. That one is the original §1.1 schema backfill and blanket-sets
    /// every task to its full estimate; this one repairs damage from a
    /// later bug and must *not* touch correctly-scheduled tasks. They
    /// answer different questions and have their own flags, so a device
    /// that already ran the first still gets this.
    ///
    /// Four call sites used to delete a `ScheduledBlock` without restoring
    /// the minutes it represented (see `ScheduleReviewViewModel
    /// .removeBlock`), permanently destroying that time. A task could end
    /// up incomplete with `remainingMinutes == 0` and nothing scheduled,
    /// which makes it invisible to the scheduler *and* to every
    /// "why wasn't this placed" surface. Fixing the leak doesn't repair
    /// tasks already damaged by it.
    ///
    /// Per-task logic — including which tasks are deliberately left
    /// untouched — lives in `TaskItem.repairedRemainingMinutes()`.
    private static func repairDrainedRemainingMinutesIfNeeded(container: ModelContainer) {
        let flagKey = "didRepairDrainedRemainingMinutes.v1"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }

        let context = ModelContext(container)
        guard let tasks = try? context.fetch(FetchDescriptor<TaskItem>()) else { return }
        var repairedCount = 0
        for task in tasks {
            guard let repaired = task.repairedRemainingMinutes() else { continue }
            task.remainingMinutes = repaired
            repairedCount += 1
        }
        do {
            try context.save()
            UserDefaults.standard.set(true, forKey: flagKey)
            if repairedCount > 0 {
                print("[migration] repaired remainingMinutes on \(repairedCount) task(s)")
            }
        } catch {
            // Flag stays unset so this retries next launch rather than
            // leaving drained tasks permanently unschedulable.
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
