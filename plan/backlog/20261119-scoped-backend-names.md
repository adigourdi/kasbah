---
description: >
  Traefik sits on every project's kasbah network and resolves a fragment's bare backend name
  across all of them, so C09 forces routed services to be `<name>-*` (containers
  `<name>-<name>-<svc>-1`) and nothing on the server stops a fragment from reaching another
  project. Qualify every backend host with the project's own network in the installed fragment
  (`web` → `web.<name>_kasbah`), refuse a backend that is not the project's, and drop C09's
  prefix rule on the project network, in internal/deploy and internal/check.
state: ready
priority: normal
---

## Prompted by

Containers named `proj-proj-svc-1` come from a naming rule forced on every project's compose
file, for an isolation that rests on every project complying. A project should be able to
write `web`, `db` and `http://web:80`, and nothing kasbah-specific.

## Evidence

Measured on Docker 29.9.2 with `traefik:v3.7.10` (file provider), two projects each on its own
network, Traefik attached to both, as kasbah attaches it to `<name>_kasbah`:

- Project containers are isolated from each other: A's container cannot resolve B's `admin`.
- Traefik is not. Project `zzz-mine`'s route to its own `http://web:80`, with project
  `aaa-other` also serving a `web`: 6 of 6 requests served by `aaa-other`, whichever network
  Traefik joined first. This is the hijack C09's prefix rule exists to prevent.
- A fragment pointing at `http://admin:80`, a name only the other project has, is served by it:
  only `kasbah check` (T07) refuses that; `deploy` does not run check.
- A network-qualified host is scoped: `http://web.dnst_a:80` and `http://web.dnst_b:80` each
  reach their own network's `web`, and `http://dnst-a-web.dnst_b:80` (A's container through B's
  network) answers 502. The underscore in the network name is no trouble to Traefik.

Ruled out: Traefik's Docker provider (scoped by `traefik.docker.network`, but `traefik.*`
labels in the project's compose, refused by T06); a Traefik per project (ports 80/443 and
certificates are shared); a generated compose override adding `<name>-*` aliases (every
hand-run `docker compose` in `<apps>/<name>` would miss it).

## The change (kasbah 2.0)

- `kasbah remote deploy fragment` and the engine's pre-flight render qualify every
  `loadBalancer` server URL host with the project's `kasbah` network as compose names it, in
  the installed copy only; the project's `traefik-dynamic.yml` keeps `http://web:80`. The roll
  logic reads the qualified live fragment.
- The same steps refuse, before anything starts, a host that is not a service, `kasbah` alias
  or `container_name` of the project's compose on its `kasbah` network: another project's name,
  an IP literal, an outside hostname, a host already qualified — T07 held on the server.
- kasbah's own `_mail.yml` targets `mail-cypht.mail_kasbah`.
- `container_name` stays allowed, scoped like any name; the pre-flight and `check --server`
  refuse one held by a container outside the project.
- `kasbah-net` is dropped: the Traefik stack no longer creates it, and check's legacy paths go.
- `kasbah migrate server` 1→2 qualifies every installed fragment and `_mail.yml`, removes
  `kasbah-net` from Traefik's compose file, and detaches and removes the network live; a 2.x
  workstation refuses an unmigrated server, and a migrated one refuses 1.x.
- C09 is retired and `init-project` scaffolds `web`. Dropping an existing `<proj>-` prefix is
  the project's own edit, described in `authoring.md`; no migrate step, the manifest schema
  stays 1.

## Done when

A project whose routed service is `web`, fragment `http://web:80`, deploys with a clean
`kasbah check`; its route reaches only its own `web` while another project also serves one; a
fragment naming another project's service or an IP is refused by `deploy`.
