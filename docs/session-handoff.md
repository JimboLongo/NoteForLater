# Session handoff — open queue

Detail lives in `docs/NoteForLater-Scheduling-Spec.md`; this file only says
what is open, why, and where to start. **Read the spec's two investigation
rules first** — *"tests whose failure mode is silence"* and
*"absence of evidence requires the test to have run"*. They got used
repeatedly this session — the crash-surface item at the bottom of this file
exists only because a test actually ran and something broke, not because
anyone inferred it.

**Deletion practice, general — a deletion list is a hypothesis, not an
inventory. Re-derive every site by reading it at delete time.**

Stage 4b started from a list of eight call sites to delete, written during
planning and reviewed and approved before any code was touched. **Three of
the eight were wrong.** Re-reading each site at delete time caught all
three; working from the list would not have.

The worst was `DayTimelineGridView.openRecurringTaskOccurrences(mode:)`,
listed as dead Specific-Time machinery. It is the opposite: it matches
untimed modes, so after the change it became the path *every* recurring
task takes. Deleting it would have removed recurring tasks from the day
view entirely — a silent, total feature loss, from a line in an approved
plan. The other two (`OverdueBlocksReviewList.blocksGate`'s `.specific`
branch, and the task arm of the stale-block sweep) were both still
reachable: the migration deliberately keeps *past* blocks, so paths that
read historical blocks stay live.

**Approval does not make an entry correct.** The reviewer is reading the
same summary that was written from the same misreading; they are checking
the shape of the plan, not re-deriving each site. Treat every entry as
"this looked dead when I wrote it down" and re-confirm against the code.

**The same trap, in the form that bites tests: a test's *subject* is not
the same as its *coverage*.** Before deleting a test alongside deleted
code, check what else it was the only cover for. Nothing goes red when you
remove the only test protecting something that still exists — the suite
gets smaller and stays green, and the loss is silent by construction.

Hit in stage 4b. Three `advanceOneHop` tests were built around the
Specific-Time placeholder block, which was being deleted, so they looked
like obvious companions to it. They were also the *only* coverage of
`advanceOneHop`'s date walk — which survives, and is live. Deleting them
would have left it bare with a green 547-test run. Caught by grepping for
remaining callers after the removal, finding none, and writing two
replacements that pin the surviving half directly.

**The signal to look for:** the test constructs or exercises anything that
outlives the deletion, even incidentally. If the body touches a surviving
function at all, assume it may be that function's only cover until you've
checked. The check is cheap — grep the survivor's name across the test
target after deleting — and it is the only thing standing between you and
a silent coverage hole.

Three signals that a line in a deletion list is not actually dead:
1. **It names a mode/flag/state by value.** `== .specific` is dead if that
   value is unreachable; `== mode` where `mode` is a parameter is not the
   same thing at all, and reads almost identically in a list.
2. **It reads history.** Anything touching past or completed rows survives
   a migration that only cleans up future ones.
3. **It sits in a function with another caller's arm in it.** Shared
   habit/task bodies were where every mistake here clustered.

**Testing practice, general — sabotage each rule against the EXISTING
suite before adding new tests.** Break the rule deliberately, run what's
already there, and see what fails. A rule that no test catches is
invisible to a green run, and "the suite passes" says nothing about it.

This was not hypothetical. A regression shipped (Duration/Divisible
rendering for untimed recurring tasks) because the tests asserted the
*missing-check* while nothing asserted *row visibility* — two facts that
had silently diverged. When the row rules were later unified behind
`CardRow`, sabotaging them against the pre-existing suite found a second
uncovered rule the same way: removing the shelf guard on Duration was
caught by **nothing at all**, while removing the recurring guard on
Priority was caught by exactly one test. Neither gap was visible from
reading the tests or from a passing run — only from breaking the code and
watching what stayed green.

Do this before writing new tests, not after: it tells you which rules are
actually unprotected, rather than letting you write coverage for the ones
you happened to think of. Fail-then-pass on a *new* test proves that test
works; sabotage against the *old* suite proves what the old suite was
missing. They answer different questions.

**Test-harness trap — and the reason two real rules had zero coverage.
This is not merely a gotcha; read it before concluding any scheduling code
is untestable.**

**The rule:** an XCTest method that constructs *any* implicitly-`@MainActor`
class — `ScheduleReviewViewModel`, `MockAISchedulingService` (the
production packer; the name is a leftover) — **must be `async`**. Bare
construction is enough to trigger it. Doing nothing else with the object
still crashes.

**The symptom, which is the important part:**
```
NoteForLater(…) malloc: *** error for object 0x…: pointer being freed was not allocated
	 Executed 0 tests, with 0 failures (0 unexpected)
** TEST FAILED **
```
The host dies *before any assertion runs*. The run reports **zero tests
executed and no failing test named** — so there is nothing pointing at your
test, and the only visible artifact is a malloc abort inside a call to
production code. **It presents as "the scheduler is broken," not as "my
test is shaped wrong."** A reasonable person writing the first test for
`placeHabitsAndRecurringTasks` sees a crash in the packer, concludes
they've found a real bug or that the code can't be exercised in isolation,
and stops. That is the most plausible reason both habit block-placement
rules went uncovered while 553 other tests passed.

**The fix is the single word `async` on the test method.** Nothing else.

**Root cause** (full version in the scheduling spec's Open Decisions):
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes these classes implicitly
`@MainActor`, so `deinit` is an *isolated* deinit. Releasing one with no
enclosing Swift Task trips a runtime bug in task-local scope teardown.
Nothing about the class's own code is involved, which is why reading it
tells you nothing.

⚠️ **The earlier version of this note was worse than no note at all.** It
attributed the crash to `ScheduleReviewViewModel`'s `deinit` specifically.
The mechanism was right, the scope was wrong — and stated that narrowly, it
actively misleads: anyone hitting this while constructing a *scheduling
service*, with no view model anywhere in the test, would read the note,
correctly conclude it didn't apply to them, and go on believing they'd
found a production crash. A note scoped to one class is a note that
excludes every other class. State the rule by the property that causes it
(implicitly `@MainActor`), not by the one example where it was first seen.

**Testing practice, general — a rule and its rendering can agree on every
case and still be two separate expressions that drift. The failure shows up
as a render that *didn't* move, which nothing goes red for.**

`CardRow` exists so "does this row apply" is answered once. It was working:
the `.shown ⟺ missable` invariant held throughout, every missing-check
routed through it, and the visibility matrix was fully covered.

**What was missing is the other half: `.hidden ⟹ not drawn`.** The card body
drew the Due row unconditionally and gated Duration only on
`recurringAndUntimed`. Neither consulted `CardRow` at all. So changing
`CardRow.due` from `.greyed` to `.hidden` had *zero* visible effect — the
shelf's own Due toggle still did nothing to whether the row appeared.

**Why nothing caught it.** Every baseline passed, because the render was
unchanged — and an unchanged render is what passing looks like. A
regression that *removes* an effect is invisible to a net built to notice
changes. It surfaced only because the change was expected to move three
fixtures and moved none, which is a signal you only get if you state the
expectation first (see the render-diff entry below).

**The general guard, now in place:** for every hidable row, making
`CardRow` hide it must change what the card draws
(`test_everyHidableRow_actuallyDisappearsFromTheRender`). It found nothing
else wrong — every other row restates its rule in the body as a parallel
expression (`priorityAllowed`, `nextStepAllowed`, `showsDivisibleRow`,
`futureReminderAllowed`, an inline `schedulingRules` check) and all of them
agree today. The guard is what notices when one stops.

⚠️ **`.eligibleSchedules` is not covered by it.** On the test fixture it
falls outside the 1400pt render viewport, so hiding it changes nothing
*inside the frame* and the assertion can't tell that apart from the body
ignoring `CardRow`. Rendering taller does not fix it: layout stops settling
and then every row compares identical, which makes the whole test
vacuously green — a worse outcome than the gap. Left uncovered and named.

**The structural fix, if it is ever worth it:** render the scroll body from
`CardRow.scrollBodyOrder` with a `ForEach` per `CardRow.Section`, so a row
cannot be drawn without appearing in the list and the two expressions
become one. `CardRow.section` already exists to model the two stacks'
spacing difference, so the pieces are there. **Deliberately not done** — the
card body has had three restructuring passes already, and this would be a
fourth to convert a *caught* problem into a *prevented* one. Scoped as
larger than the problem it prevents.

**Testing practice, general — a render baseline cannot observe whether a
live view *invalidates*. It renders one body pass on demand, so "the
picture is unchanged" says nothing about whether the real screen would ever
have redrawn to produce it.**

Same family as `.hidden ⟹ not drawn` above: a check that passes because it
is structurally blind to the property in question, not because the property
holds.

Stage 4b was verified as "pure deletion, all five render baselines pinned
and unchanged" — and that check was sound for what it covered. What it
could not see: `TaskItem.cycleRecurringOccurrence` mirrors its status onto
the occurrence's `ScheduledBlock`, and that mirror was the *only* thing
invalidating `NightlyReviewView` after a recurring-task tap, because
`@Query allBlocks` observes `ScheduledBlock` while nothing observes
`RecurringTaskLog`. Stage 4 removed the last recurring-task block, the
mirror stopped firing, and the row stopped redrawing. Measured on device:
**zero body passes across four consecutive taps**, the row catching up only
5+ seconds later when something unrelated invalidated the view. The write
was always correct and always took ~2ms; only the display was stale.

**The general signal: a data write that a view depends on for refresh, but
that the view does not observe directly.** Ask of every write behind a tap,
"which `@Query`d entity does this touch?" If the answer is "none, but it
incidentally writes a mirror/relationship that is queried," the refresh is
a side effect of the data model and a future deletion can take it away with
every test still green.

**Where the audit landed** (every Nightly Review tap, against the nine
`@Query`s):
- **Recurring task** — `RecurringTaskLog` + `TaskCompletionRecord`, both
  keyed by a plain `taskID: UUID` with no relationship. Nothing observed.
  Fixed with `recurringOccurrenceRefreshTick`, matching
  `DayTimelineGridView.habitOccurrenceRefreshTick`. A deliberate
  invalidation rather than a restored mirror, so the next deletion cannot
  silently remove it.
- **Habit** — same shape, currently saved by an accident of typing.
  `HabitLog.habit` is a real `Habit?` relationship, so writing a log
  touches a queried entity and `@Query allHabits` fires. `RecurringTaskLog`
  is the sibling type kept deliberately parallel to it, and its key is a
  plain UUID — so the two differ on precisely the field that decides
  whether the screen refreshes. Re-keying `HabitLog` to `habitID: UUID`
  would break habits identically and silently. Note also that
  `Habit.cycleOccurrence`'s own block mirror is **not** a second line of
  defence: the store holds **zero** habit `ScheduledBlock`s, so the
  relationship is the only live mechanism.
  **Now covered** by `habitOccurrenceRefreshTick`, plus a ⚠️ on
  `HabitLog.habit` itself so the warning sits where the tidy-up would be
  made. The tick is a deliberate no-op today — its entire value is
  conditional on a change nobody has made yet, which is the point: it
  converts a silent future break into no break at all. Scoped to Nightly
  Review; **no other habit surface has been audited for the same
  dependency**, and `HabitsView`/`HabitDetailView` are the obvious next
  places to look if this is ever picked up.
- **2-Minute task** — invalidated by a query its rows are not read from.
  Rows come from `allShelves` → `shelf.tasks`; the write is to
  `TaskItem.status`, observed by `allTasks`, which this step does not
  otherwise use. Works today, same class of dependency.
- **Block / meal** — genuinely direct. The row renders `block.status` /
  `selection.status`, and the view queries exactly those entities. These
  are the two that are correct by construction rather than by luck.

**Verification practice, general — a check can only bless what it is
capable of seeing, and "I verified determinism" is a claim with a scope.**

The render baselines were introduced with a determinism check: render the
same fixture twice in a row, and again after a rebuild forced by a no-op
source edit. Both passed. The conclusion recorded was "rendering is
deterministic" — stated flatly, with no scope.

It wasn't. `tail_recurring` later went red with **no code change at all**.
The card called `task.atRiskBlocker()`, which defaults to `asOf: .now`, and
the fixture carried a due date plus a toggled-on scheduling rule — so as
that day's slack ran out it crossed into at-risk and grew a banner that
pushed the whole card down. 50% of pixels, from a clock.

Neither determinism check could ever have caught it. Repeat runs were
minutes apart; a rebuild takes seconds. **Both sample the same moment.** The
defect class was time-of-day dependence, and the verification had no axis
along which that varied. The check wasn't wrong — it was narrower than the
conclusion drawn from it.

The general rule: when recording that something is verified, record *what
the check varied*. "Deterministic across repeat runs and rebuilds" would
have been true and would have left the gap visible. "Deterministic" closed
the question.

**And a guard test must pin an invariant that actually holds.** The first
guard written for this was: render the same fixture in January and
December, assert identical. It fails — correctly. A September due date
really is past due by December; at-risk is *supposed* to vary with time, so
varying `asOf` can never prove time-independence. The wrong test looked
more rigorous than the right one, because it exercised more.

What works instead is structural plus a boundary guard:
- `TaskReviewCard` takes `asOf: Date = .now`; the render tests pin it. Now
  the baseline cannot drift with wall-clock time at all — that is the fix,
  and it isn't testable by varying `asOf` because it's a property of the
  wiring, not of a computation.
- `test_fixturesAreNotAtRiskAtTheRenderMoment` asserts no fixture sits near
  the at-risk boundary at that pinned moment. That *is* an invariant that
  holds, and it fails with a sentence naming the fixture instead of handing
  over a 50%-different picture.

**Testing practice, general — the render baselines now actually compare,
and the story of why they didn't is worth keeping.**

`RecurringTaskCardRenderTests` renders the card through
`UIHostingController` + `UIGraphicsImageRenderer` and compares against PNGs
checked into `NoteForLaterTests/RenderBaselines/`. Any pixel difference
fails the test.

**It did not do this for most of its life.** It rendered a PNG to a scratch
directory and asserted `FileManager.fileExists` — it *emitted* images and
checked the write succeeded. Nothing compared them. No visual regression
could turn the suite red, and yet "the render tests pass" was cited as
verification across several stages of the card work. The names read like
baselines, so a green run looked like visual coverage it never provided.
That is *"tests whose failure mode is silence"* in its purest form, and the
lesson generalizes past this file: **read what a test asserts, not what it
is called.** A test whose assertion cannot fail is worse than no test,
because it is counted.

**Exact comparison, not tolerance — and why.** Tolerance sounds like the
robust choice and isn't. What actually breaks these is an Xcode or
simulator-iOS bump changing glyph rasterization across *every* character on
the card: a large-area change, not a small-delta one. A tolerance loose
enough to absorb that would also be loose enough to hide a renamed label,
which is the thing the suite exists to catch. Exact keeps the signal clean
and makes the noise legible instead — *all* fixtures red means the
environment moved, *one* fixture red means the code did. A `manifest.json`
records the iOS version, width and scale at record time, and the failure
message calls out any drift so nobody has to work that out from scratch.

Measured, rather than assumed: rendering is stable across repeat runs *and*
across rebuilds (verified with a no-op source edit forcing recompilation).
The brittleness is environment bumps, not ordinary work.

**Reading a failure.** Artifacts land in `RenderBaselines/__Failures__/`
(gitignored): `.diff.png` paints changed pixels red over a dimmed render,
alongside `.actual.png` and `.expected.png`. The message carries the
changed-pixel count and a bounding box.

**Do not read bbox size as change size.** The two are not related, and the
mistake is the obvious one to make: a wide bbox and a big percentage look
like something major broke. They routinely don't mean that. The card's rows
share an alignment guide, so changing one label's *width* re-flows every
row by a subpixel and re-rasterizes all the text on the card — sabotaging
this suite by editing `"Remind In"` to `"Remind in"`, a single character,
lit up 7% of the pixels and a bbox spanning almost the whole card.

What you may conclude:
- **A tight bbox is strong evidence** the change is confined to those rows.
  Nothing outside it moved, full stop.
- **A wide bbox tells you almost nothing.** It is equally consistent with a
  one-character label edit and with a genuine layout regression. Do not
  escalate on it, and do not treat it as confirmation that a large intended
  change landed correctly.
- **To tell those apart, open `.diff.png`.** A width re-flow shows as thin
  red antialiasing fringes outlining glyphs that are otherwise in the same
  place; a real regression shows as solid red blocks where content moved,
  appeared, or vanished. That distinction is obvious by eye and invisible
  in the numbers.

**Re-recording.** `TEST_RUNNER_RECORD_RENDER_BASELINES=1` — note the
prefix, `xcodebuild` forwards only `TEST_RUNNER_`-prefixed variables into
the test process and setting it unprefixed silently does nothing. Then run
`python3 scripts/optimize-render-baselines.py`: `UIImage.pngData()` writes
PNGs ~30% larger than needed, and these live in git forever. A size-budget
test fails if you skip it, because a forgotten optimisation step is exactly
as invisible as the missing comparison was.

**Still true, and the reason the above matters:** a render diff is a
regression net, not a change-verification tool. Its value comes from
fixtures that *don't* change. When a change touches every fixture — stage 3
of the card work changed all four — "it differs" carries no information,
and a red diff is not verification. Then: state up front which fixtures
should change and how; lean on `CardRow.scrollBodyOrder` as the real
control for row presence and ordering, since it fails specifically; use the
images only for what an assertion can't see, like a rename or a row's
position; re-record, and the net is back for the next change.

**SwiftData trap, general — not specific to any one change:** turning an
existing `@Model` stored property into a computed one (e.g. `isCompleted:
Bool` → a computed property backed by a new `statusRaw` stored field)
silently zeroes that property's history the moment the app opens the store
with the new schema. Lightweight migration adds the new stored column with
its Swift default and does not carry the old column's data into it — there
is no compile error, no runtime warning, nothing to notice until old
records start reading back as if they'd never happened. Confirmed with a
throwaway probe (write a row under the old shape, reopen the same `.store`
file under the new shape, read it back) rather than assumed — the
probe showed a row saved as `isCompleted: true` reading back
`statusRaw: "none"` after nothing but opening it. The fix: before removing
the old stored property, rename it and keep it mapped to the same column
with `@Attribute(originalName: "isCompleted") var legacyIsCompleted: Bool`,
so the old data survives under the new name; a one-time migration pass then
reads `legacyIsCompleted` to seed the new field correctly. Applied to
`TaskItem`/`ScheduledBlock`/`MealSelection.isCompleted` → `.status` this
session (`NoteForLaterApp.migrateIncompleteBlocksAndMealsToThreeStateIfNeeded`).
The next person converting any stored field to computed needs to do the
rename-and-backfill *before* shipping the schema change, not discover the
data loss after.

Two more findings from getting that migration right, worth recording
alongside it:

- **Flag ordering, and why the per-row guard is a second line of defense,
  not redundant with it.** The migration's own completion flag
  (`UserDefaults` key `didMigrateBlocksAndMealsToThreeState.v1`) is set
  **only after** `context.save()` returns successfully — never before.
  Setting it first would be the worse failure mode: a crash mid-backfill
  would permanently disable the retry the migration needs, leaving the
  store half-migrated forever with nothing left to notice or fix it.
  Setting it only after success means an interrupted run just re-runs next
  launch instead. But `UserDefaults` and the SwiftData store are two
  *separate* stores — a crash in the narrow window after `save()` succeeds
  but before that flag durably persists would leave the flag unset despite
  the data already being correctly migrated, and a naive retry would
  re-derive every row from scratch, capable of silently reclassifying one
  that had been touched since (including by the user, interactively).
  The fix was a **second** guard at the row level —
  `hasMigratedThreeState: Bool`, checked before deriving and set in the
  *same* `context.save()` call as the `status` write it guards, so the two
  can never land out of sync the way the data store and `UserDefaults` can.
  The outer flag stays as a fast-path early exit for the common case; the
  per-row flag is what actually guarantees a second pass is a true no-op.
  Verified fail-then-pass, not just asserted: with the row-level guard
  removed, a simulated second pass measurably stomped a `.complete` row
  back to `.missed`.
- **Test-methodology trap: a function that opens its own `ModelContext`
  makes a test's held object references go stale after it saves.**
  `migrateIncompleteBlocksAndMealsToThreeStateIfNeeded(container:)` builds
  its own `ModelContext(container)` rather than taking one — same
  container, but a *different* context than whatever a test (or another
  caller) already holds objects from. Mutating and saving through the
  function's context does not update the properties on a `TaskItem`/
  `ScheduledBlock` a test already has a reference to; that reference stays
  frozen at its pre-call values with no error or warning. A first version
  of the idempotence test above read those stale references straight after
  calling the migration and asserted against values that had never
  updated — passing or failing for the wrong reason regardless of what the
  migration actually did, silently measuring nothing. Fixed by re-fetching
  by `id` from the test's own context after each call, matching how any
  real second reader (another launch, another view) would see fresh state
  too. The general rule: after calling anything that constructs its own
  `ModelContext` internally, re-fetch before asserting — never trust an
  object reference held from before the call.

---

## Shipped — most recent first

### Task card consolidation and Specific-Time removal (stages 1–4)

Commits `ec584b2`…`62b2c42`, all pushed. This is the most recent work; the
sections below it are earlier sessions.

- **Stage 1 — the shipped regression.** Flattening Duration/Divisible out
  of the "Time" row had dropped the `recurrenceTimeMode == .specific` gate,
  so both rendered for untimed recurring tasks. Fixed via
  `TaskReviewCard.showsDurationRow` reading `TaskItem.recurringAndUntimed`.
  Two tests had encoded the bug and were corrected.
- **Stage 2 — one row list.** `CardRow` (in `Models/`, not the view, because
  `TaskItem.missingAttributeNames` reads it) is now the single applicability
  rule. Three drifting definitions collapsed into one; `scrollBodyOrder` is
  the single ordered list the card renders from *and* `initialExpandedRow`
  walks, so seeding/render agreement is structural rather than tested.
  **`.shown ⟺ missable`** is the invariant that kills this whole bug class:
  only a `.shown` row can be reported missing.
- **Stage 3 — the new card spec.** "2 Minutes or Less?" toggle (derived from
  shelf membership, no stored field); mutual exclusion with Recurring
  enforced in the model (`setRecurring`/`assignShelf`/
  `repairSpecialShelfExclusivity`); reset-on-toggle-off **derived** as
  (rows shown before − rows shown after) so a toggle can only clear what it
  actually hid; `ShelfPreview` tri-state for the toggle-off snap-back;
  "Starts" → "Can Start By"; ≤2 min off the duration wheel; Tags hidden for
  recurring.
- **Shelf default duration** now derives from the task wheel
  (`[0] + TaskReviewCard.durationOptions`) — the two lists had drifted and a
  shelf could stamp a duration the card couldn't display or edit.
- **Stage 4a — Specific Time removed for recurring tasks.**
  `HabitOccurrenceTimeMode.taskSelectableCases`; the setter coerces
  `.specific` away while the getter stays honest (see that property — the
  asymmetry is load-bearing for the migration); `migrateRecurringSpecificTimeTasksIfNeeded`.
  Duration/Divisible hiding fell out of `recurringAndUntimed` with no new
  rule. 24 existing tests updated in place with reasoning.
- **Stage 4b — the deletion.** 832 lines: the recurring-task block loop, the
  placeholder pipeline, and the whole projected-row subsystem. Three keeps,
  each commented where they sit. All five render baselines stayed pinned,
  which is what confirmed the code was genuinely unreachable.
- **Render baselines now actually compare** (see the practice note above) —
  they previously only asserted `fileExists`.

---

### Earlier session — commits `7f52f64`…`43bd19b`

Grouped by area, not chronological.

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

### Specific-Time recurring task projection + habit streak display on the day calendar

**Uncommitted as of this writing.**

Reported symptom: recurring task occurrences stopped showing when
navigating the day calendar forward to future days. Checked each mode
before writing anything, per the investigation rules:

- **AM/Midday/PM was already fine.** `openRecurringTaskOccurrences` reads
  `TaskItem.hasRecurringOccurrence(on:)` — pure date math, no
  `ScheduledBlock` dependency — confirmed directly from the source, not
  assumed.
- **Specific-Time was broken, but not for the reason first guessed.** The
  working theory going in was "blocks are only generated for
  today/tomorrow." Pulling the live device store showed that's wrong:
  blocks already existed out to ~26 days ahead. **The real finding: it was
  never a fixed horizon at all — it's whatever `regenerateFromNow`'s last
  walk actually reached**, which is generation-*timing*-dependent, not
  generation-*distance*-dependent. That walk can reach as little as
  tomorrow (if it hasn't run recently) or as far as 44 days out
  (`habitPopulationDays` + `taskStallThresholdDays`, if it has) — and
  `viewModel.blocks` never generates on the fly when you simply navigate
  to a day, so a Specific-Time occurrence's visibility depends entirely on
  whether some *earlier, unrelated* regenerate walk happened to reach that
  far, not on how many days out you're looking. This is the more useful
  fact for whoever touches this next — "it can break as soon as tomorrow"
  is a very different bug shape to chase than "it breaks past a fixed
  cutoff."

**Fix:** a display-time projection
(`ScheduleReviewViewModel.projectedRecurringTaskOccurrences` /
`DayTimelineRow.projectedRecurringTask`), not a materialized block —
deliberately, since generating further ahead would change scheduling
behavior/cost for every task, not just what one screen shows. Computed
once per body pass (`DayTimelineGridView.body`, same reasoning as
`computeOpenHabitOccurrenceLists`) and merged into the row list only for a
task that doesn't already have a real block that day. Kept from being
confused with a real block via the existing `isLockedRow` mechanism (the
same one a habit-linked block already uses) — drag, swipe-delete, and the
replace-menu tap all disable themselves through that one flag, no new
per-gesture special-casing needed. Completion reads `RecurringTaskLog` per
day, same as the untimed modes, so each day is independent by
construction (completing today's occurrence never touches tomorrow's).

**Deliberate divergence from the rest of the app — do not "fix" back to
the general convention:** everywhere else, a completed row/block stays
visible (faded, struck through) as a record of what was actually done. A
completed occurrence on a *future* day is hidden entirely instead
(`projectedRecurringTaskOccurrences`'s `isFutureDay` guard) — a day that
hasn't happened yet has nothing to keep a record of, so a pre-completed
occurrence sitting there is just noise. Today's own completed occurrence
still shows, same as everywhere else; only strictly-future days hide it.

**Fixed** (was: "known issue, left deliberately unfixed" — see git
history for this paragraph's original text if the old shape matters).
The recurring-task tap-cycle upgrade (habits-style
complete/missed/none, `TaskItem.cycleRecurringOccurrence`) made
`RecurringTaskLog` the single source of truth for *both*
`recurrenceTimeMode`s, not just the untimed ones — a real Specific-Time
`ScheduledBlock`'s own `isCompleted` is now a display mirror only, kept
in sync by `cycleRecurringOccurrence`, never read as truth. That alone
doesn't close the gap described below, since a block created *before*
this existed still starts with no mirror written — so
`AISchedulingService.placeHabitsAndRecurringTasks` (the block-creation
path this paragraph named as the fix) now also seeds a fresh block's
`isCompleted` from `RecurringTaskLog.log(taskID:on:)` at creation time.
Verified by direct code review rather than a test in this repo — a
minimal-fixture call into the full scheduling pipeline crashed on an
unrelated, pre-existing SwiftData issue before it could exercise this
path; the fix itself is two lines and was read carefully instead.

**Known test-harness limitation, confirmed pre-existing — do not
rediscover this as a new bug.** Calling `MockAISchedulingService
.placeHabitsAndRecurringTasks` from a unit test against a minimal
in-memory fixture (a bare `Shelf` holding one Specific-Time recurring
`TaskItem`, no habits, no free slots, no eligible-hours windows) crashes
immediately with `malloc: *** error for object 0x...: pointer being
freed was not allocated`, before any assertion runs. Reproduced with
`git stash` against commit `4875169` (before the recurring-task
tap-cycle work touched this file at all) — identical crash, same
message, so this is not something that change introduced. Given the
`RecurringTaskLog`/`MealSelection`-class history of "unregistered
model" heap corruption, this was checked specifically: `RecurringTaskLog`
and every other type reachable from this fixture's object graph is
present in both the app's real `Schema` (`NoteForLaterApp.swift`) and
the test's own `ModelContainer` type list, so that's ruled out as the
cause. The actual mechanism wasn't tracked down further — root-causing
a native SwiftData memory bug was out of scope for the change that hit
it. Whoever needs to test this path: either construct a fuller fixture
(populate `SchedulingRule`/`EligibleHoursWindow` etc. the way
`SchedulingEngineTests` does for its own `placeHabitsAndRecurringTasks`-
adjacent coverage) or verify by code review, as here — don't spend time
suspecting whatever change you're making first.

Tests: `NoteForLaterTests/DayTimelineProjectionAndStreakTests.swift`.
Fail-then-pass verified on the future-day-with-no-block case, the
day-independence case, and the hide-on-future-completion case.

Habit streaks (`Habit.currentStreak(asOf:)`, already-signed
`HabitStats.currentStreakDisplay` — no new streak math) were added to the
same screen's habit rows (both AM/Midday/PM occurrence rows and
Specific-Time habit blocks) the same visit, since it touched the same
file and the same "don't add per-row cost to this view's body" concern.
Cached (`DayTimelineGridView.cachedHabitStreaks`), refreshed once per
`targetDate` change and via the existing `HabitStatsRefreshCoordinator`
idle tick — never computed inline per row. Unlike `HabitsTodayView`'s own
cache (deliberately "as of right now" regardless of which day its date
nav shows), this one **is** keyed to `targetDate`, per the explicit ask —
so it does genuinely recompute on every day-navigation, just not on every
tap/body-pass.

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

### The Nightly Review commit's async half is unstructured — nothing awaits it

Leaving Review Schedule runs a commit batch, now extracted as
`ScheduleReviewViewModel.commitTodayStep` (synchronous) and
`.finishTodayStepCommit` (async). The view still launches the async half in
a bare `Task {}`, exactly as the original did.

**Why that's a risk.** The `Task` is unstructured: not tied to the view's
lifetime, and nothing awaits it, so nothing — including the app — knows
when it finished.

- `finishAndDismiss()` does `try? modelContext.save()` and then dismisses.
  Tap Done straight after the commit fires and that save runs while
  `purgeCompletedBlocks`, `resolveMissedPastBlocks` and `regenerateFromNow`
  are still working. Their own saves mean writes aren't *lost*, but the
  ordering is unguaranteed and the dismiss-time save can capture a
  half-finished state.
- **`regenerateFromNow` is the exposure**: it walks multiple days with a
  network call per day, and it is the *last* statement in the `Task`. Being
  backgrounded and suspended mid-walk leaves some days regenerated and some
  not.

**How likely.** Three steps sit between the commit and Done in normal use,
so hitting it needs deliberate speed-running or unlucky backgrounding.
Low-frequency, not impossible.

**The fix, now possible where it wasn't.** `finishTodayStepCommit` is an
`async` function a caller can hold onto. Either store the `Task` handle and
`await` it in `finishAndDismiss()` before saving, or make the async half
structured by driving it from a `.task` modifier keyed to the step. Either
way the Done button stops racing it. Before the extraction there was no
seam to do this at — the work was inline in a private `View` method.

Not fixed under cover of the extraction, deliberately: the extraction was a
verbatim move and changing lifetime semantics inside it would have made the
diff unreviewable.

**Status as of the end of the stage 1–4 card/Specific-Time work.** Both
long-running items below are unchanged by it — neither was investigated,
and nothing in stages 1–4 touched day-view event materialization or the
tap path. Do not read "still open" as "looked at again and still there."

### Next planned work — remove the Kitchen/meal subsystem

**Not started. Plan to be written fresh, not derived from this entry.**

⚠️ **The entanglement list from the session where this was scoped is not in
this repo or in the stage 1–4 transcript** — it was searched for
specifically and is not there. Ask for it before planning; what follows is
a survey derived from the code at the end of stage 4b, to give the plan a
starting shape, **not** a substitute for that list and not an approved
scope.

Two separable things share the name:
- **The Kitchen *shelf*** — `Shelf.isKitchen`, a shelf that suppresses every
  task attribute. Its blast radius is the six `effectiveTracks*` properties
  (`Shelf.swift:128–156`), which all read `!isKitchen`, plus ~20 view sites
  that filter it out of shelf pickers (`InboxView`, `ShelfListView`,
  `ImportView`, `NightlyReviewView:1448`, `DayTimelineGridView:1396`).
- **The meal/recipe subsystem** — `MealSelection`, `Recipe`, `UPCBank`,
  `MealSuggestionService`, `PantryDeductionService`, `RecipeImportService`,
  `RecipeIngredientParser`, `UPCLookupService`, and the views
  `KitchenView`, `MealsView`, `CookbookView`, `ReceiptImportView`,
  `ReceiptOCRScannerView`, `UnmatchedUPCsEditorView`.

29 files reference one or the other. Three things worth deciding early
because they shape everything else:
1. **Is this one removal or two?** The shelf and the meal subsystem are
   coupled only at `MealsView:196`/`KitchenView:53` (both set `isKitchen`)
   and `ScheduleReviewViewModel:1839` (fetches the kitchen shelf). They may
   well be separable, which would make each half reviewable.
2. **`MealSelection` is in the persistent `Schema`.** Removing a `@Model`
   from a live store is not a code deletion — see the SwiftData trap at the
   top of this file, and note `InboxItem` is *still* in the schema precisely
   because there's no supported path to drop an entity.
3. **`ScheduledBlock.mealSelection`** is a relationship on a model that
   stays. Dinner blocks exist in the user's store today.

**Apply the deletion-practice rules at the top of this file.** This is a
much larger deletion than stage 4b's, across a subsystem with live data —
re-derive every site at delete time, and check what each removed test was
the only cover for.

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

**Half A — DONE** (commit `7d19478`). `DayTimelineGridView.swift` 3,114 →
2,880; the Morning/Midday/Evening bands are now `OccurrenceSectionView` in
`Views/DayTimelineOccurrenceSections.swift`. Three corrections to what the
scoping above assumed, all found while doing it:

- **The sections are not habit-only.** `occurrenceGroups` emits a habit
  group *plus one group per shelf* of recurring-task occurrences, so the
  extracted view depends on task/shelf data too. "Extract the habit
  sections" is a less clean habits/tasks boundary than both this entry and
  the spec imply — worth knowing before scoping Half B off the same
  assumption.
- **Both writers had to stay in the parent.**
  `cycleRecurringTaskOccurrence` is wired into all three
  `DayTimelineSegment` call sites as well as the section, so it can't live
  solely in the child. They're passed down as closures; the refresh tick
  stays parent state.
- **The geometry seam is now tested** — `DayTimelineGeometry` +
  `DayTimelineGeometryTests`, extracted and pinned *before* the move so it
  had something to fail against. `.onGeometryChange` stays at the parent's
  call sites, since the heights are summed with the morning grid's own
  height into a value only the parent can assemble.

**Half B is harder than this entry makes it sound.** "Stop the parent
observing habits at all" reads like deleting one `@Query`, and it isn't:
`ScheduleReviewView`'s `@Query(sort: \Habit.sortOrder) allHabits` also
feeds `vm.regenerateFromNow(shelves:habits:eligibleHoursWindows:)` and
`vm.autoPlaceEligibleTasks(...)` (`ScheduleReviewView.swift:330`, `:340`).
The parent needs habits for scheduling regardless of what the grid does
with them, so Half B has to either turn those into a non-observing read
(fetch at call time) or move the calls — a decision about scheduling
inputs, not a view refactor. Budget accordingly.

**What 479/479 green does *not* cover, for whoever reads that number
next.** `DayTimelineGeometryTests` pins the scroll-space *arithmetic* —
`precedingContentHeight`, the afternoon sum, the `scrollToRoughlyNow`
offset — and that arithmetic is what decides where a dragged block lands.
It cannot cover *when* SwiftUI reports a section's height. A layout-timing
regression — a height reported stale, or at a different point in the pass —
would leave every assertion passing and still land drops on the wrong
time. The only real check for that half is an on-device drag on a split
day (with Midday habits, the case with the most terms in the sum) and on
an unsplit one. Don't read a green suite as covering the drag path.

### `startDate` cannot be cleared once set — fixed

Was: a nil `startDate` rendered as today (`task.startDate ?? .now`) and
the popover DatePicker bound straight to `task.startDate`, so tapping
the already-highlighted "today" cell produced no value change and
SwiftUI's DatePicker never fired its `set` closure — nothing was ever
written. Only tapping a *different* day (then back) generated a real
change event.

Fixed by adding `TaskItem.startDatePicked: Bool`, mirroring
`dueDateDecided`/`dueDatePicked` — `startDate == nil && !startDatePicked`
now means "never touched" (displays "Not Selected"), distinguishable from
a deliberately-picked today. The tap-registration problem itself needed
more than the flag: the popover's `DatePicker` now binds to a local
`pendingStartDate` `@State`, seeded fresh each time the popover opens,
and an explicit "Set" button commits it via `TaskItem.setStartDate(_:)`
regardless of whether the calendar's own selection binding ever fired —
a plain button tap has no "same value, no-op" case the way a `DatePicker`
binding does. `setStartDate(_:)` also keeps a recurring task's `dueDate`
in sync (via the same `syncDueDate(toAnchorDay:calendar:)` helper
`makeRecurring()` uses), so the anchor-sync blast radius the old entry
flagged is preserved.

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
