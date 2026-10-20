#!/usr/bin/env bash
# Integration test: `kasbah server init --with-mail` against the live rig.
#
# What the hermetic suite cannot show: that Traefik really *loads* the fragment
# (a file that parses is not a file that registers), that SnappyMail really
# serves through it, that the seeds land before DMS's first start, and that the
# whole thing is re-runnable against a stack the containers have already taken
# ownership of.
#
# **DMS never becomes healthy here, and waiting for it would be a bug.**
# SSL_TYPE=letsencrypt makes a certificate for mail.<domain> a boot requirement;
# the rig has no public DNS, so the HTTP-01 challenge cannot validate and the
# certificate is never issued. the original project's setup guide records the same
# crashloop as a 30-90 s transient on a real host — here it is permanent. So the
# assertion is on the *reason* in DMS's log, which is what separates "the
# documented crashloop" from "a broken compose file". DMS reaching healthy is
# provable only against real infrastructure.
#
# The rig is treated as given: this suite never starts, resets or stops it.
#
# Exit status follows test.sh's contract: 0 pass, 1 an assertion failed, 2 the
# suite could not run at all (no rig).

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
. "$repo_dir/tests/integration/rig_env.sh"

apps=/apps
data=/apps/data
mail_dir="$apps/mail"
mail_data="$data/mail"
frag="$apps/traefik/dynamic/_mail.yml"
accounts="$mail_data/dms/config/postfix-accounts.cf"
dkim="$mail_data/dms/config/rspamd/override.d/dkim_signing.conf"

# `.test` is reserved by RFC 6761, so nothing here can name a real host — and
# ACME cannot issue for it, which is the rig's documented limit.
rig_domain=rig.test
dash_user=dashadmin
dash_pass='rig-dashboard-pw'
postmaster_pw='rig-postmaster-pw'
traefik_flags=(--domain="$rig_domain" --email="ops@$rig_domain"
               --traefik-auth="$dash_user:$dash_pass")

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

tmpdir="$(mktemp -d)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

# --- Preconditions ------------------------------------------------------------
if [ ! -f "$RIG_SSH_CONFIG" ]; then
    echo "error: no $RIG_SSH_CONFIG" >&2
    echo "       the integration suite needs a running rig: tests/rig/rig.sh up" >&2
    exit 2
fi
if ! rig_reachable; then
    echo "error: the rig did not answer ssh" >&2
    echo "       is the rig up? tests/rig/rig.sh up" >&2
    exit 2
fi
if ! rig_env_init "$tmpdir"; then
    echo "error: could not build the scratch HOME and ssh wrapper under $tmpdir" >&2
    exit 2
fi
if ! rig_clean; then
    echo "error: rig_clean could not put the rig into a known state" >&2
    exit 2
fi

# Both images are in the rig's cache and are pinned by the template. Pulling
# 1.5 GB inside a suite is not a test, so a missing image is an environment
# problem and says so.
dms_image=$(yq -r '.services["mail-dms"].image' "$repo_dir/templates/mail/compose.yml" 2>/dev/null)
sm_image=$(yq -r '.services["mail-snappymail"].image' "$repo_dir/templates/mail/compose.yml" 2>/dev/null)
for img in "$dms_image" "$sm_image"; do
    if ! rig_ssh "docker image inspect '$img' >/dev/null 2>&1"; then
        echo "error: the rig has no $img in its image cache" >&2
        echo "       pull it once on the rig; this suite will not spend 1.5 GB of a test run on it" >&2
        exit 2
    fi
done

init() { kasbah_cli server init "$RIG_TARGET" "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null; }
init_err() { cat "$tmpdir/err"; }

# **Exactly the surface kasbah writes, and nothing the containers do.** This is
# the second version; the first hashed every file under the data path and was a
# race — measured on a real host with a *healthy* DMS, the digest moved twice in
# three seconds with no kasbah run at all, because Rspamd rewrites `rspamd.rrd`
# and Postfix appends to `mail.log` continuously. It passed on the rig only
# because DMS crashloops here and never gets far enough to write either. An
# idempotence assertion that races two running containers proves nothing and
# fails at random.
#
# So: the whole tree above the data path, names and contents; the data path's
# *structure* only, down to the directories kasbah creates; and the two seeded
# files by name, which kasbah owns and the containers must not rewrite. Read
# with sudo, because SnappyMail chowns its own directory to uid 82 at mode 750
# and the deploy user cannot walk it — itself a fact this suite checks below.
apps_checksum() {
    rig_ssh "{ sudo find $apps -path $data -prune -o -printf '%y %m %u:%g %p\n' | sort; \
               sudo find $apps -path $data -prune -o -type f -exec sha256sum {} + | sort; \
               sudo find $mail_data -maxdepth 4 -type d -printf '%m %u:%g %p\n' | sort; \
               sudo sha256sum $accounts $dkim; } | sha256sum" 2>/dev/null
}

# Traefik's own router table, asked of Traefik rather than read off a file. A
# fragment that parses but does not load is the failure that matters, and only
# this can see it. --resolve so the TLS handshake carries the real SNI; -k
# because ACME cannot issue here.
traefik_routers() {
    rig_ssh "curl -s -m 15 -k --resolve 'traefik.$rig_domain:443:127.0.0.1' -u '$dash_user:$dash_pass' 'https://traefik.$rig_domain/api/http/routers'" 2>/dev/null
}
# One hostname, one scheme, one path, from inside the rig so no host port has to
# be free. The path defaults to `/`, which is every caller but the ACME pair.
http_code() {
    local host="$1" scheme="$2" path="${3:-/}" port=80
    [ "$scheme" = http ] || port=443
    rig_ssh "curl -s -o /dev/null -m 15 -k --resolve '$host:$port:127.0.0.1' -w '%{http_code}' '$scheme://$host$path'" 2>/dev/null
}

# --- The golden path ----------------------------------------------------------
# Every value passed explicitly, once. The re-run below leaves them all off,
# which is what proves a second init recovers them rather than asking again.
init --with-mail --no-backup "${traefik_flags[@]}" --postmaster-password="$postmaster_pw"; rc=$?
if [ "$rc" != "0" ]; then
    echo "  FAIL: server init --with-mail succeeded on a cleaned rig (exit $rc)" >&2
    sed 's/^/        | /' "$tmpdir/err" >&2
    fail=1
fi

# One session for every fact about the result. Timestamps are seconds since the
# epoch on the rig's own clock, so the ordering assertions below compare like
# with like.
probe_out=$(rig_ssh "bash -s '$apps' '$data'" 2>"$tmpdir/probe.err" <<'REMOTE'
set -uo pipefail
apps=$1
data=$2
mail_dir=$apps/mail
mail_data=$data/mail
frag=$apps/traefik/dynamic/_mail.yml
accounts=$mail_data/dms/config/postfix-accounts.cf
dkim=$mail_data/dms/config/rspamd/override.d/dkim_signing.conf

kv() { printf '%s=%s\n' "$1" "$2"; }
isfile() { if [ -f "$1" ]; then kv "$2" yes; else kv "$2" no; fi; }
isdir()  { if [ -d "$1" ]; then kv "$2" yes; else kv "$2" no; fi; }

isdir  "$mail_dir"             d_mail
isfile "$mail_dir/compose.yml" f_compose
isfile "$mail_dir/.env"        f_env
isfile "$mail_dir/kasbah.yml"  f_registry
isfile "$frag"                 f_frag
kv env_mode      "$(stat -c '%a' "$mail_dir/.env" 2>/dev/null)"
kv accounts_mode "$(stat -c '%a' "$accounts" 2>/dev/null)"

isfile "$accounts" f_accounts
isfile "$dkim"     f_dkim
kv accounts_line "$(head -1 "$accounts" 2>/dev/null)"

# The ordering that makes the seeding worth anything: both files have to exist
# before DMS's container is created, or the helper that would overwrite the DKIM
# config and the Dovecot that panics without an account have already run.
kv t_accounts "$(stat -c '%Y' "$accounts" 2>/dev/null)"
kv t_dkim     "$(stat -c '%Y' "$dkim" 2>/dev/null)"
# (no snappymail mtime: the container writes into that directory on boot)
kv t_dms_created "$(date -d "$(docker inspect -f '{{.Created}}' mail-dms 2>/dev/null)" +%s 2>/dev/null)"

# The other ordering, and the one the whole design is sold on: _mail.yml has to
# be in Traefik's watch directory *before* Traefik starts, so both certificates
# are requested at configuration load instead of a reload later.
#
# **ctime, not mtime.** The fragment is shipped with its mtime kept, which
# *preserves* the mtime it was rendered with on the workstation — and the render
# happens before the Traefik start whichever order the two steps run in, so an
# mtime comparison here is green for both orders and measures nothing. ctime is
# the inode's own change time on the server, which no copy can preserve: it is
# the moment the file landed, which is the fact under test. Nothing touches
# _mail.yml afterwards, so it stays that moment.
#
# Nanoseconds, because these two events are one sync and one ssh round trip
# apart and a whole-second clock reports them as simultaneous about as often as
# not.
frag_ns=$(stat -c '%.9Z' "$frag" 2>/dev/null)
kv t_frag_landed_ns "${frag_ns%.*}${frag_ns#*.}"
kv t_traefik_started_ns "$(date -d "$(docker inspect -f '{{.State.StartedAt}}' traefik 2>/dev/null)" +%s%N 2>/dev/null)"

# SnappyMail's own tree, which kasbah does not create: the container builds it
# and takes it over, and the domains/ directory it makes is where a per-project
# config is seeded (docs/mail.md). Read with sudo, because 750 uid 82 is
# precisely the state being reported.
isdir "$mail_data/snappymail" d_sm
if sudo test -d "$mail_data/snappymail/_data_/_default_/domains"; then kv d_sm_domains yes; else kv d_sm_domains no; fi
kv sm_owner "$(sudo stat -c '%u:%g %a' "$mail_data/snappymail" 2>/dev/null)"

kv dms_state    "$(docker inspect -f '{{.State.Status}}' mail-dms 2>/dev/null)"
kv dms_image    "$(docker inspect -f '{{.Config.Image}}' mail-dms 2>/dev/null)"
kv dms_project  "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' mail-dms 2>/dev/null)"
kv dms_nets     "$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' mail-dms 2>/dev/null)"
kv dms_mounts   "$(docker inspect -f '{{range .Mounts}}{{.Source}}:{{.Destination}}:{{if .RW}}rw{{else}}ro{{end}} {{end}}' mail-dms 2>/dev/null)"
# HostConfig.PortBindings, **not** NetworkSettings.Ports. The second is runtime
# state and is empty whenever the container is not running, and this container
# is crashlooping by design — a verdict run caught it mid-restart and reported
# an empty port list for a stack that publishes four. Measured on a deliberately
# stopped container: `NetworkSettings.Ports` empty, `HostConfig.PortBindings`
# `25/tcp`, `NetworkSettings.Networks` still listing the network. So the network
# rows above are safe as they stand and only this one had to move.
kv dms_ports    "$(docker inspect -f '{{range $p, $b := .HostConfig.PortBindings}}{{$p}} {{end}}' mail-dms 2>/dev/null)"
kv sm_health    "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' mail-snappymail 2>/dev/null)"
kv sm_image     "$(docker inspect -f '{{.Config.Image}}' mail-snappymail 2>/dev/null)"
kv sm_nets      "$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' mail-snappymail 2>/dev/null)"

# The signature that says the crashloop is the documented one. Counted rather
# than quoted: the line repeats once per restart, and one occurrence is enough.
kv dms_certmiss "$(docker logs mail-dms 2>&1 | grep -c 'Unable to find key and/or cert' || true)"
kv dms_welcome  "$(docker logs mail-dms 2>&1 | grep -c 'Welcome to docker-mailserver' || true)"
exit 0
REMOTE
); probe_rc=$?

if [ "$probe_rc" -ne 0 ] || [ -z "$probe_out" ]; then
    echo "error: could not read the mail stack back off the rig (ssh exit $probe_rc)" >&2
    sed 's/^/       | /' "$tmpdir/probe.err" >&2
    exit 2
fi

# The probe output is a protocol: checked complete before any assertion reads
# it, so a fact that went missing cannot produce a green assertion.
declare -A fact=()
while IFS= read -r line; do
    case $line in *=*) fact[${line%%=*}]=${line#*=} ;; esac
done <<<"$probe_out"
missing=()
for key in d_mail f_compose f_env f_registry f_frag env_mode accounts_mode \
           f_accounts f_dkim accounts_line t_accounts t_dkim \
           t_dms_created t_frag_landed_ns t_traefik_started_ns \
           d_sm d_sm_domains sm_owner \
           dms_state dms_image dms_project dms_nets dms_mounts dms_ports \
           sm_health sm_image sm_nets dms_certmiss dms_welcome; do
    [ -n "${fact[$key]+set}" ] || missing+=("$key")
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "error: the readback reported no ${missing[*]}" >&2
    sed 's/^/       | /' <<<"$probe_out" >&2
    exit 2
fi

# --- The three files ----------------------------------------------------------
assert '[ "${fact[d_mail]}" = "yes" ]'     "$mail_dir is a directory on the rig (got '${fact[d_mail]}')"
assert '[ "${fact[f_compose]}" = "yes" ]'  "$mail_dir/compose.yml exists (got '${fact[f_compose]}')"
assert '[ "${fact[f_env]}" = "yes" ]'      "$mail_dir/.env exists (got '${fact[f_env]}')"
assert '[ "${fact[f_registry]}" = "yes" ]' "$mail_dir/kasbah.yml exists (got '${fact[f_registry]}')"
assert '[ "${fact[f_frag]}" = "yes" ]'     "$frag exists — the fragment lives under traefik/, not under mail/ (got '${fact[f_frag]}')"
assert '[ "${fact[env_mode]}" = "600" ]' \
    ".env is mode 600 — the relay block is a credential (got '${fact[env_mode]}')"

registry_yml=$(rig_ssh "cat $mail_dir/kasbah.yml" 2>/dev/null)
assert 'yq -e . >/dev/null 2>&1 <<<"$registry_yml"' "the registry on the rig parses as YAML"
assert '[ "$(yq -r ".name" <<<"$registry_yml")" = "mail" ]' \
    "and names the stack (got '$(yq -r ".name" <<<"$registry_yml")')"
assert '[ "$(yq -r ".primary_domain" <<<"$registry_yml")" = "$rig_domain" ]' \
    "with the primary domain init was given (got '$(yq -r ".primary_domain" <<<"$registry_yml")')"
assert '[ "$(yq -r ".domains | join(\",\")" <<<"$registry_yml")" = "$rig_domain" ]' \
    "and it in the domains list (got '$(yq -r ".domains | join(\",\")" <<<"$registry_yml")')"

env_body=$(rig_ssh "cat $mail_dir/.env" 2>/dev/null)
assert 'grep -qxF "MAIL_HOSTNAME=mail.$rig_domain" <<<"$env_body"' \
    ".env's hostname is derived from the registry (got '$(grep MAIL_HOSTNAME <<<"$env_body")')"
assert 'grep -qxF "DOMAIN=$rig_domain" <<<"$env_body"'   "and so is DOMAIN"
assert 'grep -qxF "DATA_PATH=$data" <<<"$env_body"'      "and DATA_PATH is the path init was run with"
assert 'grep -qxF "DEFAULT_RELAY_HOST=" <<<"$env_body"'  "with an empty relay block for the operator"
assert '! grep -qF "$postmaster_pw" <<<"$env_body"' \
    "and the postmaster password is nowhere in it"

# --- The seeds, and that they landed before DMS could run ---------------------
assert '[ "${fact[f_accounts]}" = "yes" ]' "postfix-accounts.cf exists (got '${fact[f_accounts]}')"
assert '[ "${fact[accounts_mode]}" = "600" ]' \
    "at mode 600 — it is a password database (got '${fact[accounts_mode]}')"
assert '[ "${fact[accounts_line]%%|*}" = "postmaster@$rig_domain" ]' \
    "holding the postmaster account Dovecot refuses to start without (got '${fact[accounts_line]}')"
assert '[[ "${fact[accounts_line]}" =~ \|\{SHA512-CRYPT\}\$6\$ ]]' \
    "hashed the way DMS's own provisioner writes it (got '${fact[accounts_line]}')"
assert '! grep -qF "$postmaster_pw" <<<"${fact[accounts_line]}"' \
    "and the password itself never reached the server"
assert '[ "${fact[f_dkim]}" = "yes" ]' \
    "the Rspamd DKIM override is in override.d (got '${fact[f_dkim]}')"

# The ordering is the whole point of pre-seeding, and it is checkable: both
# files must predate the DMS container, or Dovecot has already panicked and the
# dkim helper has already written its own default.
assert '[ "${fact[t_accounts]}" -lt "${fact[t_dms_created]}" ]' \
    "postfix-accounts.cf was written before the DMS container was created (${fact[t_accounts]} < ${fact[t_dms_created]})"
assert '[ "${fact[t_dkim]}" -lt "${fact[t_dms_created]}" ]' \
    "and so was dkim_signing.conf (${fact[t_dkim]} < ${fact[t_dms_created]})"
# Both mtimes survive DMS: it reads these two files and rewrites neither, across
# every restart of the crashloop (observed at 8). No such assertion is made
# about snappymail/, because SnappyMail *does* write into it on boot and its
# mtime is the container's, not kasbah's — that directory's evidence is its
# owner, below.

# --- The fragment was in the watch directory before Traefik started -----------
# server init syncs the mail fragment *above* the Traefik start on
# purpose, and docs/cli.md, docs/server-setup.md and docs/mail.md all sell that
# ordering: a Traefik that boots with _mail.yml already in dynamic/ asks for
# mail.<domain> and webmail.<domain> at configuration load, so the certificate
# DMS cannot boot without is already being fetched — no watcher event, no
# reload, and on a real host 0 restarts of the proxy. Nothing else in either
# suite can see the order, because both orders produce the same files.
assert '[ "${fact[t_frag_landed_ns]}" -lt "${fact[t_traefik_started_ns]}" ]' \
    "_mail.yml was in $apps/traefik/dynamic before Traefik started, so both certificates are requested at configuration load (landed ${fact[t_frag_landed_ns]}, started ${fact[t_traefik_started_ns]})"

# The SnappyMail side of the pre-seeding mechanism: kasbah makes the bind-mount
# source and the container makes the rest, including the directory a per-project
# domain config is copied into. Both halves matter — kasbah must not pre-create
# that tree (it broke the re-run) and it must exist afterwards.
assert '[ "${fact[d_sm]}" = "yes" ]'         "$mail_data/snappymail exists (got '${fact[d_sm]}')"
assert '[ "${fact[d_sm_domains]}" = "yes" ]' \
    "and SnappyMail built _data_/_default_/domains/ inside it (got '${fact[d_sm_domains]}')"
assert '[ "${fact[sm_owner]%% *}" != "0:0" ]' \
    "the directory is not root:root, so Docker did not materialise it (got '${fact[sm_owner]}')"

# --- Traefik registered both routers ------------------------------------------
# The assertion the file cannot make. A fragment that parses and does not load
# is exactly the failure worth catching, and only Traefik's own table sees it.
routers=$(traefik_routers)
assert 'jq -e . >/dev/null 2>&1 <<<"$routers"' \
    "Traefik's router table came back as JSON (got '$(head -c 200 <<<"$routers")')"
if jq -e . >/dev/null 2>&1 <<<"$routers"; then
    names=$(jq -r '[.[].name] | sort | join(",")' <<<"$routers")
    # The control: the dashboard router is in the same table, so an empty or
    # truncated answer cannot satisfy the four assertions below by accident.
    assert 'grep -qF "traefik-dashboard@file" <<<"$names"' \
        "the dashboard router is there too — else this table proves nothing (got '$names')"
    for r in mail-cert webmail mail-cert-http webmail-http; do
        assert 'grep -qF "$r@file" <<<"$names"' \
            "Traefik registered $r from _mail.yml (routers: $names)"
        st=$(jq -r --arg n "$r@file" '.[] | select(.name == $n) | .status' <<<"$routers")
        assert '[ "$st" = "enabled" ]' "and enabled it rather than rejecting it (status '$st')"
    done
    rule=$(jq -r '.[] | select(.name == "mail-cert@file") | .rule' <<<"$routers")
    assert '[ "$rule" = "Host(\`mail.$rig_domain\`)" ]' \
        "the cert-trigger claims mail.$rig_domain (got '$rule')"
    tls=$(jq -r '.[] | select(.name == "mail-cert@file") | .tls.certResolver // ""' <<<"$routers")
    assert '[ "$tls" = "letsencrypt" ]' \
        "on the frozen resolver — that claim is the whole reason it exists (got '$tls')"
    svc=$(jq -r '.[] | select(.name == "webmail@file") | .service' <<<"$routers")
    assert '[ "$svc" = "webmail" ]' "webmail routes to its own service (got '$svc')"

    # The judgement the `web` routers rest on, measured rather than assumed:
    # Traefik answers the ACME HTTP-01 challenge from an internal router on the
    # web entrypoint, with no fragment involved. So mail-cert-http buys the
    # redirect and nothing else — it is not what makes the certificate happen.
    acme_ep=$(jq -r '.[] | select(.name == "acme-http@internal") | .entryPoints | join(",")' <<<"$routers")
    assert '[ "$acme_ep" = "web" ]' \
        "Traefik answers the HTTP-01 challenge itself on :80 (acme-http@internal on '$acme_ep')"
    # Which paths it claims, and at what priority. The entrypoint alone does not
    # say the fragment cannot shadow it — the rule and the priority do, and the
    # priority is what makes it unshadowable rather than merely lucky: Traefik
    # gives this router MaxInt, and a file-provider rule's default priority is
    # its own length. mail-cert-http's is two digits.
    acme_rule=$(jq -r '.[] | select(.name == "acme-http@internal") | .rule' <<<"$routers")
    assert '[ "$acme_rule" = "PathPrefix(\`/.well-known/acme-challenge/\`)" ]' \
        "on the challenge path and nothing else (got '$acme_rule')"
    acme_prio=$(jq -r '.[] | select(.name == "acme-http@internal") | .priority' <<<"$routers")
    mail_prio=$(jq -r '.[] | select(.name == "mail-cert-http@file") | .priority // 0' <<<"$routers")
    # awk, not `[ -gt ]`. jq 1.7 prints the literal 9223372036854775807, which is
    # exactly INT64_MAX and which bash compares happily — but jq <= 1.6 renders it
    # through a double as 9.223372036854776e+18, and bash refuses a float literal
    # outright ("integer expression expected"). awk reads both.
    assert 'awk -v a="$acme_prio" -v b="$mail_prio" "BEGIN{exit !(a+0 > b+0)}"' \
        "and above anything _mail.yml can claim (acme-http $acme_prio, mail-cert-http $mail_prio)"
fi

# --- And the routers actually answer ------------------------------------------
sm_code=$(http_code "webmail.$rig_domain" https)
assert '[ "$sm_code" = "200" ]' \
    "https://webmail.$rig_domain serves SnappyMail through the fragment (got '$sm_code')"
sm_http=$(http_code "webmail.$rig_domain" http)
assert '[ "$sm_http" = "301" ]' \
    "and plain HTTP redirects rather than 404ing, which is the whole of what the web router buys (got '$sm_http')"
mail_http=$(http_code "mail.$rig_domain" http)
assert '[ "$mail_http" = "301" ]' \
    "http://mail.$rig_domain redirects too (got '$mail_http')"
# The decisive measurement behind the router table above, and the one thing that
# proves the redirect middleware does not eat the ACME challenge: the same
# hostname, on the same entrypoint, answers 404 under /.well-known/acme-challenge
# (acme-http@internal's answer for a token it is not holding) and 301 anywhere
# else. A fragment that shadowed the internal router would redirect both, the
# challenge would never validate, and mail.<domain> would have no certificate —
# which is the one thing DMS cannot boot without.
acme_probe=$(http_code "mail.$rig_domain" http "/.well-known/acme-challenge/kasbah-no-such-token")
assert '[ "$acme_probe" = "404" ]' \
    "http://mail.$rig_domain/.well-known/acme-challenge/... reaches acme-http@internal, not the redirect (got '$acme_probe')"
assert '[ "$acme_probe" != "$mail_http" ]' \
    "and is not what the same host answers at / — the challenge path is never redirected (challenge '$acme_probe', root '$mail_http')"
sm_acme=$(http_code "webmail.$rig_domain" http "/.well-known/acme-challenge/kasbah-no-such-token")
assert '[ "$sm_acme" = "404" ]' \
    "and webmail.$rig_domain's challenge path is answered by Traefik too, not proxied to SnappyMail (got '$sm_acme')"
# noop@internal answers **418**, not 404 — measured. Nothing is served and no
# backend is reached, which is all the cert-trigger needs; the number is pinned
# so a later change to a real service is noticed.
mail_https=$(http_code "mail.$rig_domain" https)
assert '[ "$mail_https" = "418" ]' \
    "https://mail.$rig_domain reaches noop@internal and serves nothing (got '$mail_https')"
assert '[ "$mail_https" != "$sm_code" ]' \
    "and is not SnappyMail — the cert-trigger has no backend at all"

# --- The containers -----------------------------------------------------------
assert '[ "${fact[sm_health]}" = "healthy" ]' \
    "mail-snappymail is healthy (got '${fact[sm_health]}')"
assert '[ "${fact[sm_image]}" = "$sm_image" ]' \
    "from the pinned image (got '${fact[sm_image]}')"
assert '[ "${fact[dms_image]}" = "$dms_image" ]' \
    "and DMS from its own (got '${fact[dms_image]}')"
assert '[ "${fact[dms_project]}" = "mail" ]' \
    "both belong to the compose project kasbah names with -p (got '${fact[dms_project]}')"
assert 'grep -qw "kasbah-net" <<<"${fact[dms_nets]}"' \
    "DMS is on the shared network (networks: ${fact[dms_nets]})"
assert 'grep -qw "kasbah-net" <<<"${fact[sm_nets]}"' \
    "and so is SnappyMail, which is how Traefik resolves http://mail-snappymail:8888 (networks: ${fact[sm_nets]})"
assert 'grep -qF "$data/traefik/letsencrypt/acme.json:/etc/letsencrypt/acme.json:ro" <<<"${fact[dms_mounts]}"' \
    "Traefik's certificate store is mounted into DMS read-only (mounts: ${fact[dms_mounts]})"
assert 'grep -qF "$mail_data/dms/config:/tmp/docker-mailserver:rw" <<<"${fact[dms_mounts]}"' \
    "and the config directory the seeds landed in (mounts: ${fact[dms_mounts]})"
for p in 25/tcp 465/tcp 587/tcp 993/tcp; do
    assert 'grep -qw "$p" <<<"${fact[dms_ports]}"' \
        "DMS publishes $p — Traefik is not in the mail data path (ports: ${fact[dms_ports]})"
done

# --- DMS fails, and fails for the documented reason ---------------------------
# Not "DMS is unhealthy", which a broken compose file would satisfy too. The
# `Welcome` line proves the entrypoint ran at all; the cert line proves it got
# as far as looking in acme.json and finding nothing, which is the deadlock this
# whole design exists to break — and on a host where the hostname resolves, the
# other side of it.
assert '[ "${fact[dms_welcome]}" -ge 1 ]' \
    "DMS started and got as far as its own banner (got '${fact[dms_welcome]}' occurrences)"
assert '[ "${fact[dms_certmiss]}" -ge 1 ]' \
    "and stopped because acme.json holds no certificate for mail.$rig_domain — the rig cannot issue one (got '${fact[dms_certmiss]}')"
assert '[ "${fact[dms_state]}" != "healthy" ]' \
    "so it never reaches healthy here, and this suite never waits for it (state '${fact[dms_state]}')"
# What init told the operator about it, which is the difference between a
# documented transient and an unexplained container.
assert 'grep -qF "mail.$rig_domain a *boot* requirement" "$tmpdir/err"' \
    "and init named the certificate trap, for the hostname this stack actually needs (said '$(init_err)')"
assert 'grep -qF "restarts until Traefik" "$tmpdir/err"' \
    "saying what ends it (said '$(init_err)')"
# The warning fires for two different states — a container inside its 60 s
# start_period, and one that cannot find its certificate — so it must not assert
# the second. A re-run that recreates the container (any .env change does) would
# otherwise be told its perfectly ordinary boot is a crashloop.
assert 'grep -qF "expected right after a start" "$tmpdir/err"' \
    "without calling an ordinary boot a crashloop (said '$(init_err)')"
assert 'grep -qF "restarts so far" "$tmpdir/err"' \
    "and reporting the restart count rather than assuming one (said '$(init_err)')"

# --- A second run changes nothing ---------------------------------------------
before=$(apps_checksum)
assert '[ -n "$before" ]' "the tree hashes to something (got '$before')"
rig_ssh "touch $mail_dir/.checksum-probe" >/dev/null 2>&1
assert '[ "$(apps_checksum)" != "$before" ]' "the digest notices a new file in the mail directory"
rig_ssh "rm -f $mail_dir/.checksum-probe" >/dev/null 2>&1
assert '[ "$(apps_checksum)" = "$before" ]' "and the probe was undone"

# No flags at all, and stdin closed. The primary domain has to come back out of
# kasbah.yml, and the postmaster password must not be asked for — the account is
# already there, and re-hashing would lock somebody out of it.
init --with-mail --no-backup; rc=$?
assert '[ "$rc" = "0" ]' \
    "a second --with-mail run succeeds with no flags at all (exit $rc: $(init_err))"
after=$(apps_checksum)
assert '[ "$after" = "$before" ]' \
    "re-running changes nothing under $apps or $mail_data
        before: $before
        after:  $after"
assert 'grep -qF "primary $rig_domain, reused" "$tmpdir/err"' \
    "the primary domain came back off the server (said '$(init_err)')"
assert 'grep -qF "postmaster kept" "$tmpdir/err"' \
    "and the account was kept rather than reseeded (said '$(init_err)')"
assert 'grep -qF ".env unchanged" "$tmpdir/err"' "the .env too (said '$(init_err)')"
assert 'grep -qF "dkim override kept" "$tmpdir/err"' "and the DKIM override (said '$(init_err)')"

# The hand-edited relay block, which is the reason .env is merged rather than
# re-rendered. It must survive a re-run — and it must never leave the server to
# do so, which is why kasbah writes only the three keys it owns.
rig_ssh "sed -i 's|^DEFAULT_RELAY_HOST=\$|DEFAULT_RELAY_HOST=[smtp-relay.example.net]:587|; s|^RELAY_USER=\$|RELAY_USER=relay-login|' $mail_dir/.env" >/dev/null 2>&1
edited=$(apps_checksum)
assert '[ "$edited" != "$after" ]' "the hand edit moved the digest — else the case below proves nothing"
init --with-mail --no-backup; rc=$?
assert '[ "$rc" = "0" ]' "init runs against a hand-edited relay block (exit $rc: $(init_err))"
assert '[ "$(apps_checksum)" = "$edited" ]' \
    "and leaves it exactly as the operator wrote it"
env_after=$(rig_ssh "cat $mail_dir/.env" 2>/dev/null)
assert 'grep -qxF "DEFAULT_RELAY_HOST=[smtp-relay.example.net]:587" <<<"$env_after"' \
    "the relay host is still there (got '$(grep RELAY <<<"$env_after" | tr "\n" " ")')"
assert 'grep -qxF "RELAY_USER=relay-login" <<<"$env_after"' "and the relay login"

# The other direction. A kasbah-owned value edited on the server is put back,
# because kasbah.yml is where that fact lives and two writers is how they drift.
rig_ssh "sed -i 's|^DOMAIN=.*|DOMAIN=wrong.example|' $mail_dir/.env" >/dev/null 2>&1
init --with-mail --no-backup; rc=$?
assert '[ "$rc" = "0" ]' "init runs against an edited kasbah-owned value (exit $rc: $(init_err))"
assert 'grep -qF ".env rewritten" "$tmpdir/err"' "and rewrites it (said '$(init_err)')"
env_after=$(rig_ssh "cat $mail_dir/.env" 2>/dev/null)
assert 'grep -qxF "DOMAIN=$rig_domain" <<<"$env_after"' \
    "back to what the registry says (got '$(grep "^DOMAIN=" <<<"$env_after")')"
assert 'grep -qxF "RELAY_USER=relay-login" <<<"$env_after"' \
    "with the operator's half untouched by the same pass"

# The registry is the source of truth and a hand edit to it survives — that is
# what "read back off the server" means, and what makes moving the MX hostname
# a deliberate act rather than a side effect of a re-run.
rig_ssh "sed -i 's|^primary_domain: .*|primary_domain: mx.$rig_domain|' $mail_dir/kasbah.yml" >/dev/null 2>&1
init --with-mail --no-backup; rc=$?
assert '[ "$rc" = "0" ]' "init runs against an edited registry (exit $rc: $(init_err))"
assert 'grep -qF "primary mx.$rig_domain, reused" "$tmpdir/err"' \
    "honouring the edit rather than putting --domain's apex back (said '$(init_err)')"
frag_body=$(rig_ssh "cat $frag" 2>/dev/null)
assert '[ "$(yq -r ".http.routers[\"mail-cert\"].rule" <<<"$frag_body")" = "Host(\`mail.mx.$rig_domain\`)" ]' \
    "and the fragment followed it (got '$(yq -r ".http.routers[\"mail-cert\"].rule" <<<"$frag_body")')"
env_after=$(rig_ssh "cat $mail_dir/.env" 2>/dev/null)
assert 'grep -qxF "MAIL_HOSTNAME=mail.mx.$rig_domain" <<<"$env_after"' \
    "and so did the .env — one writer per fact (got '$(grep MAIL_HOSTNAME <<<"$env_after")')"
routers=$(traefik_routers)
assert '[ "$(jq -r ".[] | select(.name == \"mail-cert@file\") | .rule" <<<"$routers")" = "Host(\`mail.mx.$rig_domain\`)" ]' \
    "and Traefik reloaded the fragment live (got '$(jq -r ".[] | select(.name == \"mail-cert@file\") | .rule" <<<"$routers")')"
# Put it back, so the cleanup below and any reader of a failed run see the
# ordinary shape.
rig_ssh "sed -i 's|^primary_domain: .*|primary_domain: $rig_domain|' $mail_dir/kasbah.yml" >/dev/null 2>&1
init --with-mail --no-backup >/dev/null 2>&1

# --- --no-mail does not take an existing stack away ---------------------------
# Adding mail is a re-run of init; removing it is not something init does, and a
# flag that silently downed a mail server would be the worst possible reading of
# "no".
init --no-mail --no-backup; rc=$?
assert '[ "$rc" = "0" ]' "a --no-mail re-run against a server with mail succeeds (exit $rc: $(init_err))"
assert '[ "$(rig_ssh "docker inspect -f '{{.State.Status}}' mail-snappymail" 2>/dev/null | tr -d "\r")" = "running" ]' \
    "and leaves the mail stack running — init scaffolds mail, it never removes it"
assert '[ "$(rig_ssh "[ -f $frag ] && echo yes || echo no" 2>/dev/null | tr -d "\r")" = "yes" ]' \
    "with its Traefik fragment still in place"
assert '! grep -qF "mail:" "$tmpdir/err"' \
    "and says nothing about mail, because it did nothing to it (said '$(init_err)')"

# --- add-mail-domain and mail-setup-guide, against the running stack ----------
# 7.1b's two commands, driven where the registry they read is a real file on a
# real server and the alias they append is one docker-mailserver is watching.
# The stack is up from the runs above, and --no-mail left it that way.
add_domain() { kasbah_cli server add-mail-domain "$RIG_TARGET" "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null; }
guide() { kasbah_cli server mail-setup-guide "$RIG_TARGET" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null; }
extra_domain="shop.$rig_domain"
aliases="$mail_data/dms/config/postfix-virtual.cf"

# Read off the server rather than written down here: the cases above moved the
# primary and moved it back, and `server init` prepends a primary without ever
# removing the old one — so what is in domains: at this point is a fact about
# this run, and the assertion is that the new domain is *appended* to it.
domains_before=$(yq -r '.domains | join(" ")' <<<"$(rig_ssh "cat $mail_dir/kasbah.yml" 2>/dev/null)")
add_domain "$extra_domain"; rc=$?
assert '[ "$rc" = "0" ]' "add-mail-domain adds a domain (exit $rc: $(init_err))"
registry_after=$(rig_ssh "cat $mail_dir/kasbah.yml" 2>/dev/null)
domains_after=$(yq -r '.domains | join(" ")' <<<"$registry_after")
assert '[ "$domains_after" = "$domains_before $extra_domain" ]' \
    "and the registry on the server gains it and keeps everything it had (was '$domains_before', is '$domains_after')"
assert '[ "$(yq -r ".primary_domain" <<<"$registry_after")" = "$rig_domain" ]' \
    "with the primary untouched — the MX target and both certificates hang off it"
aliases_after=$(rig_ssh "cat $aliases" 2>/dev/null | tr -d '\r')
assert 'grep -qxF "postmaster@$extra_domain postmaster@$rig_domain" <<<"$aliases_after"' \
    "and postfix-virtual.cf carries the alias that makes Postfix accept the domain (got '$aliases_after')"
# The fragment is the primary's and nobody else's: an app domain needs an MX
# record, not a router (docs/mail.md → Multi-domain).
frag_after=$(rig_ssh "cat $frag" 2>/dev/null)
assert '! grep -qF "$extra_domain" <<<"$frag_after"' \
    "and the Traefik fragment is untouched (got '$frag_after')"

# Twice. A no-op that says so, and the file is byte-identical afterwards —
# "nothing to do" has to mean nothing was done.
digest_before=$(rig_ssh "cat $mail_dir/kasbah.yml $aliases | md5sum" 2>/dev/null | tr -d '\r')
add_domain "$extra_domain"; rc=$?
digest_after=$(rig_ssh "cat $mail_dir/kasbah.yml $aliases | md5sum" 2>/dev/null | tr -d '\r')
assert '[ "$rc" = "0" ]' "adding the same domain again is not an error (exit $rc: $(init_err))"
assert 'grep -qF "already served" "$tmpdir/err"' "and says so (said '$(init_err)')"
assert '[ "$digest_before" = "$digest_after" ]' \
    "with neither file touched ($digest_before vs $digest_after)"

# And a re-run of init reproduces the registry add-mail-domain wrote, byte for
# byte: two writers of one file that disagreed would lose the added domain on
# the next init.
init --with-mail --no-backup; rc=$?
registry_reinit=$(rig_ssh "cat $mail_dir/kasbah.yml" 2>/dev/null)
assert '[ "$rc" = "0" ]' "init re-runs against the extended registry (exit $rc: $(init_err))"
assert '[ "$registry_reinit" = "$registry_after" ]' \
    "and reproduces it unchanged — one template, one shape"

guide; rc=$?
guide_out=$(cat "$tmpdir/out")
assert '[ "$rc" = "0" ]' "mail-setup-guide prints (exit $rc: $(init_err))"
assert 'grep -qF "Domains served: $domains_after" <<<"$guide_out"' \
    "rendered for this server's registry, every domain in it (said '$(head -8 <<<"$guide_out")')"
assert 'grep -qF "$extra_domain.                    IN MX    10 mail.$rig_domain." <<<"$guide_out"' \
    "with an MX for the added domain pointing at the primary's hostname"
assert 'grep -qF "Reverse DNS (PTR)" <<<"$guide_out"' "and the PTR prerequisite"
assert 'grep -qF "Port 25 **outbound**" <<<"$guide_out"' "and the port 25 one"
# Read-only: the whole mail directory is unchanged across the run.
digest_before=$(rig_ssh "find $mail_dir -type f | sort | xargs md5sum | md5sum" 2>/dev/null | tr -d '\r')
guide >/dev/null 2>&1
digest_after=$(rig_ssh "find $mail_dir -type f | sort | xargs md5sum | md5sum" 2>/dev/null | tr -d '\r')
assert '[ "$digest_before" = "$digest_after" ]' \
    "and changed nothing on the server ($digest_before vs $digest_after)"

if [ "$fail" -eq 0 ]; then
    rig_clean >/dev/null 2>&1 || true
fi
exit "$fail"
