#!/usr/bin/env bash
# Integration test: the spine — `hosting server init` then `hosting deploy`,
# against the live rig, ending at a page served through Traefik.
#
# This is the phase's exit criterion made checkable: a stock nginx project put
# on a prepared server by deploy, routed by a file-provider fragment that
# Traefik picked up without restarting. Everything is read back off the rig;
# hosting's own summary is never the evidence.
#
# Anything downstream of a fragment write is polled, never asserted straight
# after the rsync returns: Traefik's providersThrottleDuration puts a ~2 s floor
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

apps=/apps
data=/apps/data
marker="$apps/.hosting/server.json"

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
# is given a git history. `git init` inside the checkout would land in hosting's
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
cleanup() {
    [ -z "$bashrc_planted" ] || rig_ssh "mv -f ~/.bashrc.hosting-unit-d ~/.bashrc" >/dev/null 2>&1
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

init() { hosting_cli server init "$RIG_TARGET" "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null; }
deploy() (
    cd "$projdir" || return 2
    hosting_cli deploy "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null
)
cli_err() { cat "$tmpdir/err"; }

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
    echo "error: the server marker carries no limits to seed the project .env with" >&2
    echo "       marker: $marker_json" >&2
    exit 2
fi
# The values Phase 3 will inject into every project's .env, in the shape the
# compose files expect them.
assert '[[ "$cpu_limit" =~ ^[0-9]+\.[0-9]$ ]]' "the marker's cpu_limit is a number (got '$cpu_limit')"
assert '[[ "$mem_limit" =~ ^[0-9]+[gm]$ ]]'    "the marker's mem_limit carries a unit (got '$mem_limit')"

# --- The project, with a git history of its own -----------------------------------
projdir="$tmpdir/$project"
cp -R "$repo_dir/tests/fixtures/$project" "$projdir" || exit 2
if ! (
    cd "$projdir" || exit 1
    git init -q .
    # The scratch HOME the harness uses has no git identity, so the repo carries
    # its own. Signing is off for the same reason: whatever the developer's
    # global config says must not decide whether this commit can be made.
    git config user.email "spine-test@$rig_domain"
    git config user.name  "hosting spine test"
    git config commit.gpgsign false
    git add -A
    git commit -qm "the demo fixture, v$project_version"
    git tag "v$project_version"
) >"$tmpdir/git.log" 2>&1; then
    echo "error: could not give the fixture copy a git repo with a v-tag" >&2
    sed 's/^/       | /' "$tmpdir/git.log" >&2
    exit 2
fi

# --- Deploy refuses before the .env exists ----------------------------------------
# The seam Phase 3 replaces. It is asserted rather than assumed, because the
# whole reason the test seeds .env by hand is that nothing else does yet.
deploy "$RIG_TARGET"; rc=$?
assert '[ "$rc" != "0" ]' "deploy refuses a project with no .env on the server (exit $rc)"
assert 'grep -qF "$apps/$project/.env" "$tmpdir/err"' \
    "and names the file it wants (said '$(cli_err)')"
assert 'grep -qF "Phase 3" "$tmpdir/err"' \
    "and says what will render it (said '$(cli_err)')"
assert '[ "$(rig_ssh "[ -e $fragment ] && echo present || echo absent" 2>/dev/null)" = "absent" ]' \
    "a refused deploy ships no Traefik fragment — a route to a container that never started"
assert '[ ! -f "$projdir/.hosting/state.json" ]' \
    "and writes no project state (docs/project-manifest.md: only on success)"

# --- Can this rig apply a cgroup limit at all? --------------------------------------
# Measured, not assumed, because on the rig as built today it cannot: the
# container's cgroup root holds processes and has no `init` sub-cgroup, so the
# nested dockerd cannot distribute domain controllers and runc falls back to
# threaded cgroups. Any --cpus or --memory then fails with
#   cannot enter cgroupv2 "/sys/fs/cgroup/docker" with domain controllers
#   -- it is in threaded mode
# and the container never starts. That is a property of the rig, not of hosting
# (docs/phases/02-spine.md → Findings), and the fix is the standard docker:dind
# cgroup-nesting step in the rig's entrypoint.
#
# So the seeded values are chosen from what the rig can do: 0 means "no limit"
# to Docker and skips the cgroup path entirely. The probe is what keeps this
# honest — a rig that grows cgroup nesting seeds the marker's real limits
# instead, with no edit here.
limit_probe=$(rig_ssh "docker run --rm --cpus 0.5 --memory 64m nginx:alpine /bin/true 2>&1" 2>/dev/null); probe_rc=$?
if [ "$probe_rc" -eq 0 ]; then
    seed_cpu="$cpu_limit"
    seed_mem="$mem_limit"
elif grep -qF "threaded mode" <<<"$limit_probe"; then
    seed_cpu=0
    seed_mem=0
    echo "note: this rig cannot apply cgroup limits (nested cgroup v2 is in threaded mode)," >&2
    echo "      so the project .env is seeded with 0/0 — Docker reads that as no limit." >&2
else
    echo "error: could not tell whether the rig can apply cgroup limits (rc $probe_rc)" >&2
    sed 's/^/       | /' <<<"$limit_probe" >&2
    exit 2
fi

# --- Seed .env by hand -------------------------------------------------------------
# Exactly what Phase 3's HOSTING_* injection will take over: the two resource
# limits (from the server marker, wherever the rig can honour them) plus the one
# variable the fixture's own template declares. Nothing else creates this file
# today, which is why the refusal above is asserted rather than assumed.
rig_ssh "mkdir -p $apps/$project && cat > $apps/$project/.env" <<EOF >/dev/null 2>&1
HOSTING_CPU_LIMIT=$seed_cpu
HOSTING_MEM_LIMIT=$seed_mem
DEMO_GREETING=hello from the demo fixture
EOF
seeded=$(rig_ssh "cat $apps/$project/.env" 2>/dev/null)
if ! grep -qF "HOSTING_CPU_LIMIT=$seed_cpu" <<<"$seeded"; then
    echo "error: could not seed $apps/$project/.env on the rig (got '$seeded')" >&2
    exit 2
fi

# --- A deploy that cannot finish must not route anything ------------------------------
# The fragment is the last thing a deploy ships, after `compose up` has
# returned 0. Everything that can make it fail — an image that will not pull, a
# port already bound, a value the compose file cannot use — would otherwise
# leave `demo.test` routed at a container that does not exist, answering 502
# until somebody deploys again. An unpullable image is the cheapest way to hold
# `compose up` at arm's length.
broken_image=nginx:no-such-tag-hosting-unit-d
break_image() { sed -i "s|image: nginx:alpine|image: $broken_image|" "$projdir/compose.prod.yml"; }
fix_image()   { sed -i "s|image: $broken_image|image: nginx:alpine|" "$projdir/compose.prod.yml"; }

break_image
assert 'grep -qF "$broken_image" "$projdir/compose.prod.yml"' \
    "the working tree really does name an unpullable image — else this case proves nothing"
deploy "$RIG_TARGET"; rc=$?
assert '[ "$rc" != "0" ]' "a deploy whose compose up fails is a failed deploy (exit $rc)"
assert '[ "$(rig_ssh "[ -e $fragment ] && echo present || echo absent" 2>/dev/null)" = "absent" ]' \
    "and ships no fragment — nothing reaches traefik/dynamic until the deploy is known to have finished"
unrouted_code=$(code_stays "$project_host" 404); stays_rc=$?
assert '[ "$stays_rc" = "0" ]' \
    "so the host stays unrouted rather than turning 502 a reload later (went to '$unrouted_code')"
assert '[ "$(rig_ssh "[ -e $apps/$project/versions.log ] && echo present || echo absent" 2>/dev/null)" = "absent" ]' \
    "no versions.log line for a deploy that did not run"
assert '[ ! -f "$projdir/.hosting/state.json" ]' "and no project state"
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
    echo "  FAIL: hosting deploy succeeded against the prepared rig (exit $rc)" >&2
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
           helper_mode f_unrenamed versions_lines versions_first c_project c_state c_nets c_env; do
    [ -n "${got[$key]+set}" ] || missing+=("$key")
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "error: the readback reported no ${missing[*]}" >&2
    sed 's/^/       | /' <<<"$land_out" >&2
    exit 2
fi

assert '[ "${got[d_project]}" = "yes" ]'  "$apps/$project is a directory (got '${got[d_project]}')"
assert '[ "${got[d_scripts]}" = "yes" ]'  "$apps/$project/scripts is a directory (got '${got[d_scripts]}')"
assert '[ "${got[d_backups]}" = "yes" ]'  "$apps/$project/backups is a directory (got '${got[d_backups]}')"
assert '[ "${got[d_data]}" = "yes" ]'     "$data/$project is a directory (got '${got[d_data]}')"
assert '[ "${got[f_compose]}" = "yes" ]' \
    "the sync list's rename landed: compose.prod.yml arrived as compose.yml (got '${got[f_compose]}')"
assert '[ "${got[f_unrenamed]}" = "no" ]' \
    "and under that name only — a rename, not a copy (got '${got[f_unrenamed]}')"
assert '[ "${got[f_envexample]}" = "yes" ]' "the plain sync entry landed (got '${got[f_envexample]}')"
assert '[ "${got[f_page]}" = "yes" ]' \
    "and the trailing-slash entry recursed: site/index.html is there (got '${got[f_page]}')"
assert '[ "${got[f_helper]}" = "yes" ]'   "remote-deploy.sh was shipped (got '${got[f_helper]}')"
assert '[ "${got[helper_mode]}" = "755" ]' \
    "and landed executable — hosting runs it over ssh (got '${got[helper_mode]}')"

# --- versions.log ---------------------------------------------------------------------
assert '[ "${got[versions_lines]}" = "1" ]' \
    "one deploy wrote exactly one versions.log line (got '${got[versions_lines]}')"
read -r v_ts v_action v_version v_backup v_hosting v_digest v_extra <<<"${got[versions_first]}"
assert '[[ "$v_ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\+00:00$ ]]' \
    "field 1 is a UTC ISO-8601 timestamp (line: '${got[versions_first]}')"
assert '[ "$v_action" = "deploy" ]'   "field 2 is the action (got '$v_action')"
assert '[ "$v_version" = "$project_version" ]' \
    "field 3 is the version off HEAD's tag (got '$v_version')"
assert '[ "$v_backup" = "no-backup" ]' "field 4 is the backup path, absent here (got '$v_backup')"
assert '[ "$v_hosting" = "hosting=$(cat "$repo_dir/VERSION")" ]' \
    "then hosting=<this checkout's version> (got '$v_hosting')"
assert '[ "$v_digest" = "digest=-" ]' \
    "and digest=- , because a stock-only project builds no image (got '$v_digest')"
assert '[ -z "$v_extra" ]' "with nothing appended after it yet (got '$v_extra')"

# --- The container, and how Traefik reaches it -------------------------------------------
assert '[ "${got[c_state]}" = "running" ]' "$container is running (got '${got[c_state]}')"
assert '[ "${got[c_project]}" = "$project" ]' \
    "it belongs to the compose project deploy names with -p (got '${got[c_project]}')"
assert 'grep -qw "hosting-net" <<<"${got[c_nets]}"' \
    "and it is on hosting-net, which is what makes container_name resolvable (networks: ${got[c_nets]})"
assert 'grep -qw "demo_internal" <<<"${got[c_nets]}"' \
    "as well as the project's own network (networks: ${got[c_nets]})"
assert '[ "${got[c_env]}" = "1" ]' \
    "compose read the seeded .env — DEMO_GREETING reached the container (got '${got[c_env]}' matches)"

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
state="$projdir/.hosting/state.json"
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
if rig_ssh "cp ~/.bashrc ~/.bashrc.hosting-unit-d && printf 'export COMPOSE_PROJECT_NAME=%s\n%s' hosting-not-demo \"\$(cat ~/.bashrc)\" > ~/.bashrc.new && mv ~/.bashrc.new ~/.bashrc" >/dev/null 2>&1; then
    bashrc_planted=yes
    planted=$(rig_ssh "bash -s" <<<'echo "${COMPOSE_PROJECT_NAME:-unset}"' 2>/dev/null)
    assert '[ "$planted" = "hosting-not-demo" ]' \
        "COMPOSE_PROJECT_NAME reaches the shell remote-deploy.sh runs in (got '$planted') — else this case proves nothing"

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
    lines=$(rig_ssh "wc -l < $apps/$project/versions.log" 2>/dev/null | tr -d ' ')
    assert '[ "$lines" = "2" ]' "the second deploy appended a second line (got '$lines')"
    assert '[ "$(rig_ssh "head -1 $apps/$project/versions.log" 2>/dev/null)" = "${got[versions_first]}" ]' \
        "and left the first one exactly as it was"

    rig_ssh "mv -f ~/.bashrc.hosting-unit-d ~/.bashrc" >/dev/null 2>&1 && bashrc_planted=""
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

# --- Leave the rig as it was found, but only on success ------------------------------------
if [ "$fail" -eq 0 ]; then
    rig_clean || fail=1
fi

exit "$fail"
