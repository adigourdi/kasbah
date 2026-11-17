---
description: An interrupted ship's write can land after the restore put it back
cause: init write and traefik restore do not serialize on the server
where: internal/serverinit/remote.go (remoteWrite), internal/upgrade/remote.go
state: ready
priority: low
---

## Prompted by

2026-11-17, the review of the upgrade-traefik ship restore: a Ctrl-C kills
the in-flight `kasbah remote init write`'s ssh client, but the server arm
ignores SIGHUP; when its whole payload had already arrived it still renames
the file into place — possibly after the restore, started over a new ssh
session, has put the backup back. The live directory then holds one new file
while the report says the previous files are back, and the next run backs up
that mix.

## Evidence

- `internal/upgrade/upgrade.go` `run.ship` / `putBack` — the restore runs over
  a fresh `x.s.Call` once the held signal is seen
- `internal/serverinit/remote.go` `remoteWrite` — `remote.Payload` then
  `remote.Install` (temp + rename); nothing it takes is shared with the restore
- `internal/upgrade/remote.go` `restoreFiles` / `putFile`
- the window is about one ssh session's start

## Work

- [ ] `init write` and `traefik restore` serialize on the server: an exclusive
      `flock(2)` on the target's directory, taken by `init write` before it
      reads its payload and by the restore on `traefik/` and
      `traefik/dynamic/` (fixed order) — so a write that started before the
      interrupt finishes before the restore copies; no new file on disk
- [ ] a test that a restore waits for a write holding the lock
- [ ] `docs/traefik.md` ("What a failure leaves") and `docs/cli.md` say so
