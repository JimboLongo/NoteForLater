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
        DiagFileLog.markLaunch()
        Self.purgeSyntheticTestHabitLogs(container: sharedModelContainer)
        Self.auditDuplicateHabitLogs(container: sharedModelContainer)
        Self.repairDuplicateHabitLogsIfNeeded(container: sharedModelContainer)
        Self.backfillRemainingMinutesIfNeeded(container: sharedModelContainer)
        Self.repairDrainedRemainingMinutesIfNeeded(container: sharedModelContainer)
    }

    /// TEMP cleanup — deletes the `HabitLog`s created on 2026-08-27 by the
    /// Experiment 3 burst. That day is synthetic: it was tapped into
    /// existence purely to exercise the creation path on a date with no
    /// saved log, and counting it would inflate every duplicate total and
    /// corrupt the repair migration's input. Scoped to exactly that one
    /// day so no organic data is reachable. Runs before the audit so the
    /// totals it prints are already post-purge. Remove with the rest of
    /// the instrumentation.
    private static func purgeSyntheticTestHabitLogs(container: ModelContainer) {
        let calendar = Calendar.current
        let context = ModelContext(container)
        // Every date tapped into existence purely to exercise a code path.
        // 08-27: the Experiment 3 creation bursts. 08-30: the Part C
        // detail-calendar creation test. Each is scoped to exactly one day
        // so no organic data is reachable, and the whole thing is
        // idempotent — it reports "nothing to delete" once clean.
        for day in [(2026, 8, 27), (2026, 8, 30)] {
            var components = DateComponents()
            components.year = day.0
            components.month = day.1
            components.day = day.2
            guard let start = calendar.date(from: components).map({ calendar.startOfDay(for: $0) }),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { continue }
            let label = ISO8601DateFormatter().string(from: start).prefix(10)
            let descriptor = FetchDescriptor<HabitLog>(predicate: #Predicate { $0.date >= start && $0.date < end })
            guard let doomed = try? context.fetch(descriptor), !doomed.isEmpty else {
                DiagFileLog.write("PURGE \(label): nothing to delete")
                continue
            }
            let summary = Dictionary(grouping: doomed) { $0.habit?.name ?? "<orphan>" }
                .sorted { $0.key < $1.key }
                .map { "\($0.key)×\($0.value.count)" }
                .joined(separator: " ")
            for log in doomed { context.delete(log) }
            try? context.save()
            DiagFileLog.write("PURGE \(label): deleted \(doomed.count) logs [\(summary)]")
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

    /// TEMP dry run for the repair migration — computes exactly what
    /// `HabitLogMerge` would write, and writes nothing.
    ///
    /// Derived fresh at run time from the live store, never from earlier
    /// counts: `HabitDetailView.deduplicateLogs` mutates this data whenever
    /// a habit's detail screen opens, so any figure computed in a previous
    /// session is already stale. The real migration must re-derive the same
    /// way immediately before applying.
    ///
    /// Every changed occurrence is labelled:
    ///
    /// - **RESTORE** — currently reads `.missed`, merges to `.complete`.
    ///   A sibling row kept a completion that the nightly sweep had
    ///   overwritten. These are recoveries of real user actions.
    /// - **FLIP** — any other change. Reviewed individually.
    ///
    /// The label is computed from present state only (current displayed
    /// value vs merged value) and does not depend on knowing which row is
    /// older — which is unknowable, since `lastModified` is `.distantPast`
    /// on every pre-existing row.
    private static func previewHabitLogRepair(habits: [Habit], calendar: Calendar) {
        var restoreCount = 0
        var flipCount = 0
        var daysTouched = 0
        var logsDeleted = 0
        var onDiskOnlyCount = 0

        for habit in habits.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            let byDay = Dictionary(grouping: habit.logs ?? []) { calendar.startOfDay(for: $0.date) }
            for (day, logs) in byDay.sorted(by: { $0.key < $1.key }) {
                // What a read returns today: the same row `log(on:context:)`
                // would pick, so the "before" column matches what the user
                // actually sees right now.
                guard let current = logs.max(by: { $0.lastModified < $1.lastModified }) else { continue }
                let indices = Set(logs.flatMap { $0.completedOccurrences + $0.missedOccurrences + $0.excusedOccurrences })
                guard !indices.isEmpty else { continue }

                var lines: [String] = []
                for index in indices.sorted() {
                    let before = current.occurrenceStatus(index)
                    let after = HabitLogMerge.resolvedStatus(for: index, across: logs)
                    guard before != after else { continue }
                    let isRestore = (before == .missed && after == .complete)
                    if isRestore { restoreCount += 1 } else { flipCount += 1 }
                    lines.append("occ\(index) \(before)->\(after) \(isRestore ? "RESTORE" : "FLIP")")
                }
                // On-disk-only rewrites: a log already corrupted by the
                // old union holds an index in two arrays at once.
                // `occurrenceStatus` reports only the first match, so the
                // displayed value is unchanged by normalising it — but the
                // row IS rewritten, and any code reading
                // `missedOccurrences`/`excusedOccurrences` directly (streak,
                // rolling-30) stops double-counting. Reported here so the
                // preview is self-contained rather than needing a caveat
                // alongside it.
                for log in logs {
                    let c = Set(log.completedOccurrences)
                    let m = Set(log.missedOccurrences)
                    let e = Set(log.excusedOccurrences)
                    let overlap = c.intersection(m).union(c.intersection(e)).union(m.intersection(e))
                    guard !overlap.isEmpty else { continue }
                    for index in overlap.sorted() {
                        let kept = HabitLogMerge.resolvedStatus(for: index, across: logs)
                        lines.append("occ\(index) arrays overlap \(overlap.sorted()) -> keeps \(kept) only, ON-DISK-ONLY (no visible change)")
                        onDiskOnlyCount += 1
                    }
                }

                let extras = logs.count - 1
                guard !lines.isEmpty || extras > 0 else { continue }
                daysTouched += 1
                logsDeleted += extras
                let dayLabel = ISO8601DateFormatter().string(from: day).prefix(10)
                let changeText = lines.isEmpty ? "no occurrence change" : lines.joined(separator: ", ")
                DiagFileLog.write("  PREVIEW \(habit.name) \(dayLabel) rows=\(logs.count) deletes=\(extras) :: \(changeText)")
            }
        }
        DiagFileLog.write("PREVIEW TOTAL daysTouched=\(daysTouched) logsDeleted=\(logsDeleted) restorations=\(restoreCount) flips=\(flipCount) onDiskOnly=\(onDiskOnlyCount)")
    }

    /// TEMP audit — habit-tap investigation. Counts habits carrying more
    /// than one `HabitLog` for the same calendar day. Nothing enforces
    /// one-per-day (no uniqueness constraint; six separate non-atomic
    /// check-then-create sites), so this measures whether the invariant
    /// several call sites assume actually holds. Remove with the rest of
    /// the instrumentation.
    private static func auditDuplicateHabitLogs(container: ModelContainer) {
        let context = ModelContext(container)
        // The auditor's own context id, so a pulled log shows whether the
        // auditor is itself a distinct graph from any of the writers —
        // if every CREATE line carries a different ctx than this, the
        // audit may be reading a merged view the writers never saw.
        DiagFileLog.write("DUPAUDIT ctx=\(HabitLogDiag.contextTag(context)) (auditor's own ModelContext)")
        guard let habits = try? context.fetch(FetchDescriptor<Habit>()) else { return }
        // Full roster, so timesPerDay/time-modes are on record for every
        // habit rather than only the ones that happen to have duplicates
        // — a second occurrence in a different time mode renders in a
        // different section of the day, which changes what "tapping
        // different rows" can mean.
        for habit in habits.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            let modes = (0..<max(habit.timesPerDay, 1)).map { "\(habit.timeMode(for: $0))" }.joined(separator: ",")
            DiagFileLog.write("ROSTER habit=\(habit.name) timesPerDay=\(habit.timesPerDay) modes=\(modes) logs=\(habit.logs?.count ?? 0)")
        }
        let calendar = Calendar.current
        var affectedHabits = 0
        var duplicateDays = 0
        var extraLogs = 0
        for habit in habits {
            let logs = habit.logs ?? []
            let byDay = Dictionary(grouping: logs) { calendar.startOfDay(for: $0.date) }
            let dupes = byDay.filter { $0.value.count > 1 }
            guard !dupes.isEmpty else { continue }
            affectedHabits += 1
            duplicateDays += dupes.count
            extraLogs += dupes.values.reduce(0) { $0 + $1.count - 1 }
            let detail = dupes
                .sorted { $0.key < $1.key }
                .map { "\(ISO8601DateFormatter().string(from: $0.key).prefix(10))×\($0.value.count)" }
                .joined(separator: " ")
            DiagFileLog.write("DUPAUDIT habit=\(habit.name) timesPerDay=\(habit.timesPerDay) modes=\((0..<max(habit.timesPerDay, 1)).map { "\(habit.timeMode(for: $0))" }.joined(separator: ",")) logs=\(logs.count) dupDays=\(dupes.count) [\(detail)]")
            // Per-row contents for each duplicated day, in relationship
            // order — shows whether completions are scattered one-per-row
            // (which would mean each tap wrote to its own fresh log), and
            // whether `.first` and `.last` disagree about that day's
            // state, i.e. whether switching the scan direction changed
            // what the user sees.
            for (day, rows) in dupes.sorted(by: { $0.key < $1.key }) {
                let dayLabel = ISO8601DateFormatter().string(from: day).prefix(10)
                let perRow = rows.map { "\($0.id.uuidString.prefix(8)):c\($0.completedOccurrences.sorted())m\($0.missedOccurrences.sorted())e\($0.excusedOccurrences.sorted())" }
                DiagFileLog.write("  DUPROWS \(habit.name) \(dayLabel) \(perRow.joined(separator: " | "))")
                let firstRow = rows.first
                let lastRow = rows.last
                let firstSet = Set(firstRow?.completedOccurrences ?? [])
                let lastSet = Set(lastRow?.completedOccurrences ?? [])
                if firstSet != lastSet {
                    let union = firstSet.union(lastSet).sorted()
                    DiagFileLog.write("  DUPDIFF \(habit.name) \(dayLabel) first=\(firstSet.sorted()) last=\(lastSet.sorted()) union=\(union) VISIBLE-CHANGE")
                }
            }
        }
        DiagFileLog.write("DUPAUDIT TOTAL habits=\(habits.count) affected=\(affectedHabits) dupDays=\(duplicateDays) extraLogs=\(extraLogs)")

        // Invariant sweep, across EVERY log rather than only duplicated
        // days: `HabitLog`'s own contract is that each occurrence index
        // sits in at most one of the three arrays. `deduplicateLogs`
        // unions all three, so any day it has already merged with
        // conflicting statuses now violates that — and `occurrenceStatus`
        // masks it by checking completed first, so it reads fine while
        // streak/rolling-30 math reading `missedOccurrences` directly
        // double-counts. This says whether the repair has to fix
        // already-merged single logs too, not just collapse duplicates.
        var violatingLogs = 0
        var violatingHabits = 0
        for habit in habits {
            var habitHasViolation = false
            for log in habit.logs ?? [] {
                let c = Set(log.completedOccurrences)
                let m = Set(log.missedOccurrences)
                let e = Set(log.excusedOccurrences)
                let overlaps = c.intersection(m).union(c.intersection(e)).union(m.intersection(e))
                guard !overlaps.isEmpty else { continue }
                violatingLogs += 1
                habitHasViolation = true
                let dayLabel = ISO8601DateFormatter().string(from: calendar.startOfDay(for: log.date)).prefix(10)
                DiagFileLog.write("  INVARIANT habit=\(habit.name) \(dayLabel) logID=\(log.id.uuidString.prefix(8)) overlap=\(overlaps.sorted()) c=\(c.sorted()) m=\(m.sorted()) e=\(e.sorted())")
            }
            if habitHasViolation { violatingHabits += 1 }
        }
        DiagFileLog.write("INVARIANT TOTAL violatingHabits=\(violatingHabits) violatingLogs=\(violatingLogs)")
        previewHabitLogRepair(habits: habits, calendar: calendar)

        // TEMP Part C readiness check. Both halves of that test go vacuous
        // if a log already exists for the target habit+day — it becomes the
        // `found` path instead of the creation path. Reports the exact
        // preconditions rather than assuming them.
        let todayStart = calendar.startOfDay(for: .now)
        var partCComponents = DateComponents()
        partCComponents.year = 2026
        partCComponents.month = 8
        partCComponents.day = 30
        let targetDay = calendar.date(from: partCComponents).map { calendar.startOfDay(for: $0) }
        for habit in habits.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            let todayLogs = Habit.sameDayLogs(habitID: habit.id, day: todayStart, context: context, calendar: calendar)
            let futureLogs = targetDay.map { Habit.sameDayLogs(habitID: habit.id, day: $0, context: context, calendar: calendar) } ?? []
            let todayState = todayLogs.isEmpty
                ? "NO LOG (creation path reachable)"
                : "log exists status=\((0..<max(habit.timesPerDay, 1)).map { "\(todayLogs[0].occurrenceStatus($0))" }.joined(separator: ","))"
            // A tappable target for the HabitDetailView half: that screen
            // gates on `isApplicable && !isFuture && !isBeforeStart`, so a
            // future date is inert — the first attempt at this test tapped
            // 2026-08-30 and nothing happened at all. Find the most recent
            // PAST applicable day with no log, which is what actually
            // exercises the creation path there.
            var tappableTarget = "none found in last 60d"
            for back in 1...60 {
                guard let candidate = calendar.date(byAdding: .day, value: -back, to: todayStart) else { continue }
                guard candidate >= calendar.startOfDay(for: habit.startDate) else { break }
                guard habit.isApplicable(on: candidate, calendar: calendar) else { continue }
                guard Habit.sameDayLogs(habitID: habit.id, day: candidate, context: context, calendar: calendar).isEmpty else { continue }
                tappableTarget = String(ISO8601DateFormatter().string(from: candidate).prefix(10))
                break
            }
            DiagFileLog.write("  PARTC habit=\(habit.name) today=\(todayState) 2026-08-30=\(futureLogs.isEmpty ? "clean" : "\(futureLogs.count) LOG(S) PRESENT") tappablePastDayWithNoLog=\(tappableTarget)")
        }

        // Ceiling census for sweep damage. `markUnresolvedHabitOccurrences
        // AsMissed` overwrites in place, so an overwritten completion is
        // byte-identical to a genuine miss — nothing here distinguishes
        // them. This is therefore an **upper bound**, not an estimate: the
        // population sweep damage must live inside, never a count of it.
        // Reported per-day-across-habits as well as per-habit, because the
        // four known-damaged days all landed on one date (2026-08-18) —
        // if misses cluster on a few dates, the damage is localized to
        // those nights rather than smeared across the history.
        var missDaysByDate: [Date: Set<String>] = [:]
        var missDayCountByHabit: [String: Int] = [:]
        var totalMissDays = 0
        for habit in habits {
            var daysWithMiss = Set<Date>()
            for log in habit.logs ?? [] where !log.missedOccurrences.isEmpty {
                daysWithMiss.insert(calendar.startOfDay(for: log.date))
            }
            guard !daysWithMiss.isEmpty else { continue }
            missDayCountByHabit[habit.name] = daysWithMiss.count
            totalMissDays += daysWithMiss.count
            for day in daysWithMiss {
                missDaysByDate[day, default: []].insert(habit.name)
            }
        }
        for (name, count) in missDayCountByHabit.sorted(by: { $0.value > $1.value }) {
            DiagFileLog.write("  MISSCEIL habit=\(name) daysWithMiss=\(count)")
        }
        // Dates where several habits are missed at once — the shape a
        // single sweep run leaves behind.
        let clustered = missDaysByDate.filter { $0.value.count >= 2 }.sorted { $0.key < $1.key }
        for (day, names) in clustered {
            let label = ISO8601DateFormatter().string(from: day).prefix(10)
            DiagFileLog.write("  MISSCLUSTER \(label) habits=\(names.count) [\(names.sorted().joined(separator: " "))]")
        }
        DiagFileLog.write("MISSCEIL TOTAL habitDaysWithMiss=\(totalMissDays) distinctDates=\(missDaysByDate.count) datesWith2PlusHabits=\(clustered.count)")

        // Flag/log drift census, both directions. Load-bearing for
        // sequencing the sweep guard: dropping the `!block.isCompleted`
        // check means DRIFT_FLAG_AHEAD rows (flag says complete, log says
        // unresolved) stop being skipped and get marked `.missed` on the
        // next sweep. DRIFT_LOG_AHEAD rows (log resolved, flag not) are
        // the ones the old sweep was overwriting.
        var flagAhead = 0      // block.isCompleted true, log .none
        var logAhead = 0       // log resolved, block.isCompleted false
        for habit in habits {
            for block in habit.scheduledBlocks ?? [] {
                let day = calendar.startOfDay(for: block.date)
                let log = Habit.sameDayLogs(habitID: habit.id, day: day, context: context, calendar: calendar)
                    .max(by: { $0.lastModified < $1.lastModified })
                let status = log?.occurrenceStatus(block.habitOccurrenceIndex) ?? .none
                let dayLabel = ISO8601DateFormatter().string(from: day).prefix(10)
                if block.isCompleted, status == .none {
                    flagAhead += 1
                    DiagFileLog.write("  DRIFT_FLAG_AHEAD habit=\(habit.name) \(dayLabel) occ=\(block.habitOccurrenceIndex) flag=true log=none -> WILL BECOME MISSED")
                } else if !block.isCompleted, status == .complete {
                    logAhead += 1
                    DiagFileLog.write("  DRIFT_LOG_AHEAD habit=\(habit.name) \(dayLabel) occ=\(block.habitOccurrenceIndex) flag=false log=complete -> was being overwritten")
                }
            }
        }
        DiagFileLog.write("DRIFT TOTAL flagAheadWillFlipToMissed=\(flagAhead) logAheadWasBeingOverwritten=\(logAhead)")
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
