# hosting

A CLI that turns a plain VPS into a multi-project Docker host — shared
Traefik with file-provider routing, image shipping over SSH
(`docker save | scp | docker load`, no registry), per-project env
management, hooks, and rollback. Think "cPanel for Docker Compose",
except it's auditable bash and nothing but Docker runs on the server.

## Install

```sh
./install.sh    # copies bin/ to ~/.local/bin, lib/ to ~/.local/share/hosting
```

## Quick start

```sh
cd ~/work/my-app
hosting init-project --name=my-app --domain=my-app.example.com
# author compose.prod.yml (a starter is printed), then:
hosting check
```

## Docs

The spec lives in [docs/](docs/) — start with
[overview.md](docs/overview.md) (the decisions table) and
[project-manifest.md](docs/project-manifest.md). Development: run
`./test.sh` before committing; conventions in [CLAUDE.md](CLAUDE.md).
