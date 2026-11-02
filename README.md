# kasbah

kasbah turns a plain Linux VPS into a host for many Docker Compose projects.
You keep writing your own compose file and building on your own machine;
kasbah streams the images to the server over SSH, with no registry in
between, runs each project behind one shared Traefik that serves its domain
over HTTPS, and records every version it deploys so you can roll back. The
server needs only Docker: kasbah copies its own binary there, and everything
it runs is a container.

A shared mail server and off-server backups are there when a project needs
them.

The name is the shape: a kasbah is a fortified citadel, many dwellings behind
one wall, reached through one gate.

## How to use it

From a project's directory, every release is a git tag, two
commands and a push of the tag:

```sh
git tag v1.2.0
kasbah build-push deploy@vps.example.com   # build the images, stream them to the server
kasbah deploy                              # ship the files, start the new version, route it
git push origin v1.2.0                     # publish the tag: kasbah never pushes it
```

And when something goes wrong:

```sh
kasbah history     # what ran on the server, and when
kasbah rollback    # back to the previous version
kasbah logs -f     # follow the project's logs
```

Commands remember the last server a project used. `kasbah --help` lists them
all; [docs/cli.md](docs/cli.md) describes each one.

## Requirements

- **Your machine:** Linux or macOS on amd64 or arm64 (the macOS build is not yet
  verified on a Mac), with Docker and its compose plugin,
  `ssh` and `git`.
- **The server:** Docker 24 or newer with Compose v2 or newer, SSH key login as
  a user in the `docker` group, root for the first setup (passwordless `sudo`,
  or running the few commands kasbah prints), ports
  80 and 443 reachable from the internet, and DNS pointing at it for each
  project's domain — and for `traefik.<your domain>` when you serve the Traefik
  dashboard (optional).

## Installation

```sh
curl -fsSL https://github.com/adigourdi/kasbah/releases/latest/download/get.sh | sh
```

kasbah installs under `~/.local/share/kasbah/` and links `~/.local/bin/kasbah`;
`kasbah self-update` later installs the newest release of the same major
version. Other ways to install, verifying a download yourself, and
uninstalling: [docs/install.md](docs/install.md).

## Setup

Once per server, prepare it to host projects. It asks whether you want the
mail server and the backups:

```sh
kasbah server init deploy@vps.example.com --domain=example.com --email=you@example.com
```

Certificates come from Let's Encrypt, whose rate limits count failed attempts:
until DNS is right, `--acme-staging` rehearses against its staging service.

Once per project, from its directory:

```sh
kasbah init-project --name=my-app --domain=my-app.example.com
```

It writes `kasbah.yml` and `.env.prod.example`, the template the server's
`.env` is generated from: each variable listed there is asked for at the first
deploy. It also prints a starter for the two files you write yourself:
`compose.prod.yml`, the compose file the server runs, and
`traefik-dynamic.yml`, how its domain routes to it. `kasbah check` then tells
you whether the project is ready to deploy. More in
[docs/server-setup.md](docs/server-setup.md) and
[docs/project-manifest.md](docs/project-manifest.md).

## Limitations

- There is no Windows build, and the macOS one has not yet been run on a Mac.
- kasbah checks that Docker and SSH access on the server are ready, but installs
  none of the prerequisites, never checks ports or DNS, and never touches the
  firewall or SSH configuration.
- Deploys start from your machine; nothing deploys on a `git push`.
- A rollback restores code and configuration; it restores data only through
  the project's own `restore` hook, from the newest backup of that version
  — a deploy's, a rollback's, a `kasbah backup`'s or the nightly backup's.
  kasbah dumps and loads no database itself.
- Secrets live in a plain `.env` file on the server, readable by every operator
  in the server's `kasbah` group and nobody else.

## Documentation

The full documentation is in [docs/](docs/README.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The build plan and the backlog are in
[plan/](plan/roadmap/README.md).

## License

MIT — see [LICENSE](LICENSE).
