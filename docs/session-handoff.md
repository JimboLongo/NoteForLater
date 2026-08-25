# Session handoff — open queue

## 2026-08-24 — six-issue queue, tier 1/2 status

Six issues were triaged this session, tackled in tier order. Current state:

**Done:**
- **#3 — deleted task's Tomorrow step didn't persist.** Root cause:
  `NightlyReviewView`'s Done/Close buttons called `dismiss()` with no paired
  save, relying on non-guaranteed SwiftData autosave. Fixed via
  `finishAndDismiss()` (`try? modelContext.save(); dismiss()`), both buttons
  now route through it. Shipped in `d99dbdb`.
- **#2 — incomplete recurring tasks should push forward, not vanish.**
  `PushedRecurringOccurrence` (taskID/originalDate/currentDate/isCompleted)
  is captured in `NightlyReviewView.advance()` before
  `clearIncompletePastBlocks` deletes the incomplete block. On launch,
  `NoteForLaterApp.processPushedRecurringOccurrencesIfNeeded` →
  `advanceOneDay` walks `currentDate` forward — **the whole gap in one
  call**, not one day per launch (traced through the 9/1→9/2→9/3→9/4
  example, confirmed correct) — relocating one placeholder `ScheduledBlock`
  as it goes (never leaving orphans at intermediate days), stopping the
  instant the next day is a real recurrence. `recurrenceEndDate` is
  deliberately never checked. Shipped in `d99dbdb`. Still wants real
  on-device, multi-day verification — nothing in this session simulated an
  actual multi-day gap between launches, only traced the code by hand.

**Open — #4, event duplication across days in day view — genuinely
unresolved, NOT "root cause found":**

Investigated across several rounds this session, no confirmed root cause.
Do not restart from "it's `.startTime` corruption" — that hypothesis was
tried and the one piece of ground-truth evidence obtained *contradicts* it.

- Hypothesis 1 (moveEntry desyncs `.date`/`.startTime` during drag-reorder):
  implemented a fix, deployed, user reported a regression (Clean Up Office
  appearing on every day). Fix was fully reverted; confirmed via `git diff`
  no trace remains in `ScheduleReviewViewModel.moveEntry`.
- Hypothesis 2 (genuine data duplication — two block records): grepped
  every `.startTime =` write site in the app (4 total, all behind explicit
  drag gestures, one — `reorderTimeline`/`TimelineEntryRef` — dead code,
  never called from anywhere). Nothing found that explains a duplicate
  write outside user-initiated drags.
- Hypothesis 3 (`.startTime` dynamically resetting to "now"): added
  diagnostic logging (`ScheduleReviewView.logDuplicateInvestigationBlocks`,
  since **removed** in `d99dbdb` — temporary, hardcoded to "clean up
  office"/"fsa account") dumping every matching block's raw
  `id`/`date`/`startTime`/`endTime` on `setupIfNeeded()`. The one capture
  obtained (before the user deleted the test tasks) showed **exactly one
  block each, `.date` and `.startTime` both correct and internally
  consistent** — no duplication, no corruption. This is evidence *against*
  all three hypotheses, not confirmation of any.

**First step:** recreate a reproducible test case (a task that shows up on
multiple days in day view but correctly once in week view) and re-add
targeted diagnostic logging *before* touching any fix — the last round
ended because the repro tasks were deleted mid-investigation, not because
the bug was found. Get a log capture spanning the moment the duplicate
*appears* in day view, not just a static dump at load time.

**Not started:** #5 (2-Minute Tasks tap-to-edit → `TaskCardSheet`), #1
(meal ingredient checklist → interactive pantry deduction).

**Next session:** #4 (finish the investigation with a fresh repro before
attempting any fix), then #5, then #1 if time allows.

---

Written 2026-08-21, after the habit-tap investigation (commits `2318fb0`…`3baf55e`).

Detail lives in `docs/NoteForLater-Scheduling-Spec.md`; this file only says
what is open, why, and where to start. **Read the spec's two investigation
rules first** — *"tests whose failure mode is silence"* and
*"absence of evidence requires the test to have run"*. They were learned
expensively in the last session and apply to everything below.

---

## 1. §10 Follow-On #1 is DONE but the doc says otherwise — fix the doc

**State:** Shipped in `493b236` (ranged `fetchFreeSlots(from:to:)` added to
the protocol and both implementations) and `176ab46` (both scheduling walks
batched, per-day fallback retained). Verified present:
`CalendarService.swift:80` (protocol), `:153` and `:419` (implementations).

**Why still open:** §6.4 was updated to reflect the batching; **§10 #1 was
not**. It still opens *"First because it's nearly free… What's missing is
only that `fetchFreeSlots(for:)` calls it one day at a time"* — describing
work that is already done. A reader following the priority order would
start on a finished task.

**First step:** Rewrite §10 #1 as completed, citing both commits, and keep
the `FakeCalendarService.fetchFreeSlotsCallCount` regression check note —
that assertion is the thing that keeps it fixed.

---

## 2. §10 priority order is stale — revise it

**Why still open:** The list is ordered *"#3 depends on #1; #1, #2, #4 and
#5 are independent."* With #1 done, that dependency is discharged and #3 is
unblocked, so the stated order no longer reflects reality.

**First step:** Renumber or re-rank after #1 is marked done. Note in passing
that #4 (make synchronous viewmodel construction in tests fail loudly) is
unrelated to the rest and can be done any time.

---

## 3. `startDate` cannot be cleared once set — real bug, unreported

**Not previously written up anywhere.** Verified in code this session.

- `TaskItem.isEligibleToStart` returns `true` when `startDate` is nil, but
  gates packing on it once set (`TaskItem.swift:211`).
- The Start Date row renders `task.startDate ?? .now`
  (`NightlyReviewView.swift:1373`) — **a nil start date is displayed as
  today**, indistinguishable from a deliberately-set one.
- The picker's setter only ever assigns
  (`NightlyReviewView.swift:1390`), and `grep "startDate = nil"` across the
  app returns **nothing**.

**Consequence:** opening the picker and touching it sets a start date
permanently. Pick a future date by accident and that task is unschedulable
until it arrives, with no way back. For a recurring task the same setter
also rewrites `dueDate`, so the blast radius is larger.

**First step:** decide the intended semantics before writing code — is
"no start date" a state the UI should express at all? If yes, this needs a
clear affordance and a distinguishable empty display, mirroring how
`TaskReviewCard` handles *"Has due date → No"*
(`dueDateDecided = true; dueDate = nil; dueDatePicked = false`). If no, the
nil case should be eliminated rather than left silently reachable.

---

## 4. §10 #3 — `BGAppRefreshTask` background regeneration — now unblocked

**Why still open:** It was deliberately gated on #1, because a regeneration
walk cost up to ~44 sequential network round-trips — a poor fit for a
background execution budget. #1 removed that.

**First step:** Re-read §10 #3 and the TODO at `NoteForLaterApp.swift:215`,
then confirm the round-trip count is actually what §6.4 now claims before
building on it. **Measure it; don't infer it from the commit message.**

---

## 5. §10 #5 — split `DayTimelineGridView` / `NightlyReviewView`

**Why still open:** Genuinely structural, deliberately deferred.

**Already established** (see §10 #5, which now carries the full argument):
three independently-chased problems all landed on `DayTimelineGridView`
being too large a unit of invalidation — habit-tap render cost (2 full
passes per tap), the parent `@Query allHabits` re-run (fired 18/18 taps),
and drag auto-scroll (243 body evals in ~10s). **Making the body cheaper
helped all three and fixed none** — the scope never changed, only the cost
per pass.

The spec also carries the Half A / Half B scoping: extracting the habit
sections is *not* free isolation (geometry plumbing feeds
`precedingContentHeight`), and stopping the parent observing habits is a
data-flow contract change, not a refactor.

**First step:** Half A, as the first move of the split rather than a
standalone perf fix — doing it separately means opening this file twice.

---

## 6. Fix 5 — habit row tap feedback — parked deliberately

**Not forgotten, not abandoned.** Full reasoning in the spec entry
*"Deferred deliberately: immediate tap feedback on habit rows."*

Short version: the taps were never actually being dropped — 20 rapid taps
registered cleanly, and the unacknowledged tap was a completion landing in
a `HabitLog` row nothing read back. Adding feedback then would have masked
corruption rather than fixed it.

**First step:** none yet, by choice. It depends on whether the rows still
feel unresponsive after a few days of ordinary use **now that taps take
effect**. If picked up, keep the checkmark/fade/strikethrough semantics —
an already-complete row stays visible rather than disappearing.

---

## Current state of the habit subsystem

Clean as of 2026-08-21: `dupDays=0`, `extraLogs=0`, `violatingLogs=0`,
90 tests passing.

Three permanent `DiagFileLog` signals remain, each boring by design — the
day one isn't is the day you want to know:

| Signal | Meaning if it appears |
|---|---|
| `REJECTED` | the scheduler tried to double-book and was stopped |
| `REPAIR` | the one-shot `HabitLog` migration ran |
| `SWEEP ENTER` | the nightly sweep ran; `untimedOccurrences=0` means the run was vacuous |

⚠️ Before touching the nightly sweep or `openHabitOccurrencesForReview`,
read *"What actually protects the untimed path"* in the spec. The untimed
path is protected by the `status == .none` **filter**, not by the guard —
weakening the filter reopens data corruption regardless of the guard.
