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

#### 1.1a Every block deletion must restore, and deferral is not completion

`pack()` decrements `remainingMinutes` when it places a block, so **any** deletion of an incomplete block that skips the restore destroys that time permanently. Three paths did restore; four did not (`trimOverflowingRuleBlocks` ×2, `deleteBlock`, `manualReplace`). The trim pair runs at the top of every `autoPlaceEligibleTasks` — on essentially every Calendar appear — so the leak was high-frequency, and four real tasks were found drained to `remainingMinutes = 0` while still incomplete.

The audit that found this also **disproved** the obvious hypothesis, which is worth recording so nobody re-checks it: `restoreRemainingMinutes` reads `block.task`, and all three clear paths nil that inverse before deleting — but every one of them calls the restore *strictly first*, so the `guard let task = block.task` never no-ops. The ordering was correct everywhere; the calls were simply absent in four places.

**All deletions now route through one `removeBlock(_:restoringRemainingMinutes:)` that restores by default.** Four call sites had independently grown the same delete-without-restore shape and nothing stopped a fifth. Completed blocks are safe to pass — the restore already no-ops on them, since their time was genuinely spent.

**`deleteBlock` (the user's swipe) restores, deliberately.** A swipe means "not here, not now": the app has a separate gesture — completing the block — that means the work is done, and `deleteBlock` already increments `pushedCount`, which is semantically a *deferral*. Not restoring turned a routine swipe into a silent-drain trap. An explicit discard-the-work action would be a separate deliberate feature, never a side effect of a swipe.

#### 1.1b The `min(estimatedMinutes, …)` clamp, and duration edits

`restoreRemainingMinutes` clamps with `min(estimatedMinutes, remainingMinutes + block.durationMinutes)`, which is correct against over-restore but silently caps a legitimate restore if `estimatedMinutes` was edited **downward** after the block was placed.

That interaction was audited and is **not** currently a drain source, but the reason is worth stating because it is fragile: several paths *reset* `remainingMinutes` whenever `estimatedMinutes` changes — `NightlyReviewView`'s `onChange(of: task.estimatedMinutes)` sets `remainingMinutes = newValue`, and both shelf-move paths reset it via `resolvedDuration`. Those resets inflate rather than drain, so they mask the clamp rather than compound it. If any of them is ever removed or narrowed, the clamp becomes a live leak.

**Repair of already-damaged data** lives in `TaskItem.repairedRemainingMinutes()` (one-shot launch migration, its own flag, deliberately separate from the §1.1 backfill above which blanket-sets every task). Three cases: blocks already covering the estimate → leave alone; no blocks → full estimate; partial blocks → estimate minus placed. The first is the one that matters — a fully-scheduled task legitimately has `remainingMinutes == 0`, and resetting it would re-offer work already on the calendar.

### 1.2 `TaskItem.isNightlyReviewed` (new) — ✅ done, Phase 6

```swift
/// True only between "Next" on the Nightly Review Today step and the push
/// that follows. Not durable state on a surviving task. Diagnostic only —
/// nothing reads it. See §7.2 for what actually guarantees the batch.
var isNightlyReviewed: Bool = false
```

Rationale: `reviewCutoff` is `min(.now, dayEnd)`, recomputed on every access. Reviewing across midnight, or an async cleanup interleaving, means `advance()` can operate on a different set than the user just looked at. **The actual fix is capturing `reviewedBlocks`/`frozenCutoff`/`frozenAllBlocks` as local `let`s synchronously, before the async work starts** — see §7.2. `isNightlyReviewed` doesn't drive that determinism itself (it's write-only, never read back); it exists to make a stamped task visibly identifiable while it's mid-batch, not as the mechanism the freeze depends on.

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

### 3.2 Filter at read time — do not write — ✅ done as of `df87fb6`

`syncEligibilityWithFit()` and all five call sites in `TaskReviewCard` are deleted (`.onAppear`, three `.onChange` hooks, the `shelfRow` preview tap). `eligibleSchedulesMissing` was already reading the raw array at HEAD before this landed, unchanged. The task card's Eligible Schedules row now reads `TaskItem.fitStatus(for:)` and captions per-case, per §3.1.

`TaskItem.isEffectivelyEligible(for:)` shipped, but **not** with the snippet originally given here:
```swift
func isEffectivelyEligible(for rule: SchedulingRule) -> Bool {
    isEligible(for: rule) && rule.canEverFit(
        estimatedMinutes: estimatedMinutes,
        isDivisible: isDivisible,
        minimumSegmentMinutes: minimumSegmentMinutes
    )
}
```
This reads `estimatedMinutes` — the task's *original* stated size — which is correct for most callers (the task card toggle, the scheduler's own candidate filter) since those want to know "is this task, as configured, a candidate for this rule at all." But it is **not** correct for `ScheduleReviewViewModel.hasRemainingSchedulableWork`, one of only two conditions that ever stop `regenerateFromNow`'s multi-day walk (§6.4 — the other is `taskSafetyCapDays`). That function needs `remainingMinutes` (what's actually still unplaced on a partially-scheduled divisible task), not `estimatedMinutes` (the task's full original size): checking the original size would keep reporting "still fits" even once the task is fully drained, if `isScheduled` hasn't been set by whatever path drained it — the walk would never terminate on that task. `hasRemainingSchedulableWork` deliberately does **not** call `isEffectivelyEligible` — it inlines the same `isEligible(for:) && canEverFit(...)` check with `remainingMinutes` substituted for `estimatedMinutes`, with a comment on-site explaining why. This is the one caller `isEffectivelyEligible` is not meant to replace.

Caption when suppressed: **"Exceeds time constraint — will re-enable if this changes"** (`.exceedsConstraint`), shipped as one of four status-specific captions per §3.1 (`.needsDuration`/`.needsMinimumSegment` get their own).

### 3.3 Duration-less tasks are never eligible — ✅ done as of `df87fb6`

`estimatedMinutes == 0` → `fitStatus` returns `.needsDuration` (§3.1) → `canEverFit` is `false` for all strategies including `fillToFit`, with no special-cased duration check needed at this layer — `.needsDuration` already isn't `.fits`.

**Removed:** `guessedMinutes(for:)` and the `isEstimated` path in `pack()` — every candidate reaching `pack()` now passes `isEffectivelyEligible` upstream, which already guarantees `estimatedMinutes > 0`, so nothing in the packer ever needs to guess a duration on a task's behalf again. `tieredOrdering`/`durationTieredOrdering` (the has-duration-vs-guessed sort tier) were also removed as a direct consequence — every candidate now guarantees a real duration, so that comparison was as dead as the eligible-vs-ineligible one §2.1 already removed; see the corrected note on §5.1 below.

**Kept, deliberately:** `ScheduledBlock.isEstimatedDuration` and its "(Est Duration)" / `~` display — the field has two other writers untouched by this section: `ScheduleReviewViewModel.insertBlock`'s manual-timeline-insert fallback, and `placeHabitsAndRecurringTasks`'s own recurring-task 30-minute fallback (a deliberate exception — a recurring task bypasses eligibility/rule-packing by design, so "duration-less tasks are never eligible" doesn't apply to a mechanism that doesn't check eligibility at all).

⚠️ Feature removal — duration-less tasks currently receive a guessed 30-minute block. They will now never appear on the calendar until a duration is set. `durationMissing` already flags them in attribute review.

Check whether `isEstimatedDuration` has other writers before removing the field itself — `ScheduleReviewViewModel.insertBlock` uses a 30-minute fallback for manual timeline inserts, which is a separate path and should be left alone.

### 3.4 `fitStatus` is asked two different questions — keep the split, but know it

`SchedulingRule.fitStatus` is called with `estimatedMinutes` at some sites and `remainingMinutes` at others. **This is deliberate and should stay**, but it is not obvious from the call sites, and one pair of them genuinely disagrees.

| Call site | Passes | Question it is really asking |
|---|---|---|
| `ScheduleReviewViewModel.isSchedulableBacklog` | `remainingMinutes` | can what's *left* still be placed? |
| `TaskItem.fitStatus(for:)` | `estimatedMinutes` | is this task well-*configured*? |
| `TaskItem.isEffectivelyEligible` | `estimatedMinutes` | is this task well-configured? |
| `TaskItem.atRiskBlocker` | `estimatedMinutes` (via `fitStatus(for:)`) | configuration |
| `NightlyReviewView` task-card toggles | `estimatedMinutes` (via `fitStatus(for:)`) | configuration |

The two questions are genuinely different and unifying them would break one caller or the other. What makes the split hazardous is the guard at the top of `fitStatus`: `guard estimatedMinutes > 0 else { return .needsDuration }`. A task with `estimatedMinutes = 120` and `remainingMinutes = 0` therefore reads `.fits` at the configuration sites and `.needsDuration` at the scheduler site — the same task, opposite verdicts.

**Unresolved: `AISchedulingService.swift:175`.** The packer filters its candidates with `isEffectivelyEligible`, which reads `estimatedMinutes`, while `hasRemainingSchedulableWork` reads `remainingMinutes`. For a drained task these disagree, so it is *admitted* to `pack()` and then discarded inside it — `baseMinutes = remainingMinutes = 0` hits `guard minutesNeeded > 0 else { continue }` and the task is skipped silently, every day, with no error and no placement. That is the least visible possible outcome, and it is why the `remainingMinutes` drain (§1.1a) went unnoticed for so long rather than surfacing as a failure.

Not changed, because the drain that produced zero-remaining tasks is now fixed at source and §5.4 surfaces any that still occur. Recorded because the disagreement is still there, and it is the mechanism by which any *future* zero-remaining bug will again fail silently.

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

**Required — ✅ done, `ac86a0d`, and the floor is needed in *two* places:**

- **In `pack()`, before `place()` is called.** Floor `minutesNeeded` to a whole multiple of `minimumSegmentMinutes`. This is the one that actually mattered: the reported bug (a 4-hour task with 2-hour segments against a 3.5-hour budget) never reached `place()`'s splitting loop at all. `minutesNeeded` was set to the raw 210-minute budget, and `place()`'s **whole-task fast path** — `slots.first(where: { $0.durationMinutes >= minutesNeeded })` — put all 210 minutes in one block. A fix confined to the loop would not have touched it.
- **In `place()`'s loop.** Each per-slot take is floored too, so a 3.5-hour slot yields one whole 2-hour segment rather than absorbing 3.5 hours.

Either alone is insufficient. Without the second, a slot absorbs a non-multiple; without the first, the fast path bypasses the check entirely.

**Why the orphan is fatal rather than untidy:** the leftover 30 minutes can never be placed, because every slot is gated on holding at least a full `minimumSegment`. The task then sits unschedulable forever *while still counting as remaining work* — which is precisely the condition that drove the unbounded walk in §6.4.

### 4.2 The round-up is removed — ✅ `ac86a0d`, reversing this section

**This section previously said to retain `place()`'s round-up of a final divisible segment to `minimumSegmentMinutes`. That is no longer correct and the round-up is gone.**

With §4.1's flooring in place, `remaining` stays a whole multiple of the segment size throughout, so it can never drop below one mid-placement — the branch became unreachable. It was also actively harmful: it could *over-place* a task. Taking 210 minutes from a 3.5-hour slot left 30 remaining, which the next slot then rounded back **up** to a full 120 — placing 330 minutes of a 240-minute task.

`pack()` still tracks `actualMinutes` rather than `minutesNeeded` for bookkeeping, and still applies it to `remainingMinutes`. Keep that.

### 4.3 Segment options must divide the duration — ✅ `ac86a0d`

The packer's floor is only half the invariant; the UI has to stop offering segment sizes that guarantee a remainder. `TaskItem.validSegmentOptions(for:)` filters the candidate list to values that **evenly divide** `estimatedMinutes` and are strictly smaller than it (45 → `[15]`; 60 → `[15, 30]`; 240 → `[15, 30, 60, 120]`). Strictly smaller because a segment the size of the whole task is what "not divisible" already means.

Durations with no divisor at all (25, 50, 100) yield an empty list. Those **disable** the divisible toggle with a stated reason rather than presenting an empty picker — a control that silently refuses to turn on reads as broken.

`TaskItem.validateDivisibility()` is the single enforcement point, called wherever `estimatedMinutes` or `isDivisible` is written — including both shelf-move paths, where `resolvedDuration` rewrites the duration without the user touching the divisibility controls at all. It snaps **down** to the largest valid divisor, so a task never silently ends up chunked more coarsely than chosen, and clears divisibility outright when no divisor exists.

---

## 5. Ordering and deadlines

### 5.1 Ordering

**Current as of `df87fb6`:** `tieredOrdering` and `durationTieredOrdering` no longer exist — both were removed during Phase 2 as dead code once §2.1 (eligible-vs-ineligible tier) and §3.3 (has-duration-vs-guessed tier) made their respective comparisons unreachable (every candidate reaching either function was already guaranteed to be eligible/have a real duration, so the tier they sorted on could never actually differ). `AISchedulingService`'s per-rule candidate `.sorted` call already calls `taskOrdering` directly. **The "Removed" line below is therefore already satisfied — nothing left to remove, only steps 3 and 6 below to actually add.**

Replace the remaining `taskOrdering` (due date → priority → `createdAt` → a same-tiebreak `estimatedMinutes`/divisible pair — see its current body) with:

1. **Filter:** `isEligibleToStart(on: date)` — unchanged
2. **Filter:** `isEffectivelyEligible(for: rule)` — §3.2 (already the candidate filter's own job, upstream of this sort — not something `taskOrdering` itself needs to check)
3. **Sort:** ascending `slack` (§5.2); tasks with no due date sort last
4. **Sort:** priority descending (high → medium → low → unset)
5. **Sort:** `createdAt` ascending (insertion order)
6. **Sort:** `remainingMinutes` descending — current code compares `estimatedMinutes` here; needs to move to `remainingMinutes` for the same reason §3.2's `isEffectivelyEligible` caveat exists (a partially-placed divisible task's real remaining size, not its original stated size)
7. **Sort:** non-divisible before divisible

Steps 6–7 minimize fragmentation: one 2-hour task preferred over four 30-minute divisible ones for a 2-hour window.

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

### 5.4 Why a task wasn't placed — `UnplacedReason`

Distinct from At-Risk, and the boundary matters: At-Risk is deadline-driven and its `.exceedsConstraint` cases are tasks that can *never* fit any rule. Everything in `UnplacedReason` already returns `.fits` — it could be placed in principle, but no day in the horizon had room. A task failing `canEverFit` belongs to At-Risk and must never appear here.

Reasons are derived from per-rule tallies accumulated during the walk (eligible days, free minutes, longest contiguous slot, whether the horizon was hit) rather than by threading per-day reporting out of `pack()` — that would mean changing the packer's return signature, which was the invasive option and was not taken.

Checked in a **fixed priority order**, most-specific and directly-measured first:

1. `.needsDuration` — no schedulable time at all. First because it is a measured configuration fact, and because these tasks never reach the packer.
2. `.noEligibleDays` — the rule's window never applied.
3. `.fewEligibleDays` — applied on ≤3 days.
4. `.noFreeTime` — eligible days existed, all fully booked.
5. `.noContiguousSlot` — free time existed but no stretch long enough for one whole segment.
6. `.horizonReached` — the walk stopped at `maxWalkDays` with viable days still ahead.
7. `.ruleBudgetFull` — the fallback, inferred by elimination.

**Free-slot tallies are clipped to each rule's own window, not counted whole-day.** This is load-bearing rather than a refinement: a rule covering 6–8pm on a day with a free morning and a booked evening has no usable time at all, but a whole-day tally records hours of it and the derivation then blames the rule's caps instead of reporting the real `.noFreeTime`.

**`.ruleBudgetFull` appears to be unreachable, and is kept anyway.** A rule's budget resets each day, so for it to be the *standing* explanation something must consume that budget on every day of the walk. Only `pack()` spends it, and `pack()` excludes recurring tasks (`AISchedulingService.swift:168`) — so the consumption must come from ordinary tasks placing repeatedly, which resets the stall counter, which runs the walk to `maxWalkDays`, which makes `.horizonReached` true and claims the case first. Two fixtures were attempted and both resolved to a different reason, so it ships without a test rather than with one asserting something other than what it claims. It stays because the derivation needs a total fallback and "no reason at all" would be worse. **Seeing it in the UI is itself the finding** — it would mean budget accounting or walk termination has changed.

---

## 6. Regeneration triggers — ✅ done, Phase 5

**Current as of Phase 5:** `ScheduleReviewView`'s own appear/day-change sync used to mean exactly one thing (the purely-additive `autoPlaceEligibleTasks` — this section's original "Current" line describing "calendar-appear (habits/recurring top-up only)" was already stale by the time this section was written, since that top-up had already grown to cover every shelf's rule-eligible tasks, not just habits/recurring). It now means one of two things depending on `ScheduleDirtyState`, per §6.2 below.

### 6.1 Dirty flag — ✅ done

`Services/ScheduleDirtyState.swift`, mirroring `InboxSearchState` / `NightlyReviewLaunchState`:

```swift
@Observable final class ScheduleDirtyState {
    static let shared = ScheduleDirtyState()
    var isDirty = false
}
```

**Set `isDirty = true`** — verified against current code, not assumed from the list below:
- `TaskReviewCard.advance()` (the single shared commit point behind Save/Save & Move/Save & Submit/Skip across `TaskCardSheet`, `TaskReviewQueueSheet`, and Nightly Review's own Today/Inbox steps — they all wrap this one view), gated on `hasChanges || isMoving` — a bare Skip/Next with neither leaves the flag alone.
- `TaskReviewCard`'s own Discard confirmation.
- Mark Complete / Mark Incomplete, at every real entry point: `TaskCardSheet.toggleComplete`, `TaskReviewQueueSheet.markComplete`, `DailyDigestCheckInView.blockRow`, and the task branch only of `ScheduleReviewViewModel.toggleComplete` (the calendar's own tap-to-complete circle) — **not** its habit branch, since a habit occurrence's completion never touches shelf-task scheduling at all. **Not** the 2-Minute Task shelf's own checklist toggle either (`DayTimelineGridView.twoMinuteTasksSection`, `NightlyReviewView.twoMinuteTaskRow`) — that shelf is permanently excluded from the packer's candidate pool by design (see `AISchedulingService`'s own doc comment), so completing one of its tasks can never be relevant to anything this flag exists to catch.
- `SchedulingRule` create (`ShelfEditView.assignSchedule`) / edit (`SchedulingRuleEditView.save`) / delete (`ShelfEditView.deleteRules`).
- `NamedSchedule` edit (`NamedScheduleEditView.save`) / delete (`SchedulesListView.deleteSchedules`).
- Shelf deletion (`ShelvesView.deleteShelves`).

**Two items from the original draft of this list don't correspond to anything real, found while wiring this up — not silently dropped:**
- **"Task created on a shelf, or moved between shelves"** — already fully covered by `TaskReviewCard.advance()`'s `isMoving` check above; there's no separate call site for this.
- **"Inbox bulk submit"** — no such feature exists in the current codebase, and `InboxViewModel.route(_:to:)` (the method this bullet presumably meant) is dead code, never called from anywhere. The actual task-to-shelf routing UI is `TaskReviewCard.advance()`, already covered.

**Do not set:** Cancel (restores the snapshot — net zero change).

### 6.2 Flush — ✅ done

`ScheduleReviewView.setupIfNeeded`/`changeDate`/`jumpToDay`/`goToToday` (four call sites, factored into one shared `syncSchedule()`): if `ScheduleDirtyState.shared.isDirty` → `await regenerateFromNow(...)` → clear the flag; **otherwise** (the normal case) → `await autoPlaceEligibleTasks(...)`, unchanged from before this section existed. The original draft's "if dirty → regenerateFromNow → clear flag" was correct as far as it went, but didn't name what happens the rest of the time — `autoPlaceEligibleTasks` is the load-bearing default this section's flush escalates *away from*, not something `regenerateFromNow` simply replaced.

Deferred rather than immediate because `regenerateFromNow` walks a variable number of days (now bounded by stall detection, not a flat 30 — see §6.4) with one `fetchFreeSlots` call per day. Firing on the Save tap either blocks sheet dismissal or runs a long async job behind a dismissing sheet.

Nightly Review's own Today→Tomorrow handoff clears the flag right after its own unconditional `regenerateFromNow` call — pure hygiene (that walk already did everything a dirty-triggered one would), not required for correctness, since the handoff never checked the flag to begin with.

### 6.3 Use `regenerateFromNow`, not `regenerateSingleDay` — moot, `regenerateSingleDay` no longer exists

This section's whole premise predates a change made earlier the same session this spec was first written: Nightly Review's Today→Tomorrow handoff already calls `regenerateFromNow` unconditionally (see §6.2), and `regenerateSingleDay` was deleted as dead code once nothing called it anymore. There is only one regenerate function left — nothing to choose between.

### 6.4 Horizon — ✅ resolved: habit/task split + stall detection, as of Phase 5

**This section's original text described a single `maxDays = 30` cap shared by both habits and tasks — that's no longer the design.** `1bd15d3` (before this spec existed) split the walk's two termination conditions apart, exactly along the line this section's original warning was drawing: `hasSchedulableHabits` (habits, `!habits.isEmpty`, checked once outside the loop — genuinely never goes false on its own, by design, since a habit recurs forever) got its own separate `habitPopulationDays = 30`, a real permanent horizon choice, not a safety net. `hasRemainingSchedulableWork` (tasks) was left paired with a raw day-count backstop, `taskSafetyCapDays`, which that same commit set to 365 — high enough that a genuinely-stuck-but-still-"remaining" task (the exact failure mode this section warned about — `hasRemainingSchedulableWork` never goes false when permanently-unplaceable tasks exist, which §2.2/§3.3 make a normal state) could still burn 365 `fetchFreeSlots` calls before the walk gave up, a real cost that gets paid far more often once Phase 5's dirty-flag flush makes `regenerateFromNow` fire on ordinary edits instead of only on deliberate, occasional regenerates.

**Current, replacing the flat cap:** the task side of the walk now stops via **stall detection** (`taskStallThresholdDays = 14`, `ScheduleReviewViewModel`) instead of a raw day count — `dayIndex < N` became `consecutiveDaysWithoutTaskPlacement < 14`, reset to 0 any day that places at least one task block, incremented otherwise. This terminates correctly regardless of how far out the walk could theoretically go, for a structural reason rather than a chosen number: the candidate task pool for a single call is finite and only ever shrinks (a placement either fully schedules a task, permanently removing it via `isScheduled`, or drains `remainingMinutes` toward zero, a bounded quantity) — so the walk can only have finitely many "progress" days total, and the stall counter bounds how many *consecutive* non-progress days can separate any two of them. Both together guarantee termination without needing an outer day cap at all. 14 was chosen, not defaulted to: a rule restricted to a single weekday can legitimately go up to 6 days between chances to place anything, and doubling that leaves margin for a rule that's *also* narrow some other way (a tight eligible-hours window, a task-count cap already claimed by other shelves that day) without waiting anywhere near as long as 365 ever did.

Habits are untouched by any of this — `habitPopulationDays` stays a flat 30-day cap, unconditionally, since "zero habit blocks placed on some day" was never itself a signal of anything going wrong the way an empty day is for a finite task backlog.

**Correction, `99996ab`: the stall counter must exclude recurring tasks, and the arithmetic is why.** The termination argument above holds *only* if "a day that placed a task block" genuinely means the backlog made progress. It didn't. Recurring tasks are **tasks**, not habits — the fixed-time pass builds them with `task != nil`, so they satisfied the counter's reset condition — and `AISchedulingService` deliberately never sets their `isScheduled`, so they are re-placed on **every** occurrence day, forever, whether or not anything is stuck.

The counter therefore measured recurrence frequency rather than backlog progress, and the arithmetic is unforgiving: a **weekly** recurring task resets it every 7th day, so it climbs 1…6, resets, climbs 1…6 — and **never reaches 14**. Any recurrence more frequent than `taskStallThresholdDays` disables stall detection entirely; daily is not required. With stall detection permanently disabled the only surviving terminator was `hasRemainingSchedulableWork`, which stays true while any unplaceable task exists — a normal state per §2.2/§3.3 — so the walk crawled forward one day at a time until such a task happened to fit. Observed in the field at **day 1046**. That block was never "scheduled far out" by intent; day 1046 was simply the first day it fit.

Both counters now exclude recurring tasks (`$0.task != nil && !($0.task?.isRecurring ?? false)`). A `maxWalkDays` ceiling (= `freeSlotPrefetchDays`, 44) was added alongside as defense in depth, so any *future* condition that wrongly resets the counter degrades into a bounded miss rather than an unbounded crawl.

**Consequence worth knowing:** capping at exactly `freeSlotPrefetchDays` makes the per-day `fetchFreeSlots` fallback unreachable from these two walks. The fallback stays — `fetchFreeSlots(for:)` has other callers, and a failed pre-fetch still routes every day through it — but the test that used to prove the overshoot now asserts that the cap and the pre-fetch horizon stay tied together instead.

---

## 7. Nightly Review — ✅ done, Phase 6

Steps: `chooseDay → today → inbox → twoMinuteTasks → tomorrow → atRisk` (§7.1 inserted at the end).

### 7.1 New step: At Risk — ✅ done

Inserted **after `tomorrow`**, last in the flow (`tomorrow`'s Next becomes `atRisk`'s own Next/Done boundary). Lists tasks where `isAtRisk()` is true, via `atRiskBlocker()` for the label. Actions per task: open task card (`TaskCardSheet`), extend due date (+1 day from wherever it currently sits, not from `.now`), clear due date (mirrors `TaskReviewCard`'s own "Has due date → No" case exactly: `dueDateDecided = true; dueDate = nil; dueDatePicked = false`), or acknowledge. Extend/clear both set `ScheduleDirtyState.shared.isDirty = true` — a schedule-affecting edit like any other in §6.1.

The list itself is live (`allTasks.filter { $0.isAtRisk() && !acknowledged.contains($0.id) }`), not snapshotted the way `twoMinuteReviewTaskIDs` is — a task resolving (extended, cleared, or acknowledged) drops off immediately rather than lingering for the rest of the step. "Acknowledge" is a session-local `Set<UUID>` (`@State`, not persisted) — deliberately not another durable flag that can go stale; it just quiets the list for the remainder of this one review session.

**Skipped entirely when empty**: `advance()`'s own `next == .atRisk && atRiskTasks.isEmpty` check dismisses the review directly instead of transitioning into the step at all.

### 7.2 Review batch stamping — ✅ done

On **Next** from the Today step (the `today → inbox` transition — not deferred to the `tomorrow` handoff), in this order:

1. Set `isNightlyReviewed = true` on every task represented in `reviewableBlocks` at the moment of the tap. This freezes the batch.
2. `markUnresolvedHabitOccurrencesAsMissed()` — existing, unchanged, just moved earlier alongside the stamp.
3. Async:
   - **Complete** → `purgeCompletedBlocks` (existing, unscoped — safe to run against every completed block system-wide, not just this batch). Recurring tasks keep the `TaskItem`; only their occurrence's block is deleted. A recurring survivor's stamp is reset to `false` explicitly (captured *before* the purge, since purge clears each block's own `task` reference on the way out).
   - **Incomplete** → `clearIncompletePastBlocks` against the frozen `allBlocks`/`reviewCutoff` captured at tap time (not a live re-read), then `isNightlyReviewed = false` so it re-enters tomorrow's plan as an ordinary candidate.
4. `regenerateFromNow` (not `regenerateSingleDay` — doesn't exist, see §6.3), unconditionally, so the just-freed incomplete work can actually reach a real day.

**A second, gated regenerate at the `tomorrow` handoff**: the Inbox step (and Two-Minute-Tasks' own completion toggle) can still change things after step 4 above already ran — Inbox routing goes through `TaskReviewCard.advance()`, which already sets `ScheduleDirtyState.shared.isDirty` (§6.1). So the `tomorrow` transition re-runs `regenerateFromNow` **only if `ScheduleDirtyState.shared.isDirty`** — a session with no Inbox routing (or 2-minute-task completion) skips this second walk entirely, since step 4 already covered everything that mattered. Both regenerate calls only clear the flag when the walk actually completed (§ Open Decisions' `fetchFreeSlots`-failure fix applies here too).

Step 1–3's async work operates on locals captured synchronously before the `Task {}` starts, not on live-recomputed `reviewableBlocks`/`reviewCutoff` — see `TaskItem.isNightlyReviewed`'s own doc comment for why.

### 7.3 Locked past blocks lose protection — ✅ done

`clearIncompletePastBlocks` clears past incomplete blocks **regardless of `isLocked`**. A lock pins a block within a day's layout; it does not pin it to a day that has ended. Without this, a locked past-incomplete block would keep matching `reviewableBlocks`' `startTime < reviewCutoff` filter forever, with no in-app way to resolve it. Clearing isn't destructive — the task survives and `remainingMinutes` is restored, so it just returns to the shelf for rescheduling. `approvalStatus == .approved` past blocks are also swept — the function never filters on approval status at all.

`purgeCompletedBlocks` never checked `isLocked` either, so completed past blocks (locked or not) never had this problem.

Locking continues to protect present and future blocks in `regenerateFromNow`.

### 7.4 Inbox step

No immediate calendar placement required. The Tomorrow step's regeneration picks up newly-shelved tasks. Current behavior — no change.

---

## 8. Replace Task picker — ✅ done, Phase 7

**Was:** four separate, drifting candidate filters — `replaceCandidates` (Replace/Swap), `unscheduledCandidates(from:excluding:)` (Nightly Review's Replace picker, quietly narrower than the other two Replace call sites), `unscheduledCandidates(from:)` (**dead code** — never called), and `unscheduledCandidatesIncludingInbox` (empty-slot). None checked eligibility, start date, or duration fit.

**Now:** one function, `ScheduleReviewViewModel.replacementCandidates(from:for:)`, with the slot context as a parameter — `CandidateSlotContext.occupiedBlock(ScheduledBlock)` or `.freeSlot(startTime:includingInbox:)`. The eligibility/fit predicate is identical for both; only the exclusions differ:

- **Shared predicate:** not completed; `isEligibleToStart(on:)`; shelf has enabled rules; at least one enabled rule whose `effectiveDaysOfWeek` + `effective{Start,End}{Hour,Minute}` window actually covers the slot instant, and for which `isEffectivelyEligible(for:)` is true.
- **`.occupiedBlock` only:** excludes the block's own current task; a candidate already scheduled elsewhere still qualifies, but only with exactly one active, unlocked, incomplete block of its own (Replace frees it, Swap trades with it — both need a single movable block). Also applies the block's fixed duration as a fit check: `estimatedMinutes <= blockDuration`, or divisible with `minimumSegmentMinutes <= blockDuration`.
- **`.freeSlot` only:** requires genuinely unscheduled (nothing here to trade with; `insertBlock` creates a fresh block). No duration check — the new block is sized to whichever task is picked. `includingInbox` widens to unsorted no-shelf tasks, which only the long-press-to-insert popover wants.

Sorted by §5.1 via `AISchedulingService.taskOrdering` (now `static`, was `private`). The **Auto** button's own `nextCandidate` no longer carries a separate priority→createdAt→dueDate comparator; it reuses `taskOrdering` too, and further narrows to unscheduled candidates only — `autoReplace` has no logic to free a replacement's existing block the way `manualReplace` does, so taking a scheduled-elsewhere candidate would silently double-book it.

---

## 9. Rule editor — ✅ done, Phase 7

**The trap:** `generateProposedSchedule` filters on `rule.namedSchedule != nil`. A rule with no linked schedule renders a normal-looking summary (via the `effective*` fallbacks), appears in the shelf's rule list, appears in the task card with a live toggle — and never schedules anything. No error, no visual difference.

**§9.1 as originally written is dropped.** It called for disabling Save until a `NamedSchedule` is selected, plus an inline "create new schedule" shortcut — written against `e449f65`, assuming `SchedulingRuleEditView` could produce a rule with no schedule. It can't: rules are only ever created by `ShelfEditView.assignSchedule(_:)`, which assigns a `NamedSchedule` in the same breath. A Save guard would have been validating an unreachable state.

**What actually ships instead — the recovery path.** `namedSchedule == nil` is reachable only one way: a `NamedSchedule` was deleted out from under the rule (`.nullify`). So `SchedulingRuleEditView`'s nil case now offers **"Reassign Schedule…"**, opening a picker in place, replacing the old dead-end text ("remove this and add it again from the shelf's Assigned Schedules section") that threw away the rule's own fill-strategy config for no reason. Reassigning sets `ScheduleDirtyState.shared.isDirty` per §6.1. Unlike `ShelfEditView`'s picker, this one does not exclude schedules already used by the shelf's other rules — that guard prevents adding the same schedule twice as two rules, but this rule already exists and is only recovering a lost link.

**§9.2 unchanged and shipped.** The shelf rule list already handled this (red "No Schedule Assigned — won't pull any tasks", `ShelfEditView.swift`). The task card's Eligible Schedules section did not — it fell through to `summary`'s `effective*` fallbacks and rendered an ordinary window with a live toggle. Now shows red **"No schedule assigned"** plus "Won't pull any tasks until a schedule is reassigned", with the toggle disabled.

**Cascade:** already correct, no change — `@Relationship(deleteRule: .nullify) var namedSchedule: NamedSchedule?` (`SchedulingRule.swift:58`). Wiping rules across every shelf is a bigger surprise than a visible orphan.

---

## 10. Out of scope

Out of scope **for phases 1–7**. Four of these have since been promoted to prioritized follow-on work — see §10 Follow-On Work below, which supersedes the middle four bullets here.

- ~~Raising or removing the 30-day horizon (§6.4)~~ — **resolved** in Phase 5 (`e18ef4e`) by stall detection rather than a horizon change; see Open Decisions for the tradeoff it introduced
- Batching `fetchFreeSlots` into a single ranged `freeBusy` call → **now Follow-On #1**
- Real Claude API scheduling → **now Follow-On #2**, substantially reframed
- Background regeneration / `BGAppRefreshTask` → **now Follow-On #3**
- Splitting `DayTimelineGridView.swift` / `NightlyReviewView.swift` → **now Follow-On #4**
- Shelf-clearance projection ("when will this shelf empty") — still out of scope, unscheduled

---

## §10 Follow-On Work

Priority order. #3 depends on #1; #1, #2, #4, and #5 are independent of each other.

### 1. Batch `fetchFreeSlots` into one ranged call

First because it's nearly free. `GoogleCalendarService.fetchBusyRanges(from:to:)` (`CalendarService.swift:218`) is **already** range-based — it POSTs a single `freeBusy` query for an arbitrary span. What's missing is only that `fetchFreeSlots(for:)` (`CalendarService.swift:84`) calls it one day at a time, then does the busy→free subtraction locally.

Add a `fetchFreeSlots(from:to:)` that makes **one** `fetchBusyRanges` call across the whole walk span and slices per-day locally, applying `workingHoursRange(for:)` per day (it varies by day, so the slicing can't be a naive even split). The existing per-day method stays as a thin wrapper for callers that genuinely want one day.

Why it matters more now than when it was first deferred: Phase 5's dirty flush escalates to `regenerateFromNow` on **every** Calendar appear after an edit, and that walk runs up to `taskStallThresholdDays` (14) task days plus `habitPopulationDays` (30) habit days — each currently its own network round-trip. `FakeCalendarService.fetchFreeSlotsCallCount` already exists in the test suite and asserts exactly this count, so the batching work has a ready-made regression check.

### 2. Claude API for duration and divisibility estimation

**Reframed.** The old framing (still in the `TODO` this item replaces) was "replace the greedy mock packer with a real Claude call — same shape, just smarter task selection." That's no longer the right goal: after phases 1–7 the packer is good. It honors eligibility, fit status, minimum segments, slack ordering, and per-rule caps, and it's deterministic and testable. Replacing it with a model call would trade all of that for nondeterminism in the one part of the system that most needs to be predictable.

What the packer genuinely cannot do is **judgment**, and §3.3 turned that gap into a hard failure: a task with no duration is now permanently unschedulable. So anything captured without one — voice capture, Home Screen quick add, receipt scan — lands on a shelf and sits there dead until a human opens the card and fills in duration/divisibility by hand.

That's the job worth a model call: **estimate `estimatedMinutes`, `isDivisible`, and `minimumSegmentMinutes` from the task's title and notes.** It fits the constraints well — one call per task, cacheable on the task, off the hot scheduling path entirely, and a wrong answer is a bad *suggestion* the user can correct on the card rather than a wrecked calendar. Surface estimates as suggestions, not silent writes.

Possible second job, same call or a later one: **semantic placement hints the rule system can't express** — "this needs a clear head, put it early", "batch these two together". The rule model has no vocabulary for either.

### 3. `BGAppRefreshTask` background regeneration

`NoteForLaterApp.swift:215` carries the existing TODO. Deliberately **after #1**: a background refresh that fires a regeneration walk currently costs up to ~44 sequential network round-trips per run, which is a poor fit for a background task's execution budget and would burn battery for it. Once regeneration is one ranged call, this becomes reasonable to schedule.

### 4. Make synchronous viewmodel construction in tests fail loudly

Constructing a `ScheduleReviewViewModel` inside a **non-`async`** XCTest method corrupts the heap and takes down the whole test runner with `malloc: pointer being freed was not allocated`, before any assertion runs. Full diagnosis in the Open Decisions entry above: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes the class implicitly `@MainActor`, so its `deinit` is an isolated deinit, and releasing one with no enclosing Swift Task trips a runtime bug in task-local scope teardown.

The failure mode is the problem, not just the bug. It produces no message naming the cause, no failing assertion, and no pointer to the offending test — just a truncated run and a restart loop. **It has already been walked into twice by the same person who wrote the warning comment about it**, once while adding the §8 candidate-filter tests and again while adding the block-deletion regression tests. A comment in one file is evidently not sufficient guardrail.

Worth investigating whether this can be made self-announcing, roughly in order of preference:

- A test-only helper (e.g. `makeViewModel(...)` on the test case) that is itself `async`, so a synchronous test simply cannot call it and fails to compile rather than at runtime.
- An `XCTestCase` subclass or `setUp` assertion that detects a synchronous test method and fails with a real message.
- Failing that, a lint or CI grep for `ScheduleReviewViewModel(` inside a `func test_...()` lacking `async`.

Not urgent — no user-facing impact, tests currently pass. But the cost is paid in confusing debugging sessions each time, and the first option is cheap.

### 5. Split the two oversized views

Pure maintenance, no dependency on the others, do it whenever. `DayTimelineGridView.swift` is 2,309 lines and `NightlyReviewView.swift` is 2,179. Both have accreted several independent responsibilities — `NightlyReviewView.swift` alone holds the six-step flow, `TaskReviewCard` (the shared commit point behind every Save/Move/Skip in the app, §6.1), and the At-Risk step added in Phase 6.

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

## Open Decisions

Things currently settled only in conversation, not in this document. Each needs to land here (or get resolved) before the phase it blocks.

### Isolated-deinit crash: a Swift runtime bug, and one unproven gap

`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is set project-wide, so `ScheduleReviewViewModel` is implicitly `@MainActor` despite carrying no annotation, which makes its `deinit` an **isolated deinit**. Deallocating it with no enclosing Swift Task anywhere up the stack trips a runtime bug in task-local scope teardown and frees a pointer that was never `malloc`'d. Address Sanitizer's trace:

```
free
swift::TaskLocal::StopLookupScope::~StopLookupScope()
swift_task_deinitOnExecutorImpl(...)
ScheduleReviewViewModel.__deallocating_deinit
```

**This is a Swift runtime bug, not a defect in the viewmodel.** In practice it only bites XCTest's synchronous invocation path (`-[NSInvocation invoke]` straight into the test method), which supplies no Task; an `async` test method does. Hence every test constructing this viewmodel is `async` — the fix, not a workaround.

`nonisolated` on the class makes the sync case pass and is **explicitly rejected**: it would strip MainActor protection from a viewmodel touching `@Observable` state and a `ModelContext`, trading a test-only crash for real concurrency unsafety. `@MainActor` on the test class does not help. Releasing inside `Task {}`, `Task.detached {}`, or a sync closure called from an async test all pass, so the app's task-based release paths — including Nightly Review's background `Task {}` — are clear. Thread Sanitizer reported no data race (its own allocator died on the same bad free).

**Unproven gap:** whether SwiftUI's `@State` teardown is itself a no-Task context. If it is, the same bad free is reachable from the app rather than only from tests. Argued unlikely — the viewmodel has lived in a SwiftUI hierarchy across many launches without incident, and a genuinely no-Task teardown path would present as a reproducible launch crash rather than a rare one — but no test here settles it. Recorded so that a future malloc "pointer being freed was not allocated" in the app is recognized immediately instead of re-diagnosed from scratch. See the long note above the §8 tests in `SchedulingEngineTests.swift`.

### Task-walk horizon: 30 → 365 → stall detection → stall detection + cap

History: originally a deliberate 30-day horizon; `1bd15d3` raised it to a flat `taskSafetyCapDays = 365`; `e18ef4e` (Phase 5) replaced that with stall detection (`taskStallThresholdDays = 14`); `99996ab` excluded recurring tasks from the counter and added a `maxWalkDays = 44` ceiling — see §6.4 for the arithmetic that made the exclusion necessary.

The behavior change still stands and is now doubly bounded: a task whose only opening is more than 14 consecutive empty days out, **or** more than 44 days out at all, never reaches it. At-risk detection doesn't catch this — `isAtRisk` is slack/deadline-driven and says nothing about a no-due-date task sitting past the threshold — but §5.4's `.horizonReached` now does report it, which is the gap this entry originally flagged. Worth revisiting only if a "task silently never gets scheduled" report survives that surface.

### `dueDate` end-of-day semantics — in code, not in this doc

`c162acb` changed `slack`/`isAtRisk`/`atRiskBlocker` to measure against `endOfDueDate(calendar:)` (midnight ending `dueDate`'s calendar day) rather than the raw `dueDate` instant, and made `isAtRisk` return `false` outright when `dueDatePicked == false`. §5 doesn't describe either of these; both are load-bearing (the raw-instant version had a due-today-at-9am-reads-as-past-due-at-9:01 bug) and should be written into §5 before anyone edits that code without the conversation history.

### Dead code referenced by §6.1

`InboxViewModel.route(_ task:to shelf:)` is never called anywhere in the current codebase, and there is no "Inbox bulk submit" feature — §6.1's trigger list should not (and per the Phase 5 rewrite, does not) cite either as a real dirty-flag trigger site. Actual task-to-shelf routing goes entirely through `TaskReviewCard.advance()`'s `onMove` path. Noted here so a future read of `route(_:to:)` doesn't get treated as a call site worth instrumenting.

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
