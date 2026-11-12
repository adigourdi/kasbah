---
description: >
  build-push replaces a server image tag that already exists with different
  bytes without a word, so a version shipped once from a discarded build is
  silently overwritten by a new one of the same number. Warn, or refuse, when
  the server's <image>:<version> exists with another digest, in
  internal/buildpush and docs/build-deploy.md.
state: ready
priority: low
---

## Prompted by

2026-11-12: a server held `<image>:0.1.2` built weeks earlier and never
deployed; the project's tags no longer had a v0.1.2, so the next build-push
bumped to 0.1.2 and `docker load` retagged over it. Harmless that time, but a
version number on a server should mean one build.

## Evidence

- `internal/buildpush/load.go:19` — the stream goes straight into `docker load`,
  which retags without asking.

## Work

- [ ] before the stream: read the server's digest for each `<image>:<version>`;
      on a mismatch warn (or refuse, naming `--force`), on a match skip the send
- [ ] test; docs/build-deploy.md (build-push)
