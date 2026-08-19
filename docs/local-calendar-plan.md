# Empty-calendar diagnosis + park Google behind a local calendar service

Plan for Claude Code. Two steps: confirm the cause, then remove the dependency. Verified against HEAD (`176ab46`).

**Do not start step 2 until step 1's finding is reported back.** If step 1 disproves the hypothesis, stop and report — step 2 may be treating the wrong problem.

## Symptoms

- Nightly Review's advance deleted all future unapproved blocks and rebuilt **nothing**.
- Opening the Calendar tab since then places **nothing** — `autoPlaceEligibleTasks` is running but producing zero blocks.
- No error is surfaced to the user in either case.
- Separately and currently unexplained: before the wipe, blocks existed ~5 days out, then a ~119-day gap, then blocks again around day 125. No task has a `startDate`, and those blocks were not approved or locked. **This is parked, not in scope here** — the evidence was deleted by the wipe. Do not chase it.

## Hypothesis

`ScheduleReviewViewModel.autoPlaceEligibleTasks` line 178:

```
guard var freeSlots = resolvedSlots else { break }
```

If the calendar service throws, `resolvedSlots` is `nil` and the walk breaks **on day 0** — zero placements, silently. `prefetchFreeSlots` returns `[:]` on failure, so every day is a cache miss and falls through to the per-day call, which fails identically. `regenerateFromNow` has the same shape via its `catch`.

A dead/expired Google auth token, a network failure, or an empty `enabledCalendarIDs` would each produce exactly this, invisibly.

## Step 1 — Confirm (diagnostic only, no behavior change)

Add temporary logging and run on the real device against the real store:

- In `prefetchFreeSlots`: log whether the ranged call **succeeded or threw**, and on throw log the concrete error. On success log the number of days returned and how many of those days have a **non-empty** slot array.
- In both walks at the `guard`/`catch`: log when the walk breaks due to a nil/failed fetch, and the `cursorDay` and `dayIndex` it broke on.
- In `GoogleCalendarService`: log the resolved `enabledCalendarIDs` and the HTTP status / error body from the `freeBusy` call.

Then open the Calendar tab and capture the output.

**Report back which of these it is** before writing any fix:

1. The fetch **throws** (auth/network/HTTP error) → hypothesis confirmed, proceed to step 2.
2. The fetch **succeeds but every day returns zero free slots** → the hypothesis is wrong. The break isn't firing; the packer is being handed a legitimately full calendar. Likely `enabledCalendarIDs` pointing at a calendar full of all-day events, or a degenerate `workingHours`. Stop and report — step 2 would not fix this.
3. The fetch succeeds **with** free slots and blocks still aren't placed → the failure is in the packer, not the calendar. Stop and report; this needs a different investigation entirely (rule eligibility, `isEffectivelyEligible`, `hasRemainingSchedulableWork`).

This branch matters. Only case 1 is fixed by step 2.

## Step 2 — `LocalCalendarService` (only if step 1 = case 1)

Google is **parked, not removed**. Everything stays behind the existing `CalendarServiceProtocol` seam so it can be swapped back.

### Implement
- New `LocalCalendarService: CalendarServiceProtocol` in `CalendarService.swift`.
- `fetchFreeSlots(for:)` and `fetchFreeSlots(from:to:)` return each day's **full working-hours window** with no busy subtraction — i.e. call the existing `freeSlots(inWindow:busy:)` free function with `busy: []`, reusing `calendarDays(from:to:)` for the ranged variant so day-keying matches the other implementations exactly.
- Reuse the same `workingHoursRange(for:)`-equivalent per-day window computation. Compute it **per day**, not once for the span — DST means the same wall-clock components map to different absolute instants.
- Neither method should ever throw. `async throws` stays in the signature for protocol conformance, but there is no failure path. This is the point of the change: the `guard ... else { break }` can no longer fire.
- `enabledCalendarIDs` is accepted and ignored (no-op setter or stored-but-unused). Do not remove it from the protocol.

### Swap in
- Two composition roots: `ScheduleReviewView.swift:218` and `NightlyReviewView.swift:797`. Both currently construct `GoogleCalendarService` and pin `workingHours` to `00:00–23:59`.
- Keep that same `workingHours` assignment — don't quietly change it to 8am–9pm while swapping.
- Prefer a single named constant/factory for "which calendar service the app uses" over duplicating the choice at both sites, so unparking Google later is a one-line change.

### Explicitly do NOT
- Do not delete or modify `GoogleCalendarService`, the ranged `fetchFreeSlots`, the batching in either walk, `freeSlotPrefetchDays`, or the fallback path. All of it stays dormant and correct for when Google returns. The prefetch will simply always hit and never fall back.
- Do not change `AISchedulingService` or the packer.
- Do not touch the Nightly Review generate button — that's a separate planned item.
- Do not remove the step 1 logging until the fix is confirmed working on device.

### Note on double-booking
Already handled — `autoPlaceEligibleTasks` lines 179–182 subtract existing blocks from free slots locally, and `placeHabitsAndRecurringTasks` subtracts habit blocks. Losing Google (which previously reflected approved blocks back as busy) does **not** open a double-booking hole. No change needed here; do not add compensating logic.

## Verification

- Full test suite still passes (51/51 at HEAD). Existing tests use `FakeCalendarService` and should be unaffected.
- Add a test that `LocalCalendarService` returns a non-empty free window for a day with no data, and that its ranged variant keys every day in the span.
- On device: open Calendar and confirm blocks actually appear. This is the real acceptance criterion — the unit tests can't prove it.
