# Divisible tasks: no orphan segments, no partial placements

Plan for Claude Code. Verified against HEAD (`99996ab`).

**Context:** this is the upstream cause of the "task that can never fit" condition the walk-termination fix (`99996ab`) bounded. That fix stopped the unbounded crawl; this one stops stranded tasks being created in the first place. Expect it to reduce how often the "won't fit" banner appears.

## Reported symptom

A 4-hour task, divisible into 2-hour segments: 3.5 hours gets scheduled on one day, and the remaining 30 minutes can never be placed anywhere, because no slot can hold a 2-hour segment for it. The task stays permanently unscheduled with `remainingMinutes = 30`.

## Root cause

`AISchedulingService.place(minutesNeeded:minimumSegment:isDivisible:in:)`, line 516:

```
let take = remaining >= minimumSegment ? min(remaining, slot.durationMinutes) : minimumSegment
```

`min(remaining, slot.durationMinutes)` takes **whatever the slot happens to hold**, not a multiple of `minimumSegment`. A 3.5-hour free slot therefore absorbs 3.5 hours of a 4-hour task, leaving a 30-minute remainder. Every later slot is gated by `guard slot.durationMinutes >= minimumSegment` (line 508), and 30 < 120, so the remainder is stranded permanently.

Because `hasRemainingSchedulableWork` still counts that task (it passes `canEverFit`), this is exactly the condition that drove the unbounded walk.

## Two invariants to enforce

### 1. Packer — segments must be whole multiples of `minimumSegmentMinutes`

In `place()`, floor the take to a multiple of the segment size:

```
let usable = (slot.durationMinutes / minimumSegment) * minimumSegment
let take = min(remaining, usable)
```

- A 3.5-hour slot with 2-hour segments yields 2 hours, not 3.5. The other 2 hours stay as a clean segment to place elsewhere.
- Skip the slot entirely when `usable == 0` (already covered by the existing `>= minimumSegment` guard, but keep both — they're guarding different things).
- **Remove the round-up branch** (`: minimumSegment`). With `remaining` always a multiple of the segment size, it can never be below it mid-placement, so that branch becomes unreachable. Don't leave dead code; note the removal in the commit message.
- The whole-task fast path (line 498, `slots.first(where: { $0.durationMinutes >= minutesNeeded })`) stays as-is. Placing all 4 hours in one block is valid and is explicitly wanted.

### 2. UI — only offer proper divisors of `estimatedMinutes`

`NightlyReviewView.divisibleSegmentOptions` (line 879) is currently a static `[15, 30, 45, 60, 90, 120, 240]`, offered regardless of the task's duration. That's how 45 becomes selectable for a 60-minute task.

Filter it to values that **evenly divide `estimatedMinutes` and are strictly less than it**:

- 45 min → `[15]`
- 60 min → `[15, 30]`
- 90 min → `[15, 30, 45]`
- 240 min → `[15, 30, 60, 120]`

`estimatedMinutes` itself is excluded — "one segment the size of the whole task" is what None already means.

The picker must recompute as duration changes, not just on appear.

**Durations with no valid options.** A 25- or 50-minute task has no divisor in the list. **Disable the divisible toggle and show a short explanation** — e.g. "A 25-minute task can't be split into even segments." Do not present an empty picker, and do not silently widen the option list to avoid the empty case.

The toggle must be visibly disabled with its reason stated, not merely switched off — a toggle that silently won't turn on reads as a broken control.

### 3. Re-validate and snap on save

`minimumSegmentMinutes` can go stale when `estimatedMinutes` changes afterwards. This is a **live path, not hypothetical**: `TaskCardSheet.swift:43` and `TaskReviewQueueSheet.swift:68` both reassign `estimatedMinutes` via `shelf.resolvedDuration(candidateMinutes:)` on a shelf move, and only clear `minimumSegmentMinutes` when the target shelf doesn't track duration at all.

Add one shared validation helper on `TaskItem` (so all call sites share a definition — the same reasoning behind `isSchedulableBacklog` in `99996ab`):

- If `!isDivisible`, force `minimumSegmentMinutes = 0`.
- If `isDivisible` and `minimumSegmentMinutes` doesn't evenly divide `estimatedMinutes`, **snap down to the largest valid divisor**.
- If no valid divisor exists, set `isDivisible = false` and `minimumSegmentMinutes = 0`.

Call it wherever `estimatedMinutes` or `isDivisible` is written: `TaskCardSheet` save (line ~176), `TaskCardSheet` shelf move (~43), `TaskReviewQueueSheet` shelf move (~68), `ShelfEditView` (~361), and the `NightlyReviewView` divisible controls (~1633-1675).

Snapping **down** rather than up so a task never silently gets a coarser chunking than the user chose.

**Interaction with the disabled toggle — don't lose a setting silently.** These two rules meet in one case: a task that is *already* divisible with segments set, whose `estimatedMinutes` is then edited to a value with no valid divisor (e.g. 60 with 30-minute segments, edited to 25). Validation clears `isDivisible` and `minimumSegmentMinutes`, so the user's existing choice is discarded by a duration edit they may not connect to it.

Surface this rather than doing it silently — the toggle should end up disabled with its explanation visible, so the state change is legible at the moment it happens. If making that legible requires more than the disabled toggle plus its explanatory text, stop and report rather than building alert/confirmation flow.

## Tests

- 4-hour task, 2-hour segments, a 3.5-hour free slot: places exactly 2 hours, leaves `remainingMinutes = 120`, no 30-minute orphan. **This is the regression test for the reported bug.**
- Same task with two separate 2-hour slots: places both, `remainingMinutes = 0`.
- Whole-task fast path still places 4 hours in one block when a 4-hour slot exists.
- Option filtering: 45 → `[15]`; 60 → `[15, 30]`; 240 → `[15, 30, 60, 120]`; 25 → `[]`.
- Snap-on-save: 60-min task with 30-min segments, duration edited to 45 → segments snap to 15. Edited to 25 → `isDivisible` false, segments 0.
- Shelf-move path specifically: task whose `estimatedMinutes` is changed by `resolvedDuration` gets its segments re-validated.
- Existing suite (54 tests at HEAD) must still pass. **If any existing test asserts a partial placement like the 3.5-hour case, that test encoded the bug — report it rather than quietly updating it.**

## Out of scope

- Do not change `SchedulingRule.canEverFit` / `fitStatus`. Misconfigured tasks (60 min against a 30-min-per-task cap) are a separate state surfaced through At-Risk, not through this.
- Do not adjust `maxWalkDays` or the walk logic.
- Do not change `DayTimelineGridView.swift:2044`'s drag-resize step, which reads `minimumSegmentMinutes` for a different purpose — flag it if it looks affected, but don't change it here.
