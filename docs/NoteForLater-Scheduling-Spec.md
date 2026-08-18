# NoteForLater — Scheduling Engine Spec

**Baseline commit:** `e449f65`
**Scope:** Eligibility semantics, fit checking, packing order, deadline handling, regeneration triggers, Nightly Review review-state.

This spec describes **intended behavior**. Where it differs from current code, the current behavior is noted so the change is deliberate rather than accidental. Read the "Current" note before changing anything — several of these are working as designed today and are being changed on purpose.

---

## 0. Vocabulary

| Term | Model | Notes |
|---|---|---|
| **Schedule** | `NamedSchedule` | Reusable day/time window. "Work: M–F 9–5". Managed from More → Schedules. |
| **Rule** | `SchedulingRule` | Belongs to a `Shelf`. References one `NamedSchedule` + adds a fill strategy. |
| **Eligible Schedule** | rule ID in `TaskItem.includedSchedulingRuleIDs` | Per-task opt-in to one of its shelf's rules. |

A rule is *"an eligible schedule plus a fill strategy."* The same `NamedSchedule` may back rules on many shelves with different strategies.

---

## 1. Data model changes

### 1.1 `TaskItem.remainingMinutes` (new)

```swift
/// What's left to place. `estimatedMinutes` is the user's stated size and
/// is never written by the scheduler.
var remainingMinutes: Int = 0
```

**Current:** `pack()` decrements `estimatedMinutes` directly when a divisible task is partially placed. The user's stated duration is destroyed, the task card shows a shrinking number, and `clearIncompletePastBlocks` frees the block without restoring the minutes — so partial placements silently shrink a task permanently.

**Required:**

- `estimatedMinutes` — user-entered, written **only** from the task card. Immutable to the scheduler.
- `remainingMinutes` — initialized to `estimatedMinutes`; decremented by `pack()` as segments are placed.
- Reset `remainingMinutes = estimatedMinutes` whenever `estimatedMinutes` is edited on the card.
- **`clearIncompletePastBlocks` must restore** `remainingMinutes` by the duration of each block it deletes. This is the current silent-shrink bug; without it the new field has the same defect.
- Task card displays `estimatedMinutes`, with "X of Y scheduled" when `remainingMinutes < estimatedMinutes`.
- `slack` (§5.2) and `pack()` read `remainingMinutes`. `canEverFit` reads `minimumSegmentMinutes` / `estimatedMinutes` (§3).

**Migration:** `remainingMinutes = estimatedMinutes` for all existing tasks.

### 1.2 `TaskItem.isNightlyReviewed` (new)

```swift
/// True only between "Next" on the Nightly Review Today step and the push
/// that follows. Not durable state on a surviving task.
var isNightlyReviewed: Bool = false
```

Rationale: `reviewCutoff` is `min(.now, dayEnd)`, recomputed on every access. Reviewing across midnight, or an async cleanup interleaving, means `advance()` can operate on a different set than the user just looked at. Stamping the batch makes the push deterministic. See §7.2.

**Migration:** `false` for all existing tasks.

### 1.3 No `isReviewed` on habits

**Do not add one.** `Habit.occurrenceStatus` already provides this: `openHabitOccurrencesForReview` surfaces only `.none` occurrences, and `markUnresolvedHabitOccurrencesAsMissed()` flips unchecked ones to `.missed` on advance. Yesterday's missed occurrence is already excluded from tonight's review. A second flag would create two sources of truth.

---

## 2. Eligibility — hard exclusion

**Current as of `1bd15d3` (post-baseline — §2.1 and §2.2 already shipped):** `generateProposedSchedule`'s per-rule candidate filter is `.filter { $0.isEligible(for: rule) }` — no Tier 3, no fallback. `tieredOrdering` has no eligible/ineligible comparison left; it's duration-only. Both match this section's **Required** state already. §2.3 does not — see below.

**Required:** A task not eligible for a rule is **never** placed by that rule.

### 2.1 Remove Tier 3 — ✅ done

- `generateProposedSchedule` filters candidates to `task.isEligible(for: rule)` before packing (not yet renamed to `isEffectivelyEligible` — that rename is §3.2, still open, since `canEverFit` isn't factored in at this filter yet).
- `tieredOrdering` dropped the eligible/ineligible comparison; its doc comment already reflects the new (post-Tier-3) two-tier state.

### 2.2 Seeding — inbox→shelf only — ✅ done at the two named sites

- `InboxViewModel.swift` `route(_:to:)` — seeds correctly.
- `NightlyReviewView.swift` `shelfRow` (~line 1752) — seeds correctly, and also still calls `syncEligibilityWithFit()` right after (§3.2 dead code, not yet removed).
- Confirmed still unseeded: `ShelfListView.swift`, `ReceiptImportView.swift`, `TaskImportService.swift`.

Not originally listed here: `NightlyReviewView.swift`'s "Recurring?" toggle (~line 1236) also seeds `includedSchedulingRuleIDs` when it auto-previews the Recurring Tasks shelf, by the same "preview a shelf, seed its enabled rules" rationale as `shelfRow`. Same category, just not enumerated by name in the original draft of this section.

**Leave unseeded** (deliberate): `ShelfListView.swift:205`, `ReceiptImportView.swift:139`, `TaskImportService.swift:118` and `:132`.

⚠️ **Consequence:** tasks from those four paths are unschedulable until the user opens the card and picks schedules. Under Tier 3 they were being quietly scheduled anyway. This is intended — `eligibleSchedulesMissing` already flags them, so they surface through attribute review. Do not "fix" this by adding seeding.

### 2.3 New rules auto-opt-in every existing task — ✅ intentional, supersedes the old model comment

**Reversed from the original draft of this section**, which carried forward the model comment's "new rule ≠ auto-eligible" note without weighing it against §2.1's own hard exclusion. Under hard exclusion, "a new rule opts in nobody" means adding a schedule to a shelf does nothing at all until every task on that shelf has its card opened by hand and the new toggle flipped on — for a shelf with any real backlog, that's the schedule sitting inert, not a safety default. Appending the *new* rule's own ID also can't be overriding a user decision, since by construction no task has an opinion yet on a rule that didn't exist a moment ago — there's nothing to override.

**Required:** `ShelfEditView.assignSchedule(_:)` keeps its current behavior — on creating a new `SchedulingRule`, append that rule's ID to `includedSchedulingRuleIDs` for every task already on the shelf that doesn't already have it (which, for a brand-new rule, is all of them). Verified this fires *only* from rule creation (the "Add Schedule" picker, which excludes schedules already assigned) and never from editing an existing rule — `SchedulingRuleEditView.swift` never touches `includedSchedulingRuleIDs`, so a rule someone deliberately toggled off on a task stays off across any number of edits to that rule's own window/fill-strategy. Only a genuinely *new* rule ever seeds anything.

The old model-comment language this contradicts (`SchedulingRule`'s own doc comment, if it still says a new rule isn't auto-eligible) should be updated to match, not the other way around.

### 2.4 No migration backfill

Existing tasks keep their empty arrays and surface via attribute review as "Eligible Schedules" missing. Expect most of the existing shelf backlog to go unscheduled on first launch after this ships. This is intended. Still true at HEAD — no eligibility migration exists (the Phase 1 migration only backfills `remainingMinutes`, an unrelated field).

---

## 3. Fit checking

### 3.1 Rewrite `SchedulingRule.canEverFit`

**Current as of `1bd15d3`** (partially fixed, but not to this section's spec — the whole-chunk-size bug from the baseline is gone, replaced by a different bug):
```swift
func canEverFit(minutesNeeded: Int, isDivisible: Bool, minimumSegmentMinutes: Int = 0) -> Bool {
    switch fillStrategy {
    case .fillToFit:
        return true
    case .maxDuration:
        guard isDivisible else { return minutesNeeded <= maxTotalMinutes }
        return minimumSegmentMinutes <= 0 || minimumSegmentMinutes <= maxTotalMinutes
    case .maxTaskCount:
        guard isDivisible else { return minutesNeeded <= maxMinutesPerTask }
        return minimumSegmentMinutes <= 0 || minimumSegmentMinutes <= maxMinutesPerTask
    }
}
```
The baseline bug (any divisible task returns `true` regardless of chunk size) is fixed — a divisible task's chunk size is now checked against the rule's cap. But `minimumSegmentMinutes <= 0` (not yet decided) returns **`true`** here — optimistic, mirroring `pack()`'s own "not ready yet, skip rather than flag" guard — where the original draft of this section wanted **`false`** ("can't be split safely"). Neither is actually correct, which is the reason for the redesign below, not just a pick between the two: `canEverFit` is answering two different questions with one `Bool` — "blocked by a real constraint" and "not ready to evaluate yet" — and collapsing them loses information a caller might need. Optimistic (`true`) makes the task card's toggle look enabled while `pack()` silently skips the task anyway; strict (`false`) shows "Exceeds time constraint," which is a lie — nothing is actually too big, the minimum segment just hasn't been chosen yet.

**Required — replace the `Bool` with a status enum:**
```swift
enum SchedulingFitStatus {
    /// No duration set at all — nothing to compare against the rule's
    /// cap yet, so no fit judgment is possible either way.
    case needsDuration
    /// Divisible, but no minimum segment chosen yet ("Not Selected") —
    /// same idea as `needsDuration`, for the divisible/segment question
    /// instead of the duration one.
    case needsMinimumSegment
    /// Genuinely too big for anything this rule could ever offer —
    /// duration/segment vs. the rule's own cap, a real comparison.
    case exceedsConstraint
    /// Fits — comfortably within whatever the rule allows.
    case fits
}

func fitStatus(estimatedMinutes: Int, isDivisible: Bool, minimumSegmentMinutes: Int) -> SchedulingFitStatus {
    guard estimatedMinutes > 0 else { return .needsDuration }
    if isDivisible, minimumSegmentMinutes <= 0 { return .needsMinimumSegment }
    let minutesToCheck = isDivisible ? minimumSegmentMinutes : estimatedMinutes
    switch fillStrategy {
    case .fillToFit:
        return .fits
    case .maxDuration:
        return minutesToCheck <= maxTotalMinutes ? .fits : .exceedsConstraint
    case .maxTaskCount:
        return minutesToCheck <= maxMinutesPerTask ? .fits : .exceedsConstraint
    }
}

/// Convenience for every existing Bool call site (e.g. `isEffectivelyEligible`,
/// §3.2) that only needs a yes/no, not the reason.
func canEverFit(estimatedMinutes: Int, isDivisible: Bool, minimumSegmentMinutes: Int) -> Bool {
    fitStatus(estimatedMinutes: estimatedMinutes, isDivisible: isDivisible, minimumSegmentMinutes: minimumSegmentMinutes) == .fits
}
```

Divisible cases use the **segment** test, not the whole-task test. A recurring window drains a large task across multiple occurrences; a whole-task test would gray out most large projects and defeat divisibility. A whole-task test would also produce a gray-out that flickers as `remainingMinutes` drains.

The four cases map 1:1 onto the two existing attribute-review checks in `TaskItem` (`durationMissing` ↔ `.needsDuration`, `divisibleMissing` ↔ `.needsMinimumSegment`), plus the one genuine "no" (`.exceedsConstraint`) and the one genuine "yes" (`.fits`) — nothing left over, nothing double-counted. §3.3's "duration-less tasks are never eligible" is now just `fitStatus != .fits` (which `canEverFit` already gives for free) rather than a special-cased `estimatedMinutes > 0` guard bolted onto every strategy branch.

**Task card caption picks off the status, not a single flat string:**
- `.needsDuration` → "Set a duration first."
- `.needsMinimumSegment` → "Set a minimum segment first" — names the actual blocker instead of implying the task itself is too big.
- `.exceedsConstraint` → "Exceeds time constraint — will re-enable if this changes" (§3.2's caption).
- `.fits` → no caption; toggle just reads enabled.

### 3.2 Filter at read time — do not write

**Current:** unchanged from baseline — still live at HEAD, not started. `syncEligibilityWithFit()` calls `setEligible(false, ...)`, permanently deleting the rule ID when a fit check fails. Loosening the rule later does not restore it, and the array can no longer distinguish "user said no" from "system cleared this." Currently called from **five** sites in `TaskReviewCard` (`NightlyReviewView.swift`), not two: `.onAppear` (~line 850), three separate `.onChange` hooks (`estimatedMinutes` ~852, `isDivisible` ~863, `minimumSegmentMinutes` ~864), and the `shelfRow` preview tap (~line 1753) — all need to go. Point 4 below is already true at HEAD independent of the rest of this section: `eligibleSchedulesMissing` already reads the raw `includedSchedulingRuleIDs` array, not any fit-aware helper.

**Required:**

1. **Delete `syncEligibilityWithFit()`** and all five call sites above.
2. Add to `TaskItem`:
   ```swift
   func isEffectivelyEligible(for rule: SchedulingRule) -> Bool {
       isEligible(for: rule) && rule.canEverFit(
           estimatedMinutes: estimatedMinutes,
           isDivisible: isDivisible,
           minimumSegmentMinutes: minimumSegmentMinutes
       )
   }
   ```
3. Scheduler reads `isEffectivelyEligible`. Task card toggle reads raw `isEligible` for its stored value, and `canEverFit` separately for enabled/disabled state.
4. `eligibleSchedulesMissing` checks the **raw** array — a task whose only rule is temporarily suppressed should not be dragged into attribute review.

Caption when suppressed: **"Exceeds time constraint — will re-enable if this changes"** (currently a flat "Exceeds time constraint", which reads as permanent).

### 3.3 Duration-less tasks are never eligible

**Current:** unchanged from baseline — still live at HEAD, not started. `guessedMinutes(for:)` and the `isEstimated` path in `pack()` (lines ~395, 401, 451, 465, 481) are fully intact; `fillToFit` in the current `canEverFit` (§3.1) returns `true` unconditionally, with no `estimatedMinutes > 0` check anywhere in it yet.

`estimatedMinutes == 0` → `fitStatus` returns `.needsDuration` (§3.1) → `canEverFit` is `false` for all strategies including `fillToFit`, with no special-cased duration check needed at this layer — `.needsDuration` already isn't `.fits`.

**Removes:** `guessedMinutes(for:)`, the `isEstimated` path in `pack()`, and `ScheduledBlock.isEstimatedDuration` display of `~` durations from the packer.

⚠️ Feature removal — duration-less tasks currently receive a guessed 30-minute block. They will now never appear on the calendar until a duration is set. `durationMissing` already flags them in attribute review.

Check whether `isEstimatedDuration` has other writers before removing the field itself — `ScheduleReviewViewModel.insertBlock` uses a 30-minute fallback for manual timeline inserts, which is a separate path and should be left alone.

---

## 4. Packing fixes

### 4.1 Truncation must respect the segment floor

**Current bug**, `pack()`:
```swift
} else if task.isDivisible {
    minutesNeeded = budget          // no floor check
}
```
`place()`'s single-contiguous-slot path never consults `minimumSegment`:
```swift
if let slot = slots.first(where: { $0.durationMinutes >= minutesNeeded }) {
    return [(slot.start, slot.start + minutesNeeded)]
}
```
Result: with 20 minutes of budget left, a task configured as indivisible below 60 minutes receives a 20-minute block. The floor only holds on the multi-slot fallback path.

**Required:**
- When truncating a divisible task (`maxDuration` budget or `maxTaskCount` per-task cap), floor the result to a whole multiple of `minimumSegmentMinutes`. If that is `0`, skip the task.
- `place()` must reject any single-slot placement below `minimumSegment` when `isDivisible`.

### 4.2 Keep the existing round-up

`place()` rounds a final divisible segment **up** to `minimumSegmentMinutes` rather than leaving a sliver. Retain. `pack()` already tracks `actualMinutes` rather than `minutesNeeded` for bookkeeping — keep that, and apply it to `remainingMinutes`.

---

## 5. Ordering and deadlines

### 5.1 Ordering

Replace `tieredOrdering` / `durationTieredOrdering` / `taskOrdering` with:

1. **Filter:** `isEligibleToStart(on: date)` — unchanged
2. **Filter:** `isEffectivelyEligible(for: rule)` — §3.2
3. **Sort:** ascending `slack` (§5.2); tasks with no due date sort last
4. **Sort:** priority descending (high → medium → low → unset)
5. **Sort:** `createdAt` ascending (insertion order)
6. **Sort:** `remainingMinutes` descending
7. **Sort:** non-divisible before divisible

Steps 6–7 minimize fragmentation: one 2-hour task preferred over four 30-minute divisible ones for a 2-hour window.

Removed: the has-duration-vs-guessed tier (dead per §3.3) and the eligible-vs-ineligible tier (dead per §2.1).

### 5.2 Slack

```swift
/// Minutes of headroom before the deadline becomes impossible.
/// nil when no due date.
func slack(asOf date: Date) -> Int?
```

`slack = minutesBetween(date, dueDate) − remainingMinutes`

- `slack < 0` → **at risk**, cannot be met
- `nil` → sorts last in step 3

This is earliest-deadline-first. It does not *guarantee* placement — fitting variable-length tasks into fixed windows against deadlines is bin-packing, and sometimes the work genuinely does not fit. The guarantee is: tightest deadlines get first claim on capacity, and anything that still misses is **surfaced rather than silently dropped**.

### 5.3 At-risk surfacing

A task is at risk when, after a full regeneration pass, `remainingMinutes > 0` and no placement exists before `dueDate` within the walk horizon.

Two surfaces:

- **Task card badge** — visible wherever `TaskReviewCard` renders. Should name the blocker where possible: past due, no eligible schedule, or insufficient capacity.
- **New Nightly Review step** — see §7.1.

Threshold is `slack < 0` only. No buffer.

---

## 6. Regeneration triggers

**Current:** no reactive trigger. Regeneration runs only from the manual Regenerate button, Nightly Review's `advance()`, and calendar-appear (habits/recurring top-up only).

### 6.1 Dirty flag

New `@Observable` singleton, mirroring `InboxSearchState` / `NightlyReviewLaunchState`:

```swift
@Observable final class ScheduleDirtyState {
    static let shared = ScheduleDirtyState()
    var isDirty = false
}
```

**Set `isDirty = true`:**
- Task card **Save** (any variant: "Save", "Save & Move", "Save & Submit", "Save, Move & Submit") when `hasChanges` is true
- Mark Complete / Mark Incomplete
- Discard
- Task created on a shelf, or moved between shelves
- Any `SchedulingRule` create / edit / delete
- Any `NamedSchedule` edit or delete
- Shelf deletion
- Inbox bulk submit

**Do not set:** Cancel (restores the snapshot — net zero change).

### 6.2 Flush

`ScheduleReviewView.onAppear` and on viewed-day change: if dirty → `await regenerateFromNow(...)` → clear flag.

Deferred rather than immediate because `regenerateFromNow` walks up to 30 days with one `fetchFreeSlots` call per day. Firing on the Save tap either blocks sheet dismissal or runs a long async job behind a dismissing sheet.

Nightly Review clears the flag on completion — `regenerateSingleDay` already covers it.

### 6.3 Use `regenerateFromNow`, not `regenerateSingleDay`

Edits that push work to a later day (untoggling a weekday schedule so a task moves to the weekend) require the multi-day walk. `regenerateSingleDay` never walks forward and would drop the overflow.

### 6.4 Horizon stays at 30 days

`maxDays = 30` is retained. Note for future work: `hasSchedulableHabits` is `!habits.isEmpty` computed once outside the loop, so for any user with a habit the day cap is the **only** terminating condition. `hasRemainingSchedulableWork` also never goes false when permanently-unplaceable tasks exist — which §2.2 and §3.3 make a normal state. **Do not raise or remove the cap without first fixing both conditions**; the loop will not terminate.

---

## 7. Nightly Review

Steps unchanged: `chooseDay → today → inbox → twoMinuteTasks → tomorrow`, plus §7.1.

### 7.1 New step: At Risk

Insert **after `tomorrow`**. Lists tasks meeting §5.3 with their blocker. Actions per task: open task card, extend due date, clear due date, or acknowledge. Skipped entirely when empty.

### 7.2 Review batch stamping

On **Next** from the Today step, in this order:

1. Set `isNightlyReviewed = true` on every task represented in `reviewItems` at the moment of the tap. This freezes the batch.
2. `markUnresolvedHabitOccurrencesAsMissed()` — existing, unchanged.
3. For each stamped task:
   - **Complete** → delete task and blocks (`purgeCompletedBlocks`, existing). Recurring tasks keep the `TaskItem`, delete only the occurrence's block.
   - **Incomplete** → `clearIncompletePastBlocks` (deletes block, `isScheduled = false`, `pushedCount += 1`, **restores `remainingMinutes`** per §1.1), then set `isNightlyReviewed = false` so it re-enters tomorrow's review.
4. `regenerateSingleDay` for the target day, then `regenerateFromNow` so pushed work can reach later days.

Steps 1–3 operate on the frozen batch, not on a recomputed `reviewCutoff`.

### 7.3 Locked past blocks lose protection

`clearIncompletePastBlocks` must clear past incomplete blocks **regardless of `isLocked`**. A lock pins a block within a day's layout; it does not pin it to a day that has ended. Current code already ignores lock status here — verify no regression, and confirm `approvalStatus == .approved` past blocks are also swept.

Locking continues to protect present and future blocks in `regenerateFromNow` and `regenerateSingleDay`.

### 7.4 Inbox step

No immediate calendar placement required. The Tomorrow step's regeneration picks up newly-shelved tasks. Current behavior — no change.

---

## 8. Replace Task picker

**Current:** `ReplacementPickerSheet` lists every unscheduled task grouped by shelf, unfiltered.

**Required:** filter `candidates` to tasks that could actually occupy the target block:

- `isEligibleToStart(on: block.date)`
- `isEffectivelyEligible(for:)` for the rule owning that window
- fits the block's duration, or is divisible with `minimumSegmentMinutes <= blockDuration`

Sort by §5.1. Apply the same filter to `EmptySlotPickerSheet` in `DayTimelineGridView.swift` — same operation from a different entry point.

The **Auto** button (`autoReplace`) currently sorts by priority then due date; update to §5.1.

---

## 9. Rule editor

**Current trap:** `generateProposedSchedule` filters on `rule.namedSchedule != nil`. A rule with a custom window and no linked schedule renders a normal-looking summary (via the `effective*` fallbacks), appears in the shelf's rule list, appears in the task card with a live toggle — and never schedules anything. No error, no visual difference.

**Required:**

1. `SchedulingRuleEditView` — disable Save until a `NamedSchedule` is selected. Provide an inline "Create new schedule" shortcut so the user isn't bounced to More → Schedules.
2. When `namedSchedule == nil` (orphaned by a schedule deletion), render the rule row in red with **"No schedule assigned"** in place of the summary — in both the shelf rule list and the task card's Eligible Schedules section.

Do **not** cascade-delete rules when a `NamedSchedule` is deleted. Wiping rules across every shelf is a bigger surprise than a visible orphan. Keep `.nullify`.

---

## 10. Out of scope

- Raising or removing the 30-day horizon (§6.4)
- Batching `fetchFreeSlots` into a single ranged `freeBusy` call — worthwhile, separate
- Real Claude API scheduling (`MockAISchedulingService` remains the implementation)
- Background regeneration / `BGAppRefreshTask` (`NoteForLaterApp.swift:187`)
- Splitting `DayTimelineGridView.swift` (2,243 lines) and `NightlyReviewView.swift` (1,922 lines)
- Shelf-clearance projection ("when will this shelf empty")

---

## 11. Suggested phasing

Each phase should build and run.

| Phase | Contents | Risk |
|---|---|---|
| 1 | §1.1 `remainingMinutes` + restore-on-clear; §4 packing floor fixes | Low — fixes real bugs, no behavior change users would notice |
| 2 | §3 fit checking, read-time filtering, delete `syncEligibilityWithFit` | Medium — toggles change availability |
| 3 | §2 hard exclusion | **High** — most visible drop in scheduled volume |
| 4 | §5 slack ordering + at-risk detection | Medium |
| 5 | §6 dirty flag and flush | Low |
| 6 | §1.2 + §7 Nightly Review changes | Medium — migration |
| 7 | §8 picker filtering, §9 rule editor | Low |

**Phase 3 is the one to expect complaints about.** Removing Tier 3 plus §2.4's no-backfill plus §3.3's duration requirement means the calendar will look substantially emptier immediately after. That is correct behavior, not a regression. Land phases 1–2 first so the gray-out logic is trustworthy before tasks start depending on it.

---

## 12. Test cases

Extend `NoteForLaterTests/`. Currently only `HabitRollingStatsTests` and `ReceiptLineParserTests` exist — there is no scheduler coverage at all.

**Fit checking**
1. 4hr task, divisible @ 60min, rule `maxTaskCount` ≤15min each → `canEverFit == false`
2. Same task, rule `maxDuration` 120min total → `canEverFit == true` (segment test)
3. Divisible, `minimumSegmentMinutes == 0` → `false`
4. `estimatedMinutes == 0`, `fillToFit` → `false`
5. Task eligible for a rule it can't fit → `isEligible == true`, `isEffectivelyEligible == false`, ID still present in the array
6. Loosen that rule → `isEffectivelyEligible == true` with no user action

**Packing**
7. Divisible @ 60min, `maxDuration` with 20min budget left → **not placed** (regression test for §4.1)
8. Divisible task partially placed → `estimatedMinutes` unchanged, `remainingMinutes` reduced
9. Same task's block cleared by `clearIncompletePastBlocks` → `remainingMinutes` restored to full
10. Task ineligible for the only applicable rule → never placed, even with the window empty (regression test for Tier 3 removal)

**Ordering**
11. Two tasks, one negative slack / low priority, one positive slack / high priority → negative slack first
12. Equal slack, differing priority → higher priority first
13. Equal slack and priority → older `createdAt` first
14. All equal → larger `remainingMinutes` first; non-divisible before divisible at equal size

**Nightly Review**
15. Review spanning midnight → the batch acted on equals the batch stamped, not a recomputed window
16. Incomplete reviewed task → `isNightlyReviewed` returns to `false`, appears in the next review
17. Locked past incomplete block → cleared
18. Locked future block → survives `regenerateFromNow`
19. Missed habit occurrence from yesterday → absent from tonight's review (existing `.missed` behavior)

**Rules**
20. Rule with `namedSchedule == nil` → excluded from packing, rendered as "No schedule assigned"
21. Deleting a `NamedSchedule` → dependent rules orphaned, not deleted
