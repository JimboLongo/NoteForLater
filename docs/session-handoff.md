# Session handoff — open queue

Detail lives in `docs/NoteForLater-Scheduling-Spec.md`; this file only says
what is open, why, and where to start. **Read the spec's two investigation
rules first** — *"tests whose failure mode is silence"* and
*"absence of evidence requires the test to have run"*. They got used
repeatedly this session — the crash-surface item at the bottom of this file
exists only because a test actually ran and something broke, not because
anyone inferred it.

---

## Shipped this session

Commits `7f52f64`…`43bd19b`. Grouped by area, not chronological.

### MealSelection lifecycle — model existed, three separate ways it leaked

- **Never registered in the app's persistent `Schema`.** The `MealSelection`
  model was added in `dd2892e` but never added to `NoteForLaterApp`'s
  `Schema([...])` list — inserting an unregistered SwiftData model type is
  undefined behavior. Predates this session; found this session (writing a
  test for the meal-purge fix below reproduced it as a real crash) and fixed
  in `7f52f64`, registered in both the app's and the test suite's schema.
- **Completed meals never purged.** `NightlyReviewView.todayMealSelections`'s
  `isCompleted` clause matched every dinner ever checked off, forever, since
  nothing ever deleted a completed `MealSelection`. Fixed in `7f52f64` —
  `purgeCompletedMealSelections()`, called alongside `purgeCompletedBlocks`
  at the same Nightly Review commit point.
- **Orphaned `ScheduledBlock` left behind.** `ScheduledBlock.mealSelection`
  has no explicit delete rule, so SwiftData defaults to `.nullify` —
  deleting the `MealSelection` left its block behind (`mealSelection = nil`,
  `isLocked = true`, `task`/`habit` both nil), which then passed
  `reviewableBlocks`'s own `mealSelection == nil` filter and reappeared as a
  phantom "Open slot" row on the same day/5pm slot as the dinner just
  purged. Fixed in `43fc4b2` — `purgeCompletedMealSelections` now deletes
  the block via `removeBlock` first.
- **Incomplete meals never purged either.** The completed-side fix above
  only ever handled completed selections — an incomplete one had nothing
  that ever cleared it, so it resurfaced in every future Nightly Review
  forever. Fixed in `e723d0c` — `resolveIncompleteMealSelections(reviewDate:)`,
  called alongside the completed-side purge, deleting the backlog
  selection's block (same nullify-orphan handling) and the selection
  itself. No pantry deduction on this path — an incomplete selection means
  the dinner never happened.
- **Picking a meal didn't update the Tomorrow step's rendered blocks.**
  `insertMealBlock` inserted straight into `modelContext` but never updated
  `tomorrowViewModel.blocks`, which is what `DayTimelineGridView` actually
  renders (a cached array, not a live fetch) — a newly picked meal's block
  existed in the store but never appeared on the calendar. Fixed in
  `e723d0c` — `registerInsertedBlock`/`deregisterBlock` on
  `ScheduleReviewViewModel`, wired into `insertMealBlock`/`removeMealBlock`.

### Completed-habit one-extra-cycle leak

`openHabitOccurrencesForReview`'s `completedRecently` check used
`cursor >= completedSinceDay`, where `completedSinceDay` is
`lastClosedReviewDay` — the day already closed out by the *previous* review
session (`NightlyReviewCompletionState.markReviewed`/`lastClosedReviewDay`).
An occurrence completed on that day was already surfaced and handled then;
`>=` let it resurface once more in the *next* review too. Changed to strict
`>` in `7f52f64`. (A test had encoded the leak as expected behavior —
`completedSince` set to the same day as the occurrence under test — and was
fixed alongside it.)

### Guaranteed next-eligible-day placement (ripple/bump)

An incomplete task in Nightly Review used to just be unscheduled and freed
up to maybe get picked up by a future general regenerate walk — a task
could sit with room genuinely free in its own eligible window and still
never actually get placed. Shipped in `6555cff`:

- `RippleSchedulingService` (shared core) makes room for an incoming
  placement: locked blocks, habit blocks, and completed blocks are fixed
  obstacles that never move; everything else on the day ripples forward to
  close the gap. Anything that would get pushed past midnight is bumped to
  *its own* next eligible day instead of overflowing into tomorrow
  unannounced.
- `ScheduleReviewViewModel.guaranteePlacement` (non-recurring misses) and
  the recurring-task app-launch catch-up walk (`NoteForLaterApp`, see below)
  both route through it.
- Recursion is capped (`RippleSchedulingService.maxDepth = 10`); hitting the
  cap inserts a `PushRecursionWarning` row instead of failing silently,
  surfaced as a red "couldn't be rescheduled" banner in `ScheduleReviewView`
  alongside the existing orange "won't fit" one.

### Location-based reminders

- `LocationMonitoringService.notifyForTag` no longer excludes a task just
  because it has a calendar block (`isScheduled` says nothing about
  physical proximity — a task scheduled for Thursday should still nudge you
  Wednesday if you're physically at the tagged place).
- Fixed the "already inside the region" gap: CoreLocation only calls
  `didEnterRegion` on a fresh boundary crossing, so being inside a region
  when monitoring starts (app launch, or any tag edit — `syncRegions`
  re-runs on every one) produced silence. `requestState(for:)` +
  `didDetermineState(_:for:)` now catch that case.
- Per-tag 1-hour debounce so a resync doesn't re-notify on every edit while
  you're still standing in the same region.
- `ContentView`'s `Tag` query now has an explicit sort, so the 20-region-cap
  truncation is deterministic if located tags ever exceed the cap.

### AM/Midday/PM recurring task blind spot

Investigation trigger: "Review Monarch Expenses" wasn't appearing on the
calendar or surfacing as missed anywhere. Root cause, confirmed by pulling
the live device store (not by reading): an AM/Midday/PM recurring
`TaskItem` never gets a `ScheduledBlock` at all, so `NightlyReviewView`'s
capture loop (block-only) could never see it — and nothing else in Nightly
Review ever consulted `RecurringTaskLog` either. A miss simply evaporated,
with no `PushedRecurringOccurrence` ever created to carry it forward.

- `ScheduleReviewViewModel.openRecurringTaskOccurrencesForReview` /
  `pushMissedRecurringOccurrences` close the gap, sourced from
  `RecurringTaskLog` instead of a block.
- `PushedRecurringOccurrence.advanceOneHop` extracted so the app-launch
  catch-up walk (`NoteForLaterApp.processPushedRecurringOccurrencesIfNeeded`)
  and one immediate hop from Nightly Review's own today→tomorrow transition
  share a single implementation — a miss can now show up the *same night*
  instead of waiting for the next app launch.
- The same-night-relaunch double-placement question was verified on the
  iOS Simulator (not just reasoned through): fabricated a pending
  occurrence already hopped to tomorrow, forced a relaunch, confirmed no
  second block and no further advance. A positive-control occurrence
  genuinely several days behind was walked forward and correctly resolved
  in the same run, ruling out "the mechanism is just inert" as an
  alternative explanation for the clean result.

### StepAutoSkip

Nightly Review auto-skips empty 2-Minute Tasks / Inbox / At Risk / Meals
steps with a brief non-blocking toast, looping past more than one empty
step in a single Next tap and running every step's real entry side effects
along the way (staged-toggle commits, starting the Inbox review session,
the recurring-occurrence push) rather than silently dropping them. Today
and Tomorrow are never eligible to skip. `back()` mirrors the same walk in
reverse, live-re-checking emptiness rather than replaying a stale skip
list. `Services/StepAutoSkip.swift`.

### Move-to-slot in the empty-slot picker

Long-pressing an open calendar slot now also lists already-scheduled tasks
(gated to a single, unlocked, incomplete block — same reasoning
Replace/Swap already uses) with their current time. Picking one *moves*
that block (`ScheduleReviewViewModel.moveExistingBlock` + `insertWithRipple`)
instead of creating a second one.

### Inbox 2-minute engagement timer

A 2-minute minimum-engagement floor on Nightly Review's Inbox step, one
budget per session — resumes rather than resets across Cancel/"Review
Again". While time remains and unresolved items remain, reaching the end
of the queue wraps back around instead of finishing; "Skip Remaining" stays
disabled (with the remaining time shown on it) until the floor expires.
Finishing because everything is genuinely resolved always proceeds
immediately, regardless of time left. `Services/InboxEngagementTimer.swift`.

### Recurrence frequency label

Shelf task cards show a recurring task's cadence — `TaskItem
.recurrenceSummary`: "Every 3 days", "Every week until Oct 14", dropping
the numeral at a 1x interval.

### Empty-slot eligibility override

The empty-slot picker now lists every schedulable task, not just eligible
ones — an ineligible task appears grayed out with a reason ("Starts Sep
12", "Outside Work – Afternoons") but stays fully selectable, since placing
something by hand is a deliberate override.
`ScheduleReviewViewModel.evaluateCandidates` is the one evaluation behind
every "what can go here" picker (Replace/Swap, Auto-Replace, the
empty-slot sheet); only the empty-slot context turns three exclusions soft.
`ScheduledBlock.manuallyPlaced` is what makes this actually stick — a
hand-placed ineligible block was confirmed (by test, not by reading) to get
swept by the very next `autoPlaceEligibleTasks` pass otherwise, since that
runs on essentially every Calendar tab appear.

### Choose Day → planning reframe

Nightly Review's first step is relabeled from "which day are you
reviewing?" to "which day are you planning?" (Today/Tomorrow) —
`reviewDate`'s own meaning is unchanged, only the labels moved. The "Today"
option's old gate (disabled when yesterday had nothing to review) is gone —
planning today must always be available. The one-time default nudge is now
time-of-day aware (before noon → default Today, at/after → default
Tomorrow) instead of backlog-based. `Services/ChooseDayPlanning.swift`.

### Nightly Review completion-leak bug class — four instances, found separately, weeks apart

**Uncommitted as of this writing** — fixed this session, on top of
`43bd19b`, not yet in a commit.

The reported symptom: tasks checked off in last night's Nightly Review
showed up again, still unchecked, in tonight's Today step (five items,
confirmed via the live device store — all five completed the same day
`lastClosedReviewDay` had just closed out). That's the fourth time this
exact bug class has been found, each time separately, each time by
noticing a UI symptom rather than by review or a test catching it. It's
worth naming as a class because the pattern — found once, "fixed," found
again somewhere else weeks later — means there are probably still more
instances than the ones caught so far.

**Two shapes, both currently live in this codebase (one still unfixed —
see below):**

1. **`>=` against a day-granular "since" value.** `TaskCompletionRecord
   .completedAt` is a full timestamp; `NightlyReviewCompletionState
   .lastClosedReviewDay` is day-granular (`startOfDay`, see
   `markReviewed`). Comparing `completedAt >= lastClosedReviewDay`
   re-admits every record from the day *just* closed into the very next
   review — the day is "since," inclusive, when it should mean "before
   this, already handled." Found in `ScheduleReviewViewModel
   .openHabitOccurrencesForReview` first (fixed earlier this session as
   `cursor > completedSinceDay`), missed in `NightlyReviewView
   .completedTasksWithNoBlock` (this bug report) and, found while fixing
   that, missed a third time in the Two-Minute-Tasks step's own copy of
   the same filter (`runEntryEffects(for: .twoMinuteTasks)`).

2. **An `isCompleted` check OR'd into a filter with no date bound at
   all**, e.g. `startTime < cutoff || isCompleted` or `isCompleted ||
   date <= cutoffDay`. Whatever bound governs the *other* side of the OR
   does nothing for the `isCompleted` side — a completed record from any
   day, however long ago, matches forever. In every instance found, this
   was masked by a purge (`purgeCompletedBlocks`,
   `purgeCompletedMealSelections`) deleting the completed record before
   it could ever accumulate — meaning the filter itself was never
   correct, only the surrounding cleanup made it look correct. **That
   masking is exactly what let this survive undetected**: nobody could
   see the filter was wrong because the purge always ran before the gap
   was ever exercised. Found in `NightlyReviewView.reviewableBlocks`
   (this bug report's second, independent finding) and in
   `todayMealSelections` (found during the sweep that followed — same
   shape the `reviewableBlocks` doc comment had already named as
   precedent, just never itself fixed until now).

**The no-op trap, worth remembering on its own:** the obvious-looking fix
for shape 2 — add a date bound onto the `isCompleted` side, e.g. `A ||
(isCompleted && startTime >= someBound)` — is a **Boolean identity no-op**
whenever `A` already covers every date the unbounded `isCompleted` could
otherwise reach: `A || (B && ¬A) ≡ A || B`, for any A/B. It compiles,
reads like a fix, survives a shallow review, and changes the output for
*zero* inputs. The only way to actually close the gap is to stop
OR-ing and split the two cases outright — `isCompleted ? startTime >=
completedSinceBound : startTime < cutoff` — so a completed record's
admission no longer depends on whether the incomplete-side bound would
have let it through anyway. Caught this by working out the truth table
before shipping the obvious version, not by testing — the no-op version
would have passed every test that only checks *today's* data, since
today nothing is ever old enough to exercise the gap.

**Fix:** centralized the day-granularity bound as
`NightlyReviewCompletionState.completedSinceBound` (a static function,
`completedSinceBound(closedDay:calendar:)`, plus an instance convenience
reading the singleton) — the start of the day *after* the closed day, so
a plain `>=` against a full timestamp lands on day granularity without
needing a `Calendar` call inside a `#Predicate` (unsupported there).
`completedTasksWithNoBlock`, the Two-Minute-Tasks filter,
`reviewableBlocks`, and `todayMealSelections` all route through it now.
`reviewableBlocks`/`todayMealSelections` also got the split-not-OR
restructure above.

**Regression coverage:** `NoteForLaterTests/NightlyReviewCompletionLeakTests.swift`
— per-instance tests for the two named in the bug report, plus a
table-driven class-level pair (`test_noReviewPath_surfacesCompletionFromTheClosedReviewDay`
/ `test_everyReviewPath_stillSurfacesCompletionFromAfterTheClosedReviewDay`)
covering all four paths that feed `NightlyReviewView.reviewItems` (habit
occurrences, blocks, completed-with-no-block tasks, meal selections) from
one shared table — add a row for a new path rather than a new test.
Verified this actually catches the class, not just the instances already
fixed: reverted `todayMealSelections` to its pre-fix shape and reran only
the class test — failed, naming that exact path. Restored, reran: green.

**Swept for more instances; one more shape-match found, not fixed — it's
harmless.** `markUnresolvedHabitOccurrencesAsMissed`'s `sweepBlocks`
filter (`($0.startTime < reviewCutoff || $0.isCompleted) && $0.habit !=
nil`) has the identical unbounded-OR shape, but it only decides which
blocks get *checked* by the missed-sweep, not what's *displayed* — every
block that reaches the loop is gated by `guard status == .none else {
continue }` against the authoritative `HabitLog`, so an old completed
block slipping in via the `isCompleted` branch gets read and skipped,
never mis-marked. Recording this so it isn't re-discovered and
mis-diagnosed as a fifth live instance later — it's the same shape,
verified inert.

### Habits screen: static order, four-state cycle, date navigation

- **Order.** The Today list's order is now fixed — `Habit.todayOrderKey`:
  frequency (more days/week first), then occurrence-0's time of day, then a
  stable `sortOrder`/name tiebreak — instead of a "what's coming up next"
  queue keyed off completion state, which needed a debounce
  (`displayedHabits`) to stop rows jumping mid-tap. The debounce is gone;
  `nextTargetDate`, the function it was built on, is gone too (fully dead
  once nothing called it any more).
- **Cycle.** Tapping an occurrence circle now cycles all four states (none
  → complete → missed → excused → none, `OccurrenceStatus.next`) instead of
  just complete/none — missed/excused used to be reachable only from a
  habit's own detail calendar. Marking one from this screen correctly drops
  it out of Nightly Review's open list, same as the detail calendar already
  did (`openHabitOccurrencesForReview`'s `status == .none` filter — see the
  spec's own warning about that filter before touching it). Extracted onto
  the model as `Habit.cycleOccurrence` for testability.
- **Date navigation.** Left/right chevrons navigate days; a future day is
  viewable but not editable. `HabitsTodayDayList` is a child view re-created
  via `.id(selectedDate)` per day, since SwiftData `@Query` predicates can't
  be mutated after `init` — chosen over a manual fetch specifically to keep
  `@Query`'s live cross-screen observation (a completion made on the
  Calendar tab still shows up here instantly; a manual fetch driven by
  `selectedDate` would have regressed that to the 3-second idle-tick
  debounce).

---

## Open

### #4 — event duplication across days in day view — still genuinely unresolved

**Not observed since the last investigation round — but nobody has been
looking for it either, and it was not found, only lost its repro.** Do not
record this as fixed or likely fixed.

It's plausible this was resolved *incidentally* by the orphaned-`ScheduledBlock`
fix (`43fc4b2`) or the guaranteed-placement/ripple work (`6555cff`) — both
touch block lifecycle and placement in ways that could have papered over
whatever caused this — but that is a guess, not a finding. Nothing this
session deliberately tested for it.

Do not restart from **"it's `.startTime` corruption"** — that hypothesis
was tried and the one piece of ground-truth evidence obtained *contradicts*
it (and the other two hypotheses tried alongside it):

- Hypothesis 1 (`moveEntry` desyncs `.date`/`.startTime` during
  drag-reorder): a fix was implemented, deployed, and caused a regression
  (a task appearing on every day). Fully reverted; confirmed via `git diff`
  no trace remains.
- Hypothesis 2 (genuine data duplication — two block records): every
  `.startTime =` write site in the app was grepped (4 total, all behind
  explicit drag gestures, one dead code). Nothing found that explains a
  duplicate write outside a user-initiated drag.
- Hypothesis 3 (`.startTime` dynamically resetting to "now"): temporary
  diagnostic logging dumped every matching block's raw
  `id`/`date`/`startTime`/`endTime`. The one capture obtained (before the
  repro tasks were deleted mid-investigation) showed **exactly one block,
  `.date` and `.startTime` both correct and internally consistent** — no
  duplication, no corruption.

**First step:** recreate a reproducible test case (a task that shows up on
multiple days in day view but correctly once in week view) and re-add
targeted diagnostic logging *before* touching any fix — the last round
ended because the repro tasks were deleted mid-investigation, not because
the bug was found or fixed. Get a log capture spanning the moment the
duplicate *appears* in day view, not just a static dump at load time.

### Split `DayTimelineGridView` / `NightlyReviewView` — genuinely structural, deliberately deferred

**Perf investigation: instrumented on-device, not reproduced — record
this as a failed reproduction, not an open hypothesis.** The reported
symptom was a ~3 second lag tapping a recurring task occurrence on the day
calendar (habit occurrences on the same screen felt instant). The leading
hypothesis — recurring tasks doing a per-task, uncached `RecurringTaskLog`
fetch inside `openRecurringTaskOccurrences`, amplified by the same
over-invalidation problem this entry describes — was **contradicted, not
confirmed**, by real measurement:

- Recurring-task tap: **1 body pass**, **7 `RecurringTaskLog` fetches**,
  **22–29ms** total (tap-handler entry through the body pass computing the
  fresh occurrence lists).
- Habit tap: **2 body passes**, **55 fetches**, **55–65ms** total —
  *more* body passes and *more* fetches than the recurring-task tap, not
  fewer, even though habits are the ones that feel instant. That's the
  opposite of what the hypothesis predicted.
- Nothing anywhere near 3 seconds turned up in the write
  (`logOrCreate`/`upsert`/`TaskCompletionRecord`), the
  `habitOccurrenceRefreshTick` increment, the body re-evaluation it
  triggers, or the occurrence-list recompute. `habitOccurrenceRefreshTick`
  *is* confirmed as the real re-render driver — every increment was
  followed by a body pass within 1–5ms, every time, across every tap
  captured.
- **The bug did not reproduce during the instrumented test**, and — this
  is the actual gap, not a footnote — whether the tap that was performed
  *felt* slow was never confirmed either way. Without that, "didn't
  reproduce" could mean the bug is intermittent/condition-dependent, or it
  could mean this test run simply wasn't the right conditions.

Do **not** re-open this by instrumenting deeper into the read/write path —
fetch counts, fetch timing, write timing, and body-eval count are already
measured and cleared; going back over that ground again without new
information would just repeat this round. If it reproduces again:

1. Reproduce it *while the diagnostic log is live*, and note what's
   different about that moment — cold start, a day with unusually many
   blocks, a specific task, the phone under load from something else.
   Condition-dependent bugs need the condition, not another clean-room tap.
2. Only if it reproduces and the existing instrumentation still shows
   nothing (i.e. the numbers above look the same even though it felt
   slow): move the measurement downstream of where this round stopped —
   full `body` cost (not just `computeOpenHabitOccurrenceLists()`), and
   actual SwiftUI diff/layout/paint or commit timing. That's genuinely
   unmeasured territory; the read/write path isn't.

If a reproduction *does* eventually implicate this same over-invalidation
problem, the fix is the rest of this entry, not a new diagnosis — that's
why the structural case below is kept regardless of this investigation's
outcome.

**Already established:** three independently-chased problems all landed on
`DayTimelineGridView` being too large a unit of invalidation — habit-tap
render cost (2 full passes per tap), the parent `@Query allHabits` re-run
(fired 18/18 taps), and drag auto-scroll (243 body evals in ~10s).
**Making the body cheaper helped all three and fixed none** — the scope
never changed, only the cost per pass. Don't re-run a body-cost fix here
expecting a different result; it's been tried, on this exact file, more
than once.

Full argument lives in the spec's own §10 #5 entry — this is the pointer,
not a duplicate of it.

**Scoping (Half A / Half B):** extracting the habit sections is *not* free
isolation — geometry plumbing feeds `precedingContentHeight`, so the split
has to carry that dependency with it, not assume it away. Stopping the
parent from observing habits at all is a data-flow contract change, not a
refactor — treat it as its own decision, not a side effect of moving code
around.

**First step (for the structural split itself):** Half A. Not currently
tied to the perf investigation above — that investigation didn't confirm
this is the same problem, so don't start here *because of* the recurring-
task lag. Start here if/when the structural split is picked up on its own
merits, and if a future reproduction of the lag does implicate this same
over-invalidation problem, doing Half A first still means opening this
file only once either way.

### `startDate` cannot be cleared once set — real bug, unreported elsewhere

**The only written record of this bug is this entry** — it was never
folded into the spec, so removing it here deletes it entirely. Re-verified
against current code for this rewrite (line numbers below are current, not
copied from an earlier draft):

- `TaskItem.isEligibleToStart` returns `true` when `startDate` is `nil`,
  but gates packing on it once set (`TaskItem.swift:232`,
  `guard let startDate else { return true }`).
- The Start Date row displays `task.startDate ?? .now`
  (`NightlyReviewView.swift:2007`) — **a nil start date renders as
  today**, indistinguishable from one deliberately set to today.
- The picker's binding only ever assigns
  (`NightlyReviewView.swift:2022-2024`, `set: { task.startDate = newValue }`)
  — `grep "startDate = nil"` across the whole app still returns nothing.

**Consequence:** opening the picker and touching it sets a start date
permanently. Pick a date by accident (or just experimentally) and that
task is unschedulable until it arrives, with no way back through the UI.
For a recurring task the same setter also rewrites `dueDate`
(`NightlyReviewView.swift:2031-2035`, since Start Date doubles as the
recurrence anchor), so the blast radius is larger there.

**First step:** decide the intended semantics before writing code — is "no
start date" a state the UI should express at all? If yes, this needs a
clear affordance and a distinguishable empty display, mirroring how
`TaskReviewCard` handles *"Has due date → No"*
(`dueDateDecided = true; dueDate = nil; dueDatePicked = false`) — that's
the existing precedent for how this app represents "explicitly no value"
as distinct from "never touched." If no, the nil case should be eliminated
rather than left silently reachable.

### #5 — 2-Minute Tasks tap-to-edit → `TaskCardSheet`

Not started.

### #1 — meal ingredient checklist → interactive pantry deduction

Not started.

### New — `TaskItem.title.getter` crash surface (latent, not currently reachable)

Found this session while verifying the AM/Midday/PM push-chain fix in the
iOS Simulator: a `ScheduledBlock`/`TaskItem` row missing values for
non-optional stored properties (`priorityRaw`, `notes`, `nextStep`, or an
un-decodable transformable like `tags`) traps in `TaskItem.title.getter` —
a SwiftData macro-generated property accessor — the instant anything reads
`.title` on it. Concretely: `DailyDigestNotificationService.openItems` →
`ScheduledBlock.displayTitle.getter` → `TaskItem.title.getter`, called from
`DailyDigestNotificationService.reschedule` at app launch.

**Not reachable through any normal app flow today** — this was only
produced by writing malformed raw SQL rows directly into the SQLite store
for a test scenario, bypassing the app (and SwiftData's own initializers)
entirely. Flagging it anyway because of how close the MealSelection story
above came to the same failure class for real: `dd2892e` shipped a model
that was silently half-wired into the persisted schema for a full session
before `7f52f64` caught it, and only did so because a test happened to
exercise the crash. A future schema change to `TaskItem` or `ScheduledBlock`
that leaves a row partially migrated could reproduce this same trap for a
real user, not just a fabricated store. Worth a defensive read or a
migration audit before the next schema change touches either model — not
urgent on its own, but worth remembering the shape of it.

---

## Current state of the habit subsystem

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
weakening the filter reopens data corruption regardless of the guard. This
is load-bearing, not history: it was cited and relied on twice this
session, most recently for the four-state habit cycle change above.

---

Written 2026-09-08. Dropped the 2026-08-24 six-issue queue's bookkeeping
items (§10 doc-drift, the priority-order note) and the 2026-08-21
habit-investigation's parked tap-feedback item — all either completed
work being tracked as open, or deliberately parked with no next step.
`BGAppRefreshTask` (old §10 #3) can be rediscovered from the spec if
picked up. Everything else from those two lists is either shipped (above)
or restored (Open, this trailer). See git history (`7f52f64`…`43bd19b`)
rather than this file for anything from before this rewrite.
