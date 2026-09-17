#!/usr/bin/env python3
"""Check that `endOfDueDate` stays the only path from `dueDate` to a deadline.

On a recurring task `TaskItem.dueDate` is the **recurrence anchor**, not a
deadline — `syncDueDate` writes it (and sets `dueDatePicked` alongside), and
`hasRecurringOccurrence` reads it back as `anchor`. Reading it directly for a
due-date-shaped purpose silently treats that anchor as a deadline, and the
mistake is invisible on screen because the Due row is hidden for recurring
tasks.

`endOfDueDate(calendar:)` is the chokepoint: it returns nil for a recurring
task, and `slack`, `isAtRisk` and `atRiskBlocker` all read the deadline
through it. This script fails if a *new* direct reader appears beside them.

Not hypothetical: `ScheduleReviewView.dueDateFirst` was exactly such a
reader, sorting the empty-slot picker by an anchor, and nothing caught it.

⚠️ **This is a script, not a test, and that is a real gap.** It was written
as an XCTest first — the natural home, since the suite would then enforce it.
That test hangs the test host indefinitely the moment it reads the source
file from the simulator, taking the whole run down with it (no failure, no
timeout, just a run that never finishes). It is not enforced by `xcodebuild
test`; someone has to run it.

    python3 scripts/check-deadline-readers.py
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# (path, allowed-reader predicates) — a line matching any predicate is the
# sanctioned reader for that file and is skipped.
TARGETS = {
    "NoteForLater/Models/TaskItem.swift": (
        "guard let dueDate else",          # endOfDueDate's own nil-check
        "startOfDay(for: dueDate)",        # endOfDueDate's own body
        "let anchor = dueDate",            # reading it AS an anchor is correct
    ),
    "NoteForLater/Views/ScheduleReviewView.swift": (
        "task.isRecurring ? nil : task.dueDate",  # dueDateFirst's own guard
    ),
}

# `dueDate` next to a comparison or interval operator is a deadline reading.
# Assignment, nil-checks, `dueDatePicked`/`dueDateDecided` are all fine.
DEADLINE_SHAPED = ("<", ">", "timeIntervalSince", "compare(")


def offenders_in(path: pathlib.Path, allowed: tuple) -> list:
    found = []
    for number, raw in enumerate(path.read_text().splitlines(), start=1):
        code = raw.strip()
        if code.startswith("//"):
            continue
        # `->` is a return arrow, not a comparison. Strip it before looking
        # for operators, or every function signature mentioning dueDate is a
        # false positive — which is exactly what the first version did.
        scannable = code.replace("->", " ")
        if "dueDate" not in code:
            continue
        if "dueDatePicked" in code or "dueDateDecided" in code:
            continue
        if any(marker in code for marker in allowed):
            continue
        if not any(op in scannable for op in DEADLINE_SHAPED):
            continue
        found.append(f"  {path.name}:{number}: {code}")
    return found


def main() -> int:
    offenders = []
    for relative, allowed in TARGETS.items():
        path = ROOT / relative
        if not path.exists():
            sys.exit(f"Missing {relative} — update TARGETS in this script.")
        offenders += offenders_in(path, allowed)

    if offenders:
        print("A deadline reading bypasses `endOfDueDate`:\n")
        print("\n".join(offenders))
        print(
            "\nOn a recurring task `dueDate` is the recurrence anchor, not a "
            "deadline.\nRead it through `endOfDueDate(calendar:)`, which "
            "returns nil for one.\nSee `TaskItem.dueDate`'s own doc comment."
        )
        return 1

    print(f"OK — no deadline reading bypasses endOfDueDate ({len(TARGETS)} files checked).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
