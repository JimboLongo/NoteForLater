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

### 1.2 `TaskItem.isNightlyReviewed` (new) — ✅ done, Phase 6

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

## Open Decisions

Things currently settled only in conversation, not in this document. Each needs to land here (or get resolved) before the phase it blocks.

### Task-walk horizon: 30 → 365 → stall detection

History: the walk was originally capped at a deliberate 30-day horizon; `1bd15d3` raised it to a flat `taskSafetyCapDays = 365`; `e18ef4e` (Phase 5) replaced that flat cap with stall detection (`taskStallThresholdDays = 14` consecutive days placing zero task blocks). This is a real behavior change worth naming explicitly: a task that's eligible and fits, but whose only opening is more than 14 consecutive empty days out, now never reaches that opening — the walk gives up first. At-risk detection (§5.3) doesn't catch this either, since `isAtRisk` is slack/deadline-driven and has nothing to say about a task with no due date sitting past the stall threshold. Not blocking any phase today, but worth flagging if a "task silently never gets scheduled" report ever comes in.

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
