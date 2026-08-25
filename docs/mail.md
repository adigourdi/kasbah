# Mail — docker-mailserver + SnappyMail

An optional kasbah primitive: one shared mail stack per VPS, enabled via
`kasbah server init --with-mail`. Ported from the original project's `mail/` and
generalized to serve multiple app domains.

## Components

| Service | Image | Container | Purpose |
|---|---|---|---|
| `mail-dms` | `ghcr.io/docker-mailserver/docker-mailserver:15.1.0` | `mail-dms` | Postfix + Dovecot + Rspamd + Fail2ban. One maintained image, replacing OpenDKIM, OpenDMARC, Amavis and policyd-spf with Rspamd |
| `mail-snappymail` | `djmaze/snappymail:v2.38.2` | `mail-snappymail` | Webmail, served at `webmail.<domain>` through Traefik |

Both pinned to the exact tags the original project runs in production, which is the
whole argument for them: these two versions are known to work together and
with Traefik's `acme.json`. Bumping either is a deliberate edit to
`templates/mail/compose.yml` and a re-run of init.

The container names are load-bearing twice over — this document's
`docker exec mail-dms …` lines, and `_mail.yml`'s
`http://mail-snappymail:8888`. The compose *service* names match them rather
than being the shorter `dms`/`snappymail`, because compose registers a
service name as a DNS alias on every network it joins and a bare `dms` on the
shared `kasbah-net` is the collision `kasbah check`'s C09 warns every project
about.

Mail ports `25`, `465`, `587` and `993` are bound on the host. Traefik is an
HTTP proxy and is not in the mail data path.

## TLS flow

DMS needs a Let's Encrypt cert for `mail.<domain>` to start, but Traefik
only issues certs when a router requests the host. If we only had a DMS
router, it'd deadlock: DMS won't boot → router never registers → cert
never issued → DMS won't boot.

`kasbah server init --with-mail` writes a kasbah-owned fragment at
`/apps/traefik/dynamic/_mail.yml` that declares a **cert-trigger router**
claiming `Host(\`mail.<domain>\`)` on `websecure` with
`tls.certResolver: letsencrypt`. The router is registered the moment
Traefik loads the fragment — independent of SnappyMail or DMS startup.
Traefik requests the cert → DMS reads it from `acme.json` and boots.

The `_mail.yml` fragment also holds SnappyMail's webmail router
(`Host(\`webmail.<domain>\`)` → `http://mail-snappymail:8888`). Both
routers living in a kasbah-owned fragment makes the boot-order deadlock
impossible regardless of container health.

The original project broke the same deadlock differently, because it had to: under
Traefik's **docker** provider every router must name a real service, so the
cert-trigger router lived on the *SnappyMail container's labels* (SnappyMail
boots in ~10 s whatever the cert store holds) and carried a
`replacepathregex` middleware rewriting every path to `/nonexistent` so that
SnappyMail answered 404. kasbah does not wire the docker provider in at all,
so the router moves into the file fragment and the middleware goes away:
`service: noop@internal` is Traefik's own placeholder for a router with no
backend, and `_shared.yml`'s dashboard redirect already uses it.

**`https://mail.<domain>` answers `418`, not `404`** — that is what
`noop@internal` returns (measured). Nothing is served and no backend is
reached, which is all the cert-trigger needs; the original project's 404 came from
SnappyMail being handed a path it did not have.

Four routers, not two. Each hostname also gets a `web`-entrypoint router
carrying `http-to-https` — unqualified, because the middleware is defined by
the same file provider — and served by `noop@internal`, so plain HTTP
redirects rather than returning Traefik's 404 — the shape `docs/traefik.md`
asks of every project fragment (T08). **That is not what makes ACME work.**
Traefik answers the HTTP-01 challenge from its own internal
`acme-http@internal` router on `:80` (`PathPrefix(/.well-known/acme-challenge/)`,
observed in Traefik's router table), with no fragment involved — the original project's
comment on the equivalent router says otherwise and is wrong. For
`webmail.<domain>` the redirect is the difference between a working
bookmark and a 404; for `mail.<domain>` it is only consistency, since
nothing is served either way.

Traefik issues at **configuration load**, not on the first request
(`traefik.md` → Which CA), so both hostnames must already resolve to the host
when the fragment lands. A `certResolver` on a name that does not resolve
spends Let's Encrypt rate-limit budget with nobody visiting.

## Multi-domain support

The original project hosts a single domain. Kasbah generalizes: multiple app domains
can share one DMS instance.

```yaml
# /apps/mail/kasbah.yml  (kasbah-managed, not a user project)
name: mail
primary_domain: example.com          # MX for this + reverse DNS
domains:
  - example.com
  - shop.example.com
  - another-app.com
```

**This file is the registry, and nothing else is.** It is the only thing
asked "does this stack serve X?". The `.env` beside it carries what compose
and DMS interpolate — `MAIL_HOSTNAME`, `DOMAIN`, `DATA_PATH` — and those are
*derived from here* and rewritten by every mail command, so there is one
writer per fact and the two cannot drift. Below them sits the operator's
relay block, which kasbah copies through and never reads back to the
workstation.

Both values are read back off the server on every run rather than
regenerated, so a hand edit to `primary_domain` survives and is how the MX
hostname is moved. On a first run it defaults to `--domain`'s apex.

Reading it from the workstation means base64-ing the file back over SSH and
parsing it with the local `yq`: the VPS has no `yq`, `jq` or `python3`, and
keeping it that way is deliberate.

For each additional domain:
- DNS needs MX → `mail.<primary>` (apps don't need their own MX record).
- SPF + DKIM + DMARC must be published per domain.
- DMS `postmaster-aliases.cf` routes `postmaster@<domain>` → the primary mailbox.
- SnappyMail adds the domain via the pre-seeded JSON config.

`kasbah server add-mail-domain <domain>` (v0.2) automates this.

## Account management

Deliberately out of the deploy cycle. Accounts are created/removed via
DMS's own CLI on the VPS:

```
ssh user@vps docker exec mail-dms setup email add noreply@example.com
ssh user@vps docker exec mail-dms setup email del old@example.com
ssh user@vps docker exec mail-dms setup email list
```

Rationale:
- Deploys shouldn't touch user data.
- Account list is small and changes slowly.
- Making accounts a manifest field would create friction for ops tasks
  (rotating a compromised password, removing an ex-employee).

`kasbah deploy` does **not** reconcile accounts. It only validates that
the claimed domain is known to the mail stack.

## SMTP access from apps

Apps that need to send mail connect to DMS over the shared `kasbah-net`
network:

```
MAIL_HOST=mail-dms      # container hostname
MAIL_PORT=587           # submission / STARTTLS
MAIL_USER=noreply@example.com
MAIL_PASSWORD=...       # set by admin via setup.sh
MAIL_ENCRYPTION=tls
```

Apps don't expose SMTP publicly; they only use it internally. External
submission (e.g. for humans using a mail client) goes through the public
ports (25/465/587/993) on the VPS.

## Per-app mail claims

A project manifest can declare:

```yaml
mail:
  domain: shop.example.com
  snappymail_domain: ./mail/snappymail-domain.json    # optional pre-seed
```

What kasbah does with it:
1. On deploy, verify the mail stack is up.
2. Verify `shop.example.com` is in `/apps/mail/kasbah.yml`'s `domains` list.
3. If `snappymail_domain` is set and the target file is missing on the VPS,
   copy it into `/apps/data/mail/snappymail/_data_/_default_/domains/<domain>.json`.

Steps 2 and 3 are not implemented yet; the deploy warns rather than checking.
Step 3 has a wrinkle worth knowing before it is built: SnappyMail chowns its
whole data tree to the container's own uid at mode 750 on first boot, so that
`domains/` directory is **not writable, or even traversable, by the deploy
user**. The copy has to go through the container (`docker cp`, or a
`docker exec` writing the file) or through sudo.

What kasbah does NOT do:
- Create mailboxes.
- Generate DKIM keys (admin runs `docker exec mail-dms setup config dkim …`).
- Publish DNS records.

The mail stack's setup walkthrough (ported from the original project's `mail/SETUP.md`)
is shown once after `kasbah server init --with-mail` and also accessible
via `kasbah server mail-setup-guide user@vps`. Neither exists yet; what init
prints today is the stack's state and the one warning that matters — that
DMS crashlooping while the first certificate is issued is expected.

## Pre-seeding (first-deploy gotchas, preserved)

All three exist because somebody lost time to them. The first two are done by
`server init --with-mail`, **before the DMS container is created** — which is
the whole of what makes them work, and is asserted rather than assumed.

- **DKIM dual-signing config** — Ed25519 primary + RSA fallback.
  `rspamd-dkim-signing.conf` is rendered for the primary domain and copied to
  `<data>/mail/dms/config/rspamd/override.d/dkim_signing.conf` before first
  start, so the `setup config dkim` helper generates keys without writing its
  own single-selector default over it. **Copy-if-missing**: once DMS has run
  that helper the file names real key paths, and re-shipping kasbah's copy
  would break signing.
- **Postmaster account** — DMS's Dovecot panics within 120s if no account
  exists in `postfix-accounts.cf`. `kasbah server init --with-mail` prompts
  for the postmaster password, hashes it locally (`openssl passwd -6`), and
  seeds `postmaster@<primary>|{SHA512-CRYPT}$6$…` before starting DMS — the
  exact line DMS's own file provisioner writes. Only the hash crosses the
  wire. **Written only onto a file with no account in it**: that file holds
  every mailbox on the server, so a re-run neither asks for a password nor
  rewrites the account.
- **SnappyMail domain config** — pre-seeded from the file referenced in a
  project's manifest, keyed by the project's domain. Not implemented yet; see
  the wrinkle under "Per-app mail claims" above. What `server init` does today
  is create `<data>/mail/snappymail` as the bind-mount source — and *only*
  that, because SnappyMail builds `_data_/_default_/domains/` itself and
  takes ownership of the lot, and a kasbah that pre-created that tree worked
  once and then failed every re-run with a permission denial.

## Outbound relay (opt-in)

If VPS IP has poor reputation or ISP blocks port 25 egress, configure a
relay in `/apps/mail/.env`. Those three keys are the **operator's half** of
that file: kasbah rewrites the three keys above them by name and copies every
other line through untouched, so what is set here survives a re-run and never
leaves the server.

```
DEFAULT_RELAY_HOST=[smtp-relay.brevo.com]:587
RELAY_USER=...
RELAY_PASSWORD=...
```

Empty = direct delivery via port 25 (the original project's default). Apply with
`docker compose -p mail up -d` in `/apps/mail`.

## Mail is optional

If `kasbah server init` was run without `--with-mail`, the `mail/`
directory doesn't exist. A project's `mail:` claim then fails
compliance at deploy time with a clear message:

```
ERROR: Project claims mail domain `shop.example.com` but no mail stack
       is installed on the VPS.
       Enable it with: kasbah server init user@host --with-mail
       Or remove the `mail:` section from kasbah.yml.
```

## First run, and what "not healthy" means

`SSL_TYPE: letsencrypt` makes a certificate for `mail.<domain>` a **boot
requirement** for DMS, not a nicety. On a first run the sequence is:

1. Init ships `_mail.yml` and the two pre-seeds, then starts Traefik. Traefik
   loads the fragment and asks Let's Encrypt for both hostnames straight away.
2. Init starts the mail stack. SnappyMail is healthy in ~10 s and init waits
   for it.
3. If the certificate is not in `acme.json` yet, **DMS crashloops**, logging
   `Unable to find key and/or cert for '<domain>' in
   '/etc/letsencrypt/acme.json'`.
4. Once it lands, DMS reads it and comes up healthy, then watches `acme.json`
   and reloads on renewal.

**Step 3 is often skipped entirely, and that is the point of the ordering.**
Because the fragment goes into Traefik's watch directory *before* the mail
containers start, issuance runs in parallel with the image pull. Measured on a
first run against a real OVH host: Traefik requested both certificates 5 s into
the run and had `mail.<domain>` in hand 10 s later, while `docker compose up`
was still pulling 1.5 GB — so DMS found its certificate on its **first** start
and came up healthy with **0 restarts**. The original project's stack, which hangs the
router on a container, cannot do that and records the 30–90 s crashloop as
normal. It is still normal here; it is just no longer necessary.

The ordering that buys this is asserted in `lib/server_init.sh` and pinned in
`tests/integration/server_init_mail_test.sh`, which compares the moment
`_mail.yml` landed on the server against Traefik's own `StartedAt` — the
fragment's *ctime*, because `rsync -pt` preserves the mtime it was rendered
with on the workstation and that is earlier than the Traefik start whichever
order the two steps run in.

Init reports DMS's state and **does not wait for it**, deliberately. If
`mail.<domain>` does not resolve to the host from the public internet the
challenge never validates, the certificate is never issued, and the crashloop
is permanent — a test rig with no public DNS is exactly that case, and a wait
there would turn "mail is not reachable yet" into "init failed".

Check afterwards:

```
ssh you@vps 'docker inspect -f "{{.State.Health.Status}}" mail-dms'
ssh you@vps 'docker logs --tail 40 mail-dms'
```
