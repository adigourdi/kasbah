#!/usr/bin/env bash
# Integration test: the spine — `kasbah server init` then `kasbah deploy`,
# against the live rig, ending at a page served through Traefik.
#
# This is the phase's exit criterion made checkable: a stock nginx project put
# on a prepared server by deploy, routed by a file-provider fragment that
# Traefik picked up without restarting. Everything is read back off the rig;
# kasbah's own summary is never the evidence.
#
# Anything downstream of a fragment write is polled, never asserted straight
# after the sync returns: Traefik's providersThrottleDuration puts a ~2 s floor
# under every reload (docs/phases/02-spine.md → Findings).
#
# The rig is treated as given: this suite never starts, resets or stops it. It
# does call rig_clean, which establishes a known starting state.
#
# Exit status follows test.sh's contract: 0 pass, 1 an assertion failed, 2 the
# suite could not run at all (no rig).

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
. "$repo_dir/tests/integration/rig_env.sh"
. "$repo_dir/tests/fixture_repo.sh"

apps=/apps
data=/apps/data
marker="$apps/.kasbah/server.json"

# The server, prepared the same way every rig suite prepares one. `.test` is
# reserved by RFC 6761, so no name here can reach anything real, and ACME
# refuses the account outright rather than burning issuance quota.
rig_domain=rig.test
dash_host="traefik.$rig_domain"
dash_user=dashadmin
dash_pass='rig-dashboard-pw'
traefik_flags=(--domain="$rig_domain" --email="ops@$rig_domain"
               --traefik-auth="$dash_user:$dash_pass")

# The project under test: tests/fixtures/demo, copied out of the repo before it
# is given a git history. `git init` inside the checkout would land in kasbah's
# own history as a gitlink.
project=demo
project_host=demo.test
project_version=1.0.0
container=demo-web
fragment="$apps/traefik/dynamic/$project.yml"
# The one string in the fixture's page. A Traefik 404, an nginx welcome page and
# a 502 all fail to contain it, so "the page came back" is one grep.
page_marker=served-by-demo-web-through-the-file-provider

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

tmpdir="$(mktemp -d)"
# One case plants COMPOSE_PROJECT_NAME in the rig's .bashrc to prove `-p` still
# wins on the deploy path. Left behind, it would follow every later suite into
# every docker compose call on the rig, so it comes back whatever happens here.
bashrc_planted=""
# A second prepared tree, planted outside /apps for the --apps-path case. It is
# outside everything rig_clean removes, so it comes back off the rig here.
alt_planted=""
alt_apps=""
cleanup() {
    [ -z "$bashrc_planted" ] || rig_ssh "mv -f ~/.bashrc.kasbah-unit-d ~/.bashrc" >/dev/null 2>&1
    [ -z "$alt_planted" ] || rig_ssh "rm -rf '$alt_apps'" >/dev/null 2>&1
    rm -rf "$tmpdir"
}
trap cleanup EXIT

# --- Preconditions --------------------------------------------------------------
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

# --- Helpers --------------------------------------------------------------------

init() { kasbah_cli server init "$RIG_TARGET" "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null; }
status() { kasbah_cli server status "$RIG_TARGET" "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null; }
status_out() { cat "$tmpdir/out"; }
deploy() (
    cd "$projdir" || return 2
    kasbah_cli deploy "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null
)
# The same, bounded — for the cases whose failure mode is a prompt nobody can
# answer rather than a wrong answer. `timeout` puts the child in a process group
# of its own, so stdin stays on /dev/null here as it is everywhere in this
# harness: a child reading the *controlling* terminal from a background process
# group takes SIGTTIN and stops, and a stopped process never handles the SIGTERM
# that follows (tests/integration/rig_env.sh).
deploy_bounded() (
    cd "$projdir" || return 2
    timeout "${DEPLOY_TIMEOUT:-180}" \
        env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" \
            "$KASBAH_BIN" deploy "$@" \
        >"$tmpdir/out" 2>"$tmpdir/err" </dev/null
)
cli_err() { cat "$tmpdir/err"; }

# Everything under <apps>/ that is not one of kasbah's own four directories —
# the list `server status` must reproduce, read off the rig rather than written
# down here.
rig_projects() {
    rig_ssh "cd $apps 2>/dev/null && ls -A | grep -v -x -e .kasbah -e data -e backups -e traefik | sort | tr '\n' ' '" 2>/dev/null
}

# Type, mode, owner, mtime and content of the whole tree. acme.json is left out
# of both halves: Traefik owns that file and rewrites it on its own schedule, so
# a digest covering it would fail for something status did not do.
apps_digest() {
    rig_ssh "{ find $apps ! -name acme.json -printf '%y %m %u:%g %T@ %p\n' | sort; find $apps -type f ! -name acme.json -exec sha256sum {} + | sort; } | sha256sum" 2>/dev/null
}

# How many times Traefik has come up inside its container. The observable unit C
# established: `StartedAt` cannot see a restart performed in the same breath as
# a create, but Traefik logs its version on every boot and the log survives one.
traefik_boot_count() {
    rig_ssh "docker logs traefik 2>&1 | grep -c 'Traefik version' || true" 2>/dev/null
}
traefik_started_at() {
    rig_ssh "docker inspect -f '{{.State.StartedAt}}' traefik" 2>/dev/null
}
traefik_container_id() {
    rig_ssh "docker inspect -f '{{.Id}}' traefik" 2>/dev/null
}

# Curl from inside the rig, so nothing here depends on a host port being free
# (5080 is for driving it by hand). Plain HTTP goes by Host header; HTTPS needs
# --resolve, because the TLS handshake has to carry the real SNI, and -k because
# ACME cannot issue on the rig — Traefik answers with its built-in certificate.
curl_http()  { rig_ssh "curl -s -m 15 -H 'Host: $1' http://127.0.0.1/" 2>/dev/null; }
curl_https() { rig_ssh "curl -s -m 15 -k --resolve '$1:443:127.0.0.1' https://$1/" 2>/dev/null; }
curl_http_code() {
    rig_ssh "curl -s -o /dev/null -m 15 -w '%{http_code}' -H 'Host: $1' http://127.0.0.1/" 2>/dev/null
}

# A status that has to *stay* put. Everything a deploy writes into
# traefik/dynamic takes effect about two seconds later, so a single
# check taken the moment a deploy returns passes against a fragment that is
# already on disk and about to be applied — which is exactly the bug the
# failed-deploy cases assert is absent. Six seconds is three throttle windows.
code_stays() {
    local host="$1" want="$2" secs="${3:-6}"
    local deadline got
    deadline=$(( $(date +%s) + secs ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        got=$(curl_http_code "$host")
        if [ "$got" != "$want" ]; then
            printf '%s' "$got"
            return 1
        fi
        sleep 1
    done
    printf '%s' "$want"
    return 0
}

# Everything downstream of a fragment write. Returns the last body either way,
# and the elapsed milliseconds in $poll_ms, so a failure can say how long it
# waited rather than just that it gave up.
poll_ms=0
poll_page() {
    local how="$1" host="$2" timeout_s="${3:-45}"
    local started deadline body=""
    started=$(date +%s%3N)
    deadline=$(( $(date +%s) + timeout_s ))
    while :; do
        body=$("curl_$how" "$host")
        if grep -qF "$page_marker" <<<"$body"; then
            poll_ms=$(( $(date +%s%3N) - started ))
            printf '%s' "$body"
            return 0
        fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
            poll_ms=$(( $(date +%s%3N) - started ))
            printf '%s' "$body"
            return 1
        fi
        sleep 1
    done
}

# --- status on a server kasbah has never touched -----------------------------------
# rig_clean has just removed /apps, so this is the no-marker state itself rather
# than a manufactured one — and the only moment in this suite when it exists.
assert '[ "$(rig_ssh "[ -e $apps ] && echo present || echo absent" 2>/dev/null)" = "absent" ]' \
    "the rig starts with no $apps — else the exit-4 case below proves nothing"
status; rc=$?
assert '[ "$rc" = "4" ]' "server status against an unprepared server exits 4, like deploy (exit $rc)"
assert 'grep -qF "$marker" "$tmpdir/err"' "naming the marker it looked for (said '$(cli_err)')"
assert 'grep -qF -- "--apps-path" "$tmpdir/err"' \
    "and the flag that makes a prepared server look unprepared (said '$(cli_err)')"
# The remedy must not be followable into a disaster: a bare
# `kasbah server init user@host` against a server whose apps path is not /apps
# renders a second Traefik stack under the frozen `traefik` compose project and
# takes every site on the host down.
assert '! grep -qE "kasbah server init [A-Za-z0-9._-]+@" "$tmpdir/err"' \
    "and never prints a runnable bare \`server init\` (said '$(cli_err)')"

# --- A prepared server ------------------------------------------------------------
init --no-mail --no-backup "${traefik_flags[@]}"; rc=$?
if [ "$rc" != "0" ]; then
    echo "error: server init failed on a cleaned rig (exit $rc) — the deploy has nothing to land on" >&2
    sed 's/^/       | /' "$tmpdir/err" >&2
    exit 2
fi

marker_json=$(rig_ssh "cat $marker" 2>/dev/null)
cpu_limit=$(jq -r '.cpu_limit // ""' <<<"$marker_json" 2>/dev/null)
mem_limit=$(jq -r '.mem_limit // ""' <<<"$marker_json" 2>/dev/null)
if [ -z "$cpu_limit" ] || [ -z "$mem_limit" ]; then
    echo "error: the server marker carries no limits for injection to write" >&2
    echo "       marker: $marker_json" >&2
    exit 2
fi
# The values injection writes into every project's .env, in the shape the
# compose files expect them. Read here so the block assertions further down
# compare against the marker rather than against a constant.
assert '[[ "$cpu_limit" =~ ^[0-9]+\.[0-9]$ ]]' "the marker's cpu_limit is a number (got '$cpu_limit')"
assert '[[ "$mem_limit" =~ ^[0-9]+[gm]$ ]]'    "the marker's mem_limit carries a unit (got '$mem_limit')"

# --- status on a prepared server with nothing deployed --------------------------------
# The other state that exists exactly once in this suite: init has run, and no
# project directory is under /apps yet.
empty_projects=$(rig_projects)
assert '[ -z "$empty_projects" ]' \
    "the rig really has no project directory yet (found '$empty_projects') — else the case below proves nothing"
status; rc=$?
assert '[ "$rc" = "0" ]' "server status on a prepared server exits 0 (exit $rc: $(cli_err))"
assert 'grep -qF "none — no project directory under $apps" "$tmpdir/out"' \
    "and reports no projects rather than an empty list (said '$(status_out)')"
assert 'grep -qF "Traefik: running (healthy)" "$tmpdir/out"' \
    "with the Traefik init just started (said '$(status_out)')"

# --- The project, with a git history of its own -----------------------------------
projdir="$tmpdir/$project"
if ! fixture_repo_make "$projdir" "$repo_dir/tests/fixtures/$project" "v$project_version" \
        2>"$tmpdir/git.log"; then
    echo "error: could not give the fixture copy a git repo with a v-tag" >&2
    sed 's/^/       | /' "$tmpdir/git.log" >&2
    exit 2
fi

# --- Deploy refuses to render a .env with nobody to answer it -----------------------
# The env step, at the one shape this harness can produce: no .env on the server
# and no terminal at either end. Running the generator anyway would feed it EOF,
# which its non-interactive contract turns into every default silently accepted
# — secrets included — so it refuses with exit 5 instead (docs/cli.md).
#
# Bounded, because the failure mode this replaces is not a wrong answer but a
# prompt nobody can answer: `deploy` is measured, and a run that took the whole
# timeout would fail here rather than hang the suite.
deploy_started=$(date +%s%3N)
deploy_bounded "$RIG_TARGET"; rc=$?
noenv_ms=$(( $(date +%s%3N) - deploy_started ))
assert '[ "$rc" != "124" ]' \
    "a deploy that cannot render .env returns rather than waiting on a prompt (took ${noenv_ms}ms)"
assert '[ "$rc" = "5" ]' \
    "and exits 5 — the env step could not complete (exit $rc: $(cli_err))"
assert 'grep -qF "$apps/$project/.env" "$tmpdir/err"' \
    "naming the file it wanted (said '$(cli_err)')"
assert 'grep -qF "no terminal" "$tmpdir/err"' \
    "and what is missing (said '$(cli_err)')"
assert 'grep -qF "kasbah env $RIG_TARGET" "$tmpdir/err"' \
    "and the command that renders it (said '$(cli_err)')"
assert '[ "$(rig_ssh "[ -e $fragment ] && echo present || echo absent" 2>/dev/null)" = "absent" ]' \
    "a refused deploy ships no Traefik fragment — a route to a container that never started"
assert '[ "$(rig_ssh "[ -e $apps/$project/.env ] && echo present || echo absent" 2>/dev/null)" = "absent" ]' \
    "and invents no .env of its own"
assert '[ ! -f "$projdir/.kasbah/state.json" ]' \
    "and writes no project state (docs/project-manifest.md: only on success)"

# What it *did* ship first, and the reason the order is that way round: the
# generator the message recommends is the server's own kasbah binary, which this
# run ensured, and no shell helper is shipped beside the project any more.
srvbin="$apps/.kasbah/bin/kasbah"
assert '[ "$(rig_ssh "stat -c %a $srvbin" 2>/dev/null)" = "775" ]' \
    "the server binary that renders .env is there, executable, and the operators' group may replace it (got '$(rig_ssh "stat -c %a $srvbin" 2>/dev/null)')"
assert '[ "$(rig_ssh "[ -e $apps/$project/scripts ] && echo present || echo absent" 2>/dev/null)" = "absent" ]' \
    "and no scripts/ directory was shipped — the server's binary runs the deploy"
assert '[ "$(rig_ssh "[ -e $apps/$project/.env.prod.example ] && echo present || echo absent" 2>/dev/null)" = "present" ]' \
    "with the template beside it, which is what the setup prompts from"

# --- Can this rig apply a cgroup limit at all? --------------------------------------
# Measured, not assumed, because on the rig as built today it cannot: the
# container's cgroup root holds processes and has no `init` sub-cgroup, so the
# nested dockerd cannot distribute domain controllers and runc falls back to
# threaded cgroups. Any --cpus or --memory then fails with
#   cannot enter cgroupv2 "/sys/fs/cgroup/docker" with domain controllers
#   -- it is in threaded mode
# and the container never starts. That is a property of the rig, not of kasbah
# (docs/phases/02-spine.md → Findings), and the fix is the standard docker:dind
# cgroup-nesting step in the rig's entrypoint.
#
# Nothing here special-cases kasbah. What changes is the *server marker*: on a
# rig that cannot honour a limit it is rewritten to 0/0, which Docker reads as
# "no limit", and injection then does its real job end to end against a value
# the host can live with. The assertion that matters — the block in .env matches
# the marker — holds either way, and a rig that later grows cgroup nesting needs
# no edit here.
limit_probe=$(rig_ssh "docker run --rm --cpus 0.5 --memory 64m nginx:alpine /bin/true 2>&1" 2>/dev/null); probe_rc=$?
if [ "$probe_rc" -eq 0 ]; then
    want_cpu="$cpu_limit"
    want_mem="$mem_limit"
elif grep -qF "threaded mode" <<<"$limit_probe"; then
    want_cpu=0
    want_mem=0
    echo "note: this rig cannot apply cgroup limits (nested cgroup v2 is in threaded mode)," >&2
    echo "      so the server marker is rewritten to 0/0 — Docker reads that as no limit." >&2
    new_marker=$(jq --arg c "$want_cpu" --arg m "$want_mem" '.cpu_limit = $c | .mem_limit = $m' \
        <<<"$marker_json" 2>/dev/null)
    if [ -z "$new_marker" ] || ! rig_ssh "cat > $marker" <<<"$new_marker" >/dev/null 2>&1; then
        echo "error: could not rewrite the server marker's limits on the rig" >&2
        exit 2
    fi
    marker_json=$(rig_ssh "cat $marker" 2>/dev/null)
    if [ "$(jq -r '.cpu_limit' <<<"$marker_json" 2>/dev/null)" != "$want_cpu" ]; then
        echo "error: the rewritten marker does not carry cpu_limit=$want_cpu (got '$marker_json')" >&2
        exit 2
    fi
else
    echo "error: could not tell whether the rig can apply cgroup limits (rc $probe_rc)" >&2
    sed 's/^/       | /' <<<"$limit_probe" >&2
    exit 2
fi

# --- The operator renders .env, with the script kasbah shipped ---------------------
# This is the half kasbah refuses to do headless, done by hand — the suite
# playing the person at the terminal. It runs the *shipped* helper, off the
# server, against the template the failed deploy put beside it; stdin is empty,
# which for a first run means every template default is accepted (there is no
# menu until a .env exists, so nothing here trips the errexit path).
#
# The two KASBAH_* lines that used to be seeded here are deliberately not: this
# writes only what the project's own template declares, and injection is what
# has to produce the rest. A .env with them already in it would make the
# assertions below pass against a kasbah that injected nothing at all.
setup_out=$(rig_setup_env "$apps/$project" </dev/null 2>&1); setup_rc=$?
rendered=$(rig_ssh "cat $apps/$project/.env" 2>/dev/null)
if [ "$setup_rc" -ne 0 ] || ! grep -qF "DEMO_GREETING=hello from the demo fixture" <<<"$rendered"; then
    echo "error: the server's env setup did not render $apps/$project/.env (rc $setup_rc)" >&2
    sed 's/^/       | /' <<<"$setup_out" >&2
    sed 's/^/       > /' <<<"$rendered" >&2
    exit 2
fi
assert '! grep -q "^KASBAH_" <<<"$rendered"' \
    "the rendered .env carries no KASBAH_ key of its own — injection is what puts them there
        rendered: $(tr '\n' '|' <<<"$rendered")"

# --- A deploy that cannot finish must not route anything ------------------------------
# The fragment is the last thing a deploy ships, after `compose up` has
# returned 0. Everything that can make it fail — an image that will not pull, a
# port already bound, a value the compose file cannot use — would otherwise
# leave `demo.test` routed at a container that does not exist, answering 502
# until somebody deploys again. An unpullable image is the cheapest way to hold
# `compose up` at arm's length.
broken_image=nginx:no-such-tag-kasbah-unit-d
break_image() { sed -i "s|image: nginx:alpine|image: $broken_image|" "$projdir/compose.prod.yml"; }
fix_image()   { sed -i "s|image: $broken_image|image: nginx:alpine|" "$projdir/compose.prod.yml"; }

break_image
assert 'grep -qF "$broken_image" "$projdir/compose.prod.yml"' \
    "the working tree really does name an unpullable image — else this case proves nothing"
# --dirty: the edit is uncommitted, and a deploy refuses that before compose up.
deploy "$RIG_TARGET" --dirty; rc=$?
assert '[ "$rc" != "0" ]' "a deploy whose compose up fails is a failed deploy (exit $rc)"
assert 'grep -qF "up -d --remove-orphans failed in" "$tmpdir/err"' \
    "and it is compose up that failed it, not the clean-tree check (said '$(cli_err)')"
assert '[ "$(rig_ssh "[ -e $fragment ] && echo present || echo absent" 2>/dev/null)" = "absent" ]' \
    "and ships no fragment — nothing reaches traefik/dynamic until the deploy is known to have finished"
unrouted_code=$(code_stays "$project_host" 404); stays_rc=$?
assert '[ "$stays_rc" = "0" ]' \
    "so the host stays unrouted rather than turning 502 a reload later (went to '$unrouted_code')"
assert '[ "$(rig_ssh "[ -e $apps/$project/versions.log ] && echo present || echo absent" 2>/dev/null)" = "absent" ]' \
    "no versions.log line for a deploy that did not run"
assert '[ ! -f "$projdir/.kasbah/state.json" ]' "and no project state"
fix_image
assert 'grep -qF "image: nginx:alpine" "$projdir/compose.prod.yml"' "the fixture is back to a pullable image"

# --- The deploy ---------------------------------------------------------------------
boot_before=$(traefik_boot_count)
started_before=$(traefik_started_at)
id_before=$(traefik_container_id)
assert '[ "$boot_before" = "1" ]' \
    "Traefik has booted once before the deploy (got '$boot_before') — the later comparison needs a known start"

deploy_started=$(date +%s%3N)
deploy "$RIG_TARGET"; rc=$?
deploy_ms=$(( $(date +%s%3N) - deploy_started ))
if [ "$rc" != "0" ]; then
    echo "  FAIL: kasbah deploy succeeded against the prepared rig (exit $rc)" >&2
    sed 's/^/        | /' "$tmpdir/err" >&2
    fail=1
fi

# --- The page comes back through Traefik ---------------------------------------------
body=$(poll_page http "$project_host"); poll_rc=$?
http_ms=$poll_ms
assert '[ "$poll_rc" = "0" ]' \
    "curl -H 'Host: $project_host' http://127.0.0.1/ returns the fixture page from inside the rig
        waited ${http_ms}ms, deploy took ${deploy_ms}ms
        body: $(head -c 400 <<<"$body")"

# The same host over TLS. Traefik has no certificate for it and never will on
# the rig, so this is `curl -k` and the assertion is that it *serves* — never
# that anything was issued.
body_tls=$(poll_page https "$project_host"); poll_tls_rc=$?
assert '[ "$poll_tls_rc" = "0" ]' \
    "the websecure router serves the same page under curl -k (waited ${poll_ms}ms)
        body: $(head -c 400 <<<"$body_tls")"
cert_subject=$(rig_ssh "openssl s_client -connect 127.0.0.1:443 -servername $project_host </dev/null 2>/dev/null | openssl x509 -noout -subject" 2>/dev/null)
assert 'grep -qi "TRAEFIK DEFAULT CERT" <<<"$cert_subject"' \
    "and it is Traefik's default certificate, not an issued one (subject: '$cert_subject')"

# --- The negative: the routing is real, not incidental --------------------------------
# Without this, "curl returned the page" would pass just as well against a
# Traefik that served the same backend to every Host it was asked about.
body_unrouted=$(curl_http not-routed.test)
code_unrouted=$(curl_http_code not-routed.test)
assert '! grep -qF "$page_marker" <<<"$body_unrouted"' \
    "an unrouted Host on the same port does not get the fixture page (got '$(head -c 200 <<<"$body_unrouted")')"
assert '[ "$code_unrouted" = "404" ]' \
    "it gets Traefik's own 404 — so the port is answering and the rule is what selected it (got '$code_unrouted')"

# --- The fragment, and a Traefik that never restarted ----------------------------------
frag_stat=$(rig_ssh "stat -c '%F %a' $fragment" 2>/dev/null)
assert '[ "$frag_stat" = "regular file 644" ]' \
    "$fragment is a regular file, mode 644 (got '$frag_stat')"
frag_sha=$(rig_ssh "sha256sum $fragment | cut -d' ' -f1" 2>/dev/null)
local_sha=$(sha256sum "$projdir/traefik-dynamic.yml" | cut -d' ' -f1)
assert '[ "$frag_sha" = "$local_sha" ]' \
    "and it is the project's traefik-dynamic.yml byte for byte
        rig:   $frag_sha
        local: $local_sha"
assert '[ "$(rig_ssh "[ -e $apps/$project/traefik-dynamic.yml ] && echo present || echo absent" 2>/dev/null)" = "absent" ]' \
    "the fragment went out of band — no copy of it landed in the project directory"

boot_after=$(traefik_boot_count)
assert '[ "$boot_after" = "$boot_before" ]' \
    "Traefik did not restart to pick the fragment up (booted $boot_before before, $boot_after after)"
assert '[ "$(traefik_started_at)" = "$started_before" ]' \
    "its start time is unmoved (was '$started_before', now '$(traefik_started_at)')"
assert '[ "$(traefik_container_id)" = "$id_before" ]' \
    "and it is the same container — deploy touches the shared stack not at all"

# --- What landed in the project directory -----------------------------------------------
# One session for every fact, checked as a protocol before any assertion reads
# it: a fact that never arrived must not produce a green assertion.
land_out=$(rig_ssh "bash -s '$apps' '$data' '$project'" 2>"$tmpdir/land.err" <<'REMOTE'
set -uo pipefail
apps=$1
data=$2
name=$3
dir="$apps/$name"

kv() { printf '%s=%s\n' "$1" "$2"; }
isdir()  { if [ -d "$1" ]; then kv "$2" yes; else kv "$2" no; fi; }
isfile() { if [ -f "$1" ]; then kv "$2" yes; else kv "$2" no; fi; }

isdir  "$dir"              d_project
isdir  "$dir/scripts"      d_scripts
isdir  "$dir/backups"      d_backups
isdir  "$data/$name"       d_data
isfile "$dir/compose.yml"  f_compose
isfile "$dir/.env.prod.example" f_envexample
isfile "$dir/site/index.html"   f_page
isfile "$dir/scripts/remote-deploy.sh" f_helper
kv helper_mode "$(stat -c '%a' "$dir/scripts/remote-deploy.sh" 2>/dev/null)"
isfile "$dir/scripts/setup-env.sh" f_envhelper
kv envhelper_mode "$(stat -c '%a' "$dir/scripts/setup-env.sh" 2>/dev/null)"
# compose.prod.yml is the *source* name; the sync list renames it on arrival, so
# its absence here is what proves the rename happened rather than a plain copy.
isfile "$dir/compose.prod.yml" f_unrenamed
kv versions_lines "$(wc -l < "$dir/versions.log" 2>/dev/null || echo 0)"
kv versions_first "$(head -1 "$dir/versions.log" 2>/dev/null)"
kv c_project "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' demo-web 2>/dev/null)"
kv c_state   "$(docker inspect -f '{{.State.Status}}' demo-web 2>/dev/null)"
kv c_nets    "$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' demo-web 2>/dev/null)"
kv c_env     "$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' demo-web 2>/dev/null | grep -c '^DEMO_GREETING=hello from the demo fixture$' || true)"
exit 0
REMOTE
); land_rc=$?

if [ "$land_rc" -ne 0 ] || [ -z "$land_out" ]; then
    echo "error: could not read the deployed project back off the rig (ssh exit $land_rc)" >&2
    sed 's/^/       | /' "$tmpdir/land.err" >&2
    exit 2
fi
declare -A got=()
while IFS= read -r line; do
    case $line in *=*) got[${line%%=*}]=${line#*=} ;; esac
done <<<"$land_out"
missing=()
for key in d_project d_scripts d_backups d_data f_compose f_envexample f_page f_helper \
           helper_mode f_envhelper envhelper_mode f_unrenamed versions_lines versions_first \
           c_project c_state c_nets c_env; do
    [ -n "${got[$key]+set}" ] || missing+=("$key")
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "error: the readback reported no ${missing[*]}" >&2
    sed 's/^/       | /' <<<"$land_out" >&2
    exit 2
fi

assert '[ "${got[d_project]}" = "yes" ]'  "$apps/$project is a directory (got '${got[d_project]}')"
assert '[ "${got[d_scripts]}" = "no" ]'  "no $apps/$project/scripts: nothing is shipped into it (got '${got[d_scripts]}')"
assert '[ "${got[d_backups]}" = "yes" ]'  "$apps/$project/backups is a directory (got '${got[d_backups]}')"
assert '[ "${got[d_data]}" = "yes" ]'     "$data/$project is a directory (got '${got[d_data]}')"
assert '[ "${got[f_compose]}" = "yes" ]' \
    "the sync list's rename landed: compose.prod.yml arrived as compose.yml (got '${got[f_compose]}')"
assert '[ "${got[f_unrenamed]}" = "no" ]' \
    "and under that name only — a rename, not a copy (got '${got[f_unrenamed]}')"
assert '[ "${got[f_envexample]}" = "yes" ]' "the plain sync entry landed (got '${got[f_envexample]}')"
assert '[ "${got[f_page]}" = "yes" ]' \
    "and the trailing-slash entry recursed: site/index.html is there (got '${got[f_page]}')"
assert '[ "${got[f_helper]}" = "no" ]'   "no remote-deploy.sh was rendered — the engine is \`kasbah remote deploy\` (got '${got[f_helper]}')"
assert '[ "${got[f_envhelper]}" = "no" ]'    "and no setup-env.sh shipped (got '${got[f_envhelper]}')"

# --- The KASBAH_* managed block, written from the marker -----------------------------
# The seam this phase replaces. Until now the two limits were seeded into .env by
# this file; now the only thing that puts them there is injection, so what is
# read back is kasbah's work and not the suite's.
env_body=$(rig_ssh "cat $apps/$project/.env" 2>/dev/null)
bmark='# >>> kasbah managed block - do not edit, rewritten on every deploy >>>'
emark='# <<< kasbah managed block <<<'
assert '[ "$(grep -cxF "$bmark" <<<"$env_body")" = "1" ]' \
    "the deploy wrote exactly one managed block into $apps/$project/.env
        .env: $(tr '\n' '|' <<<"$env_body")"
assert '[ "$(grep -cxF "$emark" <<<"$env_body")" = "1" ]' "closed by exactly one end sentinel"
assert 'grep -qxF "KASBAH_CPU_LIMIT=$want_cpu" <<<"$env_body"' \
    "carrying the marker's cpu_limit verbatim (wanted '$want_cpu', .env: $(grep KASBAH_CPU <<<"$env_body"))"
assert 'grep -qxF "KASBAH_MEM_LIMIT=$want_mem" <<<"$env_body"' \
    "and its mem_limit (wanted '$want_mem', .env: $(grep KASBAH_MEM <<<"$env_body"))"
# Both directions of the stray rule, on a real file: two lines setting one
# variable and the last one wins, so a KASBAH_ assignment outside the block
# would silently outrank the marker.
assert '[ "$(grep -c "^KASBAH_" <<<"$env_body")" = "2" ]' \
    "and nothing sets a KASBAH_ variable outside it (got $(grep -c "^KASBAH_" <<<"$env_body") lines)"
# The operator's own value, written by the generator before injection ever ran,
# is still there — injection touches the block and nothing else.
assert 'grep -qxF "DEMO_GREETING=hello from the demo fixture" <<<"$env_body"' \
    "the value the generator rendered survived injection (.env: $(tr '\n' '|' <<<"$env_body"))"
env_sha=$(rig_ssh "sha256sum $apps/$project/.env | cut -d' ' -f1" 2>/dev/null)

# --- versions.log ---------------------------------------------------------------------
assert '[ "${got[versions_lines]}" = "1" ]' \
    "one deploy wrote exactly one versions.log line (got '${got[versions_lines]}')"
read -r v_ts v_action v_version v_backup v_kasbah v_digest v_extra <<<"${got[versions_first]}"
assert '[[ "$v_ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\+00:00$ ]]' \
    "field 1 is a UTC ISO-8601 timestamp (line: '${got[versions_first]}')"
assert '[ "$v_action" = "deploy" ]'   "field 2 is the action (got '$v_action')"
assert '[ "$v_version" = "$project_version" ]' \
    "field 3 is the version off HEAD's tag (got '$v_version')"
assert '[ "$v_backup" = "no-backup" ]' "field 4 is the backup path, absent here (got '$v_backup')"
assert '[ "$v_kasbah" = "kasbah=$(kasbah_base_version)" ]' \
    "then kasbah=<this checkout's version> (got '$v_kasbah')"
assert '[ "$v_digest" = "digest=-" ]' \
    "and digest=- , because a stock-only project builds no image (got '$v_digest')"
assert '[ "$v_extra" = "by=$RIG_SSH_USER" ]' "then by=<the ssh user>, and nothing after it yet (got '$v_extra')"

# --- The container, and how Traefik reaches it -------------------------------------------
assert '[ "${got[c_state]}" = "running" ]' "$container is running (got '${got[c_state]}')"
assert '[ "${got[c_project]}" = "$project" ]' \
    "it belongs to the compose project deploy names with -p (got '${got[c_project]}')"
assert 'grep -qw "kasbah-net" <<<"${got[c_nets]}"' \
    "and it is on kasbah-net, which is what makes container_name resolvable (networks: ${got[c_nets]})"
assert 'grep -qw "demo_internal" <<<"${got[c_nets]}"' \
    "as well as the project's own network (networks: ${got[c_nets]})"
assert '[ "${got[c_env]}" = "1" ]' \
    "compose read the rendered .env — DEMO_GREETING reached the container (got '${got[c_env]}' matches)"

# Traefik's own view of the fragment: the router is registered and the service
# points at the container by name. The 200 above says it works; this says it
# works for the reason the phase claims.
api() {
    rig_ssh "curl -s -m 15 -k -u '$dash_user:$dash_pass' --resolve '$dash_host:443:127.0.0.1' 'https://$dash_host/api/$1'" 2>/dev/null
}
routers=$(api http/routers)
services=$(api http/services)
assert '[ "$(jq -r "[.[] | select(.name == \"$project@file\")] | length" <<<"$routers" 2>/dev/null)" = "1" ]' \
    "Traefik registered the fragment's websecure router as $project@file"
assert '[ "$(jq -r "[.[] | select(.name == \"$project-http@file\")] | .[0].status // \"\"" <<<"$routers" 2>/dev/null)" = "enabled" ]' \
    "and the :80 router is enabled (routers: $(jq -r '[.[].name] | join(" ")' <<<"$routers" 2>/dev/null))"
assert '[ "$(jq -r "[.[] | select(.name == \"$project@file\")] | .[0].loadBalancer.servers[0].url // \"\"" <<<"$services" 2>/dev/null)" = "http://$container:80" ]' \
    "and the service targets the container by container_name, not by service-name alias"

# --- The project state, written only now --------------------------------------------------
state="$projdir/.kasbah/state.json"
assert '[ -f "$state" ]' "a successful deploy writes $state"
if [ -f "$state" ]; then
    assert '[ "$(jq -r .last_server <<<"$(cat "$state")")" = "$RIG_TARGET" ]' \
        "recording last_server (state: $(cat "$state" | tr -d '\n'))"
    assert '[ "$(jq -r .last_version <<<"$(cat "$state")")" = "$project_version" ]' "and last_version"
    assert '[[ "$(jq -r .last_deploy <<<"$(cat "$state")")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]' \
        "and last_deploy as a UTC timestamp (got '$(jq -r .last_deploy <<<"$(cat "$state")")')"
fi

# --- A second deploy, with a hostile COMPOSE_PROJECT_NAME ---------------------------------
# Two things at once, because they need the same second deploy: the default that
# the state file buys (no USER@HOST on the command line at all), and that `-p`
# decides the compose project.
#
# `name: demo` in the compose file would produce the same project label on its
# own, so the label proves nothing until the environment disagrees with it.
# COMPOSE_PROJECT_NAME outranks `name:` and `down` removes by project label —
# which is what put nine unrelated containers in range on this workstation
# (docs/phases/01-rig.md).
if rig_ssh "cp ~/.bashrc ~/.bashrc.kasbah-unit-d && printf 'export COMPOSE_PROJECT_NAME=%s\n%s' kasbah-not-demo \"\$(cat ~/.bashrc)\" > ~/.bashrc.new && mv ~/.bashrc.new ~/.bashrc" >/dev/null 2>&1; then
    bashrc_planted=yes
    planted=$(rig_ssh "bash -s" <<<'echo "${COMPOSE_PROJECT_NAME:-unset}"' 2>/dev/null)
    assert '[ "$planted" = "kasbah-not-demo" ]' \
        "COMPOSE_PROJECT_NAME reaches the shell the server binary runs in (got '$planted') — else this case proves nothing"

    deploy; rc=$?
    # This exit status is the assertion that catches a missing -p: without it
    # compose reads COMPOSE_PROJECT_NAME, tries to create its own demo-web and
    # dies on the name the running container already holds.
    assert '[ "$rc" = "0" ]' \
        "a second deploy succeeds with no USER@HOST (last_server) and a hostile COMPOSE_PROJECT_NAME (-p) (exit $rc: $(cli_err))"
    labelled=$(rig_ssh "docker inspect -f '{{index .Config.Labels \"com.docker.compose.project\"}}' $container" 2>/dev/null)
    # And this one catches the other shape: a deploy that succeeded while
    # putting the container under somebody else's project.
    assert '[ "$labelled" = "$project" ]' \
        "and the running container is still labelled $project (got '$labelled')"
    # Idempotence, end to end and on a file two deploys have now rewritten: the
    # second injection produced the same bytes as the first, so a redeploy does
    # not churn a file the operator edits by hand.
    assert '[ "$(rig_ssh "sha256sum $apps/$project/.env | cut -d\" \" -f1" 2>/dev/null)" = "$env_sha" ]' \
        "the second deploy left .env byte-identical — injection is idempotent against a real file"
    lines=$(rig_ssh "wc -l < $apps/$project/versions.log" 2>/dev/null | tr -d ' ')
    assert '[ "$lines" = "2" ]' "the second deploy appended a second line (got '$lines')"
    assert '[ "$(rig_ssh "head -1 $apps/$project/versions.log" 2>/dev/null)" = "${got[versions_first]}" ]' \
        "and left the first one exactly as it was"

    rig_ssh "mv -f ~/.bashrc.kasbah-unit-d ~/.bashrc" >/dev/null 2>&1 && bashrc_planted=""
    assert '[ -z "$bashrc_planted" ]' "the rig's .bashrc was put back"
else
    assert 'false' "could not plant COMPOSE_PROJECT_NAME in the rig's environment"
fi

assert '[ "$(traefik_boot_count)" = "$boot_before" ]' \
    "Traefik still has not restarted after a second deploy (booted $boot_before at the start, $(traefik_boot_count) now)"
body_again=$(poll_page http "$project_host" 20); poll_rc=$?
assert '[ "$poll_rc" = "0" ]' \
    "and the page still serves after the redeploy (waited ${poll_ms}ms)
        body: $(head -c 200 <<<"$body_again")"

# --- A redeploy that cannot finish leaves the live site alone --------------------------
# The same rule from the other side: with a version already serving, a deploy
# that dies at `compose up` must leave the live site, its fragment and its log
# exactly as they were.
#
# What this case does *not* construct is the container_name rename, where the
# ordering earns the most: the fixture ships the same fragment both times, so a
# fragment written early would be byte-identical and invisible here. That shape
# needs a second version of the fixture and belongs with the rest of the
# multi-version work in Phase 4.
lines_before=$(rig_ssh "wc -l < $apps/$project/versions.log" 2>/dev/null | tr -d ' ')
frag_before=$(rig_ssh "sha256sum $fragment | cut -d' ' -f1" 2>/dev/null)
break_image
deploy; rc=$?
assert '[ "$rc" != "0" ]' "a redeploy whose compose up fails is a failed deploy (exit $rc)"
assert '[ "$(rig_ssh "sha256sum $fragment | cut -d\" \" -f1" 2>/dev/null)" = "$frag_before" ]' \
    "the fragment on the server is untouched by it"
assert '[ "$(rig_ssh "wc -l < $apps/$project/versions.log" 2>/dev/null | tr -d " ")" = "$lines_before" ]' \
    "and so is versions.log ($lines_before lines before)"
body_survived=$(curl_http "$project_host")
assert 'grep -qF "$page_marker" <<<"$body_survived"' \
    "and the version that was already serving still serves (got '$(head -c 200 <<<"$body_survived")')"
survived_code=$(code_stays "$project_host" 200); stays_rc=$?
assert '[ "$stays_rc" = "0" ]' \
    "and keeps serving past the reload window, so nothing was quietly rerouted (went to '$survived_code')"
fix_image

# --- Drift, on a server with a real .env and no terminal anywhere ------------------------
# The plan's own deliverable ("pre-seeded .env + drift -> exit 5, no hang"),
# with the .env the generator rendered above standing in for the seeding this
# phase retired. The drift is
# made the way it happens in life — a key added to the project's template — and
# the template reaches the server through the manifest's sync: list, so what the
# far side compares is genuinely the new one.
lines_before=$(rig_ssh "wc -l < $apps/$project/versions.log" 2>/dev/null | tr -d ' ')
frag_before=$(rig_ssh "sha256sum $fragment | cut -d' ' -f1" 2>/dev/null)
env_before=$(rig_ssh "sha256sum $apps/$project/.env | cut -d' ' -f1" 2>/dev/null)
printf 'DRIFT_PROBE=added since the .env was rendered\n' >> "$projdir/.env.prod.example"

drift_started=$(date +%s%3N)
# --dirty throughout: the drift is an uncommitted edit to the template.
deploy_bounded --dirty; rc=$?
drift_ms=$(( $(date +%s%3N) - drift_started ))
assert '[ "$rc" != "124" ]' \
    "a drifting .env with nobody to ask returns rather than waiting on a prompt (took ${drift_ms}ms)"
assert '[ "$rc" = "5" ]' "and exits 5 (exit $rc: $(cli_err))"
assert 'grep -qF "DRIFT_PROBE" "$tmpdir/err"' \
    "naming the key that drifted (said '$(cli_err)')"
assert 'grep -qF -- "--on-drift" "$tmpdir/err"' \
    "and the flag that makes the choice scriptable (said '$(cli_err)')"
assert '[ "$(rig_ssh "wc -l < $apps/$project/versions.log" 2>/dev/null | tr -d " ")" = "$lines_before" ]' \
    "nothing was deployed ($lines_before lines before)"
assert '[ "$(rig_ssh "sha256sum $apps/$project/.env | cut -d\" \" -f1" 2>/dev/null)" = "$env_before" ]' \
    "and the server's .env was not touched — not even the block"
assert '[ "$(rig_ssh "sha256sum $fragment | cut -d\" \" -f1" 2>/dev/null)" = "$frag_before" ]' \
    "nor the fragment"
survived_code=$(code_stays "$project_host" 200); stays_rc=$?
assert '[ "$stays_rc" = "0" ]' \
    "and the version already serving keeps serving (went to '$survived_code')"

deploy_bounded --dirty --on-drift=abort; rc=$?
assert '[ "$rc" = "5" ]' "--on-drift=abort is the same refusal, asked for (exit $rc: $(cli_err))"
assert '[ "$(rig_ssh "sha256sum $apps/$project/.env | cut -d\" \" -f1" 2>/dev/null)" = "$env_before" ]' \
    "changing nothing on the server"

# The scriptable way through. `continue` means the .env is left as it stands —
# the new template key does *not* appear in it — and only the managed block is
# refreshed.
deploy_bounded --dirty --on-drift=continue; rc=$?
assert '[ "$rc" = "0" ]' "--on-drift=continue deploys against the .env as it stands (exit $rc: $(cli_err))"
drifted_env=$(rig_ssh "cat $apps/$project/.env" 2>/dev/null)
assert '! grep -q "^DRIFT_PROBE=" <<<"$drifted_env"' \
    "and adds no key of its own — continue is not a silent setup (.env: $(tr '\n' '|' <<<"$drifted_env"))"
assert 'grep -qxF "KASBAH_CPU_LIMIT=$want_cpu" <<<"$drifted_env"' \
    "while the block is still the marker's ( .env: $(grep KASBAH_CPU <<<"$drifted_env"))"
assert '[ "$(rig_ssh "wc -l < $apps/$project/versions.log" 2>/dev/null | tr -d " ")" = "$(( lines_before + 1 ))" ]' \
    "and the deploy really ran (was $lines_before lines)"

# Back in sync, and the deploy stops mentioning drift at all — without this, the
# three cases above would pass equally against a kasbah that saw drift always.
head -n -1 "$projdir/.env.prod.example" > "$tmpdir/tpl" && mv "$tmpdir/tpl" "$projdir/.env.prod.example"
assert '! grep -q "^DRIFT_PROBE=" "$projdir/.env.prod.example"' "the fixture template is back as it was"
deploy_bounded; rc=$?
assert '[ "$rc" = "0" ]' "an in-sync .env deploys with no flag and no prompt (exit $rc: $(cli_err))"
assert '! grep -qF "has drifted" "$tmpdir/err"' "saying nothing about drift (said '$(cli_err)')"

# --- server status matches the rig -----------------------------------------------------
# Every expectation below is read off the rig moments before the comparison, so
# a hard-coded version, image or project name cannot make this pass.
want_docker=$(rig_ssh "docker version --format '{{.Server.Version}}'" 2>/dev/null | tr -d '\r')
want_compose=$(rig_ssh "docker compose version --short" 2>/dev/null | tr -d '\r')
want_tstate=$(rig_ssh "docker inspect -f '{{.State.Status}}' traefik" 2>/dev/null | tr -d '\r')
want_thealth=$(rig_ssh "docker inspect -f '{{.State.Health.Status}}' traefik" 2>/dev/null | tr -d '\r')
want_image=$(rig_ssh "docker inspect -f '{{.Config.Image}}' traefik" 2>/dev/null | tr -d '\r')
want_image_id=$(rig_ssh "docker inspect -f '{{.Image}}' traefik" 2>/dev/null | tr -d '\r')
want_line=$(rig_ssh "tail -1 $apps/$project/versions.log" 2>/dev/null | tr -d '\r')
read -r want_ts want_action want_version _ want_kasbah _ <<<"$want_line"
want_running=$(rig_ssh "docker ps --filter label=com.docker.compose.project=$project -q | wc -l" 2>/dev/null | tr -d ' \r')
want_total=$(rig_ssh "docker ps -a --filter label=com.docker.compose.project=$project -q | wc -l" 2>/dev/null | tr -d ' \r')
want_projects=$(rig_projects)
want_marker_data=$(jq -r '.data_path // ""' <<<"$(rig_ssh "cat $marker" 2>/dev/null)" 2>/dev/null)

digest_before=$(apps_digest)
id_before=$(traefik_container_id)
started_at_before=$(traefik_started_at)
demo_id_before=$(rig_ssh "docker inspect -f '{{.Id}}' $container" 2>/dev/null)

status; rc=$?
assert '[ "$rc" = "0" ]' "server status on the deployed rig exits 0 (exit $rc: $(cli_err))"
assert '[ -n "$want_docker" ] && [ -n "$want_image_id" ] && [ -n "$want_version" ]' \
    "the rig answered every question the comparison needs (docker '$want_docker', image '$want_image_id', version '$want_version')"

assert 'grep -qF "Docker: $want_docker, Compose: $want_compose" "$tmpdir/out"' \
    "the versions are the daemon's own (wanted '$want_docker'/'$want_compose', said '$(status_out)')"
assert 'grep -qF "Root: $apps (pointer)  Data: $want_marker_data" "$tmpdir/out"' \
    "the paths are the marker's, and the root came from the server's own pointer (wanted '$want_marker_data', said '$(status_out)')"
assert 'grep -qF "Traefik: $want_tstate ($want_thealth)" "$tmpdir/out"' \
    "Traefik's state and health are what docker reports (wanted '$want_tstate ($want_thealth)', said '$(status_out)')"
# `-x`, and a second assertion that the full id is absent: the untruncated id
# *contains* the truncated one, so a substring match here would pass against a
# line that prints all 71 characters.
assert 'grep -qxF "  Image: $want_image (${want_image_id:0:19})" "$tmpdir/out"' \
    "and the image is the one it is actually running (wanted '$want_image ${want_image_id:0:19}', said '$(status_out)')"
assert '! grep -qF "$want_image_id" "$tmpdir/out"' \
    "shortened to twelve hex digits, not printed whole (said '$(grep Image: "$tmpdir/out")')"

# The project list is the set of directories that are there, not a name this
# file knows: a status that printed `demo` because someone typed it here would
# pass the row assertion below and fail this one.
# `[^ ][^ ]*` rather than `[^ ]*`: a project row is two spaces then a name, and
# every line under it — the domain, its certificate, the containers — is
# indented further. A pattern that lets the name be empty matches those too and
# turns the list into a row of blanks.
listed=$(sed -n '/^Projects:/,/^$/p' "$tmpdir/out" | sed -n 's/^  \([^ ][^ ]*\) .*/\1 /p' | sort | tr -d '\n')
assert '[ "$listed" = "$want_projects" ]' \
    "the projects listed are the directories under $apps (wanted '$want_projects', listed '$listed')"
assert '[ "$want_total" != "0" ] && [ "$want_running" = "$want_total" ]' \
    "the fixture has every container it declares running ($want_running/$want_total) — which is the state the word below is asserted for"
assert 'grep -qE "^  $project +$want_running/$want_total running +$want_version " "$tmpdir/out"' \
    "the row carries the container counts and the version versions.log holds
        wanted: $project $want_running/$want_total running $want_version
        line:   $want_line
        said:   $(grep "^  $project" "$tmpdir/out")"
# The timestamp is what separates the last entry from the first: this project
# deployed the same version twice, so a status reading line 1 would print the
# right version off the wrong deploy.
assert 'grep -qF "$want_action $want_ts (kasbah ${want_kasbah#kasbah=})" "$tmpdir/out"' \
    "and the action, timestamp and kasbah version of the *last* entry
        wanted: $want_action $want_ts (kasbah ${want_kasbah#kasbah=})
        said:   $(grep "^  $project" "$tmpdir/out")"

# The five things 7.6 added, against a rig that has them: the project's domain
# comes out of its own Traefik fragment (parsed here — the rig has no yq), the
# disk figure out of df, and the container list out of docker. Read off the rig
# moments before the comparison, exactly as everything above is.
want_host=$(rig_ssh "cat $apps/traefik/dynamic/$project.yml" 2>/dev/null \
    | tr -d '\r' | sed -n 's/.*Host(`\([^`]*\)`).*/\1/p' | head -1)
want_cnames=$(rig_ssh "docker ps -a --filter label=com.docker.compose.project=$project --format '{{.Names}}'" 2>/dev/null | tr -d '\r' | sort | tr '\n' ' ')
assert '[ -n "$want_host" ]' "the deployed project's fragment claims a hostname (got '$want_host')"
assert 'grep -qxF "      $want_host" "$tmpdir/out"' \
    "status prints the domain out of $apps/traefik/dynamic/$project.yml (wanted '$want_host', said '$(status_out)')"
assert 'grep -qE "^Disk: $apps  [0-9]" "$tmpdir/out"' \
    "and a disk figure for the apps path (said '$(grep -A1 "^Disk:" "$tmpdir/out")')"
assert 'grep -qE "^  Certificates: " "$tmpdir/out"' \
    "and what the certificate store can answer — on the rig, an empty one (said '$(grep "Certificates:" "$tmpdir/out")')"
assert 'grep -qE "container\(s\), all running|^      [a-z0-9_.-]+ +[a-z]+ \(" "$tmpdir/out"' \
    "and the project's containers, which is the health nothing but Traefik had (wanted '$want_cnames', said '$(status_out)')"
# The precondition of the assertion above it, not a round-trip check: the
# container line can only be evidence if the project has containers. **The
# one-round-trip guarantee is pinned in tests/server_status_test.sh**, by
# counting `bash -s` invocations in a stub ssh's log — nothing here counts ssh
# sessions, and a comment claiming otherwise would describe a check that is not
# in this file.
assert '[ -n "${want_cnames// /}" ]' "the project has containers to report on (got '$want_cnames')"

# Read-only, proved on a real server rather than argued: the tree is unmoved to
# the mtime, and neither container was recreated.
assert '[ "$(apps_digest)" = "$digest_before" ]' \
    "server status changed nothing under $apps — not a mode, not a byte, not an mtime"
assert '[ "$(traefik_container_id)" = "$id_before" ]' "and did not recreate Traefik"
assert '[ "$(traefik_started_at)" = "$started_at_before" ]' "or restart it"
demo_id_after=$(rig_ssh "docker inspect -f '{{.Id}}' $container" 2>/dev/null)
assert '[ "$demo_id_after" = "$demo_id_before" ]' \
    "or touch the project's container"

# The digest is only evidence if it can tell. One touch inside a project must
# break it. The mtime is left moved: nothing reads that file again, and
# rig_clean removes the tree at the end of the suite.
rig_ssh "touch $apps/$project/versions.log" >/dev/null 2>&1
assert '[ "$(apps_digest)" != "$digest_before" ]' \
    "the digest notices a bare touch — else the read-only assertion above proves nothing"

# --- The word in the state column, against a real docker ---------------------------------
# Everything the rig has ever shown this suite is a project with every container
# up, so `running` is the only word the deploy path can produce — and a column
# that said `0/1 running` for a dead site would pass every assertion above.
# Stopping the fixture's container is the cheapest way to have docker disagree.
rig_ssh "docker stop $container" >/dev/null 2>&1
stopped_state=$(rig_ssh "docker inspect -f '{{.State.Status}}' $container" 2>/dev/null | tr -d '\r')
assert '[ -n "$stopped_state" ] && [ "$stopped_state" != "running" ]' \
    "the fixture's container really is down (docker says '$stopped_state') — else the word below proves nothing"
status; rc=$?
assert '[ "$rc" = "0" ]' "status reports with a project's container stopped (exit $rc: $(cli_err))"
assert 'grep -qE "^  $project +0/1 stopped " "$tmpdir/out"' \
    "and calls it stopped rather than '0/1 running' (said '$(grep "^  $project" "$tmpdir/out")')"

rig_ssh "docker start $container" >/dev/null 2>&1
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(rig_ssh "docker inspect -f '{{.State.Status}}' $container" 2>/dev/null | tr -d '\r')" = running ] && break
    sleep 1
done
status; rc=$?
assert 'grep -qE "^  $project +1/1 running " "$tmpdir/out"' \
    "and back to running once it is up again — the column tracks docker both ways (said '$(grep "^  $project" "$tmpdir/out")')"

# --- --apps-path, end to end -----------------------------------------------------------
# The one flag status has that deploy does not. Parsed correctly and never sent,
# it would look identical from here — so the check is that a *second* prepared
# tree, somewhere rig_clean does not reach, is the one read.
#
# Built by hand rather than by init: what is under test is that the flag steers
# every read, not that init can lay out a second server. It lives outside /apps
# and comes back off the rig in the EXIT trap whatever happens.
alt_apps=/home/stevedore/kasbah-alt-apps
alt_line='2026-08-14T00:00:00+00:00 deploy 7.7.7 no-backup kasbah=9.9.9 digest=- future=xyz'
# The marker of the real server with its two paths moved, so the data directory
# is `store` — a name no static list can hold, and the case that proves the
# bind-mount root is filtered from the marker rather than from a hard-coded list.
alt_marker=$(jq --arg a "$alt_apps" '.apps_path = $a | .data_path = ($a + "/store")' \
    <<<"$(rig_ssh "cat $marker" 2>/dev/null)" 2>/dev/null)
if [ -n "$alt_marker" ] && rig_ssh "mkdir -p $alt_apps/.kasbah $alt_apps/altproj $alt_apps/store && printf '%s\n' '$alt_line' > $alt_apps/altproj/versions.log && cat > $alt_apps/.kasbah/server.json" >/dev/null 2>&1 <<<"$alt_marker"; then
    alt_planted=yes
    status --apps-path="$alt_apps"; rc=$?
    assert '[ "$rc" = "0" ]' "server status --apps-path reads a server prepared elsewhere (exit $rc: $(cli_err))"
    assert 'grep -qF "Root: $alt_apps (flag)  Data: $alt_apps/store" "$tmpdir/out"' \
        "and reports that tree's own paths, read because the flag said so (said '$(status_out)')"
    assert 'grep -qE "^  altproj +no containers +7\.7\.7 +deploy 2026-08-14T00:00:00\+00:00 \(kasbah 9\.9\.9\)$" "$tmpdir/out"' \
        "the project it lists is the one under --apps-path, with its own log line (said '$(status_out)')"
    assert '! grep -qE "^  $project " "$tmpdir/out"' \
        "and not the one under $apps — the flag steered the whole read (said '$(status_out)')"
    assert '! grep -qE "^  store " "$tmpdir/out"' \
        "the marker's own data directory is not a project, whatever it is called (said '$(status_out)')"
    # The forward-compatibility rule, end to end: that line carries a pair this
    # kasbah has never heard of, and it is ignored rather than printed or
    # choked on.
    assert '! grep -qF "future=xyz" "$tmpdir/out"' \
        "a trailing pair this version does not know is ignored, not echoed (said '$(status_out)')"
    # And the default is still the default: the flag changed this run, not the
    # command.
    status; rc=$?
    assert '[ "$rc" = "0" ]' "and without the flag status is back on $apps (exit $rc: $(cli_err))"
    assert 'grep -qE "^  $project " "$tmpdir/out"' "listing $project again (said '$(status_out)')"
    assert '! grep -qE "^  altproj " "$tmpdir/out"' "and not altproj (said '$(status_out)')"

    rig_ssh "rm -rf $alt_apps" >/dev/null 2>&1 && alt_planted=""
    assert '[ -z "$alt_planted" ]' "the second tree was removed from the rig"
else
    assert 'false' "could not plant a second prepared tree at $alt_apps on the rig"
fi

# --- An untagged HEAD: deploy --bump=patch tags it, deploys it, pushes it -----------------
# A commit past v$project_version, and a bare repository standing in for origin.
bump_origin="$tmpdir/bump-origin.git"
bumped=$(printf '%s' "$project_version" | awk -F. '{ printf "%d.%d.%d", $1, $2, $3 + 1 }')
if ! ( git init -q --bare "$bump_origin" && cd "$projdir" && git commit -q --allow-empty -m "past v$project_version" \
        && git remote add origin "$bump_origin" ) >"$tmpdir/git.log" 2>&1; then
    echo "error: could not move HEAD past v$project_version in the fixture copy" >&2
    sed 's/^/       | /' "$tmpdir/git.log" >&2
    exit 2
fi
deploy "$RIG_TARGET" --bump=patch; rc=$?
assert '[ "$rc" = "0" ]' "deploy --bump=patch on an untagged HEAD succeeds (exit $rc: $(cli_err))"
head_tags=$(cd "$projdir" && git tag --points-at HEAD | tr '\n' ' ')
assert '[ "$head_tags" = "v$bumped " ]' "having tagged HEAD v$bumped (HEAD has: '$head_tags')"
last_line=$(rig_ssh "tail -n 1 $apps/$project/versions.log" 2>/dev/null | tr -d '\r')
assert '[[ "$last_line" == *" deploy $bumped "* ]]' "and deployed it under that version (line: $last_line)"
origin_tags=$(git --git-dir="$bump_origin" tag | tr '\n' ' ')
assert '[ "$origin_tags" = "v$bumped " ]' "and pushed the tag to origin (origin has: '$origin_tags')"
assert 'grep -qF "git:     pushed v$bumped to origin" "$tmpdir/err"' "saying so (said '$(cli_err)')"

# --- Leave the rig as it was found, but only on success ------------------------------------
if [ "$fail" -eq 0 ]; then
    rig_clean || fail=1
fi

exit "$fail"
