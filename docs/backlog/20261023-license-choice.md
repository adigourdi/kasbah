---
description: >
  The repository has no licence, so once public it is visible but nobody may
  legally use, fork or package it. Choose one and add `LICENSE` at the root,
  named in README.md.
state: needs-decision
priority: high
urgency: Must land before the repo goes public ([[go-public]]).
---

## Prompted by

Planning the public install path (Phase 11, `docs/phases/11-open.md`) on
2026-10-23: going public "soon" surfaced that no `LICENSE` exists. Asked whether
it belonged in the phase, the user answered "backlog license decision".

## To decide

1. **Which licence.** MIT — permissive and short, the usual for CLIs of this
   kind. Apache-2.0 — permissive with an explicit patent grant. AGPL-3.0 —
   copyleft that reaches anyone running a fork as a hosted service.

## Work

- [ ] `LICENSE` at the root; README.md names it
