---
description: Re-running upgrade-traefik after a partial ship backs up a mixed set
cause: the backup step copies whatever the live files are, partly new or not
where: internal/upgrade/upgrade.go (ship, backup, start), docs/cli.md
state: needs-decision
priority: low
---

## Prompted by

2026-11-17, the next-step sweep over `internal/upgrade`: giving a failed ship
its next step showed that a plain re-run is not safe. When `ship` fails after
writing one or two of the three files, the proxy is not restarted, but the
live directory now holds a mix of old and new files. A re-run's `backup` takes
that mix as "the version in effect", and a rollback in that run (`start` failing
health) restores the mix, not the previous stack. The failure now tells the
operator to put the backup back with `cp -p` before re-running; nothing makes
a plain re-run safe.

## Evidence

- `internal/upgrade/upgrade.go` `run.ship` — writes compose.yml, traefik.yml,
  dynamic/_shared.yml one `kasbah remote init write` at a time; a failure
  between them leaves the mix
- `run.backup` → `kasbah remote traefik backup` — copies the live files as
  they are
- `run.restore` — the three `cp -p` lines the ship failure prints

## To decide

1. **Restore on ship failure** — the ship failure itself puts the backed-up
   files back (one more `kasbah remote` arm) before reporting: the server is
   never left mixed, the printed `cp -p` lines go away.
2. **Refuse a mixed re-run** — `readStack`/`recover` detect files that do not
   come from one image's render and refuse, naming the newest backup to
   restore: leaves the server mixed, but no run builds on it.
3. **Leave it** — the printed restore step is the remedy; partial ships are
   rare (an ssh drop between three small writes).
