---
description: >
  R01/R02 force every service onto the one global `KASBAH_*` ceiling, so a
  project cannot give postgres 2g and web 512m without `check` failing the
  literal, while the ceiling itself never stops two containers from hogging
  together. Accept a literal at or below the host ceiling (warn locally, fail
  on `--server` above it) and keep the variable as the default, in
  internal/check R01–R04 and compliance.md.
state: ready
priority: normal
---

## Prompted by

Design review, 2026-10-28: "Every container on the box can individually take
90% of RAM … the operator can't say postgres gets 2g". User: "I don't have to
block a user from putting what they want, worth investigating".

## Work

- [ ] R01/R02 pass on the variable or a literal; R03 unchanged
- [ ] `check` without a server warns on a literal (cannot compare); `check --server` R04 fails a literal above the ceiling
- [ ] `check --fix` leaves literals alone
- [ ] a later per-project cgroup (`cgroup_parent:` slice) is the real answer to "two at once"; note it in server-setup.md as not done

## References

- `docs/compliance.md` → Resources, `docs/server-setup.md` → Resource limits
