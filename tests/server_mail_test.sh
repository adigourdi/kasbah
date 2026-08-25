#!/usr/bin/env bash
# Test: `kasbah server add-mail-domain` and `kasbah server mail-setup-guide`,
# against a stub ssh. Everything both commands decide is decided on this side —
# the registry travels back as base64 and is parsed with the workstation's yq,
# because the VPS has no YAML parser and keeping it that way is deliberate — so
# a stub that answers the two remote reads exercises the whole of it.
#
# What the stub cannot show is on the rig: that the registry it writes is the
# one `server init` re-renders unchanged, and that docker-mailserver picks the
# alias up.

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

stub_dir="$tmpdir/bin"
mkdir -p "$stub_dir" "$tmpdir/home" "$tmpdir/run"
call_log="$tmpdir/calls"
payload_log="$tmpdir/payloads"

# The stub answers three remote steps and records every one, with the script it
# was fed: the registry this command writes travels down stdin's `bash -s`
# argument list, so the only way to see what would have landed on the server is
# to catch it here.
cat > "$stub_dir/ssh" <<'STUB'
#!/usr/bin/env bash
{ printf 'ssh'; for a in "$@"; do printf '|%s' "$a"; done; printf '\n'; } >> "$CALL_LOG"
last="${!#}"
for a in "$@"; do [ "$a" = "-n" ] || continue; exec </dev/null; break; done
case "$*" in
    *"-O exit"*) exit 0 ;;
esac
case "$last" in
    true) exit 0 ;;
    "'bash' '-s'"*) cat >/dev/null ;;
esac
case "$last" in
    # The marker read every server-side command opens with.
    "'bash' '-s' '--' '/apps' '/etc/kasbah/apps-path'")
        printf 'apps=/apps\nsource=default\n'
        printf '%s\n' '{"kasbah_version":"0.1.0","apps_path":"/apps","data_path":"/apps/data","cpu_limit":"2.0","mem_limit":"4g"}' ;;
    # The mail read: apps path and data path, and nothing else.
    "'bash' '-s' '--' '/apps' '/apps/data'")
        printf 'mail_dir=%s\n' "${MAIL_DIR:-dir}"
        printf 'mail_env=%s\n' "${MAIL_ENV:-yes}"
        printf 'mail_registry_b64=%s\n' "${REGISTRY_B64-}"
        printf 'mail_aliases_b64=%s\n' "${ALIASES_B64-}"
        printf 'host_addr=%s\n' "${HOST_ADDR-203.0.113.7}" ;;
    # The write: apps, data, the whole rendered registry, the alias line.
    "'bash' '-s' '--' '/apps' '/apps/data' "*)
        printf '%s\n' "$last" >> "$PAYLOAD_LOG"
        printf 'registry=%s\n' "${REGISTRY_RESULT:-written}"
        printf 'alias=%s\n' "${ALIAS_RESULT:-added}" ;;
    *)
        printf 'stub: no answer for remote step %s\n' "$last" >&2
        exit 9 ;;
esac
exit 0
STUB
chmod 0755 "$stub_dir/ssh"

run() {
    : > "$call_log"; : > "$payload_log"
    env -u KASBAH_LIB_DIR -u KASBAH_TEMPLATE_DIR -u KASBAH_VERSION \
        HOME="$tmpdir/home" PATH="$stub_dir:$PATH" TMPDIR="$tmpdir/run" \
        CALL_LOG="$call_log" PAYLOAD_LOG="$payload_log" \
        "$kasbah" "$@" </dev/null 2>&1
}

b64() { printf '%s' "$1" | openssl base64 -A; }

registry_one=$'name: mail\nprimary_domain: example.test\ndomains:\n  - example.test\n'
registry_two=$'name: mail\nprimary_domain: example.test\ndomains:\n  - example.test\n  - shop.test\n'

# --- Adding a domain the stack does not have -------------------------------------
out="$( REGISTRY_B64="$(b64 "$registry_one")" \
        run server add-mail-domain deploy@vps shop.test )"; rc=$?
calls="$(<"$call_log")"
payload="$(<"$payload_log")"
assert '[ "$rc" = "0" ]' "add-mail-domain adds a new domain (rc $rc: $out)"
assert 'grep -qF "Added shop.test" <<<"$out"' "and says so (said '$out')"
# The registry is re-rendered from templates/mail/kasbah.yml with the new list,
# so what travels has to carry *both* domains — a payload with only the new one
# would be a registry that dropped the primary.
assert 'grep -qF "  - example.test" <<<"$payload"' \
    "the registry that travelled keeps the domain it already had (payload: $payload)"
assert 'grep -qF "  - shop.test" <<<"$payload"' "and gains the new one (payload: $payload)"
assert 'grep -qF "primary_domain: example.test" <<<"$payload"' \
    "and its primary is untouched — the MX target and both certificates hang off it"
# The alias is what makes Postfix accept mail for the domain at all: DMS builds
# its accepted-domain list out of postfix-accounts.cf and postfix-virtual.cf.
assert 'grep -qF "'"'"'postmaster@shop.test postmaster@example.test'"'"'" <<<"$payload"' \
    "and postmaster@shop.test is aliased to the primary mailbox (payload: $payload)"
assert 'grep -qF "postmaster@shop.test postmaster@example.test" <<<"$out"' \
    "which is reported (said '$out')"
# No router: mail.<primary> and webmail.<primary> are the stack's hostnames and
# an app domain needs an MX record, not a fragment (docs/mail.md → Multi-domain).
assert '! grep -qF "_mail.yml" <<<"$calls"' \
    "and nothing touched the Traefik fragment ($calls)"
assert 'grep -qF "add-mail-domain" <<<"$out" || grep -qF "dkim" <<<"$out"' \
    "and the DKIM follow-up is spelled out (said '$out')"
assert 'grep -qF "setup config dkim keytype ed25519 selector ed   domain shop.test" <<<"$out"' \
    "naming the keygen command for the new domain (said '$out')"

# --- Idempotence -----------------------------------------------------------------
# Both halves already in place: the registry lists it and the alias is in
# postfix-virtual.cf. A no-op that says so, and — the part that matters — no
# write step at all.
out="$( REGISTRY_B64="$(b64 "$registry_two")" \
        ALIASES_B64="$(b64 $'postmaster@shop.test postmaster@example.test\n')" \
        run server add-mail-domain deploy@vps shop.test )"; rc=$?
calls="$(<"$call_log")"
payload="$(<"$payload_log")"
assert '[ "$rc" = "0" ]' "adding a domain twice is not an error (rc $rc: $out)"
assert 'grep -qF "already served" <<<"$out"' "and says so (said '$out')"
assert '[ -z "$payload" ]' "and writes nothing at all (payload: $payload)"
assert '! grep -qF "Added shop.test" <<<"$out"' \
    "not reported as an addition (said '$out')"

# The half-done state, which is the one an idempotence check written as "is it in
# the registry?" gets wrong: listed, but with no alias, so Postfix still refuses
# mail for it. That converges rather than reporting nothing to do.
out="$( REGISTRY_B64="$(b64 "$registry_two")" \
        run server add-mail-domain deploy@vps shop.test )"; rc=$?
payload="$(<"$payload_log")"
assert '[ "$rc" = "0" ]' "a domain in the registry with no alias converges (rc $rc: $out)"
assert 'grep -qF "'"'"'postmaster@shop.test postmaster@example.test'"'"'" <<<"$payload"' \
    "writing the missing alias (payload: $payload)"
assert '! grep -qF "already served" <<<"$out"' "rather than calling it done (said '$out')"
# And the list does not gain a second copy of a domain that is already in it.
assert '[ "$(grep -c -- "- shop.test" <<<"$payload")" = 1 ]' \
    "with no duplicate entry (payload: $payload)"

# --- What it refuses -------------------------------------------------------------
out="$( run server add-mail-domain deploy@vps 'not a domain' )"; rc=$?
calls="$(<"$call_log")"
assert '[ "$rc" != "0" ]' "a value that is not a domain is refused (rc $rc: $out)"
assert 'grep -qF "is not a domain name" <<<"$out"' "saying why (said '$out')"
assert '[ -z "$calls" ]' "before any connection (ssh saw: $calls)"

out="$( run server add-mail-domain deploy@vps )"; rc=$?
assert '[ "$rc" != "0" ]' "a missing domain is refused (rc $rc: $out)"
assert 'grep -qF "a domain is required" <<<"$out"' "saying so (said '$out')"

out="$( MAIL_DIR=absent REGISTRY_B64="$(b64 "$registry_one")" \
        run server add-mail-domain deploy@vps shop.test )"; rc=$?
payload="$(<"$payload_log")"
assert '[ "$rc" != "0" ]' "a server with no mail stack is refused (rc $rc: $out)"
assert 'grep -qF "there is no mail stack" <<<"$out"' "saying so (said '$out')"
assert 'grep -qF "kasbah server init deploy@vps --with-mail" <<<"$out"' \
    "and naming what installs it (said '$out')"
assert '[ -z "$payload" ]' "and nothing was written (payload: $payload)"

out="$( REGISTRY_B64="$(b64 $'name: mail\ndomains:\n  - [oops\n')" \
        run server add-mail-domain deploy@vps shop.test )"; rc=$?
payload="$(<"$payload_log")"
assert '[ "$rc" != "0" ]' "a registry that does not parse is refused (rc $rc: $out)"
assert 'grep -qF "could not be read as YAML" <<<"$out"' "saying that (said '$out')"
assert '[ -z "$payload" ]' "and is never rewritten from a guess (payload: $payload)"

out="$( REGISTRY_B64= run server add-mail-domain deploy@vps shop.test )"; rc=$?
assert '[ "$rc" != "0" ]' "an absent registry is refused (rc $rc: $out)"
assert 'grep -qF "missing or empty" <<<"$out"' "as its own case (said '$out')"

# The alias file docker-mailserver has taken over. The registry is still kasbah's
# and is still written; the alias is reported as not written, with the command
# that writes it — a silent success there would be mail nobody accepts.
out="$( REGISTRY_B64="$(b64 "$registry_one")" ALIAS_RESULT=failed \
        run server add-mail-domain deploy@vps shop.test )"; rc=$?
assert '[ "$rc" = "0" ]' "an unwritable alias file does not lose the registry write (rc $rc: $out)"
assert 'grep -qF "Added shop.test" <<<"$out"' "which is still reported (said '$out')"
assert 'grep -qF "docker exec mail-dms setup alias add postmaster@shop.test postmaster@example.test" <<<"$out"' \
    "with the command that finishes the job (said '$out')"

# A stack whose .env never landed. The registry is this command's to write and
# it is written; what the operator is told is that the stack it was added to
# cannot start as it stands.
out="$( REGISTRY_B64="$(b64 "$registry_one")" MAIL_ENV=no \
        run server add-mail-domain deploy@vps shop.test )"; rc=$?
payload="$(<"$payload_log")"
assert '[ "$rc" = "0" ]' "a half-made stack does not stop the domain being added (rc $rc: $out)"
assert 'grep -qF "has no .env, so that stack cannot start" <<<"$out"' \
    "and the missing .env is reported (said '$out')"
assert 'grep -qF "  - shop.test" <<<"$payload"' "while the registry is still written (payload: $payload)"

# The write step's own report, read rather than merely counted. The registry is
# replaced through a temp file and a rename, so a step that came back saying
# anything else is one whose result this kasbah cannot vouch for.
out="$( REGISTRY_B64="$(b64 "$registry_one")" REGISTRY_RESULT=half \
        run server add-mail-domain deploy@vps shop.test )"; rc=$?
assert '[ "$rc" != "0" ]' "an unrecognised write result is a failure (rc $rc: $out)"
assert 'grep -qF "reported registry='\''half'\''" <<<"$out"' "quoting what it said (said '$out')"
assert '! grep -qF "Added shop.test" <<<"$out"' \
    "and nothing is reported as added (said '$out')"

# --- mail-setup-guide -------------------------------------------------------------
out="$( REGISTRY_B64="$(b64 "$registry_two")" \
        run server mail-setup-guide deploy@vps )"; rc=$?
calls="$(<"$call_log")"
payload="$(<"$payload_log")"
assert '[ "$rc" = "0" ]' "the guide prints (rc $rc: $out)"
assert '[ -z "$payload" ]' "and writes nothing on the server (payload: $payload)"
assert '[ "$(grep -c "bash. .-s" <<<"$calls")" = 2 ]' \
    "in two remote reads and no more — marker, then registry ($calls)"
# Rendered for this server's registry, not printed as a generic example.
assert 'grep -qF "Primary domain: example.test" <<<"$out"' "naming the primary (said '$out')"
assert 'grep -qF "shop.test.                    IN MX    10 mail.example.test." <<<"$out"' \
    "with an MX for the added domain pointing at the primary's hostname (said '$out')"
assert 'grep -qF "example.test.                    IN MX    10 mail.example.test." <<<"$out"' \
    "and one for the primary itself (said '$out')"
assert 'grep -qF "_dmarc.shop.test." <<<"$out"' "a DMARC record per domain (said '$out')"
assert 'grep -qF "mail._domainkey.shop.test." <<<"$out"' "and both DKIM selectors (said '$out')"
assert 'grep -qF "ed._domainkey.shop.test." <<<"$out"' "including the ed25519 one (said '$out')"
assert 'grep -qF "mail.example.test.               IN A     203.0.113.7" <<<"$out"' \
    "the two A records the stack needs, at the address the session reached (said '$out')"
assert 'grep -qF "ip4:203.0.113.7" <<<"$out"' "and the SPF carrying it (said '$out')"
# The two prerequisites kasbah cannot check and an operator will otherwise miss.
assert 'grep -qF "Reverse DNS (PTR)" <<<"$out"' "the PTR prerequisite is stated (said '$out')"
assert 'grep -qF "mail.example.test" <<<"$out"' "for this server'\''s hostname (said '$out')"
assert 'grep -qF "Port 25 **outbound**" <<<"$out"' \
    "and the port 25 one, which many providers block (said '$out')"
# A domain the registry does not list must not appear anywhere in the guide:
# that is the difference between rendering the registry and printing a template.
assert '! grep -qF "original project" <<<"$out"' "and nothing of the stack it was ported from (said '$out')"
assert '! grep -qF "other.test" <<<"$out"' "nor a domain this server does not serve"

# With no address to render — a server that told us nothing — the guide says
# what it does not know rather than inventing an IP.
out="$( REGISTRY_B64="$(b64 "$registry_one")" HOST_ADDR= \
        run server mail-setup-guide deploy@vps )"; rc=$?
assert '[ "$rc" = "0" ]' "the guide prints without an address too (rc $rc)"
assert 'grep -qF "<VPS IP>" <<<"$out"' "with a placeholder (said '$out')"

out="$( MAIL_DIR=absent run server mail-setup-guide deploy@vps )"; rc=$?
assert '[ "$rc" != "0" ]' "and refuses on a server with no mail stack (rc $rc: $out)"
assert 'grep -qF "there is no mail stack" <<<"$out"' "saying so (said '$out')"

exit "$fail"
