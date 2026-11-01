---
description: Every service may take 90% of the host; limits read as quotas
cause: KASBAH_*_LIMIT is one server-wide figure injected into every project
where: internal/manifest, internal/env, check --server, server-setup.md
state: ready
priority: normal
---

## Prompted by

Design review, 2026-11-01. Fifteen containers each allowed 90% of RAM means
one leaking app still OOMs the host, while the variable name promises
protection. The user kept the percent so a server change needs nothing from
projects, and asked for a two-way spelling: "the value should get a suffix,
`%` or `m` or `g` and it translates to percentage or megabytes or gigabytes".
Runtime monitoring of what eats CPU stays out of scope.

## Evidence

- `internal/env/cmd.go:353` injects the two keys from the server marker.
- `docs/overview.md` decisions table, Resources: "ceilings against total takeover, not fair-share slices".

## Work

- [ ] Manifest `resources: {cpus: …, memory: …}`, optional; unset keeps today's 90%
- [ ] `memory` requires a suffix: `%` of the marker's total, `m`, `g`; a bare number is refused naming the three
- [ ] `cpus` accepts a bare number as cores (compose's meaning) or `%` of the marker's cores
- [ ] `%` resolved at deploy against `server.json`, written into the managed block
- [ ] `check --server` warns when the absolute sums across projects exceed the host
- [ ] Docs name the limits as per-container ceilings, in `server-setup.md` and `project-manifest.md`
