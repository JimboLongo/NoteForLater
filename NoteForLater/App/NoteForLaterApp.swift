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
            PushedRecurringOccurrence.self,
            PushRecursionWarning.self
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
        Self.migrateIncompleteBlocksAndMealsToThreeStateIfNeeded(container: sharedModelContainer)
        Self.migrateDurationDivisibleToSingleWheelIfNeeded(container: sharedModelContainer)
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
            if PushedRecurringOccurrence.isAlreadyResolved(occurrence, task: task, calendar: calendar, context: context) {
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

    /// One-time backfill for the three-state completion redesign
    /// (`TaskItem`/`ScheduledBlock`/`MealSelection.status`, replacing the
    /// old bare `isCompleted: Bool`). Every existing row's `statusRaw` is
    /// a brand-new column that defaults to `.none` with no historical
    /// data of its own — this seeds it correctly instead of leaving every
    /// pre-existing record reading as "never touched," using each model's
    /// `legacyIsCompleted` (see `TaskItem.legacyIsCompleted`'s own doc
    /// comment — the renamed-but-still-mapped old `isCompleted` column,
    /// confirmed by a throwaway SwiftData probe to still hold the real
    /// historical value at the point this runs).
    ///
    /// Three-way split per row, not just complete/incomplete:
    /// - `legacyIsCompleted == true` → `.complete`. Actually finished,
    ///   under the old code, before any of this existed.
    /// - `false` and already in the past (`startTime`/`date < now`) →
    ///   `.missed`. This is the faithful translation of what the old
    ///   sweeps (`clearIncompletePastBlocks`/`resolveIncompleteMealSelections`)
    ///   were about to do to it anyway — delete it and move on — not a new
    ///   decision. Landing on `.missed` also means `resolveMissedPastBlocks`
    ///   picks these up on the very next commit and guarantees each one a
    ///   fresh placement, the same as if a real interactive tap had just
    ///   landed it on `.missed` (see that function's own doc comment on
    ///   why it exists as a redundant safety net *for exactly this case*).
    /// - `false` and current/future → `.none`. Genuinely not reached yet;
    ///   nothing to translate.
    ///
    /// `TaskItem` gets only the two-way `.complete`/`.none` split, not the
    /// three-way one — unlike a block or meal, a bare task has no single
    /// unambiguous day to compare against `now` (no due date, no
    /// schedule, or scheduled far in the future are all ordinary), so
    /// there's no non-arbitrary way to call an old incomplete task
    /// "missed" the way a dated block or meal can be. Its `.missed`
    /// surfaces identically to `.none` everywhere that reads it today
    /// anyway (both fail `!isCompleted`), so this loses nothing
    /// functionally — it just doesn't manufacture a "missed" verdict this
    /// migration has no real basis for.
    ///
    /// A migrated `.complete` meal also gets `hasDeductedPantry = true` —
    /// that deduction already happened for real, under the old
    /// `isCompleted`-toggle pantry logic, before `hasDeductedPantry`
    /// existed to guard it. Leaving it `false` would let a later
    /// Complete → Missed → Complete cycle deduct the same ingredients a
    /// second time. A migrated `.missed`/`.none` meal was never deducted,
    /// so it's left `false`, still eligible for a real future deduction.
    /// Blocks get no equivalent seed for `hasGuaranteedReplacement` — it
    /// only ever gates `.missed`, and letting `resolveMissedPastBlocks`
    /// see it unset (its ordinary default) is exactly what makes it
    /// guarantee that first placement in the paragraph above.
    ///
    /// **Idempotence, the gate, and interruption — answered explicitly,
    /// not assumed:**
    ///
    /// - **Gate:** `UserDefaults` key `didMigrateBlocksAndMealsToThreeState.v1`,
    ///   checked before touching anything. It is set **only after**
    ///   `context.save()` returns successfully — never before, and never
    ///   speculatively. Setting it first would be the worse failure mode:
    ///   a crash between "flag set" and "work finished" would permanently
    ///   disable the retry that migration needs, leaving the store
    ///   half-migrated forever with nothing left to notice or fix it.
    ///   Setting it only after success means the only failure mode left
    ///   is *retrying too often*, never *not retrying when it should*.
    /// - **Interrupted partway (app killed mid-backfill):** SwiftData's
    ///   `context.save()` is transactional — every row mutated in this
    ///   pass commits together or not at all. Killed before `save()` is
    ///   reached: nothing persisted, `legacyIsCompleted` and
    ///   `hasMigratedThreeState` are both exactly as they were, next
    ///   launch retries from an untouched, consistent starting point.
    ///   Killed *during* `save()`: SQLite's own journal guarantees that
    ///   resolves to fully-committed or fully-rolled-back, never a torn
    ///   write. There is no state in which some rows are migrated and
    ///   others aren't from a single interrupted pass.
    /// - **Idempotence — the part that isn't free:** the one real gap,
    ///   found by re-reading this function rather than assuming the flag
    ///   alone was enough. The flag is set via `UserDefaults`, a
    ///   *separate* store from the SwiftData one `save()` just committed
    ///   to — so a crash in the narrow window *after* `save()` succeeds
    ///   but *before* the `UserDefaults` write durably lands would leave
    ///   the flag unset despite the data already being correctly
    ///   migrated. The next launch would then run this function again
    ///   against already-migrated data. Recomputing `migratedDatedStatus`
    ///   from `legacyIsCompleted` + a *new* `now` on that second pass
    ///   would not just redundantly repeat the first pass's answer — for
    ///   a row still sitting at `.none` (the normal, legitimate state for
    ///   anything genuinely undecided, whether that's because migration
    ///   hasn't run yet or because it ran and the user simply hasn't
    ///   acted since), enough wall-clock time passing between the two
    ///   passes could flip `ownDay < now` from false to true and silently
    ///   reclassify it to `.missed` — including a row the user
    ///   deliberately cycled back to `.none` in between, since a bare
    ///   `.none` can't tell "never migrated" apart from "migrated, still
    ///   open." That would be exactly the silent reclassification this
    ///   backfill must not cause. `hasMigratedThreeState` (see
    ///   `TaskItem`'s own doc comment on it) closes this: checked before
    ///   deriving, set in the *same* `context.save()` call as the
    ///   `status` write it guards, so the two can never land out of sync
    ///   the way the data store and `UserDefaults` can. A second full
    ///   pass — however it's triggered — now touches zero already-done
    ///   rows, making the *data-level* work idempotent regardless of
    ///   whether the outer `UserDefaults` flag's write ever completes.
    ///   The outer flag stays purely as a fast-path early exit for the
    ///   overwhelmingly common case (already migrated, skip the fetch
    ///   entirely) — the per-row flag is what actually guarantees
    ///   correctness. Verified directly: `ThreeStateCompletionTests
    ///   .test_migration_runTwice_secondPassIsANoOp`.
    static func migrateIncompleteBlocksAndMealsToThreeStateIfNeeded(container: ModelContainer) {
        let flagKey = "didMigrateBlocksAndMealsToThreeState.v1"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }

        let context = ModelContext(container)
        let now = Date.now

        if let blocks = try? context.fetch(FetchDescriptor<ScheduledBlock>()) {
            for block in blocks where !block.hasMigratedThreeState {
                block.status = migratedDatedStatus(legacyIsCompleted: block.legacyIsCompleted, ownDay: block.startTime, now: now)
                block.hasMigratedThreeState = true
            }
        }
        if let meals = try? context.fetch(FetchDescriptor<MealSelection>()) {
            for meal in meals where !meal.hasMigratedThreeState {
                meal.status = migratedDatedStatus(legacyIsCompleted: meal.legacyIsCompleted, ownDay: meal.date, now: now)
                if meal.status == .complete {
                    meal.hasDeductedPantry = true
                }
                meal.hasMigratedThreeState = true
            }
        }
        if let tasks = try? context.fetch(FetchDescriptor<TaskItem>()) {
            for task in tasks where !task.hasMigratedThreeState {
                task.status = migratedUndatedStatus(legacyIsCompleted: task.legacyIsCompleted)
                task.hasMigratedThreeState = true
            }
        }
        do {
            try context.save()
            UserDefaults.standard.set(true, forKey: flagKey)
        } catch {
            // Leave the flag unset so this retries next launch instead of
            // silently leaving every existing record's status at the
            // schema default. Safe to retry — see this function's own
            // doc comment on idempotence.
        }
    }

    /// One-time reconciliation for Duration/Divisible collapsing from a
    /// Yes/No-pills-plus-wheel pair into a single wheel. Each question's
    /// two old flags became one `...Picked` flag (see
    /// `TaskItem.durationPicked`), and the *rename* already did most of
    /// the work: `durationDecided`'s column is now `durationPicked`, and
    /// `isDivisibleDecided`'s is now `divisiblePicked`, so three of each
    /// question's four old states carry over correct with no write at
    /// all. This fixes only the fourth.
    ///
    /// The four old Duration states and where each must land — the
    /// requirement being that **none silently reclassify**:
    /// - `decided=false` → never answered → `picked=false`, still
    ///   missing. Correct already via the rename.
    /// - `decided=true, yes=true, mins>0` → a real duration → stays
    ///   `picked=true` with its value. Correct already.
    /// - `decided=true, yes=false` → *deliberately* no duration, with
    ///   `estimatedMinutes` already forced to `0` by the old "No" branch
    ///   → `picked=true` + `0` now reads as the wheel's "None" option,
    ///   which is exactly the same meaning. Correct already.
    /// - `decided=true, yes=true, mins==0` → said Yes, never picked a
    ///   value; **reported missing under the old model** → must become
    ///   `picked=false` so it stays missing. **This is the only case
    ///   needing a write**, and the only one `estimatedMinutes` alone
    ///   can't identify (it shares `0` with the deliberately-None case
    ///   above) — which is precisely why `legacyDurationAnsweredYes`
    ///   survives the rename rather than being deleted outright.
    ///
    /// Divisible is the same four cases with `isDivisible` standing in
    /// for `answeredYes`. Since `isDivisible` is a *kept* field rather
    /// than a retired one, no `legacy...` companion is needed for it.
    ///
    /// Gate and idempotence work exactly as
    /// `migrateIncompleteBlocksAndMealsToThreeStateIfNeeded`'s do — a
    /// `UserDefaults` flag set only *after* `context.save()` succeeds (so
    /// an interrupted run retries rather than leaving a half-migrated
    /// store), plus a per-row `TaskItem.hasMigratedSingleWheel` committed
    /// in that same save, which is what actually makes a second pass a
    /// no-op regardless of whether the outer flag's write ever landed.
    static func migrateDurationDivisibleToSingleWheelIfNeeded(container: ModelContainer) {
        let flagKey = "didMigrateDurationDivisibleToSingleWheel.v1"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }

        let context = ModelContext(container)
        if let tasks = try? context.fetch(FetchDescriptor<TaskItem>()) {
            for task in tasks where !task.hasMigratedSingleWheel {
                if task.durationPicked, task.legacyDurationAnsweredYes, task.estimatedMinutes == 0 {
                    task.durationPicked = false
                }
                if task.divisiblePicked, task.isDivisible, task.minimumSegmentMinutes == 0 {
                    task.divisiblePicked = false
                }
                task.hasMigratedSingleWheel = true
            }
        }
        do {
            try context.save()
            UserDefaults.standard.set(true, forKey: flagKey)
        } catch {
            // Leave the flag unset so this retries next launch. Safe to
            // retry — see this function's own doc comment on idempotence.
        }
    }

    /// The actual per-row decision `migrateIncompleteBlocksAndMealsToThreeStateIfNeeded`
    /// applies to a block or meal — pulled out as its own pure function
    /// (rather than left inline in that one-shot, `UserDefaults`-flag-gated
    /// orchestration function) so it's unit-testable on its own, the same
    /// reason `ScheduleReviewViewModel.recurringTaskOccurrenceStatus` is a
    /// standalone function instead of inline view logic. See that
    /// function's own doc comment for the full reasoning behind the
    /// three-way split.
    static func migratedDatedStatus(legacyIsCompleted: Bool, ownDay: Date, now: Date) -> OccurrenceStatus {
        if legacyIsCompleted { return .complete }
        return ownDay < now ? .missed : .none
    }

    /// The `TaskItem` counterpart — two-way, not three-way. See
    /// `migrateIncompleteBlocksAndMealsToThreeStateIfNeeded`'s own doc
    /// comment for why a bare task gets no `.missed` verdict from this
    /// migration at all.
    static func migratedUndatedStatus(legacyIsCompleted: Bool) -> OccurrenceStatus {
        legacyIsCompleted ? .complete : .none
    }

    /// Walks `occurrence.currentDate` forward one day at a time, up to
    /// (not including) `today`, via `PushedRecurringOccurrence.advanceOneHop`
    /// — stopping the instant a hop resolves the occurrence (a real
    /// recurrence day for `task` was reached), or once it catches up to
    /// `today` still unresolved. Returns whether anything actually
    /// changed, so the caller only bothers saving when it did. Deliberately
    /// never consults `recurrenceEndDate` — see `PushedRecurringOccurrence`'s
    /// own doc comment for why an already-missed occurrence keeps pushing
    /// regardless.
    ///
    /// `advanceOneHop` is shared with `NightlyReviewView`'s today→tomorrow
    /// `Task`, which calls it once, synchronously, for a miss just detected
    /// tonight — this loop is what still exists for catching up a
    /// multi-day gap (the app not opened for several days), one hop per
    /// day via the exact same function, not a second implementation of it.
    private static func advanceOneDay(_ occurrence: PushedRecurringOccurrence, task: TaskItem, today: Date, calendar: Calendar, context: ModelContext) -> Bool {
        var cursor = calendar.startOfDay(for: occurrence.currentDate)
        var changed = false
        while cursor < today {
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            let resolved = PushedRecurringOccurrence.advanceOneHop(occurrence, task: task, from: cursor, to: next, calendar: calendar, context: context)
            changed = true
            if resolved { return true }
            cursor = next
        }
        return changed
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
            // `InboxItem` is legacy-only (kept solely so a pre-existing
            // store still opens) and keeps its own original field name —
            // only the destination renamed. See `TaskItem.durationPicked`.
            task.durationPicked = item.durationDecided
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
