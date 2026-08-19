# Diagnose: `remainingMinutes` drains to zero on incomplete tasks

Plan for Claude Code. Verified against HEAD (`66238a7`) and a pull of the real device SwiftData store.

**This is a diagnostic plan. Do not implement a fix or a data migration until the finding is reported back.** Four hypotheses in this investigation have been wrong (approved/locked retention, `startDate`, the packer loop as sole cause, recurring-task overlap). The device store settled the last question in minutes where inference had failed repeatedly — prefer measurement here too.

Do the safety-net fix (`needs-duration-visibility-plan.md`) **first**. It makes this class of bug self-reporting.

## Confirmed symptom

Two incomplete tasks with `estimatedMinutes = 120` and `remainingMinutes = 0`:

- **Investigate Sub Item IDs** — `pushedCount = 2`, still holds one proposed unlocked block (Aug 20, 9:00–11:00).
- **Overage calc** — `pushedCount = 3`, no blocks at all.

Neither is completed. `remainingMinutes` reaching 0 means the scheduler believes all their work is placed or done, which is false.

The nonzero `pushedCount` on both says they have been through the clear-and-reschedule cycle repeatedly. A small leak per cycle lands exactly here.

## What is supposed to prevent this

`restoreRemainingMinutes(for:)` (`ScheduleReviewViewModel.swift` ~line 1506):

```
task.remainingMinutes = min(task.estimatedMinutes, task.remainingMinutes + block.durationMinutes)
```

Called by the three clear paths — `clearIncompletePastBlocks`, `regenerateFromNow`'s forward-looking clear (~line 461), and `clearBlocksBeforeToday`. Every decrement of `remainingMinutes` should have a matching restore when its block is cleared without being completed.

So the drain means either a decrement happens with no matching restore, or a clear path deletes a block without calling `restoreRemainingMinutes`, or a restore runs against the wrong duration.

## Step 1 — Audit every write (static, no device needed)

Enumerate **every** site that writes `remainingMinutes`, and every site that deletes or detaches a `ScheduledBlock`. For each, record:

- What it sets it to, and from what.
- Whether it is paired with a block insert (decrement) or a block clear (restore).
- Whether any path deletes a block **without** calling `restoreRemainingMinutes`.

Specific things to check, each a plausible leak:

- **`block.task = nil` before delete.** All three clear paths explicitly nil the inverse to avoid a SwiftData crash. `restoreRemainingMinutes` reads `block.task`. **If the nil-ing happens before the restore in any path, the restore silently no-ops** — its `guard let task = block.task else { return }` fails. Check the ordering in each path individually; they were written at different times.
- **Approved/locked/completed blocks** are skipped by `regenerateFromNow`'s clear filter. If such a block is later deleted elsewhere, is its duration restored?
- **Double restore vs no restore** when a task has multiple blocks (divisible tasks do).
- **The `min(estimatedMinutes, …)` clamp** — correct against over-restore, but silently caps a legitimate restore if `estimatedMinutes` was edited downward after the block was placed. The snap-on-save validation in `ac86a0d` changes `estimatedMinutes`; check whether it also needs to reconcile `remainingMinutes`.
- **`deleteBlock`** (the single-swipe path) — does it restore?

Report the table before instrumenting anything. This audit alone may identify the leak.

## Step 2 — Instrument (only if step 1 is inconclusive)

Log every `remainingMinutes` write: task title, old value, new value, call site, and whether a block was inserted or cleared in the same operation. Log every `ScheduledBlock` delete with whether `restoreRemainingMinutes` was invoked and what `block.task` was at that moment (nil or not).

Then reproduce by running a Nightly Review advance on a day with overdue blocks — the operation that preceded the observed state.

**Report which of these the log shows:**

1. A clear path deleted a block and the restore no-opped because `block.task` was already nil.
2. A clear path deleted a block and never called `restoreRemainingMinutes` at all.
3. Something decremented `remainingMinutes` with no corresponding block insert.
4. The restore ran correctly but was clamped by `min(estimatedMinutes, …)`.
5. Not reproducible — report that, with whatever partial state the log shows.

## Step 3 — Fix and migrate (only after the finding is reported)

Once the leak is identified, the fix must cover **existing data**. The device store already holds at least two drained tasks; fixing the leak does not repair them.

Do not design the migration before the cause is known — the correct repair depends on whether the leak lost time at clear (recoverable from block durations) or at decrement (not recoverable, and the safe default is resetting `remainingMinutes` to `estimatedMinutes` for incomplete tasks with no blocks).

**Report the proposed migration before running it.** It writes to real user data.

## Out of scope

- The visibility fix — separate plan, do it first.
- The double-booking investigation — its step-1 reproduction was inconclusive (205 lines, clean walk pairing, zero inserts) because the affected tasks were invisible to the walk. Revisit it after this is fixed, since the earlier run proved nothing either way.
