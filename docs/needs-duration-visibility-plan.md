# Tasks with zero remaining minutes fall through every list

Plan for Claude Code. Verified against HEAD (`66238a7`) **and against a pull of the real device SwiftData store**, not inference.

This is the safety-net fix. The underlying drain that produces `remainingMinutes = 0` is a **separate** bug with its own diagnostic plan (`remaining-minutes-drain-plan.md`) — do that one after this. Fix the invisibility first: it makes the next silent drop announce itself instead of requiring a database pull to find.

## Confirmed state (from the device store, not inferred)

Two incomplete tasks, both eligible for both Work rules:

| | Investigate Sub Item IDs | Overage calc |
|---|---|---|
| `estimatedMinutes` | 120 | 120 |
| `remainingMinutes` | **0** | **0** |
| `isDivisible` | true, 60-min segments | false |
| `isScheduled` | true | false |
| `scheduledBlocks` | 1 — Aug 20, 9:00–11:00, proposed, unlocked | none |
| `pushedCount` | 2 | 3 |
| In `tasksThatDidNotFit` | no | no |
| In At-Risk | no | no |

Neither is completed. Neither appears anywhere in the UI as needing attention.

## Root cause of the invisibility

`SchedulingRule.fitStatus` line 146: `guard estimatedMinutes > 0 else { return .needsDuration }`.

`hasRemainingSchedulableWork` and `remainingSchedulableTasks` both call `canEverFit(estimatedMinutes: task.remainingMinutes, …)`. With `remainingMinutes = 0` the guard returns `.needsDuration`, not `.fits`, so the task is excluded from **both** the scheduler's candidate pool **and** `tasksThatDidNotFit`. `isAtRisk` separately returns false (it requires `remainingMinutes > 0`). The task falls through every net.

**The asymmetry to fix.** `TaskItem.fitStatus(for:)` (`TaskItem.swift:329`) passes `estimatedMinutes`; the scheduler passes `remainingMinutes`. Same function, opposite verdicts for these tasks — 120 reads `.fits`, 0 reads `.needsDuration`. Any UI surface reading the former shows these as perfectly schedulable while the scheduler ignores them entirely.

`.needsDuration` means "misconfigured, tell someone." It is currently being treated as "skip quietly." That is the defect.

## Fix

### 1. Surface `.needsDuration` rather than swallowing it

A task that is incomplete, unscheduled or holding a block, and evaluates to `.needsDuration` against its rule must appear somewhere the user will see. The won't-fit banner and its detail sheet (added in `66238a7`) are the natural home — that surface exists precisely for "this task isn't getting scheduled and here's why."

- Add an `UnplacedReason` case for it (suggested `.needsDuration`), placed **first** in the derivation priority order. It's a measured configuration fact, not an inference, so it must precede the derived reasons.
- Its explanatory sentence should name the actual problem in plain language — that the task has no remaining time left to schedule despite not being finished — and distinguish it from a task that was never given a duration at all. **These two states produce the same enum case but need different sentences and different user actions**; use `estimatedMinutes > 0 && remainingMinutes == 0` to tell them apart.
- Do not change what `fitStatus` returns. The enum is correct; the handling of it is what's wrong.

### 2. Decide the `estimatedMinutes` vs `remainingMinutes` asymmetry deliberately

Do **not** unify the two call sites silently. They may be intentionally different — the scheduler asking "can the remaining work fit?" is a reasonable question distinct from "is this task well-configured?".

Audit every `fitStatus` / `canEverFit` call site, record which argument each passes and why, and **report the list** with a recommendation. Do not change any of them in this pass unless one is unambiguously wrong.

### 3. Stranded blocks

"Investigate Sub Item IDs" holds an Aug 20 9:00–11:00 block while `remainingMinutes = 0` — a block for work the scheduler believes is done, on a task nothing will touch. There may be others.

- Detect this state (`!isCompleted && remainingMinutes == 0 && !scheduledBlocks.isEmpty`) and surface it through the same banner.
- **Do not auto-delete these blocks.** The block may represent real work the user intends to do; deleting it silently repeats the class of bug being fixed. Surface, don't sweep.

## Tests

- A task with `estimatedMinutes = 120`, `remainingMinutes = 0`, incomplete, eligible for a rule appears in `tasksThatDidNotFit` with the `.needsDuration` reason. **This is the regression test — before the fix it appears nowhere.**
- A task with `estimatedMinutes = 0` (never configured) also surfaces, with the *different* sentence.
- Priority: `.needsDuration` wins over every derived reason when both apply.
- A task with a block but zero remaining minutes surfaces, and its block is **not** deleted.
- A normally-schedulable task still produces no entry.
- Existing suite (71 tests at HEAD) must still pass. If an existing test asserts that a zero-remaining task is absent from these lists, **report it rather than updating it** — same instruction that surfaced the encoded-bug test in `ac86a0d`.

## Out of scope

- The drain itself — separate plan, do not attempt a fix or a data migration here.
- Do not modify `SchedulingFitStatus`'s cases or `fitStatus`'s logic.
- Do not change walk termination, `maxWalkDays`, or the double-booking investigation.
