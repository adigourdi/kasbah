---
description: >
  A first deploy onto a server that already runs stacks kasbah did not start can
  collide with them: a host port the project publishes may be held by a foreign
  container, and a compose project of the same name elsewhere on the host is one
  compose project to Docker. Neither is noticed before compose up. Add a
  pre-flight to deploy in internal/deploy, with the reason and the way out.
state: ready
priority: normal
---

## Prompted by

Adopting a hand-run stack (`docker compose` in a home directory) as a kasbah
project on 2026-11-12. Both stacks used the same compose project name and the
same published UDP port. The old stack had to be stopped by hand first; had it
not been, compose up would have failed on the port — and compose, keying on the
project name, would have treated the foreign container as part of the new
project.

## Evidence

- The two stacks shared `com.docker.compose.project` while their
  `com.docker.compose.project.working_dir` differed (`docker compose ls -a`
  lists both config paths under one name).
- `docker compose up` on an allocated port fails mid-run ("port is already
  allocated"), after the project's files are already synced.

## Work

- [ ] before compose up: the ports compose.prod.yml publishes vs the host's
      containers outside this project — refuse, naming the container
- [ ] a compose project of the same name whose working dir is not
      `<apps>/<name>` — refuse, naming its config files and `docker compose down`
- [ ] `check --server` reports the same two, so they show before a deploy
- [ ] rig test with a foreign stack holding the port and the name; docs/build-deploy.md
