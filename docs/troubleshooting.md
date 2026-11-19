# Troubleshooting

The failures a new project most often meets, each under the text kasbah
prints, so searching for the `error:` line lands here. Every failure is laid
out the same way (`cli.md` → How a failure reads): what failed and why, what
to do next, a `kasbah help` topic where one fits, and the log the run saved.
`kasbah help troubleshooting` is the short form of this page.

Where a line below shows `…`, kasbah prints the project's, the server's or a
path's own name there.

## No kasbah.yml in current directory.

```
error: No kasbah.yml in current directory.
       Run from the project root, or `kasbah init-project` to scaffold.
       help: kasbah help S01
```

`kasbah check` prints it as `error: S01 No kasbah.yml in current directory.`
Exit 2.

**Cause:** every project command reads `./kasbah.yml`, and the current
directory has none — it is a subdirectory of the project, or the project was
never set up for kasbah.

**Fix:** `cd` to the project's root, the directory that holds `kasbah.yml`.
For a project that has none yet, `kasbah init-project` writes it and
`.env.prod.example` (`authoring.md`).

## invalid project name '…' (must match ^[a-z][a-z0-9-]*$)

```
error: invalid project name 'My_App' (must match ^[a-z][a-z0-9-]*$)
       The name defaults to this directory's: pass --name=<name> with one that matches.
```

**Cause:** `kasbah init-project` names the project after the current
directory unless `--name` says otherwise, and a project name is lowercase
ASCII letters, digits and `-`, starting with a letter: it becomes the compose
project, the directory on the server and part of every container's name. A
directory called `My_App`, `my.site` or `2048` does not qualify.

**Fix:** pass a name that matches — `kasbah init-project --name=my-app` — and
the directory keeps its own. A few names are reserved (`traefik`, `mail`,
`data`, `backups`, `kasbah-backup`); init-project says so when one is picked.

## Summary: … failed (`kasbah check` exits 6)

```
Summary: 30 passed, 0 warning, 1 failed
`kasbah help S03` (or any ID above) says why a rule exists and what to change.
```

**Cause:** at least one `✗` line above the summary: a rule the project breaks.
`check` never changes anything on its own, and `deploy` refuses several of the
same things itself — an outside container on a published port, a
`container_name` or the project's compose project name (C12, C17, C13), a
`client:` it cannot file backups under (S08) — so a failure here is usually
the deploy's failure, earlier.

**Fix:** `kasbah help <ID>` for the rule on the line — why it exists and what
to change. `kasbah check --fix` repairs the rules it can (C01–C05, C08,
R01–R03) and shows the diff before writing; `kasbah check --server USER@HOST`
adds what only the server can answer.

## cannot reach … over ssh (see ssh's own error above)

```
deploy@vps: Permission denied (publickey).
error: cannot reach deploy@vps over ssh (see ssh's own error above)
       Make `ssh deploy@vps true` work from this shell first: the host answers,
       the user is right, and ssh offers a key the server accepts
       (ssh-add -l lists the agent's).
       help: kasbah help troubleshooting
```

Exit 3.

**Cause:** kasbah runs your own `ssh` with your own configuration, and the
line ssh printed just above says why it failed: `Permission denied
(publickey)` — the server accepts no key ssh offered for that user;
`Could not resolve hostname` — a typo, or an alias your `~/.ssh/config` does
not define; `Connection timed out` — the host is down or port 22 (or the
config's port) is filtered, and kasbah gives up after 10 seconds;
`Host key verification failed` — the server's key is not the one
`~/.ssh/known_hosts` holds for it.

**Fix:** get `ssh USER@HOST true` to succeed from the same shell without
typing anything, then re-run. kasbah takes `USER@HOST` as given — any port,
key or jump host goes in `~/.ssh/config` under that host name. A bare host
(`kasbah server status vps`) is logged in to as the user your ssh config gives
it, and the `kasbah: as …` line before the error names that user.

## could not tell which user ssh logs in to … as

```
error: could not tell which user ssh logs in to vps as: `ssh -G vps` failed: …
       Pass the user yourself: USER@vps.
       help: kasbah help troubleshooting
```

Exit 1, before any connection.

**Cause:** the server was given as a bare host, so kasbah asked ssh which user
it would log in as — `ssh -G HOST`, its `user` line (`cli.md` → Targets) — and
ssh failed (the text after `failed:` is its own, typically a `~/.ssh/config`
it cannot parse), or printed no `user` line, or named a user kasbah does not
take.

**Fix:** pass `USER@HOST`, which kasbah uses as given without asking ssh; or
fix the config until `ssh -G HOST` prints the right `user`.

## ssh logs in to … as root, and kasbah takes root only when it is typed

```
error: ssh logs in to vps as root, and kasbah takes root only when it is typed
       root is the User your ssh config gives vps, or your own login when it gives none.
       Pass root@vps to work as root, or USER@vps with the operator kasbah acts as.
       help: kasbah help troubleshooting
```

Exit 1, before any connection.

**Cause:** the server was given as a bare host and `ssh -G` says root — a
`User root` in `~/.ssh/config`, or no `User` line while you are root locally.
What kasbah creates on the server is owned by the user it acts as, and each
operator is their own Unix user (`server-setup.md` → Operators), so root is
never chosen by a config default.

**Fix:** type `root@HOST` if root is meant, or `USER@HOST` with your own
operator user — or give the host your operator's `User` in `~/.ssh/config`.

## passwordless sudo — `sudo -n true` failed as …

```
error: deploy@vps does not meet the prerequisites for kasbah server init:
       passwordless sudo — `sudo -n true` failed as deploy.
         /apps does not exist, and it lives outside the deploy user's home,
         so only root can create it. Run these once and re-run init — or run init
         from a terminal, where it waits while you do:
       …
       kasbah checks prerequisites and never installs them.
       Fix each line above on the server, then re-run
       `kasbah server init deploy@vps`.
       help: kasbah help troubleshooting
```

**Cause:** the apps path (`/apps` unless `--apps-path=` names another) does not
exist, only root can create it, and the deploy user cannot `sudo` without a
password. kasbah never types a password for you.

**Fix:** run `server init` from a terminal: it prints the few commands to run
as root and waits while you run them in another session. Without a terminal,
run the printed commands as root first, then re-run init. The same table
carries the other prerequisites — `the SSH user can run docker without sudo`
(add the user to the `docker` group and open a new session), Docker 24 and
Compose v2 (`server-setup.md` → Prerequisites).

## … has no server marker at …/.kasbah/server.json

```
error: deploy@vps has no server marker at /apps/.kasbah/server.json
       …
```

Exit 4.

**Cause:** kasbah found no server marker where the apps path says it should
be. Either the server was never prepared, or it was prepared at another apps
path and the pointer that names it (`/etc/kasbah/apps-path`) is gone, or the
pointer names a tree with no marker in it. The lines under the error say
which.

**Fix:** a server never prepared: `kasbah server init USER@HOST`. A server
prepared elsewhere: **do not re-run init at the default** — it would start a
second Traefik and take every site down. Find the tree with
`kasbah server status USER@HOST --apps-path=<dir>` and pass `--apps-path=<dir>`
(`cli.md` → Exit codes, 4).

## … was written by kasbah X, and this is kasbah Y

```
error: /apps/.kasbah/server.json on deploy@vps was written by kasbah 2.0.0, and this is kasbah 1.4.0
```

**Cause:** the server marker belongs to another major of kasbah. A newer major
on the server means fields this binary does not know; an older one means the
server has not been moved to this major.

**Fix:** a newer major on the server: install that major on the workstation
(`kasbah self-update v2`). An older one: `kasbah migrate server USER@HOST`
moves it, as the error's next lines say.

## the server runs kasbah X, newer than this kasbah Y

```
error: the server runs kasbah 1.5.0, newer than this kasbah 1.4.0 — both ends run the server's build
       kasbah 1.5.0 is not installed on this workstation (nothing under …)
       Install it: `kasbah self-update v1.5.0`, or ./install-dev.sh from that tag's checkout.
```

**Cause:** both ends must run the same build, and kasbah never downgrades a
server. When the server's version is installed on the workstation, kasbah hands
the command to it and nothing is printed; this error means it is not.

**Fix:** `kasbah self-update vX` (the server's version), then re-run; the next
run hands off by itself (`cli.md` → Hand-off between installed versions).

## the working tree differs from HEAD

```
error: deploy: the working tree differs from HEAD (v1.2.0) — what it would ship as 1.2.0 is not what v1.2.0 holds
          M compose.prod.yml
       commit them and cut a new tag, stash them, or ship them as a labelled test build:
         kasbah deploy --dirty
```

**Cause:** `deploy` and `build-push` ship HEAD's tag, and the files on disk
are not what the tag holds — a modified or untracked file .gitignore does not
cover.

**Fix:** commit and tag (or let kasbah tag: `--bump=patch`), stash the change,
or ship the tree as it is with `--dirty`, which labels the build
`<version>-dirty.<time>` and is never a rollback target.

## HEAD carries no version tag

```
error: cannot ask: deploy: HEAD carries no version tag — tag it as which release? (…)
       stdin is not a terminal — pass --bump=patch|minor|major instead
```

and, for a project that builds images:

```
error: deploy: HEAD carries no version tag, and demo builds images — a deploy retags the images `kasbah build-push` shipped, and none were shipped under a version not cut yet
```

**Cause:** the version is HEAD's `v` tag, and HEAD has none. From a terminal
kasbah offers to tag it; without one it needs the answer as a flag. A project
that builds images has to ship them under the tag first.

**Fix:** `--bump=patch` (or `minor`, `major`) tags HEAD and goes on; or tag
it yourself (`git tag v1.0.0`). A project that builds images:
`kasbah build-push USER@HOST` first, then `kasbah deploy USER@HOST`.

## … and there is no terminal here to render it on

```
error: /apps/demo/.env does not exist yet on deploy@vps, and there is no terminal here to render it on
       the setup is interactive — it prompts per variable, masks the secret ones and
       runs the template's generators. Either:
       …
       Nothing was deployed.
       help: kasbah help troubleshooting
```

Exit 5. Its sibling, for a server `.env` that has drifted from
`.env.prod.example`:

```
error: cannot ask what to do about the drift: there is no terminal to ask on
```

**Cause:** the server's `.env` is missing, or lacks keys the template has, and
filling it asks questions — with no terminal (CI, a pipe, `ssh -T`) there is
nobody to answer them.

**Fix:** run `kasbah env USER@HOST` once from a terminal; or give the answers
in a file, `--env-seed=FILE` (`env-template.md`); for drift, pass
`--on-drift=setup`, `--on-drift=continue` (deploy against the `.env` as it
is) or `--on-drift=abort`.

## … did not become healthy within …s

```
remote: demo-web-1 did not become healthy within 120s — its last state was 'unhealthy'
…
error: the deploy failed on deploy@vps (the server's kasbah exited 1, see above)
       it was reverted: deploy@vps runs what it ran before, …
       `kasbah logs deploy@vps` shows why the containers did not become healthy;
       health.timeout in kasbah.yml sets how long the wait is.
       help: kasbah help troubleshooting
```

**Cause:** after `compose up` the deploy waits for every container with a
healthcheck to report `healthy`, and one did not in time — its healthcheck
keeps failing (`unhealthy`), or the service is slower to start than the wait
(`starting`). A server with an earlier version is put back on it; a first
deploy is left as it came up.

**Fix:** `kasbah logs USER@HOST <service>` for what the service printed. A
slow start: raise `health.timeout` in `kasbah.yml` (`project-manifest.md`).
A healthcheck that can never pass: fix it in `compose.prod.yml`, then deploy
again. A rollback or `deploy <version>` waits on that version's own tagged
`kasbah.yml`, which no edit reaches, and says so instead: `--no-health-wait`
skips the wait, or the timeout is fixed in a new release.

## a compose project named … already exists outside …

```
a compose project named demo already exists outside /apps/demo: demo-web-1, started from /home/you/demo — Docker keys compose projects by name, …; run `docker compose -p demo down` in /home/you/demo, or rename this project
```

and, for a published port:

```
container other-db-1 (…) publishes 0.0.0.0:5432/tcp, which service db of this project publishes too — stop or move that container, or change the port db publishes
```

and, for a `container_name`:

```
container db (…) already holds db, the container_name service db of this project sets — Docker gives a name to one container per host, running or stopped; remove or rename that container, or change the container_name db sets
```

**Cause:** a container that is not this project's holds what the deploy would
need: the compose project name (Docker would take its containers for this
project's), a host port the project publishes, or a `container_name` it sets
(Docker names one container per host, a stopped one included). The deploy
refuses before changing anything; `kasbah check --server USER@HOST` reports
the same as C13, C12 and C17.

**Fix:** the line names the containers and where they were started: stop them
there (`docker compose -p <name> down`), or rename the project (`name:` in
`kasbah.yml`), or change the port the service publishes. For a name, remove
(`docker rm`) or rename (`docker rename`) the container holding it, or change
the service's `container_name` — beyond C09's prefix on the `kasbah`
network, any name is allowed, so long as no other container on the host has
it.

## traefik-dynamic.yml cannot be rendered: ${…} is not set in …/.env

```
remote: traefik-dynamic.yml cannot be rendered: ${MYAPP_AUTH_SECRET} is not set in /apps/myapp/.env — `kasbah env set MYAPP_AUTH_SECRET deploy@vps` sets it (a key new to .env.prod.example: `kasbah env deploy@vps`, …)
…
error: the deploy failed on deploy@vps (the server's kasbah exited 1, see above)
       nothing was started, and the files it had shipped were put back — …
```

**Cause:** the project's `traefik-dynamic.yml` names a `${KEY}` the deploy
fills from the server's `.env`, and that `.env` has no value for it — the key
was added to the fragment and the template after the server's `.env` was
written, or set empty. The same line says `is empty`, `is not declared in
…/.env.prod.example` or `is a KASBAH_ key` for the other keys a fragment may
not take (`traefik.md` → Project fragment), and `spans lines` for a
multi-line value. A value that would change the fragment's YAML — it does not
parse once filled, or adds a key or a list item — is named by its key and
line, never quoted: single-quote that `${KEY}` in the fragment, or set a value
that reads as one scalar. The deploy refuses before changing anything.

**Fix:** run the `kasbah env set KEY USER@HOST` the line names, then deploy
again. A key this deploy is the first to add to `.env.prod.example` is not on
the server's template yet — the refused deploy put the old one back, and `env
set` changes only a key the server's template declares — so run `kasbah env
USER@HOST`, which ships the template and asks for it, or deploy again from a
terminal and answer the drift prompt with the setup. An undeclared key is
declared in `.env.prod.example` first; `kasbah check` reports it locally as
T12.

## could not load the images onto …

```
error: could not load the images onto deploy@vps (it exited 1, see above)
       Look at docker's error above; a full disk on the server is the usual
       cause (`kasbah server prune deploy@vps` removes old image tags).
       Then re-run build-push.
       help: kasbah help troubleshooting
```

Its sibling, `… could not unpack the images it loaded (see docker's error
above)`, is a load docker accepted and then could not unpack.

**Cause:** `docker load` on the server refused the stream; the server's own
line above says why — most often `no space left on device`.

**Fix:** free space on the server (`kasbah server prune USER@HOST` removes
image tags outside the retention window; `docker system df` there shows what
holds the rest), then re-run `kasbah build-push USER@HOST`.

## could not list the releases of adigourdi/kasbah: …

```
error: could not list the releases of adigourdi/kasbah: Get "https://api.github.com/repos/adigourdi/kasbah/releases?per_page=100&page=1": dial tcp: lookup api.github.com…: no such host
       check that this machine reaches api.github.com over HTTPS — behind a proxy, set HTTPS_PROXY
```

Its siblings, `could not read the release v…` and `could not download … of
v…`, are the same request for one release or one of its files.

**Cause:** `kasbah self-update` — and `get.sh` asked for a version other than
its own — reads GitHub's releases API, and the request got no answer: no
network, a name that does not resolve, a firewall, or a proxy kasbah was not
told about. When GitHub answers and refuses, the line says so instead, and the
line under it what to do: a used-up rate limit (until when), a `Retry-After`
(how long), or a 404 without a token (the repository may be private: set
`GITHUB_TOKEN` or `gh auth login`).

**Fix:** get `curl -sI https://api.github.com` to answer from the same shell.
Behind a proxy, export `HTTPS_PROXY` (and `NO_PROXY` for hosts that bypass
it): kasbah reads them. For a rate limit, wait until the time named, or set
`GITHUB_TOKEN`.

## … checksums.txt does not verify against release.pub

```
error: v1.2.0's checksums.txt does not verify against release.pub (key …): …
       nothing was installed — the release is not one kasbah's key signed
       Fetching it again gets the same files: install nothing of v1.2.0 by hand, and report it.
       help: kasbah help troubleshooting
```

Its siblings: `… checksums.txt is signed as "kasbah X", not "kasbah Y"`,
`kasbah_…: sha256 …, checksums.txt says …`, `kasbah_…: N bytes downloaded, the
release lists M` and `… is not the published kasbah_…`.

**Cause:** before anything is installed, the release's `checksums.txt` must
carry a signature by the key built into kasbah, made for that version, and
each file must match the size and sha256 it lists. A file that does not is a
download cut short, one altered on the way (a proxy that rewrites downloads),
files of two releases mixed in one directory given to `--from DIR` by hand
(`get.sh` downloads into a fresh directory and checks every sha256 itself
before it hands off), or a release kasbah's key did not sign.

**Fix:** the symlink was not moved, and the file that failed was not installed.
What happens next depends on the line:

- **`N bytes downloaded`** is a download cut short: run the command again.
- **A sha256 that does not match**, or **a signature that does not verify**,
  fetched from GitHub: a second run gets the same files unless something on the
  way rewrites them. If it repeats, install nothing of that release some other
  way, and report it (below).
- **With `--from DIR`:** download the release's files again into an empty
  directory and pass that (`get.sh` does so on each run); a signature that
  fails the same way again is worth reporting.

On a Mac, when kasbah downloads the two Linux server builds (not with
`--from`, whose builds are checked before anything is written), a mismatch in
one comes after the macOS binary is in place: `<lib>/<ver>/kasbah` stays,
with any server build checked before it. A second run takes that version as
installed and moves the symlink; the server build it lacks is fetched, verified, when a server first
needs it.

## cannot write …/kasbah: …

```
error: cannot write /home/you/.local/bin/kasbah: symlink kasbah /home/you/.local/bin/.kasbah.new: permission denied
       nothing was installed
       Make /home/you/.local/bin writable by this user, or set KASBAH_BIN_DIR to a directory that is.
       help: kasbah help troubleshooting
```

Its sibling, `cannot make …: …`, is the same directory failing to be created.

**Cause:** an install ends by pointing `<bin>/kasbah` — `~/.local/bin/kasbah`,
or `KASBAH_BIN_DIR`'s — at the version it installed, and this user cannot
create the symlink there: the directory, or one above it, belongs to root,
often after an earlier install or `mkdir` run under `sudo`. kasbah needs no
root and asks for none; an install checks this before it writes anything.

**Fix:** give back the directory the line names — or, for `cannot make`, the
lowest one above it that exists (`ls -ld ~/.local ~/.local/bin` shows the
owners): `sudo chown "$USER" ~/.local/bin`, or `sudo chown "$USER" ~/.local`
when `~/.local/bin` is not there yet. Or install where you can write, with that
directory on `PATH`: `KASBAH_BIN_DIR=$HOME/bin kasbah self-update`, or `curl
-fsSL …/get.sh | KASBAH_BIN_DIR=$HOME/bin sh`. The variable holds for that run
only: export it in your shell profile, or every later `self-update` goes back
to `~/.local/bin` and fails there the same way.

## Anything else

Every run that ends on an `error:` saves a log of what it did on both ends and
names it on its last line (`log: …`); `kasbah --debug <command>` streams the same trace as it
happens (`cli.md` → Debugging a failure).

A bug report goes to https://github.com/adigourdi/kasbah/issues, on the
Bug report form, with what happened and what you expected, the command run,
the output of `kasbah info USER@HOST` when a server is involved (else
`kasbah info`), and the run's log: the path its last line names, which
`kasbah info` also shows as `logs.last`. A run that misbehaves, or exits
non-zero without an `error:` (`kasbah check`'s findings), saves no log;
`kasbah --debug <command>` saves one. A log holds no env value
or secret, but names the run's servers, users and paths: look it over before
attaching it.
