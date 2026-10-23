# kasbah

A CLI that turns a plain VPS into a multi-project Docker host — shared
Traefik with file-provider routing, image shipping over SSH
(`docker save` streamed into `docker load`, no registry), per-project env
management, hooks, and rollback. Think "cPanel for Docker Compose", in
one Go binary — nothing but Docker and that binary runs on the server.

## Install

```sh
./install-dev.sh    # builds this checkout through Docker (a dev build); installs under ~/.local/share/kasbah/<version>/ and links ~/.local/bin/kasbah to the newest
kasbah self-update   # later: the newest release of this major, verified against release.pub (needs GITHUB_TOKEN or gh)
```

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
