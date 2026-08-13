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

drive() { bash "$driver" "$@" 2>"$tmpdir/err"; }
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

# Every rejection below is a flag the command must not silently accept. The
# --domain/--email/--traefik-auth trio belongs to the Traefik unit: accepted
# here they would be knobs that change nothing.
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
reject "an unknown flag"         "--domain=x"            deploy@vps --domain=x
reject "--email="                "--email=a@b.c"         deploy@vps --email=a@b.c
reject "--traefik-auth="         "--traefik-auth=u:p"    deploy@vps --traefik-auth=u:p
reject "an empty --apps-path"    "must not be empty"     deploy@vps --apps-path=
reject "an empty --data-path"    "must not be empty"     deploy@vps --data-path=
reject "a relative apps path"    "must be an absolute"   deploy@vps --apps-path=apps
reject "the filesystem root"     "filesystem root"       deploy@vps --apps-path=/
reject "a path with .."          "normalised"            deploy@vps --apps-path=/srv/../apps
reject "a path with a newline"   "must not contain a newline" deploy@vps "--apps-path=$(printf '/srv/a\nb')"
reject "contradicting mail flags"   "cannot both be given" deploy@vps --with-mail --no-mail
reject "contradicting backup flags" "cannot both be given" deploy@vps --no-backup --with-backup

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

# --- The command line, through bin/hosting ------------------------------------
# The two exports above are for the driver, which sources the libraries
# directly. bin/hosting must not see them: it takes VERSION from beside
# HOSTING_LIB_DIR, and a checkout has no lib/VERSION.
run() {
    env -u HOSTING_LIB_DIR -u HOSTING_VERSION \
        "$hosting" "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null
}

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
# nothing would be a lie, so it is a hard failure that names the phase — and it
# happens before anything is opened, which is why this is a hermetic test.
run server init deploy@hosting-unit-test.invalid --with-mail --no-backup; rc=$?
assert '[ "$rc" != "0" ]' "--with-mail fails rather than silently skipping mail (exit $rc)"
assert 'grep -qF "Phase 7" "$tmpdir/err"' "--with-mail names the phase that builds it (said '$(cat "$tmpdir/err")')"
assert 'grep -qF -- "--no-mail" "$tmpdir/err"' "--with-mail says how to proceed today"

run server init deploy@hosting-unit-test.invalid --no-mail --with-backup; rc=$?
assert '[ "$rc" != "0" ]' "--with-backup fails rather than silently skipping backups (exit $rc)"
assert 'grep -qF "Phase 8" "$tmpdir/err"' "--with-backup names the phase that builds it (said '$(cat "$tmpdir/err")')"
assert 'grep -qF -- "--no-backup" "$tmpdir/err"' "--with-backup says how to proceed today"

# The tri-state rule: no flag and no terminal is a hard fail naming the flag,
# never an assumed "no". Nothing is contacted first.
run server init deploy@hosting-unit-test.invalid; rc=$?
assert '[ "$rc" != "0" ]' "an unanswerable mail question fails (exit $rc)"
assert 'grep -qF -- "--with-mail or --no-mail" "$tmpdir/err"' \
    "the no-TTY failure names both flags (said '$(cat "$tmpdir/err")')"

run server init deploy@hosting-unit-test.invalid --no-mail; rc=$?
assert '[ "$rc" != "0" ]' "an unanswerable backup question fails (exit $rc)"
assert 'grep -qF -- "--with-backup or --no-backup" "$tmpdir/err"' \
    "the no-TTY failure names the backup flags (said '$(cat "$tmpdir/err")')"

exit "$fail"
