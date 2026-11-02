package serverinit

// Usage is `server init --help`.
const Usage = `Usage: kasbah server init USER@HOST [flags]

Prepares a VPS to host projects: checks the prerequisites, creates the
directory layout, renders and starts the shared Traefik stack, and writes
the server marker, and records the apps path at /etc/kasbah/apps-path so
every project command can find this server without being told. Idempotent.

Flags:
  --apps-path=<dir>      root directory on the VPS (default /apps)
  --data-path=<dir>      bind-mount root (default <apps-path>/data)
  --domain=<apex>        the dashboard is served at traefik.<apex>, and a
                         new mail stack's primary domain defaults to it
  --email=<addr>         ACME registration address for Let's Encrypt
  --with-dashboard|--no-dashboard  publish the Traefik dashboard, or leave
                         it off (a re-run without either keeps the server's)
  --traefik-auth=user:pass   dashboard basic auth; hashed with bcrypt here
  --acme-staging         issue from Let's Encrypt's staging CA (untrusted
                         certificates, far looser rate limits)
  --reset-acme|--keep-acme   what to do with a certificate store whose CA
                         nothing on the server records
  --acme-dns=<provider>:<env file>  add or replace a DNS-01 resolver named
                         <provider> (lego's name), its credentials read from
                         the file's KEY=value lines (repeatable)
  --no-acme-dns=<provider>   remove that resolver and its credentials
  --with-mail|--no-mail      scaffold the mail stack, or skip it
  --postmaster-password=<pw> password for postmaster@<mail domain>, seeded
                         before DMS first starts; hashed here, never sent
  --with-backup|--no-backup  install the restic backup stack, or skip it
  --backup-repo-base=<url>   where snapshots go; kasbah appends <client> to it
  --backup-env=KEY=VALUE     environment restic needs to reach it (repeatable)
  --no-backup-env            state that it needs none
  --backup-password=<repo>=<pw>  the restic password for one repository
  --backup-at=HH:MM      daily slot, local time (default 02:00)
  --backup-jitter=<s>    seconds added to the slot (default: derived per server)
  --backup-keep-daily=N  retention, applied by "server backup-prune"
  --backup-keep-weekly=N
  --backup-keep-monthly=N
  --backup-timeout=<s>   bound on one restic invocation (default 900)
  --backup-user=NAME     who the nightly backup hooks run as on the server
                         (default: the ssh user)
  --backup-hook-timeout=<s>  the nightly backup hooks' deadline, every
                         project's together (default 1800)
  --yes                  confirm a switch away from a stated endpoint

Every *feature* flag is tri-state: leaving one off asks. The dashboard is
asked about on a first init only — a re-run keeps what dynamic/_shared.yml
has; --no-dashboard removes its routers and its credentials, and
--with-dashboard asks for them afresh. --acme-staging and
--yes are not — production is the default and never asks, and --yes only
answers a confirmation that a stated CA change raises. Domain, email and the
dashboard credentials are only asked for once — a re-run reuses what is
already on the server, since bcrypt salts randomly and a fresh hash would
rewrite the stack on every run.

Certificates come from the HTTP-01 resolver 'http' unless a router names a
DNS provider's resolver (certResolver: <provider>), which --acme-dns adds.
A re-run without --acme-dns keeps every DNS resolver the server has; each
needs its env file at <apps>/traefik/acme-dns/<provider>.env (mode 640,
group kasbah). --no-acme-dns is refused while any file under dynamic/ names the
provider. See docs/traefik.md -> TLS.

The ACME endpoint is production unless --acme-staging says otherwise, on
every run: a re-run without the flag against a staging server is how you
switch back. Where that would strand certificates, init archives acme.json
and re-issues, and asks first. See docs/server-setup.md for the
prerequisites table and the layout.

--with-mail scaffolds <apps>/mail (compose.yml, .env, kasbah.yml), writes the
cert-trigger and webmail routers to <apps>/traefik/dynamic/_mail.yml, seeds the
postmaster account and the DKIM signing config before DMS first starts, and
brings the stack up after Traefik. The mail domain defaults to --domain's apex;
it is read back out of <apps>/mail/kasbah.yml on a re-run, so an edit there
survives. The postmaster password is asked for once — a re-run against a server
that already has the account neither asks nor changes it. See docs/mail.md.

--with-backup scaffolds <apps>/.kasbah/backup — a compose stack that sleeps
until the daily slot and then pushes restic snapshots of every project's data,
hook-produced dumps and .env off the box, one repository per "client:" plus one
for mail. kasbah never parses the repository URL and never generates a
repository password. Before the stack is started, init writes a probe object
with the credentials in effect and tries to delete it again: a credential that
can delete its own history is refused, because that is the one property the
whole feature rests on. See docs/backup.md.
`
