# Mail — docker-mailserver + Cypht

An optional kasbah primitive: one shared mail stack per VPS, enabled via
`kasbah server init --with-mail`. Ported from the original project's `mail/` and
generalized to serve multiple app domains.

## Components

| Service | Image | Container | Purpose |
|---|---|---|---|
| `mail-dms` | `ghcr.io/docker-mailserver/docker-mailserver:15.1.0` | `mail-dms` | Postfix + Dovecot + Rspamd + Fail2ban. One maintained image, replacing OpenDKIM, OpenDMARC, Amavis and policyd-spf with Rspamd |
| `mail-cypht` | `cypht/cypht:2.13.0` | `mail-cypht` | Webmail, served at `webmail.<domain>` through Traefik (see Webmail below) |

Both are pinned. DMS's tag is the one the original project runs in production, known to
work with Traefik's `acme.json`. The webmail is not the original project's: SnappyMail cut
no release after v2.38.2 (October 2024), while Cypht releases every few weeks
and reads several accounts in one combined inbox. Bumping either is a
deliberate edit to `templates/mail/compose.yml` and a re-run of init.

The container names are load-bearing twice over — this document's
`docker exec mail-dms …` lines, and `_mail.yml`'s
`http://mail-cypht.mail_kasbah:80`. The compose *service* names match them
rather than being the shorter `dms`/`cypht`, because compose registers a
service name as a DNS alias on every network it joins, and Traefik — which joins
the mail stack's network and every project's — would see a bare `dms` beside any
project's. The webmail backend's host is qualified with the stack's network
(`mail-cypht.mail_kasbah`), which only `mail_kasbah` answers: Docker looks a
whole dotted name up on every network first, and no project kasbah deploys may
put a dotted name on a network Traefik is on (C16, `compliance.md`).

**The mail stack has its own network, `mail_kasbah`**, which both containers
join and Traefik is attached to at the mail start (and at every Traefik start),
the same way it is attached to projects' — for webmail. No project shares a
network with DMS: apps send through `mail.<domain>:587`.

Mail ports `25`, `465`, `587` and `993` are bound on the host. Traefik is an
HTTP proxy and is not in the mail data path.

## Webmail (Cypht)

Users sign in at `https://webmail.<primary>` with a full mailbox address and
its password. Cypht checks them against DMS over IMAP at `mail.<primary>:993`
(TLS) and sends through `mail.<primary>:465`. It uses the public name, never
`mail-dms`, because DMS's certificate is issued for that name alone. Every
domain on the server signs in the same way; webmail needs no per-domain config.

- **Combined inbox.** Other accounts, on this server or anywhere else (IMAP/SMTP),
  are added under Settings → Servers. The combined views (Everything, Unread,
  Flagged…) span all of them. Their credentials sit in the user's settings,
  encrypted with the login password.
- **Settings are kept only when saved.** A change, an added account included, is
  written only by Settings → Save, with the password ("Save" or "Save and
  Logout"). "Just Logout" discards it. The setup guide says so.
- **Data:** `<data>/mail/cypht` is mounted at `/var/lib/hm3`, and the whole
  tree is `www-data`'s (uid 33). It holds `users/` (one encrypted settings file per
  address, 0644), `attachments/`, and `cypht.sqlite`. Sessions are PHP's, settings
  are files, and sign-in is IMAP, so the database holds only `brute_force`'s
  failed-login counts. The image's entrypoint exits after ten failed database
  probes and creates the file as root, so compose wraps that entrypoint: it
  creates the file and hands it and the directory to `www-data` (SQLite writes its
  journal beside the file), then `exec`s the original.
- **Modules** are listed explicitly in `CYPHT_MODULES`. `developer` is left out,
  because its server-information page shows the site config to every logged-in user.
  `XDEBUG_MODE=off`, because the image ships Xdebug at `mode=debug`.
- **Failed logins are throttled by Cypht, never by DMS.**
  - Every webmail login reaches IMAP from the `mail-cypht` container's address:
    Docker's hairpin DNAT keeps the source address, and DMS logs `rip=<mail-cypht>`.
    DMS's Fail2ban (`maxretry 6`, `findtime 1w`, `bantime 1w`) would therefore ban
    webmail for every user over a few typos. This was proved on a real server.
    kasbah ships `<data>/mail/dms/config/fail2ban-jail.cf` with
    `ignoreip = 127.0.0.1/8 mail-cypht`. Fail2ban resolves the name through
    Docker's DNS and re-resolves it every five minutes. Init rewrites the file
    when it differs. DMS copies it into place only when its container is
    created; a restart skips its setup. For an existing container the start step
    copies it, inside a running DMS when it differs, or by `docker cp` into a
    stopped one. It then runs `fail2ban-client reload` unless the live `ignoreip`
    already lists `mail-cypht`, so there's no restart. Init reports `mail_jail` as
    `atstart`, `unchanged`, `reloaded` or `failed`; a failure warns and names the
    retry. The live check covers only that line, so if a future change to the jail
    keeps `mail-cypht` and its reload fails, the next run reports `unchanged` with
    the rest never loaded. Exempting an address doesn't lift a ban it already has,
    so whenever Fail2ban answers, the start step also resolves every address of
    `mail-cypht` inside DMS (`getent ahosts`: on a dual-stack network `getent hosts`
    gives only the IPv6 one, and the ban is on the IPv4 one) and runs
    `fail2ban-client unban <ip>…`. That covers every jail, and init warns when it
    lifted a ban (`mail_cypht_unbanned`). A starting Fail2ban needs nothing: it restores no ban for an
    address in `ignoreip`. On a real server, a webmail session left polling two
    deleted mailboxes is what got `mail-cypht` banned. Direct IMAP/SMTP clients are
    still banned as before.
  - Cypht's `brute_force` does the throttling instead: 5 failed logins lock that
    client address, and that username, out of webmail for 10 minutes
    (`BRUTE_FORCE_MAX_ATTEMPTS`, `BRUTE_FORCE_LOCKOUT_DURATION`). The username lock
    applies from any address, so anyone can keep a known address out of webmail
    (not out of mail clients) for 10 minutes; this cost is accepted.
  - The client address is real because `mail-cypht` mounts a kasbah-owned
    `<apps>/mail/cypht-nginx.conf`: the image's own config plus `real_ip`,
    trusting `X-Forwarded-For` from the private ranges. Traefik sets that header,
    and `mail-cypht` publishes no port, so only Traefik and the mail stack itself,
    the containers on `mail_kasbah`, could forge it. When the shipped file differs
    from the one the container is serving, the start step recreates `mail-cypht`,
    because a renamed file does not reach a single-file bind mount.
  - Proved locally against 2.13.0: 5 failures with `X-Forwarded-For: 203.0.113.9`
    locked that address, and the same password from another address signed in.
    Scripted logins need an `Origin:` header; without one, Cypht destroys the session.
- **Health:** the healthcheck is an anonymous AJAX POST, which answers 303 with no
  body in ~5 ms. `GET /` renders the 677 KB login page. Cypht is healthy ~5 s
  after start. The login page needs no backend, so this holds while DMS is still
  waiting for its certificate.
- **Known quirk:** after an account is added, or after signing out and back in,
  the combined view can show stale rows from the browser's local cache (one
  account's message twice, or a new account's missing). Reloading after clearing
  site data fixes it. Each account's own folder is always right. Observed with
  Cypht 2.13.0.

## TLS flow

DMS needs a Let's Encrypt cert for `mail.<domain>` to start, but Traefik
only issues certs when a router requests the host. If we only had a DMS
router, it'd deadlock: DMS won't boot → router never registers → cert
never issued → DMS won't boot.

`kasbah server init --with-mail` writes a kasbah-owned fragment at
`/apps/traefik/dynamic/_mail.yml` that declares a **cert-trigger router**
claiming `Host(\`mail.<domain>\`)` on `websecure` with
`tls.certResolver: http`. The router is registered the moment
Traefik loads the fragment — independent of webmail or DMS startup.
Traefik requests the cert → DMS reads it from `acme.json` and boots.

The `_mail.yml` fragment also holds the webmail router
(`Host(\`webmail.<domain>\`)` → `http://mail-cypht.mail_kasbah:80`). Both
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
*derived from here* and rewritten by `server init --with-mail`, so there is one
writer per fact and the two cannot drift. Below them sits the operator's
relay block, which kasbah copies through and never reads back to the
workstation.

Both values are read back off the server on every run rather than
regenerated, so a hand edit to `primary_domain` survives and is how the MX
hostname is moved. On a first run it defaults to `--domain`'s apex.

It is read by the kasbah binary — on the server (`kasbah remote mail read`) or
on the workstation from the bytes that binary returns — and parsed by
`internal/mailreg`, the one reader every command uses: a registry with no
`primary_domain`, an entry that is not a domain, or a `domains:` that is not a
list is refused by name. The VPS needs no `yq`, `jq` or `python3`.

For each additional domain:
- DNS needs MX → `mail.<primary>` (apps don't need their own MX record).
- SPF + DKIM + DMARC must be published per domain.
- DMS's `postfix-virtual.cf` routes `postmaster@<domain>` → the primary mailbox.

Webmail needs nothing per domain: every address signs in at `webmail.<primary>`.

`kasbah server add-mail-domain USER@HOST <domain>` does the third, and the
DKIM keys of the second (DKIM signing, below): the domain joins `domains:`
here, the alias is appended to `<data>/mail/dms/config/postfix-virtual.cf`, and
the domain's keys are made and signed with. **That alias is not a courtesy.**
docker-mailserver builds `/etc/postfix/vhost` — which `main.cf` uses as
`virtual_mailbox_domains` — out of `postfix-accounts.cf` and
`postfix-virtual.cf`, taking the domain part of every account and of every alias
carrying an `@` (`helpers/postfix.sh` → `_vhost_collect_postfix_domains`). So a
domain with neither a mailbox nor an alias is one Postfix refuses mail for: the
registry entry alone buys nothing. Verified in the image and against the real
host, whose `vhost` holds exactly the one domain it serves. DMS watches both
files and reloads; no restart.

*(The file is `postfix-virtual.cf`; docker-mailserver 15.1.0 has no
`postmaster-aliases.cf`. `setup alias add` writes `postfix-virtual.cf`, space-delimited, one
`alias recipient` per line, and that is what kasbah appends to.)*

**Additional domains get no routers.** `_mail.yml`'s four routers claim
`mail.<primary>` and `webmail.<primary>`, which are the stack's own hostnames,
and an app domain needs an MX record rather than a fragment. `add-mail-domain`
does not touch the fragment.

DNS stays the operator's: `add-mail-domain` ends by pointing at
`mail-setup-guide`, which lists the records.

### DKIM signing

Every domain signs twice — RSA-2048 under selector `mail`, Ed25519 under
selector `ed` — with keys in `<data>/mail/dms/config/rspamd/dkim/`, named as
docker-mailserver's `setup config dkim` names them:
`rsa-2048-mail-<domain>.private.txt`, `.public.txt` and `.public.dns.txt`, and
`ed25519-ed-<domain>.…` likewise. `server init --with-mail` makes the primary's
and `add-mail-domain` the added domain's; a re-run of either makes only what is
still missing, and `kasbah server mail-dkim USER@HOST <domain>` does the same
for any registry domain, or rotates its keys (below).

The keys come from `rspamadm dkim_keygen` of the image the mail `compose.yml`
pins for `mail-dms`, run as `_rspamd` in named one-off containers (`docker run
--rm --network none`, the key directory mounted where DMS mounts it), so they
are what DMS's helper writes: the directory and every key file belong to the
image's `_rspamd` (the directory `chown`ed in a container, as DMS's preflight
does), a private key is `600` and its public files `644` — `.public.txt` is
rspamadm's zone-format output, `.public.dns.txt` the record DMS's own transform
makes of it. Every docker command but the image pull is bounded (two
minutes), and a container that outlives the bound is removed, so nothing lands
after the step gave up. Nothing waits on DMS: this works before its first
start, and while it crashloops for want of a certificate. The step runs under
the server lock, which `server init` holds for its whole run and
`add-mail-domain` and `server mail-dkim` exclusively for their own, so no two
of them make keys at once.

**A key file is never written over.** Each key's three files are made under temporary
names (`.kasbah-new-<name>`) inside its container and hard-linked into place,
and a link never writes over a file: a private key that appears meanwhile is
kept, the new one discarded, and the key reported `kept`. A private key whose
public files are missing — a run cut short between them — is kept, and the
missing files are derived from it in the same image (`openssl pkey` for RSA,
the public half of rspamd's Ed25519 key), the bytes rspamadm wrote; the run
reports the key `repaired`, and a private key they cannot be derived from
fails the step with that key left for the operator. One whose private file is
missing while a public file is still there is not made, and the run says so,
naming `server mail-dkim … --replace-keys`, which rotates both of the domain's
keys, all six files, the old ones kept — so the healthy key's record changes
too. A key file the deploy user cannot look for — a
key directory made `700`, say — refuses the step before any container runs,
naming the path: a key kasbah cannot see is one it could replace.

`<data>/mail/dms/config/rspamd/override.d/dkim_signing.conf` is **rendered
whole** on the same runs, from `templates/mail/rspamd-dkim-signing.conf`, the
registry and the keys present: one block per registry domain, listing each
selector whose private key exists. A domain with neither key gets no block —
Rspamd fails signing with a key path that is not there — and the run names it
as sending unsigned. kasbah is the file's one writer, and its first line,
`# kasbah-render sha256:<hex>`, is the digest of the rest: a file whose digest
still matches is kasbah's own last render, replaced without a copy. Any other
— a hand edit, or the copy an older kasbah seeded, which has no digest line and
so is saved once, on this kasbah's first run over it — is saved beside it as
`dkim_signing.conf.kasbah-prev`, over any older one, and the run names that
path; Rspamd loads only `dkim_signing.conf`.

Rspamd takes the change without a hand step, as `mail-dms`'s state allows.
Into a healthy one the run copies the override to `/etc/rspamd/override.d/`
and runs `supervisorctl restart rspamd` (both by `docker exec`), as DMS's
helper does after a key; a failure there is a warning, since DMS reads both at
its next start. One running but not healthy yet is left to its change
detector, which copies `override.d` and restarts Rspamd on any change under
`rspamd/`. One not running — not created yet, stopped, crashlooping — reads
both when it starts.

**Repair and rotation** are `kasbah server mail-dkim USER@HOST <domain>`, for
a domain in the registry (any other is refused, naming `add-mail-domain`). It
is the same step for that one domain — missing keys made, missing public files
derived, the override rendered and Rspamd reloaded — and it prints the
domain's two TXT records. A domain that already has key files is first asked
"replace <domain>'s DKIM keys? DNS must then carry the new public keys before
mail signed with them is trusted", answered by `--replace-keys` or
`--keep-keys`; without a terminal and without either flag the run fails naming
both. `--keep-keys` (or no) is the repair alone. Replacing **generates first,
then swaps**, in one container of the same image as `_rspamd`: both new keys
are made under their temporary names, and only once both are made is each of
the six files swapped in — the current one hard-linked to
`<name>.kasbah-old-<UTC stamp>` beside it (a link never writes over a file, so
a stamp already taken refuses the run before any key is made), then the new
one renamed over the name, which replaces it in one step. The override names
the fixed key paths, so it stays valid throughout and no moment is without a
key. Each key's public files go before its private file: until that is
swapped, Rspamd signs with the key DNS already carries. kasbah never deletes
an old key. The run names the files kept and prints the new records: until
DNS carries them, receivers fail mail signed with the new keys.

A generation that fails changes nothing; the new files are discarded. A swap
that fails partway leaves the files swapped before it in place, and the run —
having rendered the override and reloaded Rspamd all the same — names exactly
those files, which keys are rotated (DNS must carry their new records) and
which are not, and the way back: a `docker run` of the same image that links
each `.kasbah-old-<stamp>` file back over its name, then an Rspamd restart.
What was swapped is read from the disk once the container is gone (when a
timed-out one cannot be removed, the run says it may still be running and that
the list is the disk as kasbah last saw it) — a file
whose `.kasbah-old-<stamp>` is no longer the file itself, or one that was
absent — not from the container's output, so a run whose output is cut short,
or whose container is removed at its timeout after swapping, still names every
file swapped. A failed run also says when Rspamd signs with the rotated keys,
by how the reload went, and gives the warnings a finished one does (an
override kept aside, a domain unsigned, an Rspamd not restarted).

Publishing each domain's two TXT records — `mail._domainkey.<domain>` and
`ed._domainkey.<domain>`, the `.public.dns.txt` files' values, which
`mail-setup-guide` and `server mail-dkim` print — is DNS, and the
operator's. **Back up `<data>/mail/dms/config/rspamd/dkim/`**: a regenerated key
is a different key, and every receiver holding the old one fails verification
until its cache expires.

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

Apps send mail the way any mail client does — through the server's public
submission port, with a mailbox login, against a certificate that matches:

```
MAIL_HOST=mail.example.com   # the stack's public hostname
MAIL_PORT=587                # submission / STARTTLS
MAIL_USER=noreply@example.com
MAIL_PASSWORD=...            # set by admin via setup.sh
MAIL_ENCRYPTION=tls
```

No app shares a network with DMS, so a compromised app cannot reach the mail
server's other ports or its internals — only the authenticated submission
every client gets. The connection leaves the container for the host's public
address and comes back in through the published port; `kasbah check` warns on
a project that still names `mail-dms` (C10). That hairpin is what most VPS
networks do; one whose provider drops it needs the relay below instead.

## Per-app mail claims

A project manifest can declare:

```yaml
mail:
  domain: shop.example.com
```

What kasbah does with it:
1. On deploy, verify the mail stack is up.
2. Verify `shop.example.com` is in `/apps/mail/kasbah.yml`'s `domains` list.

Both are implemented, and **neither can stop a deploy**: every outcome here is
a warning, because an unmet claim costs mail and not the site.

Step 2 reads the registry the way every command reads it — through the kasbah
binary and `internal/mailreg` — and names
`kasbah server add-mail-domain` when the answer is no.

`kasbah check`'s **M01** (a `mail:` block names a domain) is the local half of
the same claim. **M03** — "the stack on the VPS knows this domain" — is a `--server`
rule and runs under `kasbah check --server`, which reads this file and fails a
claim it does not carry; the deploy asks that question anyway, on every deploy,
and only warns, because an unmet claim costs mail rather than the site. **M04**
warns, from any project's `check --server`, for each domain of the registry
missing either DKIM key or its block in the signing override — a key that
could not be made, or a domain served since before kasbah made keys — naming
`kasbah server mail-dkim USER@HOST <domain> --keep-keys` (the repair, which
never asks), and unsigned mail from a fresh
VPS is mail in spam.

What kasbah does NOT do:
- Create mailboxes.
- Publish DNS records, DKIM's included.

The mail stack's setup walkthrough (ported from the original project's `mail/SETUP.md`)
is printed once by the `kasbah server init --with-mail` run that *creates* the
stack, and on demand by `kasbah server mail-setup-guide user@vps`. A re-run of
init prints the one-line pointer at that command instead, along with the stack's
state and the one warning that matters — that DMS crashlooping while the first
certificate is issued is expected. Every run ends with a three-line
deliverability checklist — two DKIM TXT records per domain, a PTR record matching the mail
hostname, an SPF record — each pointing at its step of the guide; kasbah states
them and probes none.

The guide is rendered for the server's own registry rather than shown as an
example: the primary domain, every domain under `domains:`, the DNS records each
one needs, and the address the ssh session reached the host on. Its DKIM records
carry the values the server's `.public.dns.txt` files hold, read in the same
round trip as the registry (on the init run that creates the stack, as its
DKIM step reported them); the RSA one, longer than the 255 characters one TXT
string holds, is listed as quoted strings of at most 255, and the guide says a
panel with one value field takes them run together. A key not made yet is a
placeholder, with the `server mail-dkim … --keep-keys` command that makes it
(the repair, which never asks). Its DKIM step
names that command for repair and rotation, and tells the operator not to run
DMS's `setup config dkim` (which refuses a domain that has keys) nor to edit the
override by hand (the next render keeps the edit only as `-prev`). It carries two
prerequisites nothing in kasbah can check — reverse DNS (PTR) on the VPS IP set
to `mail.<primary>`, and port 25 **outbound** unblocked by the provider — and
both are fatal to deliverability when missed.

## Pre-seeding (first-deploy gotchas, preserved)

All three exist because somebody lost time to them. The first two are done by
`server init --with-mail`, **before the DMS container is created** — which is
the whole of what makes them work, and is asserted rather than assumed.

- **DKIM dual-signing** — Ed25519 primary + RSA fallback. The primary's two
  keys are made and `override.d/dkim_signing.conf` rendered (DKIM signing,
  above) before first start, so DMS boots signing, and its `setup config dkim`
  helper finds the file and never writes its own single-selector default
  over it.
- **Postmaster account** — DMS's Dovecot panics within 120s if no account
  exists in `postfix-accounts.cf`. `kasbah server init --with-mail` prompts
  for the postmaster password, hashes it locally (SHA512-crypt, in Go), and
  seeds `postmaster@<primary>|{SHA512-CRYPT}$6$…` before starting DMS — the
  exact line DMS's own file provisioner writes. Only the hash crosses the
  wire. **Written only onto a file with no account in it**: that file holds
  every mailbox on the server, so a re-run neither asks for a password nor
  rewrites the account.
- **Webmail data** — `server init` creates `<data>/mail/cypht` as the
  bind-mount source and nothing inside it: the container's entrypoint builds
  `users/`, `attachments/` and `cypht.sqlite` (see Webmail above).

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
directory doesn't exist. A project's `mail:` claim is then **reported and the
deploy continues**:

```
warning: shop claims the mail domain shop.example.com, and there is no mail
         stack at /apps/mail on you@vps
warning: enable it with: kasbah server init you@vps --with-mail — the deploy continues
```

**A warning, not a failure, and deliberately.** An unmet mail claim costs mail;
stopping the deploy costs the site as well, and a site that will not go up
because nobody has run `add-mail-domain` yet is the worse of the two failures.
The same holds for every other state the claim can be in — a half-made stack, a
registry that does not list the domain, a stopped DMS.
`docs/project-manifest.md` → `mail` says the same, and
`internal/deploy` is where it is true.

## First run, and what "not healthy" means

`SSL_TYPE: letsencrypt` makes a certificate for `mail.<domain>` a **boot
requirement** for DMS, not a nicety. On a first run the sequence is:

1. Init ships `_mail.yml` and the two pre-seeds, then starts Traefik. Traefik
   loads the fragment and asks Let's Encrypt for both hostnames straight away.
2. Init starts the mail stack. Cypht is healthy in ~5 s and init waits
   for it.
3. If the certificate is not in `acme.json` yet, **DMS crashloops**, logging
   `Unable to find key and/or cert for '<domain>' in
   '/etc/letsencrypt/acme.json'`.
4. Once it lands, DMS reads it and comes up healthy, then watches `acme.json`
   and reloads on renewal.

**Step 3 is often skipped entirely, and that is the point of the ordering.**
Because the fragment goes into Traefik's watch directory *before* the mail
containers start, issuance runs in parallel with the image pull — the DKIM
step's pull of the docker-mailserver image included, which is why that step
runs after Traefik starts. Measured on a
first run against a real OVH host: Traefik requested both certificates 5 s into
the run and had `mail.<domain>` in hand 10 s later, while `docker compose up`
was still pulling 1.5 GB — so DMS found its certificate on its **first** start
and came up healthy with **0 restarts**. The original project's stack, which hangs the
router on a container, cannot do that and records the 30–90 s crashloop as
normal. It is still normal here; it is just no longer necessary.

The ordering that buys this is in `internal/serverinit` and pinned in
`tests/integration/server_init_mail_test.sh`, which compares the moment
`_mail.yml` landed on the server against Traefik's own `StartedAt` — the
fragment's *ctime*, which is when it landed whatever its mtime says.

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
