---
description: docs/files.md cites code by line number, and the citations rot
cause: `<file>.go:<line>` references move with every edit; nothing checks them
where: docs/files.md (code column), tests/integration/files_test.sh
state: needs-decision
priority: low
---

## Prompted by

2026-11-15, the debug-trace unit: routing every exec through one helper
shifted lines in ~40 files, and a review found about twenty `files.md`
references already pointing at the wrong line before that change — some at
a comment, some at an unrelated statement. Each fix is a hand search through
blame.

## To decide

1. **Cite by symbol, not line** — `serverbin.go` `func installSelf`, or
   `serverbin.go` (`mkdir -p "$1"` in the install script): survives edits,
   less precise.
2. **Keep lines, add a check** — a test that opens each cited line and
   requires a marker (e.g. the path or the write call) on it: precise, but
   every edit above a write breaks the doc until it is fixed.
3. **Drop the column** — the path, mode and owner columns are what readers use.

## Work

- [ ] the chosen form across every row of docs/files.md
- [ ] if 2: the check, in the files test
