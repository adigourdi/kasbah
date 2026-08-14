#!/usr/bin/env bash
# Test: lib/server_init.sh — everything about `hosting server init` that does
# not need a server. Flag parsing, the limit formatter, the marker, and the
# prerequisite verdicts, which are driven from a synthetic fact set so that
# rows the rig cannot break (an old daemon, a sudo that prompts) are still
# covered. The rig-driven half lives in tests/integration/server_init_test.sh.

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
hosting="$repo_dir/bin/hosting"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

export HOSTING_LIB_DIR="$repo_dir/lib"
export HOSTING_TEMPLATE_DIR="$repo_dir/templates"
export HOSTING_VERSION="9.9.9-test"
export NO_COLOR=1

# --- Driver -------------------------------------------------------------------
# The library's own functions, called the way cmd_server_init calls them. The
# fact set below is a host that passes every prerequisite row; each case
# overrides only what it means to break, so a row that stops being checked shows
# up as one failing case rather than a suite that quietly proves nothing.
driver="$tmpdir/driver.sh"
cat > "$driver" <<'DRV'
#!/usr/bin/env bash
set -euo pipefail
. "$HOSTING_LIB_DIR/common.sh"
. "$HOSTING_LIB_DIR/server_init.sh"

mode="$1"; shift
case "$mode" in
    parse)
        _server_init_parse_args "$@"
        printf 'target=%s\napps=%s\ndata=%s\nmail=%s\nbackup=%s\n' \
            "$_SI_TARGET" "$_SI_APPS_PATH" "$_SI_DATA_PATH" \
            "${_SI_MAIL:-unset}" "${_SI_BACKUP:-unset}"
        printf 'domain=%s\nemail=%s\nauth=%s\n' \
            "${_SI_DOMAIN:-unset}" "${_SI_EMAIL:-unset}" "${_SI_AUTH:-unset}"
        ;;
    authsplit)
        _si_parse_auth "$1" u p
        printf 'user=%s\npass=%s\n' "$u" "$p"
        ;;
    extract)
        # The content arrives on stdin so a fixture can carry newlines and
        # quotes without the shell getting a vote.
        body="$(cat; printf x)"; body="${body%x}"
        v=""
        case "$1" in
            auth)   _si_extract_auth   "$body" v ;;
            domain) _si_extract_domain "$body" v ;;
            email)  _si_extract_email  "$body" v ;;
        esac
        printf '%s\n' "$v"
        ;;
    render)
        _SI_APPS_PATH="$1"; _SI_DATA_PATH="$2"; _SI_ACME_EMAIL="$3"
        _SI_DASHBOARD_DOMAIN="$4"; _SI_AUTH_ENTRY="$5"
        _server_init_traefik_render
        [ -z "${RENDER_OUT:-}" ] || cp -R "$_SI_TMPDIR"/. "$RENDER_OUT"/
        for rel in "${_SI_TRAEFIK_FILES[@]}"; do
            printf '%s %s\n' "$(stat -c '%a' "$_SI_TMPDIR/$rel")" "$rel"
        done
        rm -rf "$_SI_TMPDIR"
        ;;
    values)
        # The dashboard-credential reuse rule, with bcrypt stubbed: what is
        # under test is which of the three sources wins, and a real htpasswd
        # would make this suite need one.
        shared="$1"; static="$2"; shift 2
        _server_init_parse_args deploy@vps "$@"
        _SI_TARGET=deploy@vps
        _SI_TRAEFIK_CURRENT=([compose.yml]="" [traefik.yml]="$static" [dynamic/_shared.yml]="$shared")
        _si_bcrypt() { printf -v "$3" '%s' "$1:\$2y\$05\$FRESHFRESHFRESHFRESHFR"; }
        _server_init_traefik_values
        printf 'domain=%s\nemail=%s\nauth=%s\norigin=%s\n' \
            "$_SI_DASHBOARD_DOMAIN" "$_SI_ACME_EMAIL" "$_SI_AUTH_ENTRY" "$_SI_AUTH_ORIGIN"
        ;;
    sync)
        # Which files ship, and which change forces a Traefik restart. rsync is
        # stubbed: the decision is local, and it is the decision under test.
        same="$1"
        _SI_APPS_PATH=/apps; _SI_DATA_PATH=/apps/data
        _SI_ACME_EMAIL=ops@example.com; _SI_DASHBOARD_DOMAIN=example.com
        _SI_AUTH_ENTRY='admin:$2y$05$STUB'
        SSH_TARGET=deploy@vps
        _server_init_traefik_render
        _SI_TRAEFIK_CURRENT=()
        for rel in "${_SI_TRAEFIK_FILES[@]}"; do
            case ",$same," in
                *",$rel,"*) c="$(cat "$_SI_TMPDIR/$rel"; printf x)"; _SI_TRAEFIK_CURRENT[$rel]="${c%x}" ;;
                *)          _SI_TRAEFIK_CURRENT[$rel]="" ;;
            esac
        done
        ssh_rsync() { printf 'rsync->%s\n' "${*: -1}" >&2; }
        _server_init_traefik_sync
        printf 'changed=%s\nrestart=%s\n' \
            "${_SI_TRAEFIK_CHANGED[*]-}" "$_SI_TRAEFIK_RESTART"
        rm -rf "$_SI_TMPDIR"
        ;;
    limits)
        _server_limits "$1" "$2"
        printf 'cpu=%s\nmem=%s\n' "$_SI_CPU_LIMIT" "$_SI_MEM_LIMIT"
        ;;
    marker)
        _server_marker_json "$1" "$2" "$3" "$4" "$5" "${6:-}"
        ;;
    compat)
        _SI_APPS_PATH=/apps
        _SI_TARGET=deploy@vps
        _SI_MARKER_PRESENT="$1"
        _SI_MARKER_EXISTING="$2"
        _server_init_check_marker
        printf 'compat=ok\n'
        ;;
    elevation|preflight)
        _SI_FACT=(
            [user]=deploy [group]=deploy
            [have_docker]=yes [docker_server]=27.3.1 [docker_error]=""
            [compose_version]=2.29.7
            [have_rsync]=yes [have_openssl]=yes [have_gzip]=yes
            [sudo_nopasswd]=yes
            [apps_state]=absent [apps_owned]=no [apps_writable]=no [apps_owner]=""
            [apps_write_error]="" [apps_root_state]=absent [apps_root_owner]=""
            [apps_base]=/ [apps_base_owner]=root:root [apps_base_mode]=755
            [data_state]=absent [data_writable]=no [data_owner]="" [data_scope]=inside
            [data_base]=/ [data_base_writable]=no
            [nproc]=4 [memtotal_kb]=8388608
        )
        while [ $# -gt 0 ]; do _SI_FACT[${1%%=*}]="${1#*=}"; shift; done
        _SI_DATA_PATH=/apps/data
        _server_init_elevation
        if [ "$mode" = elevation ]; then printf 'elevate=%s\n' "$_SI_ELEVATE"; exit 0; fi
        _server_init_preflight deploy@vps /apps "$_SI_ELEVATE"
        printf 'preflight=ok\n'
        ;;
esac
DRV

# stdin is closed, exactly as `run()` closes it further down. The `values` mode
# reaches prompt_value/prompt_secret, and the tri-state rule sends those to a
# terminal when there is one — so without this the suite passes when stdin is a
# pipe (a CI runner, a `| tee`) and hangs forever in the repo owner's own shell,
# with the question itself swallowed into $tmpdir/err.
drive() { bash "$driver" "$@" 2>"$tmpdir/err" </dev/null; }
# The one mode fed its fixture on stdin. It parses text and cannot prompt, so
# closing stdin here would break the input rather than protect anything.
drive_stdin() { bash "$driver" "$@" 2>"$tmpdir/err"; }
drive_err() { cat "$tmpdir/err"; }

# --- Flag parsing -------------------------------------------------------------
out=$(drive parse deploy@vps); rc=$?
assert '[ "$rc" = "0" ]'                        "a bare target parses (exit $rc: $(drive_err))"
assert 'grep -qxF "target=deploy@vps" <<<"$out"' "the target is kept as given (got '$out')"
assert 'grep -qxF "apps=/apps" <<<"$out"'        "--apps-path defaults to /apps (got '$out')"
assert 'grep -qxF "data=/apps/data" <<<"$out"'   "--data-path defaults below the apps path (got '$out')"
assert 'grep -qxF "mail=unset" <<<"$out"'        "an unpassed --with-mail/--no-mail stays unset — the prompt decides"
assert 'grep -qxF "backup=unset" <<<"$out"'      "an unpassed --with-backup/--no-backup stays unset"

out=$(drive parse --apps-path=/srv/apps deploy@vps)
assert 'grep -qxF "apps=/srv/apps" <<<"$out"'      "--apps-path is honoured (got '$out')"
assert 'grep -qxF "data=/srv/apps/data" <<<"$out"' "--data-path follows --apps-path (got '$out')"

out=$(drive parse --apps-path=/srv/apps/ --data-path=/mnt/vol1/ deploy@vps)
assert 'grep -qxF "apps=/srv/apps" <<<"$out"'  "a trailing slash is normalised away (got '$out')"
assert 'grep -qxF "data=/mnt/vol1" <<<"$out"'  "--data-path may sit outside the apps path (got '$out')"

out=$(drive parse --no-mail --no-backup deploy@vps)
assert 'grep -qxF "mail=no" <<<"$out"'    "--no-mail is recorded as an explicit no"
assert 'grep -qxF "backup=no" <<<"$out"'  "--no-backup is recorded as an explicit no"

out=$(drive parse --with-mail --with-backup deploy@vps)
assert 'grep -qxF "mail=yes" <<<"$out"'   "--with-mail is recorded as an explicit yes"
assert 'grep -qxF "backup=yes" <<<"$out"' "--with-backup is recorded as an explicit yes"

out=$(drive parse deploy@vps); rc=$?
assert 'grep -qxF "domain=unset" <<<"$out"' "an unpassed --domain stays unset — the server, then the prompt, decides"
assert 'grep -qxF "email=unset" <<<"$out"'  "an unpassed --email stays unset"
assert 'grep -qxF "auth=unset" <<<"$out"'   "an unpassed --traefik-auth stays unset"

out=$(drive parse --domain=example.com --email=ops@example.com --traefik-auth=admin:pw deploy@vps); rc=$?
assert '[ "$rc" = "0" ]'                              "the three Traefik flags parse (exit $rc: $(drive_err))"
assert 'grep -qxF "domain=example.com" <<<"$out"'     "--domain is recorded (got '$out')"
assert 'grep -qxF "email=ops@example.com" <<<"$out"'  "--email is recorded (got '$out')"
assert 'grep -qxF "auth=admin:pw" <<<"$out"'          "--traefik-auth is recorded (got '$out')"

# Every rejection below is a flag the command must not silently accept.
reject() {
    local desc="$1" want="$2"; shift 2
    local o r e
    o=$(drive parse "$@"); r=$?
    e=$(drive_err)
    assert '[ "$r" != "0" ]'          "$desc is rejected (exit $r, printed '$o')"
    assert 'grep -qF -- "$want" <<<"$e"' "$desc names '$want' (said '$e')"
}
reject "a missing target"        "USER@HOST is required"
reject "a second target"         "given once"            deploy@vps other@vps
reject "an unknown flag"         "unknown flag '--nope'" deploy@vps --nope
reject "an empty --apps-path"    "must not be empty"     deploy@vps --apps-path=
reject "an empty --data-path"    "must not be empty"     deploy@vps --data-path=
reject "a relative apps path"    "must be an absolute"   deploy@vps --apps-path=apps
reject "the filesystem root"     "filesystem root"       deploy@vps --apps-path=/
reject "a path with .."          "normalised"            deploy@vps --apps-path=/srv/../apps
reject "a path with a newline"   "must not contain a newline" deploy@vps "--apps-path=$(printf '/srv/a\nb')"
# Valid YAML is not enough for the two paths: they land in compose's volume
# short syntax, which compose interpolates and splits before Traefik sees the
# file, so both of these render a document that parses and means something
# else. `/apps/$HOME` mounted `/apps//home/you/...` — expanded on the *server*
# — and `/d:ata` mounted `/d` while leaving acme.json unmounted entirely.
reject "a \$ in the apps path"   "compose expands"       deploy@vps '--apps-path=/apps/$HOME'
reject "a \$ in the data path"   "compose expands"       deploy@vps '--data-path=/data/${STAGE}'
reject "a colon in the apps path" "separates source"     deploy@vps '--apps-path=/ap:ps'
reject "a colon in the data path" "separates source"     deploy@vps '--data-path=/d:ata'
reject "contradicting mail flags"   "cannot both be given" deploy@vps --with-mail --no-mail
reject "contradicting backup flags" "cannot both be given" deploy@vps --no-backup --with-backup

# The Traefik values are checked where they are typed: each one is baked into a
# config file Traefik parses on the far side, so a bad value would otherwise
# surface as a stack that will not start.
reject "an empty --domain"        "--domain= must not be empty"  deploy@vps --domain=
reject "a --domain with no dot"   "is not a domain name"         deploy@vps --domain=localhost
reject "a --domain with a space"  "is not a domain name"         deploy@vps "--domain=ex ample.com"
reject "an empty --email"         "--email= must not be empty"   deploy@vps --email=
reject "an --email with no @"     "is not an email address"      deploy@vps --email=ops.example.com
reject "an --email with two @"    "is not an email address"      deploy@vps --email=a@b@c
reject "an --email with a space"  "must not contain whitespace"  deploy@vps "--email=a b@c.d"
reject "--traefik-auth with no colon" "must be user:pass"        deploy@vps --traefik-auth=admin
reject "--traefik-auth with no user"  "username must not be empty" deploy@vps --traefik-auth=:pw
reject "--traefik-auth with no password" "password must not be empty" deploy@vps --traefik-auth=admin:

# Every value below is written into a double-quoted YAML scalar. A `"` ends that
# scalar; in dynamic/_shared.yml that takes tls.options.default with it, and
# traefik.yml points every websecure entrypoint at those options — so one quote
# in a username stops every project's HTTPS router from starting, while /ping
# keeps answering 200 and the health wait passes. Refused at the input, with a
# message about the input.
reject "a quote in the dashboard username" "must not contain a double quote" \
    deploy@vps '--traefik-auth=ad"min:pw123'
reject "a backslash in the dashboard username" "must not contain a backslash" \
    deploy@vps '--traefik-auth=ad\min:pw123'
reject "a quote in --email"      "must not contain a double quote" deploy@vps '--email=a"b@c.d'
reject "a backslash in --email"  "must not contain a backslash"    deploy@vps '--email=a\b@c.d'
reject "a quote in --apps-path"  "must not contain a double quote" deploy@vps '--apps-path=/srv/a"b'
reject "a quote in --data-path"  "must not contain a double quote" deploy@vps '--data-path=/srv/a"b'

# The control-character rule is asked positively (`[[:cntrl:]]`) rather than as
# "is every byte printable", because the negative form is locale-dependent: any
# UTF-8 value fails it under LC_ALL=C, which is routine in CI, and gets refused
# with a message about control characters it does not contain. Both locales are
# driven here so a reversion cannot pass on this machine's inherited one.
for _loc in C C.UTF-8; do
    out=$(LC_ALL=$_loc drive parse deploy@vps '--apps-path=/srv/café' \
                                    '--email=josé@example.com'); rc=$?
    assert '[ "$rc" = "0" ]' \
        "a UTF-8 path and address are accepted under LC_ALL=$_loc (exit $rc: $(drive_err))"
    out=$(LC_ALL=$_loc drive parse deploy@vps "--apps-path=$(printf '/srv/a\tb')"); rc=$?
    assert '[ "$rc" != "0" ]' \
        "a tab in a path is still refused under LC_ALL=$_loc (exit $rc)"
done
unset _loc

# The password is not written to any file — only its bcrypt hash is, and bcrypt
# emits nothing but [./A-Za-z0-9$]. So the quote rule must not reach it.
out=$(drive parse deploy@vps '--traefik-auth=admin:pw"with\quote'); rc=$?
assert '[ "$rc" = "0" ]' \
    "a quote in the *password* is fine — only the hash is written, never the password (exit $rc: $(drive_err))"

# A rejected --traefik-auth must never quote the value back: the flag carries a
# password, and an error message is the one place it would reach a terminal or
# a CI log.
out=$(drive parse deploy@vps "--traefik-auth=ad min:hunter2"); rc=$?
err_out=$(drive_err)
assert '[ "$rc" != "0" ]' "a username with a space is rejected (exit $rc)"
assert 'grep -qF "username must not contain whitespace" <<<"$err_out"' \
    "and says why (said '$err_out')"
assert '! grep -qF "hunter2" <<<"$err_out"' \
    "and does not print the password back (said '$err_out')"

# The same property for the spelling that never reaches the validator. A
# mistyped credential flag falls through to the unknown-flag branch, which used
# to quote the whole argument — password included — into the message and into
# any CI log that keeps one.
for typo in --traefik-auths --traefik-auth-- --dashboard-pw; do
    out=$(drive parse deploy@vps "$typo=admin:hunter2"); rc=$?
    err_out=$(drive_err)
    assert '[ "$rc" != "0" ]' "$typo is rejected (exit $rc)"
    assert 'grep -qF "unknown flag '\''$typo'\''" <<<"$err_out"' \
        "naming the flag so the typo is obvious (said '$err_out')"
    assert '! grep -qF "hunter2" <<<"$err_out"' \
        "without echoing what might be a password (said '$err_out')"
done

# user:pass splits at the *first* colon, so a password may contain colons.
out=$(drive authsplit 'admin:pa:ss:word'); rc=$?
assert '[ "$rc" = "0" ]' "a password with colons parses (exit $rc: $(drive_err))"
assert 'grep -qxF "user=admin" <<<"$out"'      "the username is everything before the first colon (got '$out')"
assert 'grep -qxF "pass=pa:ss:word" <<<"$out"' "the password is everything after it (got '$out')"

out=$(drive parse --help); rc=$?
assert '[ "$rc" = "0" ]' "--help exits 0 (got $rc)"
assert 'grep -qF -- "--apps-path" <<<"$out"' "--help lists the flags (got '$out')"

# --- Resource limits ----------------------------------------------------------
# 90% of the host, formatted the one way it is always formatted.
limits() { drive limits "$1" "$2" | tr '\n' ' '; }
assert '[ "$(limits 16 63624052)" = "cpu=14.4 mem=54g " ]' \
    "16 cores / 60.7 GiB -> 14.4 and 54g (got '$(limits 16 63624052)')"
assert '[ "$(limits 4 8388608)" = "cpu=3.6 mem=7g " ]' \
    "4 cores / 8 GiB -> 3.6 and 7g, the GiB floored (got '$(limits 4 8388608)')"
assert '[ "$(limits 10 1048576)" = "cpu=9.0 mem=921m " ]' \
    "a whole cpu result keeps its decimal place, and a 1 GiB host gets MiB (got '$(limits 10 1048576)')"
assert '[ "$(limits 1 524288)" = "cpu=0.9 mem=460m " ]' \
    "a 512 MiB host gets a ceiling below its own RAM, not 1g (got '$(limits 1 524288)')"
assert '[ "$(limits 3 2097152)" = "cpu=2.7 mem=1g " ]' \
    "2 GiB floors to 1g rather than rounding to 2 (got '$(limits 3 2097152)')"
assert '[ "$(limits 2 1165085)" = "cpu=1.8 mem=1g " ]' \
    "1165085 kB is the smallest host whose 90% still reaches 1g (got '$(limits 2 1165085)')"
assert '[ "$(limits 2 1165084)" = "cpu=1.8 mem=1023m " ]' \
    "and one kB less crosses to MiB rather than clamping (got '$(limits 2 1165084)')"
assert '[ "$(limits 1 1)" = "cpu=0.9 mem=1m " ]' \
    "an absurd host still gets a parseable limit (got '$(limits 1 1)')"

# The formatter must stay locale-proof, and that cannot be shown by running it
# under a locale this machine may not have: LC_ALL overrides LC_NUMERIC, and
# setlocale falls back to C for a locale that is not installed, so the obvious
# comparison passes against a `printf '%.1f'` implementation too (measured).
# What holds everywhere is the structural property — the limit path does no
# floating-point formatting at all.
limit_body=$(sed -n '/^_server_limits() {/,/^}/p' "$repo_dir/lib/server_init.sh" | grep -v '^ *#')
assert '[ -n "$limit_body" ]' "the limit function was found (else the checks below are vacuous)"
for float in 'printf' 'bc' 'awk' 'python' 'perl'; do
    assert '! grep -qF -- "$float" <<<"$limit_body"' \
        "_server_limits computes without $float — a float formatter is what makes output locale-dependent"
done
assert 'grep -qF -- "\$((" <<<"$limit_body"' "_server_limits uses shell integer arithmetic"

# And the real thing, when the machine can express it. Skipped loudly: a silent
# skip is how the version of this check that could never fail survived review.
comma_locale=""
while IFS= read -r loc; do
    [ -n "$loc" ] || continue
    if [ "$(LC_ALL="$loc" locale decimal_point 2>/dev/null)" = "," ]; then comma_locale="$loc"; break; fi
done < <(locale -a 2>/dev/null)
if [ -n "$comma_locale" ]; then
    assert '[ "$(limits 16 63624052)" = "$(LC_ALL="$comma_locale" limits 16 63624052)" ]' \
        "the decimal separator does not follow the operator's locale (checked under $comma_locale)"
else
    echo "  SKIP: no comma-decimal locale is installed — the locale comparison could not run" >&2
fi

for bad in "0 8388608" "x 8388608" "4 0" "4 abc" "-4 8388608"; do
    # shellcheck disable=SC2086
    out=$(drive limits $bad); rc=$?
    assert '[ "$rc" != "0" ]' "limits refuse a nonsense host fact ('$bad' produced '$out')"
done

# --- Server marker ------------------------------------------------------------
marker=$(drive marker 0.1.0 /apps /apps/data 3.6 7g); rc=$?
assert '[ "$rc" = "0" ]'                  "the marker renders (exit $rc: $(drive_err))"
assert 'jq -e . >/dev/null <<<"$marker"'  "the marker is valid JSON (got '$marker')"
for key in hosting_version apps_path data_path cpu_limit mem_limit backup; do
    assert 'jq -e --arg k "$key" "has(\$k)" >/dev/null <<<"$marker"' \
        "the marker carries $key, as docs/server-setup.md specifies"
done
assert '[ "$(jq -r .hosting_version <<<"$marker")" = "0.1.0" ]' "hosting_version is the tool's"
assert '[ "$(jq -r .apps_path <<<"$marker")" = "/apps" ]'       "apps_path is recorded"
assert '[ "$(jq -r .data_path <<<"$marker")" = "/apps/data" ]'  "data_path is recorded"
assert '[ "$(jq -r .cpu_limit <<<"$marker")" = "3.6" ]'         "cpu_limit is recorded as a string"
assert '[ "$(jq -r .mem_limit <<<"$marker")" = "7g" ]'          "mem_limit is recorded with its unit"
assert '[ "$(jq -r .backup.enabled <<<"$marker")" = "false" ]'  "backup is off until Phase 8 builds it"
assert '[ "$marker" = "$(drive marker 0.1.0 /apps /apps/data 3.6 7g)" ]' \
    "two renders are byte-identical — the marker is what a re-run compares against"
odd=$(drive marker 0.1.0 '/srv/a"b' /apps/data 3.6 7g)
assert 'jq -e . >/dev/null <<<"$odd"' "a quote in a path is escaped, not emitted raw (got '$odd')"

# A re-run owns five keys and must leave everything else exactly as it found it:
# Phase 8 puts backup.repo_base in the marker, and a plain init must not be what
# deletes an operator's backup configuration.
existing='{"hosting_version":"0.1.0","apps_path":"/apps","data_path":"/apps/data","cpu_limit":"1.8","mem_limit":"3g","backup":{"enabled":true,"repo_base":"s3:https://example/hosting-backups"},"future_key":{"kept":[1,2]}}'
merged=$(drive marker 0.2.0 /apps /apps/data 3.6 7g "$existing")
assert 'jq -e . >/dev/null <<<"$merged"'                          "a merged marker is valid JSON (got '$merged')"
assert '[ "$(jq -r .hosting_version <<<"$merged")" = "0.2.0" ]'   "the writing tool's version wins"
assert '[ "$(jq -r .cpu_limit <<<"$merged")" = "3.6" ]'           "recomputed limits win"
assert '[ "$(jq -r .backup.enabled <<<"$merged")" = "true" ]'     "an enabled backup is not switched off by a re-run"
assert '[ "$(jq -r .backup.repo_base <<<"$merged")" = "s3:https://example/hosting-backups" ]' \
    "backup.repo_base survives a re-run (got '$(jq -c .backup <<<"$merged")')"
assert '[ "$(jq -c .future_key <<<"$merged")" = "{\"kept\":[1,2]}" ]' \
    "a key this hosting has never heard of survives a re-run"
same=$(drive marker 0.1.0 /apps /apps/data 3.6 7g "$(drive marker 0.1.0 /apps /apps/data 3.6 7g)")
assert '[ "$same" = "$(drive marker 0.1.0 /apps /apps/data 3.6 7g)" ]' \
    "merging a marker into itself is a no-op, byte for byte — that is what makes a re-run idempotent"

# --- Marker compatibility -----------------------------------------------------
# docs/server-setup.md: a hosting binary operates on a VPS whose marker shares
# its major version. HOSTING_VERSION is 9.9.9-test here.
assert '[ "$(drive compat no "")" = "compat=ok" ]'                              "no marker is the ordinary case"
assert '[ "$(drive compat yes "$(drive marker 9.0.1 /apps /apps/data 1.8 3g)")" = "compat=ok" ]' \
    "a marker of the same major is accepted"
compat_reject() {
    local desc="$1" want="$2" doc="$3"
    local o r e
    o=$(drive compat yes "$doc"); r=$?
    e=$(drive_err)
    assert '[ "$r" != "0" ]'             "$desc is refused (exit $r, printed '$o')"
    assert 'grep -qF -- "$want" <<<"$e"' "$desc is diagnosed with '$want' (said: $e)"
}
compat_reject "a marker from a newer major" "10.0.0" \
    "$(drive marker 10.0.0 /apps /apps/data 1.8 3g)"
compat_reject "a marker that is not JSON"   "not a JSON object" "{oops"
compat_reject "a marker that is not an object" "not a JSON object" '["/apps"]'
# A marker that exists and holds nothing is a marker, not an absence: the file
# is there, so overwriting it is the same decision as overwriting a corrupt one.
compat_reject "a marker file that is empty" "not a JSON object" ""
compat_reject "a marker file of whitespace" "not a JSON object" "   "
out=$(drive compat yes '{"apps_path":"/apps"}'); rc=$?
assert '[ "$rc" = "0" ]' "a marker with no version is not fatal (exit $rc)"
assert 'grep -qF "cannot be compared" "$tmpdir/err"' \
    "but it says the check could not be made (said '$(drive_err)')"

# --- Elevation decision -------------------------------------------------------
# One condition, and one only. Every other state of the apps path is a preflight
# refusal below: chowning a directory hosting did not create would hand somebody
# else's /var/www to the deploy user and leave its contents in mixed ownership.
assert '[ "$(drive elevation apps_state=absent)" = "elevate=yes" ]' \
    "a missing apps path needs root to create it"
assert '[ "$(drive elevation apps_state=dir apps_owned=yes apps_writable=yes)" = "elevate=no" ]' \
    "an apps path already owned by the deploy user is never elevated over"
assert '[ "$(drive elevation apps_state=dir apps_owned=no apps_writable=no)" = "elevate=no" ]' \
    "an apps path owned by somebody else is never elevated over either — it is refused, not seized"
assert '[ "$(drive elevation apps_state=notdir)" = "elevate=no" ]' \
    "a non-directory at the apps path is never elevated over"
assert '[ "$(drive elevation apps_state=dangling)" = "elevate=no" ]' \
    "a dangling symlink at the apps path is never elevated over"
# The state that reads as absent to the deploy user and exists to root. The
# probe resolves it to `unreachable` precisely so this decision cannot be made
# on the deploy user's view of a path the chown would touch as root.
assert '[ "$(drive elevation apps_state=unreachable apps_root_state=exists apps_root_owner=root:root)" = "elevate=no" ]' \
    "a path only root can see is never elevated over — that is the seizure"

# --- Prerequisite verdicts ----------------------------------------------------
laid_out=(apps_state=dir apps_owned=yes apps_writable=yes data_state=dir data_writable=yes)
out=$(drive preflight "${laid_out[@]}"); rc=$?
assert '[ "$rc" = "0" ] && [ "$out" = "preflight=ok" ]' \
    "a host that meets every row passes (exit $rc: $out $(drive_err))"

# The rows the rig cannot be made to fail without damaging it.
row() {
    local desc="$1" want="$2"; shift 2
    local o r e
    o=$(drive preflight "$@"); r=$?
    e=$(drive_err)
    assert '[ "$r" != "0" ]'             "$desc fails preflight (exit $r, printed '$o')"
    assert 'grep -qF -- "$want" <<<"$e"' "$desc is diagnosed with '$want' (said: $e)"
}
row "no docker at all"        "https://docs.docker.com/engine/install/" have_docker=no docker_server=
row "docker 23"               "Docker >= 24"           docker_server=23.0.6
row "a docker version that is not a number" "Docker >= 24" docker_server=nightly
row "a daemon out of reach"   "usermod -aG docker"     docker_server= docker_error="permission denied while trying to connect"
row "no compose plugin"       "Docker Compose v2"      compose_version=
row "compose v1"              "Docker Compose v2"      compose_version=1.29.2
row "a compose version that is not a number" "Docker Compose v2" compose_version=edge
row "no rsync"                "rsync is missing"       have_rsync=no
row "no openssl"              "openssl is missing"     have_openssl=no
row "no gzip"                 "gzip is missing"        have_gzip=no
row "an unreadable core count" "nproc="                nproc=
row "an unreadable MemTotal"   "MemTotal="             memtotal_kb=

# The apps path, in every state but the two hosting acts on.
row "a sudo that would prompt" "sudo mkdir -p /apps && sudo chown deploy:deploy /apps" sudo_nopasswd=no
row "an apps path that is a file" "/apps exists and is not a directory" apps_state=notdir
row "an apps path that dangles"   "/apps is a symlink to nothing"       apps_state=dangling
row "an apps path owned by somebody else" "sudo chown deploy:deploy /apps" \
    apps_state=dir apps_owned=no apps_writable=no apps_owner=root:root
row "an apps path owned by somebody else, world-writable" "belongs to root:root, not deploy" \
    apps_state=dir apps_owned=no apps_writable=yes apps_owner=root:root
row "an apps path the deploy user owns but cannot write" "chmod u+rwx /apps" \
    apps_state=dir apps_owned=yes apps_writable=no \
    apps_write_error="touch: cannot touch '/apps/.hosting-write-probe': Permission denied"
# The same -w, wanting the opposite advice: no chmod fixes a read-only mount.
row "an apps path on a read-only filesystem" "read-only filesystem" \
    apps_state=dir apps_owned=yes apps_writable=no \
    apps_write_error="touch: cannot touch '/apps/.hosting-write-probe': Read-only file system"
out=$(drive preflight apps_state=dir apps_owned=yes apps_writable=no \
    apps_write_error="touch: cannot touch '/apps/.hosting-write-probe': Read-only file system")
assert '! grep -qF "chmod u+rwx" "$tmpdir/err"' \
    "and it does not prescribe a chmod that cannot work (said '$(drive_err)')"

# The apps path the deploy user cannot see. Root can, and root is who would run
# the chown — so the state is asked for a second time before elevating, and the
# refusal quotes the owner root reported.
row "an apps path only root can see" "belongs to root:root, and deploy cannot see it" \
    apps_state=unreachable apps_root_state=exists apps_root_owner=root:root
row "an apps path behind a wall" "/root is not traversable by them (owner root:root, mode 700)" \
    apps_state=unreachable apps_root_state=absent apps_base=/root \
    apps_base_owner=root:root apps_base_mode=700

# The data path, which is created unelevated and therefore has to be reachable.
row "a data path that is a file"   "/apps/data exists and is not a directory" \
    "${laid_out[@]}" data_state=notdir
row "a data path that dangles"     "/apps/data is a symlink to nothing" \
    "${laid_out[@]}" data_state=dangling
row "a data path owned by somebody else" "sudo chown deploy:deploy /apps/data" \
    "${laid_out[@]}" data_state=dir data_writable=no data_owner=root:root
row "a data path under an unwritable parent" "/srv is not writable by deploy" \
    "${laid_out[@]}" data_state=absent data_scope=outside data_base=/srv data_base_writable=no

# Compose 5.4.0 is what the rig reports (docs/phases/01-rig.md): the row is a
# floor, and a `== 2` reading of it would fail every modern host.
assert '[ "$(drive preflight "${laid_out[@]}" compose_version=5.4.0)" = "preflight=ok" ]' \
    "compose 5.4.0 passes the v2 row — the check is major >= 2, not == 2"
assert '[ "$(drive preflight "${laid_out[@]}" compose_version=v2.29.7 docker_server=v27.3.1)" = "preflight=ok" ]' \
    "a leading v on either version is tolerated, not read as 'not a number'"

# Sudo is a prerequisite only for creating the apps path; a server already laid
# out must not start demanding it.
assert '[ "$(drive preflight "${laid_out[@]}" sudo_nopasswd=no)" = "preflight=ok" ]' \
    "sudo is not required once the apps path is the deploy user's"
assert '[ "$(drive preflight "${laid_out[@]}" data_state=absent data_scope=inside data_base_writable=no)" = "preflight=ok" ]' \
    "a data path below the apps path needs no parent of its own"

# Every failing row at once, so a three-row-short host costs one round trip.
out=$(drive preflight have_rsync=no have_gzip=no compose_version=)
err_out=$(drive_err)
assert 'grep -qF "rsync is missing" <<<"$err_out" && grep -qF "gzip is missing" <<<"$err_out" && grep -qF "Docker Compose v2" <<<"$err_out"' \
    "all failing rows are reported together (said: $err_out)"

# --- The Traefik stack: rendering ---------------------------------------------
# A real bcrypt entry, so the `$` handling is exercised by the thing that
# actually carries dollars. Single `$`, never `$$`: _shared.yml is read by
# Traefik, not interpolated by compose.
hash_admin='admin:$2y$05$/HFtyMw8JsZ/43mgOXgq9uHlaDgqGw3FQiCw9s7m80LjXU9jh.wpe'
out_dir="$tmpdir/rendered"
mkdir -p "$out_dir"
modes=$(RENDER_OUT="$out_dir" drive render /srv/apps /mnt/vol1 ops@example.com example.com "$hash_admin"); rc=$?
assert '[ "$rc" = "0" ]' "the Traefik templates render (exit $rc: $(drive_err))"

compose="$out_dir/compose.yml"
static="$out_dir/traefik.yml"
shared="$out_dir/dynamic/_shared.yml"
assert '[ -f "$compose" ] && [ -f "$static" ] && [ -f "$shared" ]' \
    "all three files land, keeping their paths (got '$(cd "$out_dir" && find . -type f | sort | tr "\n" " ")')"
assert '[ "$(tr -d "\n" <<<"$modes" )" = "644 compose.yml644 traefik.yml644 dynamic/_shared.yml" ]' \
    "each rendered file is mode 644, whatever the operator's umask (got '$modes')"
for f in "$compose" "$static" "$shared"; do
    assert 'yq -e . "$f" >/dev/null 2>&1' "$(basename "$f") parses as YAML"
    assert '! grep -qE "__[A-Z0-9_]+__" "$f"' \
        "$(basename "$f") carries no surviving placeholder ($(grep -oE "__[A-Z0-9_]+__" "$f" | head -1))"
done

# The guard that makes the line above worth having: a template with a token the
# renderer knows nothing about must be a hard failure, not a file shipped with
# a literal placeholder in it.
bad_tpl="$tmpdir/badtpl"
mkdir -p "$bad_tpl/traefik/dynamic"
cp "$repo_dir/templates/traefik/traefik.yml" "$bad_tpl/traefik/traefik.yml"
cp "$repo_dir/templates/traefik/dynamic/_shared.yml" "$bad_tpl/traefik/dynamic/_shared.yml"
sed 's|image: traefik:.*|image: "__NOPE__"|' "$repo_dir/templates/traefik/compose.yml" \
    > "$bad_tpl/traefik/compose.yml"
out=$(HOSTING_TEMPLATE_DIR="$bad_tpl" drive render /apps /apps/data a@b.c example.com "$hash_admin"); rc=$?
assert '[ "$rc" != "0" ]' "an unsubstituted placeholder is a hard failure (exit $rc, printed '$out')"
assert 'grep -qF "__NOPE__" "$tmpdir/err"' \
    "and the failure names the token that survived (said '$(drive_err)')"
assert 'grep -qF "compose.yml" "$tmpdir/err"' "and the file it survived in (said '$(drive_err)')"

out=$(HOSTING_TEMPLATE_DIR="$tmpdir/not-there" drive render /apps /apps/data a@b.c example.com x); rc=$?
assert '[ "$rc" != "0" ]' "a hosting with no templates fails rather than shipping nothing (exit $rc)"
assert 'grep -qF "installation is incomplete" "$tmpdir/err"' \
    "and says the installation is incomplete (said '$(drive_err)')"

# A token in an operator's *value* is not hosting's templates being out of step,
# and must not be reported as one. It is also never re-scanned: __APPS_PATH__
# inside the data path comes back verbatim rather than expanded.
mkdir -p "$tmpdir/stage"
out=$(RENDER_OUT="$tmpdir/stage" drive render '/apps/__STAGE__' '/data/__APPS_PATH__' a@b.c example.com "$hash_admin"); rc=$?
stage_vols=$(yq -r '.services.traefik.volumes | join(" ")' "$tmpdir/stage/compose.yml" 2>/dev/null)
assert '[ "$rc" = "0" ]' \
    "a path carrying hosting's own token syntax renders rather than being blamed on the templates (exit $rc: $(drive_err))"
assert 'grep -qF "/apps/__STAGE__/traefik/traefik.yml" <<<"$stage_vols"' \
    "the operator's path is substituted in as written (got '$stage_vols')"
assert 'grep -qF "/data/__APPS_PATH__/traefik/letsencrypt" <<<"$stage_vols"' \
    "and a value that looks like another token is not expanded a second time (got '$stage_vols')"

# The guarantee behind the input checks: whatever gets in — a hand-edited rule
# on the server is read back and re-rendered without ever passing a validator —
# nothing that fails to parse reaches the far side.
out=$(drive render /apps /apps/data ops@example.com 'ex"ample.com' "$hash_admin"); rc=$?
assert '[ "$rc" != "0" ]' \
    "a quote arriving from the server rather than the command line is still caught (exit $rc, printed '$out')"
assert 'grep -qF "is not valid YAML" "$tmpdir/err"' \
    "by parsing the rendered file before shipping it (said '$(drive_err)')"
assert 'grep -qF "dynamic/_shared.yml" "$tmpdir/err"' "naming the file that broke"
assert 'grep -qF "refusing to ship it" "$tmpdir/err"' "and saying it went nowhere"

# --- compose.yml --------------------------------------------------------------
assert '[ "$(yq -r ".services.traefik.image" "$compose")" = "traefik:v3.7.10" ]' \
    "Traefik is pinned to an exact v3 tag (got '$(yq -r ".services.traefik.image" "$compose")')"
assert '[[ "$(yq -r ".services.traefik.image" "$compose")" =~ ^traefik:v3\.[0-9]+\.[0-9]+$ ]]' \
    "the pin is a full version, never a moving tag"
assert '[ "$(yq -r "has(\"version\")" "$compose")" = "false" ]' \
    "no deprecated version: attribute (C05)"
assert '[ "$(yq -r ".services.traefik.restart" "$compose")" = "unless-stopped" ]' \
    "restart: unless-stopped, as hosting check demands of every service (C01)"
assert '[ "$(yq -r ".services.traefik.logging.driver" "$compose")" = "json-file" ]' \
    "json-file logging (C02)"
assert '[ "$(yq -r ".services.traefik.logging.options[\"max-size\"]" "$compose")" != "null" ] \
        && [ "$(yq -r ".services.traefik.logging.options[\"max-file\"]" "$compose")" != "null" ]' \
    "with both rotation knobs set (C02)"
assert '[ "$(yq -r ".networks[\"hosting-net\"].name" "$compose")" = "hosting-net" ]' \
    "the network is named hosting-net — a frozen contract every project fragment depends on"
assert '[ "$(yq -r ".networks[\"hosting-net\"].driver" "$compose")" = "bridge" ]' \
    "and is a bridge (got '$(yq -r ".networks[\"hosting-net\"].driver" "$compose")')"
assert '[ "$(yq -r ".services.traefik.networks | join(\",\")" "$compose")" = "hosting-net" ]' \
    "Traefik itself joins it"
assert '[ "$(yq -r ".services.traefik.ports | join(\",\")" "$compose")" = "80:80,443:443" ]' \
    "it binds 80 and 443 (got '$(yq -r ".services.traefik.ports | join(\",\")" "$compose")')"
assert '[ "$(yq -r ".services.traefik.healthcheck.test | join(\" \")" "$compose")" = "CMD traefik healthcheck --ping" ]' \
    "the healthcheck is traefik healthcheck --ping (got '$(yq -r ".services.traefik.healthcheck.test | join(\" \")" "$compose")')"

# The one mount that must never exist. The positive control on the next line is
# what stops this from passing against an empty volume list.
volumes=$(yq -r '.services.traefik.volumes | join("\n")' "$compose")
assert '! grep -qF "docker.sock" <<<"$volumes"' \
    "no docker socket is mounted — the docker provider is not wired in (got '$volumes')"
assert 'grep -qF "/srv/apps/traefik/traefik.yml:/etc/traefik/traefik.yml:ro" <<<"$volumes"' \
    "the static config is mounted read-only from the apps path (got '$volumes')"
assert 'grep -qF "/srv/apps/traefik/dynamic:/etc/traefik/dynamic:ro" <<<"$volumes"' \
    "the dynamic directory is mounted read-only (got '$volumes')"
assert 'grep -qF "/mnt/vol1/traefik/letsencrypt/acme.json:/letsencrypt/acme.json" <<<"$volumes"' \
    "acme.json comes from the data path, writable (got '$volumes')"

# Deliberate: the anti-takeover ceilings exist so a project cannot lock Traefik
# out, and capping the ingress protects nothing it is not already the victim of.
assert '[ "$(yq -r ".services.traefik.cpus // \"none\"" "$compose")" = "none" ]' \
    "Traefik declares no cpus ceiling — R01-R03 govern project compose files, not this one"
assert '[ "$(yq -r ".services.traefik.mem_limit // \"none\"" "$compose")" = "none" ]' \
    "nor a mem_limit"

# --- traefik.yml --------------------------------------------------------------
assert '[ "$(yq -r ".entryPoints.web.address" "$static")" = ":80" ]'        "entrypoint web is :80"
assert '[ "$(yq -r ".entryPoints.websecure.address" "$static")" = ":443" ]' "entrypoint websecure is :443"
assert '[ "$(yq -r ".entryPoints.websecure.http.tls.options" "$static")" = "default" ]' \
    "websecure defaults to the 'default' TLS options declared in _shared.yml"
assert '[ "$(yq -r ".providers.file.directory" "$static")" = "/etc/traefik/dynamic" ]' \
    "the file provider watches the mounted dynamic directory"
assert '[ "$(yq -r ".providers.file.watch" "$static")" = "true" ]' \
    "and watches it live — a fragment must land without a restart"
assert '[ "$(yq -r ".providers | has(\"docker\")" "$static")" = "false" ]' \
    "the docker provider is not wired in at all"
assert '[ "$(yq -r ".certificatesResolvers.letsencrypt.acme.email" "$static")" = "ops@example.com" ]' \
    "the ACME email is baked in, because Traefik expands no env vars here"
assert '[ "$(yq -r ".certificatesResolvers.letsencrypt.acme.storage" "$static")" = "/letsencrypt/acme.json" ]' \
    "ACME storage is the mounted acme.json"
assert '[ "$(yq -r ".certificatesResolvers.letsencrypt.acme.httpChallenge.entryPoint" "$static")" = "web" ]' \
    "HTTP-01 is answered on web"
assert '[ "$(yq -r ".api.dashboard" "$static")" = "true" ]'   "the dashboard is enabled"
assert '[ "$(yq -r ".api.insecure // false" "$static")" = "false" ]' \
    "but never on the insecure API entrypoint"
assert '[ "$(yq -r ".ping.entryPoint" "$static")" = "web" ]'  "ping answers on web, which is what the healthcheck talks to"
assert '[ "$(yq -r ".log.level" "$static")" = "INFO" ]'       "log level INFO"
assert '[ "$(yq -r ".global.checkNewVersion" "$static")" = "false" ]'    "no version check"
assert '[ "$(yq -r ".global.sendAnonymousUsage" "$static")" = "false" ]' "no anonymous usage reporting"

# --- dynamic/_shared.yml ------------------------------------------------------
# The frozen names. A project fragment references each one as <name>@file, so a
# rename here breaks every deployed project on every server.
for mw in http-to-https http-www-to-https-non-www https-www-to-https-non-www \
          security-headers gzip-compression api-rate-limit; do
    assert '[ "$(yq -r ".http.middlewares | has(\"$mw\")" "$shared")" = "true" ]' \
        "_shared.yml defines the frozen middleware $mw"
done
assert '[ "$(yq -r ".http.middlewares[\"api-rate-limit\"].rateLimit.average" "$shared")" = "50" ]' \
    "api-rate-limit averages 50/s"
assert '[ "$(yq -r ".http.middlewares[\"api-rate-limit\"].rateLimit.burst" "$shared")" = "100" ]' \
    "and bursts to 100"
assert '[ "$(yq -r ".http.middlewares[\"http-to-https\"].redirectScheme.scheme" "$shared")" = "https" ]' \
    "http-to-https redirects to https"
assert '[ "$(yq -r ".http.middlewares[\"security-headers\"].headers.frameDeny" "$shared")" = "true" ]' \
    "security-headers denies framing"
assert '[ "$(yq -r ".http.middlewares[\"security-headers\"].headers | has(\"contentSecurityPolicyReportOnly\")" "$shared")" = "true" ]' \
    "and carries a CSP that only reports"

# The TLS options traefik.yml points websecure at. Without this block every
# HTTPS router fails to start, which is why it is asserted and not assumed.
assert '[ "$(yq -r ".tls.options | has(\"default\")" "$shared")" = "true" ]' \
    "_shared.yml declares the 'default' TLS options websecure references"
assert '[ "$(yq -r ".tls.options.default.minVersion" "$shared")" = "VersionTLS12" ]' "TLS 1.2 floor"
assert '[ "$(yq -r ".tls.options.default.maxVersion" "$shared")" = "VersionTLS13" ]' "TLS 1.3 ceiling"
assert '[ "$(yq -r ".tls.options.default.cipherSuites | length" "$shared")" -ge 4 ]' \
    "with a modern cipher list (got $(yq -r ".tls.options.default.cipherSuites | length" "$shared") suites)"

router='.http.routers["traefik-dashboard"]'
assert '[ "$(yq -r "$router.rule" "$shared")" = "Host(\`traefik.example.com\`)" ]' \
    "the dashboard hangs off traefik.<domain> (got '$(yq -r "$router.rule" "$shared")')"
assert '[ "$(yq -r "$router.entryPoints | join(\",\")" "$shared")" = "websecure" ]' "on websecure only"
assert '[ "$(yq -r "$router.tls.certResolver" "$shared")" = "letsencrypt" ]' \
    "with the letsencrypt resolver — a frozen name"
assert '[ "$(yq -r "$router.service" "$shared")" = "api@internal" ]' "served by api@internal"
assert '[ "$(yq -r "$router.middlewares | length" "$shared")" -ge 1 ]' "behind at least one middleware"
auth_mw=$(yq -r "$router.middlewares[0]" "$shared")
assert '[ "$(yq -r ".http.middlewares[\"$auth_mw\"].basicAuth.users[0]" "$shared")" = "$hash_admin" ]' \
    "which is basic auth carrying the bcrypt entry verbatim (got '$(yq -r ".http.middlewares[\"$auth_mw\"].basicAuth.users[0]" "$shared")')"

# 02-spine.md's original warning had this backwards. A single \$ is correct in a
# file Traefik parses; \$\$ only governs a value that lands in a
# compose-interpolated .env, and this stack has none.
assert 'grep -qF "\$2y\$05\$" "$shared"' "the hash keeps its single dollars (got '$(grep -o "2y.\{0,4\}" "$shared")')"
assert '! grep -qF "\$\$" "$shared"'     "and nothing in _shared.yml is dollar-doubled"

# --- Where the Traefik values come from ---------------------------------------
# Flag beats server, server beats prompt. The middle rule is what makes a
# re-run a no-op: bcrypt salts randomly, so re-hashing the same password would
# rewrite _shared.yml every single time.
stored_shared=$(cat "$shared")
stored_static=$(cat "$static")

out=$(drive values "$stored_shared" "$stored_static"); rc=$?
assert '[ "$rc" = "0" ]' "a re-run against a rendered server needs no flags at all (exit $rc: $(drive_err))"
assert 'grep -qxF "domain=example.com" <<<"$out"' "the domain is read back off the server (got '$out')"
assert 'grep -qxF "email=ops@example.com" <<<"$out"' "so is the ACME email (got '$out')"
assert 'grep -qxF "auth=$hash_admin" <<<"$out"' \
    "and the stored hash is reused byte for byte, not regenerated (got '$out')"
assert 'grep -qxF "origin=reused" <<<"$out"' "which the run reports as reuse (got '$out')"

out=$(drive values "$stored_shared" "$stored_static" --traefik-auth=admin:other); rc=$?
assert '[ "$rc" = "0" ]' "an explicit --traefik-auth is accepted on a re-run (exit $rc: $(drive_err))"
assert '! grep -qF "$hash_admin" <<<"$out"' "and re-hashes rather than reusing (got '$out')"
assert 'grep -qxF "origin=flag" <<<"$out"'  "reported as coming from the flag (got '$out')"

out=$(drive values "$stored_shared" "$stored_static" --domain=other.example --email=new@example.com)
assert 'grep -qxF "domain=other.example" <<<"$out"' "a --domain overrides what the server has (got '$out')"
assert 'grep -qxF "email=new@example.com" <<<"$out"' "so does an --email (got '$out')"
assert 'grep -qxF "auth=$hash_admin" <<<"$out"' "while the credentials are still reused (got '$out')"

# Nothing stored and no flag: the tri-state rule, with stdin not a terminal.
out=$(drive values "" "" --email=a@b.c --traefik-auth=u:p); rc=$?
assert '[ "$rc" != "0" ]' "a bare server with no --domain and no terminal is a hard fail (exit $rc)"
assert 'grep -qF -- "--domain=<value>" "$tmpdir/err"' \
    "naming the flag that would answer it (said '$(drive_err)')"
out=$(drive values "" "" --domain=example.com --traefik-auth=u:p); rc=$?
assert '[ "$rc" != "0" ]' "likewise a missing --email (exit $rc)"
assert 'grep -qF -- "--email=<value>" "$tmpdir/err"' "naming --email (said '$(drive_err)')"
out=$(drive values "" "" --domain=example.com --email=a@b.c); rc=$?
assert '[ "$rc" != "0" ]' "likewise missing dashboard credentials (exit $rc)"
assert 'grep -qF -- "--traefik-auth=<value>" "$tmpdir/err"' "naming --traefik-auth (said '$(drive_err)')"

out=$(drive values "" "" --domain=example.com --email=a@b.c --traefik-auth=admin:pw); rc=$?
assert '[ "$rc" = "0" ]' "all three flags on a bare server is enough (exit $rc: $(drive_err))"
assert 'grep -qxF "origin=flag" <<<"$out"' "and the credentials come from the flag (got '$out')"

# The extractors on their own, against shapes an operator's editor produces.
extract() { printf '%s' "$2" | drive_stdin extract "$1"; }

assert '[ "$(extract auth "$stored_shared")" = "$hash_admin" ]' \
    "the hash is found in hosting's own output"
crlf=$(printf 'http:\r\n  middlewares:\r\n    traefik-dashboard-auth:\r\n      basicAuth:\r\n        users:\r\n          - "bob:$2b$12$abcdefghijklmnopqrstuv"\r\n')
assert '[ "$(extract auth "$crlf")" = "bob:\$2b\$12\$abcdefghijklmnopqrstuv" ]' \
    "and in a file saved with CRLF line endings (got '$(extract auth "$crlf")')"
inline=$(printf 'http:\n  middlewares:\n    traefik-dashboard-auth:\n      basicAuth:\n        users: ["bob:$2y$05$inlineinlineinlineinl"]\n')
assert '[ "$(extract auth "$inline")" = "bob:\$2y\$05\$inlineinlineinlineinl" ]' \
    "and written as an inline list, which is the same YAML (got '$(extract auth "$inline")')"
assert '[ -z "$(extract auth "no hash here")" ]' \
    "a file with no entry yields nothing rather than a plausible-looking one"

# The reported bug: docs/traefik.md invites operators to add middlewares under
# dynamic/, and one of theirs carrying a basicAuth must never be mistaken for
# the dashboard's. `admin-area-auth` sorts first and appears first in the file —
# both of the things a scan would go by.
competing=$(printf 'http:\n  middlewares:\n    admin-area-auth:\n      basicAuth:\n        users:\n          - "someoneelse:$2y$05$THEIRSTHEIRSTHEIRSTHE"\n    traefik-dashboard-auth:\n      basicAuth:\n        users:\n          - "dash:$2y$05$OURSOURSOURSOURSOURSO"\n')
assert '[ "$(extract auth "$competing")" = "dash:\$2y\$05\$OURSOURSOURSOURSOURSO" ]' \
    "an operator's own basicAuth sorting first is not adopted as the dashboard's (got '$(extract auth "$competing")')"
assert '[ -z "$(extract auth "$(printf "http:\n  middlewares:\n    admin-area-auth:\n      basicAuth:\n        users:\n          - \"someoneelse:\$2y\$05\$THEIRS\"\n")")" ]' \
    "and with no dashboard middleware at all, nothing is reused rather than somebody else's"

# users present but holding something that is not an htpasswd entry: reusing it
# verbatim is the contract, and there is nothing here to reuse.
junk=$(printf 'http:\n  middlewares:\n    traefik-dashboard-auth:\n      basicAuth:\n        users:\n          - notanentry\n')
out=$(extract auth "$junk"); rc=$?
assert '[ "$rc" != "0" ]' "an unusable dashboard entry is a refusal, not a silent regeneration (exit $rc, printed '$out')"
assert 'grep -qF "not an htpasswd entry" "$tmpdir/err"' "which says what it found (said '$(drive_err)')"
assert 'grep -qF -- "--traefik-auth=user:pass" "$tmpdir/err"' "and how to settle it"

assert '[ "$(extract domain "$stored_shared")" = "example.com" ]' \
    "the dashboard domain is read back out of the rule"
assert '[ -z "$(extract domain "$stored_static")" ]' \
    "and is not invented from the static config, which has no rule in it"
assert '[ "$(extract email "$stored_static")" = "ops@example.com" ]' \
    "the ACME email is read back out of the static config"

# A file hosting cannot parse is not a file it may quietly replace: the value it
# would invent is the dashboard password.
broken=$(printf 'http:\n  middlewares:\n   bad indentation: [\n')
out=$(drive values "$broken" "$stored_static"); rc=$?
assert '[ "$rc" != "0" ]' "an unreadable _shared.yml stops the run (exit $rc, printed '$out')"
assert 'grep -qF "could not be read as YAML" "$tmpdir/err"' "saying so (said '$(drive_err)')"
assert 'grep -qF "dynamic/_shared.yml" "$tmpdir/err"'       "and naming the file"
out=$(drive values "$broken" "$stored_static" --domain=example.com --traefik-auth=admin:pw); rc=$?
assert '[ "$rc" = "0" ]' \
    "but not when the flags already settle everything it would have read (exit $rc: $(drive_err))"
out=$(drive values "$stored_shared" "$(printf 'certificatesResolvers: [\n')"); rc=$?
assert '[ "$rc" != "0" ]' "the same for an unreadable traefik.yml (exit $rc)"
assert 'grep -qF -- "--email=" "$tmpdir/err"' "naming the flag that settles it (said '$(drive_err)')"

# --- What ships, and what forces a restart ------------------------------------
# docs/server-setup.md: Traefik is restarted only if the static config changed.
out=$(drive sync compose.yml,traefik.yml,dynamic/_shared.yml); rc=$?
err_out=$(drive_err)
assert '[ "$rc" = "0" ]' "sync runs when nothing differs (exit $rc: $err_out)"
assert 'grep -qxF "changed=" <<<"$out"'    "an unchanged stack ships nothing (got '$out')"
assert 'grep -qxF "restart=no" <<<"$out"'  "and does not restart Traefik (got '$out')"
assert '! grep -qF "rsync->" <<<"$err_out"' "rsync is not even invoked (said '$err_out')"

out=$(drive sync compose.yml,traefik.yml); err_out=$(drive_err)
assert 'grep -qxF "changed=dynamic/_shared.yml" <<<"$out"' \
    "a changed fragment ships on its own (got '$out')"
assert 'grep -qxF "restart=no" <<<"$out"' \
    "and never restarts Traefik — the file provider watches it (got '$out')"
assert 'grep -qF "rsync->deploy@vps:/apps/traefik/dynamic/_shared.yml" <<<"$err_out"' \
    "landing in the watched directory (said '$err_out')"

out=$(drive sync compose.yml,dynamic/_shared.yml); err_out=$(drive_err)
assert 'grep -qxF "changed=traefik.yml" <<<"$out"' "a changed static config ships (got '$out')"
assert 'grep -qxF "restart=yes" <<<"$out"' \
    "and is the one change that forces a restart — Traefik reads it once, at startup (got '$out')"
assert 'grep -qF "rsync->deploy@vps:/apps/traefik/traefik.yml" <<<"$err_out"' \
    "to the apps path (said '$err_out')"

out=$(drive sync traefik.yml,dynamic/_shared.yml)
assert 'grep -qxF "changed=compose.yml" <<<"$out"' "a changed compose.yml ships (got '$out')"
assert 'grep -qxF "restart=no" <<<"$out"' \
    "without an explicit restart — a changed service definition is what up -d recreates (got '$out')"

out=$(drive sync ''); err_out=$(drive_err)
assert 'grep -qxF "changed=compose.yml traefik.yml dynamic/_shared.yml" <<<"$out"' \
    "a bare server ships all three (got '$out')"
assert '[ "$(grep -c "rsync->" <<<"$err_out")" = "3" ]' \
    "in three rsync calls (said '$err_out')"

# --- The command line, through bin/hosting ------------------------------------
# The two exports above are for the driver, which sources the libraries
# directly. bin/hosting must not see them: it takes VERSION from beside
# HOSTING_LIB_DIR, and a checkout has no lib/VERSION.
#
# A recording ssh goes first on PATH, and every case below asserts its log is
# empty. That is what makes "the question is asked before anything is opened" an
# assertion rather than a hope: without the stub these runs reach the real ssh,
# spend a DNS lookup on a .invalid name, and fail for that instead — so a guard
# that had stopped working would still exit non-zero and the case would still
# pass. tests/deploy_test.sh does it this way for the same reason.
si_stub_dir="$tmpdir/stubbin"
mkdir -p "$si_stub_dir"
si_ssh_log="$tmpdir/ssh.log"
: > "$si_ssh_log"
cat > "$si_stub_dir/ssh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SSH_LOG"
echo "stub ssh: this suite reaches no network" >&2
exit 255
STUB
chmod 0755 "$si_stub_dir/ssh"

run() {
    : > "$si_ssh_log"
    env -u HOSTING_LIB_DIR -u HOSTING_VERSION \
        PATH="$si_stub_dir:$PATH" SSH_LOG="$si_ssh_log" \
        "$hosting" "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null
}

assert '[ "$(PATH="$si_stub_dir:$PATH" command -v ssh)" = "$si_stub_dir/ssh" ]' \
    "the stub ssh shadows any real one for the cases below"

run server; rc=$?
assert '[ "$rc" != "0" ]' "bare \`hosting server\` fails (exit $rc)"
assert 'grep -qF "expected: init" "$tmpdir/err"' \
    "it names the subcommands that exist (said '$(cat "$tmpdir/err")')"

run server --help; rc=$?
assert '[ "$rc" = "0" ]' "\`hosting server --help\` is help, not an unknown subcommand (exit $rc: $(cat "$tmpdir/err"))"
assert 'grep -qF "init USER@HOST" "$tmpdir/out"' "it lists the subcommands (got '$(cat "$tmpdir/out")')"
run server -h; rc=$?
assert '[ "$rc" = "0" ]' "\`hosting server -h\` too (exit $rc)"

run server statsu; rc=$?
assert '[ "$rc" != "0" ]' "an unknown server subcommand fails (exit $rc)"
assert 'grep -qF "unknown subcommand '\''statsu'\''" "$tmpdir/err"' \
    "it names what was typed (said '$(cat "$tmpdir/err")')"

run --help
assert 'grep -qF "server init" "$tmpdir/out"' "usage advertises server init"

# Mail and backup are scaffolded in Phases 7 and 8. Accepting the flag and doing
# nothing would be a lie, so it is a hard failure that names the phase — and the
# refusal comes before the connection, which the empty ssh log is what proves.
run server init deploy@hosting-unit-test.invalid --with-mail --no-backup; rc=$?
assert '[ "$rc" != "0" ]' "--with-mail fails rather than silently skipping mail (exit $rc)"
assert 'grep -qF "Phase 7" "$tmpdir/err"' "--with-mail names the phase that builds it (said '$(cat "$tmpdir/err")')"
assert 'grep -qF -- "--no-mail" "$tmpdir/err"' "--with-mail says how to proceed today"
assert '[ ! -s "$si_ssh_log" ]' "and nothing was contacted first (ssh saw: $(cat "$si_ssh_log"))"

run server init deploy@hosting-unit-test.invalid --no-mail --with-backup; rc=$?
assert '[ "$rc" != "0" ]' "--with-backup fails rather than silently skipping backups (exit $rc)"
assert 'grep -qF "Phase 8" "$tmpdir/err"' "--with-backup names the phase that builds it (said '$(cat "$tmpdir/err")')"
assert 'grep -qF -- "--no-backup" "$tmpdir/err"' "--with-backup says how to proceed today"
assert '[ ! -s "$si_ssh_log" ]' "and nothing was contacted first (ssh saw: $(cat "$si_ssh_log"))"

# The tri-state rule: no flag and no terminal is a hard fail naming the flag,
# never an assumed "no". Nothing is contacted first — and that half matters as
# much as the exit code, because a guard that stopped guarding would still fail
# the run, just further along and against somebody's server.
run server init deploy@hosting-unit-test.invalid; rc=$?
assert '[ "$rc" != "0" ]' "an unanswerable mail question fails (exit $rc)"
assert 'grep -qF -- "--with-mail or --no-mail" "$tmpdir/err"' \
    "the no-TTY failure names both flags (said '$(cat "$tmpdir/err")')"
assert '[ ! -s "$si_ssh_log" ]' \
    "and the unanswered question cost no connection (ssh saw: $(cat "$si_ssh_log"))"

run server init deploy@hosting-unit-test.invalid --no-mail; rc=$?
assert '[ "$rc" != "0" ]' "an unanswerable backup question fails (exit $rc)"
assert 'grep -qF -- "--with-backup or --no-backup" "$tmpdir/err"' \
    "the no-TTY failure names the backup flags (said '$(cat "$tmpdir/err")')"
assert '[ ! -s "$si_ssh_log" ]' \
    "and the unanswered question cost no connection (ssh saw: $(cat "$si_ssh_log"))"

# The positive control: with both questions answered the command does reach the
# transport, so the four empty logs above are about the guards and not about a
# stub that was never on PATH.
run server init deploy@hosting-unit-test.invalid --no-mail --no-backup; rc=$?
assert '[ "$rc" = "3" ]' "an answered init goes on to the server, and this one is unreachable (exit $rc: $(cat "$tmpdir/err"))"
assert '[ -s "$si_ssh_log" ]' "and the stub ssh is what it reached (ssh saw: $(cat "$si_ssh_log"))"

# A target carrying a Windows line ending is the same target. ssh_target_parse
# strips it too, but only once a connection is being made: everything this
# command prints first — the two questions among them — reads _SI_TARGET
# directly, and a carriage return in the middle of a prompt overwrites the line
# the operator is being asked to answer.
run server init "$(printf 'deploy@hosting-unit-test.invalid\r')"
assert '! grep -qU $'"'"'\r'"'"' "$tmpdir/err"' \
    "a CRLF target carries no carriage return into the prompt (said '$(cat -v "$tmpdir/err")')"
assert 'grep -qF "on deploy@hosting-unit-test.invalid?" "$tmpdir/err"' \
    "and the question names the target it would act on (said '$(cat "$tmpdir/err")')"

exit "$fail"
