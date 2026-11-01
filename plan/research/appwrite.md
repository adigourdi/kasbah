# Appwrite — different category, one validated decision

*Researched 2026-09-01. Not spec; see [README.md](README.md).*

**Verdict: not a competitor.** Appwrite is a Backend-as-a-Service — a
self-hostable Firebase. Its user writes application code against Appwrite's
SDKs; kasbah's user brings their own Docker images to their own VPS. Appwrite
is a backend you build *on*; kasbah is a host you deploy *to*.

## What it is

Open-source BaaS / "all-in-one development platform", BSD 3-Clause, created
2019. ~57.2k stars, ~446 contributors, ~35–48 staff, ~$37M raised (seed +
$27M Series A, Tiger Global, Apr 2022; no Series B). Stable 1.9.6 (Jul 2026),
2.0 announced 2026-08-31. Mature and commercially backed.

Product surface: Auth (30+ OAuth providers, OIDC in 2.0), Databases (MariaDB /
MongoDB / native Postgres 18 + MySQL 8.4 in 2.0, plus VectorsDB), Storage
(S3-compatible API in 2.0), Functions (Open Runtimes), Messaging, Realtime,
and Sites. Cloud-only extras: the edge Network/CDN, org Domains, Firewall.
Cloud gets 2.0 features first; self-hosted Community Edition follows.

## Why it isn't a competitor

**It doesn't take containers.** Appwrite Sites — launched May 2025, pitched as
"the open source Vercel alternative" — auto-detects a framework from
`package.json` and builds it on the Open Runtimes executor. Supported: Next,
Nuxt, SvelteKit, Angular, Remix, Astro, TanStack Start, Flutter Web, static.
There is **no bring-your-own-image and no bring-your-own-Dockerfile path**;
Appwrite's own guidance for arbitrary containers is "write a function that
calls your service." A Rails app, a Go binary, a Postgres, any third-party
image — none are deployable to Appwrite at all.

**It is a workload, not a platform for workloads.** The generated compose
defines ~38 services (API, console, realtime, ~15 workers, executor +
orchestrator, redis, clickhouse, a database, optional assistant/browser/geo/
embedding). Docs ask for 2 cores / 4 GB RAM / 2 GB swap; community reports
~4 GB at idle. It owns ports 80/443 with its own Traefik. All of that yields
*one* thing: an Appwrite instance. It is a plausible **tenant** of a kasbah
host, not a manager of unrelated projects.

**Different audience.** Appwrite's user is an app developer avoiding ops.
Kasbah's user has already chosen ops and wants it small.

The one real overlap: "I have an Astro frontend and want it on a URL with
TLS." Sites wins that single case — if you also adopt Appwrite for the
backend, or accept 38 containers to host a static site.

## The finding worth keeping

Appwrite independently arrived at **Traefik with the file provider**, driven by
a `worker-certificates` that issues Let's Encrypt certs and writes dynamic
config into a volume Traefik watches. From its compose:

```
--providers.file.directory=/storage/config
--providers.file.watch=true
--providers.docker=true
--providers.docker.constraints=Label(`traefik.constraint-label-stack`,`appwrite`)
```

Architecturally this is kasbah's T-series routing decision, reached
independently by a 57k-star, $37M-funded project — though scoped to Appwrite's
own domains rather than to arbitrary user containers, and combined with the
docker provider rather than replacing it. Treat it as corroboration of
`docs/traefik.md`, not as a reason to change anything.

Also noted: Appwrite needs **DNS-01 configured by hand** for wildcard
Functions/Sites domains (`*.sites.example.com`). Same wall kasbah hits — see
the phase 9 open question on wildcards for the LAN case. Nobody gets wildcards
free from HTTP-01.

## Actionable

- Nothing to build. If a comparison ever puts kasbah next to Appwrite, the
  answer is the first paragraph of this note.
- Optional positioning line, if it stays true: *"Appwrite is something kasbah
  can host."*

## Sources

- https://github.com/appwrite/appwrite — repo, and its `docker-compose.yml` / `.env` on `main`
- https://appwrite.io/docs/advanced/self-hosting/installation
- https://appwrite.io/docs/advanced/self-hosting/configuration/functions — wildcard / DNS-01
- https://appwrite.io/docs/products/sites and .../sites/frameworks
- https://appwrite.io/blog/post/announcing-appwrite-sites, .../announcing-appwrite-2, .../the-appwrite-network
- https://appwrite.io/pricing
- Forum threads on arbitrary containers: appwrite.io/threads/1126496044998479922, .../1232769324251480105
- Funding: Crunchbase, PitchBook
