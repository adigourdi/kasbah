---
description: >
  The macOS workstation build ships but has never run on a Mac: it is
  cross-compiled, vetted and unit-tested only. Walk the install, a deploy and
  the terminal paths on Apple Silicon and Intel and fix what breaks, across
  get.sh, internal/selfupdate, internal/term, internal/ssh and build-push.
state: blocked
priority: normal
after:
  - a Mac (Apple Silicon, and ideally Intel) to run it on
---

## Prompted by

Design review, 2026-10-28 ("Linux-only workstation. This is the adoption
cliff"); built in the 2026-10-29 run as **traced**, by the user's ruling
("Include, traced"), so this item keeps what only a real Mac can prove.

## Work

- [ ] `curl … get.sh | sh` on Apple Silicon and on Intel: download, `shasum`, the binary runs, Gatekeeper does not block a curl-downloaded binary
- [ ] `self-update --from` and plain `self-update` install the darwin binary plus both linux server builds; `~/.local/bin/kasbah` works
- [ ] terminal: hidden password prompts, the one-key menus, echo restored after Ctrl-C (`internal/term`'s darwin file)
- [ ] an ssh master opens under macOS's `$TMPDIR` and the derived 86-byte ControlPath budget holds with macOS's OpenSSH (measure as `build-deploy.md` did for Linux)
- [ ] build-push from an arm64 Mac to an amd64 VPS on Docker Desktop (containerd image store; cross-arch save/load proven here only on overlay2)
- [ ] `htpasswd -niB` from macOS for the dashboard password
- [ ] `install-dev.sh` and `KASBAH_GOOS=darwin docker compose run --rm build` on a Mac; `release.sh` from a Mac (it needs `sha256sum`, which macOS lacks)
- [ ] a project synced from a case-insensitive APFS volume
- [ ] `./test.sh` on a Mac: the suites use GNU sed, `setsid`, `/proc` — decide whether they should run there at all
