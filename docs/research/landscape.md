# Landscape — who kasbah is actually compared to

*Researched 2026-09-01. Not spec; see [README.md](README.md). Star counts
approximate, current that day.*

## The field

| Tool | What it is | Stars | Impl | Server-side footprint | Images | Interface |
|---|---|---|---|---|---|---|
| **Coolify** | Full PaaS, Vercel-alike | ~61k | PHP/Laravel, Apache-2.0 | Heavy control plane, ≥2 GB RAM | Builds on server | Web UI |
| **Dokploy** | Full PaaS, cleaner UI | ~37k | TypeScript, dual/source-available | Heavy control plane | Builds on server | Web UI + CLI |
| **Dokku** | Smallest classic PaaS | ~32k | Shell/Go, MIT | Installs a real platform + plugins | `git push`, buildpacks or Dockerfile | CLI only |
| **Kamal** | Deploy CLI, not a PaaS | ~14.5k | Ruby, MIT | `kamal-proxy` (~10 MB) | **Requires a registry** | CLI only |
| **CapRover** | Heroku-alike on Swarm | ~13k | Node | Swarm + dashboard | Builds on server | Web UI + CLI |
| **Haloy** | New Go deploy CLI | small | Go | `haloyd` daemon + `haloy-proxy` | Local build, ships changed layers over HTTPS | CLI only |
| **kasbah** | Multi-project Docker host | — | Bash | **Traefik only** | `docker save \| rsync \| docker load` | CLI only |

Notes on the numbers: one comparison article cited Dokploy at ~24k against
GitHub's ~37k — GitHub used. Dokploy's `/proprietary` directory is under the
Dokploy Source Available License 1.0, which permits production use only with a
commercial agreement. An independent security audit cited seven CVEs in
Coolify; that claim comes from Haloy's own comparison page and is unverified
here.

## Where kasbah sits

The closest neighbours are **Kamal** and **Haloy**, not the PaaS crowd. All
three are "a CLI on your laptop, SSH, nothing clever on the server."

- **Kamal** is one app per project and hard-requires a registry — the exact
  thing kasbah designed away — and does not do multi-project-on-one-host,
  which is kasbah's entire premise. Installation also wants a Ruby toolchain.
- **Haloy** is the nearest direct competitor: Go, CLI-only, registry optional,
  local build shipped to the server. Its **layer-diff upload is better than
  `docker save` of everything**. But it runs a daemon; kasbah runs none.

Against Coolify / Dokploy / Dokku / CapRover kasbah is a different bet: they
own the server and the config, kasbah deliberately does not. The no-lock-in
rule — *a project checked out without kasbah installed must still run via
`docker compose up -d`* — is a real differentiator none of them can claim.

## Better here

1. **Zero server-side agent.** Not "small daemon" — none. Traefik and the
   project's own containers, full stop. Nobody else in the table says this.
2. **The compose file is the source of truth, authored by the user.** Coolify
   and Dokploy generate and own config; migrating off them hurts. Migrating
   off kasbah is deleting a CLI.
3. **`server destroy` de-brands and leaves every container running.** A
   deliberate exit door; no comparator ships one.
4. **The spec and the tests.** ~11k lines of docs with a decisions table and
   recorded measurements; ~1.5 lines of test per line of lib. Well above the
   norm for this category.
5. **Operational paranoia that reads as earned** — `acme.json` archived and
   never deleted, the append-only backup credential *proved* at init, the
   Traefik fragment shipped last so a failed deploy cannot route to a dead
   container.

## Worse here, and it will be said out loud

1. **24k lines of Bash.** "Auditable bash" is the pitch; "24,000 lines of
   Bash" is the top comment. The roadmap already concedes a Go rewrite
   (phase 5 / v1.x). Expect this to dominate any first thread.
2. **No web UI.** Defensible as a stance, but it removes kasbah from most
   comparison articles, which are written for the dashboard audience.
3. **No git/CI integration.** Laptop-only deploys read as a missing feature to
   most readers regardless of the reasoning in `docs/overview.md`.
4. **`docker save` ships everything, every time.** Haloy already does the
   layer-diff version. The most concrete technical gap in the table.
5. **Secrets are a plain `.env` on the VPS.** Every comparator has *some*
   story here. Already an open question in the roadmap.
6. **Single-server, single-maintainer, 0.1.0-dev, no adopters yet.** Phase 9
   is open and the one real host was de-branded at the phase 8 close.

## Publishing read

The space is saturated at the top and Coolify has won mindshare at ~61k stars.
Out-featuring it is not available and not worth attempting. There is a real,
small niche in "no agent, no lock-in, your compose file, one VPS, many
projects" — Kamal owns the adjacent slot and left the multi-project case
empty. Narrow, but genuine.

If kasbah is published, lead with the constraint list, not the feature list.

## Actionable

- **Layer-diff shipping** instead of a full `docker save` every deploy. The
  one place a comparator is plainly ahead. Backlog candidate; would need a
  measurement to justify against `docs/build-deploy.md`'s current claim.
- **Secrets story.** Not necessarily a `kasbah secrets` command — but the
  roadmap open question now has competitive pressure behind it.
- **The Bash-vs-Go question is now a publishing question, not just an
  engineering one.** Worth deciding before any announcement, not after.
- **Positioning copy**, if kasbah is ever published: constraints first, and
  name Kamal as the neighbour rather than Coolify as the target.
- Nothing here changes a spec decision. Every "worse" item above is either
  already an explicit non-goal in `docs/overview.md` / `docs/roadmap.md` or
  already an open question. That is a good sign: the field found no surprise.

## Sources

- https://wz-it.com/en/blog/self-hosted-paas-comparison-coolify-dokploy-caprover/
- https://haloy.dev/blog/self-hosted-deployment-tools-compared *(vendor's own comparison — motivated; its criticisms of competitors are unverified here)*
- https://dev.to/ameistad/self-hosted-deployment-tools-compared-coolify-dokploy-kamal-dokku-and-haloy-2npd *(same author as Haloy)*
- https://github.com/coollabsio/coolify
- https://github.com/dokploy/dokploy
- https://github.com/dokku/dokku
- https://github.com/basecamp/kamal and https://kamal-deploy.org/docs/installation/
- https://sliplane.io/blog/caprover-self-hosted-heroku-alternative

Not covered (agents were killed mid-run, and depth was capped deliberately):
Piku, Disco, Sliplane, Ptah.sh, Canine, Komodo, Dockge, Portainer, Easypanel.
Portainer/Dockge/Komodo are container-management UIs rather than deploy tools
and are unlikely to change the picture; the rest are small. Real user
sentiment from Reddit/HN was **not** gathered — the scrapers 403'd.
