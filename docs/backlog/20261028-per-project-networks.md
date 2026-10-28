---
description: >
  Every routed container of every project sits on the one shared `kasbah-net`,
  so a compromised container reaches its neighbours and routed services
  collide on bare service-name aliases (C09). Give each project its own
  compose-owned network that Traefik joins live with `docker network connect`
  at deploy, leaving `kasbah-net` to kasbah's own stacks, in the deploy engine,
  drop, the Traefik start step and `kasbah check`.
state: ready
priority: high
---

## Prompted by

Design review, 2026-10-28, raised by the user: "one hacked container can
propagate to siblings … and having traefik join project networks would impact
the whole server for one project's deployment". Answer: attaching a running
container to a network is live — no Traefik restart, no change to its compose.

## Work

- [ ] project compose declares a non-external `kasbah: {}` network for its routed services (runs standalone without kasbah — no `external:`)
- [ ] engine: `compose up -d` → `docker network connect <project>_kasbah traefik` (idempotent) → health → report → fragment last
- [ ] drop: fragment removed → `network disconnect` → `compose down` (down fails on a network with a foreign container attached)
- [ ] Traefik start step (`server init`, `upgrade-traefik`): re-attach every project network, enumerated from `dynamic/*.yml` minus `_` files; rig test asserts routing after an upgrade
- [ ] the routed target keeps a project-prefixed alias — Traefik sits on all project networks and resolves names across them, so C09 becomes a fail for the routed service rather than disappearing
- [ ] `kasbah-net` stays (frozen name) for `_mail.yml`/webmail and for projects not yet migrated; `check` accepts both shapes in 1.x
- [ ] docs: traefik.md Network, compliance.md C03/C07/C09, project-manifest.md starter

## References

- `docs/traefik.md` → Network, Lifecycle on deploy / rollback / drop
- `internal/deploy/remote.go`, `internal/drop`, `internal/serverinit`, `internal/upgrade`
