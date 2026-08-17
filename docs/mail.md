# Mail — docker-mailserver + SnappyMail

An optional kasbah primitive: one shared mail stack per VPS, enabled via
`kasbah server init --with-mail`. Ported from the original project's `mail/` and
generalized to serve multiple app domains.

## Components (unchanged from the original project)

- **docker-mailserver** (ghcr.io/docker-mailserver/docker-mailserver) —
  Postfix + Dovecot + Rspamd + Fail2ban. Single maintained image; replaces
  OpenDKIM, OpenDMARC, Amavis, policyd-spf via Rspamd.
- **SnappyMail** (djmaze/snappymail) — lightweight webmail, served at
  `webmail.<domain>` via Traefik.

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
2. Verify `shop.example.com` is in `/apps/mail/.env`'s `domains` list.
3. If `snappymail_domain` is set and the target file is missing on the VPS,
   copy it into `/apps/data/mail/snappymail/_data_/_default_/domains/<domain>.json`.

What kasbah does NOT do:
- Create mailboxes.
- Generate DKIM keys (admin runs `docker exec mail-dms setup config dkim …`).
- Publish DNS records.

The mail stack's setup walkthrough (ported from the original project's `mail/SETUP.md`)
is shown once after `kasbah server init --with-mail` and also accessible
via `kasbah server mail-setup-guide user@vps`.

## Pre-seeding (first-deploy gotchas, preserved)

- **DKIM dual-signing config** — Ed25519 primary + RSA fallback.
  `rspamd-dkim-signing.conf` is copied into `override.d/` before first start
  so the `setup config dkim` helper doesn't overwrite it.
- **Postmaster account** — DMS's Dovecot panics within 120s if no account
  exists in `postfix-accounts.cf`. `kasbah server init --with-mail` prompts
  for the postmaster password, hashes it locally (`openssl passwd -6`), and
  seeds the account before starting DMS.
- **SnappyMail domain config** — pre-seeded from the file referenced in a
  project's manifest, keyed by the project's domain.

## Outbound relay (opt-in)

If VPS IP has poor reputation or ISP blocks port 25 egress, configure a
relay in `/apps/mail/.env`:

```
DEFAULT_RELAY_HOST=[smtp-relay.brevo.com]:587
RELAY_USER=...
RELAY_PASSWORD=...
```

Empty = direct delivery via port 25 (the original project's default).

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
