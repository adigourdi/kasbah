#!/usr/bin/env bash
# Test: lib/server_init.sh — everything about `kasbah server init` that does
# not need a server. Flag parsing, the limit formatter, the marker, and the
# prerequisite verdicts, which are driven from a synthetic fact set so that
# rows the rig cannot break (an old daemon, a sudo that prompts) are still
# covered. The rig-driven half lives in tests/integration/server_init_test.sh.

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
# The library's own functions, called the way cmd_server_init calls them. The
# fact set below is a host that passes every prerequisite row; each case
# overrides only what it means to break, so a row that stops being checked shows
# up as one failing case rather than a suite that quietly proves nothing.
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
        printf 'target=%s\napps=%s\ndata=%s\nmail=%s\nbackup=%s\n' \
            "$_SI_TARGET" "$_SI_APPS_PATH" "$_SI_DATA_PATH" \
            "${_SI_MAIL:-unset}" "${_SI_BACKUP:-unset}"
        printf 'domain=%s\nemail=%s\nauth=%s\n' \
            "${_SI_DOMAIN:-unset}" "${_SI_EMAIL:-unset}" "${_SI_AUTH:-unset}"
        printf 'staging=%s\nyes=%s\nacme_choice=%s\n' \
            "${_SI_ACME_STAGING:-unset}" "${_SI_YES:-unset}" \
            "${_SI_ACME_RESET_CHOICE:-unset}"
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
            domain) traefik_dashboard_apex "$body" v ;;
            email)  _si_extract_email  "$body" v ;;
            ca)     _si_extract_ca     "$body" v ;;
        esac
        printf '%s\n' "$v"
        ;;
    render)
        _SI_APPS_PATH="$1"; _SI_DATA_PATH="$2"; _SI_ACME_EMAIL="$3"
        _SI_DASHBOARD_DOMAIN="$4"; _SI_AUTH_ENTRY="$5"
        _SI_ACME_CA="${6:-$_SI_ACME_CA_PRODUCTION}"
        _SI_TRAEFIK_IMAGE="${7:-$KASBAH_TRAEFIK_IMAGE}"
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
        _SI_APPS_PATH=/apps
        # What the server read brings back about acme.json. `empty` is the
        # default because that is every fresh server, and the ACME questions
        # are about a store with something in it.
        _SI_ACME_STORE="${SI_STORE:-empty}"
        # The compose.yml the server already has. Its own variable because it
        # answers a fourth question — which Traefik image this run renders —
        # and because most cases here are about the other three.
        _SI_TRAEFIK_CURRENT=([compose.yml]="${SI_COMPOSE:-}" [traefik.yml]="$static" [dynamic/_shared.yml]="$shared")
        _si_bcrypt() { printf -v "$3" '%s' "$1:\$2y\$05\$FRESHFRESHFRESHFRESHFR"; }
        _server_init_traefik_values
        printf 'image=%s\n' "$_SI_TRAEFIK_IMAGE"
        printf 'domain=%s\nemail=%s\nauth=%s\norigin=%s\n' \
            "$_SI_DASHBOARD_DOMAIN" "$_SI_ACME_EMAIL" "$_SI_AUTH_ENTRY" "$_SI_AUTH_ORIGIN"
        printf 'ca=%s\nstored_ca=%s\nca_origin=%s\nreset=%s\nkept=%s\n' \
            "$_SI_ACME_CA" "$_SI_ACME_CA_STORED" "$_SI_ACME_CA_ORIGIN" \
            "$_SI_ACME_RESET" "${_SI_ACME_KEPT:-none}"
        ;;
    sync)
        # Which files ship, and which change forces a Traefik restart. rsync is
        # stubbed: the decision is local, and it is the decision under test.
        same="$1"
        _SI_APPS_PATH=/apps; _SI_DATA_PATH=/apps/data
        _SI_ACME_EMAIL=ops@example.com; _SI_DASHBOARD_DOMAIN=example.com
        _SI_AUTH_ENTRY='admin:$2y$05$STUB'
        _SI_ACME_CA="$_SI_ACME_CA_PRODUCTION"
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
    readtraefik)
        # The local half of the stack read: which keys it insists on, and what
        # it does with an acme_store value it does not know. The remote half is
        # extracted from its heredoc and run for real further down.
        _SI_TARGET=deploy@vps; _SI_APPS_PATH=/apps; _SI_DATA_PATH=/apps/data
        _SI_FACT=()
        canned="$1"
        ssh_script() { printf '%s' "$canned"; }
        _server_init_read_traefik
        printf 'store=%s\nstatic=%s\n' \
            "$_SI_ACME_STORE" "${_SI_TRAEFIK_CURRENT[traefik.yml]}"
        ;;
    start)
        # What a Traefik that will not come up tells the operator. The remote
        # step is stubbed into failing: what is under test is the local message.
        _SI_TARGET=deploy@vps; _SI_APPS_PATH=/apps; _SI_TRAEFIK_PROJECT=traefik
        _SI_TRAEFIK_RESTART=no
        _SI_FACT=([acme_reset]="$1" [acme_archive]="${2:-}")
        ssh_script() { return 7; }
        _server_init_traefik_start
        printf 'start=ok\n'
        ;;
    reset)
        # Whether the reset step goes to the server at all, and what it hands
        # over when it does. The remote half is driven for real further down,
        # extracted from its heredoc.
        _SI_TARGET=deploy@vps; _SI_DATA_PATH=/apps/data
        _SI_ACME_RESET="$1"; _SI_TRAEFIK_RESTART="$2"
        _SI_FACT=()
        ssh_script() {
            printf 'ssh_script|%s|%s\n' "$1" "$2" >&2
            printf 'acme_archive=%s.%s\nacme_reset=done\n' "$1" "$2"
        }
        _server_init_acme_reset
        printf 'reset=%s\narchive=%s\n' "${_SI_FACT[acme_reset]}" "${_SI_FACT[acme_archive]}"
        ;;
    limits)
        _server_limits "$1" "$2"
        printf 'cpu=%s\nmem=%s\n' "$_SI_CPU_LIMIT" "$_SI_MEM_LIMIT"
        ;;
    marker)
        _server_marker_json "$1" "$2" "$3" "$4" "$5" "${6:-}"
        ;;
    pointercheck)
        # The refusal that keeps one server to one kasbah, driven from the two
        # facts the probe brings back.
        _SI_TARGET=deploy@vps
        _SI_APPS_PATH="$1"
        # `user` comes from the probe, whose key set is checked before any
        # verdict runs, so it is always there by the time this is called.
        _SI_FACT=([pointer_state]="$2" [pointer_value]="${3:-}" [user]=deploy)
        _server_init_check_pointer
        printf 'pointer=accepted\n'
        ;;
    pointerverdict)
        # What a pointer step's report costs, which depends on the apps path.
        _SI_TARGET=deploy@vps
        _SI_APPS_PATH="$1"
        _SI_FACT=([pointer]="$2" [user]=deploy)
        _server_init_pointer_verdict
        printf 'verdict=ok\n'
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
            [have_rsync]=yes [have_openssl]=yes [have_gzip]=yes [have_flock]=yes
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

# The ACME endpoint is not tri-state: production is the default and the status
# quo, so the flag's absence is an answer rather than a question. What does get
# asked is the destructive act it can trigger, and --yes is that flag's pair.
out=$(drive parse deploy@vps)
assert 'grep -qxF "staging=unset" <<<"$out"' "--acme-staging is off unless passed — production is the default (got '$out')"
assert 'grep -qxF "yes=unset" <<<"$out"'     "and --yes is off unless passed (got '$out')"
out=$(drive parse --acme-staging --yes deploy@vps); rc=$?
assert '[ "$rc" = "0" ]'                   "--acme-staging and --yes parse (exit $rc: $(drive_err))"
assert 'grep -qxF "staging=yes" <<<"$out"' "--acme-staging is recorded (got '$out')"
assert 'grep -qxF "yes=yes" <<<"$out"'     "--yes is recorded (got '$out')"

# The unknown-store question is a choice, so it gets a choice's pair and stays
# tri-state: unset means ask, which is what makes the no-TTY failure legible.
out=$(drive parse deploy@vps)
assert 'grep -qxF "acme_choice=unset" <<<"$out"' \
    "neither --reset-acme nor --keep-acme leaves the choice unset — the prompt decides (got '$out')"
out=$(drive parse --reset-acme deploy@vps)
assert 'grep -qxF "acme_choice=yes" <<<"$out"'   "--reset-acme is an explicit reset (got '$out')"
out=$(drive parse --keep-acme deploy@vps)
assert 'grep -qxF "acme_choice=no" <<<"$out"'    "--keep-acme is an explicit keep (got '$out')"

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
for key in kasbah_version apps_path data_path cpu_limit mem_limit backup; do
    assert 'jq -e --arg k "$key" "has(\$k)" >/dev/null <<<"$marker"' \
        "the marker carries $key, as docs/server-setup.md specifies"
done
assert '[ "$(jq -r .kasbah_version <<<"$marker")" = "0.1.0" ]' "kasbah_version is the tool's"
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
existing='{"kasbah_version":"0.1.0","apps_path":"/apps","data_path":"/apps/data","cpu_limit":"1.8","mem_limit":"3g","backup":{"enabled":true,"repo_base":"s3:https://example/kasbah-backups"},"future_key":{"kept":[1,2]}}'
merged=$(drive marker 0.2.0 /apps /apps/data 3.6 7g "$existing")
assert 'jq -e . >/dev/null <<<"$merged"'                          "a merged marker is valid JSON (got '$merged')"
assert '[ "$(jq -r .kasbah_version <<<"$merged")" = "0.2.0" ]'   "the writing tool's version wins"
assert '[ "$(jq -r .cpu_limit <<<"$merged")" = "3.6" ]'           "recomputed limits win"
assert '[ "$(jq -r .backup.enabled <<<"$merged")" = "true" ]'     "an enabled backup is not switched off by a re-run"
assert '[ "$(jq -r .backup.repo_base <<<"$merged")" = "s3:https://example/kasbah-backups" ]' \
    "backup.repo_base survives a re-run (got '$(jq -c .backup <<<"$merged")')"
assert '[ "$(jq -c .future_key <<<"$merged")" = "{\"kept\":[1,2]}" ]' \
    "a key this kasbah has never heard of survives a re-run"
same=$(drive marker 0.1.0 /apps /apps/data 3.6 7g "$(drive marker 0.1.0 /apps /apps/data 3.6 7g)")
assert '[ "$same" = "$(drive marker 0.1.0 /apps /apps/data 3.6 7g)" ]' \
    "merging a marker into itself is a no-op, byte for byte — that is what makes a re-run idempotent"

# --- Marker compatibility -----------------------------------------------------
# docs/server-setup.md: a kasbah binary operates on a VPS whose marker shares
# its major version. KASBAH_VERSION is 9.9.9-test here.
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
# refusal below: chowning a directory kasbah did not create would hand somebody
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
# Its own row, and its own sentence: flock is the one tool the shipped scripts
# need that is not coreutils, and the alternative to catching it here is
# catching it in rd_lock — mid-deploy, after the rsync, where `flock -n 9`
# exiting 127 reads as a concurrent operator who does not exist.
row "no flock"                "flock (util-linux)"     have_flock=no
row "an unreadable core count" "nproc="                nproc=
row "an unreadable MemTotal"   "MemTotal="             memtotal_kb=

# The apps path, in every state but the two kasbah acts on.
row "a sudo that would prompt" "sudo mkdir -p /apps && sudo chown deploy:deploy /apps" sudo_nopasswd=no
row "an apps path that is a file" "/apps exists and is not a directory" apps_state=notdir
row "an apps path that dangles"   "/apps is a symlink to nothing"       apps_state=dangling
row "an apps path owned by somebody else" "sudo chown deploy:deploy /apps" \
    apps_state=dir apps_owned=no apps_writable=no apps_owner=root:root
row "an apps path owned by somebody else, world-writable" "belongs to root:root, not deploy" \
    apps_state=dir apps_owned=no apps_writable=yes apps_owner=root:root
row "an apps path the deploy user owns but cannot write" "chmod u+rwx /apps" \
    apps_state=dir apps_owned=yes apps_writable=no \
    apps_write_error="touch: cannot touch '/apps/.kasbah-write-probe': Permission denied"
# The same -w, wanting the opposite advice: no chmod fixes a read-only mount.
row "an apps path on a read-only filesystem" "read-only filesystem" \
    apps_state=dir apps_owned=yes apps_writable=no \
    apps_write_error="touch: cannot touch '/apps/.kasbah-write-probe': Read-only file system"
out=$(drive preflight apps_state=dir apps_owned=yes apps_writable=no \
    apps_write_error="touch: cannot touch '/apps/.kasbah-write-probe': Read-only file system")
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
sed 's|image: __TRAEFIK_IMAGE__|image: "__NOPE__"|' "$repo_dir/templates/traefik/compose.yml" \
    > "$bad_tpl/traefik/compose.yml"
out=$(KASBAH_TEMPLATE_DIR="$bad_tpl" drive render /apps /apps/data a@b.c example.com "$hash_admin"); rc=$?
assert '[ "$rc" != "0" ]' "an unsubstituted placeholder is a hard failure (exit $rc, printed '$out')"
assert 'grep -qF "__NOPE__" "$tmpdir/err"' \
    "and the failure names the token that survived (said '$(drive_err)')"
assert 'grep -qF "compose.yml" "$tmpdir/err"' "and the file it survived in (said '$(drive_err)')"

out=$(KASBAH_TEMPLATE_DIR="$tmpdir/not-there" drive render /apps /apps/data a@b.c example.com x); rc=$?
assert '[ "$rc" != "0" ]' "a kasbah with no templates fails rather than shipping nothing (exit $rc)"
assert 'grep -qF "installation is incomplete" "$tmpdir/err"' \
    "and says the installation is incomplete (said '$(drive_err)')"

# A token in an operator's *value* is not kasbah's templates being out of step,
# and must not be reported as one. It is also never re-scanned: __APPS_PATH__
# inside the data path comes back verbatim rather than expanded.
mkdir -p "$tmpdir/stage"
out=$(RENDER_OUT="$tmpdir/stage" drive render '/apps/__STAGE__' '/data/__APPS_PATH__' a@b.c example.com "$hash_admin"); rc=$?
stage_vols=$(yq -r '.services.traefik.volumes | join(" ")' "$tmpdir/stage/compose.yml" 2>/dev/null)
assert '[ "$rc" = "0" ]' \
    "a path carrying kasbah's own token syntax renders rather than being blamed on the templates (exit $rc: $(drive_err))"
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

# --- The ACME endpoint --------------------------------------------------------
# Always written out, production included: a re-run decides whether the CA
# changed by comparing one line, which an omitted field cannot be compared to.
ca_prod="https://acme-v02.api.letsencrypt.org/directory"
ca_stag="https://acme-staging-v02.api.letsencrypt.org/directory"
assert '[ "$(yq -r ".certificatesResolvers.letsencrypt.acme.caServer" "$static")" = "$ca_prod" ]' \
    "the default render names the production CA (got '$(yq -r ".certificatesResolvers.letsencrypt.acme.caServer" "$static")')"

stag_dir="$tmpdir/rendered-staging"
mkdir -p "$stag_dir"
RENDER_OUT="$stag_dir" drive render /srv/apps /mnt/vol1 ops@example.com example.com "$hash_admin" "$ca_stag" >/dev/null; rc=$?
static_stag="$stag_dir/traefik.yml"
assert '[ "$rc" = "0" ]' "a staging render succeeds (exit $rc: $(drive_err))"
assert 'yq -e . "$static_stag" >/dev/null 2>&1' "and still parses as YAML"
assert '[ "$(yq -r ".certificatesResolvers.letsencrypt.acme.caServer" "$static_stag")" = "$ca_stag" ]' \
    "with the staging CA in it (got '$(yq -r ".certificatesResolvers.letsencrypt.acme.caServer" "$static_stag")')"
assert '[ "$(yq -r ".certificatesResolvers.letsencrypt.acme.email" "$static_stag")" = "ops@example.com" ]' \
    "and nothing else about the resolver moved"

# The URLs are the two Let's Encrypt directories and are read back off servers
# kasbah rendered earlier, so a typo in either is unrecoverable by re-running.
assert '[ "$(sed -n "s/^_SI_ACME_CA_PRODUCTION=\"\(.*\)\"$/\1/p" "$repo_dir/lib/server_init.sh")" = "$ca_prod" ]' \
    "the production endpoint is Let's Encrypt's own directory URL"
assert '[ "$(sed -n "s/^_SI_ACME_CA_STAGING=\"\(.*\)\"$/\1/p" "$repo_dir/lib/server_init.sh")" = "$ca_stag" ]' \
    "and so is the staging one"

# --- compose.yml --------------------------------------------------------------
#
# The pin is a token in the template and a constant in lib/common.sh, because
# `server upgrade-traefik` renders the same file with a tag of its own and every
# later init reproduces whatever the server already runs (docs/traefik.md ->
# Ownership). A literal put back into the template would make a managed upgrade
# revert on the next re-run, silently.
pin=$(sed -n 's/^KASBAH_TRAEFIK_IMAGE=//p' "$repo_dir/lib/common.sh")
assert 'grep -qF "image: __TRAEFIK_IMAGE__" "$repo_dir/templates/traefik/compose.yml"' \
    "the template carries the image as a token, not a literal"
assert '[[ "$pin" =~ ^traefik:v3\.[0-9]+\.[0-9]+$ ]]' \
    "and KASBAH_TRAEFIK_IMAGE is a full version, never a moving tag (got '$pin')"
assert '[ "$(yq -r ".services.traefik.image" "$compose")" = "$pin" ]' \
    "which is what a first init renders (got '$(yq -r ".services.traefik.image" "$compose")')"
assert '[ "$(yq -r ".services.traefik.image" "$compose")" = "traefik:v3.7.10" ]' \
    "Traefik is pinned to an exact v3 tag (got '$(yq -r ".services.traefik.image" "$compose")')"
assert '[[ "$(yq -r ".services.traefik.image" "$compose")" =~ ^traefik:v3\.[0-9]+\.[0-9]+$ ]]' \
    "the pin is a full version, never a moving tag"
assert '[ "$(yq -r "has(\"version\")" "$compose")" = "false" ]' \
    "no deprecated version: attribute (C05)"
assert '[ "$(yq -r ".services.traefik.restart" "$compose")" = "unless-stopped" ]' \
    "restart: unless-stopped, as kasbah check demands of every service (C01)"
assert '[ "$(yq -r ".services.traefik.logging.driver" "$compose")" = "json-file" ]' \
    "json-file logging (C02)"
assert '[ "$(yq -r ".services.traefik.logging.options[\"max-size\"]" "$compose")" != "null" ] \
        && [ "$(yq -r ".services.traefik.logging.options[\"max-file\"]" "$compose")" != "null" ]' \
    "with both rotation knobs set (C02)"
assert '[ "$(yq -r ".networks[\"kasbah-net\"].name" "$compose")" = "kasbah-net" ]' \
    "the network is named kasbah-net — a frozen contract every project fragment depends on"
assert '[ "$(yq -r ".networks[\"kasbah-net\"].driver" "$compose")" = "bridge" ]' \
    "and is a bridge (got '$(yq -r ".networks[\"kasbah-net\"].driver" "$compose")')"
assert '[ "$(yq -r ".services.traefik.networks | join(\",\")" "$compose")" = "kasbah-net" ]' \
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
assert '[ "$(yq -r "$router.middlewares | join(\",\")" "$shared")" = "security-headers,traefik-dashboard-auth" ]' \
    "behind security-headers then basic auth — headers first so the 401 carries HSTS (got '$(yq -r "$router.middlewares | join(\",\")" "$shared")')"
auth_mw=$(yq -r "$router.middlewares[-1]" "$shared")
assert '[ "$(yq -r ".http.middlewares[\"$auth_mw\"].basicAuth.users[0]" "$shared")" = "$hash_admin" ]' \
    "which is basic auth carrying the bcrypt entry verbatim (got '$(yq -r ".http.middlewares[\"$auth_mw\"].basicAuth.users[0]" "$shared")')"

# The dashboard's :80 half. Redirect-only: it must never carry the auth
# middleware, because a router that asks for credentials over plain HTTP is
# how they end up on the wire.
http_router='.http.routers["traefik-dashboard-http"]'
assert '[ "$(yq -r "$http_router.rule" "$shared")" = "$(yq -r "$router.rule" "$shared")" ]' \
    "the :80 dashboard router matches the same host as the HTTPS one"
assert '[ "$(yq -r "$http_router.entryPoints | join(\",\")" "$shared")" = "web" ]' "on web only"
assert '[ "$(yq -r "$http_router.middlewares | join(\",\")" "$shared")" = "http-to-https" ]' \
    "carrying only the redirect (got '$(yq -r "$http_router.middlewares | join(\",\")" "$shared")')"
assert '[ "$(yq -r "$http_router.service" "$shared")" = "noop@internal" ]' \
    "served by noop@internal, the placeholder for a router its middleware answers"
assert '[ "$(yq -r "$http_router | has(\"tls\")" "$shared")" = "false" ]' \
    "and declaring no tls — it is the plaintext half"

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

# --- Which Traefik image a re-run renders --------------------------------------
#
# The fourth value read back off the server, and the one with a default behind
# it. It exists so that `server upgrade-traefik` is not undone by the next
# init: an init that rendered kasbah's own pin over a tag somebody upgraded to
# would downgrade a live proxy on a re-run nobody thought was risky
# (docs/traefik.md -> Ownership). Three cases, and the pairing matters — "falls
# back" is only meaningful beside a case where it does not.
pin=$(sed -n 's/^KASBAH_TRAEFIK_IMAGE=//p' "$repo_dir/lib/common.sh")
compose_doc() { printf 'services:\n  traefik:\n    image: %s\n' "$1"; }

out=$(SI_COMPOSE="$(compose_doc traefik:v3.6.7)" drive values "$stored_shared" "$stored_static"); rc=$?
assert '[ "$rc" = "0" ]' "a server carrying its own traefik tag needs no flags (exit $rc: $(drive_err))"
assert 'grep -qxF "image=traefik:v3.6.7" <<<"$out"' \
    "the tag on the server wins over KASBAH_TRAEFIK_IMAGE ($pin) — an upgrade survives a re-run (got '$out')"
assert '[ -z "$(drive_err)" ]' "and nothing is warned about (said '$(drive_err)')"

out=$(SI_COMPOSE="" drive values "$stored_shared" "$stored_static"); rc=$?
assert 'grep -qxF "image=$pin" <<<"$out"' \
    "a server with no compose.yml yet renders kasbah's own pin (got '$out')"
assert '[ -z "$(drive_err)" ]' \
    "silently — there is nothing to lose on a fresh server (said '$(drive_err)')"

# The same document with one field changed, so the fallback is a decision about
# the value and not about the file.
out=$(SI_COMPOSE="$(compose_doc mirror.example/traefik:v3.7.10)" drive values "$stored_shared" "$stored_static"); rc=$?
assert '[ "$rc" = "0" ]' "an image kasbah does not reproduce is not fatal (exit $rc: $(drive_err))"
assert 'grep -qxF "image=$pin" <<<"$out"' "it falls back to the pin (got '$out')"
assert 'grep -qF "upgrade-traefik" "$tmpdir/err"' \
    "and says so out loud, because the operator is about to lose that value (said '$(drive_err)')"

out=$(SI_COMPOSE="services: [" drive values "$stored_shared" "$stored_static"); rc=$?
assert '[ "$rc" = "0" ]' "a compose.yml that does not parse is not fatal either — init owns that file (exit $rc)"
assert 'grep -qxF "image=$pin" <<<"$out"' "and the pin is rendered (got '$out')"
assert '[ -n "$(drive_err)" ]' "with a warning (said '$(drive_err)')"

# The extractors on their own, against shapes an operator's editor produces.
extract() { printf '%s' "$2" | drive_stdin extract "$1"; }

assert '[ "$(extract auth "$stored_shared")" = "$hash_admin" ]' \
    "the hash is found in kasbah's own output"
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

# --- Which CA is in effect, and what a switch costs ---------------------------
# The endpoint is the one Traefik value the server gets no vote on: the flag
# decides it every run. The server is read for two other things — which CA the
# config records, and whether acme.json holds anything — and it is the pairing
# that decides whether a certificate is at risk.
stored_static_stag=$(cat "$static_stag")
assert '[ "$(extract ca "$stored_static")" = "$ca_prod" ]' \
    "the CA is read back out of the static config (got '$(extract ca "$stored_static")')"
assert '[ "$(extract ca "$stored_static_stag")" = "$ca_stag" ]' \
    "staging included (got '$(extract ca "$stored_static_stag")')"
ca_crlf=$(printf 'certificatesResolvers:\r\n  letsencrypt:\r\n    acme:\r\n      caServer: "%s"\r\n' "$ca_stag")
assert '[ "$(extract ca "$ca_crlf")" = "$ca_stag" ]' \
    "and out of a file saved with CRLF line endings (got '$(extract ca "$ca_crlf")')"
no_ca=$(printf 'certificatesResolvers:\n  letsencrypt:\n    acme:\n      email: "ops@example.com"\n      storage: /letsencrypt/acme.json\n')
assert '[ -z "$(extract ca "$no_ca")" ]' \
    "a static config with no caServer yields nothing rather than a guess (got '$(extract ca "$no_ca")')"

# An empty store is the whole of a fresh server, and there is nothing in it to
# lose: no question is asked whatever the endpoints say. This is the path a
# first init takes, so anything louder here would be noise on every new VPS.
out=$(drive values "" "" --domain=example.com --email=a@b.c --traefik-auth=admin:pw --acme-staging); rc=$?
assert '[ "$rc" = "0" ]' "a bare server takes --acme-staging without asking anything (exit $rc: $(drive_err))"
assert 'grep -qxF "ca=$ca_stag" <<<"$out"' "and renders staging (got '$out')"
assert 'grep -qxF "reset=no" <<<"$out"'    "with no store to reset (got '$out')"

out=$(drive values "$stored_shared" "$stored_static" --acme-staging); rc=$?
assert '[ "$rc" = "0" ]' \
    "an endpoint change over an empty store asks nothing either (exit $rc: $(drive_err))"
assert 'grep -qxF "ca=$ca_stag" <<<"$out"' "the flag still decides the endpoint (got '$out')"
assert 'grep -qxF "reset=no" <<<"$out"'    "and an empty store is not worth archiving (got '$out')"

# Same endpoint, certificates in the store: the idempotent re-run.
out=$(SI_STORE=nonempty drive values "$stored_shared" "$stored_static"); rc=$?
assert '[ "$rc" = "0" ]' "a re-run with the same endpoint needs no confirmation (exit $rc: $(drive_err))"
assert 'grep -qxF "ca=$ca_prod" <<<"$out"'      "the production CA is rendered by default (got '$out')"
assert 'grep -qxF "ca_origin=known" <<<"$out"'  "read off the server (got '$out')"
assert 'grep -qxF "reset=no" <<<"$out"'         "and acme.json is left alone (got '$out')"

out=$(SI_STORE=nonempty drive values "$stored_static_stag" "$stored_static_stag" --acme-staging --domain=example.com --traefik-auth=admin:pw); rc=$?
assert '[ "$rc" = "0" ]' "so does a staging re-run with --acme-staging (exit $rc: $(drive_err))"
assert 'grep -qxF "ca=$ca_stag" <<<"$out"' "which renders the staging CA (got '$out')"
assert 'grep -qxF "reset=no" <<<"$out"'    "and resets nothing (got '$out')"

# The switch itself. It discards certificates, so it is confirmed — and with no
# terminal to confirm at, the run stops naming the flag, exactly as every other
# kasbah prompt does.
out=$(SI_STORE=nonempty drive values "$stored_shared" "$stored_static" --acme-staging); rc=$?
err_out=$(drive_err)
assert '[ "$rc" != "0" ]' "an endpoint change over a real store is a hard fail with no terminal (exit $rc, printed '$out')"
assert 'grep -qF -- "--yes" <<<"$err_out"' "naming --yes (said '$err_out')"
assert 'grep -qF "acme.json" <<<"$err_out"' "and saying what would happen (said '$err_out')"

out=$(SI_STORE=nonempty drive values "$stored_shared" "$stored_static" --acme-staging --yes); rc=$?
assert '[ "$rc" = "0" ]' "--yes answers it for a script (exit $rc: $(drive_err))"
assert 'grep -qxF "ca=$ca_stag" <<<"$out"' "production -> staging renders staging (got '$out')"
assert 'grep -qxF "stored_ca=$ca_prod" <<<"$out"' "against the CA the server was on (got '$out')"
assert 'grep -qxF "reset=yes" <<<"$out"'   "and acme.json is reset (got '$out')"

out=$(SI_STORE=nonempty drive values "$stored_static_stag" "$stored_static_stag" --yes --domain=example.com --traefik-auth=admin:pw); rc=$?
assert '[ "$rc" = "0" ]' "and back again, with no flag at all (exit $rc: $(drive_err))"
assert 'grep -qxF "ca=$ca_prod" <<<"$out"' \
    "dropping --acme-staging is what moves a server to production (got '$out')"
assert 'grep -qxF "reset=yes" <<<"$out"'   "resetting acme.json on the way (got '$out')"

# --- A store whose provenance nothing records ---------------------------------
# The most common run this will ever see: a server prepared before caServer was
# rendered, holding real production certificates, re-run with --acme-staging.
# Reading the config alone says "no change", and kasbah would ship a staging
# endpoint over a production store in silence.
#
# It is a *choice*, not a confirmation, and it gets a choice's flag pair. --yes
# deliberately does not answer it: --yes accepts a destructive act the operator
# asked for, and this question is one kasbah raises about state it cannot read.
out=$(SI_STORE=nonempty drive values "" "$no_ca" --acme-staging --domain=example.com --traefik-auth=admin:pw); rc=$?
err_out=$(drive_err)
assert '[ "$rc" != "0" ]' \
    "a non-empty store with no recorded CA is asked about, not assumed safe (exit $rc, printed '$out')"
assert 'grep -qF -- "--reset-acme or --keep-acme" <<<"$err_out"' \
    "and with no terminal the run stops naming both flags (said '$err_out')"
assert 'grep -qF "parses but names no caServer" <<<"$err_out"' \
    "saying which fact is missing (said '$err_out')"
# A traefik.yml that is not Traefik's parses and has no caServer too, so the
# message reports the missing field and claims nothing about how it got that way.
assert '! grep -qF "predates" <<<"$err_out"' \
    "without asserting a history it cannot know (said '$err_out')"
not_traefik=$(printf 'hello: world\n')
out=$(SI_STORE=nonempty drive values "$stored_shared" "$not_traefik" --email=a@b.c --keep-acme); rc=$?
assert '[ "$rc" = "0" ] && grep -qxF "ca_origin=nofield" <<<"$out"' \
    "a file that is not Traefik's at all lands in the same state (exit $rc, got '$out')"
assert '! grep -qF "predates" "$tmpdir/err"' \
    "and is not told it predates anything (said '$(drive_err)')"

out=$(SI_STORE=nonempty drive values "" "$no_ca" --acme-staging --yes --domain=example.com --traefik-auth=admin:pw); rc=$?
err_out=$(drive_err)
assert '[ "$rc" != "0" ]' \
    "--yes does not answer it — the only scriptable answer must not be the destructive one (exit $rc, printed '$out')"
assert 'grep -qF -- "--reset-acme or --keep-acme" <<<"$err_out"' \
    "the failure still names the pair that does (said '$err_out')"

out=$(SI_STORE=nonempty drive values "" "$no_ca" --acme-staging --reset-acme --domain=example.com --traefik-auth=admin:pw); rc=$?
assert '[ "$rc" = "0" ]' "--reset-acme accepts the reset (exit $rc: $(drive_err))"
assert 'grep -qxF "ca_origin=nofield" <<<"$out"' "the missing field is the reason (got '$out')"
assert 'grep -qxF "reset=yes" <<<"$out"'         "and the store is reset (got '$out')"

# The answer the design itself calls safe, and the reason the pair exists: it
# has to be expressible without a terminal, or a CI script's only option is the
# one that spends production issuance budget on a server that needed nothing.
out=$(SI_STORE=nonempty drive values "" "$no_ca" --keep-acme --domain=example.com --traefik-auth=admin:pw); rc=$?
err_out=$(drive_err)
assert '[ "$rc" = "0" ]' "--keep-acme proceeds with no terminal at all (exit $rc: $err_out)"
assert 'grep -qxF "ca=$ca_prod" <<<"$out"' "the endpoint is still recorded (got '$out')"
assert 'grep -qxF "reset=no" <<<"$out"'    "and the store is untouched (got '$out')"
assert 'grep -qxF "kept=unknown" <<<"$out"' "the run carrying that it was kept (got '$out')"
assert 'grep -qF "unknown provenance" <<<"$err_out"' "and warning about it (said '$err_out')"

reject "contradicting acme store flags" "cannot both be given" deploy@vps --reset-acme --keep-acme

# No traefik.yml content at all, and one that does not parse: both leave the
# endpoint unknown, and the operator can act on which of the two it is.
out=$(SI_STORE=nonempty drive values "$stored_shared" "" --email=a@b.c --reset-acme); rc=$?
err_out=$(drive_err)
assert '[ "$rc" = "0" ]' "a missing traefik.yml over a real store asks too (exit $rc: $err_out)"
assert 'grep -qxF "ca_origin=nocontent" <<<"$out"' "recorded as a file with nothing in it (got '$out')"
assert 'grep -qF "is missing, empty or unreadable" <<<"$err_out"' \
    "and said as one, not as a missing field — the read reports all three alike (said '$err_out')"

broken_static=$(printf 'certificatesResolvers: [\n')
out=$(SI_STORE=nonempty drive values "$stored_shared" "$broken_static" --email=a@b.c --reset-acme); rc=$?
err_out=$(drive_err)
assert '[ "$rc" = "0" ]' "an unparseable traefik.yml with --email given asks too (exit $rc: $err_out)"
assert 'grep -qxF "ca_origin=unreadable" <<<"$out"' \
    "as a file that does not parse, never collapsed into 'never had one' (got '$out')"
assert 'grep -qF "does not parse" <<<"$err_out"' "and the operator is told which it is (said '$err_out')"
assert 'grep -qxF "reset=yes" <<<"$out"' "and --reset-acme resets (got '$out')"

# --- Where the two flag philosophies meet -------------------------------------
# --yes answers the confirmation, --reset-acme/--keep-acme answer the choice,
# and one flag per question only holds if a flag aimed at the other question
# cannot quietly decide this one.
#
# The destructive collision first: --keep-acme states an intent the switch
# cannot honour, and --yes states the opposite one. Whichever branch read its
# flag last would win in silence, and the losing direction archives a store the
# operator asked to keep.
out=$(SI_STORE=nonempty drive values "$stored_shared" "$stored_static" --acme-staging --keep-acme --yes); rc=$?
err_out=$(drive_err)
assert '[ "$rc" != "0" ]' \
    "--keep-acme with a switch is refused, not overridden by --yes (exit $rc, printed '$out')"
assert '! grep -qxF "reset=yes" <<<"$out"' \
    "and above all does not reset a store the operator asked to keep (got '$out')"
assert 'grep -qF -- "--keep-acme cannot be honoured" <<<"$err_out"' \
    "naming the contradiction rather than picking a side (said '$err_out')"
assert 'grep -qF -- "re-run without --keep-acme" <<<"$err_out"' \
    "and both ways out of it (said '$err_out')"
assert 'grep -qF -- "with --yes to switch and reset" <<<"$err_out"' \
    "including the one that resets (said '$err_out')"

out=$(SI_STORE=nonempty drive values "$stored_shared" "$stored_static" --acme-staging --keep-acme); rc=$?
assert '[ "$rc" != "0" ]' "the same without --yes — the objection is to the flag, not to the pair (exit $rc)"
assert 'grep -qF -- "--keep-acme cannot be honoured" "$tmpdir/err"' "with the same message (said '$(drive_err)')"

# --reset-acme is merely spare here: it agrees with the outcome but answers a
# question this run does not ask, and --yes is what settles the one it does.
out=$(SI_STORE=nonempty drive values "$stored_shared" "$stored_static" --acme-staging --reset-acme --yes); rc=$?
err_out=$(drive_err)
assert '[ "$rc" = "0" ]' "--reset-acme alongside a switch is not a failure (exit $rc: $err_out)"
assert 'grep -qxF "reset=yes" <<<"$out"' "the switch still resets (got '$out')"
assert 'grep -qF -- "--reset-acme had no effect" <<<"$err_out"' \
    "and the operator is told the flag did nothing (said '$err_out')"

# A fleet script sets the pair once and meets servers that never ask. Those runs
# warn and carry on — failing them is what would make the pair unusable.
out=$(SI_STORE=nonempty drive values "$stored_shared" "$stored_static" --reset-acme); rc=$?
err_out=$(drive_err)
assert '[ "$rc" = "0" ]' "a choice flag on an idempotent re-run is a warning, not a refusal (exit $rc: $err_out)"
assert 'grep -qxF "reset=no" <<<"$out"' "nothing is reset (got '$out')"
assert 'grep -qF -- "--reset-acme had no effect" <<<"$err_out"' "and it says so (said '$err_out')"
assert 'grep -qF "records the CA that filled acme.json" <<<"$err_out"' \
    "naming why the question was not asked (said '$err_out')"

out=$(drive values "$stored_shared" "$stored_static" --keep-acme); rc=$?
err_out=$(drive_err)
assert '[ "$rc" = "0" ]' "and likewise over an empty store (exit $rc: $err_out)"
assert 'grep -qF -- "--keep-acme had no effect" <<<"$err_out"' "naming the flag that was passed (said '$err_out')"
assert 'grep -qF "holds nothing to decide about" <<<"$err_out"' \
    "and that there was nothing to decide (said '$err_out')"

# The silence that makes those warnings legible: neither flag, nothing to say.
out=$(SI_STORE=nonempty drive values "$stored_shared" "$stored_static"); rc=$?
err_out=$(drive_err)
assert '[ "$rc" = "0" ] && [ -z "$err_out" ]' \
    "a re-run that asks nothing says nothing at all (exit $rc, said '$err_out')"

# --- Declining, behind a real terminal ----------------------------------------
# `[ -t 0 ]` is a property of the pty, and a pipe cannot stand in for it.
drive_tty() {
    local input="$1"; shift
    local cmd; cmd="$(printf '%q ' bash "$driver" "$@")"
    tty_out=$(printf '%s' "$input" | script -qec "$cmd" /dev/null 2>&1); tty_rc=$?
    tty_out=${tty_out//$'\r'/}
}

# A stated endpoint the operator declines to leave: an abort, because the
# likeliest way to be here is a mistyped flag and nothing has happened yet.
SI_STORE=nonempty drive_tty $'n\n' values "$stored_shared" "$stored_static" --acme-staging
assert '[ "$tty_rc" != "0" ]' "declining a stated switch stops the run (exit $tty_rc, said '$tty_out')"
assert 'grep -qF "declined" <<<"$tty_out"'  "saying it was declined (said '$tty_out')"
assert 'grep -qF "unchanged" <<<"$tty_out"' "and that the server is untouched (said '$tty_out')"
assert 'grep -qF -- "re-run without --acme-staging" <<<"$tty_out"' \
    "and naming the re-run that keeps the production CA it is on (said '$tty_out')"
assert '! grep -qxF "reset=yes" <<<"$tty_out"' "with no reset decided (said '$tty_out')"

SI_STORE=nonempty drive_tty $'y\n' values "$stored_shared" "$stored_static" --acme-staging
assert '[ "$tty_rc" = "0" ]' "accepting it at the terminal goes ahead (exit $tty_rc, said '$tty_out')"
assert 'grep -qxF "reset=yes" <<<"$tty_out"' "with the reset decided (said '$tty_out')"
assert 'grep -qF "$ca_stag" <<<"$tty_out"'   "and the question named both endpoints (said '$tty_out')"

# An unknown provenance the operator declines: the run *proceeds*. There is no
# flag that answers this question, so an abort would leave every pre-caServer
# server with no way to run init at all.
SI_STORE=nonempty drive_tty $'n\n' values "" "$no_ca" --domain=example.com --traefik-auth=admin:pw
assert '[ "$tty_rc" = "0" ]' "answering keep at the terminal lets the run continue (exit $tty_rc, said '$tty_out')"
assert 'grep -qxF "reset=no" <<<"$tty_out"'      "without resetting (said '$tty_out')"
assert 'grep -qxF "kept=unknown" <<<"$tty_out"'  "and recording that the store was kept (said '$tty_out')"
assert 'grep -qF "warning:" <<<"$tty_out"'       "loudly (said '$tty_out')"
assert 'grep -qF "unknown provenance" <<<"$tty_out"' \
    "saying what is now true of the server (said '$tty_out')"
assert 'grep -qF "asked this once" <<<"$tty_out"' \
    "and that this run records the endpoint, so it is asked once (said '$tty_out')"

# --- A caServer that is neither Let's Encrypt endpoint -------------------------
# Set outside kasbah. It must not be announced as "staging" or "production" —
# and above all the decline advice must not name a flag, because neither flag
# reproduces it and both would reset the store the warning is about.
custom_ca="https://acme.internal.example/dir"
custom_static=$(printf 'certificatesResolvers:\n  letsencrypt:\n    acme:\n      email: "ops@example.com"\n      caServer: "%s"\n' "$custom_ca")
out=$(SI_STORE=nonempty drive values "$stored_shared" "$custom_static" --yes); rc=$?
err_out=$(drive_err)
assert '[ "$rc" = "0" ]' "a custom endpoint is a switch like any other (exit $rc: $err_out)"
assert 'grep -qxF "stored_ca=$custom_ca" <<<"$out"' "quoted verbatim (got '$out')"
assert 'grep -qF "$custom_ca" <<<"$err_out"'        "and shown to the operator (said '$err_out')"
assert 'grep -qF "kasbah does not render" <<<"$err_out"' \
    "named as something kasbah does not render (said '$err_out')"
assert '! grep -qE "for the Let.s Encrypt (staging|production) CA and this run" <<<"$err_out"' \
    "never announced as one of the two endpoints it is not (said '$err_out')"

SI_STORE=nonempty drive_tty $'n\n' values "$stored_shared" "$custom_static"
assert '[ "$tty_rc" != "0" ]' "declining it aborts (exit $tty_rc, said '$tty_out')"
assert '! grep -qF -- "re-run with" <<<"$tty_out"' \
    "without offering a flag that would cause the loss it warns about (said '$tty_out')"
assert 'grep -qF "no kasbah flag reproduces it" <<<"$tty_out"' \
    "saying plainly that none exists (said '$tty_out')"

# A file kasbah cannot parse is not a file it may quietly replace: the value it
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

# --- What the server says about the stack, and about the store ----------------
# The whole ACME decision is keyed on acme_store, and the driver stubs it
# everywhere above — so the producer is tested here, extracted from its heredoc
# and run against a scratch tree, or the four-state ladder proves nothing.
read_payload="$tmpdir/readtraefik.sh"
awk '/<<'"'"'REMOTE'"'"'$/{buf=""; inb=1; next} inb && /^REMOTE$/{if (buf ~ /acme_store=nonempty/) printf "%s", buf; inb=0; next} inb{buf = buf $0 "\n"}' \
    "$repo_dir/lib/server_init.sh" > "$read_payload"
assert '[ -s "$read_payload" ]' "the Traefik stack read was extracted from lib/server_init.sh"
assert 'grep -qF "traefik_static_b64" "$read_payload"' \
    "and it is the right block — every case below is empty theatre otherwise"

read_apps="$tmpdir/readfs/apps"
read_data="$tmpdir/readfs/data"
run_read() {
    r_rc=0
    r_out="$(bash "$read_payload" "$read_apps" "$read_data" 2>"$tmpdir/rerr")" || r_rc=$?
}
rfact() { grep -m1 "^$1=" <<<"$r_out" | cut -d= -f2-; }

rm -rf "$tmpdir/readfs"
mkdir -p "$read_apps/traefik/dynamic" "$read_data/traefik/letsencrypt"
printf 'a: 1\n' > "$read_apps/traefik/traefik.yml"
run_read
assert '[ "$r_rc" = "0" ]' "the read runs against a bare tree (rc $r_rc: $(cat "$tmpdir/rerr"))"
assert '[ "$(rfact acme_store)" = "absent" ]' \
    "no acme.json at all is absent, not empty (got '$(rfact acme_store)')"
assert '[ "$(printf %s "$(rfact traefik_static_b64)" | base64 -d)" = "a: 1" ]' \
    "and the files still come back base64 on one line — this block is a protocol"
assert '[ -z "$(rfact traefik_compose_b64)" ]' "a file that is not there reports empty (got '$(rfact traefik_compose_b64)')"

acme_r="$read_data/traefik/letsencrypt/acme.json"
: > "$acme_r"
run_read
assert '[ "$(rfact acme_store)" = "empty" ]' \
    "a zero-length store is empty — this is the state every fresh init is in (got '$(rfact acme_store)')"

printf '{"letsencrypt":{}}\n' > "$acme_r"
run_read
assert '[ "$(rfact acme_store)" = "nonempty" ]' \
    "one with anything in it is nonempty — the only state that puts a certificate at risk (got '$(rfact acme_store)')"

rm -f "$acme_r"; mkdir -p "$acme_r"
run_read
assert '[ "$(rfact acme_store)" = "notfile" ]' \
    "a directory at the path is its own answer: -e and -s cannot tell it from a store (got '$(rfact acme_store)')"
rmdir "$acme_r"

# The local half: the key is required, and a value this kasbah does not know is
# a refusal rather than a state that falls through to "nothing at risk".
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
canned() { printf 'traefik_compose_b64=\ntraefik_static_b64=%s\ntraefik_shared_b64=\nacme_store=%s\n' "$(b64 "$1")" "$2"; }

out=$(drive readtraefik "$(canned 'x: 1' nonempty)"); rc=$?
assert '[ "$rc" = "0" ]' "the stack read absorbs a well-formed report (exit $rc: $(drive_err))"
assert 'grep -qxF "store=nonempty" <<<"$out"' "carrying the store state into the run (got '$out')"
assert 'grep -qxF "static=x: 1" <<<"$out"'    "alongside the decoded files (got '$out')"

out=$(drive readtraefik "$(printf 'traefik_compose_b64=\ntraefik_static_b64=\ntraefik_shared_b64=\n')"); rc=$?
assert '[ "$rc" != "0" ]' "a report with no acme_store is a truncated step, not a store to guess at (exit $rc, printed '$out')"
assert 'grep -qF "reported no acme_store" "$tmpdir/err"' \
    "as the protocol failure it is, naming the key that never arrived (said '$(drive_err)')"
assert 'grep -qF "the step was truncated" "$tmpdir/err"' \
    "not as an unbound variable a page later — the check is what makes the key required (said '$(drive_err)')"

out=$(drive readtraefik "$(canned 'x: 1' plenty)"); rc=$?
assert '[ "$rc" != "0" ]' "an acme_store value this kasbah does not know is refused (exit $rc, printed '$out')"
assert 'grep -qF "does not know" "$tmpdir/err"' "saying so (said '$(drive_err)')"

# --- What a Traefik that will not start says about the store ------------------
# The reset is this command's one destructive act, and a failed start is the
# path where the operator cannot see for themselves that it worked.
drive start done /apps/data/traefik/letsencrypt/acme.json.20260822T101500Z >/dev/null; rc=$?
err_out=$(drive_err)
assert '[ "$rc" != "0" ]' "a Traefik that will not come up fails the run (exit $rc)"
assert 'grep -qF "could not start Traefik" <<<"$err_out"' "saying so (said '$err_out')"
assert 'grep -qF "acme.json.20260822T101500Z" <<<"$err_out"' \
    "and naming where the certificates went — they exist only in the archive now (said '$err_out')"

drive start skipped >/dev/null; rc=$?
err_out=$(drive_err)
assert '[ "$rc" != "0" ]' "a start failure with no reset behind it still fails (exit $rc)"
assert '! grep -qF "acme.json was reset" <<<"$err_out"' \
    "without inventing an archive that was never made (said '$err_out')"

# --- The acme.json reset ------------------------------------------------------
# A CA change always changes traefik.yml's bytes, so it always rides the one
# restart mechanism there is. The order is load-bearing: acme.json is
# bind-mounted as a file, so the running Traefik holds the old inode until the
# restart re-resolves the mount.
steps=$(sed -n '/^cmd_server_init() {/,/^}/p' "$repo_dir/lib/server_init.sh" \
        | grep -oE '_server_init_(traefik_sync|acme_reset|traefik_start)' | tr '\n' ' ')
assert '[ "$steps" = "_server_init_traefik_sync _server_init_acme_reset _server_init_traefik_start " ]' \
    "the reset runs after the new traefik.yml lands and before the restart (got '$steps')"

out=$(drive reset no no); rc=$?
err_out=$(drive_err)
assert '[ "$rc" = "0" ]' "a run that changes no endpoint runs the reset step (exit $rc: $err_out)"
assert 'grep -qxF "reset=skipped" <<<"$out"'  "which does nothing (got '$out')"
assert '! grep -qF "ssh_script|" <<<"$err_out"' "and does not go to the server at all (said '$err_out')"

out=$(drive reset yes yes); rc=$?
err_out=$(drive_err)
assert '[ "$rc" = "0" ]' "a switch runs it for real (exit $rc: $err_out)"
assert 'grep -qF "ssh_script|/apps/data/traefik/letsencrypt/acme.json|" <<<"$err_out"' \
    "against the data path's acme.json (said '$err_out')"
assert '[[ "$err_out" =~ \|[0-9]{8}T[0-9]{6}Z$ ]]' \
    "with a UTC timestamp taken here, not on a host with no coreutils to spare (said '$err_out')"
assert 'grep -qxF "reset=done" <<<"$out"' "and reports what the server did (got '$out')"

out=$(drive reset yes no); rc=$?
assert '[ "$rc" != "0" ]' "a reset with no restart behind it is refused (exit $rc, printed '$out')"
assert 'grep -qF "internal:" "$tmpdir/err"' \
    "as the internal inconsistency it would be — the restart is what makes Traefik adopt the new file (said '$(drive_err)')"

# The remote half, extracted from its heredoc and run against a directory of its
# own. The rig cannot show the archive it replaces: `rig_clean` never gets as
# far as a second CA.
acme_payload="$tmpdir/acmereset.sh"
awk '/<<'"'"'REMOTE'"'"'$/{buf=""; inb=1; next} inb && /^REMOTE$/{if (buf ~ /acme_reset=done/) printf "%s", buf; inb=0; next} inb{buf = buf $0 "\n"}' \
    "$repo_dir/lib/server_init.sh" > "$acme_payload"
assert '[ -s "$acme_payload" ]' "the reset step was extracted from lib/server_init.sh"
assert 'grep -qF "acme_archive=" "$acme_payload"' \
    "and it is the right block — every case below is empty theatre otherwise"

acme_dir="$tmpdir/acmefs"
run_acme() {
    a_rc=0
    a_out="$(bash "$acme_payload" "$acme_dir/acme.json" "$1" 2>"$tmpdir/aerr")" || a_rc=$?
}

rm -rf "$acme_dir"; mkdir -p "$acme_dir"
printf 'CERTS\n' > "$acme_dir/acme.json"; chmod 600 "$acme_dir/acme.json"
run_acme 20260822T101500Z
assert '[ "$a_rc" = "0" ]' "the reset runs (rc $a_rc: $(cat "$tmpdir/aerr"))"
assert 'grep -qxF "acme_reset=done" <<<"$a_out"' "and says so (got '$a_out')"
assert '[ "$(cat "$acme_dir/acme.json.20260822T101500Z" 2>&1)" = "CERTS" ]' \
    "the old store is archived beside itself, never deleted — the certificates in it may be real"
assert '[ "$(stat -c %a "$acme_dir/acme.json.20260822T101500Z")" = "600" ]' \
    "keeping mode 600 (got '$(stat -c %a "$acme_dir/acme.json.20260822T101500Z" 2>&1)')"
assert 'grep -qxF "acme_archive=$acme_dir/acme.json.20260822T101500Z" <<<"$a_out"' \
    "and the run is told where it went (got '$a_out')"
assert '[ -f "$acme_dir/acme.json" ] && [ ! -s "$acme_dir/acme.json" ]' \
    "a fresh empty acme.json takes its place — a missing bind-mount source is what Docker turns into a directory"
assert '[ "$(stat -c %a "$acme_dir/acme.json")" = "600" ]' \
    "mode 600 (got '$(stat -c %a "$acme_dir/acme.json" 2>&1)')"

# Twice in the same second is the one way the archive could overwrite an
# archive. It refuses rather than losing the first one.
run_acme 20260822T101500Z
assert '[ "$a_rc" != "0" ]' "a second archive with the same stamp is refused (rc $a_rc, printed '$a_out')"
assert 'grep -qF "already there" "$tmpdir/aerr"' "saying so (said '$(cat "$tmpdir/aerr")')"
assert '[ "$(cat "$acme_dir/acme.json.20260822T101500Z")" = "CERTS" ]' "and the first archive is intact"

rm -rf "$acme_dir"; mkdir -p "$acme_dir"
run_acme 20260822T101501Z
assert '[ "$a_rc" = "0" ]' "with no store there yet, the reset still creates one (rc $a_rc: $(cat "$tmpdir/aerr"))"
assert 'grep -qxF "acme_archive=" <<<"$a_out"' "and reports an empty archive (got '$a_out')"
assert '[ "$(stat -c %a "$acme_dir/acme.json")" = "600" ]' "mode 600 all the same"

rm -rf "$acme_dir"; mkdir -p "$acme_dir/acme.json"
run_acme 20260822T101502Z
assert '[ "$a_rc" != "0" ]' "a directory at the path is a hard failure, as in the layout step (rc $a_rc)"
assert 'grep -qF "not a regular file" "$tmpdir/aerr"' "naming what it found (said '$(cat "$tmpdir/aerr")')"

# Every warning wall in this file opens its lines lowercase, so a reader can see
# where one warning ends and the next begins. Checked structurally: the drift
# this catches is a single line inside a block nobody reads twice.
warn_openers=$(grep -oE '^ *warn "[A-Za-z]' "$repo_dir/lib/server_init.sh" | grep -oE '.$' | sort -u | tr -d '\n')
assert '[ -n "$warn_openers" ]' "the warn lines were found (else the check below is vacuous)"
assert '[ "$warn_openers" = "$(tr "A-Z" "a-z" <<<"$warn_openers")" ]' \
    "no warn line opens with a capital (found: '$warn_openers')"

# --- The command line, through bin/kasbah ------------------------------------
# The two exports above are for the driver, which sources the libraries
# directly. bin/kasbah must not see them: it takes VERSION from beside
# KASBAH_LIB_DIR, and a checkout has no lib/VERSION.
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
    env -u KASBAH_LIB_DIR -u KASBAH_VERSION \
        PATH="$si_stub_dir:$PATH" SSH_LOG="$si_ssh_log" \
        "$kasbah" "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null
}

assert '[ "$(PATH="$si_stub_dir:$PATH" command -v ssh)" = "$si_stub_dir/ssh" ]' \
    "the stub ssh shadows any real one for the cases below"

run server; rc=$?
assert '[ "$rc" != "0" ]' "bare \`kasbah server\` fails (exit $rc)"
assert 'grep -qF "expected: init" "$tmpdir/err"' \
    "it names the subcommands that exist (said '$(cat "$tmpdir/err")')"

run server --help; rc=$?
assert '[ "$rc" = "0" ]' "\`kasbah server --help\` is help, not an unknown subcommand (exit $rc: $(cat "$tmpdir/err"))"
assert 'grep -qF "init USER@HOST" "$tmpdir/out"' "it lists the subcommands (got '$(cat "$tmpdir/out")')"
run server -h; rc=$?
assert '[ "$rc" = "0" ]' "\`kasbah server -h\` too (exit $rc)"

run server statsu; rc=$?
assert '[ "$rc" != "0" ]' "an unknown server subcommand fails (exit $rc)"
assert 'grep -qF "unknown subcommand '\''statsu'\''" "$tmpdir/err"' \
    "it names what was typed (said '$(cat "$tmpdir/err")')"

run --help
assert 'grep -qF "server init" "$tmpdir/out"' "usage advertises server init"

# Mail is built now, so --with-mail is no longer a refusal: it goes on to the
# server like any other answered run. What is checked here is that it *reaches*
# the transport rather than stopping at a leftover guard, and that it does not
# ask for the postmaster password before it knows whether the server already has
# an account — that question is settled from the server, not from the flag.
run server init deploy@kasbah-unit-test.invalid --with-mail --no-backup; rc=$?
assert '[ "$rc" = "3" ]' \
    "--with-mail goes on to the server, and this one is unreachable (exit $rc: $(cat "$tmpdir/err"))"
assert '! grep -qF "not implemented" "$tmpdir/err"' \
    "and no longer refuses (said '$(cat "$tmpdir/err")')"
assert '[ -s "$si_ssh_log" ]' "the stub ssh is what it reached (ssh saw: $(cat "$si_ssh_log"))"
assert '! grep -qF "postmaster" "$tmpdir/err"' \
    "and it did not ask for a postmaster password before reading the server (said '$(cat "$tmpdir/err")')"

# Backup is still Phase 8. Accepting the flag and doing nothing would be a lie,
# so it is a hard failure that names the phase — and the refusal comes before the
# connection, which the empty ssh log is what proves.
run server init deploy@kasbah-unit-test.invalid --no-mail --with-backup; rc=$?
assert '[ "$rc" != "0" ]' "--with-backup fails rather than silently skipping backups (exit $rc)"
assert 'grep -qF "Phase 8" "$tmpdir/err"' "--with-backup names the phase that builds it (said '$(cat "$tmpdir/err")')"
assert 'grep -qF -- "--no-backup" "$tmpdir/err"' "--with-backup says how to proceed today"
assert '[ ! -s "$si_ssh_log" ]' "and nothing was contacted first (ssh saw: $(cat "$si_ssh_log"))"

# The tri-state rule: no flag and no terminal is a hard fail naming the flag,
# never an assumed "no". Nothing is contacted first — and that half matters as
# much as the exit code, because a guard that stopped guarding would still fail
# the run, just further along and against somebody's server.
run server init deploy@kasbah-unit-test.invalid; rc=$?
assert '[ "$rc" != "0" ]' "an unanswerable mail question fails (exit $rc)"
assert 'grep -qF -- "--with-mail or --no-mail" "$tmpdir/err"' \
    "the no-TTY failure names both flags (said '$(cat "$tmpdir/err")')"
assert '[ ! -s "$si_ssh_log" ]' \
    "and the unanswered question cost no connection (ssh saw: $(cat "$si_ssh_log"))"

run server init deploy@kasbah-unit-test.invalid --no-mail; rc=$?
assert '[ "$rc" != "0" ]' "an unanswerable backup question fails (exit $rc)"
assert 'grep -qF -- "--with-backup or --no-backup" "$tmpdir/err"' \
    "the no-TTY failure names the backup flags (said '$(cat "$tmpdir/err")')"
assert '[ ! -s "$si_ssh_log" ]' \
    "and the unanswered question cost no connection (ssh saw: $(cat "$si_ssh_log"))"

# The positive control: with both questions answered the command does reach the
# transport, so the four empty logs above are about the guards and not about a
# stub that was never on PATH.
run server init deploy@kasbah-unit-test.invalid --no-mail --no-backup; rc=$?
assert '[ "$rc" = "3" ]' "an answered init goes on to the server, and this one is unreachable (exit $rc: $(cat "$tmpdir/err"))"
assert '[ -s "$si_ssh_log" ]' "and the stub ssh is what it reached (ssh saw: $(cat "$si_ssh_log"))"

# A target carrying a Windows line ending is the same target. ssh_target_parse
# strips it too, but only once a connection is being made: everything this
# command prints first — the two questions among them — reads _SI_TARGET
# directly, and a carriage return in the middle of a prompt overwrites the line
# the operator is being asked to answer.
run server init "$(printf 'deploy@kasbah-unit-test.invalid\r')"
assert '! grep -qU $'"'"'\r'"'"' "$tmpdir/err"' \
    "a CRLF target carries no carriage return into the prompt (said '$(cat -v "$tmpdir/err")')"
assert 'grep -qF "on deploy@kasbah-unit-test.invalid?" "$tmpdir/err"' \
    "and the question names the target it would act on (said '$(cat "$tmpdir/err")')"

# --- The pointer, and the second apps path it refuses -------------------------
# One kasbah per server, because one Traefik holds :80 and :443. The states come
# from the probe's two facts, so every branch below is reachable from a real
# server.
out=$(drive pointercheck /apps absent); rc=$?
assert '[ "$rc" = "0" ] && grep -qxF "pointer=accepted" <<<"$out"' \
    "no pointer is the ordinary first run, and the check returns rather than exits (exit $rc, got '$out': $(drive_err))"
out=$(drive pointercheck /apps present /apps); rc=$?
assert '[ "$rc" = "0" ] && grep -qxF "pointer=accepted" <<<"$out"' \
    "a pointer naming this very path is idempotent, not a conflict (exit $rc, got '$out': $(drive_err))"
out=$(drive pointercheck /srv/apps present /srv/apps); rc=$?
assert '[ "$rc" = "0" ] && grep -qxF "pointer=accepted" <<<"$out"' \
    "and so is a re-run at a non-default path (exit $rc, got '$out': $(drive_err))"

# The refusal itself. It has to name both paths and what would happen, because
# the alternative to reading it is a host whose every site goes dark.
drive pointercheck /apps present /srv/apps >/dev/null; rc=$?
out=$(drive_err)
assert '[ "$rc" != "0" ]' "a second, different apps path is refused (exit $rc, said '$out')"
assert 'grep -qF "/srv/apps" <<<"$out"' "naming the path the server is prepared at (said '$out')"
assert 'grep -qF "/apps" <<<"$out"'     "and the one this run would prepare (said '$out')"
assert 'grep -qF "/etc/kasbah/apps-path" <<<"$out"' "and where that is recorded (said '$out')"
assert 'grep -qF "traefik" <<<"$out"'   "and what would happen to the running proxy (said '$out')"
assert 'grep -qF "Nothing has been changed" <<<"$out"' \
    "and that this run did nothing (said '$out')"
assert 'grep -qF -- "--apps-path" <<<"$out"' \
    "and the flag that manages the server that is there (said '$out')"

# A pointer spelling the path with a `..` segment names a real directory, and
# the refusal is right to fire — but its remedy has to be one the operator can
# carry out: `--apps-path=/srv/x/..` is rejected by init's own flag check as not
# normalised, which would be a refusal loop printed by kasbah itself.
drive pointercheck /apps present /srv/x/.. >/dev/null; rc=$?
out=$(drive_err)
assert '[ "$rc" != "0" ]' "a pointer naming another tree through '..' is refused (exit $rc, said '$out')"
assert '! grep -qF -- "--apps-path=/srv/x/.." <<<"$out"' \
    "and never prescribes a flag its own parser rejects (said '$out')"
assert 'grep -qF "resolves to" <<<"$out"' \
    "asking for the directory it resolves to instead (said '$out')"
assert 'grep -qF "remove /etc/kasbah/apps-path" <<<"$out"' \
    "with the other way out still spelled (said '$out')"

drive pointercheck /srv/apps present /apps >/dev/null; rc=$?
out=$(drive_err)
assert '[ "$rc" != "0" ]' "the refusal is symmetric — the default is not privileged (exit $rc, said '$out')"

# A pointer that is not a file, and one that holds nothing usable: kasbah does
# not write over a record it cannot read, because whatever it was meant to say
# is the tree this run would stand a second Traefik beside.
drive pointercheck /apps notfile >/dev/null; rc=$?
out=$(drive_err)
assert '[ "$rc" != "0" ]' "a pointer that is not a regular file is refused (exit $rc, said '$out')"
assert 'grep -qF "not a regular file" <<<"$out"' "saying so (said '$out')"

# A directory nothing here can enter: whether this server records an apps path
# cannot be told, and "cannot tell" is not "there is none".
drive pointercheck /apps unreachable >/dev/null; rc=$?
out=$(drive_err)
assert '[ "$rc" != "0" ]' "a pointer directory nothing can enter is refused (exit $rc, said '$out')"
assert 'grep -qF "/etc/kasbah" <<<"$out"' "naming it (said '$out')"
assert 'grep -qF "chmod 755" <<<"$out"' "and how to open it (said '$out')"

# Not even root could read it. Init repairs a pointer it can read — that is the
# mode-600 case the rig covers — but what it cannot read may name another tree,
# and standing a second Traefik beside a running one is not a guess to make.
drive pointercheck /apps unreadable >/dev/null; rc=$?
out=$(drive_err)
assert '[ "$rc" != "0" ]' "a pointer nothing can read is refused (exit $rc, said '$out')"
assert 'grep -qF "cannot be read" <<<"$out"' "saying so (said '$out')"
assert 'grep -qF "traefik" <<<"$out" || grep -qF "Traefik" <<<"$out"' \
    "and what it is protecting (said '$out')"
for bad in srv/apps . ""; do
    drive pointercheck /apps present "$bad" >/dev/null; rc=$?
    out=$(drive_err)
    assert '[ "$rc" != "0" ]' "a pointer holding '$bad' is refused (exit $rc, said '$out')"
    assert 'grep -qF "not an absolute path" <<<"$out"' "saying why (said '$out')"
    assert 'grep -qF "remove /etc/kasbah/apps-path" <<<"$out"' \
        "and how to get out of it (said '$out')"
done

# --- What a pointer that could not be written costs ---------------------------
out=$(drive pointerverdict /apps written); rc=$?
assert '[ "$rc" = "0" ] && grep -qxF "verdict=ok" <<<"$out"' \
    "a written pointer is the end of it, and the verdict returns rather than exits (exit $rc, got '$out': $(drive_err))"
out=$(drive pointerverdict /apps unchanged); rc=$?
assert '[ "$rc" = "0" ] && grep -qxF "verdict=ok" <<<"$out"' \
    "and so is one that was already right (exit $rc, got '$out': $(drive_err))"

# The split the whole sudo question comes down to: at /apps the fallback covers
# it, anywhere else the server is prepared and undiscoverable.
sentinel=$(drive pointerverdict /apps nosudo); rc=$?
out=$(drive_err)
assert '[ "$rc" = "0" ] && grep -qxF "verdict=ok" <<<"$sentinel"' \
    "no sudo at the default apps path is a warning, not a failure, and the run goes on (exit $rc, got '$sentinel', said '$out')"
assert 'grep -qF "warning:" <<<"$out"' "and it does warn (said '$out')"
assert 'grep -qF "sudo -n" <<<"$out"'  "naming what was missing (said '$out')"

drive pointerverdict /srv/apps nosudo >/dev/null; rc=$?
out=$(drive_err)
assert '[ "$rc" != "0" ]' "no sudo at a non-default apps path is a hard failure (exit $rc, said '$out')"
assert 'grep -qF "/srv/apps" <<<"$out"' "naming the path nothing would find (said '$out')"
assert 'grep -qF "exit 4" <<<"$out"'    "and what deploy would do instead (said '$out')"
assert 'grep -qF "sudo tee /etc/kasbah/apps-path" <<<"$out"' \
    "and the one command that fixes it by hand (said '$out')"

drive pointerverdict /apps somethingelse >/dev/null; rc=$?
out=$(drive_err)
assert '[ "$rc" != "0" ]' "a report this kasbah does not know is a failure (exit $rc, said '$out')"

# --- The pointer step, run locally --------------------------------------------
# Extracted from its heredoc and run against a pointer path of its own. Two of
# its branches cannot be produced on the rig, whose ssh user has passwordless
# sudo: a host with no sudo at all, and one where the file is something other
# than a file. The rig proves the half this cannot — root ownership, mode 644,
# and the unchanged re-run.
payload="$tmpdir/pointer.sh"
awk '/<<'"'"'REMOTE'"'"'$/{buf=""; inb=1; next} inb && /^REMOTE$/{if (buf ~ /pointer=written/) printf "%s", buf; inb=0; next} inb{buf = buf $0 "\n"}' \
    "$repo_dir/lib/server_init.sh" > "$payload"
assert '[ -s "$payload" ]' "the pointer step was extracted from lib/server_init.sh"
assert 'grep -qF "pointer=nosudo" "$payload"' \
    "and it is the right block — every case below is empty theatre otherwise"

# A stand-in for root, because this suite is not root and must not become it.
#
#   * `-n` is required, not tolerated: a sudo that would prompt has nowhere to
#     read a password from inside a remote step, so a call without it is a
#     defect rather than a slower path. This stub answers such a call the way
#     the real one answers a caller with no terminal — it does not run.
#   * $STUB_SUDO=no is a host where sudo refuses outright.
#   * $STUB_ROOT_DIR / $STUB_ROOT_FILE are what root's *eyes* amount to here:
#     the mode is lifted for the duration of the one command and put straight
#     back, so a directory this user cannot enter and a file it cannot read are
#     both reachable through sudo and through nothing else.
#   * `chown` is faked: this user cannot hand a file to uid 0, and the rig
#     asserts that half against a real one.
#
# Every call is logged, so a step can be asked what it actually ran.
sudo_stub="$tmpdir/sudobin"
mkdir -p "$sudo_stub"
cat > "$sudo_stub/sudo" <<'STUB'
#!/usr/bin/env bash
{ printf 'sudo'; for a in "$@"; do printf '|%s' "$a"; done; printf '\n'; } >> "$STUB_SUDO_LOG"
if [ "${1:-}" != "-n" ]; then
    printf 'sudo: a terminal is required to read the password\n' >&2
    exit 97
fi
[ "${STUB_SUDO:-yes}" = yes ] || exit 1
shift
case "$1" in chown) exit 0 ;; esac
restore=""
for p in "${STUB_ROOT_DIR:-}" "${STUB_ROOT_FILE:-}"; do
    [ -n "$p" ] && [ -e "$p" ] || continue
    restore="$restore$p $(stat -c '%a' "$p")
"
    chmod u+rwx "$p" 2>/dev/null || true
done
"$@"; rc=$?
while read -r p mode; do
    [ -n "$p" ] || continue
    chmod "$mode" "$p" 2>/dev/null || true
done <<<"$restore"
exit "$rc"
STUB
chmod 0755 "$sudo_stub/sudo"
sudo_log="$tmpdir/sudo.log"
: > "$sudo_log"

pdir="$tmpdir/pointerfs"
ppath="$pdir/etc/kasbah/apps-path"
run_pointer() {
    local apps="$1"; shift
    p_rc=0
    : > "$sudo_log"
    p_out="$(env PATH="$sudo_stub:$PATH" STUB_SUDO_LOG="$sudo_log" "$@" \
             bash "$payload" "$apps" "$ppath" 2>"$tmpdir/perr")" || p_rc=$?
}

# No sudo, nothing written: the file the caller then has to have an opinion
# about is the one that is not there.
rm -rf "$pdir"; mkdir -p "$pdir/etc"
run_pointer /srv/apps STUB_SUDO=no
assert '[ "$p_rc" = "0" ]' "a host with no sudo is reported, not a transport failure (rc $p_rc: $(cat "$tmpdir/perr"))"
assert '[ "$p_out" = "pointer=nosudo" ]' "as nosudo (got '$p_out')"
assert '[ ! -e "$ppath" ]' "and nothing was written"

# With root available: one absolute path, one line, mode 644.
run_pointer /srv/apps
assert '[ "$p_rc" = "0" ]' "the pointer is written (rc $p_rc: $(cat "$tmpdir/perr"))"
assert '[ "$p_out" = "pointer=written" ]' "and says so (got '$p_out')"
assert '[ "$(cat "$ppath")" = "/srv/apps" ]' "holding the apps path (got '$(cat "$ppath" 2>&1)')"
assert '[ "$(stat -c %a "$ppath")" = "644" ]' "world-readable (got '$(stat -c %a "$ppath" 2>&1)')"
assert '[ "$(wc -l < "$ppath")" = "1" ]' "on one line (got $(wc -l < "$ppath") lines)"
assert '[ "$(stat -c %a "$pdir/etc/kasbah")" = "755" ]' \
    "in a directory anyone can traverse (got '$(stat -c %a "$pdir/etc/kasbah" 2>&1)')"
assert '[ -z "$(ls "$pdir/etc/kasbah" | grep -v "^apps-path$")" ]' \
    "and the staging file was renamed into place, not left behind (dir: $(ls -A "$pdir/etc/kasbah" | tr '\n' ' '))"

# A pointer whose content is right but whose mode is not is rewritten: a 600
# pointer is one no deploy user can read, which is the same as none.
chmod 600 "$ppath"
run_pointer /srv/apps
assert '[ "$p_out" = "pointer=written" ]' \
    "a pointer with the wrong mode is rewritten rather than left (got '$p_out')"
assert '[ "$(stat -c %a "$ppath")" = "644" ]' "back to 644 (got '$(stat -c %a "$ppath" 2>&1)')"

# A different apps path overwrites — by the time this step runs, the refusal
# above has already had its say about whether that is allowed.
run_pointer /opt/apps
assert '[ "$(cat "$ppath")" = "/opt/apps" ]' "a re-prepare rewrites it (got '$(cat "$ppath" 2>&1)')"

# The staging file is gone after a run that worked, not only after one that
# failed: it holds the apps path, and /tmp on a server is not where that lives.
stage_ok="$tmpdir/pointer-staging-ok"
mkdir -p "$stage_ok"
run_pointer /srv/apps TMPDIR="$stage_ok"
assert '[ "$p_out" = "pointer=written" ]' "the staged write succeeded (got '$p_out')"
assert '[ -z "$(ls -A "$stage_ok")" ]' \
    "and left nothing behind in TMPDIR (left: $(ls -A "$stage_ok" | tr '\n' ' '))"

# Every elevation is `sudo -n`. Without the flag sudo asks for a password, and
# a remote step has no terminal to be asked on — it would hang until the ssh
# session timed out. The stub refuses a call without it, and the log is what
# says the step never made one.
assert '[ -s "$sudo_log" ]' "the write really did elevate (sudo log: $(cat "$sudo_log"))"
assert '! grep -qv "^sudo|-n|" "$sudo_log"' \
    "and every sudo call carries -n (sudo log: $(tr '\n' ' ' < "$sudo_log"))"

# Owner as well as mode. A 644 pointer that belongs to the deploy user rather
# than to root is one that user can rewrite at will, which is not the file the
# rest of kasbah trusts — so "already right" is not content alone.
printf '/srv/apps\n' > "$ppath"
chmod 644 "$ppath"
run_pointer /srv/apps
assert '[ "$p_out" = "pointer=written" ]' \
    "a pointer with the right content and the wrong owner is rewritten (got '$p_out')"

# A pointer this user cannot read at all: rewritten, and silently. The `-r`
# guard is what keeps a failed redirect out of the operator's terminal.
printf '/srv/apps\n' > "$ppath"
chmod 000 "$ppath"
if [ ! -r "$ppath" ]; then
    run_pointer /srv/apps
    assert '[ "$p_out" = "pointer=written" ]' "an unreadable pointer is rewritten (got '$p_out')"
    assert '[ ! -s "$tmpdir/perr" ]' \
        "with nothing on stderr — the step reads no file it cannot read (said '$(cat "$tmpdir/perr")')"
else
    assert 'true' "skipped: this user can read a mode-000 file"
fi
chmod 644 "$ppath"

# A step that fails half way takes its staging file with it: the apps path must
# not be left lying in /tmp on the server.
stage_dir="$tmpdir/pointer-staging"
mkdir -p "$stage_dir"
locked="$tmpdir/locked"
rm -rf "$locked"; mkdir -p "$locked"; chmod 555 "$locked"
saved_ppath="$ppath"
ppath="$locked/kasbah/apps-path"
run_pointer /srv/apps TMPDIR="$stage_dir"
assert '[ "$p_rc" != "0" ]' "a pointer directory that cannot be created is a failure (rc $p_rc)"
assert '[ -z "$(ls -A "$stage_dir")" ]' \
    "and the staging file went with it (left: $(ls -A "$stage_dir" | tr '\n' ' '))"
chmod 755 "$locked"; rm -rf "$locked"
ppath="$saved_ppath"

rm -f "$ppath"; mkdir -p "$ppath"
run_pointer /srv/apps
assert '[ "$p_rc" != "0" ]' "a directory where the pointer belongs is a failure (rc $p_rc)"
assert 'grep -qF "not a regular file" "$tmpdir/perr"' "saying so (said '$(cat "$tmpdir/perr")')"
rmdir "$ppath"

# --- The prerequisite probe's pointer facts, run locally ------------------------
# The one remote payload in this change that nothing else runs. Extracted the
# same way as the pointer step and pointed at a scratch tree, because the states
# it has to tell apart — a pointer only root can read, one behind a directory
# this user cannot enter, one that is not there at all — are the states whose
# verdicts differ, and the rig can only ever be in the easy one.
probe_payload="$tmpdir/probe.sh"
awk '/<<'"'"'REMOTE'"'"'$/{buf=""; inb=1; next} inb && /^REMOTE$/{if (buf ~ /kv pointer_state/) printf "%s", buf; inb=0; next} inb{buf = buf $0 "\n"}' \
    "$repo_dir/lib/server_init.sh" > "$probe_payload"
assert '[ -s "$probe_payload" ]' "the prerequisite probe was extracted from lib/server_init.sh"
assert 'grep -qF "kv memtotal_kb" "$probe_payload"' \
    "and it is the whole probe — every case below is empty theatre otherwise"

probe_root="$tmpdir/probefs"
probe_ptr="$probe_root/etc/kasbah/apps-path"
probe_out=""
run_probe() {
    : > "$sudo_log"
    probe_out="$(env PATH="$sudo_stub:$PATH" STUB_SUDO_LOG="$sudo_log" "$@" \
        bash "$probe_payload" "$probe_root/apps" "$probe_root/apps/data" "$probe_ptr" 2>/dev/null)"
}
pfact() { sed -n "s/^$1=//p" <<<"$probe_out"; }

rm -rf "$probe_root"; mkdir -p "$probe_root/etc/kasbah"
run_probe
assert '[ "$(pfact pointer_state)" = "absent" ]' \
    "no pointer is reported as absent (got '$(pfact pointer_state)')"
assert '[ "$(pfact pointer_value)" = "" ]' "with no value (got '$(pfact pointer_value)')"
# flock, probed here with the other prerequisites rather than discovered by
# rd_lock mid-deploy. This workstation has it, so the probe answering `yes` is
# what says the row exists at all; the `no` verdict is driven above.
assert '[ "$(pfact have_flock)" = "yes" ]' \
    "flock is probed alongside rsync, openssl and gzip (got '$(pfact have_flock)')"
# And the fact is required, not merely emitted: a key nothing checks is one that
# can quietly stop arriving, and the preflight would then read an unset value.
assert 'grep -qF "have_gzip have_flock" "$repo_dir/lib/server_init.sh"' \
    "and _server_init_probe's protocol check names it with the others"
assert '[ "$(pfact sudo_nopasswd)" = "yes" ]' \
    "and the sudo row is asked with -n (got '$(pfact sudo_nopasswd)', sudo log: $(tr '\n' ' ' < "$sudo_log"))"
assert '! grep -qv "^sudo|-n|" "$sudo_log"' \
    "every sudo the probe runs carries -n (sudo log: $(tr '\n' ' ' < "$sudo_log"))"

printf '%s\n' "/srv/apps/" > "$probe_ptr"
run_probe
assert '[ "$(pfact pointer_state)" = "present" ]' "a pointer is read (got '$(pfact pointer_state)')"
assert '[ "$(pfact pointer_value)" = "/srv/apps" ]' \
    "and normalised, so it compares with a --apps-path the same way (got '$(pfact pointer_value)')"

# Only root can read it. Init repairs such a pointer — but not before it knows
# what it says, because what it says may be another tree.
chmod 000 "$probe_ptr"
if [ ! -r "$probe_ptr" ]; then
    run_probe STUB_ROOT_FILE="$probe_ptr"
    assert '[ "$(pfact pointer_state)" = "present" ]' \
        "a pointer only root can read is read with root's eyes (got '$(pfact pointer_state)')"
    assert '[ "$(pfact pointer_value)" = "/srv/apps" ]' "with its value (got '$(pfact pointer_value)')"
    # And when root cannot help either — no sudo, or a sudo that answers
    # nothing — an empty read must never stand in for "there is no pointer".
    run_probe
    assert '[ "$(pfact pointer_state)" = "unreadable" ]' \
        "a read that came back empty is not a pointer holding nothing (got '$(pfact pointer_state)')"
    run_probe STUB_SUDO=no
    assert '[ "$(pfact pointer_state)" = "unreadable" ]' \
        "and neither is a host with no sudo to look with (got '$(pfact pointer_state)')"
else
    assert 'true' "skipped: this user can read a mode-000 file"
fi
chmod 644 "$probe_ptr"

# The directory, which is the harder half: `[ -e ]` answers "no" for a pointer
# behind a directory this user cannot enter, exactly as it does for one that is
# not there — and the second means "this server is at /apps" while the first may
# mean "this server is somewhere else entirely".
chmod 000 "$probe_root/etc/kasbah"
if [ ! -x "$probe_root/etc/kasbah" ]; then
    run_probe STUB_ROOT_DIR="$probe_root/etc/kasbah"
    assert '[ "$(pfact pointer_state)" = "present" ]' \
        "root looks inside a directory this user cannot enter (got '$(pfact pointer_state)')"
    assert '[ "$(pfact pointer_value)" = "/srv/apps" ]' "and finds it (got '$(pfact pointer_value)')"
    run_probe STUB_SUDO=no
    assert '[ "$(pfact pointer_state)" = "unreachable" ]' \
        "and with no sudo the answer is 'cannot tell', never 'absent' (got '$(pfact pointer_state)')"
else
    assert 'true' "skipped: this user can enter a mode-000 directory"
fi
chmod 755 "$probe_root/etc/kasbah"

# The same directory, with no pointer in it: root's eyes say absent, and absent
# is the ordinary first run.
rm -f "$probe_ptr"
chmod 000 "$probe_root/etc/kasbah"
if [ ! -x "$probe_root/etc/kasbah" ]; then
    run_probe STUB_ROOT_DIR="$probe_root/etc/kasbah"
    assert '[ "$(pfact pointer_state)" = "absent" ]' \
        "root can also say there is nothing there (got '$(pfact pointer_state)')"
else
    assert 'true' "skipped: this user can enter a mode-000 directory"
fi
chmod 755 "$probe_root/etc/kasbah"

# --- The call sites -------------------------------------------------------------
# Everything above tests these functions. What the functions cannot say is
# whether anything calls them, and three of the decisions in this file are
# decisions about *when*: the refusal has to run before the layout, the verdict
# has to run at all, and the pointer has to follow the marker so that a run
# which dies earlier leaves neither.
# Read with the indentation taken off, so the calls match as whole lines and a
# name that merely appears inside a longer one cannot stand in for a call.
cmd_body="$(sed -n '/^cmd_server_init() {/,/^}/p' "$repo_dir/lib/server_init.sh" | sed 's/^[[:space:]]*//')"
assert '[ -n "$cmd_body" ]' "cmd_server_init's body was found in lib/server_init.sh"
line_in() { grep -n -m1 -xF "$1" <<<"$cmd_body" | cut -d: -f1; }
n_check=$(line_in '_server_init_check_pointer')
n_layout=$(line_in '_server_init_layout')
n_marker=$(line_in '_server_init_marker "$marker_json"')
n_pointer=$(line_in '_server_init_pointer')
assert '[ -n "$n_check" ]' "cmd_server_init calls _server_init_check_pointer (body: $(tr '\n' ' ' <<<"$cmd_body" | head -c 200))"
assert '[ -n "$n_pointer" ]' "and _server_init_pointer"
assert '[ -n "$n_check" ] && [ -n "$n_layout" ] && [ "$n_check" -lt "$n_layout" ]' \
    "the refusal runs before anything is created (check $n_check, layout $n_layout)"
assert '[ -n "$n_marker" ] && [ -n "$n_pointer" ] && [ "$n_pointer" -gt "$n_marker" ]' \
    "and the pointer is written after the marker, so a run that dies earlier leaves neither (marker $n_marker, pointer $n_pointer)"

pointer_body="$(sed -n '/^_server_init_pointer() {/,/^}/p' "$repo_dir/lib/server_init.sh")"
assert 'grep -qF "_server_init_pointer_verdict" <<<"$pointer_body"' \
    "the pointer step reaches its verdict — the whole sudo split hangs off that one call"

exit "$fail"
