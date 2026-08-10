# The rig — a container that plays VPS

A privileged Debian container running its own dockerd behind sshd, so
hosting's commands can be driven over real SSH against real Docker instead
of a local shortcut. It exists because the chosen exit bar for every phase
is "works against a container that plays VPS" — the rig is what makes that
bar checkable.

```
tests/rig/rig.sh up                 # build if needed, start, wait until usable
tests/rig/rig.sh ssh                # interactive session as stevedore
tests/rig/rig.sh ssh -- 'docker ps' # run a command, exit status propagates
tests/rig/rig.sh reset              # pristine rig, ~3 s
tests/rig/rig.sh down               # stop and remove its volume
```

Integration tests assume a running rig and never start one:

```
tests/rig/rig.sh up
HOSTING_RIG_TESTS=1 ./test.sh
```

## Shape

| | |
|---|---|
| Base | `debian:bookworm-slim` + docker-ce from Docker's apt repo, **unpinned** |
| SSH user | `stevedore` — in the `docker` group, passwordless sudo, **root login disabled** |
| Ports | `5022→22`, `5080→80`, `5043→443`, bound to `127.0.0.1` |
| Storage | named volume at `/var/lib/docker`; nested driver `overlayfs` |
| Keypair | generated per checkout by `rig.sh`, gitignored, never committed |
| Connection contract | the generated `tests/rig/ssh_config` — hand it to `ssh -F`, `scp -F`, `rsync -e`. Do not restate its flags anywhere |

`HOSTING_RIG_BIND` and `HOSTING_RIG_SSH_PORT` affect only a container being
*created*. Once one exists, `rig.sh` reads the published endpoint back out
of Docker and renders `ssh_config` from that — the port is a property of
the running container, not of whatever a later caller happens to have
exported. Otherwise one stray `HOSTING_RIG_SSH_PORT=… rig.sh ssh` would
repoint the shared file at a port nothing listens on and every subsequent
caller would blame the rig.

Overridable: `HOSTING_RIG_BIND`, `HOSTING_RIG_{SSH,HTTP,HTTPS}_PORT`,
`HOSTING_RIG_READY_TIMEOUT`, `HOSTING_RIG_DOCKERD_TIMEOUT`,
`HOSTING_RIG_DOCKER_VERSION`.

Docker's version is deliberately **not pinned** — the rig should look like
a VPS provisioned today. The build that produced this text carried
docker-ce 29.7.2, containerd.io 2.3.3 and compose v5.4.0, but that is a
snapshot of one build, not a property of the rig: it moves whenever a
cache-busting rebuild happens. Ask the rig, don't trust this paragraph.
To reproduce an old version:
`HOSTING_RIG_DOCKER_VERSION=5:27.1.1-1~debian.12~bookworm tests/rig/rig.sh reset`.

## Limitations — what the rig cannot prove

**ACME cannot issue.** The rig has no public DNS name and nothing reaches
port 80 from outside this machine, so Let's Encrypt's HTTP-01 challenge
can never complete. Traefik will serve its built-in self-signed
certificate instead. Until Phase 6, TLS is asserted as *"Traefik serves
HTTPS at all"* (`curl -k`) — never as *"a valid certificate was issued"*.
Phase 6 puts a real project on a real VPS with real DNS; that is where
certificate issuance is proven, and nowhere earlier.

**It is a container, not a machine.** No systemd, no reboot, no kernel of
its own, no disk-pressure or memory-pressure behaviour worth trusting, no
firewall. Resource limits computed from `nproc`/`MemTotal` inside it
reflect the *host*, not a VPS's real allocation.

**sshd runs `maxstartups 10:30:100`.** More than about ten concurrent SSH
sessions get random early drops — `Connection closed`, exit 255. Batch
work into one session rather than fanning out.

**Not hermetic.** The smoke test pulls `hello-world` from Docker Hub on
every run, deliberately: a cached image would reduce the assertion to "a
local image starts", which is not what "docker functional" means. Offline,
or past an anonymous pull limit, the suite fails — with an accurate
diagnosis, but it fails.

**A checkout path containing spaces breaks it.** The generated
`IdentityFile` line and the `rsync -e "ssh -F …"` recipe both assume no
spaces. Known and unfixed; a partial fix that left the recipe broken would
be worse.

**`docker compose up` never rebuilds this image on its own** (`build:`
paired with a fixed `image:`), which is why `rig.sh` always calls
`compose build` and lets the layer cache decide. Driving compose directly
gets you whatever `hosting-rig` already is.

## Rules for anything that drives the rig

- **Always pass `-p hosting-rig` to `docker compose`.** The `name:` key in
  a compose file is the *weakest* source of the project name —
  `COMPOSE_PROJECT_NAME` in the environment outranks it, and `down`
  removes by project label rather than by the services the file lists.
  With that variable set for another stack, `docker compose -f
  tests/rig/compose.yml ps -a` lists *that stack's* containers.
- **Never run a global prune.** This repo is developed on workstations
  with unrelated containers running.
- **`ssh host cmd args` re-joins its arguments with spaces.** Wrap a remote
  command in a single quoted string, or the quoting is lost.
- **The compose healthcheck is a monitoring signal, not a readiness gate.**
  It has been observed reporting `healthy` on a rig nobody could log into
  (a mismatched authorized key). `rig.sh` waits on a real `ssh … docker
  info` probe instead.
