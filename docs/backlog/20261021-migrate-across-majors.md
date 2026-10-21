---
description: >
  Crossing a major has no path: `kasbah migrate` is named by `overview.md`,
  `server-setup.md` and `cli.md` but does not exist, and the older-major marker
  refusal is deliberately unimplemented because it would strand a server. Design
  settled: `kasbah migrate server USER@HOST` (explicit, snapshot, per-file
  idempotent, marker last, the fleet's point of no return) and `kasbah migrate`
  in a project; open on undo and how far back — `internal/marker`,
  `internal/manifest`, `internal/serverbin/prepared.go`.
state: ready
priority: low
---

## Prompted by

*"2.0 > 1.4, this is now a question to answer, how do we upgrade/migrate? and do
we have migrations on `1.2 > 1.1` as well"*. Rulings from that discussion:

- **Minors never migrate.** Within a major: writes are additive (`server.json`
  merges, `versions.log` appends `key=value`, manifest keys optional with a
  default), a newer minor fills defaults and rewrites a file only when it
  writes it anyway (lazy, no sweep). A change that cannot be additive **is** the
  next major — the only bump criterion.
- **Majors are explicit.** A 2.0 command meeting a 1.x marker refuses *before
  shipping* (the binary must not land, or 1.x workstations are locked out before
  anyone chose to migrate); the refusal names `kasbah migrate server`.
- Nothing to build until the first non-additive change exists; the design is
  recorded so 2.0's author does not re-derive it.

## Evidence

- `docs/server-setup.md:379-384`: the older-major refusal is specified and
  deferred "until the remedy it names exists" — it lands with this item.
- `docs/project-manifest.md:108-123` (`schema` frozen at 1, `kasbah_version` =
  last writer), `:325-350` (`state.json` reserves `schema_migrations_applied`).
- `internal/marker/marker.go:189-224` `Major`/`Compat`; `internal/manifest/manifest.go:21-23,117`.
- `docs/roadmap.md:96-99` asked for VPS migration to be "opt-in and reversible".
- Every file kasbah writes records its version (`docs/files.md`) — what makes a
  per-file idempotent migration possible.

## Rulings (run of 2026-10-21 — settled, do not re-propose)

- **Undo:** `kasbah migrate server USER@HOST --undo` restores the latest
  snapshot and marker, allowed only while no `versions.log` line in any
  project is newer than the snapshot; otherwise it refuses and names the
  manual path (the snapshot tarball). A snapshot is always written.
- **Chain:** the newest binary carries every step (`1→2`, `2→3`, …) and runs
  them in sequence; a step is a Go value registered in `internal/migrate`,
  idempotent per file from each file's own version stamp.
- **Order:** project and server migrations are independent and run in either
  order; a newer-major binary refuses a schema-1 manifest (`kasbah migrate`
  in the project) or a schema-1 server (`kasbah migrate server`) until each
  is migrated; `deploy` needs both.
- **Proof without a real step:** the step registry is empty for schema 1; a
  test-only step (Go unit tests over the engine; a rig case that plants a
  `0.9.0` marker and runs the real binary) proves lock, snapshot, per-file
  rewrite, marker-last, `--undo` and its refusal. The older-major refusal in
  `serverbin.EnsurePrepared` lands with this (`server-setup.md` says it waits
  for the remedy to exist).

## Work

- [ ] `EnsurePrepared`: older-major marker → refusal naming `migrate server`
- [ ] `kasbah migrate server USER@HOST`: plan + prompt (`--yes`), says 1.x
      workstations are refused afterwards; lock; ship the new major (the one
      command allowed to); `kasbah remote migrate` under `remote.Outlive`:
      snapshot, per-file temp+rename, marker last; idempotent per file
- [ ] `kasbah migrate` in a project: `kasbah.yml` + tree files, bump
      `kasbah_version`, record in `state.json`; a newer-major binary refuses an
      older-schema manifest until run
- [ ] Files only, never containers; a change needing a recreate is a
      `deploy`/`upgrade-traefik` afterwards — written down
- [ ] Docs: `overview.md:74`, `server-setup.md`, `project-manifest.md`,
      `cli.md` deferred-commands entry, `roadmap.md` Phase 5 line

## References

- `docs/overview.md:74,149`, `docs/server-setup.md:370-384`, `docs/project-manifest.md`
- `internal/marker/`, `internal/manifest/`, `internal/serverbin/prepared.go`
