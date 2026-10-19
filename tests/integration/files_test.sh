#!/usr/bin/env bash
# Integration test: the files a real run writes are the files docs/files.md
# lists — on the rig and on this workstation, by path, mode and owner.
#
# The run is the whole life of one project on a fully equipped server: `server
# init --with-mail --with-backup`, build-push and deploy of two versions of the
# built-app fixture, and a rollback. Afterwards every entry under the server
# roots (rig_files_snapshot), and everything new in the project tree and the
# scratch HOME, must each match a row of the document; where a row fixes a mode
# or an owner, the entry must carry it. Every step succeeded, so nothing may be
# left in the run's TMPDIR, the rig's /tmp or the deploy user's home, and no
# *transient* row may match. A list of rows the run must have produced closes
# the other side.
#
# Set KASBAH_FILES_SNAPSHOT_DIR to keep the snapshots: names are normalized, so
# two binaries' runs diff line for line.
#
# Exit status follows test.sh's contract: 0 pass, 1 an assertion failed, 2 the
# suite could not run at all (no rig, no docker, no backup harness).

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
. "$repo_dir/tests/integration/rig_env.sh"
. "$repo_dir/tests/fixture_repo.sh"

doc="$repo_dir/docs/files.md"
apps=/apps
data=$apps/data
marker="$apps/.kasbah/server.json"
deploy_user="$RIG_SSH_USER:$RIG_SSH_USER"

rig_domain=rig.test
traefik_flags=(--domain="$rig_domain" --email="ops@$rig_domain"
               --traefik-auth="dashadmin:rig-dashboard-pw")
project=built-app
v1=3.1.0
v2=3.2.0
image_web=built-app-web
image_worker=built-app-worker
run_id="f$$-$(date +%s)"

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

tmpdir="$(mktemp -d)"
cleanup() {
    rig_ssh "docker image rm -f $image_web:$v1 $image_worker:$v1 $image_web:$v2 $image_worker:$v2 $image_web:current $image_worker:current; rm -f /tmp/$project-*.tar.gz" >/dev/null 2>&1
    docker image rm -f "$image_web:$v1" "$image_worker:$v1" "$image_web:$v2" "$image_worker:$v2" \
        "$image_web:current" "$image_worker:current" >/dev/null 2>&1
    rm -rf "$tmpdir"
}
trap cleanup EXIT

# --- Preconditions ------------------------------------------------------------
if [ ! -f "$RIG_SSH_CONFIG" ]; then
    echo "error: no $RIG_SSH_CONFIG — the suite needs a running rig: tests/rig/rig.sh up" >&2
    exit 2
fi
if ! command -v docker >/dev/null; then
    echo "error: this suite builds images on this workstation, and docker is not on PATH" >&2
    exit 2
fi
if ! rig_reachable; then
    echo "error: the rig did not answer ssh — is it up? tests/rig/rig.sh up" >&2
    exit 2
fi
if ! rig_backup_ready; then
    echo "error: the rig's backup harness did not answer (tests/rig/rig.sh up writes $RIG_BACKUP_ENV)" >&2
    exit 2
fi
if [ ! -f "$doc" ]; then
    echo "error: no $doc to check the run against" >&2
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
# A reset rig has an empty image store (10-recast.md Findings).
for image in "$RIG_RESTIC_IMAGE" nginx:alpine redis:7-alpine; do
    if ! rig_ssh "docker image inspect $image >/dev/null 2>&1 || docker pull -q $image" >/dev/null 2>&1; then
        echo "error: the rig could not pull $image" >&2
        exit 2
    fi
done

# --- docs/files.md as data ----------------------------------------------------
# One row per backticked path pattern in the first column, under a heading that
# says which side it is on. Printed as `side<TAB>pattern<TAB>mode<TAB>owner<TAB>t`,
# t being 1 for a *transient* row.
doc_rows() {
    awk -F'|' '
        /^## /           { side = "" }
        /^## On a VPS/   { side = "vps" }
        /^## On the workstation/ { side = "ws" }
        side != "" && /^\| `/ {
            p = $2; m = $6; o = $7; t = ($8 ~ /\*transient\*/) ? 1 : 0
            gsub(/^ *`|` *$/, "", p); gsub(/^ +| +$/, "", m); gsub(/^ +| +$/, "", o)
            print side "\t" p "\t" m "\t" o "\t" t
        }' "$doc"
}

# What a placeholder stands for in this run. `<apps>`, `<data>` and the names
# this run chose are substituted, so `<apps>/<project>/.env` cannot be vouched
# for by /apps/mail/.env; on the workstation `<project-dir>`, `<tmp>` and `~` are
# the labels the local snapshots print. Any other `<name>` is one path segment.
regex_meta='.[]()*+?{}|^$\'
# ere_quote STRING — STRING as an ERE matching only itself.
ere_quote() {
    local s=$1 c out=""
    while [ -n "$s" ]; do
        c=${s:0:1}; s=${s:1}
        if [[ $regex_meta == *"$c"* ]]; then out+="\\$c"; else out+=$c; fi
    done
    printf '%s' "$out"
}
versions_re="($(ere_quote "$v1")|$(ere_quote "$v2"))"
declare -A ph_vps=([apps]=$apps [data]=$data [project]=$project
                   [version]=$versions_re [repo]="($(ere_quote "$project")|mail)")
declare -A ph_ws=([project-dir]='<project-dir>' [tmp]='<tmp>' [project]=$project
                  [version]=$versions_re)
# pattern_regex SIDE PATTERN — sets RX (anchored ERE) and LIT, the count of
# literal characters: the more, the more specific the row. `*` is within a
# segment, `/**` the entry and anything below it.
pattern_regex() {
    local side=$1 p=$2 c name val
    RX="" LIT=0
    while [ -n "$p" ]; do
        case $p in
            '<'*'>'*)
                name=${p#<}; name=${name%%>*}; p=${p#*>}
                if [ "$side" = vps ]; then val=${ph_vps[$name]:-}; else val=${ph_ws[$name]:-}; fi
                if [ -z "$val" ]; then RX+='[^/]+'
                elif [[ $val == \(* ]]; then RX+=$val; LIT=$((LIT + ${#name}))
                else
                    while [ -n "$val" ]; do
                        c=${val:0:1}; val=${val:1}; LIT=$((LIT + 1))
                        if [[ $regex_meta == *"$c"* ]]; then RX+="\\$c"; else RX+=$c; fi
                    done
                fi ;;
            '/**'*)    RX+='(/.*)?'; p=${p#'/**'} ;;
            '*'*)      RX+='[^/]*'; p=${p#'*'} ;;
            *)         c=${p:0:1}; p=${p:1}; LIT=$((LIT + 1))
                       if [[ $regex_meta == *"$c"* ]]; then RX+="\\$c"; else RX+=$c; fi ;;
        esac
    done
    RX="^$RX\$"
}

# The matcher checks itself first: a literal `.` or `$` that matched anything
# would let every row vouch for its neighbours.
pattern_regex vps '<apps>/a.b$c'
assert '[[ "$apps/a.b\$c" =~ $RX ]]' "a pattern matches its own path (RX $RX)"
assert '! [[ "$apps/axb\$c" =~ $RX ]]' "a literal . in a pattern is not a wildcard (RX $RX)"
assert '! [[ "$apps/a.bc" =~ $RX ]]' "a literal \$ in a pattern is not an anchor (RX $RX)"
pattern_regex vps '<apps>/<project>/.env'
assert '! [[ "$apps/mail/.env" =~ $RX ]]' "<project> is this run's project, not any segment (RX $RX)"

# rig_files_new must see a new leftover that normalizes to an old one's name.
printf '%s\n' '/tmp/tmp.AbC123xyz0 700 u:g d' > "$tmpdir/left.before"
printf '%s\n' '/tmp/tmp.AbC123xyz0 700 u:g d' '/tmp/tmp.ZzY987qrs1 700 u:g d' > "$tmpdir/left.after"
left_new=$(rig_files_new "$tmpdir/left.before" "$tmpdir/left.after")
assert '[ "$left_new" = "/tmp/tmp.XXXXXX 700 u:g d" ]' \
    "a new leftover shaped like an old one is reported (got '$left_new')"
assert '[[ "$v1" =~ ^$versions_re$ ]] && ! [[ "3x1x0" =~ ^$versions_re$ ]]' \
    "<version> values are escaped (RX $versions_re)"

row_side=() row_pat=() row_rx=() row_lit=() row_mode=() row_owner=() row_transient=()
while IFS=$'\t' read -r side pat mode owner transient; do
    # `<path>` rows (whatever `sync:` names) document; they cannot vouch for a file.
    [[ $pat != *'<path>'* ]] || continue
    pattern_regex "$side" "$pat"
    row_side+=("$side"); row_pat+=("$pat"); row_rx+=("$RX"); row_lit+=("$LIT")
    row_mode+=("$mode"); row_owner+=("$owner"); row_transient+=("$transient")
done < <(doc_rows)
assert '[ "${#row_pat[@]}" -ge 20 ]' "docs/files.md parses into rows (got ${#row_pat[@]})"

# The most specific row of SIDE matching PATH; sets ROW (-1 when none).
best_row() {
    local side=$1 path=$2 i best=-1 lit=-1
    for i in "${!row_pat[@]}"; do
        [ "${row_side[$i]}" = "$side" ] || continue
        [[ $path =~ ${row_rx[$i]} ]] || continue
        if [ "${row_lit[$i]}" -gt "$lit" ]; then best=$i; lit=${row_lit[$i]}; fi
    done
    ROW=$best
}

# A row's mode or owner is checked only when the cell is exactly one backticked
# value; prose ("umask", "the container's") is documentation, not a contract.
fixed() { [[ $1 =~ ^\`([^\`]+)\`$ ]] && printf '%s' "${BASH_REMATCH[1]}"; }

# check_listing SIDE FILE OWNER — every line of FILE against the document. Every
# step of the run succeeded, so a path whose row is *transient* is a leftover.
check_listing() {
    local side=$1 file=$2 me=$3 path mode owner type want
    while read -r path mode owner type; do
        [ -n "$path" ] || continue
        best_row "$side" "$path"
        if [ "$ROW" -lt 0 ]; then
            echo "  FAIL: $path ($mode $owner $type) is written but no row of docs/files.md covers it" >&2
            fail=1; continue
        fi
        if [ "${row_transient[$ROW]}" = 1 ]; then
            echo "  FAIL: $path is transient (\`${row_pat[$ROW]}\`) and outlived a run that succeeded" >&2
            fail=1
        fi
        want=$(fixed "${row_mode[$ROW]}")
        if [ -n "$want" ] && [ "$((8#$want))" != "$((8#$mode))" ]; then
            echo "  FAIL: $path is mode $mode; row \`${row_pat[$ROW]}\` says $want" >&2
            fail=1
        fi
        want=$(fixed "${row_owner[$ROW]}")
        [ "$want" != deploy ] || want=$me
        if [ -n "$want" ] && [ "$want" != "$owner" ]; then
            echo "  FAIL: $path is owned $owner; row \`${row_pat[$ROW]}\` says $want" >&2
            fail=1
        fi
    done < "$file"
    return 0
}

# require SIDE FILE PATTERN... — each pattern is a row, and the run produced it.
require() {
    local side=$1 file=$2 pat i found paths
    shift 2
    paths=$(cut -d' ' -f1 "$file")
    for pat in "$@"; do
        found=-1
        for i in "${!row_pat[@]}"; do
            [ "${row_side[$i]}" = "$side" ] && [ "${row_pat[$i]}" = "$pat" ] && { found=$i; break; }
        done
        if [ "$found" -lt 0 ]; then
            echo "  FAIL: \`$pat\` is not a $side row of docs/files.md" >&2
            fail=1; continue
        fi
        if ! grep -qE "${row_rx[$found]}" <<<"$paths"; then
            echo "  FAIL: the run should have written \`$pat\`, and nothing matches it" >&2
            fail=1
        fi
    done
    return 0
}

# --- The run ------------------------------------------------------------------
work_tmp="$tmpdir/tmp"
mkdir -p "$work_tmp"
projdir="$tmpdir/$project"
run() (
    cd "${RUN_DIR:-$tmpdir}" || return 2
    timeout "${RUN_TIMEOUT:-600}" env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" TMPDIR="$work_tmp" \
        "$KASBAH_BIN" "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null
)
step() {
    local what=$1 rc=0
    shift
    "$@" || rc=$?
    if [ "$rc" != 0 ]; then
        echo "error: $what failed (exit $rc) — the written-file set cannot be judged" >&2
        sed 's/^/       | /' "$tmpdir/err" >&2
        exit 2
    fi
}

snap_dir="$tmpdir/snap"
before="$tmpdir/before"
mkdir -p "$snap_dir" "$before"
shared_roots=(/tmp "/home/$RIG_SSH_USER")
rig_files_snapshot -r "${shared_roots[@]}" > "$before/shared" ||
    { echo "error: could not snapshot the rig's /tmp and home" >&2; exit 2; }
rig_files_local -r "$RIG_HOME" '~' > "$before/home" ||
    { echo "error: could not snapshot the scratch HOME" >&2; exit 2; }

step "server init --with-mail --with-backup" run server init "$RIG_TARGET" \
    "${traefik_flags[@]}" --with-mail --postmaster-password=rig-postmaster-pw \
    --with-backup --no-backup-env --backup-repo-base="${RIG_BACKUP_REPO_BASE}$run_id/" \
    --backup-password="$project=rig-project-repo-pw" --backup-password="mail=rig-mail-repo-pw"

# The rig cannot apply cgroup limits; the marker is rewritten to Docker's "no
# limit" in place, as every deploying rig suite does (02-spine.md Findings).
probe=$(rig_ssh "docker run --rm --cpus 0.5 --memory 64m nginx:alpine /bin/true 2>&1"); probe_rc=$?
if [ "$probe_rc" -ne 0 ]; then
    grep -qF "threaded mode" <<<"$probe" || { echo "error: the cgroup-limit probe failed (rc $probe_rc)" >&2; exit 2; }
    new_marker=$(rig_ssh "cat $marker" | jq '.cpu_limit = "0" | .mem_limit = "0"') &&
        [ -n "$new_marker" ] && rig_ssh "cat > $marker" <<<"$new_marker" >/dev/null ||
        { echo "error: could not relax the marker's limits on the rig" >&2; exit 2; }
fi

step "making the fixture repo" fixture_repo_make "$projdir" "$repo_dir/tests/fixtures/$project" "v$v1"
rig_files_local -r "$projdir" '<project-dir>' > "$before/project" ||
    { echo "error: could not snapshot the project tree" >&2; exit 2; }
RUN_DIR=$projdir
step "build-push $v1" run build-push "$RIG_TARGET"
# The first deploy stops for an .env it has no terminal to set up; the server's
# own kasbah renders it, as the operator would.
first_rc=0
run deploy "$RIG_TARGET" || first_rc=$?
if [ "$first_rc" = 0 ] || ! grep -qF ".env does not exist yet" "$tmpdir/err"; then
    echo "error: the first deploy did not stop for the missing .env (exit $first_rc)" >&2
    sed 's/^/       | /' "$tmpdir/err" >&2
    exit 2
fi
step "rendering the .env" rig_setup_env "$apps/$project" </dev/null >/dev/null
step "deploy $v1" run deploy "$RIG_TARGET"
# The suite's own edit, not kasbah's: an existing path, so never a new entry.
sed -i "s|served-by-built-app-from-an-image-shipped-over-ssh|served-by-built-app-edition-two|" "$projdir/Dockerfile"
step "cutting $v2" bash -c "cd '$projdir' && git commit -qam 'edition two' && git tag v$v2"
step "build-push $v2" run build-push "$RIG_TARGET"
step "deploy $v2" run deploy "$RIG_TARGET"
step "rollback" run rollback "$RIG_TARGET"

# --- Snapshots ----------------------------------------------------------------
# Container-filled trees are listed down to the directory kasbah made: what DMS,
# SnappyMail and the project's own bind mount put inside them is theirs.
rig_files_snapshot \
    -x "$data/mail/dms/mail-data" -x "$data/mail/dms/mail-state" -x "$data/mail/dms/mail-logs" \
    -x "$data/mail/snappymail" -x "$apps/$project/state" \
    "${RIG_SNAPSHOT_ROOTS[@]}" > "$snap_dir/vps" ||
    { echo "error: could not snapshot the server roots" >&2; exit 2; }
rig_files_snapshot -r "${shared_roots[@]}" > "$tmpdir/shared.after" ||
    { echo "error: could not snapshot the rig's /tmp and home" >&2; exit 2; }
rig_files_new "$before/shared" "$tmpdir/shared.after" > "$snap_dir/vps.shared"
rig_files_local -r "$projdir" '<project-dir>' > "$tmpdir/project.after" &&
    rig_files_local -r "$RIG_HOME" '~' > "$tmpdir/home.after" &&
    rig_files_local "$work_tmp" '<tmp>' > "$tmpdir/tmp.after" ||
    { echo "error: could not snapshot the workstation side" >&2; exit 2; }
rig_files_new "$before/project" "$tmpdir/project.after" > "$snap_dir/ws.project"
rig_files_new "$before/home" "$tmpdir/home.after" > "$snap_dir/ws.home"
grep -v '^<tmp> ' "$tmpdir/tmp.after" > "$snap_dir/ws.tmp"
rig_docker_snapshot > "$snap_dir/docker"
if [ -n "${KASBAH_FILES_SNAPSHOT_DIR:-}" ]; then
    mkdir -p "$KASBAH_FILES_SNAPSHOT_DIR" && cp "$snap_dir"/* "$KASBAH_FILES_SNAPSHOT_DIR/"
fi

assert '[ "$(wc -l < "$snap_dir/vps")" -ge 40 ]' \
    "the server snapshot holds a whole server ($(wc -l < "$snap_dir/vps") entries)"

# --- Every written path is a row ----------------------------------------------
me_local="$(id -un):$(id -gn)"
# The fixture's own `sync:` directory is the `<path>` row's: the project's, not
# a name kasbah owns.
grep -v "^$apps/$project/state[ /]" "$snap_dir/vps" > "$tmpdir/vps.kasbah"
check_listing vps "$tmpdir/vps.kasbah" "$deploy_user"
check_listing ws "$snap_dir/ws.project" "$me_local"
check_listing ws "$snap_dir/ws.home" "$me_local"

# --- Nothing outlives a run that succeeded ------------------------------------
assert '[ ! -s "$snap_dir/vps.shared" ]' \
    "nothing is left in the rig's /tmp or home: $(tr '\n' ';' < "$snap_dir/vps.shared")"
assert '[ ! -s "$snap_dir/ws.tmp" ]' \
    "nothing is left in the run's TMPDIR: $(tr '\n' ';' < "$snap_dir/ws.tmp")"

# --- Every row this run must produce exists -----------------------------------
require vps "$snap_dir/vps" \
    /etc/kasbah /etc/kasbah/apps-path \
    '<apps>' '<apps>/.kasbah' '<apps>/.kasbah/server.json' \
    '<apps>/.kasbah/backup' '<apps>/.kasbah/backup/compose.yml' '<apps>/.kasbah/backup/backup.sh' \
    '<apps>/.kasbah/backup/env' '<apps>/.kasbah/backup/repos' '<apps>/.kasbah/backup/repos/<repo>.pass' \
    '<apps>/traefik' '<apps>/traefik/compose.yml' '<apps>/traefik/traefik.yml' \
    '<apps>/traefik/dynamic' '<apps>/traefik/dynamic/_shared.yml' '<apps>/traefik/dynamic/_mail.yml' \
    '<apps>/traefik/dynamic/<project>.yml' \
    '<apps>/mail' '<apps>/mail/compose.yml' '<apps>/mail/kasbah.yml' '<apps>/mail/.env' \
    '<data>' '<data>/traefik/letsencrypt/acme.json' \
    '<data>/mail/dms/config/postfix-accounts.cf' \
    '<data>/mail/dms/config/rspamd/override.d/dkim_signing.conf' \
    '<apps>/backups' \
    '<apps>/<project>' '<apps>/<project>/compose.yml' '<apps>/<project>/.env' \
    '<apps>/<project>/.env.prod.example' '<apps>/<project>/versions.log' \
    '<apps>/<project>/.kasbah-client' '<apps>/<project>/backups/pre-deploy-*' '<data>/<project>'
require ws "$snap_dir/ws.project" '<project-dir>/.kasbah' '<project-dir>/.kasbah/state.json'

# --- Docker objects -----------------------------------------------------------
docker_list=$(cat "$snap_dir/docker")
for want in "network kasbah-net" "image $image_web:$v1" "image $image_web:$v2" "image $image_web:current" \
            "image $image_worker:current" "project traefik" "project mail" "project $project" "project kasbah-backup"; do
    assert 'grep -qxF "$want" <<<"$docker_list"' "the rig holds $want (docs/files.md → Docker objects)"
done

# --- Leave the rig as it was found, but only on success -----------------------
# rig_clean downs every compose project — mail and the backup stack included —
# and removes kasbah-net, /apps and /etc/kasbah; the images it leaves go here.
if [ "$fail" -eq 0 ]; then
    rig_ssh "docker image rm -f $image_web:$v1 $image_worker:$v1 $image_web:$v2 $image_worker:$v2 $image_web:current $image_worker:current" >/dev/null 2>&1
    rig_clean || fail=1
fi
[ "$fail" = 0 ] && echo "files_test: the run wrote exactly what docs/files.md lists"
exit "$fail"
