---
description: >
  `server init` always publishes the Traefik dashboard at `traefik.<domain>`
  behind basic auth, with no way to leave it off or turn it off later. Make it
  a `--with-dashboard` / `--no-dashboard` choice recorded in the marker, where
  a re-run with `--no-dashboard` removes the two routers from `_shared.yml`,
  in internal/serverinit, templates/traefik and server-setup.md.
state: ready
priority: normal
---

## Prompted by

Design review, 2026-10-28: "Dashboard public by default … make it opt-in."
User: "we can make it optional, but first, how do we change these initial
decision, same for --with-mail". Answer: init is already additive on re-run
(`server-setup.md` → Idempotency rules: `--with-mail` adds, `--no-mail` leaves
alone); the dashboard is only two routers in a file Traefik watches, so unlike
mail, turning it off is as cheap as turning it on.

## Work

- [ ] tri-state flag; unset = ask, as every other init choice; stored in `server.json`
- [ ] off: `_shared.yml` rendered without `traefik-dashboard`/`traefik-dashboard-http`; `traefik.yml` keeps `api.dashboard` (harmless unrouted); `upgrade-traefik`'s "dashboard router must appear in the dry run" proof needs another witness when off
- [ ] on from off: asks for the password as a first init does
- [ ] `server status` reports it; docs: server-setup.md, traefik.md Dashboard, roadmap's "Dashboard-optional Traefik template" line
