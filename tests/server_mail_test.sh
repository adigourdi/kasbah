#!/usr/bin/env bash
# Test: `kasbah server add-mail-domain` and `kasbah server mail-setup-guide`
# (internal/mail), against a scratch apps tree. A stub ssh runs each remote
# command here, so the server half is the real `kasbah remote mail` of the
# binary under test, reading and writing planted files; /apps in its arguments
# is the scratch tree. The registry is parsed on the workstation by
# internal/mailreg, the one reader.
#
# What the stub cannot show is on the rig: that the registry it writes is the
# one `server init` re-renders unchanged, and that docker-mailserver picks the
# alias up. A write step reporting something kasbah does not know is pinned in
# internal/mail's go test, which can fake the server's answer.

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
. "$repo_dir/tests/cli.sh"
kasbah="$KASBAH_BIN"

tmpdir="$(mktemp -d)"
trap 'chmod -R u+rwX "$tmpdir" 2>/dev/null; rm -rf "$tmpdir"' EXIT

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

stub_dir="$tmpdir/bin"
mkdir -p "$stub_dir" "$tmpdir/home" "$tmpdir/run"
call_log="$tmpdir/calls"
FAKE_APPS="$tmpdir/srv/apps"

cat > "$stub_dir/ssh" <<'STUB'
#!/usr/bin/env bash
{ printf 'ssh'; for a in "$@"; do printf '|%s' "$a"; done; printf '\n'; } >> "$CALL_LOG"
for a; do [ "$a" = -O ] && exit 0; done
for a; do [ "$a" = -n ] && exec </dev/null; done
last="${!#}"
[ "$last" = true ] && exit 0
if [ -n "${HOST_ADDR-203.0.113.7}" ]; then
    export SSH_CONNECTION="198.51.100.1 50000 ${HOST_ADDR-203.0.113.7} 22"
else
    unset SSH_CONNECTION
fi
eval "set -- $last"
if [ "$1 $2" = "sh -s" ]; then
    exec sh -s -- "$FAKE_APPS" "$FAKE_APPS/no-pointer" "$6" "$7"
fi
args=()
for a; do case $a in /apps|/apps/*) a="$FAKE_APPS${a#/apps}" ;; esac; args+=("$a"); done
exec "${args[@]}"
STUB
chmod 0755 "$stub_dir/ssh"

registry_one=$'name: mail\nprimary_domain: example.test\ndomains:\n  - example.test\n'
registry_two=$'name: mail\nprimary_domain: example.test\ndomains:\n  - example.test\n  - shop.test\n'
reg="$FAKE_APPS/mail/kasbah.yml"
aliases="$FAKE_APPS/data/mail/dms/config/postfix-virtual.cf"
frag="$FAKE_APPS/traefik/dynamic/_mail.yml"

# A prepared server with a mail stack: marker, binary, the stack's directory,
# its .env, DMS's config directory, the fragment. MAIL_DIR=absent leaves the
# stack out; MAIL_ENV=no its .env; REGISTRY="" leaves the registry out.
plant() {
    chmod -R u+rwX "$tmpdir/srv" 2>/dev/null
    rm -rf "$tmpdir/srv"
    mkdir -p "$FAKE_APPS/.kasbah/bin" "$FAKE_APPS/traefik/dynamic"
    printf '%s\n' '{"kasbah_version":"0.1.0","apps_path":"/apps","data_path":"/apps/data","cpu_limit":"2.0","mem_limit":"4g"}' \
        > "$FAKE_APPS/.kasbah/server.json"
    cp "$KASBAH_BIN" "$FAKE_APPS/.kasbah/bin/kasbah"
    printf 'http: {}\n' > "$frag"
    [ "${MAIL_DIR:-dir}" = dir ] || return 0
    mkdir -p "$FAKE_APPS/mail" "$FAKE_APPS/data/mail/dms/config"
    [ "${MAIL_ENV:-yes}" = no ] || printf 'DOMAIN=example.test\n' > "$FAKE_APPS/mail/.env"
    [ -z "${REGISTRY-$registry_one}" ] || printf '%s' "${REGISTRY-$registry_one}" > "$reg"
    [ -z "${ALIASES:-}" ] || printf '%s' "$ALIASES" > "$aliases"
    return 0
}

run() {
    plant
    : > "$call_log"
    env -u KASBAH_LIB_DIR \
        HOME="$tmpdir/home" PATH="$stub_dir:$PATH" TMPDIR="$tmpdir/run" NO_COLOR=1 \
        CALL_LOG="$call_log" FAKE_APPS="$FAKE_APPS" \
        "$kasbah" "$@" </dev/null 2>&1
}
wrote() { grep -qF "'mail' 'write'" "$call_log"; }

# --- Adding a domain the stack does not have -------------------------------------
out="$( run server add-mail-domain deploy@vps shop.test )"; rc=$?
calls="$(<"$call_log")"
assert '[ "$rc" = "0" ]' "add-mail-domain adds a new domain (rc $rc: $out)"
assert 'grep -qF "Added shop.test" <<<"$out"' "and says so (said '$out')"
# Re-rendered from templates/mail/kasbah.yml with the new list: both domains,
# the primary untouched — the MX target and both certificates hang off it.
assert 'grep -qxF "  - example.test" "$reg"' "the registry keeps the domain it had ($(cat "$reg"))"
assert 'grep -qxF "  - shop.test" "$reg"' "and gains the new one"
assert 'grep -qxF "primary_domain: example.test" "$reg"' "and its primary is untouched"
assert '[ "$(stat -c %a "$reg")" = 644 ]' "at mode 644"
# The alias is what makes Postfix accept mail for the domain at all.
assert 'grep -qxF "postmaster@shop.test postmaster@example.test" "$aliases"' \
    "and postmaster@shop.test is aliased to the primary mailbox ($(cat "$aliases" 2>&1))"
assert 'grep -qF "postmaster@shop.test postmaster@example.test" <<<"$out"' "which is reported (said '$out')"
# No router: an app domain needs an MX record, not a fragment.
assert '[ "$(cat "$frag")" = "http: {}" ]' "and the Traefik fragment is untouched"
assert 'grep -qF "setup config dkim keytype ed25519 selector ed   domain shop.test" <<<"$out"' \
    "the DKIM follow-up names the keygen command for the new domain (said '$out')"
assert '[ -z "$(ls "$FAKE_APPS/mail" | grep -v -e "^kasbah.yml$" -e "^.env$")" ] && [ -z "$(ls -A "$tmpdir/run")" ]' \
    "and no staging file is left anywhere ($(ls -A "$FAKE_APPS/mail" "$tmpdir/run"))"

# --- Idempotence -----------------------------------------------------------------
out="$( REGISTRY="$registry_two" ALIASES=$'postmaster@shop.test postmaster@example.test\n' \
        run server add-mail-domain deploy@vps shop.test )"; rc=$?
assert '[ "$rc" = "0" ]' "adding a domain twice is not an error (rc $rc: $out)"
assert 'grep -qF "already served" <<<"$out"' "and says so (said '$out')"
assert '! wrote' "and writes nothing at all ($(<"$call_log"))"
assert '! grep -qF "Added shop.test" <<<"$out"' "not reported as an addition (said '$out')"

# Listed, but with no alias, so Postfix still refuses mail for it: converges.
out="$( REGISTRY="$registry_two" run server add-mail-domain deploy@vps shop.test )"; rc=$?
assert '[ "$rc" = "0" ]' "a domain in the registry with no alias converges (rc $rc: $out)"
assert 'grep -qxF "postmaster@shop.test postmaster@example.test" "$aliases"' "writing the missing alias"
assert '! grep -qF "already served" <<<"$out"' "rather than calling it done (said '$out')"
assert '[ "$(grep -c -- "- shop.test" "$reg")" = 1 ]' "with no duplicate entry ($(cat "$reg"))"

# An alias file whose last line has no newline is not glued onto.
out="$( ALIASES='x@example.test y@example.test' run server add-mail-domain deploy@vps shop.test )"; rc=$?
assert '[ "$(sed -n 2p "$aliases")" = "postmaster@shop.test postmaster@example.test" ]' \
    "an alias is appended on its own line ($(cat "$aliases"))"

# --- What it refuses -------------------------------------------------------------
out="$( run server add-mail-domain deploy@vps 'not a domain' )"; rc=$?
assert '[ "$rc" != "0" ]' "a value that is not a domain is refused (rc $rc: $out)"
assert 'grep -qF "is not a domain name" <<<"$out"' "saying why (said '$out')"
assert '[ ! -s "$call_log" ]' "before any connection (ssh saw: $(<"$call_log"))"

out="$( run server add-mail-domain deploy@vps )"; rc=$?
assert '[ "$rc" != "0" ]' "a missing domain is refused (rc $rc: $out)"
assert 'grep -qF "a domain is required" <<<"$out"' "saying so (said '$out')"

out="$( MAIL_DIR=absent run server add-mail-domain deploy@vps shop.test )"; rc=$?
assert '[ "$rc" != "0" ]' "a server with no mail stack is refused (rc $rc: $out)"
assert 'grep -qF "there is no mail stack" <<<"$out"' "saying so (said '$out')"
assert 'grep -qF "kasbah server init deploy@vps --with-mail" <<<"$out"' "and naming what installs it (said '$out')"
assert '! wrote && [ ! -e "$FAKE_APPS/mail" ]' "and nothing was written"

out="$( REGISTRY=$'name: mail\ndomains:\n  - [oops\n' run server add-mail-domain deploy@vps shop.test )"; rc=$?
assert '[ "$rc" != "0" ]' "a registry that does not parse is refused (rc $rc: $out)"
assert 'grep -qF "could not be read as YAML" <<<"$out"' "saying that (said '$out')"
assert '! wrote && grep -qF "[oops" "$reg"' "and is never rewritten from a guess"

# D4: a registry with no primary_domain is refused, naming the file and key.
out="$( REGISTRY=$'name: mail\ndomains:\n  - example.test\n' run server add-mail-domain deploy@vps shop.test )"; rc=$?
assert '[ "$rc" != "0" ]' "a registry with no primary_domain is refused (rc $rc: $out)"
assert 'grep -qF "/apps/mail/kasbah.yml on deploy@vps has no primary_domain:" <<<"$out"' "naming file and key (said '$out')"
assert '! wrote' "and nothing was written"

out="$( REGISTRY= run server add-mail-domain deploy@vps shop.test )"; rc=$?
assert '[ "$rc" != "0" ]' "an absent registry is refused (rc $rc: $out)"
assert 'grep -qF "missing or empty" <<<"$out"' "as its own case (said '$out')"

# The alias file docker-mailserver has taken over. The registry is still
# written; the alias is reported as not written, with the command that writes it.
if [ "$(id -u)" != 0 ]; then
    out="$( ALIASES=$'x@example.test y@example.test\n' \
            run server add-mail-domain deploy@vps shop.test 2>&1 )"
    # Re-run against the same tree with the alias file read-only.
    chmod 444 "$aliases"
    : > "$call_log"
    out="$( env -u KASBAH_LIB_DIR \
            HOME="$tmpdir/home" PATH="$stub_dir:$PATH" TMPDIR="$tmpdir/run" NO_COLOR=1 \
            CALL_LOG="$call_log" FAKE_APPS="$FAKE_APPS" \
            "$kasbah" server add-mail-domain deploy@vps other.test </dev/null 2>&1 )"; rc=$?
    assert '[ "$rc" = "0" ]' "an unwritable alias file does not lose the registry write (rc $rc: $out)"
    assert 'grep -qF "Added other.test" <<<"$out" && grep -qxF "  - other.test" "$reg"' "which is still made and reported (said '$out')"
    assert 'grep -qF "docker exec mail-dms setup alias add postmaster@other.test postmaster@example.test" <<<"$out"' \
        "with the command that finishes the job (said '$out')"
fi

# A stack whose .env never landed: the domain is still added, and the operator
# told the stack cannot start as it stands.
out="$( MAIL_ENV=no run server add-mail-domain deploy@vps shop.test )"; rc=$?
assert '[ "$rc" = "0" ]' "a half-made stack does not stop the domain being added (rc $rc: $out)"
assert 'grep -qF "has no .env, so that stack cannot start" <<<"$out"' "and the missing .env is reported (said '$out')"
assert 'grep -qxF "  - shop.test" "$reg"' "while the registry is still written"

# --- mail-setup-guide -------------------------------------------------------------
out="$( REGISTRY="$registry_two" run server mail-setup-guide deploy@vps )"; rc=$?
assert '[ "$rc" = "0" ]' "the guide prints (rc $rc: $out)"
assert '! wrote && [ "$(cat "$reg")" = "${registry_two%$'"'"'\n'"'"'}" ]' "and writes nothing on the server"
assert '[ "$(grep -c "'"'"'remote'"'"' '"'"'mail'"'"'" "$call_log")" = 1 ]' \
    "in one mail read and no more ($(<"$call_log"))"
assert 'grep -qF "Primary domain: example.test" <<<"$out"' "naming the primary (said '$out')"
assert 'grep -qF "shop.test.                    IN MX    10 mail.example.test." <<<"$out"' \
    "with an MX for the added domain pointing at the primary's hostname"
assert 'grep -qF "example.test.                    IN MX    10 mail.example.test." <<<"$out"' "and one for the primary itself"
assert 'grep -qF "_dmarc.shop.test." <<<"$out"' "a DMARC record per domain"
assert 'grep -qF "mail._domainkey.shop.test." <<<"$out"' "and both DKIM selectors"
assert 'grep -qF "ed._domainkey.shop.test." <<<"$out"' "including the ed25519 one"
assert 'grep -qF "mail.example.test.               IN A     203.0.113.7" <<<"$out"' \
    "the two A records the stack needs, at the address the session reached"
assert 'grep -qF "ip4:203.0.113.7" <<<"$out"' "and the SPF carrying it"
assert 'grep -qF "Reverse DNS (PTR)" <<<"$out"' "the PTR prerequisite is stated"
assert 'grep -qF "Port 25 **outbound**" <<<"$out"' "and the port 25 one, which many providers block"
assert '! grep -qF "original project" <<<"$out"' "and nothing of the stack it was ported from"
assert '! grep -qF "other.test" <<<"$out"' "nor a domain this server does not serve"

# With no address to render, the guide says what it does not know.
out="$( HOST_ADDR= run server mail-setup-guide deploy@vps )"; rc=$?
assert '[ "$rc" = "0" ]' "the guide prints without an address too (rc $rc)"
assert 'grep -qF "<VPS IP>" <<<"$out"' "with a placeholder (said '$out')"

out="$( MAIL_DIR=absent run server mail-setup-guide deploy@vps )"; rc=$?
assert '[ "$rc" != "0" ]' "and refuses on a server with no mail stack (rc $rc: $out)"
assert 'grep -qF "there is no mail stack" <<<"$out"' "saying so (said '$out')"

# The usage texts are this binary's.
out="$( "$kasbah" server add-mail-domain --help 2>&1 )"; rc=$?
assert '[ "$rc" = 0 ] && grep -qF "Usage: kasbah server add-mail-domain USER@HOST <domain>" <<<"$out"' "add-mail-domain --help (said '$out')"
out="$( "$kasbah" server mail-setup-guide -h 2>&1 )"; rc=$?
assert '[ "$rc" = 0 ] && grep -qF "Usage: kasbah server mail-setup-guide USER@HOST" <<<"$out"' "mail-setup-guide -h (said '$out')"

exit "$fail"
