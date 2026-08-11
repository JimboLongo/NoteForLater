import Foundation
import SwiftData
import Observation

/// Drives the schedule review screen for a single day (default: today, but
/// navigable to any day) and every interaction the user has with a block:
/// delete (swipe left), auto-replace (swipe right), long-press to manually
/// replace, and — on today specifically — mark complete or push to another
/// day.
@Observable
final class ScheduleReviewViewModel {
    private let modelContext: ModelContext
    private let calendarService: CalendarServiceProtocol
    private let schedulingService: AISchedulingServiceProtocol

    private(set) var blocks: [ScheduledBlock] = []
    private(set) var calendarEvents: [CalendarEventSummary] = []
    var targetDate: Date
    var isGenerating = false
    var errorMessage: String?

    init(
        modelContext: ModelContext,
        calendarService: CalendarServiceProtocol,
        schedulingService: AISchedulingServiceProtocol,
        targetDate: Date = .now
    ) {
        self.modelContext = modelContext
        self.calendarService = calendarService
        self.schedulingService = schedulingService
        self.targetDate = targetDate
    }

    // MARK: - Generation (the nightly job)

    /// Builds tomorrow's proposed schedule from each shelf's SchedulingRules
    /// + free calendar slots. Called automatically each night (see
    /// NoteForLaterApp / TODO for BackgroundTasks wiring) and manually via
    /// a "Regenerate" button.
    func generateProposedSchedule(shelves: [Shelf], habits: [Habit], eligibleHoursWindows: [EligibleHoursWindow]) async {
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }

        // Generating always clears out anything left over from a day
        // before today first — see `clearBlocksBeforeToday`.
        await clearBlocksBeforeToday()

        // Resync against the calendar first so generation (and the events
        // shown alongside it) reflect anything added/changed since this
        // screen last loaded, rather than possibly-stale free/busy data.
        await loadCalendarEvents()

        do {
            let freeSlots = try await calendarService.fetchFreeSlots(for: targetDate)
            let proposed = try await schedulingService.generateProposedSchedule(
                shelves: shelves,
                habits: habits,
                freeSlots: freeSlots,
                eligibleHoursWindows: eligibleHoursWindows,
                date: targetDate
            )
            // The scheduler itself decides per-task whether to mark it fully
            // scheduled or just trim its remaining time (divisible tasks
            // that only got part of their time placed stay unscheduled).
            for block in proposed {
                modelContext.insert(block)
            }
            blocks = proposed.sorted { $0.startTime < $1.startTime }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Regenerate (from now, across as many days as it takes)

    /// Rebuilds the schedule starting from the next quarter-hour after
    /// whichever is later — right now, or the day currently on screen —
    /// never touching anything already in the past, and never touching an
    /// already-*approved* block anywhere (that's a real, pushed calendar
    /// event; the calendar's own free/busy already treats it as busy) —
    /// and keeps walking forward a day at a time until every eligible,
    /// currently-unscheduled task across every shelf has either been
    /// placed or genuinely can't ever fit anywhere. So tapping Regenerate
    /// while looking a few days ahead starts placing things there, not
    /// silently back on today — freeing up a batch of previous-day tasks
    /// (see `clearIncompletePastBlocks`) and regenerating while browsing a
    /// future day lands them starting from that day, not buried back on
    /// today where you're not even looking. A habit eligible for
    /// scheduling never "runs out" the way a shelf's task queue does — it
    /// recurs on every applicable day forever — so it keeps the walk going
    /// out to the full `maxDays` horizon on its own, rather than stopping
    /// the moment shelves empty out: that's the difference between a habit
    /// only showing up on whatever day happened to get generated versus
    /// showing up on every eligible day as you scroll the calendar
    /// forward.
    ///
    /// Every `ScheduledBlock` is fetched fresh from the store right here,
    /// rather than trusting a caller-supplied array — a caller that just
    /// finished deleting some (e.g. `clearIncompletePastBlocks`, or even a
    /// plain `deleteBlock` from a swipe moments earlier) would otherwise
    /// hand over a stale snapshot that still contains those now-deleted
    /// objects, and this function's own final `blocks = combined.filter
    /// { ... }` would silently resurrect them right back into view.
    func regenerateFromNow(shelves: [Shelf], habits: [Habit], eligibleHoursWindows: [EligibleHoursWindow]) async {
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }

        // Regenerating always clears out anything left over from a day
        // before today first — see `clearBlocksBeforeToday`.
        await clearBlocksBeforeToday()

        let calendar = Calendar.current
        let cutoff = Self.roundedUpToQuarterHour(max(targetDate, .now), calendar: calendar)
        // Completed task blocks are deliberately left alone here — they
        // stay on the shelf/calendar (faded, struck through) until Night
        // Time Review actually sweeps them; see `purgeCompletedBlocks`.
        let allBlocks = (try? modelContext.fetch(FetchDescriptor<ScheduledBlock>())) ?? []

        // A locked block is left alone entirely — same protection an
        // already-*approved* block gets, just for a reason the user chose
        // rather than the calendar push having already happened.
        var survivingBlocks = allBlocks
        for block in allBlocks where block.approvalStatus != .approved && !block.isLocked && block.startTime >= cutoff {
            block.task?.isScheduled = false
            // Explicitly clears the task/habit's to-one inverse before the
            // delete, rather than letting SwiftData's delete-rule nullify
            // sort it out on its own — otherwise a task picked up by a
            // *new* block later in this same run (before this delete has
            // actually settled) can find its `scheduledBlock` inverse
            // still claimed by the one being removed, which SwiftData
            // reports as a hard "relationship already has a value but
            // it's not the target" crash rather than silently overwriting it.
            block.task = nil
            block.habit = nil
            modelContext.delete(block)
            survivingBlocks.removeAll { $0.id == block.id }
        }
        // Flushed explicitly rather than left to autosave — the walk below
        // repeatedly reads relationships that touch these same objects
        // (e.g. `habit.scheduledBlocks`, inside `generateProposedSchedule`)
        // across many iterations without ever otherwise yielding back to
        // SwiftData, which could otherwise still be carrying this batch of
        // deletes as pending when that happens.
        try? modelContext.save()

        var cursorDay = calendar.startOfDay(for: cutoff)
        var dayIndex = 0
        let maxDays = 30 // a sane cap on how far out a single regenerate walks — see doc comment.
        var newBlocks: [ScheduledBlock] = []

        let keepWalking = hasSchedulableHabits(habits: habits)

        while dayIndex == 0 || (dayIndex < maxDays && (keepWalking || hasRemainingSchedulableWork(shelves: shelves))) {
            do {
                var freeSlots = try await calendarService.fetchFreeSlots(for: cursorDay)
                if dayIndex == 0 && calendar.isDateInToday(cursorDay) {
                    // Today only offers up whatever's still ahead of the
                    // cutoff — everything earlier is already past, so it's
                    // left alone regardless of what free/busy reports. This
                    // only makes sense when the walk's first day really is
                    // today: if it's a future day instead (regenerating
                    // while browsing tomorrow, say), `cutoff` still carries
                    // whatever time-of-day `targetDate` happened to have
                    // (it's never normalized to midnight) — clipping by it
                    // here would wrongly cut off tomorrow's whole morning
                    // instead of leaving the future day's full day open.
                    freeSlots = freeSlots.compactMap { slot in
                        let start = max(slot.start, cutoff)
                        return start < slot.end ? TimeSlot(start: start, end: slot.end) : nil
                    }
                }
                // An approved surviving block is already reflected in the
                // calendar's own free/busy above (it's really been pushed),
                // but a locked-while-still-proposed one hasn't — carve its
                // time back out manually so regeneration doesn't schedule
                // something new right on top of it.
                let lockedSurviving = survivingBlocks.filter {
                    $0.isLocked && $0.approvalStatus != .approved && calendar.isDate($0.date, inSameDayAs: cursorDay)
                }
                for locked in lockedSurviving {
                    freeSlots = subtracting(locked.startTime..<locked.endTime, from: freeSlots)
                }
                let dayBlocks = try await schedulingService.generateProposedSchedule(
                    shelves: shelves,
                    habits: habits,
                    freeSlots: freeSlots,
                    eligibleHoursWindows: eligibleHoursWindows,
                    date: cursorDay
                )
                for block in dayBlocks {
                    modelContext.insert(block)
                    newBlocks.append(block)
                }
            } catch {
                errorMessage = error.localizedDescription
                break
            }
            cursorDay = calendar.date(byAdding: .day, value: 1, to: cursorDay) ?? cursorDay
            dayIndex += 1
        }
        try? modelContext.save()

        let combined = survivingBlocks + newBlocks
        blocks = combined
            .filter { calendar.isDate($0.date, inSameDayAs: targetDate) }
            .sorted { $0.startTime < $1.startTime }

        await loadCalendarEvents()
    }

    /// Carves `occupied` out of `slots`, splitting or trimming whichever
    /// slot(s) it overlaps — used to protect a locked-but-not-yet-approved
    /// block's time during `regenerateFromNow`, the same way an approved
    /// block's time is already protected by the calendar's own free/busy.
    private func subtracting(_ occupied: Range<Date>, from slots: [TimeSlot]) -> [TimeSlot] {
        slots.flatMap { slot -> [TimeSlot] in
            guard occupied.lowerBound < slot.end, occupied.upperBound > slot.start else { return [slot] }
            var pieces: [TimeSlot] = []
            if occupied.lowerBound > slot.start {
                pieces.append(TimeSlot(start: slot.start, end: occupied.lowerBound))
            }
            if occupied.upperBound < slot.end {
                pieces.append(TimeSlot(start: occupied.upperBound, end: slot.end))
            }
            return pieces
        }.filter { $0.durationMinutes > 0 }
    }

    /// Whether any shelf still has an unscheduled task — the condition
    /// `regenerateFromNow` keeps walking forward for, so today running out
    /// of room pushes the overflow to tomorrow, and the day after that, and
    /// so on. Deliberately not scoped to "eligible for one of the shelf's
    /// rules, and could ever fit it": `AISchedulingService`'s tier-3
    /// catch-all pass will still pick up a task that was never marked
    /// eligible for any specific rule, or one whose duration only just
    /// fits once guessed — the walk needs to keep going for those too, not
    /// just the narrower rule-matched case. A task that's flat-out too
    /// long for a single day to ever hold isn't specially detected here
    /// anymore; the `maxDays` cap is still what stops the walk from
    /// running forever on something truly unplaceable.
    private func hasRemainingSchedulableWork(shelves: [Shelf]) -> Bool {
        shelves.contains { shelf in
            shelf.hasEnabledSchedulingRules && (shelf.tasks ?? []).contains { !$0.isScheduled }
        }
    }

    /// Whether the walk needs to keep going just because habits exist —
    /// every habit is assumed schedulable now (see `AISchedulingService`),
    /// so as long as there's at least one, *some* day ahead is bound to be
    /// applicable for it. Unlike `hasRemainingSchedulableWork`, this
    /// doesn't need to be re-checked per iteration: a habit doesn't get
    /// "used up" the way a shelf task does.
    private func hasSchedulableHabits(habits: [Habit]) -> Bool {
        !habits.isEmpty
    }

    /// Rounds up to the next quarter-hour — e.g. 10:35 -> 10:45, but 10:45
    /// exactly stays put (it's already on a boundary, not past one).
    private static func roundedUpToQuarterHour(_ date: Date, calendar: Calendar) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        let secondsIntoDay = date.timeIntervalSince(startOfDay)
        let quarterHour: TimeInterval = 15 * 60
        let roundedSeconds = (secondsIntoDay / quarterHour).rounded(.up) * quarterHour
        return startOfDay.addingTimeInterval(roundedSeconds)
    }

    // MARK: - Drag to reorder

    /// A movable row in the day's timeline: either a proposed block or an
    /// unlocked calendar event. Locked events are never passed in here —
    /// they're excluded entirely, keeping both their order and their time.
    enum TimelineEntryRef: Hashable {
        case block(UUID)
        case event(String)
    }

    /// Reorders the day's proposed blocks and unlocked calendar events to
    /// match `newOrder`, then repacks their times back-to-back in that new
    /// order, starting from the earliest slot in the group — each entry
    /// keeps its own duration, but later ones shift to close any gap the
    /// move opened up, and earlier ones get pushed later to make room.
    /// Locked events are excluded, so the group reshuffles only among
    /// itself rather than routing around fixed anchors. Any calendar event
    /// whose time actually changes gets pushed back to Google.
    func reorderTimeline(newOrder: [TimelineEntryRef]) {
        let blockLookup = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        let eventLookup = Dictionary(uniqueKeysWithValues: calendarEvents.map { ($0.id, $0) })

        let startTimes: [Date] = newOrder.compactMap { ref in
            switch ref {
            case .block(let id): return blockLookup[id]?.startTime
            case .event(let id): return eventLookup[id]?.start
            }
        }
        guard let anchor = startTimes.min() else { return }

        var cursor = anchor
        var updatedEvents: [CalendarEventSummary] = []

        for ref in newOrder {
            switch ref {
            case .block(let id):
                guard let block = blockLookup[id] else { continue }
                let duration = block.endTime.timeIntervalSince(block.startTime)
                if block.startTime != cursor {
                    block.startTime = cursor
                    block.endTime = cursor.addingTimeInterval(duration)
                    needsReapproval(block)
                }
                cursor = cursor.addingTimeInterval(duration)
            case .event(let id):
                guard let event = eventLookup[id] else { continue }
                let duration = event.end.timeIntervalSince(event.start)
                if event.start != cursor {
                    updatedEvents.append(CalendarEventSummary(id: event.id, title: event.title, start: cursor, end: cursor.addingTimeInterval(duration), notes: event.notes))
                }
                cursor = cursor.addingTimeInterval(duration)
            }
        }

        blocks = blocks.sorted { $0.startTime < $1.startTime }
        for updated in updatedEvents {
            if let idx = calendarEvents.firstIndex(where: { $0.id == updated.id }) {
                calendarEvents[idx] = updated
            }
        }
        guard !updatedEvents.isEmpty else { return }
        Task {
            for updated in updatedEvents {
                try? await calendarService.updateEvent(eventID: updated.id, title: updated.title, start: updated.start, end: updated.end, notes: updated.notes)
            }
        }
    }

    /// Moves a single unlocked block or calendar event to `newStart`
    /// (keeping its own duration), then shifts only the *other* unlocked
    /// entries that would now overlap it out of the way — cascading
    /// further if that opens a new overlap with their own neighbor.
    /// Anything that doesn't conflict keeps its exact original time, so
    /// gaps elsewhere in the day are preserved. This is what a drag on
    /// `DayTimelineGridView` commits — unlike `reorderTimeline` (driven by
    /// the old List's reorder, which always packed its whole group
    /// back-to-back with no gaps), dropping something back into the same
    /// slot it started in is a genuine no-op here rather than silently
    /// recomputing the same packed time and looking like it "snapped
    /// back." `unlockedOrder` is exactly the set of refs the caller
    /// considers movable — locked events are excluded from the ripple
    /// entirely, same as `reorderTimeline`.
    func moveEntry(_ dragged: TimelineEntryRef, to newStart: Date, among unlockedOrder: [TimelineEntryRef]) {
        let blockLookup = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        let eventLookup = Dictionary(uniqueKeysWithValues: calendarEvents.map { ($0.id, $0) })

        struct Entry {
            let ref: TimelineEntryRef
            var start: Date
            let duration: TimeInterval
        }

        var entries: [Entry] = unlockedOrder.compactMap { ref in
            switch ref {
            case .block(let id):
                guard let block = blockLookup[id] else { return nil }
                return Entry(ref: ref, start: block.startTime, duration: block.endTime.timeIntervalSince(block.startTime))
            case .event(let id):
                guard let event = eventLookup[id] else { return nil }
                return Entry(ref: ref, start: event.start, duration: event.end.timeIntervalSince(event.start))
            }
        }
        guard let draggedIndex = entries.firstIndex(where: { $0.ref == dragged }) else { return }
        entries[draggedIndex].start = newStart
        entries.sort { $0.start < $1.start }
        guard let pivotIndex = entries.firstIndex(where: { $0.ref == dragged }) else { return }

        // Ripple later: each subsequent entry starts no earlier than the
        // previous (already-resolved) entry ends.
        var cursor = entries[pivotIndex].start.addingTimeInterval(entries[pivotIndex].duration)
        if pivotIndex + 1 < entries.count {
            for i in (pivotIndex + 1)..<entries.count {
                if entries[i].start < cursor {
                    entries[i].start = cursor
                }
                cursor = entries[i].start.addingTimeInterval(entries[i].duration)
            }
        }

        // Ripple earlier: each preceding entry ends no later than the next
        // (already-resolved) entry starts.
        cursor = entries[pivotIndex].start
        if pivotIndex > 0 {
            for i in stride(from: pivotIndex - 1, through: 0, by: -1) {
                let end = entries[i].start.addingTimeInterval(entries[i].duration)
                if end > cursor {
                    entries[i].start = cursor.addingTimeInterval(-entries[i].duration)
                }
                cursor = entries[i].start
            }
        }

        var updatedEvents: [CalendarEventSummary] = []
        for entry in entries {
            switch entry.ref {
            case .block(let id):
                guard let block = blockLookup[id] else { continue }
                if block.startTime != entry.start {
                    block.startTime = entry.start
                    block.endTime = entry.start.addingTimeInterval(entry.duration)
                    needsReapproval(block)
                }
            case .event(let id):
                guard let event = eventLookup[id] else { continue }
                if event.start != entry.start {
                    updatedEvents.append(CalendarEventSummary(id: event.id, title: event.title, start: entry.start, end: entry.start.addingTimeInterval(entry.duration), notes: event.notes))
                }
            }
        }

        blocks = blocks.sorted { $0.startTime < $1.startTime }
        for updated in updatedEvents {
            if let idx = calendarEvents.firstIndex(where: { $0.id == updated.id }) {
                calendarEvents[idx] = updated
            }
        }
        guard !updatedEvents.isEmpty else { return }
        Task {
            for updated in updatedEvents {
                try? await calendarService.updateEvent(eventID: updated.id, title: updated.title, start: updated.start, end: updated.end, notes: updated.notes)
            }
        }
    }

    /// Saves a manual edit (title/time/notes) to a synced calendar event and
    /// pushes it back to Google.
    func saveEventEdit(_ updated: CalendarEventSummary) {
        if let idx = calendarEvents.firstIndex(where: { $0.id == updated.id }) {
            calendarEvents[idx] = updated
        }
        Task {
            try? await calendarService.updateEvent(eventID: updated.id, title: updated.title, start: updated.start, end: updated.end, notes: updated.notes)
        }
    }

    func loadExistingBlocks(_ existing: [ScheduledBlock]) {
        blocks = existing
            .filter { Calendar.current.isDate($0.date, inSameDayAs: targetDate) }
            .sorted { $0.startTime < $1.startTime }
    }

    /// Pulls existing calendar events for the day (with real titles) so the
    /// Schedule tab can show what's already blocked off, even before a
    /// schedule is generated. Failure (e.g. not signed in) just leaves this
    /// empty.
    func loadCalendarEvents() async {
        calendarEvents = (try? await calendarService.fetchEvents(for: targetDate)) ?? []
    }

    /// Switches which day is being reviewed and reloads both the stored
    /// blocks for that day and its calendar events.
    func changeTargetDate(to newDate: Date, existingBlocks: [ScheduledBlock]) async {
        targetDate = newDate
        loadExistingBlocks(existingBlocks)
        await loadCalendarEvents()
    }

    // MARK: - Approval

    /// Approves every block and pushes each to Google Calendar — creating
    /// a new event if it's never been pushed, or updating the same event
    /// in place if it has (so re-approving after an edit overwrites what's
    /// already there instead of duplicating it).
    func approveAll() {
        for block in blocks { block.approvalStatus = .approved }
        Task {
            for block in blocks {
                if let eventID = try? await calendarService.pushEvent(for: block) {
                    block.googleEventID = eventID
                }
            }
        }
    }

    func approve(_ block: ScheduledBlock) {
        block.approvalStatus = .approved
        Task {
            if let eventID = try? await calendarService.pushEvent(for: block) {
                block.googleEventID = eventID
            }
        }
    }

    // MARK: - Swipe left: delete, leave the slot open

    /// Removes the block entirely. The underlying task goes back to being
    /// unscheduled so it can be picked up on a future night. If it had
    /// already been pushed to the calendar, that event gets removed too.
    func deleteBlock(_ block: ScheduledBlock) {
        block.task?.isScheduled = false
        block.task?.pushedCount += 1
        if let eventID = block.googleEventID {
            Task { try? await calendarService.deleteEvent(eventID: eventID) }
        }
        // See the matching comment in `regenerateFromNow` — clears the
        // task/habit inverse explicitly before the delete so it can't be
        // left claiming this block once it's gone.
        block.task = nil
        block.habit = nil
        modelContext.delete(block)
        blocks.removeAll { $0.id == block.id }
    }

    // MARK: - Swipe right: auto-replace with another queued to-do

    /// Swaps the block's task for the next-best unscheduled to-do (by
    /// priority, then due date), keeping the same time slot. The bumped task
    /// goes back into the unscheduled queue. If the block was already
    /// approved, it drops back to "proposed" so it's clear this needs
    /// re-approval (and re-pushing) before it matches the calendar again.
    func autoReplace(_ block: ScheduledBlock, candidatePool: [TaskItem]) {
        let outgoing = block.task
        let replacement = nextCandidate(from: candidatePool, excluding: outgoing)

        outgoing?.isScheduled = false
        outgoing?.pushedCount += 1
        block.task = replacement
        replacement?.isScheduled = true
        needsReapproval(block)

        if let idx = blocks.firstIndex(where: { $0.id == block.id }) {
            blocks[idx] = block
        }
    }

    // MARK: - Long-press: manually pick the replacement

    /// Explicit version of autoReplace where the user chose the specific
    /// replacement task from a picker sheet.
    func manualReplace(_ block: ScheduledBlock, with newTask: TaskItem) {
        let outgoing = block.task
        outgoing?.isScheduled = false
        outgoing?.pushedCount += 1

        block.task = newTask
        newTask.isScheduled = true
        needsReapproval(block)

        if let idx = blocks.firstIndex(where: { $0.id == block.id }) {
            blocks[idx] = block
        }
    }

    private func needsReapproval(_ block: ScheduledBlock) {
        if block.approvalStatus == .approved {
            block.approvalStatus = .proposed
        }
    }

    // MARK: - Today: complete / push to another day

    /// The timeline's tap-to-complete circle goes through here rather than
    /// flipping `block.isCompleted` directly — same Habit Tracker sync
    /// `markComplete` does, but both directions: un-tapping a habit block
    /// also resets that day's log, so the Habit Tracker (and its rolling
    /// stats, which read straight from the log) never disagrees with what
    /// the calendar shows. A task-backed block instead syncs
    /// `task.isCompleted` (so the shelf row fades/strikes through) and a
    /// `TaskCompletionRecord` (so the Task Stats page has it even after
    /// `regenerateFromNow` eventually purges the task itself).
    func toggleComplete(_ block: ScheduledBlock) {
        block.isCompleted.toggle()
        if let task = block.task {
            task.isCompleted = block.isCompleted
            if block.isCompleted {
                upsertCompletionRecord(for: task)
            } else {
                removeCompletionRecord(for: task)
            }
        }
        guard let habit = block.habit else { return }
        // Only this block's own occurrence (BrushTeeth.1 vs .2, say) is
        // affected — the day-level status/streak/calendar stay pending
        // until every occurrence is resolved (see `Habit.status`).
        let status: OccurrenceStatus = block.isCompleted ? .complete : .none
        habitLog(for: habit, on: block.date).setOccurrence(block.habitOccurrenceIndex, to: status)
        // Rebuilds this habit's pending reminders from scratch, which
        // already skips any occurrence marked complete for its day — so
        // completing (or un-completing) right here immediately drops (or
        // restores) just that occurrence's own reminder, not the whole
        // habit's.
        HabitNotificationService.shared.reschedule(habit)
    }

    /// See `TaskCompletionRecord.upsert(for:in:)`.
    func upsertCompletionRecord(for task: TaskItem) {
        TaskCompletionRecord.upsert(for: task, in: modelContext)
    }

    /// See `TaskCompletionRecord.remove(for:in:)`.
    private func removeCompletionRecord(for task: TaskItem) {
        TaskCompletionRecord.remove(for: task, in: modelContext)
    }

    /// Night Time Review's own sweep — every block still marked complete
    /// gets removed from the calendar entirely, task and habit alike.
    /// Deliberately *not* part of `regenerateFromNow`: a completed block
    /// stays visible (faded, struck through) through ordinary regenerates,
    /// and is only actually cleared out once Night Time Review runs.
    /// A task block's shelf task is deleted too — its stats already live
    /// independently in `TaskCompletionRecord` (upserted again here just
    /// in case this is somehow the first place that's ever seen it as
    /// complete). A habit block instead just loses the block itself — the
    /// habit and its completion history live independently in
    /// `Habit`/`HabitLog`, already updated the moment it was checked off
    /// (see `toggleComplete`), so there's nothing left to capture here.
    func purgeCompletedBlocks() async {
        let allBlocks = (try? modelContext.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        for block in allBlocks {
            guard block.isCompleted else { continue }
            if let task = block.task {
                upsertCompletionRecord(for: task)
                if let eventID = block.googleEventID {
                    try? await calendarService.deleteEvent(eventID: eventID)
                }
                block.task = nil
                modelContext.delete(task)
                modelContext.delete(block)
                blocks.removeAll { $0.id == block.id }
            } else if block.habit != nil {
                if let eventID = block.googleEventID {
                    try? await calendarService.deleteEvent(eventID: eventID)
                }
                block.habit = nil
                modelContext.delete(block)
                blocks.removeAll { $0.id == block.id }
            }
        }
    }

    /// Run at the start of every generate/regenerate — clears out every
    /// block (task or habit) left over from a day before today, so old
    /// days never just keep silently piling up unreviewed. An
    /// incomplete task goes back to its shelf, unscheduled, ready to be
    /// picked up by a future generate; a completed one is removed
    /// entirely (task and block alike, same as
    /// `purgeCompletedBlocks`) once its stats snapshot is captured. A
    /// habit block is just deleted — the habit itself, and its own
    /// completion history, live independently in `Habit`/`HabitLog`.
    private func clearBlocksBeforeToday() async {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let allBlocks = (try? modelContext.fetch(FetchDescriptor<ScheduledBlock>())) ?? []
        for block in allBlocks where calendar.startOfDay(for: block.date) < today {
            if let task = block.task {
                if block.isCompleted {
                    upsertCompletionRecord(for: task)
                    modelContext.delete(task)
                } else {
                    task.isScheduled = false
                }
            }
            if let eventID = block.googleEventID {
                try? await calendarService.deleteEvent(eventID: eventID)
            }
            block.task = nil
            block.habit = nil
            modelContext.delete(block)
            blocks.removeAll { $0.id == block.id }
        }
        try? modelContext.save()
    }

    private func habitLog(for habit: Habit, on date: Date) -> HabitLog {
        let calendar = Calendar.current
        if let existing = habit.log(on: date, calendar: calendar) {
            return existing
        }
        let newLog = HabitLog(habit: habit, date: calendar.startOfDay(for: date))
        modelContext.insert(newLog)
        return newLog
    }

    // MARK: - Regenerate prompt: review vs. assume not completed

    /// Every not-yet-completed block from today or an earlier day, oldest
    /// first — the shared "what needs a decision" list for both Nightly
    /// Review's Today step and the Regenerate button's "Review Previous
    /// Events" option. A block still in the future (later today or beyond)
    /// isn't "done or not" yet, so it's never included here.
    static func reviewableBlocks(from allBlocks: [ScheduledBlock]) -> [ScheduledBlock] {
        allBlocks
            .filter { !$0.isCompleted && $0.startTime < .now }
            .sorted { $0.startTime < $1.startTime }
    }

    /// Whether regenerating should even bother asking — gated on whatever's
    /// already elapsed (any previous day in full, plus today up to right
    /// now — a block later today hasn't happened yet, so it's not
    /// "overdue"): if nothing's left over from before this exact moment,
    /// there's no meaningful difference between the two choices, so the
    /// prompt is skipped entirely and Regenerate just runs.
    static func hasIncompletePastBlocks(in allBlocks: [ScheduledBlock]) -> Bool {
        allBlocks.contains { !$0.isCompleted && $0.startTime < .now }
    }

    /// The merged timeline `DayTimelineGridView` actually renders: proposed
    /// blocks plus whatever's genuinely external on the calendar. A pushed
    /// block whose Google event has already synced back shows up in both
    /// `blocks` and `calendarEvents` — matched here by event ID, or by
    /// title as a fallback if the ID round-trip hasn't landed yet — and the
    /// external copy is dropped so it isn't double-rendered. Shared by
    /// `ScheduleReviewView` and `NightlyReviewView`'s Plan step, which both
    /// show the same kind of day.
    static func timelineRows(blocks: [ScheduledBlock], calendarEvents: [CalendarEventSummary]) -> [DayTimelineRow] {
        let blockTitles = Set(blocks.compactMap { block -> String? in
            guard block.task != nil || block.habit != nil else { return nil }
            return block.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        let blockEventIDs = Set(blocks.compactMap(\.googleEventID))
        let eventRows = calendarEvents
            .filter { event in
                !blockEventIDs.contains(event.id)
                    && !blockTitles.contains(event.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }
            .map(DayTimelineRow.event)
        let proposedRows = blocks.map(DayTimelineRow.proposed)
        return (eventRows + proposedRows).sorted { $0.startTime < $1.startTime }
    }

    /// "Assume Not Completed" — the fast alternative to reviewing each
    /// overdue block one at a time: unschedules every one of them (same as
    /// swiping it away in the review list) so a following
    /// `regenerateFromNow` is free to place them again starting from right
    /// now. Covers any previous day in full, plus today up to right now —
    /// not a block later today, which hasn't happened yet and isn't
    /// "not completed," just not-yet-due. Deliberately ignores the lock —
    /// an overdue leftover is exactly the kind of thing "Assume Not
    /// Completed" exists to sweep away regardless, unlike
    /// `regenerateFromNow`'s own routine forward-looking clear, which
    /// still respects it.
    /// Unlike `deleteBlock` (whose calendar-event removal is fire-and-forget
    /// — fine for a single swipe, where nothing downstream depends on it
    /// having landed yet), this `await`s each deletion: the caller always
    /// calls `regenerateFromNow` right after this, and that pulls fresh
    /// free/busy from the calendar to decide what's open — a pushed event
    /// that hasn't actually finished being deleted yet would still show
    /// that time as busy, and the freed task wouldn't actually get a slot
    /// back despite being unscheduled again.
    /// `cutoff` defaults to right now (the regular Regenerate flow's
    /// notion of "past"), but Nightly Review's Plan step passes its own —
    /// whichever day was picked in Choose Day, not real-now — so a task
    /// left unchecked there gets freed up for tomorrow's generation even
    /// when `reviewDate` isn't today.
    func clearIncompletePastBlocks(allBlocks: [ScheduledBlock], cutoff: Date = .now) async {
        let toClear = allBlocks.filter { !$0.isCompleted && $0.startTime < cutoff }
        for block in toClear {
            block.task?.isScheduled = false
            block.task?.pushedCount += 1
            if let eventID = block.googleEventID {
                try? await calendarService.deleteEvent(eventID: eventID)
            }
            // See the matching comment in `regenerateFromNow` — clearing
            // the inverse explicitly before the delete avoids a SwiftData
            // "relationship already has a value but it's not the target"
            // crash when a new block claims this same task/habit shortly
            // after (regenerateFromNow always runs right after this).
            block.task = nil
            block.habit = nil
            modelContext.delete(block)
            blocks.removeAll { $0.id == block.id }
        }
        // Flushed explicitly rather than left to autosave — the caller
        // always runs `regenerateFromNow` right after this, which does its
        // own heavy run of fetches/inserts/deletes and repeatedly reads
        // relationships (e.g. `habit.scheduledBlocks`) touching these same
        // objects; leaving this batch of deletes unsaved going into that
        // has been the difference between a clean regenerate and a crash.
        try? modelContext.save()
    }

    /// Tasks eligible to fill an empty/replaced slot: unscheduled, on a schedulable shelf.
    func unscheduledCandidates(from allTasks: [TaskItem], excluding block: ScheduledBlock) -> [TaskItem] {
        allTasks.filter { ($0.shelf?.hasEnabledSchedulingRules ?? false) && !$0.isScheduled && $0.id != block.task?.id }
    }

    /// Same, but for tapping an open slot on the timeline grid — there's no
    /// existing block/task to exclude yet.
    func unscheduledCandidates(from allTasks: [TaskItem]) -> [TaskItem] {
        allTasks.filter { ($0.shelf?.hasEnabledSchedulingRules ?? false) && !$0.isScheduled }
    }

    /// Same as `unscheduledCandidates(from:)`, but also includes unsorted
    /// Inbox tasks (no shelf at all) — used by the timeline's
    /// long-press-to-insert popover specifically, where you're manually
    /// placing something rather than picking from the auto-scheduler's own
    /// rule-gated candidate pool.
    func unscheduledCandidatesIncludingInbox(from allTasks: [TaskItem]) -> [TaskItem] {
        allTasks.filter { task in
            guard !task.isScheduled else { return false }
            guard let shelf = task.shelf else { return true }
            return shelf.hasEnabledSchedulingRules
        }
    }

    /// Creates a brand-new block for `task` at `startTime` — reached by
    /// tapping an open slot on the timeline grid and picking a candidate.
    /// Sized by the task's own estimated duration, or a 30-minute default
    /// if it doesn't have one, same fallback the AI Scheduler itself uses.
    func insertBlock(for task: TaskItem, startTime: Date) {
        let isEstimated = task.estimatedMinutes <= 0
        let minutes = isEstimated ? 30 : task.estimatedMinutes
        let endTime = startTime.addingTimeInterval(TimeInterval(minutes * 60))
        let block = ScheduledBlock(date: targetDate, startTime: startTime, endTime: endTime, task: task, isEstimatedDuration: isEstimated)
        modelContext.insert(block)
        task.isScheduled = true
        blocks.append(block)
        blocks.sort { $0.startTime < $1.startTime }
    }

    /// Same ordering AISchedulingService uses when picking tasks to
    /// generate a schedule: priority first, then whichever has been
    /// sitting on the shelf longest (oldest `createdAt` first), then due
    /// date as the final tiebreaker.
    private func nextCandidate(from pool: [TaskItem], excluding outgoing: TaskItem?) -> TaskItem? {
        pool
            .filter { ($0.shelf?.hasEnabledSchedulingRules ?? false) && !$0.isScheduled && $0.id != outgoing?.id }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority {
                    return priorityRank(lhs.priority) > priorityRank(rhs.priority)
                }
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt < rhs.createdAt
                }
                return (lhs.dueDate ?? .distantFuture) < (rhs.dueDate ?? .distantFuture)
            }
            .first
    }

    private func priorityRank(_ priority: Priority) -> Int {
        switch priority {
        case .high: return 3
        case .medium: return 2
        case .low: return 1
        case .unset: return 0
        }
    }
}
