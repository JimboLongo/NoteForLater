# Scheduler double-books a time slot

Plan for Claude Code. Verified against HEAD (`66238a7`).

**Do not start step 2 until step 1's finding is reported back.** The root cause is genuinely unknown — the hypothesis below is the leading candidate, not a diagnosis. Two earlier hypotheses in this investigation (approved/locked block retention, and `startDate`) each looked plausible and were both wrong. Report before implementing.

## Symptom

Two rule-packed task blocks placed at **identical** start and end times (observed: "Investigate Sub Item IDs" and "Overage calc", both 9:00–11:00 AM on the same day). The user's position: the scheduler must never double-book automatically. Only a deliberate user drag may create an overlap.

Both tasks were **overdue** relative to their deadlines. Neither is recurring.

## Already ruled out — do not re-investigate

- **Recurring-task fixed-time placement** (`AISchedulingService.swift` ~line 354). Places unconditionally at its anchor and can overlap, but neither task here is recurring.
- **Habit overlap.** Habits are deliberately allowed to double-book, but both blocks are tasks (`task != nil`).
- **Within a single walk.** `autoPlaceEligibleTasks` lines 179–182 subtract that day's existing blocks from free slots, and `allBlocksNow` accumulates newly inserted blocks as the loop runs, so one pass cannot double-book itself.

## Leading hypothesis (unconfirmed)

**Two overlapping walk passes, neither seeing the other's inserts.**

Identical start *and* end times suggest two placements each taking the front of the same empty slot independently, rather than two tasks competing over fragmented free time.

There is **no concurrency guard** on the walks. `ScheduleReviewView` has no `isPlacing`/`isRunning` flag, and `syncSchedule()` (line ~233) is invoked from several independent `Task { }` blocks — lines 206, 313, 315, 371, 382, 393 — covering appear, day change, previous/next day, and go-to-today. `NightlyReviewView` separately drives its own `tomorrowViewModel` through `regenerateFromNow`.

Each walk calls `prefetchFreeSlots` up front and reads existing blocks at its own start. Two passes overlapping in time would each see 9:00 free and each place there.

The **overdue** detail may be relevant: `clearIncompletePastBlocks` unschedules overdue blocks, restores `remainingMinutes`, and sets `isScheduled = false`, and callers run `regenerateFromNow` immediately after. That's a second write path around the same tasks, and a plausible source of a second concurrent pass. Do not assume this — measure it.

## Step 1 — Diagnose (no behavior change)

Add temporary logging sufficient to answer *which pass inserted each block*:

- At **every** `modelContext.insert(block)` for a `ScheduledBlock`, log: task title, start/end time, and an identifier for the inserting call site (`autoPlaceEligibleTasks`, `regenerateFromNow`, `placeHabitsAndRecurringTasks`, drag/drop, etc).
- Give each walk invocation a short run ID (a `UUID` prefix is enough), logged at entry and exit and included in every insert line from that run. This is what distinguishes "one pass placed twice" from "two passes each placed once."
- Log entry/exit of `autoPlaceEligibleTasks` and `regenerateFromNow` with timestamps, so overlapping runs are visible as interleaved entry/exit pairs.
- Log `clearIncompletePastBlocks` entry/exit with the count cleared.

Then reproduce the double-booking on device and capture the log.

**Report which case, before writing any fix:**

1. **Two different run IDs each inserted one block at 9:00** → concurrency confirmed. Proceed to step 2.
2. **One run ID inserted both blocks** → concurrency is *not* the cause; the defect is inside a single walk's free-slot accounting, and the "ruled out" analysis above is wrong somewhere. Stop and report — step 2's guard would not fix this.
3. **The two blocks came from different call sites entirely** (e.g. one from a walk, one from a drag or a Nightly Review path) → report which. The fix depends on which pair.
4. **Not reproducible** → report that rather than guessing. Note whether the overdue-task condition was present, since that's the leading correlate.

## Step 2 — Fix (only after step 1 reports case 1)

### A. Serialize the walks
Add a guard so only one walk runs at a time per view model — an actor, a `Task` handle that later callers await, or an `isPlacing` flag that makes overlapping invocations wait rather than run concurrently.

**Waiting, not dropping.** A dropped sync means a day-change silently doesn't place anything, which is a worse bug than the one being fixed. If a queued-call approach turns out to need significant restructuring, stop and report rather than expanding scope.

Note `NightlyReviewView`'s `tomorrowViewModel` is a *separate* view model instance — a per-instance guard will not serialize across both. Report whether cross-instance serialization is needed rather than building a global singleton unprompted.

### B. Overlap invariant at insertion (do this regardless of root cause)
Nothing currently prevents inserting a task block overlapping an existing task block. Given several write paths and no guard, add a single check at the point of insertion:

- A **task** block must not be inserted where it overlaps an existing **task** block.
- Habit and recurring-task blocks are explicitly exempt — they're allowed to overlap by design (`AISchedulingService` ~lines 300-370), and that behavior must not change.
- User-initiated drags must remain able to create overlaps deliberately. Apply the invariant to **scheduler-initiated** placement only; do not route drag/drop through it.

This is defense in depth: it would have caught this the first time it occurred, and catches future causes regardless of mechanism.

## Tests

- Two concurrent `autoPlaceEligibleTasks` calls on the same view model produce no overlapping task blocks (the regression test for case 1).
- The overlap invariant rejects a scheduler-placed task block overlapping an existing task block.
- A habit block overlapping a task block is still allowed.
- A recurring task's fixed-anchor block overlapping a rule-packed task is still allowed (current intended behavior — do not change it in this pass).
- Existing suite (71 tests at HEAD) must still pass. **If an existing test asserts overlapping scheduler-placed task blocks, report it rather than updating it** — the same instruction that surfaced the encoded-bug test in `ac86a0d`.

## Out of scope

- Do not change recurring-task or habit overlap semantics. Whether a recurring task should be able to land on a rule-packed task is a real open question, but it is not this bug and the user has not decided it.
- Do not change walk termination, `maxWalkDays`, or the `UnplacedReason` work.
- Do not remove step 1's logging until the fix is confirmed on device.
