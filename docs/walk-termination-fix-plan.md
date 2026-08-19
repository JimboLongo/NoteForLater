# Scheduling walk never terminates: recurring tasks defeat stall detection

Plan for Claude Code. Verified against HEAD (`176ab46`) plus the uncommitted step-1 diagnostics.

**This is a real, reproducible bug with a confirmed mechanism — not a hypothesis.** Reproduction: send a new task from the Inbox to the Personal shelf; it gets scheduled ~1046 days out.

## Root cause

`ScheduleReviewViewModel.autoPlaceEligibleTasks` line 198:

```
placedTaskBlockToday = newBlocks.contains { $0.task != nil }
```

and line 203:

```
consecutiveDaysWithoutTaskPlacement = placedTaskBlockToday ? 0 : consecutiveDaysWithoutTaskPlacement + 1
```

Recurring tasks are **tasks**, not habits — `AISchedulingService`'s fixed-time pass places them and their blocks have `task != nil`. Per that method's own doc comment, a recurring task's `isScheduled` is *deliberately never set*, so it is re-placed on **every** occurrence day, forever.

The threshold is `taskStallThresholdDays = 14`. A **weekly** recurring task therefore resets the counter every 7th day: the counter climbs 1…6, resets to 0, climbs 1…6, resets. **It never reaches 14, so stall detection can never fire.** A daily recurrence is not required — any recurrence more frequent than every 14 days is sufficient.

With stall detection permanently disabled, the only remaining terminator is `hasRemainingSchedulableWork(shelves:)` going false. That stays `true` while any unscheduled task passes `isEligible(for:)` + `canEverFit` for an enabled rule. So the walk crawls forward one day at a time until that task finally fits — 1046 days later. The task was never "scheduled far out" by intent; day 1046 is simply the first day it fit.

The same mechanism explains previously-observed blocks ~125 days out with a ~119-day gap.

`regenerateFromNow` (line ~513) has the identical counter logic and the same defect.

**Ruled out by inspection, do not re-investigate:**
- 2-Minute shelf tasks — `Shelf.swift:75-76`: rendered as an untimed checklist, never get scheduled blocks, cannot affect `placedTaskBlockToday`.
- Habits — excluded by the `task != nil` check.
- `startDate` — no task in the store has one.
- Approved/locked block retention — the observed blocks were neither.

## Fix

### 1. Recurring placements must not count as backlog progress
In **both** walks (`autoPlaceEligibleTasks` ~line 198 and `regenerateFromNow` ~line 513), exclude recurring tasks from the reset condition:

```
placedTaskBlockToday = newBlocks.contains { $0.task != nil && !($0.task?.isRecurring ?? false) }
```

Rationale to put in a comment at both sites: the counter measures progress on the *backlog*. A recurring task places itself on every occurrence day whether or not anything is stuck, so counting it as progress makes the counter measure recurrence frequency rather than backlog progress. `TaskItem.isRecurring` is the flag (`TaskItem.swift:162`).

### 2. Absolute walk ceiling (backstop)
Add a hard cap on `dayIndex` in both walks, checked in the `while` condition alongside the existing terms. Suggested: a new `private static let maxWalkDays`, set to `freeSlotPrefetchDays` (44) so the walk never exceeds the prefetch window and the per-day fallback path stops being reachable from these two walks.

This is defense in depth, not the fix — with #1 correct the cap should rarely bind. Its purpose is that any *future* condition which wrongly resets the counter degrades into a bounded miss rather than an unbounded crawl.

Do not delete the fallback path in `prefetchFreeSlots`' callers even if it becomes unreachable from these walks — `fetchFreeSlots(for:)` has other callers.

### 3. "Won't fit" instead of burying it (product decision — decided)
A task that cannot fit within the walk horizon must be left **unscheduled and surfaced**, not placed at whatever distant day it eventually fits. A block 1046 days out is functionally invisible and is what produced the earlier fossil blocks.

- When the walk ends with `hasRemainingSchedulableWork` still `true`, collect those tasks and expose them on the viewmodel (e.g. `private(set) var tasksThatDidNotFit: [TaskItem]`).
- Surface them in the UI as a "Won't fit" state on the shelf/task row and/or the Calendar tab. Match existing badge patterns in `ShelfListView` (see `showsScheduledBadge` / the green scheduled badge at lines 260-270) rather than inventing new visual language.
- Do **not** place a block for these tasks.

Keep the UI surfacing minimal and behind a clear seam — if it grows beyond a badge and a list, stop and report rather than expanding scope.

## Tests

- **Regression test for the root cause:** a shelf with one weekly recurring task plus one unscheduled task that can never fit any enabled rule. Assert `lastWalkDayCount <= maxWalkDays` — before the fix this walk is effectively unbounded. This is the test that would have caught the bug.
- Stall detection still fires at 14 days when the only placements are non-recurring (existing test `test_autoPlaceEligibleTasks_stallDetection_stopsAtThreshold_notOldFixedCap` should still pass unmodified).
- A recurring task alone on a shelf does not extend the walk past the cap.
- A task that doesn't fit lands in `tasksThatDidNotFit` and has **no** `scheduledBlocks`.
- Existing suite (51 tests at HEAD) must still pass.

`FakeCalendarService.freeSlotsProvider` (added in `176ab46`) is the mechanism for giving different days different availability — needed to construct the "fits only on a rare day" fixture.

## Sequencing note

The step-1 diagnostics from `docs/local-calendar-plan.md` are currently uncommitted in `ScheduleReviewViewModel.swift` and `CalendarService.swift`. Google sign-in has been restored and the calendar now populates, so **case 1 is resolved at its immediate cause**. Decide explicitly whether to keep, commit, or revert those diagnostics before starting this work — do not leave them entangled with this fix's diff.

`LocalCalendarService` (step 2 of that plan) is **not** a prerequisite for this fix and should not be bundled with it.
