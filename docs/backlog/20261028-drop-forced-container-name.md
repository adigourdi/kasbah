---
description: >
  Fragments must target `container_name` (T07), which forbids `--scale` and
  any rolling recreate, so every redeploy is a 502 window. Let the fragment
  target a project-prefixed network alias the routed service declares instead,
  and resolve hook containers through `compose ps` rather than a fixed name,
  in the check rules, the fragment starter and the deploy engine.
state: ready
priority: normal
---

## Prompted by

Design review, 2026-10-28: "with `container_name` mandatory for routing (T07)
you've also closed the door on `--scale`-based rolling." User: "can we go
without the forced container_name?"

## Work

- [ ] T07: the fragment's target must be an alias the routed service declares on its project network, prefixed with the project name; uniqueness is now a config rule (fail), not Docker's refusal
- [ ] hooks and the stopped-stack refusal resolve containers via `docker compose -p <name> ps -q <service>`
- [ ] `init-project` starter and traefik.md's minimum example use the alias
- [ ] document the expected 502 window per redeploy in build-deploy.md ("No blue/green"), measured on the rig

## References

- `docs/traefik.md:783` (aliases on the shared network), `docs/compliance.md` T07/C09, `internal/check`, `internal/deploy/remote.go`
