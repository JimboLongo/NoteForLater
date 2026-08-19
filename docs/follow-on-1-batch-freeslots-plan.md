# §10 Follow-On #1 — Batch `fetchFreeSlots` into one ranged call

Implementation plan for Claude Code. Verified against HEAD (`a469ef4`) directly against source, not just against `docs/NoteForLater-Scheduling-Spec.md` §10 prose — the spec is known to drift from code, so treat this plan as the source of truth over the doc's §10 section where they conflict.

## Baseline facts (checked against code, not doc prose)

- `GoogleCalendarService.fetchBusyRanges(from:to:)` (`CalendarService.swift:218`) is already range-based — one POST to `freeBusy` for an arbitrary `[start, end)` span.
- `fetchFreeSlots(for:)` is called once per loop iteration in exactly two hot paths:
  - `ScheduleReviewViewModel.autoPlaceEligibleTasks` — `CalendarService.swift` call at line 155 (via `try?`, loop `break`s on failure)
  - `ScheduleReviewViewModel.regenerateFromNow` — call at line 484 (via `try`/`catch`, sets `completedFully = false` and `break`s on failure)
- A third call site (`generateProposedSchedule`, line 55) is a single, non-looping call — **out of scope**, leave on the thin wrapper.
- `taskStallThresholdDays = 14` (private static, `ScheduleReviewViewModel.swift:599`).
- `habitPopulationDays = 30` (currently a **local** `let` inside `regenerateFromNow`, line 470 — needs to move to a shared private static for this work).
- `workingHours` is a single wall-clock `(start, end)` pair, not day-of-week-dependent. In production it's pinned to a fixed full day (`00:00–23:59`) at both call sites that configure it (`ScheduleReviewView.swift:218`, `NightlyReviewView.swift:797`). "Varies by day" in the spec refers to the *absolute Date instant* per calendar day (DST etc.) for the same wall-clock components, not to the hours themselves changing.
- `FakeCalendarService.fetchFreeSlotsCallCount` and the assertion `SchedulingEngineTests.swift:720` (`XCTAssertEqual(calendarService.fetchFreeSlotsCallCount, 14)`) exist as described and **will need rework**, not just a rename — see §6.

## The core design problem (not fully resolved by the spec's own wording)

§10.1 says "makes one `fetchBusyRanges` call across the whole walk span" — that assumes the walk's length is known up front. It isn't: both loops use stall detection, and `consecutiveDaysWithoutTaskPlacement` only updates *after* a day's packing result comes back, which depends on that day's free slots. In the theoretical worst case (a task placed every ~10–13 days, never tripping the 14-day stall counter) the walk has no fixed ceiling.

**Resolution, agreed:** pre-fetch a fixed horizon of `habitPopulationDays + taskStallThresholdDays` = 44 days in one ranged call, slice into a per-day cache, and fall back to the existing thin `fetchFreeSlots(for:)` for any day the walk reaches beyond that window. This keeps the pathological sparse-trickle case correct instead of unbounded, at zero cost in the common case.

## Implementation steps

### 1. `CalendarServiceProtocol` — add the ranged method
```
func fetchFreeSlots(from start: Date, to end: Date) async throws -> [Date: [TimeSlot]]
```
- Keyed by `startOfDay` (via `Calendar.current`) for each day in the range.
- `fetchFreeSlots(for:)` stays in the protocol, unchanged signature — it's both the documented single-day wrapper and the fallback path.

### 2. `GoogleCalendarService` — implement the ranged method
- One call to `fetchBusyRanges(from:to:)` across `[start, end)`.
- Slice locally per calendar day: for each day, compute that day's own `workingHoursRange(for:)` (existing, stays private) and run the same busy→free subtraction `fetchFreeSlots(for:)` already does, against the one fetched busy list.
- Call `workingHoursRange(for:)` once per day of the span — don't compute one start/end for the whole range.
- Optionally rewrite `fetchFreeSlots(for:)` to call this new method for a 1-day span and return `result[startOfDay] ?? []` — reduces duplication but not required.

### 3. `MockCalendarService` — implement the ranged method
- Same shape, built from `mockBusyRanges`, looping over days in range. Low risk — SwiftUI Previews only.

### 4. `ScheduleReviewViewModel` — batching in the two hot paths
- Move `habitPopulationDays` out of `regenerateFromNow` into a shared `private static let habitPopulationDays = 30` alongside `taskStallThresholdDays`.
- Add `private static let freeSlotPrefetchDays = habitPopulationDays + taskStallThresholdDays` (derived, not hardcoded 44).
- Add a private helper:
  ```
  private func prefetchFreeSlots(from startDay: Date, days: Int) async -> [Date: [TimeSlot]]
  ```
- Call it once at the top of both `autoPlaceEligibleTasks` and `regenerateFromNow`, right before their `while` loops, seeded from that loop's actual starting `cursorDay` (post any today-is-closed adjustment).
- Inside each loop iteration, replace the direct `fetchFreeSlots(for: cursorDay)` call with a cache lookup, falling back to the thin per-day call on cache miss:
  - Preserve existing error-handling shape exactly (`try?`/`break` in `autoPlaceEligibleTasks`; `try`/`catch`/`completedFully = false`/`break` in `regenerateFromNow`) — only the data source changes.
- `regenerateFromNow`'s today-cutoff clipping logic (lines 485–499) is downstream of the fetch and needs no change regardless of source.

### 5. `FakeCalendarService` — test double update
- Implement the ranged method: for each day in `[start, end)`, key `startOfDay → freeSlotsToReturn` (same static array reused per day, consistent with current fake behavior).
- **Split the call counter — don't just rename it:**
  - `fetchFreeSlotsRangedCallCount` — increments once per call to the new ranged method.
  - `fetchFreeSlotsCallCount` — now measures only fallback-path usage (calls to the thin single-day method). Should be `0` in the stall-detection test since 14 days is well under the 44-day prefetch window.
  - Store the last `(start, end)` args passed to the ranged method so tests can assert the *span requested*, not just that a call happened.

### 6. Test changes
- **Rewrite** `test_autoPlaceEligibleTasks_stallDetection_stopsAtThreshold_notOldFixedCap` (`SchedulingEngineTests.swift:689`):
  - Assert `fetchFreeSlotsRangedCallCount == 1` and `fetchFreeSlotsCallCount == 0`.
  - Assert the requested range's day-span still reflects the walk stopping at 14 days — without this, the test only proves "one network call happened," not that stall detection still works. (Batching could hide a broken stall check.)
- **Add** a new test for the fallback path: seed a scenario where placement happens roughly every 13 days for several cycles (never tripping the 14-day stall threshold) so the walk must reach day 45+. Assert `fetchFreeSlotsCallCount > 0` (fallback fired) and `fetchFreeSlotsRangedCallCount == 1` (no second batch call). This is the test that protects the fallback design decision — without it, a future "fix" to the ranged call could silently break the fallback with nothing catching it.
- Consider whether `GoogleCalendarService`'s per-day slicing logic needs a network-free unit test (a day's busy range spanning a slicing boundary shouldn't leak into the adjacent day). If there's no existing seam for testing it directly, decide whether to extract the slicing into a testable free function/extension, or accept coverage only via `MockCalendarService` + a viewmodel-level test — flag this as an open call for whoever picks up the work, not a silent scope decision.

## Suggested commit order
1. Protocol + `GoogleCalendarService` + `MockCalendarService` ranged implementation (compiles, nothing calls it yet).
2. `FakeCalendarService` ranged implementation + counter split (existing test still passes unmodified through this point).
3. `ScheduleReviewViewModel` prefetch + cache-with-fallback wiring in both loops.
4. Rewrite the stall-detection test, add the fallback test.

**Steps 3 and 4 must land together.** An intermediate commit where the viewmodel batches but the test still asserts the old per-day count will fail — that's expected, not a regression to chase.
