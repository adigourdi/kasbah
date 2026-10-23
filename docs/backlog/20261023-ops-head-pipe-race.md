---
description: >
  The ops integration suite fails intermittently. Its "finite log … exits 0
  through `| head -3`" case assumes ssh finishes writing before `head` exits, but
  the log can arrive in more than one network read, so `head` can close the pipe
  under a later write and ssh exits 255. The case is in
  tests/integration/ops_test.sh:266-275.
state: ready
priority: low
---

## Prompted by

The full rig run for the Cypht/Fail2ban work, 2026-10-23 (`3b527e1`): one FAIL,
`a finite log small enough to fit the pipe buffer exits 0 through the same
\`| head -3\` (rc '255')`. Run alone straight afterwards, the suite passed twice.
The same suite passed in the full run before it (`1e34314`).

## Evidence

- The case's comment: "the log fits the pipe buffer, ssh finishes writing before
  the reader is missed". Fitting the local pipe buffer does not mean one write: the
  remote `compose logs` output reaches ssh in network-sized pieces, and `head -3`
  can exit between them.
- 255 is exactly what the assertion just above it proves for a closed pipe under a
  write, so this is that path, reached by timing.

## Options

- Make the reader drain: `| { head -3; cat >/dev/null; }` keeps the pipe open, so
  the case still shows "piping is not 255" without the race.
- Or seed a log short enough (≤3 lines) that `head` never exits early.
