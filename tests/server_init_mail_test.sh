#!/usr/bin/env bash
# Test: lib/server_init.sh — the `--with-mail` half. Flag parsing, the
# SHA512-CRYPT hasher, the registry read-back, the postmaster question, the
# render and the sync decision, plus the two remote payloads that can be run
# for real off a scratch tree: the mail stack read and the .env merge.
#
# What is deliberately not here: anything that needs a container. DMS and
# SnappyMail live in tests/integration/server_init_mail_test.sh, which is also
# where "Traefik actually registers both routers" is settled — a fragment that
# parses is not a fragment that loads.

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
kasbah="$repo_dir/bin/kasbah"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

export KASBAH_LIB_DIR="$repo_dir/lib"
export KASBAH_TEMPLATE_DIR="$repo_dir/templates"
export KASBAH_VERSION="9.9.9-test"
export NO_COLOR=1

# --- Driver -------------------------------------------------------------------
# The library's own functions, called the way cmd_server_init calls them, with
# the server's answers injected rather than fetched.
driver="$tmpdir/driver.sh"
cat > "$driver" <<'DRV'
#!/usr/bin/env bash
set -euo pipefail
. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/server_init.sh"

mode="$1"; shift
case "$mode" in
    parse)
        _server_init_parse_args "$@"
        printf 'mail=%s\npostmaster=%s\n' \
            "${_SI_MAIL:-unset}" "${_SI_POSTMASTER_PASSWORD:-unset}"
        ;;
    crypt)
        h=""
        _si_sha512_crypt "$1" h
        printf '%s\n' "$h"
        ;;
    bcrypt)
        # The dashboard's hasher, here for one reason: it takes its password
        # the same way, and the process-table property below is one property.
        h=""
        _si_bcrypt admin "$1" h
        printf '%s\n' "$h"
        ;;
    values)
        # The registry and the postmaster question together, which is how they
        # are called. $1 is the kasbah.yml already on the server (empty for a
        # fresh one), $2 what postfix-accounts.cf holds, the rest are flags.
        registry="$1"; accounts="$2"; shift 2
        _server_init_parse_args deploy@vps "$@"
        _SI_TARGET=deploy@vps
        _SI_APPS_PATH=/apps
        _SI_DATA_PATH=/apps/data
        _SI_MAIL_ENABLED=yes
        _SI_DASHBOARD_DOMAIN="${SI_DASH_DOMAIN:-example.com}"
        _SI_MAIL_CURRENT=([compose.yml]="" [kasbah.yml]="$registry" [_mail.yml]="")
        _SI_FACT=([mail_accounts]="$accounts")
        _server_init_mail_values
        printf 'primary=%s\norigin=%s\ndomains=%s\n' \
            "$_SI_MAIL_PRIMARY" "$_SI_MAIL_PRIMARY_ORIGIN" "${_SI_MAIL_DOMAINS[*]}"
        printf 'account_origin=%s\naccount_line=%s\n' \
            "$_SI_MAIL_ACCOUNT_ORIGIN" "$_SI_MAIL_ACCOUNT_LINE"
        ;;
    render)
        # Rendered into $RENDER_OUT so the files themselves can be read back.
        _SI_APPS_PATH="$1"; _SI_DATA_PATH="$2"; _SI_MAIL_PRIMARY="$3"; shift 3
        _SI_MAIL_DOMAINS=("$@")
        _SI_MAIL_ENABLED=yes
        # The Traefik render is what makes the temp directory; mail borrows it.
        _SI_ACME_EMAIL=ops@example.com; _SI_DASHBOARD_DOMAIN=example.com
        _SI_AUTH_ENTRY='admin:$2y$05$STUB'
        _SI_ACME_CA="$_SI_ACME_CA_PRODUCTION"
        _server_init_traefik_render
        _server_init_mail_render
        cp -R "$_SI_TMPDIR/mail/." "$RENDER_OUT"/
        for rel in "${_SI_MAIL_FILES[@]}"; do
            printf '%s %s\n' "$(stat -c '%a' "$_SI_TMPDIR/mail/$rel")" "$rel"
        done
        rm -rf "$_SI_TMPDIR"
        ;;
    sync)
        # Which of the three ship, and where each one lands. rsync is stubbed:
        # the decision and the destination are what is under test.
        same="$1"
        _SI_APPS_PATH=/apps; _SI_DATA_PATH=/apps/data
        _SI_MAIL_ENABLED=yes
        _SI_MAIL_PRIMARY=example.com; _SI_MAIL_DOMAINS=(example.com)
        _SI_ACME_EMAIL=ops@example.com; _SI_DASHBOARD_DOMAIN=example.com
        _SI_AUTH_ENTRY='admin:$2y$05$STUB'
        _SI_ACME_CA="$_SI_ACME_CA_PRODUCTION"
        SSH_TARGET=deploy@vps
        _server_init_traefik_render
        _server_init_mail_render
        _SI_MAIL_CURRENT=()
        for rel in "${_SI_MAIL_FILES[@]}"; do
            case ",$same," in
                *",$rel,"*) c="$(cat "$_SI_TMPDIR/mail/$rel"; printf x)"; _SI_MAIL_CURRENT[$rel]="${c%x}" ;;
                *)          _SI_MAIL_CURRENT[$rel]="" ;;
            esac
        done
        ssh_rsync() { printf 'rsync->%s\n' "${*: -1}" >&2; }
        _server_init_mail_sync
        printf 'changed=%s\n' "${_SI_MAIL_CHANGED[*]-}"
        rm -rf "$_SI_TMPDIR"
        ;;
    readmail)
        # The local half of the mail read: which keys it insists on, and what it
        # does with values it does not know. The remote half is extracted from
        # its heredoc and run for real further down.
        _SI_TARGET=deploy@vps; _SI_APPS_PATH=/apps; _SI_DATA_PATH=/apps/data
        _SI_MAIL_ENABLED=yes
        _SI_FACT=()
        canned="$1"
        ssh_script() { printf '%s' "$canned"; }
        _server_init_read_mail
        printf 'accounts=%s\ndir=%s\nregistry=%s\n' \
            "${_SI_FACT[mail_accounts]}" "${_SI_FACT[mail_dir]}" \
            "${_SI_MAIL_CURRENT[kasbah.yml]}"
        ;;
    report)
        # The summary line and the one warning an operator acts on. $1 is DMS's
        # state, $2 its health, $3 its restart count — the three facts the start
        # step brings back and the only ones that decide what is said.
        _SI_MAIL_ENABLED=yes
        _SI_TARGET=deploy@vps; _SI_APPS_PATH=/apps; _SI_DATA_PATH=/apps/data
        _SI_MAIL_PRIMARY=example.com; _SI_MAIL_DOMAINS=(example.com)
        _SI_MAIL_PRIMARY_ORIGIN=domain
        _SI_MAIL_CHANGED=()
        _SI_FACT=(
            [mail_env]=created [mail_account]=seeded [mail_dkim_seed]=seeded
            [mail_snappymail_health]=healthy
            [mail_dms_state]="$1" [mail_dms_health]="$2" [mail_dms_restarts]="$3"
        )
        _server_init_report_mail
        printf 'reported=ok\n'
        ;;
    skip)
        # Every mail step must be a no-op when the feature is off. A step that
        # ran anyway would go to the server, which is what the stub proves.
        _SI_MAIL_ENABLED=no
        _SI_TARGET=deploy@vps; _SI_APPS_PATH=/apps; _SI_DATA_PATH=/apps/data
        ssh_script() { printf 'ssh_script reached\n' >&2; return 1; }
        ssh_rsync() { printf 'ssh_rsync reached\n' >&2; return 1; }
        _server_init_read_mail
        _server_init_mail_values
        _server_init_mail_render
        _server_init_mail_layout
        _server_init_mail_sync
        _server_init_mail_start
        _server_init_report_mail
        printf 'skipped=all\n'
        ;;
esac
DRV

drive() { bash "$driver" "$@" 2>"$tmpdir/err" </dev/null; }
drive_err() { cat "$tmpdir/err"; }

# --- Flag parsing -------------------------------------------------------------
out=$(drive parse deploy@vps); rc=$?
assert '[ "$rc" = "0" ]' "a bare target parses (exit $rc: $(drive_err))"
assert 'grep -qxF "postmaster=unset" <<<"$out"' \
    "an unpassed --postmaster-password stays unset — the server, then the prompt, decides (got '$out')"

out=$(drive parse --with-mail --postmaster-password=hunter2 deploy@vps); rc=$?
assert '[ "$rc" = "0" ]' "--postmaster-password parses (exit $rc: $(drive_err))"
assert 'grep -qxF "postmaster=hunter2" <<<"$out"' "and is recorded (got '$out')"

# A password may contain anything a shell can carry: only its hash is ever
# written, and SHA512-CRYPT emits nothing but [./A-Za-z0-9$].
out=$(drive parse --postmaster-password='p"a\ss:w$rd #x' deploy@vps); rc=$?
assert '[ "$rc" = "0" ]' \
    "quotes, backslashes and dollars in the password are fine — only the hash is written (exit $rc: $(drive_err))"

# CRLF, because the flag's whole point is being scriptable and a fleet script is
# a file somebody may have saved on Windows. --domain, --email and the target
# all strip a trailing \r; this one has to as well, and for a consequence none of
# them has: the carriage return would be *hashed*, and the account seeded from
# it would be one nobody can log into — on the one file init then deliberately
# refuses to rewrite.
out=$(drive parse --with-mail "--postmaster-password=$(printf 'hunter2\r')" deploy@vps); rc=$?
assert '[ "$rc" = "0" ]' "a password with a trailing CR parses (exit $rc: $(drive_err))"
assert '[ "$(grep -m1 "^postmaster=" <<<"$out")" = "postmaster=hunter2" ]' \
    "with the carriage return stripped (got '$(grep -m1 "^postmaster=" <<<"$out" | cat -v)')"

reject() {
    local desc="$1" want="$2"; shift 2
    local o r e
    o=$(drive parse "$@"); r=$?
    e=$(drive_err)
    assert '[ "$r" != "0" ]'             "$desc is rejected (exit $r, printed '$o')"
    assert 'grep -qF -- "$want" <<<"$e"' "$desc names '$want' (said '$e')"
}
reject "an empty --postmaster-password" "must not be empty" deploy@vps --postmaster-password=
# openssl passwd -6 -stdin reads one line. A value with a newline in it would be
# hashed as the part before it, and the operator would be locked out of an
# account whose password they believe they know.
reject "a newline in --postmaster-password" "only the first line would be hashed" \
    deploy@vps "--postmaster-password=$(printf 'a\nb')"

# The value is a password, so no rejection may quote it back — the same property
# --traefik-auth has, checked here because a second secret-carrying flag is a
# second place to lose it.
out=$(drive parse deploy@vps "--postmaster-password=$(printf 'hunter2\nmore')"); rc=$?
err_out=$(drive_err)
assert '[ "$rc" != "0" ]' "a multi-line postmaster password is rejected (exit $rc)"
assert '! grep -qF "hunter2" <<<"$err_out"' \
    "and the message does not print it back (said '$err_out')"
for typo in --postmaster-passwords --postmaster-pw; do
    out=$(drive parse deploy@vps "$typo=hunter2"); rc=$?
    err_out=$(drive_err)
    assert '[ "$rc" != "0" ]' "$typo is rejected (exit $rc)"
    assert 'grep -qF "unknown flag '\''$typo'\''" <<<"$err_out"' \
        "naming the flag so the typo is obvious (said '$err_out')"
    assert '! grep -qF "hunter2" <<<"$err_out"' \
        "without echoing what might be a password (said '$err_out')"
done

# The unknown-flag message is the only list of flags a mistyped one meets, so it
# has to carry the flag this task added.
out=$(drive parse deploy@vps --nope); err_out=$(drive_err)
assert 'grep -qF -- "--postmaster-password=" <<<"$err_out"' \
    "the unknown-flag message lists --postmaster-password= (said '$err_out')"

# --- The hash -----------------------------------------------------------------
# SHA512-CRYPT is not a taste: docker-mailserver's own provisioner writes
# `<address>|{SHA512-CRYPT}$6$…` and reads nothing else out of that file.
h1=$(drive crypt 'hunter2'); rc=$?
assert '[ "$rc" = "0" ]' "a password hashes (exit $rc: $(drive_err))"
assert '[[ "$h1" =~ ^\$6\$[^$]+\$[./A-Za-z0-9]+$ ]]' \
    "to a SHA512-CRYPT hash, salt and all (got '$h1')"
assert '! grep -qF "hunter2" <<<"$h1"' "and the password is not in it (got '$h1')"
h2=$(drive crypt 'hunter2')
assert '[ "$h1" != "$h2" ]' \
    "the salt is random, so two hashes of one password differ (got '$h1' and '$h2')"
# The hash a *shell* would produce for the same salt, so the assertion above is
# about crypt(3) and not about the shape of a string.
salt="${h1#\$6\$}"; salt="${salt%%\$*}"
assert '[ "$(openssl passwd -6 -salt "$salt" hunter2)" = "$h1" ]' \
    "and it is the crypt(3) SHA512 of the password under its own salt"

# --- The password never reaches a process table -------------------------------
# `openssl passwd -6 -stdin` and `htpasswd -niB` are both deliberate, and both
# comments in lib/server_init.sh say so: the positional forms (`openssl passwd
# -6 "$pass"`, `htpasswd -nbB user "$pass"`) put the cleartext in argv, where
# any other user of this workstation can read it out of /proc for as long as the
# hasher runs. A comment is not a test, so the hasher is run under a stub that
# records its own argv and the password is looked for there.
stub_dir="$tmpdir/hashstub"
mkdir -p "$stub_dir"
argv_log="$tmpdir/hasher-argv"
# Both stubs drain stdin and answer with a hash of the right *shape*, so the
# caller's own validation passes and what is left under test is the argv.
cat > "$stub_dir/openssl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HASHER_ARGV_LOG"
cat >/dev/null
printf '$6$stubsalt$stubhash\n'
STUB
cat > "$stub_dir/htpasswd" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HASHER_ARGV_LOG"
cat >/dev/null
printf 'admin:$2y$05$stubstubstubstubstubstubstubstubstubstubstu\n'
STUB
chmod +x "$stub_dir/openssl" "$stub_dir/htpasswd"

secret='pr0c3ss-t4bl3-s3cr3t'
for mode in crypt bcrypt; do
    : > "$argv_log"
    out=$(HASHER_ARGV_LOG="$argv_log" PATH="$stub_dir:$PATH" \
          bash "$driver" "$mode" "$secret" 2>"$tmpdir/err" </dev/null); rc=$?
    argv=$(cat "$argv_log")
    # The control. A stub that was never reached logs nothing, and an assertion
    # that the password is absent from an empty file is the emptiest kind of
    # green there is.
    assert '[ -n "$argv" ]' \
        "the $mode hasher really ran under the stub (exit $rc, logged '$argv': $(drive_err))"
    assert '[ "$rc" = "0" ]' "and its answer was accepted (exit $rc: $(drive_err))"
    assert '! grep -qF "$secret" <<<"$argv"' \
        "the password is nowhere in the $mode hasher's argv — it went over stdin (argv: '$argv')"
done

# --- The registry -------------------------------------------------------------
# Two values read back off the server rather than regenerated, for the reason
# the dashboard hash is: primary_domain is the MX target and the name both
# certificates are issued for, and moving it abandons them.
fresh=$(drive values "" absent --postmaster-password=pw); rc=$?
assert '[ "$rc" = "0" ]' "a fresh server settles the registry (exit $rc: $(drive_err))"
assert 'grep -qxF "primary=example.com" <<<"$fresh"' \
    "the primary domain defaults to --domain's apex (got '$fresh')"
assert 'grep -qxF "origin=domain" <<<"$fresh"' "and says where it came from (got '$fresh')"
assert 'grep -qxF "domains=example.com" <<<"$fresh"' \
    "which is also the whole of the domains list on a fresh stack (got '$fresh')"

stored=$(printf 'name: mail\nprimary_domain: mx.example.org\ndomains:\n  - mx.example.org\n  - shop.example.net\n')
out=$(drive values "$stored" absent --postmaster-password=pw); rc=$?
assert '[ "$rc" = "0" ]' "a stored registry is read back (exit $rc: $(drive_err))"
assert 'grep -qxF "primary=mx.example.org" <<<"$out"' \
    "the stored primary wins over --domain's apex (got '$out')"
assert 'grep -qxF "origin=reused" <<<"$out"' "and is reported as reused (got '$out')"
assert 'grep -qxF "domains=mx.example.org shop.example.net" <<<"$out"' \
    "every stored domain survives, in order (got '$out')"

# A stack whose registry lists domains but not the primary among them: the
# primary is served by the stack it is the MX for whether or not anyone wrote it
# down, and it goes first because every other domain's MX points at it.
missing_primary=$(printf 'name: mail\nprimary_domain: mx.example.org\ndomains:\n  - shop.example.net\n')
out=$(drive values "$missing_primary" absent --postmaster-password=pw)
assert 'grep -qxF "domains=mx.example.org shop.example.net" <<<"$out"' \
    "the primary is prepended when the list does not carry it (got '$out')"

# CRLF, because kasbah.yml is a file an operator edits.
crlf=$(printf 'name: mail\r\nprimary_domain: mx.example.org\r\ndomains:\r\n  - mx.example.org\r\n')
out=$(drive values "$crlf" absent --postmaster-password=pw)
assert 'grep -qxF "primary=mx.example.org" <<<"$out"' \
    "a registry saved with CRLF line endings reads the same (got '$out')"

# A registry kasbah cannot parse is a refusal, never a fresh guess: guessing
# would move the MX hostname and abandon two certificates.
out=$(drive values "$(printf 'primary_domain: [unclosed\n')" absent --postmaster-password=pw); rc=$?
err_out=$(drive_err)
assert '[ "$rc" != "0" ]' "an unparseable registry is a refusal (exit $rc, printed '$out')"
assert 'grep -qF "could not be read as YAML" <<<"$err_out"' "saying so (said '$err_out')"
assert 'grep -qF "abandon two certificates" <<<"$err_out"' \
    "and saying what guessing would cost (said '$err_out')"

# Values that would render a file Traefik loads, or a hostname nothing can be
# issued for, are refused where they are read.
out=$(drive values "$(printf 'primary_domain: localhost\n')" absent --postmaster-password=pw); rc=$?
assert '[ "$rc" != "0" ]' "a primary domain that is not a domain name is refused (exit $rc)"
assert 'grep -qF "MX target" "$tmpdir/err"' "naming what it is for (said '$(drive_err)')"
out=$(drive values "$(printf 'primary_domain: a.example.com\ndomains:\n  - "not a domain"\n')" absent --postmaster-password=pw); rc=$?
assert '[ "$rc" != "0" ]' "so is a domains: entry that is not a domain name (exit $rc)"
assert 'grep -qF "under domains:" "$tmpdir/err"' "naming the list it came from (said '$(drive_err)')"

# --- The postmaster question --------------------------------------------------
# Asked once. The account file holds every mailbox on the server, so a re-run
# that rotated the postmaster password would be a re-run that locked somebody
# out — the question is not asked at all when the server already has one.
out=$(drive values "" present); rc=$?
assert '[ "$rc" = "0" ]' \
    "an already-seeded server needs no password and no terminal (exit $rc: $(drive_err))"
assert 'grep -qxF "account_origin=existing" <<<"$out"' "and says so (got '$out')"
assert 'grep -qxF "account_line=" <<<"$out"' \
    "handing the layout step nothing to write (got '$out')"

# The flag on a run that is not going to seed. A warning rather than a refusal,
# for the reason a spare --reset-acme is one: a fleet script sets it once.
out=$(drive values "" present --postmaster-password=pw); rc=$?
err_out=$(drive_err)
assert '[ "$rc" = "0" ]' "--postmaster-password on a seeded server still succeeds (exit $rc: $err_out)"
assert 'grep -qF -- "--postmaster-password had no effect" <<<"$err_out"' \
    "with a warning that it did nothing (said '$err_out')"
assert 'grep -qF "setup email update" <<<"$err_out"' \
    "naming the command that does rotate it (said '$err_out')"
assert 'grep -qxF "account_line=" <<<"$out"' "and nothing is seeded (got '$out')"

# The line docker-mailserver's file provisioner actually reads: address, a pipe,
# the scheme prefix, the hash. Every part of that shape was measured against the
# pinned image rather than guessed.
out=$(drive values "" absent --postmaster-password=hunter2)
line=$(grep -m1 '^account_line=' <<<"$out"); line="${line#account_line=}"
assert '[ "${line%%|*}" = "postmaster@example.com" ]' \
    "the seeded account is postmaster at the primary domain (got '$line')"
assert '[[ "$line" =~ \|\{SHA512-CRYPT\}\$6\$ ]]' \
    "carrying the scheme prefix DMS writes, and a SHA512-CRYPT hash (got '$line')"
assert '! grep -qF "hunter2" <<<"$line"' "and not the password (got '$line')"
assert 'grep -qxF "account_origin=flag" <<<"$out"' "recorded as coming from the flag (got '$out')"

# The decisive form of the CRLF case above: not "the parsed value looks right"
# but "the hash that reaches postfix-accounts.cf is the hash of the password the
# operator meant". Without the strip this is the SHA512 of 'hunter2\r', the
# account is one nobody can log into, and every visible symptom is a correct
# password being refused.
out=$(drive values "" absent "--postmaster-password=$(printf 'hunter2\r')")
line=$(grep -m1 '^account_line=' <<<"$out"); line="${line#account_line=}"
crlf_hash="${line#*\}}"
crlf_salt="${crlf_hash#\$6\$}"; crlf_salt="${crlf_salt%%\$*}"
assert '[ "$(openssl passwd -6 -salt "$crlf_salt" hunter2)" = "$crlf_hash" ]' \
    "a password scripted out of a CRLF file hashes to the password, not to the password plus a carriage return (got '$crlf_hash')"

# The tri-state rule. No flag, no terminal, a server with no account: a hard
# failure naming the flag, never a blank or generated password.
out=$(drive values "" absent); rc=$?
err_out=$(drive_err)
assert '[ "$rc" != "0" ]' "an unanswerable postmaster question fails (exit $rc, printed '$out')"
assert 'grep -qF -- "--postmaster-password=<value>" <<<"$err_out"' \
    "naming the flag that would answer it (said '$err_out')"
# `empty` is a file that exists and holds no account — a run that died between
# creating the tree and seeding it. It is seeded like an absent one.
out=$(drive values "" empty); rc=$?
assert '[ "$rc" != "0" ]' \
    "an account file with nothing in it is asked about too (exit $rc, printed '$out')"

# --- The render ---------------------------------------------------------------
render_out="$tmpdir/render"
rm -rf "$render_out"; mkdir -p "$render_out"
modes=$(RENDER_OUT="$render_out" drive render /srv/apps /srv/apps/data mx.example.org mx.example.org shop.example.net); rc=$?
assert '[ "$rc" = "0" ]' "the mail templates render (exit $rc: $(drive_err))"
for rel in compose.yml kasbah.yml _mail.yml; do
    assert 'grep -qxF "644 $rel" <<<"$modes"' "$rel is rendered mode 644 (got '$modes')"
done
assert '[ -f "$render_out/env" ]' "the .env default is rendered too"
assert '[ -f "$render_out/dkim_signing.conf" ]' "and the Rspamd DKIM override"

# No template may leave a placeholder behind. Looked for in the *output*, which
# is the one place it is unambiguous: no substituted value here can contain one.
for f in "$render_out"/*; do
    assert '! grep -qE "__[A-Z0-9_]+__" "$f"' \
        "every placeholder in $(basename "$f") was substituted ($(grep -oE "__[A-Z0-9_]+__" "$f" | sort -u | tr "\n" " "))"
done

frag="$render_out/_mail.yml"
assert 'yq -e . "$frag" >/dev/null 2>&1' "_mail.yml parses as YAML"
assert '[ "$(yq -r ".http.routers | keys | sort | join(\",\")" "$frag")" = "mail-cert,mail-cert-http,webmail,webmail-http" ]' \
    "it carries exactly the four kasbah-owned routers (got '$(yq -r ".http.routers | keys | sort | join(\",\")" "$frag")')"
assert '[ "$(yq -r ".http.routers[\"mail-cert\"].rule" "$frag")" = "Host(\`mail.mx.example.org\`)" ]' \
    "the cert-trigger claims mail.<primary> (got '$(yq -r ".http.routers[\"mail-cert\"].rule" "$frag")')"
assert '[ "$(yq -r ".http.routers[\"mail-cert\"].tls.certResolver" "$frag")" = "letsencrypt" ]' \
    "on the frozen resolver, which is the whole reason the router exists"
assert '[ "$(yq -r ".http.routers[\"mail-cert\"].entryPoints | join(\",\")" "$frag")" = "websecure" ]' \
    "on websecure alone — a certResolver on :80 issues nothing"
# noop@internal rather than the original project's replacepathregex-to-nowhere: under the
# file provider a router needs no real service, so the middleware that existed
# only to satisfy the docker provider's "every router names a service" rule
# buys nothing. _shared.yml's dashboard redirect already uses exactly this.
assert '[ "$(yq -r ".http.routers[\"mail-cert\"].service" "$frag")" = "noop@internal" ]' \
    "and is served by noop@internal (got '$(yq -r ".http.routers[\"mail-cert\"].service" "$frag")')"
assert '[ "$(yq -r ".http.routers[\"mail-cert\"] | has(\"middlewares\")" "$frag")" = "false" ]' \
    "with no middleware at all — nothing has to force a non-answer"
assert '[ "$(yq -r ".http.routers.webmail.rule" "$frag")" = "Host(\`webmail.mx.example.org\`)" ]' \
    "webmail claims webmail.<primary> (got '$(yq -r ".http.routers.webmail.rule" "$frag")')"
assert '[ "$(yq -r ".http.services.webmail.loadBalancer.servers[0].url" "$frag")" = "http://mail-snappymail:8888" ]' \
    "and points at the container name docs/mail.md names (got '$(yq -r ".http.services.webmail.loadBalancer.servers[0].url" "$frag")')"
assert '[ "$(yq -r ".http.routers.webmail.middlewares | join(\",\")" "$frag")" = "security-headers" ]' \
    "carrying the shared security headers (got '$(yq -r ".http.routers.webmail.middlewares | join(\",\")" "$frag")')"
# Both hostnames get a :80 router, for the reason docs/traefik.md gives every
# project (T08): without it the name answers plain HTTP with Traefik's 404
# rather than a redirect. It is *not* what makes ACME work — Traefik answers the
# HTTP-01 challenge on the entrypoint itself, with no router involved.
for r in mail-cert-http webmail-http; do
    assert '[ "$(yq -r ".http.routers[\"$r\"].entryPoints | join(\",\")" "$frag")" = "web" ]' \
        "$r sits on the web entrypoint (got '$(yq -r ".http.routers[\"$r\"].entryPoints | join(\",\")" "$frag")')"
    assert '[ "$(yq -r ".http.routers[\"$r\"].middlewares | join(\",\")" "$frag")" = "http-to-https" ]' \
        "$r redirects rather than serving (got '$(yq -r ".http.routers[\"$r\"].middlewares | join(\",\")" "$frag")')"
    assert '[ "$(yq -r ".http.routers[\"$r\"].service" "$frag")" = "noop@internal" ]' \
        "$r has no backend (got '$(yq -r ".http.routers[\"$r\"].service" "$frag")')"
    assert '[ "$(yq -r ".http.routers[\"$r\"] | has(\"tls\")" "$frag")" = "false" ]' \
        "$r asks for no certificate — it is the router the certificate is redirected away from"
done
# The fragment carries routing and nothing else. A middleware defined here would
# collide by name with _shared.yml's, which is a frozen contract.
assert '[ "$(yq -r ".http | has(\"middlewares\")" "$frag")" = "false" ]' \
    "_mail.yml defines no middlewares of its own — the frozen ones are _shared.yml's"

reg="$render_out/kasbah.yml"
assert '[ "$(yq -r ".name" "$reg")" = "mail" ]' "kasbah.yml names the stack (got '$(yq -r ".name" "$reg")')"
assert '[ "$(yq -r ".primary_domain" "$reg")" = "mx.example.org" ]' "and the primary domain"
assert '[ "$(yq -r ".domains | join(\",\")" "$reg")" = "mx.example.org,shop.example.net" ]' \
    "and every domain, in order (got '$(yq -r ".domains | join(\",\")" "$reg")')"

comp="$render_out/compose.yml"
assert '[ "$(yq -r ".name" "$comp")" = "mail" ]' "compose declares the mail project"
assert '[ "$(yq -r ".services[\"mail-dms\"].container_name" "$comp")" = "mail-dms" ]' \
    "the DMS container is mail-dms — docs/mail.md's docker exec lines depend on it"
assert '[ "$(yq -r ".services[\"mail-snappymail\"].container_name" "$comp")" = "mail-snappymail" ]' \
    "and SnappyMail's is mail-snappymail — the fragment's service URL depends on it"
# The service names match the container names on purpose: compose registers a
# service name as a DNS alias on every network it joins, and a service called
# `dms` would claim the bare alias on the shared kasbah-net (C09).
assert '[ "$(yq -r ".services | keys | sort | join(\",\")" "$comp")" = "mail-dms,mail-snappymail" ]' \
    "the service names are prefixed too, so neither claims a bare alias on kasbah-net"
assert '[ "$(yq -r ".services[\"mail-dms\"].image" "$comp")" = "ghcr.io/docker-mailserver/docker-mailserver:15.1.0" ]' \
    "DMS is pinned exactly (got '$(yq -r ".services[\"mail-dms\"].image" "$comp")')"
assert '[ "$(yq -r ".services[\"mail-snappymail\"].image" "$comp")" = "djmaze/snappymail:v2.38.2" ]' \
    "so is SnappyMail (got '$(yq -r ".services[\"mail-snappymail\"].image" "$comp")')"
assert '[ "$(yq -r ".networks[\"kasbah-net\"].external" "$comp")" = "true" ]' \
    "kasbah-net is joined, never created here — Traefik owns it"
assert '[ "$(yq -r ".services[\"mail-dms\"].environment.SSL_TYPE" "$comp")" = "letsencrypt" ]' \
    "DMS reads Traefik's store natively, which is why a cert is a boot requirement"
# acme.json read-only, and the only mount of it. DMS has no business writing to
# Traefik's certificate store.
acme_mounts=$(yq -r '.services["mail-dms"].volumes[] | select(contains("acme.json"))' "$comp")
assert '[ "$acme_mounts" = "\${DATA_PATH}/traefik/letsencrypt/acme.json:/etc/letsencrypt/acme.json:ro" ]' \
    "acme.json is mounted read-only, from the data path (got '$acme_mounts')"
# No routing here at all: the docker provider is not wired in, so a label would
# be dead weight that reads like configuration.
assert '[ "$(yq -r "[.services[] | select(has(\"labels\"))] | length" "$comp")" = "0" ]' \
    "no traefik.* labels survive the port — routing is _mail.yml's"
assert '! grep -qF "version:" "$comp"' "and the compose file carries no version: key"

envf="$render_out/env"
assert 'grep -qxF "MAIL_HOSTNAME=mail.mx.example.org" "$envf"' \
    "the .env default carries the mail hostname (got '$(grep MAIL_HOSTNAME "$envf")')"
assert 'grep -qxF "DOMAIN=mx.example.org" "$envf"' "and the primary domain"
assert 'grep -qxF "DATA_PATH=/srv/apps/data" "$envf"' "and the data path init was given"
for k in DEFAULT_RELAY_HOST RELAY_USER RELAY_PASSWORD; do
    assert 'grep -qxF "$k=" "$envf"' "and an empty $k for the operator to fill"
done

dkim="$render_out/dkim_signing.conf"
assert 'grep -qF "mx.example.org {" "$dkim"' \
    "the DKIM override is keyed on the primary domain (got '$(grep -c . "$dkim") lines)"
assert 'grep -qF "ed25519-ed-mx.example.org.private.txt" "$dkim"' "with the Ed25519 selector's key path"
assert 'grep -qF "rsa-2048-mail-mx.example.org.private.txt" "$dkim"' "and the RSA one's"
assert 'grep -qxF "enabled = true;" "$dkim"' "and signing switched on"

# --- The sync decision --------------------------------------------------------
out=$(drive sync ""); rc=$?
err_out=$(drive_err)
assert '[ "$rc" = "0" ]' "a server with none of the three files ships (exit $rc: $err_out)"
assert 'grep -qxF "changed=compose.yml kasbah.yml _mail.yml" <<<"$out"' \
    "all three (got '$out')"
assert 'grep -qF "rsync->deploy@vps:/apps/mail/compose.yml" <<<"$err_out"' \
    "compose.yml into the mail directory (said '$err_out')"
assert 'grep -qF "rsync->deploy@vps:/apps/mail/kasbah.yml" <<<"$err_out"' \
    "the registry beside it (said '$err_out')"
# The one destination that is not derived from the name. _mail.yml is a
# file-provider fragment, so it has to sit where Traefik's watcher looks.
assert 'grep -qF "rsync->deploy@vps:/apps/traefik/dynamic/_mail.yml" <<<"$err_out"' \
    "and _mail.yml into Traefik's watch directory, not into mail/ (said '$err_out')"

out=$(drive sync "compose.yml,kasbah.yml,_mail.yml"); rc=$?
err_out=$(drive_err)
assert '[ "$rc" = "0" ]' "a server already holding the rendered bytes succeeds (exit $rc: $err_out)"
assert 'grep -qxF "changed=" <<<"$out"' "and ships nothing (got '$out')"
assert '[ -z "$err_out" ]' "no rsync at all (said '$err_out')"

out=$(drive sync "compose.yml,kasbah.yml"); err_out=$(drive_err)
assert 'grep -qxF "changed=_mail.yml" <<<"$out"' \
    "a fragment that drifted is the only thing shipped (got '$out')"
assert '[ "$(grep -c "rsync->" <<<"$err_out")" = "1" ]' \
    "in one rsync call (said '$err_out')"

# --- The mail read, locally ---------------------------------------------------
# A key that never arrived must not be absorbed into a passing verdict.
canned=$(printf 'mail_compose_b64=\nmail_registry_b64=\nmail_fragment_b64=\nmail_accounts=absent\nmail_dir=absent\n')
out=$(drive readmail "$canned"); rc=$?
assert '[ "$rc" = "0" ]' "a complete report is absorbed (exit $rc: $(drive_err))"
assert 'grep -qxF "accounts=absent" <<<"$out"' "with the account state (got '$out')"

out=$(drive readmail "$(printf 'mail_compose_b64=\nmail_dir=absent\n')"); rc=$?
err_out=$(drive_err)
assert '[ "$rc" != "0" ]' "a truncated report is a failure, not a default (exit $rc)"
assert 'grep -qF "mail_registry_b64" <<<"$err_out"' "naming what went missing (said '$err_out')"

# A file where the mail directory belongs stops the whole stack, and `mkdir -p`
# says "File exists" about it. Refused here, with a message about the cause.
notdir=$(printf 'mail_compose_b64=\nmail_registry_b64=\nmail_fragment_b64=\nmail_accounts=absent\nmail_dir=notdir\n')
out=$(drive readmail "$notdir"); rc=$?
err_out=$(drive_err)
assert '[ "$rc" != "0" ]' "a mail path that is not a directory is refused (exit $rc)"
assert 'grep -qF "is not a directory" <<<"$err_out"' "saying so (said '$err_out')"
assert 'grep -qF "Nothing has been changed" <<<"$err_out"' \
    "and that the run cost nothing (said '$err_out')"

unknown=$(printf 'mail_compose_b64=\nmail_registry_b64=\nmail_fragment_b64=\nmail_accounts=maybe\nmail_dir=dir\n')
out=$(drive readmail "$unknown"); rc=$?
assert '[ "$rc" != "0" ]' "an account state this kasbah does not know is a failure (exit $rc)"
assert 'grep -qF "which this kasbah does not know" "$tmpdir/err"' "saying so (said '$(drive_err)')"

# The registry comes back through base64 with its trailing newline intact — the
# byte comparison the sync step makes is worthless otherwise.
b64=$(printf 'name: mail\nprimary_domain: a.example.com\n' | openssl base64 -A)
canned=$(printf 'mail_compose_b64=\nmail_registry_b64=%s\nmail_fragment_b64=\nmail_accounts=present\nmail_dir=dir\n' "$b64")
out=$(drive readmail "$canned")
assert '[ "$(sed -n "s/^registry=//p" <<<"$out")" = "name: mail" ]' \
    "the registry decodes (got '$out')"

# --- What the operator is told about DMS --------------------------------------
# The summary is always printed; the warning is not, and what it says has to be
# true of the two different states that look identical at the moment it runs.
out=$(drive report running healthy 0); rc=$?
err_out=$(drive_err)
assert '[ "$rc" = "0" ]' "a healthy DMS reports cleanly (exit $rc: $err_out)"
assert 'grep -qF "dms running (healthy, 0 restarts)" <<<"$err_out"' \
    "with its state on the summary line (said '$err_out')"
assert '! grep -qF "boot* requirement" <<<"$err_out"' \
    "and no warning at all — nothing is wrong (said '$err_out')"

# A container inside its healthcheck's 60 s start_period. This is what an
# ordinary re-run looks like whenever the .env changed, because compose then
# recreates the service — observed on a real host, where the old wording told
# the operator their perfectly healthy stack was crashlooping.
out=$(drive report running starting 0); rc=$?
err_out=$(drive_err)
assert '[ "$rc" = "0" ]' "a starting DMS reports cleanly (exit $rc: $err_out)"
assert 'grep -qF "expected right after a start" <<<"$err_out"' \
    "the warning allows for an ordinary boot (said '$err_out')"
assert 'grep -qF "60 s start_period" <<<"$err_out"' \
    "naming the reason it is expected (said '$err_out')"
assert '! grep -qF "DMS crashloops" <<<"$err_out"' \
    "and does not assert a crashloop it cannot see (said '$err_out')"
assert 'grep -qF "0 restarts so far" <<<"$err_out"' \
    "reporting the restart count instead (said '$err_out')"
# The trap the warning exists for, and the hostname it turns on.
assert 'grep -qF "mail.example.com a *boot* requirement" <<<"$err_out"' \
    "while still naming the certificate requirement (said '$err_out')"
assert 'grep -qF "restarts until Traefik" <<<"$err_out"' "and what ends it (said '$err_out')"
assert 'grep -qF "docker logs --tail 40 mail-dms" <<<"$err_out"' \
    "and how to look (said '$err_out')"

# The real crashloop. Same warning, and the restart count is what tells an
# operator which of the two they are in.
out=$(drive report restarting starting 7); err_out=$(drive_err)
assert 'grep -qF "7 restarts so far" <<<"$err_out"' \
    "a crashlooping DMS reports its restarts (said '$err_out')"
assert 'grep -qF "dms restarting (starting, 7 restarts)" <<<"$err_out"' \
    "on the summary line too (said '$err_out')"

# --- Every step is a no-op with mail off --------------------------------------
# The stubs fail if reached, so this is about the guards and not about a summary
# line that happens to be empty.
out=$(drive skip); rc=$?
err_out=$(drive_err)
assert '[ "$rc" = "0" ]' "--no-mail runs every mail step and none of them acts (exit $rc: $err_out)"
assert 'grep -qxF "skipped=all" <<<"$out"' "reaching the end (got '$out')"
assert '! grep -qF "reached" <<<"$err_out"' \
    "without one ssh or rsync call (said '$err_out')"

# --- The remote mail read, run for real ---------------------------------------
# Extracted from its heredoc and run against a scratch tree: every case above
# stubs this block's output, so the producer needs its own coverage or the
# three-state account ladder proves nothing.
read_payload="$tmpdir/readmail.sh"
awk '/<<'"'"'REMOTE'"'"'$/{buf=""; inb=1; next} inb && /^REMOTE$/{if (buf ~ /mail_accounts=/) printf "%s", buf; inb=0; next} inb{buf = buf $0 "\n"}' \
    "$repo_dir/lib/server_init.sh" > "$read_payload"
assert '[ -s "$read_payload" ]' "the mail stack read was extracted from lib/server_init.sh"
assert 'grep -qF "mail_registry_b64" "$read_payload"' \
    "and it is the right block — every case below is empty theatre otherwise"

r_apps="$tmpdir/mailfs/apps"
r_data="$tmpdir/mailfs/data"
run_read() {
    r_rc=0
    r_out="$(bash "$read_payload" "$r_apps" "$r_data" 2>"$tmpdir/rerr")" || r_rc=$?
}
rfact() { grep -m1 "^$1=" <<<"$r_out" | cut -d= -f2-; }
accounts_file="$r_data/mail/dms/config/postfix-accounts.cf"
dkim_file="$r_data/mail/dms/config/rspamd/override.d/dkim_signing.conf"

rm -rf "$tmpdir/mailfs"
mkdir -p "$r_apps/traefik/dynamic" "$r_data"
run_read
assert '[ "$r_rc" = "0" ]' "the read runs against a server with no mail at all (rc $r_rc: $(cat "$tmpdir/rerr"))"
assert '[ "$(rfact mail_dir)" = "absent" ]' "reporting no mail directory (got '$(rfact mail_dir)')"
assert '[ "$(rfact mail_accounts)" = "absent" ]' "and no account file (got '$(rfact mail_accounts)')"
assert '[ -z "$(rfact mail_registry_b64)" ]' "and an empty registry (got '$(rfact mail_registry_b64)')"

mkdir -p "$r_apps/mail" "${accounts_file%/*}" "${dkim_file%/*}"
printf 'name: mail\n' > "$r_apps/mail/kasbah.yml"
printf 'http: {}\n' > "$r_apps/traefik/dynamic/_mail.yml"
run_read
assert '[ "$(rfact mail_dir)" = "dir" ]' "an existing mail directory is seen (got '$(rfact mail_dir)')"
assert '[ "$(printf %s "$(rfact mail_registry_b64)" | base64 -d)" = "name: mail" ]' \
    "the registry comes back base64 on one line — this block is a protocol"
assert '[ "$(printf %s "$(rfact mail_fragment_b64)" | base64 -d)" = "http: {}" ]' \
    "and so does the fragment, which lives under traefik/ rather than under mail/"

# The account ladder. `empty` is the state a run that died mid-seed leaves, and
# it has to be distinguishable from `present` or the seed would never happen.
: > "$accounts_file"
run_read
assert '[ "$(rfact mail_accounts)" = "empty" ]' \
    "a zero-length account file is empty, not present (got '$(rfact mail_accounts)')"
printf '# a comment DMS ignores\n\n' > "$accounts_file"
run_read
assert '[ "$(rfact mail_accounts)" = "empty" ]' \
    "and so is one holding only comments and blanks (got '$(rfact mail_accounts)')"
printf 'postmaster@example.com|{SHA512-CRYPT}$6$x$y\n' > "$accounts_file"
run_read
assert '[ "$(rfact mail_accounts)" = "present" ]' \
    "one real account makes it present (got '$(rfact mail_accounts)')"
# No trailing newline — the file provisioner does write one, but a hand edit may
# not, and a read that missed the last line would re-seed over a live account.
printf 'postmaster@example.com|{SHA512-CRYPT}$6$x$y' > "$accounts_file"
run_read
assert '[ "$(rfact mail_accounts)" = "present" ]' \
    "including when the last line has no newline after it (got '$(rfact mail_accounts)')"
printf '\r\npostmaster@example.com|{SHA512-CRYPT}$6$x$y\r\n' > "$accounts_file"
run_read
assert '[ "$(rfact mail_accounts)" = "present" ]' \
    "and when the file was saved with CRLF line endings (got '$(rfact mail_accounts)')"
# The case the \r strip actually protects, and the reason the row above cannot
# stand for it: without the strip a blank CRLF line arrives as "\r", which
# matches neither '' nor '#'* and is counted as an account. The file would read
# as `present`, the postmaster would never be seeded, and Dovecot would panic —
# a failure caused by line endings in a file kasbah wrote nothing to.
printf '# a comment\r\n\r\n' > "$accounts_file"
run_read
assert '[ "$(rfact mail_accounts)" = "empty" ]' \
    "a CRLF file of only comments and blanks is empty, not present (got '$(rfact mail_accounts)')"

# The DKIM override is deliberately not among the facts this read brings back:
# nothing on the local side decides anything with it, and the seed step tests
# the file where it is about to write it. A fact with no verdict behind it would
# read here as a safety mechanism that is not one.
printf 'enabled = true;\n' > "$dkim_file"
run_read
assert '! grep -q "^mail_dkim=" <<<"$r_out"' \
    "the read reports no mail_dkim, seeded or not — mail_dkim_seed is the fact with a reader (got '$r_out')"

rm -rf "$r_apps/mail"; : > "$r_apps/mail"
run_read
assert '[ "$(rfact mail_dir)" = "notdir" ]' \
    "a *file* where the mail directory belongs is its own state (got '$(rfact mail_dir)')"

# --- The remote .env merge, run for real --------------------------------------
# The one file on the server with two owners, so the merge is the thing to test:
# three keys rewritten by name, every other line copied through, and the whole
# of it byte-stable on a re-run.
seed_payload="$tmpdir/mailseed.sh"
awk '/<<'"'"'REMOTE'"'"'$/{buf=""; inb=1; next} inb && /^REMOTE$/{if (buf ~ /mail_layout=done/) printf "%s", buf; inb=0; next} inb{buf = buf $0 "\n"}' \
    "$repo_dir/lib/server_init.sh" > "$seed_payload"
assert '[ -s "$seed_payload" ]' "the mail layout step was extracted from lib/server_init.sh"
assert 'grep -qF "mail_dkim_seed" "$seed_payload"' \
    "and it is the right block — every case below is empty theatre otherwise"

s_apps="$tmpdir/seedfs/apps"
s_data="$tmpdir/seedfs/data"
# The `printf x` sentinel, because $(…) strips trailing newlines and the caller
# in lib/server_init.sh does not: a default one byte shorter than the real one
# would make the created file differ from the merged one and turn this suite's
# idempotence case green for the wrong reason.
env_default=$(printf '# header\nMAIL_HOSTNAME=mail.example.com\nDOMAIN=example.com\nDATA_PATH=%s\n\nDEFAULT_RELAY_HOST=\nRELAY_USER=\nRELAY_PASSWORD=\n' "$s_data"; printf x)
env_default="${env_default%x}"
dkim_body=$(printf 'enabled = true;\ndomain {\n    example.com {}\n}\n')
account_line='postmaster@example.com|{SHA512-CRYPT}$6$salt$hash'
run_seed() {
    s_rc=0
    s_out="$(bash "$seed_payload" "$s_apps" "$s_data" example.com "$env_default" "$dkim_body" "${1-$account_line}" 2>"$tmpdir/serr")" || s_rc=$?
}
sfact() { grep -m1 "^$1=" <<<"$s_out" | cut -d= -f2-; }
s_env="$s_apps/mail/.env"
s_accounts="$s_data/mail/dms/config/postfix-accounts.cf"
s_dkim="$s_data/mail/dms/config/rspamd/override.d/dkim_signing.conf"

rm -rf "$tmpdir/seedfs"; mkdir -p "$s_apps" "$s_data"
run_seed
assert '[ "$s_rc" = "0" ]' "the seed runs against a bare tree (rc $s_rc: $(cat "$tmpdir/serr"))"
assert '[ "$(sfact mail_layout)" = "done" ]' "and says it finished (got '$s_out')"
assert '[ "$(sfact mail_env)" = "created" ]' "writing the .env from the rendered default"
assert '[ "$(sfact mail_account)" = "seeded" ]' "seeding the postmaster account"
assert '[ "$(sfact mail_dkim_seed)" = "seeded" ]' "and the DKIM override"
for d in "$s_data/mail/dms/mail-data" "$s_data/mail/dms/mail-state" \
         "$s_data/mail/dms/mail-logs" "$s_data/mail/dms/config/rspamd/override.d" \
         "$s_data/mail/snappymail"; do
    assert '[ -d "$d" ]' "$d exists — DMS and SnappyMail bind-mount it, and Docker materialises a missing bind-mount source as a root-owned directory"
done
# SnappyMail's own tree is not pre-created. It builds _data_/_default_/domains/
# itself and chowns the lot to its own uid at 750, so a kasbah that made those
# directories would be a kasbah whose *second* run cannot mkdir inside them.
assert '[ ! -e "$s_data/mail/snappymail/_data_" ]' \
    "and _data_/ is left to SnappyMail — pre-creating it is what broke the re-run"
assert '[ "$(cat "$s_accounts")" = "$account_line" ]' \
    "the account file holds exactly the line the caller computed (got '$(cat "$s_accounts")')"
assert '[ "$(stat -c %a "$s_accounts")" = "600" ]' \
    "at mode 600 — it is a password database (got '$(stat -c %a "$s_accounts")')"
assert '[ "$(stat -c %a "$s_env")" = "600" ]' \
    "and the .env too, because the relay block is a credential (got '$(stat -c %a "$s_env")')"

# A second run changes nothing. Everything below depends on this: the sync step
# compares bytes, and a merge that reordered or re-quoted would rewrite the file
# every time.
before=$(cat "$s_env")
run_seed
assert '[ "$(sfact mail_env)" = "unchanged" ]' "a second run leaves the .env alone (got '$s_out')"
assert '[ "$(cat "$s_env")" = "$before" ]' "byte for byte"
assert '[ "$(sfact mail_account)" = "kept" ]' "and does not touch the account"
assert '[ "$(sfact mail_dkim_seed)" = "kept" ]' "or the DKIM override"

# The mode, on the branch that writes nothing — which is the branch every run
# after the first one takes. chmod on the create and rewrite branches alone
# would leave an .env that an older kasbah or a hand edit left world-readable
# at 644 that way forever, with docs/server-setup.md's tree describing a mode
# that never converges. acme.json is chmodded unconditionally for the same
# reason, and what is in this file is the operator's relay credential.
chmod 644 "$s_env"
run_seed
assert '[ "$(sfact mail_env)" = "unchanged" ]' \
    "a mode-only difference is not a content rewrite (got '$s_out')"
assert '[ "$(stat -c %a "$s_env")" = "600" ]' \
    "and the mode converges anyway, on the run that changed nothing (got '$(stat -c %a "$s_env")')"

# The relay block, hand-edited. This is the whole reason the .env is merged
# rather than re-rendered: the credential must survive, and it must never have
# to leave the server to do so.
sed -i 's|^DEFAULT_RELAY_HOST=$|DEFAULT_RELAY_HOST=[smtp-relay.brevo.com]:587|; s|^RELAY_PASSWORD=$|RELAY_PASSWORD=xkeysib-secret|' "$s_env"
printf 'OPERATOR_ONLY=kept\n' >> "$s_env"
run_seed
assert '[ "$(sfact mail_env)" = "unchanged" ]' \
    "a hand-edited relay block is not a difference kasbah rewrites (got '$s_out')"
assert 'grep -qxF "DEFAULT_RELAY_HOST=[smtp-relay.brevo.com]:587" "$s_env"' \
    "the relay host survives (got '$(grep RELAY "$s_env" | tr "\n" " ")')"
assert 'grep -qxF "RELAY_PASSWORD=xkeysib-secret" "$s_env"' "the credential survives"
assert 'grep -qxF "OPERATOR_ONLY=kept" "$s_env"' "and so does a key kasbah has never heard of"

# The other direction: a kasbah-owned value edited by hand is put back, because
# kasbah.yml is where that fact lives and two writers is how they drift.
sed -i 's|^DOMAIN=.*|DOMAIN=wrong.example|' "$s_env"
run_seed
assert '[ "$(sfact mail_env)" = "rewritten" ]' "an edited kasbah-owned value is rewritten (got '$s_out')"
assert 'grep -qxF "DOMAIN=example.com" "$s_env"' \
    "back to what the registry says (got '$(grep "^DOMAIN=" "$s_env")')"
assert 'grep -qxF "RELAY_PASSWORD=xkeysib-secret" "$s_env"' \
    "and the same pass left the operator's half alone"

# A key kasbah owns that the file does not carry — an .env from an older kasbah,
# or one an operator trimmed. Appended rather than silently dropped: compose
# would interpolate an empty string and mount the wrong paths.
# All three of them, because each append is its own `saw_x` branch and one key
# standing in for the others is how the other two go missing unnoticed. An
# absent MAIL_HOSTNAME interpolates empty in compose.yml and SSL_DOMAIN and the
# container hostname both go blank; an absent DOMAIN does the same to the domain
# DMS calls its own.
for miss_key in DATA_PATH MAIL_HOSTNAME DOMAIN; do
    case $miss_key in
        DATA_PATH)     miss_want="DATA_PATH=$s_data" ;;
        MAIL_HOSTNAME) miss_want="MAIL_HOSTNAME=mail.example.com" ;;
        DOMAIN)        miss_want="DOMAIN=example.com" ;;
    esac
    grep -v "^$miss_key=" "$s_env" > "$s_env.x" && mv "$s_env.x" "$s_env"
    run_seed
    assert '[ "$(sfact mail_env)" = "rewritten" ]' \
        "a missing $miss_key is a difference (got '$s_out')"
    assert 'grep -qxF "$miss_want" "$s_env"' \
        "and it is appended rather than silently dropped (got '$(grep "^$miss_key=" "$s_env")')"
    assert 'grep -qxF "RELAY_PASSWORD=xkeysib-secret" "$s_env"' \
        "with the operator's half carried through the append"
    run_seed
    assert '[ "$(sfact mail_env)" = "unchanged" ]' \
        "and the appended file is stable from then on (got '$s_out')"
done

# CRLF, because .env is a file operators edit and some of them on Windows.
printf 'MAIL_HOSTNAME=old\r\nDOMAIN=old\r\nDATA_PATH=old\r\nRELAY_USER=someone\r\n' > "$s_env"
run_seed
assert '[ "$(sfact mail_env)" = "rewritten" ]' "a CRLF .env is merged (got '$s_out')"
assert 'grep -qxF "DOMAIN=example.com" "$s_env"' \
    "with the kasbah keys rewritten clean (got '$(cat -v "$s_env" | tr "\n" "|")')"
assert 'grep -qF "RELAY_USER=someone" "$s_env"' "and the operator's line still there"

# The account file is never written over, whatever the caller hands down. It
# holds every mailbox on the server.
printf 'someone@example.com|{SHA512-CRYPT}$6$live$account\n' > "$s_accounts"
run_seed 'postmaster@example.com|{SHA512-CRYPT}$6$new$hash'
assert '[ "$(sfact mail_account)" = "kept" ]' \
    "an account file with something in it is kept (got '$s_out')"
assert 'grep -qF "live" "$s_accounts"' \
    "and still holds the live account (got '$(cat "$s_accounts")')"
assert '! grep -qF "new" "$s_accounts"' "with nothing seeded over it"

# The DKIM override, once DMS's own helper has extended it. Re-shipping kasbah's
# copy would break signing for every domain added after this run.
printf 'enabled = true;\n# extended by setup config dkim\n' > "$s_dkim"
run_seed
assert '[ "$(sfact mail_dkim_seed)" = "kept" ]' "an extended DKIM override is kept (got '$s_out')"
assert 'grep -qF "extended by setup" "$s_dkim"' "with the extension intact"

# An empty account line is the caller saying "the server already has one" — the
# seed must not invent a file from it.
rm -f "$s_accounts"
run_seed ''
assert '[ "$(sfact mail_account)" = "kept" ]' \
    "no account line means no account written (got '$s_out')"
assert '[ ! -e "$s_accounts" ]' "and no file conjured (exists: $([ -e "$s_accounts" ] && echo yes || echo no))"

# A .env an editor left without a final newline. The merge writes lines, so it
# adds one — a single rewrite, and then stable. Pinned rather than left to
# chance: "changed once, then never" is the property, not "never changed".
rm -rf "$tmpdir/seedfs"; mkdir -p "$s_apps/mail" "$s_data"
printf 'MAIL_HOSTNAME=old\nDOMAIN=old\nDATA_PATH=old\nRELAY_USER=someone' > "$s_env"
run_seed
assert '[ "$(sfact mail_env)" = "rewritten" ]' "a .env with no final newline is rewritten once (got '$s_out')"
run_seed
assert '[ "$(sfact mail_env)" = "unchanged" ]' "and is stable from then on (got '$s_out')"

# A bind-mount directory the *container* has taken over. SnappyMail chowns its
# data root to uid 82 at mode 750 on first boot, so on every later run the
# deploy user can neither enter it nor create inside it. This case reproduces
# exactly the failure the first re-run on the rig hit, and what fixes it is that
# the seed asks for `snappymail` and not for anything below it: `mkdir -p a/b`
# walks into `a`, `mkdir -p a` on an existing `a` does not.
rm -rf "$tmpdir/seedfs"; mkdir -p "$s_apps" "$s_data/mail/snappymail/_data_"
chmod 000 "$s_data/mail/snappymail"
run_seed
chmod 750 "$s_data/mail/snappymail"
assert '[ "$s_rc" = "0" ]' \
    "a snappymail directory this user cannot enter does not fail the seed (rc $s_rc: $(cat "$tmpdir/serr"))"
assert '[ "$(sfact mail_layout)" = "done" ]' "the step still finishes (got '$s_out')"
# The control, so the case above is about the path and not about a chmod that
# did not take: the deep path the seed used to ask for does fail here.
chmod 000 "$s_data/mail/snappymail"
mkdir -p "$s_data/mail/snappymail/_data_/_default_/domains" 2>/dev/null; deep_rc=$?
chmod 750 "$s_data/mail/snappymail"
assert '[ "$deep_rc" != "0" ]' \
    "and mkdir -p into that directory really is refused (rc $deep_rc) — else the case above proves nothing"

# A file where a directory belongs. `mkdir -p` fails on it with "File exists",
# which is not a diagnosis anybody enjoys.
rm -rf "$tmpdir/seedfs"; mkdir -p "$s_apps"; : > "$s_apps/mail"
run_seed
assert '[ "$s_rc" != "0" ]' "a file at <apps>/mail fails the seed (rc $s_rc)"
assert 'grep -qF "could not create" "$tmpdir/serr"' "naming the path (said '$(cat "$tmpdir/serr")')"

exit "$fail"
