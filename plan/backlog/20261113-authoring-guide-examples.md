---
description: Writing a project's files takes reading the source to get right
cause: docs/ is a reference by command and rule ID, not by the file you write
where: docs/authoring.md, docs/troubleshooting.md, examples/, test.sh
state: ready
priority: high
---

## Prompted by

2026-11-13: what to put in `compose.prod.yml` and `traefik-dynamic.yml`,
what is allowed, what fails and what only warns, was answered from the code.
compliance.md lists every rule, but from check's side; nothing walks an author
through a file, or through the common shapes of a project.

## Work

- [ ] `docs/authoring.md`: per file (`kasbah.yml`, `compose.prod.yml`,
      `traefik-dynamic.yml`, `.env.prod.example`) what is required, allowed,
      a failure or a warning, and why; links into compliance.md for the rules
- [ ] Setups, written generically: web app, app + database, worker with no
      route, redirect-only domain, raw TCP/UDP port, an app that sends mail,
      persistent volumes
- [ ] `docs/troubleshooting.md`, keyed by the exact error text, each entry the
      cause and the fix — generic, not one operator's history
- [ ] `examples/<setup>/`, one per setup, each run through `kasbah check` in
      `test.sh` so none can drift; start from `tests/fixtures/` (`built-app`,
      `demo`, `redirect`)
- [ ] docs/README.md index; README.md points at the guide

## References

- `docs/compliance.md`, `docs/project-manifest.md`, `docs/traefik.md`
- `docs/cli.md` → `init-project` (the starter snippet it prints)
