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

## Summary: … failed (`kasbah check` exits 6)

```
Summary: 30 passed, 0 warning, 1 failed
`kasbah help S03` (or any ID above) says why a rule exists and what to change.
```

**Cause:** at least one `✗` line above the summary: a rule the project breaks.
`check` never changes anything on its own, and `deploy` refuses several of the
same things itself — an outside container on a published port or the
project's compose project name (C12, C13), a `client:` it cannot file backups
under (S08) — so a failure here is usually the deploy's failure, earlier.

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
key or jump host goes in `~/.ssh/config` under that host name.

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
       install it: `kasbah self-update v1.5.0`, or ./install-dev.sh from that tag's checkout
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
container other-db-1 (…) publishes 0.0.0.0:5432->5432/tcp, which service db of this project publishes too — stop or move that container, or change the port db publishes
```

**Cause:** a container that is not this project's holds what the deploy would
need: the compose project name (Docker would take its containers for this
project's) or a host port the project publishes. The deploy refuses before
changing anything; `kasbah check --server USER@HOST` reports the same as C13
and C12.

**Fix:** the line names the containers and where they were started: stop them
there (`docker compose -p <name> down`), or rename the project (`name:` in
`kasbah.yml`), or change the port the service publishes.

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

## Anything else

Every failure saves a log of what the run did on both ends and names it on its
last line (`log: …`); `kasbah --debug <command>` streams the same trace as it
happens (`cli.md` → Debugging a failure). A bug report is most useful with the
output of `kasbah info USER@HOST` and that log.
