# Explain why a task didn't fit (coarse)

Plan for Claude Code. Verified against HEAD (`99996ab`).

**Sequencing: do this after the divisibility fix (`divisibility-invariants-plan.md`) lands.** That fix removes the packer bug that currently strands tasks with unplaceable remainders, which today is a dominant cause of `.noContiguousSlot`. Building the explanations first means shipping UI that confidently explains a bug that's about to be deleted.

## What exists now

`ScheduleReviewViewModel.tasksThatDidNotFit` (added in `99996ab`) is a flat `[TaskItem]`, computed by `remainingSchedulableTasks(shelves:)` **after** the walk ends. It knows a task is still unscheduled and still passes `isEligible` + `canEverFit`, but retains nothing about what happened on any given day. The Calendar tab shows it as a non-interactive banner.

`SchedulingFitStatus` (`SchedulingRule.swift:26`) is **not** reusable here. It's a static judgment about a rule's caps, and its `exceedsConstraint` case is the At-Risk category that is explicitly *excluded* from `tasksThatDidNotFit` — every task in this list already returns `.fits`. The question here is dynamic: it could fit in principle, but no day in the horizon had room.

## Scope: coarse

**One reason per task per walk.** Do not thread per-day reporting out of `AISchedulingService.pack()` — it currently returns only placed blocks and leftovers, and changing that signature is the invasive option that was explicitly not chosen.

Derive the reason from lightweight stats accumulated during the walk instead.

## Implementation

### 1. Accumulate per-task stats during the walk

In both `autoPlaceEligibleTasks` and `regenerateFromNow`, accumulate a small per-shelf/per-rule tally as the loop runs. Nothing here needs the packer's internals:

- `eligibleDayCount` — days in the walk where the rule's effective window applied (weekday matched).
- `totalFreeMinutesOnEligibleDays` — sum of free-slot minutes on those days, after existing-block subtraction.
- `maxContiguousSlotMinutes` — the largest single free slot seen on any eligible day.
- `hitHorizon` — whether the walk stopped on `maxWalkDays` rather than on the stall counter or an empty backlog.

Keep this a plain struct built in the loop. It must not change placement behavior in any way.

### 2. Derive one reason per task

Add an enum (suggested `UnplacedReason`) and derive per task in `remainingSchedulableTasks`, checked in this **fixed priority order** so the result is deterministic and testable:

1. `.noEligibleDays` — `eligibleDayCount == 0`. The rule's window never applied in the horizon.
2. `.fewEligibleDays` — `eligibleDayCount` is small (suggest ≤ 3). Rare-window rules; distinct from (1) because the fix differs.
3. `.noFreeTime` — `totalFreeMinutesOnEligibleDays == 0`. Calendar genuinely full.
4. `.noContiguousSlot` — `maxContiguousSlotMinutes < requiredSegment`, where `requiredSegment` is `minimumSegmentMinutes` when divisible, else `remainingMinutes`. Free time exists but is too fragmented.
5. `.horizonReached` — `hitHorizon`. Viable days remained; the cap stopped the walk.
6. `.ruleBudgetFull` — the fallback. Free time and eligible days existed, but the rule's `maxTaskCount` / `maxMinutesPerTask` / `maxTotalMinutes` were consumed by other tasks.

Document the priority order in the enum's doc comment, including why the fallback is last: it's inferred by elimination, not measured, so anything measurable must be checked first.

Change `tasksThatDidNotFit` from `[TaskItem]` to a small pairing of task + reason. Keep it `private(set)`.

### 3. UI

Make the existing Calendar-tab banner tappable, opening a sheet listing each task with its reason and a **suggested action**:

- `.noEligibleDays` / `.fewEligibleDays` → widen the rule's schedule.
- `.noFreeTime` → the calendar is full in this window.
- `.noContiguousSlot` → lower the minimum segment size, or make the task divisible.
- `.horizonReached` → capacity; nothing is misconfigured.
- `.ruleBudgetFull` → raise the rule's cap, or reprioritize.

Write these as plain sentences naming the specific rule and number where available ("Personal — Weekday Evenings allows 3 tasks per day, already full on all 12 eligible days"), not bare enum labels.

Match existing sheet patterns rather than inventing new presentation. **Do not** add navigation into the rule editor from this sheet in this pass — if that seems warranted, report it rather than building it.

## Tests

- One test per reason: construct a fixture that isolates it and assert the derived reason.
- Priority order: a task satisfying **both** `.noContiguousSlot` and `.ruleBudgetFull` resolves to `.noContiguousSlot`. This is the test that pins the ordering.
- A task that fits normally produces no entry.
- A task failing `canEverFit` still does **not** appear here (it belongs to At-Risk) — guards the boundary Claude Code identified in `99996ab`.
- Existing suite must still pass, including the `tasksThatDidNotFit` assertions in `test_autoPlaceEligibleTasks_neverWalksPastPrefetchWindow` and `test_unplaceableTask_reportedAsDidNotFit_withNoBlock`, updated for the new type but **not** weakened.

## Out of scope

- No changes to `pack()` or `place()` signatures or behavior.
- No changes to walk termination, `maxWalkDays`, or the stall counter.
- No changes to `SchedulingFitStatus` or the At-Risk path.
- No per-day breakdown in the UI — that's the precise version, deliberately not chosen.
