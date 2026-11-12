---
description: >
  A project that publishes a raw port and has no Traefik fragment (a UDP relay)
  works, but kasbah treats the missing fragment and the empty domain as things
  to fix: three warnings on every check, forever, and compliance.md still
  lists M01 "domain set" as a failure the code no longer raises. Decide how a
  project says it is unrouted, and reconcile docs/compliance.md, check and
  server status.
state: needs-decision
priority: low
---

## Prompted by

Adopting a UDP relay (socat, one UDP port published) on 2026-11-12. Its
manifest first carried an invented hostname because compliance.md says a
domain is required; `kasbah check --server` then warned forever that no
certificate exists for it. With `domain: ""` instead, check passes, and the
warnings say plainly there is nothing to look for — but they still warn.

## Evidence

- `docs/compliance.md` M01: "`domain` set | fail". The code: `internal/manifest/manifest.go:71`
  ("Domain may be empty … the commands that need one enforce it themselves"),
  and `internal/check/check.go:1401` labels the mail-claim section M01.
  `kasbah check` on an empty domain: 0 failed. The doc drifted.
- Warnings that never clear on such a project: `traefik-dynamic.yml missing —
  skipping C03 and C11`, `… skipping T02–T05 and T08–T10`, and under `--server`
  `the manifest names no domain, so there is no certificate to look for`.
- `kasbah deploy` warns `no traefik-dynamic.yml … nothing was written`;
  `server status` says `nothing routes to this project` — accurate, and fine.

## To decide

1. **How a project says "unrouted".** Infer it from the missing fragment plus an
   empty domain, or an explicit manifest key (optional, so no schema bump).
2. **What stays a warning.** A fragment missing *by accident* is worth one; one
   missing by design is noise.

## Work

- [ ] Fix compliance.md's M01 row to what the code checks (and the doc's id for
      the mail-claim rule)
- [ ] The chosen signal, and check / check --server quiet for it
- [ ] docs: project-manifest.md (domain optional, and when), traefik.md
