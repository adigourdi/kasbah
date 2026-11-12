---
description: >
  Many failure messages drop the error that caused them — a write, mkdir,
  rename or copy fails and kasbah says only that it failed, so the operator
  cannot tell a full disk from a permission problem. Carry the cause into each
  message with cli's Cause helper (or the OS reason on the server side), across
  internal/serverinit, internal/backup, internal/mail, internal/deploy and
  internal/state.
state: ready
priority: low
---

## Prompted by

A review on 2026-11-12 of the change that made ship failures carry their cause
(`(*cli.Error).Cause`, `remote.Install`'s OS reason): the same shape — an error
in hand, dropped from the message — recurs across the codebase.

## Evidence

A grep at the time: serverinit/remote.go ~:168, :180; serverinit/acmedns.go
~:512, :549; backup/remote.go ~:163, :349, :447; backup/runner.go ~:170, :174;
mail/dkim.go ~:354; mail/remote.go ~:318; deploy/tagged.go ~:443;
state/state.go ~:131 (re-grep: `Fail(` / `Errorf(` near an unused `err`).

## Work

- [ ] each such message carries its cause (headline, via `Cause` on the
      workstation side; the OS reason without the repeated path on the server
      side, as `remote.Install` does)
- [ ] one shared unwrap helper instead of private copies (install.go `osCause`,
      treesync/send.go, serverlock)
- [ ] the raw "(the remote step exited %d)" wording (buildpush/ship.go ~:215 and
      the tests pinning it, serverinit/backup_test.go ~:391, mail/mail_test.go
      ~:481) uses `serverbin.ExitText` like its neighbours
- [ ] tests where a fake already reaches the path
