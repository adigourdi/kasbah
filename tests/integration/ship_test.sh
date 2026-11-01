#!/usr/bin/env bash
# Integration test: `kasbah build-push` — an image built on this workstation
# reaches the rig's own daemon without a registry.
#
# The one thing a hermetic suite cannot check: that `docker save | gzip`,
# streamed over ssh into `kasbah remote load`, really moves an image between two
# daemons, and that what arrives is the image that was built rather than a name
# that happens to match.
# So every assertion is read back off the rig, and the strongest of them opens
# the arrived image and looks at the file the Dockerfile wrote into it.
#
# The rig is treated as given: this suite never starts, resets or stops it. It
# does call rig_clean, which establishes a known starting state — and which
# deliberately leaves images alone, so the images this suite loads are removed
# by name here.
#
# Exit status follows test.sh's contract: 0 pass, 1 an assertion failed, 2 the
# suite could not run at all (no rig, no docker).

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
. "$repo_dir/tests/integration/rig_env.sh"
. "$repo_dir/tests/fixture_repo.sh"

project=built-app
project_version=1.5.0
# Both of the fixture's built services. Two, because one cannot tell a stream
# that carried every image from one that carried an image, and because the far
# side's loaded= count is right by accident with one.
image_web=built-app-web
image_worker=built-app-worker
web="$image_web:$project_version"
worker="$image_worker:$project_version"
# The strings the two Dockerfiles bake in. Read out of the *arrived* images, so
# "the image shipped" means its contents, not its name.
web_marker=served-by-built-app-from-an-image-shipped-over-ssh
worker_marker=built-app-worker-payload-shipped-over-ssh

# The re-push: the same project with only the web page changed.
web2="$image_web:1.5.1"
worker2="$image_worker:1.5.1"

stock=demo
stock_version=2.0.0

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

tmpdir="$(mktemp -d)"
# Both daemons keep the images this suite loads: rig_clean leaves images alone
# by design, and the workstation's docker is not this suite's to sweep. Removed
# by exact name, here and on the rig, whatever happens.
cleanup() {
    rig_ssh "docker image rm -f $web $worker $web2 $worker2 $image_web:current $image_worker:current" >/dev/null 2>&1
    docker image rm -f "$web" "$worker" "$web2" "$worker2" "$image_web:current" "$image_worker:current" >/dev/null 2>&1
    rm -rf "$tmpdir"
}
trap cleanup EXIT

# --- Preconditions --------------------------------------------------------------
if [ ! -f "$RIG_SSH_CONFIG" ]; then
    echo "error: no $RIG_SSH_CONFIG" >&2
    echo "       the integration suite needs a running rig: tests/rig/rig.sh up" >&2
    exit 2
fi
if ! command -v docker >/dev/null; then
    echo "error: build-push builds images on this workstation, and docker is not on PATH" >&2
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
# The load runs in the server's own kasbah binary, which lives under <apps>: a
# server init has never prepared is refused (exit 4) before anything is built.
rig_domain=rig.test
if ! kasbah_cli server init "$RIG_TARGET" --no-mail --no-backup --domain="$rig_domain" \
        --email="ops@$rig_domain" --with-dashboard --traefik-auth="dashadmin:rig-dashboard-pw" \
        >"$tmpdir/init.out" 2>"$tmpdir/init.err" </dev/null; then
    echo "error: server init failed on a cleaned rig — build-push has no server binary to load with" >&2
    sed 's/^/       | /' "$tmpdir/init.err" >&2
    exit 2
fi

# --- The projects, each with a git history of its own -----------------------------
projdir="$tmpdir/$project"
stockdir="$tmpdir/$stock"
if ! fixture_repo_make "$projdir" "$repo_dir/tests/fixtures/$project" "v$project_version" \
        2>"$tmpdir/git.log" \
   || ! fixture_repo_make "$stockdir" "$repo_dir/tests/fixtures/$stock" "v$stock_version" \
        2>>"$tmpdir/git.log"; then
    echo "error: could not give the fixture copies a git repo with a v-tag" >&2
    sed 's/^/       | /' "$tmpdir/git.log" >&2
    exit 2
fi

build_push() (
    cd "$1" || return 2
    shift
    kasbah_cli build-push "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null
)
cli_err() { cat "$tmpdir/err"; }

# --- A known starting state for the image itself ------------------------------------
# rig_clean leaves images alone, so a leftover from an earlier run of this suite
# would make every assertion below pass without anything having shipped.
rig_ssh "docker image rm -f $web $worker $image_web:current $image_worker:current" >/dev/null 2>&1
docker image rm -f "$web" "$worker" "$image_web:current" "$image_worker:current" >/dev/null 2>&1

# One line per image, from one session. `docker image inspect A B` exits
# non-zero when *either* argument is missing, so a single call can only ever
# answer "at least one of them" — which is never the fact being asserted here.
rig_image_states() {
    rig_ssh "for pair in web=$web worker=$worker; do
                 n=\${pair%%=*}; i=\${pair#*=}
                 if docker image inspect \"\$i\" >/dev/null 2>&1
                     then echo \"\$n=present\"
                     else echo \"\$n=absent\"
                 fi
             done" 2>/dev/null | tr -d '\r'
}
state_of() { local l; l="$(grep -m1 "^$1=" <<<"$2")"; printf '%s' "${l#*=}"; }

before="$(rig_image_states)"
assert '[ "$(state_of web "$before")" = "absent" ]' \
    "the rig starts with no $web (found '$(state_of web "$before")') — else shipping it proves nothing"
assert '[ "$(state_of worker "$before")" = "absent" ]' \
    "and none of $worker either (found '$(state_of worker "$before")')"

# Every image the rig holds, so "the stock-only project loaded nothing" is a
# comparison rather than a claim.
rig_image_ids() { rig_ssh "docker image ls -aq | sort | tr '\n' ' '" 2>/dev/null | tr -d '\r'; }

# --- build-push, against the fixture that builds --------------------------------------
started=$(date +%s%3N)
build_push "$projdir" "$RIG_TARGET"; rc=$?
ship_ms=$(( $(date +%s%3N) - started ))
if [ "$rc" != "0" ]; then
    echo "  FAIL: kasbah build-push succeeded against the rig (exit $rc, took ${ship_ms}ms)" >&2
    sed 's/^/        | /' "$tmpdir/err" >&2
    fail=1
fi
echo "note: build, save|gzip, transfer and load took ${ship_ms}ms for $project $project_version" >&2

# The fixture repo has no origin, which is the shape every fixture repo has —
# so no run of this suite can push a tag anywhere.
assert 'grep -qF "no '"'"'origin'"'"' remote" "$tmpdir/err"' \
    "a repository with no origin is warned about, not failed on (said '$(cli_err)')"

# --- What the rig's own daemon holds ----------------------------------------------------
# One session for every fact, validated as a complete key set before any
# assertion reads a value: a fact that never arrived must not produce a green
# assertion (plan/roadmap/01-rig.md, from 1.3).
read_out=$(rig_ssh "bash -s '$web' '$worker' '$project'" 2>"$tmpdir/read.err" <<'REMOTE'
set -uo pipefail
export LC_ALL=C
web=$1
worker=$2
project=$3

kv() { printf '%s=%s\n' "$1" "$2"; }
# `docker image inspect` prints an empty line on stdout for an image it cannot
# find, so the `|| echo absent` form yields two lines and a key=value reader
# keeps the empty one. Ask whether it exists first.
image_id() {
    if docker image inspect "$1" >/dev/null 2>&1; then
        docker image inspect -f '{{.Id}}' "$1"
    else
        printf 'absent\n'
    fi
}

# Every question this suite asks about one image, asked about both.
report() {
    local prefix=$1 img=$2 repo=${2%:*}
    kv "${prefix}_id"      "$(image_id "$img")"
    kv "${prefix}_current" "$(image_id "$repo:current")"
    kv "${prefix}_latest"  "$(image_id "$repo:latest")"
    kv "${prefix}_tags"    "$(docker image inspect -f '{{json .RepoTags}}' "$img" 2>/dev/null | head -1)"
    kv "${prefix}_health"  "$(docker image inspect -f '{{if .Config.Healthcheck}}yes{{else}}no{{end}}' "$img" 2>/dev/null || echo unknown)"
}

# build-push loads images and nothing else: no container, no compose project.
# Counted before anything below starts one of its own, so the assertion is not
# racing this script's own `docker run --rm`.
kv containers "$(docker ps -aq --filter "ancestor=$web" --filter "ancestor=$worker" | wc -l)"

report web "$web"
report worker "$worker"

# The contents, not the name: the files the two Dockerfiles wrote, read out of
# containers started from the images that arrived.
kv web_page "$(docker run --rm --entrypoint cat "$web" /usr/share/nginx/html/index.html 2>/dev/null | tr -d '\n')"
kv worker_page "$(docker run --rm --entrypoint cat "$worker" /etc/built-app-worker.marker 2>/dev/null | tr -d '\n')"
exit 0
REMOTE
); read_rc=$?

if [ "$read_rc" -ne 0 ] || [ -z "$read_out" ]; then
    echo "error: could not read the shipped image back off the rig (ssh exit $read_rc)" >&2
    sed 's/^/       | /' "$tmpdir/read.err" >&2
    exit 2
fi
declare -A got=()
while IFS= read -r line; do
    case $line in *=*) got[${line%%=*}]=${line#*=} ;; esac
done <<<"$read_out"
missing=()
for key in web_id web_current web_latest web_tags web_health web_page \
           worker_id worker_current worker_latest worker_tags worker_health worker_page \
           containers; do
    [ -n "${got[$key]+set}" ] || missing+=("$key")
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "error: the readback reported no ${missing[*]}" >&2
    sed 's/^/       | /' <<<"$read_out" >&2
    exit 2
fi

assert '[[ "${got[web_id]}" =~ ^sha256:[0-9a-f]{64}$ ]]' \
    "$web is on the rig after build-push, and the rig names it by content id (docker said '${got[web_id]}')"
assert '[[ "${got[worker_id]}" =~ ^sha256:[0-9a-f]{64}$ ]]' \
    "and so is $worker — one save carried both (docker said '${got[worker_id]}')"
assert 'grep -qF "$web_marker" <<<"${got[web_page]}"' \
    "the web image is the one this Dockerfile builds — its page carries the marker
        page: $(head -c 200 <<<"${got[web_page]}")"
assert 'grep -qF "$worker_marker" <<<"${got[worker_page]}"' \
    "and the worker image carries its own, from a different base entirely
        file: $(head -c 200 <<<"${got[worker_page]}")"
assert '[ "${got[web_health]}" = "yes" ] && [ "${got[worker_health]}" = "yes" ]' \
    "the HEALTHCHECKs travelled inside the images (docker said '${got[web_health]}' / '${got[worker_health]}')"
assert '[ "${got[web_current]}" = "absent" ] && [ "${got[worker_current]}" = "absent" ]' \
    "and :current was moved for neither — that is deploy's, not build-push's (docker said '${got[web_current]}' / '${got[worker_current]}')"
assert '[ "${got[web_latest]}" = "absent" ] && [ "${got[worker_latest]}" = "absent" ]' \
    "no :latest is written anywhere (docker said '${got[web_latest]}' / '${got[worker_latest]}')"
assert '[ "${got[web_tags]}" = "[\"$web\"]" ]' \
    "the loaded web image carries that one tag and no other (docker said '${got[web_tags]}')"
assert '[ "${got[worker_tags]}" = "[\"$worker\"]" ]' \
    "and so does the worker (docker said '${got[worker_tags]}')"
assert '[ "${got[containers]}" = "0" ]' \
    "build-push started nothing — it loads images and stops (found ${got[containers]} containers)"

# The ids above are deliberately not compared with this workstation's. Measured
# on docker 29.7.2 both ends: an image saved here and loaded on the rig comes
# back with a different content id, so an equality check would be a red suite
# that means nothing. What the two daemons do agree on is the contents, which is
# what the page and healthcheck assertions read.
local_id=$(docker image inspect -f '{{.Id}}' "$web" 2>/dev/null)
assert '[ -n "$local_id" ]' "the build left $web on this workstation too (got '$local_id')"

# --- A re-push sends only the layer that changed --------------------------------------------
# Measured, not assumed: the stream line of each push, and what a whole save of
# the re-pushed images would have weighed.
stream_line() { grep -m1 'stream:' "$tmpdir/err"; }
first_stream="$(stream_line)"
sed -i 's|</body></html>|<p id="v2">re-pushed</p></body></html>|' "$projdir/Dockerfile"
if ! ( cd "$projdir" && git add -A && git -c user.name=t -c user.email=t@t commit -qm v2 && git tag v1.5.1 ) >/dev/null 2>&1; then
    echo "error: could not commit the re-push's edit in $projdir" >&2
    exit 2
fi
build_push "$projdir" "$RIG_TARGET"; rc=$?
assert '[ "$rc" = "0" ]' "a re-push with only the web page changed succeeds (exit $rc: $(cli_err))"
second_stream="$(stream_line)"
whole=$(docker save "$web2" "$worker2" 2>/dev/null | gzip | wc -c)
echo "note: first push   $first_stream" >&2
echo "note: re-push      $second_stream" >&2
echo "note: a whole save of the re-pushed images gzips to $whole bytes" >&2
# A containerd-store workstation saves compressed blobs, which no diffID
# names: nothing can be left out, and this suite has nothing to measure.
env_skip=0
if grep -qF "saves compressed layers" <<<"$second_stream"; then
    echo "skip: this workstation's docker uses the containerd image store — the layer skip cannot be measured from it" >&2
    env_skip=1
else
    skipped=$(sed -n 's/.*sent; \([0-9]*\) of \([0-9]*\) layers.*/\1 \2/p' <<<"$second_stream")
    assert '[ -n "$skipped" ] && [ "${skipped% *}" -gt 0 ] && [ "$(( ${skipped#* } - ${skipped% *} ))" = "1" ]' \
        "every layer but the changed one stayed home (said '$second_stream')"
fi
page2=$(rig_ssh "docker run --rm --entrypoint cat $web2 /usr/share/nginx/html/index.html; docker run --rm --entrypoint cat $worker2 /etc/built-app-worker.marker" 2>&1 | tr -d '\r\n')
assert 'grep -qF "re-pushed" <<<"$page2" && grep -qF "$web_marker" <<<"$page2" && grep -qF "$worker_marker" <<<"$page2"' \
    "and both images run on the rig, the web one with the new page (read '$page2')"

# --- A stock-only project ships nothing --------------------------------------------------
# The other half of the deliverable, and the reason it is measured rather than
# read off stdout: "nothing was shipped" is a claim about two /tmp directories
# and the rig's image list.
ids_before=$(rig_image_ids)
assert '[ -n "$ids_before" ]' "the rig reported its image list (else the comparison below is empty)"

build_push "$stockdir" "$RIG_TARGET"; rc=$?
assert '[ "$rc" = "0" ]' "build-push on a stock-only project exits 0 (exit $rc: $(cli_err))"
assert '[ "$(rig_image_ids)" = "$ids_before" ]' \
    "loading no image at all
        before: $ids_before
        after:  $(rig_image_ids)"
assert '[ ! -e "$stockdir/.kasbah/state.json" ]' \
    "and recording no server, because it talked to none"

# --- The images this suite loaded, removed by name ------------------------------------------
rig_ssh "docker image rm -f $web $worker $web2 $worker2" >/dev/null 2>&1
after="$(rig_image_states)"
assert '[ "$(state_of web "$after")" = "absent" ]' \
    "the suite takes $web off the rig again (docker said '$(state_of web "$after")')"
assert '[ "$(state_of worker "$after")" = "absent" ]' \
    "and $worker with it (docker said '$(state_of worker "$after")')"

# --- Leave the rig as it was found, but only on success ---------------------------------------
if [ "$fail" -eq 0 ]; then
    rig_clean || fail=1
fi

# Exit 2 is test.sh's "the environment cannot run this", not a pass.
[ "$fail" -eq 0 ] && [ "$env_skip" -eq 1 ] && exit 2
exit "$fail"
