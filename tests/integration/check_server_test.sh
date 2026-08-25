#!/usr/bin/env bash
# Integration test: `kasbah check --server USER@HOST` against the live rig.
#
# What only the rig can show, and what the hermetic suite in
# tests/check_test.sh therefore cannot:
#   * the apps path, the data path and the host's limits arriving from a real
#     server marker, and the project directory, `.env`, mail registry, dashboard
#     fragment and certificate store all read back over one real ssh session —
#     a stub ssh agrees with any spelling of those paths;
#   * T05's tightened form built from files a real `server init` wrote: the
#     apex out of <apps>/traefik/dynamic/_shared.yml and the primary domain out
#     of <apps>/mail/kasbah.yml;
#   * E02/E03 against a `.env` that a real deploy generated, with the KASBAH_*
#     block a real deploy injected — which is also what R04 reads;
#   * a certificate store this user genuinely cannot read (mode 000 applies to
#     the owner too), rather than a fact table that says so;
#   * **that the whole thing writes nothing**, digested off the rig.
#
# What the rig cannot show, and the brief does not ask it to: a store with
# certificates in it. There is no public DNS here, HTTP-01 never validates, and
# `.test` is reserved by RFC 6761 — so acme.json stays empty. The parser's
# evidence is the hand-built fixtures in tests/check_test.sh plus one run
# against the real host.
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
acme="$data/traefik/letsencrypt/acme.json"

rig_domain=rig.test
traefik_flags=(--domain="$rig_domain" --email="ops@$rig_domain"
               --traefik-auth="dashadmin:rig-dashboard-pw")
postmaster_pw='rig-postmaster-pw'

project=demo
project_version=1.0.0
project_dir="$apps/$project"
container=demo-web

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

tmpdir="$(mktemp -d)"
acme_locked=""
cleanup() {
    [ -z "$acme_locked" ] || rig_ssh "chmod 600 '$acme'" >/dev/null 2>&1
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
projdir="$tmpdir/$project"
srcdir="$tmpdir/src"
init()    { kasbah_cli server init "$RIG_TARGET" "$@" >"$tmpdir/out" 2>"$tmpdir/err" </dev/null; }
cli_out() { cat "$tmpdir/out"; }
cli_err() { cat "$tmpdir/err"; }
kasbah_bounded() (
    cd "${KASBAH_CWD:-$projdir}" || return 2
    timeout "${DEPLOY_TIMEOUT:-240}" \
        env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" \
            "$RIG_REPO_DIR/bin/kasbah" "$@" \
        >"$tmpdir/out" 2>"$tmpdir/err" </dev/null
)
deploy() { kasbah_bounded deploy "$@"; }
check()  { kasbah_bounded check "$@"; }

# Type, mode, owner, mtime and content of the apps and data trees. acme.json is
# left out of both halves for the reason spine_test.sh leaves it out: Traefik
# owns that file and rewrites it on its own schedule, so a digest covering it
# would fail for something check never did.
tree_digest() {
    rig_ssh "{ find $apps $data ! -name acme.json -printf '%y %m %u:%g %T@ %p\n' | sort; find $apps $data -type f ! -name acme.json -exec sha256sum {} + | sort; } | sha256sum" 2>/dev/null
}

# --- A prepared server, with the mail stack ----------------------------------------
# --with-mail, because M03 and T05's tightened form both read the registry the
# mail stack owns. DMS crashloops here forever — `SSL_TYPE: letsencrypt` makes a
# certificate a boot requirement the rig can never meet — and nothing below
# waits on it: the registry is a file, and that is what is being read.
init --with-mail --postmaster-password="$postmaster_pw" --no-backup "${traefik_flags[@]}"; rc=$?
if [ "$rc" != "0" ]; then
    echo "error: server init failed on a cleaned rig (exit $rc) — there is nothing to check against" >&2
    sed 's/^/       | /' "$tmpdir/err" >&2
    exit 2
fi

# The rig cannot apply cgroup limits (nested cgroup v2 in threaded mode), so the
# marker is rewritten to 0/0 — Docker's "no limit" — exactly as the other rig
# suites do (docs/phases/02-spine.md → Findings). R04 then compares 0 with 0,
# which is a real comparison of the two numbers that reach it.
marker_json=$(rig_ssh "cat $marker" 2>/dev/null)
limit_probe=$(rig_ssh "docker run --rm --cpus 0.5 --memory 64m nginx:alpine /bin/true 2>&1" 2>/dev/null); probe_rc=$?
if [ "$probe_rc" -ne 0 ]; then
    if ! grep -qF "threaded mode" <<<"$limit_probe"; then
        echo "error: could not tell whether the rig can apply cgroup limits (rc $probe_rc)" >&2
        sed 's/^/       | /' <<<"$limit_probe" >&2
        exit 2
    fi
    echo "note: this rig cannot apply cgroup limits (nested cgroup v2 is in threaded mode)," >&2
    echo "      so the server marker is rewritten to 0/0 — Docker reads that as no limit." >&2
    new_marker=$(jq '.cpu_limit = "0" | .mem_limit = "0"' <<<"$marker_json" 2>/dev/null)
    if [ -z "$new_marker" ] || ! rig_ssh "cat > $marker" <<<"$new_marker" >/dev/null 2>&1; then
        echo "error: could not rewrite the server marker's limits on the rig" >&2
        exit 2
    fi
    marker_json="$new_marker"
fi
marker_cpu=$(jq -r '.cpu_limit' <<<"$marker_json" 2>/dev/null)
marker_mem=$(jq -r '.mem_limit' <<<"$marker_json" 2>/dev/null)

# --- The project ------------------------------------------------------------------
# The fixture, plus the two manifest blocks this command asks the server about:
# a health container to inspect and a mail claim to reconcile against the
# registry. Added to the source before the copy is given its git history, so
# the tag and the working tree agree.
cp -a "$repo_dir/tests/fixtures/$project" "$srcdir" || exit 2
{
    printf '\nhealth:\n  container: %s\n' "$container"
    printf '\nmail:\n  domain: %s\n' "$rig_domain"
} >> "$srcdir/kasbah.yml"
# And a healthcheck, because the fixture declares none and a container with no
# healthcheck can only ever report `none` — which is the warn branch, not the
# one this suite is here to prove. `deploy` waits for healthy, so by the time
# the check below runs the container really has passed one.
python3 - "$srcdir/compose.prod.yml" <<'EDIT' || exit 2
import sys
p = sys.argv[1]
s = open(p).read()
mark = "    container_name: demo-web\n"
if mark not in s:
    sys.exit("fixture no longer sets container_name: demo-web")
hc = mark + """    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://localhost/"]
      interval: 2s
      timeout: 2s
      retries: 5
      start_period: 2s
"""
open(p, "w").write(s.replace(mark, hc, 1))
EDIT

if ! fixture_repo_make "$projdir" "$srcdir" "v$project_version" 2>"$tmpdir/git.log"; then
    echo "error: could not give the fixture copy a git repo with a v-tag" >&2
    sed 's/^/       | /' "$tmpdir/git.log" >&2
    exit 2
fi

# The first deploy cannot finish: there is no .env on the server and no terminal
# at either end, so the env step refuses with exit 5 rather than feeding the
# generator EOF (docs/cli.md). It does ship the template and the helper, which
# is what the operator then runs by hand — the same two-step every rig suite
# uses, with this suite playing the person at the terminal.
deploy "$RIG_TARGET" >/dev/null 2>&1
setup_out=$(rig_ssh "cd $apps/$project && ./scripts/setup-env.sh $apps/$project" </dev/null 2>&1); setup_rc=$?
if [ "$setup_rc" -ne 0 ]; then
    echo "error: the shipped setup-env.sh did not render $apps/$project/.env (rc $setup_rc)" >&2
    sed 's/^/       | /' <<<"$setup_out" >&2
    exit 2
fi

deploy "$RIG_TARGET"; rc=$?
if [ "$rc" != "0" ]; then
    echo "error: deploy failed on the prepared rig (exit $rc) — there is nothing deployed to check" >&2
    sed 's/^/       | /' "$tmpdir/err" >&2
    exit 2
fi

# --- The run, and what it must not have done ----------------------------------------
digest_before=$(tree_digest)
check --server "$RIG_TARGET"; rc=$?
out="$(cli_out)"
digest_after=$(tree_digest)

assert '[ -n "$digest_before" ] && [ "$digest_after" = "$digest_before" ]' \
    "check --server changes nothing on the server (apps and data trees digest identical)"
# The digest is only evidence if it can tell.
rig_ssh "touch $project_dir/.kasbah-digest-probe" >/dev/null 2>&1
assert '[ "$(tree_digest)" != "$digest_before" ]' \
    "the digest notices a bare touch — else the read-only assertion above proves nothing"
rig_ssh "rm -f $project_dir/.kasbah-digest-probe" >/dev/null 2>&1

assert '[ "$rc" = "0" ]' "a freshly deployed project passes check --server (exit $rc)
$out
$(cli_err)"
assert 'grep -qF "Server ($RIG_TARGET at $apps):" <<<"$out"' \
    "the section names the target and the apps path read off the marker (said '$out')"
assert 'grep -qF "✓ $project_dir exists on $RIG_TARGET" <<<"$out"' \
    "the project directory a real deploy created (said '$out')"
assert 'grep -qF "✓ .env on $RIG_TARGET has no missing keys vs .env.prod.example" <<<"$out"' \
    "E02 against the .env a real deploy generated (said '$out')"
assert 'grep -qF "✓ .env on $RIG_TARGET has no extra keys vs .env.prod.example" <<<"$out"' \
    "E03 against the same file — the KASBAH_* block a deploy injected is exempt (said '$out')"
assert 'grep -qF "✓ the mail stack on $RIG_TARGET serves '"'"'$rig_domain'"'"' (its primary_domain)" <<<"$out"' \
    "M03 against the registry server init --with-mail wrote (said '$out')"
assert 'grep -qF "✓ manifest health.container '"'"'$container'"'"' is running and healthy on $RIG_TARGET" <<<"$out"' \
    "the health of the container the deploy brought up (said '$out')"
assert 'grep -qF "✓ effective resource limits on $RIG_TARGET match the host'"'"'s 90% ceiling ($marker_cpu cpus, $marker_mem)" <<<"$out"' \
    "R04, comparing the deployed .env with the marker (said '$out')"
# T05's tightened form, built from two files a real init wrote — the dashboard
# router's apex and the registry's primary domain.
assert 'grep -qF "✓ No router claims a hostname kasbah owns on $RIG_TARGET (traefik.$rig_domain mail.$rig_domain webmail.$rig_domain)" <<<"$out"' \
    "T05 tightened to hostnames read off this server (said '$out')"

# The certificate store. There will never be a certificate for demo.test here —
# no public DNS, so HTTP-01 cannot validate — but which of the three
# no-certificate states the store is in depends on whether Traefik has managed
# to register an ACME account by now, and that is Traefik's schedule, not this
# suite's. All three are warnings and all three name the store or the domain.
assert 'grep -qE "⚠ (the certificate store at $acme on $RIG_TARGET (is empty|holds no certificates)|no certificate for .demo.test.)" <<<"$out"' \
    "the store answers about demo.test without claiming a certificate (said '$out')"

# --- A store this user cannot read ---------------------------------------------------
# Mode 000 applies to the owner too, which is the one state a fact table can
# assert and only a real filesystem can produce.
acme_locked=1
rig_ssh "chmod 000 '$acme'" >/dev/null 2>&1
check --server "$RIG_TARGET"; rc=$?
out="$(cli_out)"
assert 'grep -qF "$acme on $RIG_TARGET cannot be read by this user" <<<"$out"' \
    "an unreadable store is reported as that, not as an empty one (said '$out')"
assert '[ "$rc" = "0" ]' "and it warns rather than failing (exit $rc)"
rig_ssh "chmod 600 '$acme'" >/dev/null 2>&1
acme_locked=""

# --- M03, on a domain the registry does not carry --------------------------------------
sed -i "s/^  domain: $rig_domain\$/  domain: nowhere.rig.test/" "$projdir/kasbah.yml"
check --server "$RIG_TARGET"; rc=$?
out="$(cli_out)"
assert '[ "$rc" = "6" ]' "M03 fails a claim this stack does not serve (exit $rc)"
assert 'grep -qF "✗ the mail stack on $RIG_TARGET does not serve '"'"'nowhere.rig.test'"'"'" <<<"$out"' \
    "saying so, against the registry on the rig (said '$out')"
sed -i "s/^  domain: nowhere.rig.test\$/  domain: $rig_domain/" "$projdir/kasbah.yml"

# --- R04, above the host's ceiling ------------------------------------------------------
# The .env on the rig is edited by the suite, not by kasbah: what is being
# proved is that check reads the effective limit from the file compose
# interpolates, and 999 is above any ceiling this host could report.
rig_ssh "cp $project_dir/.env $project_dir/.env.kasbah-suite-backup" >/dev/null 2>&1
rig_ssh "sed -i 's/^KASBAH_CPU_LIMIT=.*/KASBAH_CPU_LIMIT=999/' $project_dir/.env" >/dev/null 2>&1
check --server "$RIG_TARGET"; rc=$?
out="$(cli_out)"
assert '[ "$rc" = "6" ]' "R04 fails an effective cpu limit above the host's ceiling (exit $rc)"
assert 'grep -qF "✗ effective resource limits on $RIG_TARGET are above the host'"'"'s 90% ceiling: cpus 999 > $marker_cpu" <<<"$out"' \
    "naming both numbers, read off the .env and the marker (said '$out')"
rig_ssh "mv -f $project_dir/.env.kasbah-suite-backup $project_dir/.env" >/dev/null 2>&1

# --- A project that has not been deployed ------------------------------------------------
notdir="$tmpdir/not-deployed"
mkdir -p "$notdir"
(cd "$notdir" && env HOME="$RIG_HOME" PATH="$RIG_SHIM_DIR:$PATH" \
    "$RIG_REPO_DIR/bin/kasbah" init-project --name=neverdeployed --domain=never.test) \
    >/dev/null 2>&1
KASBAH_CWD="$notdir" check --server "$RIG_TARGET"; rc=$?
out="$(cli_out)"
# The scaffold `init-project` writes does not satisfy every local rule, so the
# run's exit code is about those. What this case is about is the Server section:
# a project nobody has deployed must produce no failure there.
srv_section="$(sed -n '/^Server (/,$p' <<<"$out")"
assert '[ -n "$srv_section" ]' "the Server section ran at all (said '$out')"
assert '! grep -q "✗" <<<"$srv_section"' \
    "a project nobody has deployed is a warning, not a failure (server section said '$srv_section')"
assert 'grep -qF "⚠ $apps/neverdeployed does not exist on $RIG_TARGET" <<<"$out"' \
    "saying so (said '$out')"
assert '! grep -qF "has no missing keys" <<<"$out"' \
    "and nothing is claimed about a .env that cannot be there (said '$out')"

# --- Done -------------------------------------------------------------------------------
rig_clean || fail=1
exit "$fail"
