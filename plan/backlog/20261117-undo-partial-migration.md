---
description: migrate server --undo after a partway failure says "nothing to undo"
cause: Undo looks only for a snapshot ending at the marker's major
where: internal/migrate/server.go (Undo, findTo, Find), docs/cli.md
state: ready
priority: low
---

## Prompted by

2026-11-17, the next-step sweep over `internal/migrate`: giving a partway
failure its next step showed that only going forward recovers it. A run that
fails after its first rewrite leaves the marker at the old major (it moves
last), with some files rewritten and the snapshot `<from>-to-<to>-<stamp>.tar`
on disk. `--undo` looks for a snapshot that ends at the marker's major, finds
none, and answers "nothing to undo". Today's only server step (0→1) rewrites
no file, so nothing reaches this yet; the first step that rewrites files
would.

## Evidence

- `internal/migrate/server.go` `Undo` → `findTo(apps, to)` with `to` the
  marker's major; `Find(apps, from, to)` matches `<from>-to-<to>-*.tar`
- `Run` reuses the snapshot `Find(apps, from, to)` on a re-run; the marker
  moves last, so after a partway failure it still says `from`
- after a successful undo the snapshot is kept, and the marker is back at
  `from` too: a snapshot starting at the marker's major does not by itself
  mean there is something to undo

## Work

- [ ] `--undo` with the marker at major F and a newest snapshot `F-to-*`
      whose files differ from what is live restores it (files only: the
      marker already says F); when every file matches, it is "nothing to
      undo" as now
- [ ] the partway failure's next step names `--undo` as the way back, beside
      the re-run forward, only where it now works
- [ ] tests with a made-up step that rewrites files: partway run, undo,
      second undo is "nothing to undo"; `docs/cli.md` (`migrate server`)
