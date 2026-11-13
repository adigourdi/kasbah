---
description: Nothing shows what kasbah ran on the server when a step fails
cause: no debug or trace mode exists; only the final error line is printed
where: internal/cli, internal/ssh, internal/remote, every command's run path
state: ready
priority: high
---

## Prompted by

2026-11-13: seeing which ssh call, `kasbah remote` arm or docker command
failed, and what it printed, took reading the source. A user needs that from
the binary, and something to attach to an issue.

## Evidence

- No `--debug`, `--verbose` or `KASBAH_DEBUG` anywhere in `internal/` or `cmd/`.

## Work

- [ ] `--debug` on every command and `KASBAH_DEBUG=1`: trace each ssh call,
      each remote arm with its arguments, each docker/compose command and its
      stderr, on both ends (the server streams its trace back)
- [ ] Every failed run, debug or not, writes its log to
      `~/.local/state/kasbah/logs/<time>-<command>.log` and the error names it
- [ ] `.env` values and other secrets redacted, so the log is safe to attach
- [ ] Retention: keep the last N logs
- [ ] `kasbah info` gains a line for the log directory and the latest log
      (its key order is pinned in internal/info/info_test.go TestSelf and
      tests/info_test.sh Case 1)
- [ ] docs/cli.md (flag, env var, exit codes untouched), docs/files.md (the
      log files); tests
