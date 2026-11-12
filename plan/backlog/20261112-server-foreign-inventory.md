---
description: >
  server status reports kasbah's own stacks and nothing else, so containers
  kasbah does not manage — running, unhealthy or long exited — and images kasbah
  pulled and no longer uses stay invisible. server prune only removes a
  project's version tags. Show the foreign containers in status, and let prune
  offer the stock images kasbah itself retired, in internal/status,
  internal/prune and docs/cli.md.
state: needs-decision
priority: low
---

## Prompted by

Surveying a server before migrating it to 1.0.0 on 2026-11-12: an unhealthy
foreign container, an exited one months old, and about 5 GB of images nothing
ran — among them stock images kasbah had pulled itself and then replaced (an
earlier Traefik after `upgrade-traefik`, a webmail image after the client
switch, an older mail server image). All of it was found with plain
`docker ps -a` / `docker images`; `server status` showed none of it.

## Evidence

- `internal/status/status.go:764` — Projects lists kasbah projects only.
- `internal/prune/prune.go:364` — prune's scope is version tags ("every version
  tag on … is inside the retention window"); stock images are out of it.

## To decide

1. **Foreign containers in status:** a count line, or one line each with state
   and health. Report only — kasbah never touches them.
2. **Which images prune may offer:** only those kasbah's own templates named in
   an earlier release (a known list), never a foreign project's images.

## Work

- [ ] status: a "not kasbah's" section (name, state, health)
- [ ] prune: retired stock images from kasbah's templates, asked about, with
      `--yes`
- [ ] docs/cli.md (server status, server prune), tests
