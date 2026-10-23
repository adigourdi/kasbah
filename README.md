# kasbah

A CLI that turns a plain VPS into a multi-project Docker host — shared
Traefik with file-provider routing, image shipping over SSH
(`docker save` streamed into `docker load`, no registry), per-project env
management, hooks, and rollback. Think "cPanel for Docker Compose", in
one Go binary — nothing but Docker and that binary runs on the server.

## Install

Linux, amd64 or arm64:

```sh
curl -fsSL https://github.com/adigourdi/kasbah/releases/latest/download/get.sh | sh
curl -fsSL https://github.com/adigourdi/kasbah/releases/latest/download/get.sh | sh -s -- v1   # a version
kasbah self-update      # later: the newest release of this major
./install-dev.sh        # from a checkout: build this tree (a dev build); ./install-dev.sh v1 builds a tag
```

Everything lands under `~/.local/share/kasbah/<version>/`, with `~/.local/bin/kasbah`
linked to the newest. Verifying by hand, tokens, uninstalling: [docs/install.md](docs/install.md).

## Release

```sh
./release.sh keygen      # once: the minisign key pair; commit release.pub
./release.sh v1.2.3      # VERSION must say 1.2.3; tests, reproducible build, signed checksums, GitHub Release
```

## Quick start

```sh
cd ~/work/my-app
kasbah init-project --name=my-app --domain=my-app.example.com
# author compose.prod.yml (a starter is printed), then:
kasbah check
```

## Docs

The spec lives in [docs/](docs/) — start with
[overview.md](docs/overview.md) (the decisions table) and
[project-manifest.md](docs/project-manifest.md). Development: run
`./test.sh` before committing; conventions in [CLAUDE.md](CLAUDE.md).
