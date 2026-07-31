# Note for Later — starter scaffold

SwiftUI + SwiftData starter for the app. Everything compiles and runs against
mock services so you can see the full flow (inbox -> sort -> schedule review
-> swipe/long-press) in the simulator before wiring up real Google auth or AI.

## Structure

```
NoteForLater/
  App/NoteForLaterApp.swift     entry point, SwiftData container
  Models/                          InboxItem, TaskItem, ScheduledBlock, enums
  Services/                        GoogleAccountService, CalendarService, AISchedulingService
  ViewModels/                      InboxViewModel, ScheduleReviewViewModel
  Views/                           ContentView, InboxView, HoldingPenListView, ScheduleReviewView
```

Target: iOS 17+ (uses `@Model`/SwiftData and `@Observable`).

## Setup in Xcode

1. Create a new iOS App project named `NoteForLater` (SwiftUI interface,
   Swift language, no Core Data — SwiftData already handled here).
2. Delete the generated `ContentView.swift` / `Item.swift` and drag this
   `NoteForLater/` folder's contents into the project, preserving groups.
3. Build and run — the Inbox, holding pens, and Schedule tab all work
   end-to-end against the mock services (`MockCalendarService`,
   `MockAISchedulingService`, `MockGoogleAccountService`).

## What's stubbed, and what to build next

Every stub has a `TODO(Claude Code)` comment at its definition. In priority order:

1. **Google Sign-In** (`Services/GoogleAccountService.swift`) — swap
   `MockGoogleAccountService` for the real GoogleSignIn-iOS SDK flow. Needs a
   Google Cloud project with Calendar API (and Gmail API, if inbox capture
   ever pulls from email) enabled, OAuth client ID, and the URL scheme added
   to Info.plist.
2. **Calendar free/busy + event writes** (`Services/CalendarService.swift`)
   — replace the synthetic busy blocks with real `freeBusy` and
   `events.insert` calls against the Calendar API using the OAuth token.
3. **AI scheduling** (`Services/AISchedulingService.swift`) — replace the
   greedy packer in `MockAISchedulingService` with a real Claude API call:
   send the open to-dos + free slots as JSON, ask for a structured
   assignment back. Keep the greedy packer as an offline fallback.
4. **Nightly trigger** (bottom of `App/NoteForLaterApp.swift`) — local
   notification (UNUserNotificationCenter) + a BGAppRefreshTask so tomorrow's
   schedule is generated and waiting before the reminder fires. Needs the
   Background Modes capability.
5. **Persistence of working hours / preferences** — `CalendarService.workingHours`
   is currently hardcoded 8am-9pm; surface this as a Settings screen.

## Interaction notes (already implemented in ScheduleReviewView)

- **Swipe left** on a scheduled block -> `deleteBlock`: removes the block,
  task goes back to unscheduled for a future night.
- **Swipe right** -> `autoReplace`: swaps in the next-best unscheduled to-do
  (priority, then due date) into the same slot; bumped task requeues.
- **Long-press** -> opens `ReplacementPickerSheet`, listing all unscheduled
  to-dos so you pick the exact replacement; bumped task requeues.
- **Approve All** in the toolbar marks every block approved and (once
  `CalendarService.createEvent` is real) writes them to Google Calendar.

## Not yet covered

- Editing/reordering tasks within a holding pen beyond delete.
- Turning a "Future Project" into a set of schedulable to-dos.
- Settings screen (working hours, notification time, account management).
- Unit tests for the scheduler and view models.
