---
description: >
  Two operators deploying as different Unix users collide on ownership: `.env`
  is 600 to its writer, `versions.log` and the shipped binary are writable by
  one user, and nothing excludes a `server init` from a deploy in flight. Put
  the apps tree under a `kasbah` group with setgid directories, have every
  write in files.md use a group-aware mode, add a server-wide lock and a
  `by=<user>` field to versions.log, in internal/serverinit, the remote
  writers and files.md.
state: ready
priority: normal
---

## Prompted by

Design review, 2026-10-28, user: "we do want multi user access … have a group
`kasbah` created, and have the source folder `chmod g+s` … same for `.env`, it
should be writable by the group".

Setgid (`2775`, lowercase `s`, with the execute bit) makes new files inherit
the group but does not make them group-writable, and kasbah's writes carry
explicit modes that bypass the umask anyway — so kasbah must write the group
modes itself. Directories containers create under `data/` stay root-owned
from inside the container; unchanged, a project concern.

## Work

- [ ] root step — appended to the printed block init already shows when `sudo -n` is refused (`internal/rootsteps`, `AppsBlock`/`PointerBlock` in internal/serverinit): `groupadd kasbah`, `chown :kasbah <apps> && chmod 2775 <apps>`; `usermod -aG kasbah <user>` printed per operator
- [ ] files.md gains a mode column per row: `.env` 660, `versions.log(.gz)` 664, `.deploy.lock` 664, project dirs 2775, `.kasbah/bin/kasbah` 775, marker 664; `acme.json` and `mail/.env` stay 600; temp-then-rename sets the mode before the rename
- [ ] server-wide `<apps>/.kasbah/server.lock`: exclusive for init/upgrade-traefik/prune/destroy, shared for deploy/rollback/drop
- [ ] `versions.log` lines gain `by=<ssh user>` (appended key=value — frozen format holds); `history` shows it
- [ ] documented model: one Unix user per operator, all in `kasbah`; `check --server` warns on a file whose group or mode is off
- [ ] rig test with two users

## References

- `docs/files.md`, `docs/server-setup.md` → Who creates the apps path, `docs/build-deploy.md` → flock
