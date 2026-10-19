# kasbah — the mail setup guide the Bash `server init` prints
# Sourced by lib/server_init.sh. Do not execute directly.

[ -n "${_KASBAH_SERVER_MAIL_LOADED:-}" ] && return 0
_KASBAH_SERVER_MAIL_LOADED=1

. "$KASBAH_LIB_DIR/common.sh"

# The setup guide the Bash `server init` prints (a run that wants backups).

_SM_TARGET=""
_SM_APPS_PATH=""
_SM_DATA_PATH=""

_SM_PRIMARY=""
_SM_DOMAINS=()
# The address this ssh session reached the server on. Best effort: it is what
# the server sees as the local end of the connection, which is the public IP for
# a VPS reached over the internet and something else entirely behind NAT — so
# every place it is printed says where it came from.
_SM_HOST_ADDR=""

# The zone records, rendered for the registry rather than shown as an example.
# The primary carries the stack's own names — the two A records, the hostname's
# SPF, TLS reporting and service discovery — and every domain, primary included,
# carries the four that make mail for it deliverable.
#
# Apex A records are deliberately absent: those belong to whatever serves the
# site, and this guide is not the place a mail command tells an operator where
# to point their website.
_sm_guide_dns() {
    local ip="${_SM_HOST_ADDR:-<VPS IP>}" d

    printf '; ---------- %s: the stack'\''s own names ----------\n' "$_SM_PRIMARY"
    printf 'mail.%s.               IN A     %s\n' "$_SM_PRIMARY" "$ip"
    printf 'webmail.%s.            IN A     %s\n' "$_SM_PRIMARY" "$ip"
    printf 'mail.%s.               IN TXT   "v=spf1 a -all"\n' "$_SM_PRIMARY"
    printf '_smtp._tls.%s.         IN TXT   "v=TLSRPTv1; rua=mailto:postmaster@%s"\n' "$_SM_PRIMARY" "$_SM_PRIMARY"
    printf '_imaps._tcp.%s.        IN SRV   0 1 993 mail.%s.\n' "$_SM_PRIMARY" "$_SM_PRIMARY"
    printf '_submissions._tcp.%s.  IN SRV   0 1 465 mail.%s.\n' "$_SM_PRIMARY" "$_SM_PRIMARY"
    printf '_submission._tcp.%s.   IN SRV   0 1 587 mail.%s.\n' "$_SM_PRIMARY" "$_SM_PRIMARY"

    for d in "${_SM_DOMAINS[@]}"; do
        printf '\n; ---------- %s ----------\n' "$d"
        printf '%s.                    IN MX    10 mail.%s.\n' "$d" "$_SM_PRIMARY"
        printf '%s.                    IN TXT   "v=spf1 mx ip4:%s ~all"\n' "$d" "$ip"
        printf '_dmarc.%s.             IN TXT   "v=DMARC1; p=none; rua=mailto:postmaster@%s; fo=1"\n' "$d" "$_SM_PRIMARY"
        printf 'mail._domainkey.%s.    IN TXT   "<rsa-2048-mail-%s.public.dns.txt>"\n' "$d" "$d"
        printf 'ed._domainkey.%s.      IN TXT   "<ed25519-ed-%s.public.dns.txt>"\n' "$d" "$d"
    done
    return 0
}

# Printed on stdout, all of it: this is the command's output, not its
# diagnostics, and `kasbah server mail-setup-guide you@vps > mail-setup.txt` has
# to capture the whole thing.
_sm_guide_print() {
    local d ip="${_SM_HOST_ADDR:-<VPS IP>}" addr_note=""

    [ -z "$_SM_HOST_ADDR" ] \
        || addr_note=" (the address this ssh session reached — substitute the public one if the server is behind NAT)"

    cat <<EOF
Mail setup — $_SM_TARGET
========================

Primary domain: $_SM_PRIMARY
Domains served: ${_SM_DOMAINS[*]}
VPS address:    $ip$addr_note
Stack:          $_SM_APPS_PATH/mail   data: $_SM_DATA_PATH/mail

Everything below runs on the VPS. docker-mailserver has no admin web UI; its
CLI is \`docker exec mail-dms setup …\`, and \`setup help\` lists all of it.

0. Prerequisites — kasbah cannot check either of these, and both are fatal
---------------------------------------------------------------------------
[ ] Reverse DNS (PTR) on the VPS IP is set to mail.$_SM_PRIMARY. It is set in
    the VPS provider's control panel, not in your zone, and receivers reject
    or spam-file mail from a host whose PTR does not match its HELO name.
[ ] Port 25 **outbound** is not blocked by the provider. Many block it by
    default (OVH, Hetzner, AWS, GCP) and will unblock on request. If they will
    not, use an outbound relay — step 6.
[ ] mail.$_SM_PRIMARY and webmail.$_SM_PRIMARY resolve to the VPS from the
    public internet. Traefik asks Let's Encrypt for both the moment it loads
    the fragment, and DMS will not boot without the first one's certificate.

1. Check the stack
---------------------------------------------------------------------------
    ssh $_SM_TARGET 'docker inspect -f "{{.State.Health.Status}}" mail-dms'
    ssh $_SM_TARGET 'docker logs --tail 40 mail-dms'

On a first run DMS may crashloop for 30-90 s with

    Unable to find key and/or cert for '$_SM_PRIMARY' in '/etc/letsencrypt/acme.json'

while Traefik finishes the HTTP-01 exchange. That is expected. If it never
settles, mail.$_SM_PRIMARY does not resolve to this host from the outside.

    https://webmail.$_SM_PRIMARY — webmail, and it should answer 200
    https://mail.$_SM_PRIMARY — answers 418 by design. Nothing is served there;
    the name exists so that Traefik asks for its certificate.

2. Generate DKIM keys — dual signing, Ed25519 primary with RSA fallback
---------------------------------------------------------------------------
Per domain. kasbah does not generate keys and never will: they are the one
thing here that cannot be regenerated without breaking every receiver holding
the old one.

EOF
    for d in "${_SM_DOMAINS[@]}"; do
        printf "    ssh %s 'docker exec mail-dms setup config dkim keytype rsa     selector mail domain %s'\n" "$_SM_TARGET" "$d"
        printf "    ssh %s 'docker exec mail-dms setup config dkim keytype ed25519 selector ed   domain %s'\n" "$_SM_TARGET" "$d"
    done
    cat <<EOF

The keys land in $_SM_DATA_PATH/mail/dms/config/rspamd/dkim/. The flat,
one-line public forms are the ones to paste into DNS:

    ssh $_SM_TARGET 'cat $_SM_DATA_PATH/mail/dms/config/rspamd/dkim/*.public.dns.txt'

kasbah seeded the signing override for $_SM_PRIMARY before DMS first started —
which is what stops DMS's helper writing its own single-selector default over
it — and never rewrites it. **A domain added later needs its own block added by
hand** to

    $_SM_DATA_PATH/mail/dms/config/rspamd/override.d/dkim_signing.conf

Rspamd reloads on its own; no restart.

3. Publish DNS, for this server's registry
---------------------------------------------------------------------------
EOF
    printf '\n'
    _sm_guide_dns
    cat <<EOF

The two DKIM lines are placeholders — paste the matching .public.dns.txt
contents from step 2. Apex A records are not listed: those belong to whatever
serves each site.

Start DMARC at p=none, read the rua reports for a few days, then tighten to
p=quarantine and only later to p=reject. Tighten SPF's ~all to -all once every
sender is listed.

    dig +short MX $_SM_PRIMARY
    dig +short TXT mail._domainkey.$_SM_PRIMARY
    dig +short TXT _dmarc.$_SM_PRIMARY

4. Mailboxes
---------------------------------------------------------------------------
postmaster@$_SM_PRIMARY already exists — \`server init --with-mail\` seeded it,
because Dovecot panics within 120 s if the account file is empty. Every other
address is created out of band, deliberately: deploys do not touch user data
(docs/mail.md → Account management).

    ssh -t $_SM_TARGET 'docker exec -it mail-dms setup email add noreply@$_SM_PRIMARY'
    ssh -t $_SM_TARGET 'docker exec -it mail-dms setup email update postmaster@$_SM_PRIMARY'
    ssh    $_SM_TARGET 'docker exec mail-dms setup email list'
    ssh    $_SM_TARGET 'docker exec mail-dms setup alias add hello@$_SM_PRIMARY noreply@$_SM_PRIMARY'

Each additional domain already has postmaster@<domain> aliased to
postmaster@$_SM_PRIMARY — that is what \`kasbah server add-mail-domain\` writes,
and what makes Postfix accept mail for the domain at all.

5. Webmail
---------------------------------------------------------------------------
    ssh $_SM_TARGET 'docker exec mail-snappymail cat /var/lib/snappymail/_data_/_default_/admin_password.txt'

Then https://webmail.$_SM_PRIMARY/?admin as \`admin\`, and change that password
immediately. Users log in at https://webmail.$_SM_PRIMARY with their full
address.

A domain's IMAP/SMTP config can be pre-seeded from a project's manifest:

    mail:
      domain: <domain>
      snappymail_domain: ./mail/snappymail-domain.json

\`kasbah deploy\` copies that file in **if it is not already there**, and never
over one SnappyMail has since edited. Its host must be mail.$_SM_PRIMARY — the
certificate is issued for that name and SnappyMail verifies it.

6. Outbound relay, if the IP is blocked or has poor reputation
---------------------------------------------------------------------------
Fill these three in $_SM_APPS_PATH/mail/.env — they are the operator's half of
that file, and kasbah copies them through untouched on every re-run:

    DEFAULT_RELAY_HOST=[smtp-relay.brevo.com]:587
    RELAY_USER=<smtp-login>
    RELAY_PASSWORD=<smtp-key>

    ssh $_SM_TARGET 'cd $_SM_APPS_PATH/mail && docker compose -p mail up -d'

7. Prove it end to end
---------------------------------------------------------------------------
[ ] Send from an outside account to postmaster@$_SM_PRIMARY, read it in webmail.
[ ] Reply, and confirm it arrives and is not in spam.
[ ] https://www.mail-tester.com/ — aim for 10/10, from each domain that sends.
[ ] https://mxtoolbox.com/SuperTool.aspx on each domain: MX, SPF, DKIM, DMARC.
[ ] ssh $_SM_TARGET 'docker logs mail-dms 2>&1 | grep -i rspamd | tail -20'

8. Back up the DKIM keys
---------------------------------------------------------------------------
$_SM_DATA_PATH/mail/dms/config/rspamd/dkim/ is the one directory here that
cannot be rebuilt. A regenerated key is a different key, and every receiver
holding the old one fails verification until its cache expires.

    ssh $_SM_TARGET 'tar czf - -C $_SM_DATA_PATH/mail dms/config' > dms-config-\$(date +%F).tar.gz

Mailboxes live in $_SM_DATA_PATH/mail/dms/mail-data/, webmail settings in
$_SM_DATA_PATH/mail/snappymail/.
EOF
    return 0
}
