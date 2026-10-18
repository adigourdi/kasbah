#!/usr/bin/env bash
# Test: kasbah check — Structure rules (S01–S06).

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
. "$repo_dir/tests/cli.sh"
kasbah="$KASBAH_BIN"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

# Scaffold a passing project: init-project + a minimal-but-valid
# compose.prod.yml + a traefik-dynamic.yml that together satisfy every
# check group's pass path (Structure, Compose, Resources, Traefik, Env).
# The routed service joins kasbah-net explicitly and keeps an internal
# network (C03/C07); it is named for the project, because the service name
# is a DNS alias on the shared network (C09); limits reference the KASBAH_*
# vars (R01/R02); the fragment's loadBalancer targets the container_name
# (T07) and carries both routers for the domain, the redirect on `web` and
# the TLS one on `websecure` (T08). Healthchecks and Hooks sections are
# silent — manifest has no health/hooks/backup blocks, and the only service
# has no build:.
#
# Every case below starts from this, so anything it stops satisfying shows up
# as a warning in cases that are about something else entirely.
make_project() {
    local dir="$1" name="${2:-demo}" domain="${3:-demo.example.com}"
    mkdir -p "$dir"
    (cd "$dir" && "$kasbah" init-project --name="$name" --domain="$domain" >/dev/null)
    # The scaffolded template declares nothing — comment-only is the state a
    # project with no configuration ships (case 27b covers it untouched). The
    # env cases need a key to drift about, so the fixture adds one here rather
    # than each case re-deriving what the scaffold happened to seed.
    printf 'DOMAIN=%s\n' "$domain" >> "$dir/.env.prod.example"
    # Unquoted heredoc: $name interpolates, \${KASBAH_*} stays literal.
    cat > "$dir/compose.prod.yml" <<YAML
services:
  ${name}-web:
    image: nginx:alpine
    container_name: ${name}-web
    restart: unless-stopped
    cpus: \${KASBAH_CPU_LIMIT}
    mem_limit: \${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    networks: [kasbah-net, internal]

networks:
  kasbah-net:
    external: true
  internal: {}
YAML
    # printf-built so backticks in `Host(`…`)` stay literal (heredoc would
    # require '<<YAML' for $name/$domain interpolation but then evaluate the
    # backticks as command substitution).
    {
        printf 'http:\n'
        printf '  routers:\n'
        printf '    %s-http:\n' "$name"
        printf '      rule: "Host(`%s`)"\n' "$domain"
        printf '      entryPoints: [web]\n'
        printf '      middlewares: ["http-to-https@file"]\n'
        printf '      service: noop@internal\n'
        printf '    %s:\n' "$name"
        printf '      rule: "Host(`%s`)"\n' "$domain"
        printf '      entryPoints: [websecure]\n'
        printf '      tls:\n'
        printf '        certResolver: letsencrypt\n'
        printf '      service: %s\n' "$name"
        printf '  services:\n'
        printf '    %s:\n' "$name"
        printf '      loadBalancer:\n'
        printf '        servers:\n'
        printf '          - url: "http://%s-web:80"\n' "$name"
    } > "$dir/traefik-dynamic.yml"
}

# --- Case 1: golden path — everything passes, exit 0 --------------------------
proj1="$tmpdir/ok"
make_project "$proj1"
out="$(cd "$proj1" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                       "golden path exits 0 (got $rc)"
assert 'grep -qF "✓ kasbah.yml exists (schema 1)" <<<"$out"'  "S01/S02 pass line"
assert 'grep -qF "✓ compose.prod.yml exists" <<<"$out"'        "S03 pass line"
assert 'grep -qF "✓ .env.prod.example exists" <<<"$out"'       "S04 pass line"
assert 'grep -qF "✓ .gitignore excludes .env" <<<"$out"'       "S05 pass line"
assert 'grep -qF "✓ .gitignore excludes .kasbah/" <<<"$out"'  "S06 pass line"
assert 'grep -qF "✓ client is not set — backups file under the project name (demo)" <<<"$out"' "S08 pass line"
assert 'grep -qF "✓ All services set restart policy" <<<"$out"'                 "C01 pass line"
assert 'grep -qF "✓ All services set json-file logging with rotation" <<<"$out"' "C02 pass line"
assert 'grep -qF "✓ All routed services join kasbah-net" <<<"$out"'            "C03 pass line"
assert 'grep -qF "✓ kasbah-net declared external" <<<"$out"'                   "C04 pass line"
assert 'grep -qF "✓ No internal services on kasbah-net" <<<"$out"'             "C07 pass line"
assert 'grep -qF "✓ kasbah-net service names are project-prefixed" <<<"$out"'  "C09 pass line"
assert 'grep -qF "✓ No deprecated '"'"'version:'"'"' field" <<<"$out"'          "C05 pass line"
assert 'grep -qF "✓ All services set cpus/mem_limit via KASBAH_* vars" <<<"$out"'  "R01/R02 pass line"
assert 'grep -qF "✓ No resource reservations" <<<"$out"'                            "R03 pass line"
assert 'grep -qF "✓ compose.prod.yml has no traefik.* labels" <<<"$out"'                       "T06 pass line"
assert 'grep -qF "✓ traefik-dynamic.yml exists" <<<"$out"'                                     "T01 pass line"
assert 'grep -qF "✓ At least one router references manifest domain (demo.example.com)" <<<"$out"' "T02 pass line"
assert 'grep -qF "✓ All routers declare entryPoints" <<<"$out"'                                "T03 pass line"
assert 'grep -qF "✓ Secure routers reference letsencrypt cert resolver" <<<"$out"'             "T04 pass line"
assert 'grep -qF "✓ A router serves demo.example.com on the web entrypoint" <<<"$out"'         "T08 pass line"
assert 'grep -qF "✓ No router claims reserved hostnames" <<<"$out"'                            "T05 pass line"
assert 'grep -qF "✓ Fragment loadBalancer URLs target explicit container_names" <<<"$out"'     "T07 pass line"
assert 'grep -qF "✓ .env.prod.example syntax is valid" <<<"$out"'                              "E01 pass line"
assert 'grep -qF "✓ .env.prod.example has no obvious long secrets" <<<"$out"'                  "E04 pass line"
assert 'grep -qF "✓ .env.prod.example leaves the KASBAH_* prefix to kasbah" <<<"$out"'       "E05 pass line"
assert '! grep -q "Healthchecks:" <<<"$out"'  "Healthchecks: header suppressed (nothing to check)"
assert '! grep -q "Hooks:" <<<"$out"'         "Hooks: header suppressed (no hooks/backup in manifest)"
assert '! grep -qF "built services" <<<"$out"' \
    "C08 says nothing about a project that builds nothing — there is no :current to move"
assert 'grep -qF "26 passed, 0 warning, 0 failed" <<<"$out"'   "summary all pass"

# --- Case 2: missing compose.prod.yml — fail, exit 6 -------------------------
# Exit 6 is the documented "compliance check failed" code (docs/cli.md).
proj2="$tmpdir/no-compose"
make_project "$proj2"
rm "$proj2/compose.prod.yml"
out="$(cd "$proj2" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                "missing compose exits 6 (got $rc)"
assert 'grep -qF "✗ compose.prod.yml missing" <<<"$out"' "S03 fail line"
assert 'grep -qF "1 failed" <<<"$out"'                  "summary reports 1 failed"

# --- Case 3: missing .env.prod.example — fail, exit 6 ------------------------
proj3="$tmpdir/no-env"
make_project "$proj3"
rm "$proj3/.env.prod.example"
out="$(cd "$proj3" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                  "missing env example exits 6 (got $rc)"
assert 'grep -qF "✗ .env.prod.example missing" <<<"$out"' "S04 fail line"

# --- Case 4: missing .gitignore — warn for both S05 & S06, exit 0 ------------
proj4="$tmpdir/no-gitignore"
make_project "$proj4"
rm "$proj4/.gitignore"
out="$(cd "$proj4" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                                   "warnings only still exits 0 (got $rc)"
assert 'grep -qF "⚠ .gitignore does not exclude .env" <<<"$out"'           "S05 warn line"
assert 'grep -qF "⚠ .gitignore does not exclude .kasbah/" <<<"$out"'      "S06 warn line"
assert 'grep -qF "2 warning, 0 failed" <<<"$out"'                          "summary reports 2 warnings"

# --- Case 5: partial .gitignore (missing only .kasbah/) — one warn ----------
proj5="$tmpdir/partial-gitignore"
make_project "$proj5"
# Overwrite with only .env line.
printf '.env\n' > "$proj5/.gitignore"
out="$(cd "$proj5" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                              "partial gitignore exits 0"
assert 'grep -qF "✓ .gitignore excludes .env" <<<"$out"'              "S05 still passes"
assert 'grep -qF "⚠ .gitignore does not exclude .kasbah/" <<<"$out"' "S06 warns"
assert 'grep -qF "1 warning, 0 failed" <<<"$out"'                     "summary reports 1 warning"

# --- Case 6: no kasbah.yml — exit 2 (manifest_require contract) -------------
proj6="$tmpdir/no-manifest"
mkdir -p "$proj6"
out="$(cd "$proj6" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "2" ]'                          "no manifest exits 2 (got $rc)"
assert 'grep -qF "No kasbah.yml" <<<"$out"'      "no-manifest message"

# --- Case 7: future schema — exit 1 (manifest_require contract) --------------
proj7="$tmpdir/future-schema"
mkdir -p "$proj7"
cat > "$proj7/kasbah.yml" <<EOF
schema: 99
kasbah_version: 0.1.0
name: future
domain: "x.test"
sync: []
EOF
out="$(cd "$proj7" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "1" ]'                              "future schema exits 1 (got $rc)"
assert 'grep -qF "newer than this kasbah" <<<"$out"' "future schema message"

# --- Case 8: --help works without a project ----------------------------------
out="$(cd "$tmpdir" && "$kasbah" check --help 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                "check --help exits 0"
assert 'grep -qF "Usage: kasbah check" <<<"$out"'      "check --help prints usage"

# --- Case 9: unknown flag rejected -------------------------------------------
proj9="$tmpdir/unknown-flag"
make_project "$proj9"
out="$(cd "$proj9" && "$kasbah" check --bogus 2>&1)"; rc=$?
assert '[ "$rc" = "1" ]'                            "unknown flag exits 1 (got $rc)"
assert 'grep -qF "unknown argument" <<<"$out"'      "unknown flag message"
# Naming what it does take, as every other command in the CLI does — a refusal
# that only says "no" leaves the operator guessing at a typo.
assert 'grep -qF -- "--server [USER@HOST], --fix, --yes" <<<"$out"' \
    "and it lists the flags check has (said '$out')"
assert '! grep -qF "Summary:" <<<"$out"' \
    "with no report behind it, so a typo cannot read as a clean project (said '$out')"

# --- Case 9b: S08 — `client:` outside name's charset, and the reserved names --
#
# `client:` names the backup repository this project's snapshots file into
# (08-keep.md D12). `deploy` and `rollback` both refuse a value that is not a
# repository name, so a project whose only fault is this one was reported fully
# compliant at exit 0 and then died at the deploy — which is the inversion
# lib/manifest.sh's own note about `name` exists to prevent.
proj9b="$tmpdir/bad-client"
make_project "$proj9b"
printf 'client: Acme Corp\n' >> "$proj9b/kasbah.yml"
out="$(cd "$proj9b" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]' "S08: a client: outside the charset fails the check (got $rc)"
assert 'grep -qF "✗ kasbah.yml: client '"'"'Acme Corp'"'"' must match" <<<"$out"' \
    "naming the value and the rule (said '$out')"
# The deploy refuses it in the same words, out of the same
# `manifest_client_check` — pinned in tests/rollback_test.sh, which has the git
# fixture a deploy needs before it reaches this field.

# A name kasbah owns under <apps> is the sharper half: `mail` is the repository
# every mailbox on the server files into (D7), so a project claiming it would
# put the whole host's mail into one client's handover.
proj9c="$tmpdir/reserved-client"
make_project "$proj9c"
printf 'client: mail\n' >> "$proj9c/kasbah.yml"
out="$(cd "$proj9c" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]' "S08: a client: naming a kasbah directory fails too (got $rc)"
assert 'grep -qF "✗ kasbah.yml: client '"'"'mail'"'"' is reserved" <<<"$out"' \
    "and says which list it is on (said '$out')"

# The positive, so the two above are the rule and not a check that fails on any
# client: at all.
proj9d="$tmpdir/good-client"
make_project "$proj9d"
printf 'client: acme\n' >> "$proj9d/kasbah.yml"
out="$(cd "$proj9d" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]' "S08: a well-formed client: passes (got $rc: $out)"
assert 'grep -qF "✓ client '"'"'acme'"'"' names a backup repository kasbah can create" <<<"$out"' \
    "and says which repository it is (said '$out')"

# --- Case 10: --help in dispatcher lists check -------------------------------
out="$("$kasbah" --help 2>&1)"
assert 'grep -qF "check" <<<"$out"' "--help mentions check"

# --- Case 11: full report (incl. "Checking <path>" header) lands on stdout ---
# So users can `kasbah check > report.txt` without losing the header.
proj11="$tmpdir/redirect"
make_project "$proj11"
out="$(cd "$proj11" && "$kasbah" check 2>/dev/null)"; rc=$?
assert '[ "$rc" = "0" ]'                       "redirected stdout still exits 0"
assert 'grep -qF "Checking $proj11" <<<"$out"' "Checking header is on stdout (not stderr)"
assert 'grep -qF "Structure:" <<<"$out"'       "Structure header is on stdout"
assert 'grep -qF "Summary:" <<<"$out"'         "Summary line is on stdout"

# --- Case 12: CRLF .gitignore — S05/S06 still pass ---------------------------
# Windows-authored .gitignore with CRLF endings should not false-warn — same
# CR-stripping parity that lib/manifest.sh enforces for kasbah.yml.
proj12="$tmpdir/crlf-gitignore"
make_project "$proj12"
printf '.env\r\n.kasbah/\r\n' > "$proj12/.gitignore"
out="$(cd "$proj12" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                       "CRLF gitignore exits 0 (got $rc)"
assert 'grep -qF "✓ .gitignore excludes .env" <<<"$out"'       "S05 passes despite CRLF"
assert 'grep -qF "✓ .gitignore excludes .kasbah/" <<<"$out"'  "S06 passes despite CRLF"

# --- Case 13: C01 — service missing restart policy → fail, exit 6 -----------
proj13="$tmpdir/no-restart"
make_project "$proj13"
cat > "$proj13/compose.prod.yml" <<'YAML'
services:
  demo-web:
    image: nginx:alpine
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
networks:
  default:
    name: kasbah-net
    external: true
YAML
out="$(cd "$proj13" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                            "C01 fail exits 6 (got $rc)"
assert 'grep -qF "✗ Services missing restart policy: demo-web" <<<"$out"' "C01 fail line names service"

# --- Case 14: C02 — service missing logging rotation → fail, exit 6 ---------
proj14="$tmpdir/no-logging"
make_project "$proj14"
cat > "$proj14/compose.prod.yml" <<'YAML'
services:
  demo-web:
    image: nginx:alpine
    restart: unless-stopped
networks:
  default:
    name: kasbah-net
    external: true
YAML
out="$(cd "$proj14" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                                                    "C02 fail exits 6 (got $rc)"
assert 'grep -qF "✗ Services missing json-file logging with max-size/max-file: demo-web" <<<"$out"' "C02 fail line"

# --- Case 15: C03 — routed service not on kasbah-net → fail, exit 6 --------
# Fragment targets demo-web (routed), but the service joins no network.
proj15="$tmpdir/no-kasbahnet"
make_project "$proj15"
cat > "$proj15/compose.prod.yml" <<'YAML'
services:
  demo-web:
    image: nginx:alpine
    container_name: demo-web
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
YAML
out="$(cd "$proj15" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                                "C03 fail exits 6 (got $rc)"
assert 'grep -qF "✗ Routed services not on kasbah-net: demo-web" <<<"$out"' "C03 fail line"
assert 'grep -qF "✓ No internal services on kasbah-net" <<<"$out"'     "C07 still passes"

# --- Case 16: C04 — kasbah-net referenced but not external → fail, exit 6 --
proj16="$tmpdir/kasbahnet-not-external"
make_project "$proj16"
cat > "$proj16/compose.prod.yml" <<'YAML'
services:
  demo-web:
    image: nginx:alpine
    container_name: demo-web
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    networks: [kasbah-net, internal]
networks:
  kasbah-net: {}
  internal: {}
YAML
out="$(cd "$proj16" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                                  "C04 fail exits 6 (got $rc)"
assert 'grep -qF "✓ All routed services join kasbah-net" <<<"$out"'      "C03 still passes"
assert 'grep -qF "✗ kasbah-net not declared external: true" <<<"$out"'   "C04 fail line"

# --- Case 16b: C09 — a generic service name on kasbah-net → warn ------------
# The routed service is called `web`, which is what compose publishes as a DNS
# alias on the shared network — the shape measured in Phase 6 as
# `aliases=[gbrev-web web]`. Every other rule passes: it is routed, it is on
# kasbah-net, and its container_name is unique. Warn only, because nothing
# resolves that alias today.
proj16b="$tmpdir/generic-service-name"
make_project "$proj16b"
cat > "$proj16b/compose.prod.yml" <<'YAML'
services:
  web:
    image: nginx:alpine
    container_name: demo-web
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    networks: [kasbah-net, internal]
networks:
  kasbah-net:
    external: true
  internal: {}
YAML
out="$(cd "$proj16b" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                                        "C09 is a warning, so exit stays 0 (got $rc)"
assert 'grep -qF "⚠ Services on kasbah-net whose name is not '"'"'demo'"'"' or '"'"'demo-*'"'"': web" <<<"$out"' \
       "C09 warn line names the service, not the container (said '$out')"
assert 'grep -qF "✓ All routed services join kasbah-net" <<<"$out"'            "and C03 is untouched by it"
assert 'grep -qF "✓ No internal services on kasbah-net" <<<"$out"'             "as is C07"
assert 'grep -qF "25 passed, 1 warning, 0 failed" <<<"$out"'                    "one line either way (said '$(tail -1 <<<"$out")')"

# The exact project name is as acceptable as a prefixed one, and a service that
# never joins the shared network is no business of C09's — the alias only
# exists on the networks the service is actually on.
proj16c="$tmpdir/service-name-shapes"
make_project "$proj16c"
cat > "$proj16c/compose.prod.yml" <<'YAML'
services:
  demo:
    image: nginx:alpine
    container_name: demo-web
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    networks: [kasbah-net, internal]
  cache:
    image: redis:7-alpine
    container_name: demo-cache
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    networks: [internal]
networks:
  kasbah-net:
    external: true
  internal: {}
YAML
out="$(cd "$proj16c" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                                        "the bare project name and an off-net service exit 0 (got $rc)"
assert 'grep -qF "✓ kasbah-net service names are project-prefixed" <<<"$out"'  "and C09 passes (said '$out')"

# --- Case 16d: C09 says nothing when it has nothing to say ------------------
# Two silences, both deliberate and both documented in compliance.md's C09 row,
# because a rule that emits a line per project shifts the pass count between
# projects that differ in nothing it judges.
#
# First: no service on kasbah-net at all. A worker-only project joins no shared
# network, so there is no alias to collide on and nothing to pass or warn about.
proj16d="$tmpdir/nothing-on-kasbah-net"
make_project "$proj16d"
cat > "$proj16d/compose.prod.yml" <<'YAML'
services:
  demo-worker:
    image: alpine:3
    container_name: demo-worker
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    networks: [internal]
networks:
  internal: {}
YAML
rm "$proj16d/traefik-dynamic.yml"
out="$(cd "$proj16d" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                          "a project with nothing on kasbah-net exits 0 (got $rc)"
assert '! grep -qE "kasbah-net service names|whose name is not" <<<"$out"' \
       "and C09 emits no line either way — neither its pass nor its warn (said '$out')"
assert 'grep -qF "✓ No internal services on kasbah-net" <<<"$out"' \
       "while C07, which does report on the empty case, still speaks (said '$out')"

# Second: the banned default-alias shape. C07 has just failed on the shape
# itself, deliberately as a pattern rather than a per-service list; C09 naming
# every service in the file again would be shouting twice about one mistake,
# and with the wrong fix attached — renaming them all fixes nothing, removing
# the default alias fixes everything.
proj16e="$tmpdir/default-alias-shape"
make_project "$proj16e"
cat > "$proj16e/compose.prod.yml" <<'YAML'
services:
  web:
    image: nginx:alpine
    container_name: demo-web
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
  cache:
    image: redis:7-alpine
    container_name: demo-cache
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
networks:
  default:
    name: kasbah-net
    external: true
YAML
out="$(cd "$proj16e" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                                     "the default-alias shape still fails on C07 (got $rc)"
assert 'grep -qF "✗ default network aliases kasbah-net" <<<"$out"'          "C07 reports the shape (said '$out')"
assert '! grep -qE "kasbah-net service names|whose name is not" <<<"$out"' \
       "and C09 emits neither of its two lines, so it does not name the same services a second time (said '$out')"
assert '[ "$(grep -cF "Non-routed services on kasbah-net" <<<"$out")" = "0" ]' \
       "nor does C07 fall through to its per-service list (said '$out')"

# --- Case 17: C05 — top-level `version:` → warn, exit 0 ---------------------
proj17="$tmpdir/version-field"
make_project "$proj17"
cat > "$proj17/compose.prod.yml" <<'YAML'
version: "3.8"
services:
  demo-web:
    image: nginx:alpine
    container_name: demo-web
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    networks: [kasbah-net, internal]
networks:
  kasbah-net:
    external: true
  internal: {}
YAML
out="$(cd "$proj17" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                                                "C05 warn exits 0 (got $rc)"
assert 'grep -qF "⚠ compose.prod.yml uses deprecated '"'"'version:'"'"' field" <<<"$out"' "C05 warn line"

# --- Case 18: empty compose (no services) → warn, exit 0 --------------------
# Compose checks beyond C05 have nothing to bite on; emit one warn and run C05.
proj18="$tmpdir/empty-compose"
make_project "$proj18"
: > "$proj18/compose.prod.yml"
out="$(cd "$proj18" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                                                       "empty compose exits 0 (got $rc)"
assert 'grep -qF "⚠ compose.prod.yml declares no services — skipping Compose checks" <<<"$out"' "no-services warn line"
assert 'grep -qF "✓ No deprecated '"'"'version:'"'"' field" <<<"$out"'                          "C05 still runs"

# --- Case 19: T01 — traefik-dynamic.yml missing → warn, exit 0 ---------------
# Worker-only projects without web routing should not fail the whole check.
# Consistently, such a project has no business on kasbah-net (C07) — so the
# fixture keeps the service off it entirely.
proj19="$tmpdir/no-traefik-fragment"
make_project "$proj19"
rm "$proj19/traefik-dynamic.yml"
cat > "$proj19/compose.prod.yml" <<'YAML'
services:
  demo-web:
    image: nginx:alpine
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
YAML
out="$(cd "$proj19" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                                      "T01 missing exits 0 (got $rc)"
assert 'grep -qF "⚠ traefik-dynamic.yml missing" <<<"$out"'                   "T01 warn line"
assert '! grep -qF "At least one router references manifest domain" <<<"$out"' "T02 skipped when fragment missing"
assert 'grep -qF "✓ compose.prod.yml has no traefik.* labels" <<<"$out"'       "T06 still runs"

# --- Case 20: T02 — router doesn't reference manifest domain → fail ----------
proj20="$tmpdir/wrong-domain"
make_project "$proj20"
cat > "$proj20/traefik-dynamic.yml" <<'YAML'
http:
  routers:
    demo:
      rule: "Host(`other.test`)"
      entryPoints: [websecure]
      tls:
        certResolver: letsencrypt
      service: noop@internal
YAML
out="$(cd "$proj20" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                                                  "T02 fail exits 6 (got $rc)"
assert 'grep -qF "✗ No router rule references manifest domain (demo.example.com)" <<<"$out"' "T02 fail line"

# --- Case 21: T03 — router missing entryPoints → fail ------------------------
proj21="$tmpdir/no-entrypoints"
make_project "$proj21"
cat > "$proj21/traefik-dynamic.yml" <<'YAML'
http:
  routers:
    demo:
      rule: "Host(`demo.example.com`)"
      service: noop@internal
YAML
out="$(cd "$proj21" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                          "T03 fail exits 6 (got $rc)"
assert 'grep -qF "✗ Routers without entryPoints: demo" <<<"$out"' "T03 fail line"

# --- Case 22: T04 — websecure without letsencrypt → fail ---------------------
proj22="$tmpdir/no-letsencrypt"
make_project "$proj22"
cat > "$proj22/traefik-dynamic.yml" <<'YAML'
http:
  routers:
    demo:
      rule: "Host(`demo.example.com`)"
      entryPoints: [websecure]
      service: noop@internal
YAML
out="$(cd "$proj22" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                                                       "T04 fail exits 6 (got $rc)"
assert 'grep -qF "✗ Websecure routers without tls.certResolver=letsencrypt: demo" <<<"$out"'   "T04 fail line"

# --- Case 23: T05 — router claims a reserved hostname → fail ----------------
proj23="$tmpdir/reserved-host"
make_project "$proj23"
cat > "$proj23/traefik-dynamic.yml" <<'YAML'
http:
  routers:
    demo:
      rule: "Host(`demo.example.com`)"
      entryPoints: [websecure]
      tls:
        certResolver: letsencrypt
      service: noop@internal
    demo-mail:
      rule: "Host(`mail.demo.example.com`)"
      entryPoints: [websecure]
      tls:
        certResolver: letsencrypt
      service: noop@internal
YAML
out="$(cd "$proj23" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                                  "T05 fail exits 6 (got $rc)"
assert 'grep -qF "✗ Routers claim reserved hostnames" <<<"$out"'          "T05 fail line"
assert 'grep -qF "demo-mail" <<<"$out"'                                   "T05 names offending router"

# --- Case 23b: T08 — HTTPS router only, nothing on `web` → warn -------------
# The fragment every rule but this one accepts while the site 404s on plain
# HTTP. T03 is satisfied (the router declares an entrypoint) and so is T04, so
# T08 is the only thing between a project and a hostname that works in a
# browser's address bar exactly once the user types the scheme.
proj23b="$tmpdir/no-http-router"
make_project "$proj23b"
cat > "$proj23b/traefik-dynamic.yml" <<'YAML'
http:
  routers:
    demo:
      rule: "Host(`demo.example.com`)"
      entryPoints: [websecure]
      tls:
        certResolver: letsencrypt
      service: demo
  services:
    demo:
      loadBalancer:
        servers:
          - url: "http://demo-web:80"
YAML
out="$(cd "$proj23b" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                                           "T08 is a warning, so exit stays 0 (got $rc)"
assert 'grep -qF "⚠ No router serves demo.example.com on the web entrypoint" <<<"$out"' \
       "T08 warn line (said '$out')"
assert 'grep -qF "http-to-https@file" <<<"$out"'                                   "and says what to add (said '$out')"
assert 'grep -qF "✓ All routers declare entryPoints" <<<"$out"'                   "T03 passes on the same fragment — it is not the rule that catches this"
assert 'grep -qF "25 passed, 1 warning, 0 failed" <<<"$out"'                       "one line either way (said '$(tail -1 <<<"$out")')"

# A `web` router for an unrelated host does not answer for this one: the
# entrypoint has to be declared by a router whose rule mentions the manifest
# domain, and `www.example.net` shares no text with `demo.example.com`.
cat > "$proj23b/traefik-dynamic.yml" <<'YAML'
http:
  routers:
    demo-www:
      rule: "Host(`www.example.net`)"
      entryPoints: [web]
      middlewares: ["http-to-https@file"]
      service: noop@internal
    demo:
      rule: "Host(`demo.example.com`)"
      entryPoints: [websecure]
      tls:
        certResolver: letsencrypt
      service: demo
  services:
    demo:
      loadBalancer:
        servers:
          - url: "http://demo-web:80"
YAML
out="$(cd "$proj23b" && "$kasbah" check 2>&1)"; rc=$?
assert 'grep -qF "⚠ No router serves demo.example.com on the web entrypoint" <<<"$out"' \
       "a web router for another host is not this host's redirect (said '$out')"

# The other side of that line, and the reason it is a line rather than an exact
# match: `www.demo.example.com` *contains* the manifest domain, so T08 counts
# it — deliberately, because T08 matches routers to the domain exactly the way
# T02 does, and T02 would already be passing on a fragment like this one. The
# substring rule is what makes both tolerant of Host()/HostRegexp/HostHeader
# without parsing any of them; a www redirect that also carries the apex is the
# common shape it is tolerant *for*. Pinned so the two rules cannot drift apart
# without a test saying so.
cat > "$proj23b/traefik-dynamic.yml" <<'YAML'
http:
  routers:
    demo-www:
      rule: "Host(`www.demo.example.com`)"
      entryPoints: [web]
      middlewares: ["http-to-https@file"]
      service: noop@internal
    demo:
      rule: "Host(`demo.example.com`)"
      entryPoints: [websecure]
      tls:
        certResolver: letsencrypt
      service: demo
  services:
    demo:
      loadBalancer:
        servers:
          - url: "http://demo-web:80"
YAML
out="$(cd "$proj23b" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                                                "the substring-positive fragment exits 0 (got $rc)"
assert 'grep -qF "✓ A router serves demo.example.com on the web entrypoint" <<<"$out"' \
       "a web router whose host contains the manifest domain satisfies T08 (said '$out')"
assert 'grep -qF "✓ At least one router references manifest domain (demo.example.com)" <<<"$out"' \
       "on the same reading T02 already gives it (said '$out')"
assert 'grep -qF "26 passed, 0 warning, 0 failed" <<<"$out"'                             "and nothing warns (said '$(tail -1 <<<"$out")')"

# --- Case 24: T06 — service carries traefik.* label → fail ------------------
proj24="$tmpdir/traefik-label"
make_project "$proj24"
cat > "$proj24/compose.prod.yml" <<'YAML'
services:
  demo-web:
    image: nginx:alpine
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.app.rule=Host(`demo.example.com`)"
networks:
  default:
    name: kasbah-net
    external: true
YAML
out="$(cd "$proj24" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                                                  "T06 fail exits 6 (got $rc)"
assert 'grep -qF "✗ Services carry traefik.* labels (file provider only): demo-web" <<<"$out"' "T06 fail line"

# --- Case 25: H01 — built service without compose healthcheck → warn --------
proj25="$tmpdir/built-no-hc"
make_project "$proj25"
mkdir -p "$proj25/api"
: > "$proj25/api/Dockerfile"
cat > "$proj25/compose.prod.yml" <<'YAML'
services:
  api:
    build: ./api
    # C08: a built service's image: is what deploy retags :current.
    image: demo-web:current
    container_name: demo-web
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    networks: [kasbah-net, internal]
networks:
  kasbah-net:
    external: true
  internal: {}
YAML
out="$(cd "$proj25" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                                                                          "H01 warn exits 0 (got $rc)"
assert 'grep -qF "Healthchecks:" <<<"$out"'                                                                       "Healthchecks: header appears"
assert 'grep -qF "⚠ Built services without a compose healthcheck (Dockerfile may declare one): api" <<<"$out"'    "H01 warn line"
assert 'grep -qF "✓ All built services reference their image as :current" <<<"$out"' \
    "C08 pass line — this service's image: is demo-web:current"

# --- Case 25b: C08 — a built service pinned to a version tag → fail ---------
# The carried finding this rule closes. `build-push` strips whatever tag the
# compose file carries and tags `<image>:<version>`; `deploy` then moves
# `<image>:current`. A service that names a pinned tag therefore keeps running
# the old image while the deploy reports success and changes nothing
# (docs/build-deploy.md → image tags on the VPS).
proj25b="$tmpdir/c08-pinned"
make_project "$proj25b"
mkdir -p "$proj25b/api"
: > "$proj25b/api/Dockerfile"
cat > "$proj25b/compose.prod.yml" <<'YAML'
services:
  api:
    build: ./api
    image: demo-web:1.2.3
    container_name: demo-web
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    networks: [kasbah-net, internal]
networks:
  kasbah-net:
    external: true
  internal: {}
YAML
out="$(cd "$proj25b" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]' "C08 fail exits 6 (got $rc)"
assert 'grep -qF "✗ Built services whose image: is not tagged :current: api (demo-web:1.2.3)" <<<"$out"' \
    "C08 fail line names the service and the tag it is pinned to
        said: $(grep "image:" <<<"$out")"

# --- Case 25c: C08 — a built service that names no image at all → fail ------
proj25c="$tmpdir/c08-noimage"
make_project "$proj25c"
mkdir -p "$proj25c/api"
: > "$proj25c/api/Dockerfile"
cat > "$proj25c/compose.prod.yml" <<'YAML'
services:
  api:
    build: ./api
    container_name: demo-web
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    networks: [kasbah-net, internal]
networks:
  kasbah-net:
    external: true
  internal: {}
YAML
out="$(cd "$proj25c" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]' "a built service with no image: exits 6 (got $rc)"
assert 'grep -qF "✗ Built services whose image: is not tagged :current: api (no image:)" <<<"$out"' \
    "and C08 says so rather than reporting a tag it never saw
        said: $(grep "image:" <<<"$out")"

# --- Case 25e: C08 — `current` inside the tag is not the tag ----------------
# A substring match would pass `demo-web:current-rc1`, which build-push tags
# `demo-web:<version>` and deploy never points at.
proj25e="$tmpdir/c08-current-substring"
make_project "$proj25e"
mkdir -p "$proj25e/api"
: > "$proj25e/api/Dockerfile"
cat > "$proj25e/compose.prod.yml" <<'YAML'
services:
  api:
    build: ./api
    image: demo-web:current-rc1
    container_name: demo-web
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    networks: [kasbah-net, internal]
networks:
  kasbah-net:
    external: true
  internal: {}
YAML
out="$(cd "$proj25e" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]' "a tag that merely contains 'current' still fails C08 (got $rc)"
assert 'grep -qF "✗ Built services whose image: is not tagged :current: api (demo-web:current-rc1)" <<<"$out"' \
    "quoting the tag it found (said: $(grep "image:" <<<"$out"))"

# --- Case 25d: C08 — a registry with a port is not a tag ---------------------
# `reg.example:5000/demo-web:current` has two colons and only the last one is
# the tag. C08 matches the tag as a suffix, so the port cannot be mistaken for
# one — this case is what says so out loud.
proj25d="$tmpdir/c08-registry-port"
make_project "$proj25d"
mkdir -p "$proj25d/api"
: > "$proj25d/api/Dockerfile"
cat > "$proj25d/compose.prod.yml" <<'YAML'
services:
  api:
    build: ./api
    image: reg.example:5000/demo-web:current
    container_name: demo-web
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    networks: [kasbah-net, internal]
networks:
  kasbah-net:
    external: true
  internal: {}
YAML
out="$(cd "$proj25d" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]' "a registry-with-a-port image tagged :current passes (got $rc)"
assert 'grep -qF "✓ All built services reference their image as :current" <<<"$out"' \
    "with C08's pass line (said: $(grep "current" <<<"$out"))"

# --- Case 26: H02 — manifest health.container not in compose → fail ---------
proj26="$tmpdir/bad-health-container"
make_project "$proj26"
# Append a `health:` block to the manifest.
cat >> "$proj26/kasbah.yml" <<'YAML'

health:
  container: nonexistent-container
  timeout: 60s
YAML
out="$(cd "$proj26" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                                                                                  "H02 fail exits 6 (got $rc)"
assert 'grep -qF "✗ manifest health.container '"'"'nonexistent-container'"'"' not found among compose container_names" <<<"$out"' "H02 fail line"

# --- Case 26b: H02 — a health: block with only a timeout is legal -----------
# docs/project-manifest.md says health: defaults to waiting on every service
# with a compose healthcheck. Failing a block that names no container made that
# default's timeout unreachable — `kasbah deploy` refused it too.
proj26b="$tmpdir/health-timeout-only"
make_project "$proj26b"
cat >> "$proj26b/kasbah.yml" <<'YAML'

health:
  timeout: 300s
YAML
out="$(cd "$proj26b" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]' "a health: block with only a timeout passes (got $rc)"
assert 'grep -qF "✓ manifest health: names no container — the deploy waits on every container with a healthcheck" <<<"$out"' \
    "and H02 says which path that is (said: $(grep -i health <<<"$out"))"

# --- Case 27: H02 pass — health.container matches a compose container_name --
proj27="$tmpdir/good-health-container"
make_project "$proj27"
cat > "$proj27/compose.prod.yml" <<'YAML'
services:
  demo-web:
    image: nginx:alpine
    container_name: demo-web
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    networks: [kasbah-net, internal]
networks:
  kasbah-net:
    external: true
  internal: {}
YAML
cat >> "$proj27/kasbah.yml" <<'YAML'

health:
  container: demo-web
  timeout: 60s
YAML
out="$(cd "$proj27" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                                                       "H02 pass exits 0 (got $rc)"
assert 'grep -qF "✓ manifest health.container '"'"'demo-web'"'"' exists in compose" <<<"$out"' "H02 pass line"

# --- Case 27b: a template that declares nothing is a passing project ---------
# The scaffold writes comments and no keys, because the hostname lives in the
# manifest and the fragment and a project with nothing to configure has nothing
# to seed. S04 still requires the file; E01, E04 and E05 all pass on it, since
# env_extract_keys yields nothing from comments. Asserted here rather than in
# init_project_test.sh because "empty is first-class" is a claim about the
# rules, not about the writer.
proj27b="$tmpdir/env-declares-nothing"
make_project "$proj27b"
# Back to exactly what init-project wrote, before the fixture's own DOMAIN line.
sed -i '/^DOMAIN=/d' "$proj27b/.env.prod.example"
out="$(cd "$proj27b" && "$kasbah" check 2>&1)"; rc=$?
assert '! grep -qE "^[[:space:]]*[^#[:space:]]" "$proj27b/.env.prod.example"' \
       "the scaffolded template has no line that is not a comment (said: $(cat "$proj27b/.env.prod.example"))"
assert '[ "$rc" = "0" ]'                                                       "a project whose template declares nothing exits 0 (got $rc)"
assert 'grep -qF "✓ .env.prod.example exists" <<<"$out"'                       "S04 still passes on it"
assert 'grep -qF "✓ .env.prod.example syntax is valid" <<<"$out"'              "E01 passes on comments alone"
assert 'grep -qF "✓ .env.prod.example has no obvious long secrets" <<<"$out"'  "E04 has nothing to measure"
assert 'grep -qF "✓ .env.prod.example leaves the KASBAH_* prefix to kasbah" <<<"$out"' "E05 has no key to object to"
assert 'grep -qF "26 passed, 0 warning, 0 failed" <<<"$out"'                   "and nothing warns about it (said '$(tail -1 <<<"$out")')"

# --- Case 28: E01 — invalid line → fail --------------------------------------
proj28="$tmpdir/env-bad-syntax"
make_project "$proj28"
# Inject a garbage line that's neither a comment, blank, nor NAME=value.
printf 'this is not valid env syntax\n' >> "$proj28/.env.prod.example"
out="$(cd "$proj28" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                                            "E01 fail exits 6 (got $rc)"
assert 'grep -qF "✗ .env.prod.example has invalid lines" <<<"$out"'                 "E01 fail line"

# --- Case 28b: the four env rules read a line the way Compose does -----------
# lib/env.sh sees leading blanks and an `export ` prefix as an assignment
# (ENV_ASSIGN_RE), and every rule here shares that reader: E01 must not call
# valid lines invalid, and E02–E05 must see the keys behind the prefix. All
# four in one run, so a rule that quietly fell back to the anchored shape shows
# up as its own failed assertion.
proj28b="$tmpdir/env-export-shapes"
make_project "$proj28b"
{
    printf 'export EXPORTED=1\n'
    printf '  INDENTED=2\n'
    printf '\tTABBED=3\n'
    printf 'export KASBAH_CPU_LIMIT=0\n'
    printf 'export API_TOKEN=%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
} >> "$proj28b/.env.prod.example"
cat > "$proj28b/.env" <<'ENV'
DOMAIN=demo.example.com
export EXPORTED=x
  INDENTED=y
	TABBED=z
export API_TOKEN=short
ENV
out="$(cd "$proj28b" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                                     "an exported or indented template line is not an E01 failure (got $rc)"
assert 'grep -qF "✓ .env.prod.example syntax is valid" <<<"$out"'            "E01 accepts what setup-env.sh accepts (said '$out')"
assert 'grep -qF "✓ .env has no missing keys vs .env.prod.example" <<<"$out"' "E02 reads the key behind an export/indent in .env"
assert 'grep -qF "✓ .env has no extra keys vs .env.prod.example" <<<"$out"'   "and E03 reads it in the template too"
assert 'grep -qF "⚠ .env.prod.example defines reserved KASBAH_* keys (kasbah injects these): KASBAH_CPU_LIMIT" <<<"$out"' \
       "E05 sees an exported reserved key (said '$out')"
assert 'grep -qF "⚠ .env.prod.example has values >64 chars (possibly leaked secrets): API_TOKEN" <<<"$out"' \
       "E04 measures the value of an exported assignment (said '$out')"

# The widening is not "anything goes": `export` still has to be followed by a
# name, and a name still has to be one word.
proj28c="$tmpdir/env-export-bad"
make_project "$proj28c"
printf 'export FOO BAR=baz\nexport =1\n' >> "$proj28c/.env.prod.example"
out="$(cd "$proj28c" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                            "a malformed export line still fails E01 (got $rc)"
assert 'grep -qF "✗ .env.prod.example has invalid lines" <<<"$out"' "and is named as invalid (said '$out')"

# --- Case 29: E02 — .env missing a key from .env.prod.example → warn --------
proj29="$tmpdir/env-missing-key"
make_project "$proj29"
# .env.prod.example has DOMAIN. .env has nothing.
: > "$proj29/.env"
out="$(cd "$proj29" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                                  "E02 warn exits 0 (got $rc)"
assert 'grep -qF "⚠ .env missing keys vs .env.prod.example: DOMAIN" <<<"$out"'  "E02 warn line"

# --- Case 30: E03 — .env has an extra key not in template → warn ------------
proj30="$tmpdir/env-extra-key"
make_project "$proj30"
cat > "$proj30/.env" <<'ENV'
DOMAIN=demo.example.com
EXTRA_VAR=oops
ENV
out="$(cd "$proj30" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                                              "E03 warn exits 0 (got $rc)"
assert 'grep -qF "⚠ .env has extra keys not in .env.prod.example: EXTRA_VAR" <<<"$out"' "E03 warn line"

# --- Case 30b: the KASBAH_ prefix is invisible to E02/E03 in both directions -
# Extra in .env is the injected block kasbah itself writes; missing from .env
# is the same key sitting in the template. Neither is drift, and the drift
# messages must not name them either.
proj30b="$tmpdir/env-reserved-extra"
make_project "$proj30b"
cat > "$proj30b/.env" <<'ENV'
DOMAIN=demo.example.com
KASBAH_CPU_LIMIT=14.4
KASBAH_MEM_LIMIT=54g
ENV
out="$(cd "$proj30b" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                                     "reserved keys in .env exit 0 (got $rc)"
assert 'grep -qF "✓ .env has no extra keys vs .env.prod.example" <<<"$out"'  "an extra KASBAH_ key is not E03 drift"
assert 'grep -qF "✓ .env has no missing keys vs .env.prod.example" <<<"$out"' "and leaves E02 passing"

proj30c="$tmpdir/env-reserved-missing"
make_project "$proj30c"
printf 'KASBAH_MEM_LIMIT=54g\n' >> "$proj30c/.env.prod.example"
cat > "$proj30c/.env" <<'ENV'
DOMAIN=demo.example.com
ENV
out="$(cd "$proj30c" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                                      "a reserved key only in the template exits 0 (got $rc)"
assert 'grep -qF "✓ .env has no missing keys vs .env.prod.example" <<<"$out"' "a KASBAH_ key absent from .env is not E02 drift"

# Real drift in both directions still reports, with the reserved keys filtered
# out of the message — the half that a blanket "skip the whole check" would
# also pass.
proj30d="$tmpdir/env-reserved-and-real"
make_project "$proj30d"
printf 'REAL_MISSING=x\nKASBAH_MEM_LIMIT=54g\n' >> "$proj30d/.env.prod.example"
cat > "$proj30d/.env" <<'ENV'
DOMAIN=demo.example.com
REAL_EXTRA=y
KASBAH_CPU_LIMIT=14.4
ENV
out="$(cd "$proj30d" && "$kasbah" check 2>&1)"; rc=$?
assert 'grep -qF "⚠ .env missing keys vs .env.prod.example: REAL_MISSING" <<<"$out"' \
       "real missing keys are still reported (said '$out')"
assert 'grep -qF "⚠ .env has extra keys not in .env.prod.example: REAL_EXTRA" <<<"$out"' \
       "real extra keys are still reported (said '$out')"
drift_lines="$(grep -F "vs .env.prod.example" <<<"$out")"
assert '! grep -qF "KASBAH_" <<<"$drift_lines"' \
       "no reserved key is named in either drift message (said '$drift_lines')"

# --- Case 30e: E05 — a reserved key in the template → warn -------------------
# Two of them: the message names every offender, not the first.
proj30e="$tmpdir/env-reserved-template"
make_project "$proj30e"
printf 'KASBAH_CPU_LIMIT=0\nKASBAH_MEM_LIMIT=0\n' >> "$proj30e/.env.prod.example"
out="$(cd "$proj30e" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                                     "E05 is a warning, so exit stays 0 (got $rc)"
assert 'grep -qF "⚠ .env.prod.example defines reserved KASBAH_* keys (kasbah injects these): KASBAH_CPU_LIMIT KASBAH_MEM_LIMIT" <<<"$out"' \
       "E05 warn line names every reserved key, not just the first (said '$out')"
assert 'grep -qF "25 passed, 1 warning, 0 failed" <<<"$out"'                 "E05 warns instead of passing, one line either way (said '$out')"

# The prefix is matched anchored: MY_KASBAH_URL is the user's key. A substring
# match here would warn about a key kasbah neither injects nor skips.
proj30f="$tmpdir/env-reserved-substring"
make_project "$proj30f"
printf 'MY_KASBAH_URL=https://example.com\n' >> "$proj30f/.env.prod.example"
out="$(cd "$proj30f" && "$kasbah" check 2>&1)"; rc=$?
assert 'grep -qF "✓ .env.prod.example leaves the KASBAH_* prefix to kasbah" <<<"$out"' \
       "a key merely containing KASBAH_ is not E05 (said '$out')"

# --- Case 31: E04 — long literal value in template → warn -------------------
proj31="$tmpdir/env-long-secret"
make_project "$proj31"
# 80-char hex-ish value, not a `!`-generator, not a hint.
printf 'API_TOKEN=%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" >> "$proj31/.env.prod.example"
out="$(cd "$proj31" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                                                          "E04 warn exits 0 (got $rc)"
assert 'grep -qF "⚠ .env.prod.example has values >64 chars (possibly leaked secrets): API_TOKEN" <<<"$out"' "E04 warn line"

# --- Case 32: HK01 — hook references unknown container → fail ----------------
proj32="$tmpdir/hk01-unknown"
make_project "$proj32"
cat > "$proj32/compose.prod.yml" <<'YAML'
services:
  demo-web:
    image: nginx:alpine
    container_name: demo-web
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
networks:
  default:
    name: kasbah-net
    external: true
YAML
cat >> "$proj32/kasbah.yml" <<'YAML'

hooks:
  post-deploy:
    - ghost-container echo hi
YAML
out="$(cd "$proj32" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                                              "HK01 fail exits 6 (got $rc)"
assert 'grep -qF "✗ Hooks reference unknown container_names: ghost-container" <<<"$out"' "HK01 fail line"

# --- Case 33: HK02 — backup missing required field → fail --------------------
proj33="$tmpdir/hk02-missing-field"
make_project "$proj33"
cat > "$proj33/compose.prod.yml" <<'YAML'
services:
  db:
    image: postgres:16
    container_name: demo-db
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
networks:
  default:
    name: kasbah-net
    external: true
YAML
cat >> "$proj33/kasbah.yml" <<'YAML'

backup:
  container: demo-db
  check: "true"
  command: "pg_dump -U u d"
  # extension intentionally omitted
YAML
out="$(cd "$proj33" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                                            "HK02 fail exits 6 (got $rc)"
assert 'grep -qF "✗ Backup hook missing required field(s): extension" <<<"$out"'   "HK02 fail line"

# --- Case 34: HK03 — backup container not in compose → fail ------------------
proj34="$tmpdir/hk03-bad-container"
make_project "$proj34"
cat > "$proj34/compose.prod.yml" <<'YAML'
services:
  db:
    image: postgres:16
    container_name: demo-db
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
networks:
  default:
    name: kasbah-net
    external: true
YAML
cat >> "$proj34/kasbah.yml" <<'YAML'

backup:
  container: not-in-compose
  check: "true"
  command: "pg_dump -U u d"
  extension: sql.gz
YAML
out="$(cd "$proj34" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                                                                            "HK03 fail exits 6 (got $rc)"
assert 'grep -qF "✗ Backup hook container '"'"'not-in-compose'"'"' not found among compose container_names" <<<"$out"' "HK03 fail line"

# --- Case 35: HK01–03 — full valid hooks + backup → pass --------------------
# Regression guard for the .hooks/.value[]? extraction and the container_name
# set assembly. If the yq stage names get refactored this should catch it.
proj35="$tmpdir/hk-all-pass"
make_project "$proj35"
cat > "$proj35/compose.prod.yml" <<'YAML'
services:
  api:
    image: nginx:alpine
    container_name: demo-api
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    networks: [kasbah-net, internal]
  db:
    image: postgres:16
    container_name: demo-db
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    networks: [internal]
networks:
  kasbah-net:
    external: true
  internal: {}
YAML
# Fragment must target the api container (the fixture routes demo-api, not
# make_project's default demo-web).
{
    printf 'http:\n'
    printf '  routers:\n'
    printf '    demo:\n'
    printf '      rule: "Host(`demo.example.com`)"\n'
    printf '      entryPoints: [websecure]\n'
    printf '      tls:\n'
    printf '        certResolver: letsencrypt\n'
    printf '      service: demo\n'
    printf '  services:\n'
    printf '    demo:\n'
    printf '      loadBalancer:\n'
    printf '        servers:\n'
    printf '          - url: "http://demo-api:80"\n'
} > "$proj35/traefik-dynamic.yml"
cat >> "$proj35/kasbah.yml" <<'YAML'

hooks:
  pre-deploy:
    - demo-api echo before
  post-deploy:
    - demo-api echo after
  pre-rollback:
    - demo-api echo rollback-before
  post-rollback:
    - demo-api echo rollback-after

backup:
  container: demo-db
  check: "true"
  command: "pg_dump -U u d"
  extension: sql.gz
YAML
out="$(cd "$proj35" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                                       "HK pass exits 0 (got $rc)"
assert 'grep -qF "✓ All hook commands target known container_names" <<<"$out"' "HK01 pass line"
assert 'grep -qF "✓ Backup hook has check, command, and extension" <<<"$out"'  "HK02 pass line"
assert 'grep -qF "✓ Backup hook container '"'"'demo-db'"'"' exists in compose" <<<"$out"' "HK03 pass line"

# --- Case 36: T01 — malformed traefik-dynamic.yml → warn, exit 0 ------------
# T01 was downgraded to warn (worker-only projects). A malformed file is the
# same user-facing condition as a missing one — should not fail the check.
proj36="$tmpdir/traefik-malformed"
make_project "$proj36"
printf 'http:\n  routers:\n    bad: [ this is\n      not yaml\n' > "$proj36/traefik-dynamic.yml"
# With no parseable fragment there are no routed services, so the fixture's
# service must stay off kasbah-net (C07) for the warn-only outcome to hold.
cat > "$proj36/compose.prod.yml" <<'YAML'
services:
  demo-web:
    image: nginx:alpine
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
YAML
out="$(cd "$proj36" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                                        "T01 malformed exits 0 (got $rc)"
assert 'grep -qF "⚠ traefik-dynamic.yml does not parse as YAML" <<<"$out"'      "T01 malformed warn line"
assert '! grep -qF "At least one router references manifest domain" <<<"$out"'  "T02 skipped on parse failure"

# --- Case 37: empty manifest domain → T02 skipped with a warn, exit 0 -------
# init-project allows an empty domain. The Traefik check should warn and skip
# T02 rather than failing on an empty needle.
proj37="$tmpdir/empty-domain"
mkdir -p "$proj37"
(cd "$proj37" && "$kasbah" init-project --name=demo >/dev/null 2>&1)
cat > "$proj37/compose.prod.yml" <<'YAML'
services:
  demo-web:
    image: nginx:alpine
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
YAML
{ printf 'http:\n  routers:\n    demo:\n      rule: "Host(`x.test`)"\n      entryPoints: [websecure]\n      tls:\n        certResolver: letsencrypt\n      service: noop@internal\n'; } > "$proj37/traefik-dynamic.yml"
out="$(cd "$proj37" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                                              "empty-domain T02 skip exits 0 (got $rc)"
assert 'grep -qF "⚠ manifest domain is empty — skipping T02" <<<"$out"'               "empty-domain warn line"
assert '! grep -qF "At least one router references manifest domain" <<<"$out"'        "T02 not run on empty domain"
assert 'grep -qF "✓ All routers declare entryPoints" <<<"$out"'                       "T03 still runs on empty domain"

# --- Case 38: C07 — non-routed service on kasbah-net → fail ----------------
proj38="$tmpdir/c07-internal-on-shared"
make_project "$proj38"
cat > "$proj38/compose.prod.yml" <<'YAML'
services:
  demo-web:
    image: nginx:alpine
    container_name: demo-web
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    networks: [kasbah-net, internal]
  db:
    image: postgres:16
    container_name: demo-db
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    networks: [kasbah-net, internal]
networks:
  kasbah-net:
    external: true
  internal: {}
YAML
out="$(cd "$proj38" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                              "C07 fail exits 6 (got $rc)"
assert 'grep -qF "✗ Non-routed services on kasbah-net: db" <<<"$out"' "C07 fail line names db"
assert 'grep -qF "✓ All routed services join kasbah-net" <<<"$out"'   "C03 still passes"

# --- Case 39: C07 — default network aliasing kasbah-net is banned ----------
proj39="$tmpdir/c07-default-alias"
make_project "$proj39"
cat > "$proj39/compose.prod.yml" <<'YAML'
services:
  demo-web:
    image: nginx:alpine
    container_name: demo-web
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
networks:
  default:
    name: kasbah-net
    external: true
YAML
out="$(cd "$proj39" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                                    "default-alias exits 6 (got $rc)"
assert 'grep -qF "✗ default network aliases kasbah-net" <<<"$out"'         "C07 default-alias fail line"

# --- Case 40: R01/R02 literal limits + R03 reservations → fail --------------
proj40="$tmpdir/r-rules"
make_project "$proj40"
cat > "$proj40/compose.prod.yml" <<'YAML'
services:
  demo-web:
    image: nginx:alpine
    container_name: demo-web
    restart: unless-stopped
    cpus: "1.5"
    mem_limit: ${KASBAH_MEM_LIMIT}
    mem_reservation: 512m
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    networks: [kasbah-net, internal]
networks:
  kasbah-net:
    external: true
  internal: {}
YAML
out="$(cd "$proj40" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                                                  "R rules fail exits 6 (got $rc)"
assert 'grep -qF "✗ Services with missing or literal resource limits: demo-web(cpus)" <<<"$out"' "R01 fail line (literal cpus)"
assert 'grep -qF "✗ Services declare resource reservations: demo-web" <<<"$out"'                "R03 fail line"

# --- Case 41: T07 — fragment targets a hostname with no container_name ------
proj41="$tmpdir/t07-unknown-target"
make_project "$proj41"
# Compose renames the container; the make_project fragment still targets
# demo-web. The routed set is now empty, so C03/C07 stay quiet — T07 is the
# rule that catches the dangling reference.
cat > "$proj41/compose.prod.yml" <<'YAML'
services:
  demo-web:
    image: nginx:alpine
    container_name: demo-renamed
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
YAML
out="$(cd "$proj41" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                                       "T07 fail exits 6 (got $rc)"
assert 'grep -qF "✗ Fragment targets unknown container_names: demo-web" <<<"$out"' "T07 fail line"

# --- Case 42: a name kasbah owns on the server -------------------------------
# The project should learn this from `check`, not from the deploy that rsyncs
# over the shared Traefik stack and then removes it as an orphan. It is a
# manifest rule, so it arrives the same way a bad schema does: manifest_require
# refuses and the report short-circuits.
for reserved in traefik mail data backups; do
    proj42="$tmpdir/reserved-$reserved"
    mkdir -p "$proj42"
    cat > "$proj42/kasbah.yml" <<EOF
schema: 1
kasbah_version: 0.1.0
name: $reserved
domain: "x.test"
sync: []
EOF
    out="$(cd "$proj42" && "$kasbah" check 2>&1)"; rc=$?
    # 1, not 6: a reserved name is a manifest-load refusal that short-circuits
    # before any rule runs, the same as an invalid-regex name. Every other case
    # in this suite pins 6, so pin the number that actually distinguishes them.
    assert '[ "$rc" = "1" ]' "check refuses a project named $reserved with exit 1 (got $rc)"
    assert 'grep -qF "is reserved" <<<"$out"' "and says it is reserved (said '$out')"
    assert 'grep -qF "$reserved" <<<"$out"'   "naming it"
done

# --- Mail (M01, M02) -------------------------------------------------------------
# Local rules, and only when the manifest has a `mail:` block. M03 — "the stack
# on the VPS knows this domain" — is a --server rule and is not here; deploy
# asks the registry that question and warns.
projm="$tmpdir/mail-ok"
make_project "$projm" mailer mailer.example.com
mkdir -p "$projm/mail"
printf '{"name":"mailer.example.com","imap":{"host":"mail.example.com","port":993}}\n' \
    > "$projm/mail/snappymail-domain.json"
printf 'mail:\n  domain: mailer.example.com\n  snappymail_domain: ./mail/snappymail-domain.json\n' \
    >> "$projm/kasbah.yml"
out="$(cd "$projm" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]' "a complete mail: block passes (rc $rc)
        $out"
assert 'grep -qF "Mail claim names domain '\''mailer.example.com'\''" <<<"$out"' \
    "M01 names the claimed domain (said '$out')"
assert 'grep -qF "exists and parses" <<<"$out"' "M02 passes on a JSON pre-seed (said '$out')"

# The control that makes the section conditional mean something: no mail: block,
# no Mail section at all. Without it, every assertion above is satisfied by a
# check that prints the heading unconditionally.
out="$(cd "$tmpdir/ok" && "$kasbah" check 2>&1)"
assert '! grep -qF "Mail:" <<<"$out"' \
    "a project with no mail: block is not asked about mail (said '$out')"

# M01: a block with no domain.
projm2="$tmpdir/mail-nodomain"
make_project "$projm2" mailer2 mailer2.example.com
printf 'mail:\n  snappymail_domain: ./nope.json\n' >> "$projm2/kasbah.yml"
out="$(cd "$projm2" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]' "M01 fails a mail: block with no domain: (rc $rc)"
assert 'grep -qF "mail: has no domain:" <<<"$out"' "saying which field (said '$out')"

# A mail: that is not a block. The operator gets the shape, not jq's type error.
projm3="$tmpdir/mail-scalar"
make_project "$projm3" mailer3 mailer3.example.com
printf 'mail: mailer3.example.com\n' >> "$projm3/kasbah.yml"
out="$(cd "$projm3" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]' "a scalar mail: fails (rc $rc)"
assert 'grep -qF "mail: has type '\''string'\''" <<<"$out"' "naming what it found (said '$out')"
assert '! grep -qF "Cannot index" <<<"$out"' "and not jq'\''s own error (said '$out')"

# M02: the pre-seed is named and is not there. Deploy copies that file
# **if the target is missing** and never overwrites, so a bad one is the version
# SnappyMail keeps — which is why this fails rather than warns.
projm4="$tmpdir/mail-noseed"
make_project "$projm4" mailer4 mailer4.example.com
printf 'mail:\n  domain: mailer4.example.com\n  snappymail_domain: ./mail/gone.json\n' \
    >> "$projm4/kasbah.yml"
out="$(cd "$projm4" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]' "M02 fails a snappymail_domain naming no file (rc $rc)"
assert 'grep -qF "is not a file in this project" <<<"$out"' "saying so (said '$out')"
assert 'grep -qF "Mail claim names domain" <<<"$out"' \
    "while M01 still passes — two rules, two verdicts (said '$out')"

# M02: present and not JSON. `{host: mail.example.com}` is valid YAML and is not
# JSON, which is the case a yq-based check would pass and SnappyMail would
# reject.
projm5="$tmpdir/mail-badjson"
make_project "$projm5" mailer5 mailer5.example.com
mkdir -p "$projm5/mail"
printf '{host: mail.example.com}\n' > "$projm5/mail/seed.json"
printf 'mail:\n  domain: mailer5.example.com\n  snappymail_domain: ./mail/seed.json\n' \
    >> "$projm5/kasbah.yml"
out="$(cd "$projm5" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]' "M02 fails a pre-seed that is not JSON (rc $rc)"
assert 'grep -qF "is not valid JSON" <<<"$out"' "saying so (said '$out')"

# And with no pre-seed named at all, M02 says nothing: it is optional.
projm6="$tmpdir/mail-noseedfield"
make_project "$projm6" mailer6 mailer6.example.com
printf 'mail:\n  domain: mailer6.example.com\n' >> "$projm6/kasbah.yml"
out="$(cd "$projm6" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]' "a mail: block with only a domain passes (rc $rc)
        $out"
assert '! grep -qF "snappymail_domain" <<<"$out"' \
    "and nothing is said about a pre-seed nobody named (said '$out')"


# =============================================================================
# `check --server USER@HOST` — the VPS-aware rules
# =============================================================================
# Driven through a stub ssh that answers the reachability probe, the marker read
# and the one batched check step with whatever this suite writes. That is what
# makes states no rig can be put into on demand — an unhealthy container, an
# expired certificate, an acme.json whose schema has shifted, a store this user
# cannot read — reachable without a server. The rig-driven half (that the
# numbers match a real server, and that nothing is written there) is in
# tests/integration/check_server_test.sh.

stub_dir="$tmpdir/stub"
mkdir -p "$stub_dir"
ssh_log="$tmpdir/ssh.log"
marker_payload="$tmpdir/marker-payload"
check_payload="$tmpdir/check-payload"

cat > "$stub_dir/ssh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SSH_LOG"
last="${!#}"
case "$last" in true) exit 0 ;; esac
case "$*" in *"-O exit"*) exit 0 ;; esac
# The marker read is the step that names the apps pointer; everything else is
# the check step.
case "$*" in
    *"/etc/kasbah/apps-path"*) cat "$MARKER_PAYLOAD"; exit "${MARKER_RC:-0}" ;;
esac
[ -z "${CHECK_STEP_RC:-}" ] || exit "$CHECK_STEP_RC"
cat "$CHECK_PAYLOAD"
STUB
chmod 0755 "$stub_dir/ssh"

check_cli() {
    local dir="$1"; shift
    : > "$ssh_log"
    (cd "$dir" && env PATH="$stub_dir:$PATH" SSH_LOG="$ssh_log" \
        MARKER_PAYLOAD="$marker_payload" CHECK_PAYLOAD="$check_payload" \
        "$kasbah" check "$@" 2>&1)
}

b64() { printf '%s' "$1" | base64 -w0; }

# A server prepared at /apps, 16 cores and 60 GiB, so the marker's 90% ceiling
# is the 14.4 / 54g `server init` computes.
write_marker() {
    {
        printf 'apps=/apps\nsource=default\n'
        printf '%s\n' "${1:-{\"kasbah_version\":\"0.1.0-dev\",\"apps_path\":\"/apps\",\"data_path\":\"/apps/data\",\"cpu_limit\":\"14.4\",\"mem_limit\":\"54g\"\}}"
    } > "$marker_payload"
}
write_marker

# A certificate the store can carry. Generated per run for the valid cases, so
# they never start failing on a fixed date; the expired one is a fixed literal
# below, because openssl 3.0 cannot backdate a certificate it issues.
gen_cert() {
    openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/null -out /dev/stdout \
        -subj "/CN=$2/O=kasbah test fixture" -days "$1" 2>/dev/null
}
cert_valid="$(gen_cert 400 demo.example.com)"
cert_soon="$(gen_cert 7 demo.example.com)"
# Self-signed, CN=demo.example.com, notAfter 2024-03-01 — expired since, and
# always will be.
cert_expired='-----BEGIN CERTIFICATE-----
MIIDHzCCAgegAwIBAgIUIGcPNgzoFnaGV2ty8ce2hky1lxEwDQYJKoZIhvcNAQEL
BQAwOTEZMBcGA1UEAwwQZGVtby5leGFtcGxlLmNvbTEcMBoGA1UECgwTa2FzYmFo
IHRlc3QgZml4dHVyZTAeFw0yNDAxMDExMjAwMDBaFw0yNDAzMDExMjAwMDBaMDkx
GTAXBgNVBAMMEGRlbW8uZXhhbXBsZS5jb20xHDAaBgNVBAoME2thc2JhaCB0ZXN0
IGZpeHR1cmUwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDbyhCRvnet
ftg7hTfbIBQ8JITW1j2GO2Yc+T+L1oHjUEsN8apeE3RB4UNY8BgFAStxzSOuLufW
geLVYn/OV7IA8ucxIT7XCh0kLs4OVzt1Qvcz/ZcSVkiWW4myAxeAc25CBbwUGjMQ
sgvHyK/OKgKtgKN4phHxdy74oNpkh2lWZzrLZYA50FNVf0o20pNNS6I7dSl/UjwN
WdEdu/jffSSHQe0urPaFmWD4sbPZvIhdylQHZYiLX7BwQvWV3DyA8PARKFCXidic
fR9bnorTc5R3BcnZ62MEsUqHhFeoWvJ/10I0xrpjBv+GezSY9RZznhAiqewiDKAk
4ZstM8qJLW2FAgMBAAGjHzAdMBsGA1UdEQQUMBKCEGRlbW8uZXhhbXBsZS5jb20w
DQYJKoZIhvcNAQELBQADggEBAG4I62Myy2heOxlrHxzWtdY96J194qS4zxQ8h+FO
F+Nzf8j6lP4GFV7s0WU0NWhLdxWww6V3EGPD0Hp+lzvhkpfn0ww7rrTYknjkGgyZ
VjFtg1THz9/KXefj9WoMXRdlsSoASBDoW4k1h/cEP1P9sHxFWqU6aUVWmUDBoKaa
weJvDg3SWoEj9dTO0rrEydfIWuF7orYUFiOWudauArrIpzutng1rBLw3ZVnOnN8V
uEgNKjiCJx3XIfxY/oBMHlTEdlJf9E71S1Js/PiB+ngV1X3LK6fc1217sGmDDhOG
V3o4fyEFLUqSkQEc1/9oc3bhzM3sOqITTy9RjwS75WQYZgw=
-----END CERTIFICATE-----'

# The store, shaped the way Traefik writes it. `Account.PrivateKey` and each
# entry's `key` carry a recognisable marker so the redaction assertions below
# can look for something that must never be printed.
ACME_SECRET=THIS-IS-PRIVATE-KEY-MATERIAL
acme_store() {
    local main="$1" pem="$2"
    jq -nc --arg m "$main" --arg c "$(b64 "$pem")" --arg s "$ACME_SECRET" \
        '{letsencrypt:{Account:{Email:"ops@example.com",PrivateKey:$s},
          Certificates:[{domain:{main:$m,sans:["www."+$m]},certificate:$c,key:$s,Store:"default"}]}}'
}

srv_env='DOMAIN=demo.example.com
# >>> kasbah managed block - do not edit, rewritten on every deploy >>>
KASBAH_CPU_LIMIT=14.4
KASBAH_MEM_LIMIT=54g
# <<< kasbah managed block <<<'

srv_registry='name: mail
primary_domain: rig.test
domains:
  - rig.test
  - shop.rig.test'

srv_shared='http:
  routers:
    traefik-dashboard:
      rule: "Host(`traefik.rig.test`)"
      entryPoints: [websecure]'

# The whole batched report, as the remote step writes it. Every case starts
# from this and moves one key.
# The blob the default payload carries, kept so the redaction assertions can
# look for the thing that must never be printed. Grepping for the *decoded*
# secret proves nothing on its own: the payload carries acme.json base64'd, so a
# diagnostic that echoed the whole of it would still not contain the plaintext
# — which is exactly how a redaction test scores zero against a mutant that
# removes the redaction.
ACME_B64=""
write_check_payload() {
    ACME_B64="$(b64 "$(acme_store demo.example.com "$cert_valid")")"
    {
        printf 'project_state=dir\n'
        printf 'env_state=file\n'
        printf 'env_b64=%s\n'      "$(b64 "$srv_env")"
        printf 'registry_state=file\n'
        printf 'registry_b64=%s\n' "$(b64 "$srv_registry")"
        printf 'shared_state=file\n'
        printf 'shared_b64=%s\n'   "$(b64 "$srv_shared")"
        printf 'acme_state=file\n'
        printf 'acme_b64=%s\n'     "$ACME_B64"
        printf 'health_state=running\n'
        printf 'health_health=healthy\n'
        printf 'docker_error=\n'
        # The backup stack. By default a server with none — the marker above
        # records no `backup` object, so B01 is not asked and every case that
        # predates it prints exactly what it printed before.
        printf 'backup_dir_state=%s\n' "${BK_DIR_STATE:-absent}"
        printf 'backup_status_state=%s\n' "${BK_STATUS_STATE:-absent}"
        printf 'backup_status_b64=%s\n' "$(b64 "${BK_RECORD:-}")"
        printf 'now=%s\n' "${BK_NOW:-2000000000}"
        printf 'backup_haspass=%s\n' "${BK_HASPASS-}"
        printf 'backup_projects=%s\n' "${BK_PROJECTS-}"
        printf 'backup_mail=%s\n' "${BK_MAIL:-no}"
        printf 'backup_c_state=%s\n' "${BK_C_STATE:-absent}"
        printf 'backup_c_health=%s\n' "${BK_C_HEALTH:-none}"
    } > "$check_payload"
}

payload_set() {
    local key="${1%%=*}"
    grep -v "^$key=" "$check_payload" > "$check_payload.next"
    printf '%s\n' "$1" >> "$check_payload.next"
    mv "$check_payload.next" "$check_payload"
}

# --- Case S1: the golden --server run ----------------------------------------
srv1="$tmpdir/srv-ok"
make_project "$srv1"
printf 'health:\n  container: demo-web\n' >> "$srv1/kasbah.yml"
printf 'mail:\n  domain: shop.rig.test\n' >> "$srv1/kasbah.yml"
write_check_payload
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "0" ]' "a deployed, healthy, certified project passes --server (rc $rc)
$out"
assert 'grep -qF "Server (deploy@vps at /apps):" <<<"$out"' "the section names the target and the apps path (said '$out')"
assert 'grep -qF "✓ /apps/demo exists on deploy@vps" <<<"$out"'  "the project dir (said '$out')"
assert 'grep -qF "✓ .env on deploy@vps has no missing keys" <<<"$out"' "E02 against the server (said '$out')"
assert 'grep -qF "✓ .env on deploy@vps has no extra keys" <<<"$out"'   "E03 against the server (said '$out')"
assert 'grep -qF "✓ the mail stack on deploy@vps serves '"'"'shop.rig.test'"'"' (listed under domains:)" <<<"$out"' \
    "M03 against the registry (said '$out')"
assert 'grep -qF "✓ manifest health.container '"'"'demo-web'"'"' is running and healthy on deploy@vps" <<<"$out"' \
    "the health container (said '$out')"
assert 'grep -qE "✓ certificate for .demo.example.com. valid for 39[0-9] more day" <<<"$out"' \
    "the certificate, with days left rather than an age (said '$out')"
assert 'grep -qF "✓ effective resource limits on deploy@vps match the host'"'"'s 90% ceiling (14.4 cpus, 54g)" <<<"$out"' \
    "R04 at the ceiling (said '$out')"
# Two round trips and no more: the marker read, then one batched step.
assert '[ "$(grep -c "bash. .-s" "$ssh_log")" = "2" ]' \
    "one batched read after the marker, not one per fact (ssh saw: $(cat "$ssh_log"))"
# Redaction, the reason this command does not reuse _ss_absorb_checked.
assert '[ "${#ACME_B64}" -gt 200 ]' "the fixture store is a blob worth redacting (${#ACME_B64} bytes)"
assert '! grep -qF "${ACME_B64:0:60}" <<<"$out"' \
    "the acme payload is never printed (said '$out')"
assert '! grep -qF "$ACME_SECRET" <<<"$out"' \
    "nor is anything decoded out of it (said '$out')"

# T05 tightened: the exact hostnames this server owns, named in the line.
assert 'grep -qF "✓ No router claims a hostname kasbah owns on deploy@vps (traefik.rig.test mail.rig.test webmail.rig.test)" <<<"$out"' \
    "T05 tightens to the server's own hostnames (said '$out')"
assert '! grep -qF "reserved hostnames (traefik.*" <<<"$out"' \
    "and the local heuristic line is gone (said '$out')"

# --- Case S2: project not deployed -------------------------------------------
write_check_payload
payload_set project_state=absent
payload_set env_state=absent
payload_set env_b64=
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "0" ]' "a project that has not been deployed yet is a warning, not a failure (rc $rc)"
assert 'grep -qF "⚠ /apps/demo does not exist on deploy@vps" <<<"$out"' "saying so (said '$out')"
assert '! grep -qF "has no missing keys" <<<"$out"' \
    "and the env rules say nothing about a .env that cannot exist (said '$out')"

# A path that is there and is not a directory is a different answer: a deploy
# would try to write the project into it.
write_check_payload
payload_set project_state=notdir
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "6" ]' "a project path that is not a directory fails (rc $rc)"
assert 'grep -qF "✗ /apps/demo on deploy@vps exists and is not a directory" <<<"$out"' "saying so (said '$out')"

# --- Case S3: env drift against the server ------------------------------------
write_check_payload
payload_set "env_b64=$(b64 'KASBAH_CPU_LIMIT=14.4
KASBAH_MEM_LIMIT=54g
SURPRISE=1')"
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "0" ]' "drift on the server is a warning (rc $rc)"
assert 'grep -qF "⚠ .env on deploy@vps is missing keys vs .env.prod.example: DOMAIN" <<<"$out"' \
    "E02 names the missing key (said '$out')"
assert 'grep -qF "⚠ .env on deploy@vps has extra keys not in .env.prod.example: SURPRISE" <<<"$out"' \
    "E03 names the extra one (said '$out')"
assert '! grep -qF "KASBAH_CPU_LIMIT" <<<"$(grep "extra keys" <<<"$out")"' \
    "and the reserved prefix is exempt there exactly as it is locally (said '$out')"

write_check_payload
payload_set env_state=absent
payload_set env_b64=
out="$(check_cli "$srv1" --server deploy@vps)"
assert 'grep -qF "⚠ /apps/demo/.env does not exist on deploy@vps" <<<"$out"' \
    "a deployed project with no .env (said '$out')"

# --- Case S4: M03 -------------------------------------------------------------
write_check_payload
payload_set "registry_b64=$(b64 'name: mail
primary_domain: rig.test
domains:
  - rig.test')"
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "6" ]' "M03 fails a claim the registry does not carry (rc $rc)"
assert 'grep -qF "✗ the mail stack on deploy@vps does not serve '"'"'shop.rig.test'"'"'" <<<"$out"' \
    "saying so, and naming add-mail-domain (said '$out')"
assert 'grep -qF "kasbah server add-mail-domain deploy@vps shop.rig.test" <<<"$out"' \
    "with the command that fixes it (said '$out')"

write_check_payload
payload_set registry_state=absent
payload_set registry_b64=
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "6" ]' "M03 fails a claim on a server with no mail stack (rc $rc)"
assert 'grep -qF "there is no mail stack on deploy@vps" <<<"$out"' "saying so (said '$out')"

# The primary_domain is served whether or not anyone listed it — the same rule
# `server init` renders the registry under.
srvm="$tmpdir/srv-primary"
make_project "$srvm"
printf 'mail:\n  domain: rig.test\n' >> "$srvm/kasbah.yml"
write_check_payload
out="$(check_cli "$srvm" --server deploy@vps)"
assert 'grep -qF "✓ the mail stack on deploy@vps serves '"'"'rig.test'"'"' (its primary_domain)" <<<"$out"' \
    "the primary counts as served (said '$out')"

# A project that claims no mail is asked nothing.
srvn="$tmpdir/srv-nomail"
make_project "$srvn"
write_check_payload
out="$(check_cli "$srvn" --server deploy@vps)"
assert '! grep -qF "mail stack on deploy@vps" <<<"$out"' \
    "M03 says nothing about a project with no mail: block (said '$out')"

# --- Case S5: the health container --------------------------------------------
write_check_payload
payload_set health_health=unhealthy
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "6" ]' "an unhealthy health.container fails (rc $rc)"
assert 'grep -qF "✗ manifest health.container '"'"'demo-web'"'"' is running and UNHEALTHY on deploy@vps" <<<"$out"' \
    "saying so (said '$out')"

write_check_payload
payload_set health_state=absent
payload_set health_health=none
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "0" ]' "a container that is not running warns (rc $rc)"
assert 'grep -qF "⚠ manifest health.container '"'"'demo-web'"'"' is not running on deploy@vps" <<<"$out"' \
    "saying so (said '$out')"

write_check_payload
payload_set health_state=restarting
payload_set health_health=starting
out="$(check_cli "$srv1" --server deploy@vps)"
assert 'grep -qF "⚠ manifest health.container '"'"'demo-web'"'"' is restarting and still starting" <<<"$out"' \
    "a starting container warns and says which state it is in (said '$out')"

# --- Case S6: certificate status ----------------------------------------------
write_check_payload
payload_set "acme_b64=$(b64 "$(acme_store demo.example.com "$cert_expired")")"
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "6" ]' "an expired certificate fails (rc $rc)"
assert 'grep -qF "✗ certificate for '"'"'demo.example.com'"'"' EXPIRED" <<<"$out"' "saying so (said '$out')"
assert 'grep -qF "Mar  1 12:00:00 2024 GMT" <<<"$out"' "with the expiry openssl read (said '$out')"
assert '! grep -qiF "notBefore" <<<"$out"' \
    "and nothing about notBefore, which Let's Encrypt backdates (said '$out')"

write_check_payload
payload_set "acme_b64=$(b64 "$(acme_store demo.example.com "$cert_soon")")"
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "0" ]' "a certificate inside Traefik's renewal window warns (rc $rc)"
assert 'grep -qE "⚠ certificate for .demo.example.com. expires in [0-9]+ day" <<<"$out"' "saying so (said '$out')"

# A certificate that carries the domain as a SAN rather than as its main name.
write_check_payload
payload_set "acme_b64=$(b64 "$(jq -nc --arg c "$(b64 "$cert_valid")" \
    '{letsencrypt:{Account:{},Certificates:[{domain:{main:"other.example.com",sans:["demo.example.com"]},certificate:$c,Store:"default"}]}}')")"
out="$(check_cli "$srv1" --server deploy@vps)"
assert 'grep -qF "certificate for '"'"'demo.example.com'"'"' (as a SAN of other.example.com)" <<<"$out"' \
    "a SAN match says which certificate it found (said '$out')"

# The five ways a store can fail to answer, which are five different remedies.
write_check_payload
payload_set "acme_b64=$(b64 '{"letsencrypt":{"Account":{},"Certificates":[]}}')"
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "0" ]' "an empty store warns rather than failing (rc $rc)"
assert 'grep -qF "⚠ the certificate store at /apps/data/traefik/letsencrypt/acme.json on deploy@vps holds no certificates" <<<"$out"' \
    "saying so (said '$out')"

write_check_payload
payload_set "acme_b64=$(b64 "$(acme_store other.example.com "$cert_valid")")"
out="$(check_cli "$srv1" --server deploy@vps)"
assert 'grep -qF "⚠ no certificate for '"'"'demo.example.com'"'"'" <<<"$out"' \
    "a store with certificates but not this one (said '$out')"
assert 'grep -qF "(1 in the store)" <<<"$out"' "and how many there were (said '$out')"

write_check_payload
payload_set "acme_b64=$(b64 'this is not json at all { {')"
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "0" ]' "an unparseable store warns (rc $rc)"
assert 'grep -qF "does not parse as JSON" <<<"$out"' "saying so (said '$out')"

# Schema-shifted two ways: another resolver name, and a Certificates that is
# not a list.
write_check_payload
payload_set "acme_b64=$(b64 '{"myresolver":{"Account":{},"Certificates":[]}}')"
out="$(check_cli "$srv1" --server deploy@vps)"
assert 'grep -qF "has no '"'"'letsencrypt'"'"' store" <<<"$out"' \
    "a store keyed by another resolver name (said '$out')"

write_check_payload
payload_set "acme_b64=$(b64 '{"letsencrypt":{"Account":{},"Certificates":{"main":"demo.example.com"}}}')"
out="$(check_cli "$srv1" --server deploy@vps)"
assert 'grep -qF "whose Certificates is a object, not a list" <<<"$out"' \
    "a Certificates that is not an array (said '$out')"

# Permission denied — the file is there and this user cannot read it.
write_check_payload
payload_set acme_state=unreadable
payload_set acme_b64=
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "0" ]' "an unreadable store warns (rc $rc)"
assert 'grep -qF "cannot be read by this user" <<<"$out"' "saying so (said '$out')"
assert 'grep -qF "mode 600 and owned by the deploy user" <<<"$out"' \
    "with what it should have been (said '$out')"

write_check_payload
payload_set acme_state=absent
payload_set acme_b64=
out="$(check_cli "$srv1" --server deploy@vps)"
assert 'grep -qF "⚠ no certificate store at /apps/data/traefik/letsencrypt/acme.json" <<<"$out"' \
    "no store at all is a different answer from an empty one (said '$out')"

# --- Case S7: R04 --------------------------------------------------------------
write_check_payload
payload_set "env_b64=$(b64 'DOMAIN=demo.example.com
KASBAH_CPU_LIMIT=15.9
KASBAH_MEM_LIMIT=54g')"
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "6" ]' "R04 fails a limit above the host's ceiling (rc $rc)"
assert 'grep -qF "✗ effective resource limits on deploy@vps are above the host'"'"'s 90% ceiling: cpus 15.9 > 14.4" <<<"$out"' \
    "naming the dimension and both numbers (said '$out')"

write_check_payload
payload_set "env_b64=$(b64 'DOMAIN=demo.example.com
KASBAH_CPU_LIMIT=14.4
KASBAH_MEM_LIMIT=60g')"
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "6" ]' "R04 fails a memory limit above the ceiling too (rc $rc)"
assert 'grep -qF "mem_limit 60g > 54g" <<<"$out"' "naming that dimension (said '$out')"

write_check_payload
payload_set "env_b64=$(b64 'DOMAIN=demo.example.com
KASBAH_CPU_LIMIT=2.0
KASBAH_MEM_LIMIT=1g')"
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "0" ]' "R04 warns rather than fails below the ceiling (rc $rc)"
assert 'grep -qF "⚠ effective resource limits on deploy@vps are below the host'"'"'s 90% ceiling: cpus 2.0 < 14.4; mem_limit 1g < 54g" <<<"$out"' \
    "naming both dimensions (said '$out')"

# The same limit in another spelling is the same limit: 55296m is 54g.
write_check_payload
payload_set "env_b64=$(b64 'DOMAIN=demo.example.com
KASBAH_CPU_LIMIT=14.4
KASBAH_MEM_LIMIT=55296m')"
out="$(check_cli "$srv1" --server deploy@vps)"
assert 'grep -qF "✓ effective resource limits on deploy@vps match" <<<"$out"' \
    "sizes are compared in bytes, not as strings (said '$out')"

write_check_payload
payload_set "env_b64=$(b64 'DOMAIN=demo.example.com')"
out="$(check_cli "$srv1" --server deploy@vps)"
assert 'grep -qF "carries no KASBAH_CPU_LIMIT or KASBAH_MEM_LIMIT" <<<"$out"' \
    "a .env whose managed block was edited out (said '$out')"

write_check_payload
payload_set "env_b64=$(b64 'DOMAIN=demo.example.com
KASBAH_CPU_LIMIT=all-of-them
KASBAH_MEM_LIMIT=54g')"
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "0" ]' "a limit that is not a number warns rather than failing (rc $rc)"
assert 'grep -qF "cpus '"'"'all-of-them'"'"' is not a number" <<<"$out"' "saying so (said '$out')"

# --- Case S8: T05, the tightening that changes a verdict -----------------------
# `mail.other.example.com` is not a hostname this server owns. The local
# heuristic fails it on the first label; the exact match passes it.
srvt="$tmpdir/srv-t05"
make_project "$srvt" t05 mail.other.example.com
out="$(cd "$srvt" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]' "locally, the first-label heuristic fails mail.other.example.com (rc $rc)"
assert 'grep -qF "✗ Routers claim reserved hostnames:" <<<"$out"' "with the heuristic's wording (said '$out')"
write_check_payload
out="$(check_cli "$srvt" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "0" ]' "and under --server the exact match passes it (rc $rc)
$out"
assert 'grep -qF "✓ No router claims a hostname kasbah owns on deploy@vps" <<<"$out"' \
    "with the exact form's wording (said '$out')"

# And the hostname the server really owns fails, named as the server's.
srvt2="$tmpdir/srv-t05-owned"
make_project "$srvt2" webmailer webmail.rig.test
write_check_payload
out="$(check_cli "$srvt2" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "6" ]' "a router on webmail.<primary> fails under --server (rc $rc)"
assert 'grep -qF "✗ Routers claim hostnames kasbah owns on deploy@vps:" <<<"$out"' "saying so (said '$out')"
assert 'grep -qF "webmail.rig.test" <<<"$out"' "and naming the hostname (said '$out')"

# A server whose dashboard fragment cannot be read and which has no mail
# registry yields no set at all, and T05 falls back to the heuristic rather
# than passing every hostname on a server it could not ask.
write_check_payload
payload_set shared_state=unreadable
payload_set shared_b64=
payload_set registry_state=absent
payload_set registry_b64=
out="$(check_cli "$srvt" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "6" ]' "with no reserved set, T05 keeps the local heuristic (rc $rc)"
assert 'grep -qF "✗ Routers claim reserved hostnames:" <<<"$out"' "and its wording (said '$out')"
assert 'grep -qF "heuristic: deploy@vps was asked and neither its dashboard fragment nor a mail registry could be read" <<<"$out"' \
    "saying which form answered — the line is otherwise the local one (said '$out')"

# --- Case S8b: T05 falls back per family, never per set -------------------------
# The two hostname families have two sources, and either can be unreadable
# alone. A set built as one list would then be non-empty, the exact branch would
# run, and the family with no source would be guarded by nothing at all — a
# dashboard-hostname claim passing in silence because a file could not be read.
#
# Half one: the dashboard fragment is unreadable, the registry is fine.
srvt3="$tmpdir/srv-t05-noapex"
make_project "$srvt3" dash traefik.rig.test
write_check_payload
payload_set shared_state=unreadable
payload_set shared_b64=
out="$(check_cli "$srvt3" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "6" ]' \
    "with no apex, a claim on the dashboard hostname still fails — by heuristic (rc $rc)
$out"
assert 'grep -qF "✗ Routers claim hostnames kasbah owns on deploy@vps:" <<<"$out"' \
    "in the exact form's line, because the mail family was read (said '$out')"
assert 'grep -qF "traefik.* by heuristic" <<<"$out"' \
    "which names the family that fell back (said '$out')"
assert 'grep -qF "mail.rig.test webmail.rig.test" <<<"$out"' \
    "beside the two it matched exactly (said '$out')"

# And the same server still lets go of a mail-shaped hostname on somebody
# else's apex, which is the exact match doing its job for the family that has one.
write_check_payload
payload_set shared_state=unreadable
payload_set shared_b64=
out="$(check_cli "$srvt" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "0" ]' \
    "the mail family keeps matching exactly while traefik falls back (rc $rc)
$out"

# Half two: the registry is gone, the dashboard fragment is fine. The mail pair
# is then exact off the apex — `server init --with-mail` would claim precisely
# those — so nothing falls back at all.
write_check_payload
payload_set registry_state=absent
payload_set registry_b64=
out="$(check_cli "$srvt2" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "6" ]' "with no registry, webmail.<apex> is still reserved (rc $rc)"
assert 'grep -qF "webmail.rig.test" <<<"$out"' "and named (said '$out')"
assert '! grep -qF "by heuristic" <<<"$out"' \
    "with no family on the heuristic — the apex answers for all three (said '$out')"

# --- Case S8c: a SAN carrying a space must not match by accident -----------------
# The store is read one index at a time for this: a SAN list joined into one
# string and split back on spaces turns `"x demo.example.com"` into two tokens,
# and the domain would be reported as covered by a certificate that does not
# cover it — a ✓ with an expiry date on it.
write_check_payload
payload_set "acme_b64=$(b64 "$(jq -nc --arg c "$(b64 "$cert_valid")" \
    '{letsencrypt:{Account:{},Certificates:[{domain:{main:"other.example.com",sans:["evil.test demo.example.com"]},certificate:$c,Store:"default"}]}}')")"
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "0" ]' "a SAN with a space in it is one SAN (rc $rc)"
assert 'grep -qF "⚠ no certificate for '"'"'demo.example.com'"'"'" <<<"$out"' \
    "and does not cover demo.example.com (said '$out')"
assert '! grep -qF "✓ certificate for '"'"'demo.example.com'"'"'" <<<"$out"' \
    "so nothing reports an expiry for a certificate that is not for it (said '$out')"
# The control: the same list without the space does match, so the assertion
# above is about the space and not about the reader being broken.
write_check_payload
payload_set "acme_b64=$(b64 "$(jq -nc --arg c "$(b64 "$cert_valid")" \
    '{letsencrypt:{Account:{},Certificates:[{domain:{main:"other.example.com",sans:["evil.test","demo.example.com"]},certificate:$c,Store:"default"}]}}')")"
out="$(check_cli "$srv1" --server deploy@vps)"
assert 'grep -qF "✓ certificate for '"'"'demo.example.com'"'"' (as a SAN of other.example.com)" <<<"$out"' \
    "a real second SAN still matches (said '$out')"

# --- Case S8d: a daemon that is not answering is not a container that is gone ----
write_check_payload
payload_set health_state=nodaemon
payload_set health_health=none
payload_set "docker_error=Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?"
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "0" ]' "a daemon that is down warns (rc $rc)"
assert 'grep -qF "the docker daemon on deploy@vps is not answering" <<<"$out"' \
    "and says that, not that the container is down (said '$out')"
assert 'grep -qF "nothing here says the container is down" <<<"$out"' \
    "explicitly (said '$out')"
assert 'grep -qF "Is the docker daemon running?" <<<"$out"' \
    "quoting what docker itself said (said '$out')"
assert '! grep -qF "is not running on deploy@vps" <<<"$out"' \
    "and never the absent-container wording (said '$out')"

# --- Case S9: the protocol, and what a broken one may print --------------------
write_check_payload
grep -v '^health_health=' "$check_payload" > "$check_payload.t" && mv "$check_payload.t" "$check_payload"
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "1" ]' "a truncated report ends the run rather than being absorbed (rc $rc)"
assert 'grep -qF "reported no health_health" <<<"$out"' "naming the key that never arrived (said '$out')"
assert '! grep -qF "${ACME_B64:0:60}" <<<"$out"' \
    "and the diagnostic does not echo the payload, which carries acme.json (said '$out')"
assert '! grep -qF "$ACME_SECRET" <<<"$out"' \
    "nor anything decoded out of it (said '$out')"
assert 'grep -qF "acme_state acme_b64 health_state" <<<"$out"' \
    "what it reports instead is the key names, which kasbah chose (said '$out')"
assert 'grep -qF "private key material" <<<"$out"' "saying why it does not (said '$out')"

# --- Case S10: the flag itself, and last_server --------------------------------
# `check --server` is on docs/project-manifest.md's list of commands that read
# and write last_server, so a bare `--server` means the server this project last
# talked to — and a project that has never talked to one is refused with the
# remedy rather than run locally.
srvl="$tmpdir/srv-laststate"
make_project "$srvl"
out="$(cd "$srvl" && "$kasbah" check --server 2>&1)"; rc=$?
assert '[ "$rc" = "1" ]' "a bare --server on a project with no last_server is refused (rc $rc)"
assert 'grep -qF "has never talked to one" <<<"$out"' "saying so (said '$out')"
assert 'grep -qF "last_server" <<<"$out"' "and naming where the value would live (said '$out')"

write_check_payload
out="$(check_cli "$srvl" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "0" ]' "the same project with the server named runs (rc $rc)"
assert '[ "$(jq -r .last_server "$srvl/.kasbah/state.json" 2>/dev/null)" = "deploy@vps" ]' \
    "and the run records last_server (state: $(cat "$srvl/.kasbah/state.json" 2>/dev/null))"
out="$(check_cli "$srvl" --server)"; rc=$?
assert '[ "$rc" = "0" ]' "so a bare --server afterwards uses it (rc $rc)"
assert 'grep -qF "Server (deploy@vps at /apps):" <<<"$out"' \
    "against the remembered server (said '$out')"

out="$(cd "$srvl" && "$kasbah" check --server= 2>&1)"; rc=$?
assert '[ "$rc" = "1" ]' "an empty --server= is refused rather than falling back to it (rc $rc)"
assert 'grep -qF "must name the server to ask" <<<"$out"' "saying so (said '$out')"
out="$(cd "$srv1" && "$kasbah" check --help 2>&1)"
assert 'grep -qF -- "--server USER@HOST" <<<"$out"' "--help documents the flag (said '$out')"

# --- Case S11: the remote step writes nothing ----------------------------------
# Read from the source rather than asserted about behaviour: the payload is the
# whole of what runs on the server, and a reviewer can check this claim by
# reading the same lines. The rig-driven proof (a digest of the apps and data
# trees across a real run) is in tests/integration/check_server_test.sh.
payload_src="$(awk '/<<.REMOTE./{p=1;next} /^REMOTE$/{p=0} p' "$repo_dir/lib/check_server.sh")"
assert '[ -n "$payload_src" ]' "the remote payload was found in lib/check_server.sh"
# The two redirections a read-only step legitimately makes are dropped first,
# so what is left to look for is any redirection at all.
payload_writes="$(sed -e "s#2>/dev/null##g" -e "s#>/dev/null##g" -e "s#2>&1##g" <<<"$payload_src")"
assert '! grep -qE "mkdir|touch|[^a-z_]rm |[^a-z_]mv |chmod|chown|tee |[0-9]?>" <<<"$payload_writes"' \
    "the remote step has no verb that writes to the server's filesystem"
docker_verbs="$(grep -oE "[^a-z_]docker [a-z]+" <<<"$payload_src")"
assert '[ -n "$docker_verbs" ]' "the remote step calls docker at all — else the next assertion is vacuous"
# `inspect` reads one container; `version` asks the daemon whether it is there
# at all, which is how a dead daemon is told apart from an absent container.
# Both are reads, and they are the only two allowed.
assert '[ -z "$(grep -vE "docker (inspect|version)" <<<"$docker_verbs")" ]' \
    "and every docker verb it uses is a read (found: $(tr -d " " <<<"$docker_verbs" | sort -u | tr "\n" " "))"

# --- Case S12: B01, the backup stack's last run --------------------------------
# The record templates/backup/backup.sh writes is the only thing on a VPS that
# says whether backups are still happening. Nothing read it until this rule, so
# a stack that had silently stopped was visible only in `docker logs`.
#
# Absence is never a conclusion: a stack that has never written a record, a
# record nobody can read and a record with no completed run in it each warn and
# say which. Only a record asserting a failed run, or one whose own deadline has
# passed, fails.
bk_marker="$(jq -cn '{kasbah_version:"0.1.0-dev",apps_path:"/apps",data_path:"/apps/data",
                      cpu_limit:"14.4",mem_limit:"54g",
                      backup:{enabled:true,repo_base:"s3:https://s3.example/bucket/",
                              at:"02:00",jitter:42,timeout:900}}')"
# state deadline next_run since started finished status repos
bk_rec() {
    printf 'state=%s\nsince=%s\ndeadline=%s\nnext_run=%s\nlast_run_started=%s\nlast_run_finished=%s\nlast_run_status=%s\nlast_run_repos=%s\ntimeout=900\nat=02:00\njitter=42\n' \
        "$1" "$4" "$2" "$3" "$5" "$6" "$7" "$8"
}
bk_ok="$(bk_rec sleeping 2000086400 2000082800 1999990000 1999980000 1999983600 ok ' demo mail')"
# A backup-enabled server with one repository that has its password and a
# scheduler that is running — the shape every case below moves one key of.
bk_srv() {
    BK_DIR_STATE="$1" BK_STATUS_STATE="$2" BK_RECORD="$3"
    BK_HASPASS="demo mail" BK_PROJECTS="demo=" BK_MAIL=yes
    BK_C_STATE=running BK_C_HEALTH=healthy
    write_check_payload
    write_marker "$bk_marker"
}

# A server that was never asked to back anything up is not asked about. Backups
# are optional, `--no-backup` is a documented answer, and `check` is a project
# linter rather than an opinion about a server's disaster-recovery policy.
write_marker
write_check_payload
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
srv_section="$(sed -n '/^Server (/,$p' <<<"$out")"
assert '[ "$rc" = "0" ]' "a server with no backups configured still passes (rc $rc)"
assert '! grep -qF "backup" <<<"$srv_section"' \
    "and B01 says nothing at all about it (server section said '$srv_section')"

# The healthy stack.
bk_srv dir file "$bk_ok"
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "0" ]' "a backed-up server whose last run succeeded passes (rc $rc)
$out"
assert 'grep -qF "✓ the last backup on deploy@vps finished 4h ago and succeeded (repositories: demo mail)" <<<"$out"' \
    "with the age off the server's own clock and what it reached (said '$out')"

# The stack that has never fired once — the plan's own watch-out. It must not
# read like a stack that stopped a month ago, and it must not fail.
bk_srv dir file "$(bk_rec sleeping 2000086400 2000082800 1999999000 0 0 - -)"
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "0" ]' "a stack that has never run warns rather than failing (rc $rc)"
assert 'grep -qF "⚠ backups are configured on deploy@vps and no run has finished yet" <<<"$out"' \
    "saying exactly that (said '$out')"
assert 'grep -qF "rather than one that has stopped" <<<"$out"' \
    "and saying which fact it is not (said '$out')"

# A stack that has written no record at all: the container writes one as its
# first act, so this is a scheduler that has not started.
bk_srv dir absent ""
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "0" ]' "no record warns (rc $rc)"
assert 'grep -qF "⚠ the backup scheduler on deploy@vps has written no record at /apps/.kasbah/backup/state/status" <<<"$out"' \
    "naming the file (said '$out')"
assert 'grep -qF "docker compose -p kasbah-backup up -d" <<<"$out"' "and the remedy (said '$out')"

# A record that is there and cannot be read. `kasbah server prune` refuses to
# conclude from a record it could not read, and so does this.
bk_srv dir unreadable ""
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "0" ]' "an unreadable record warns (rc $rc)"
assert 'grep -qF "cannot be read by the ssh user, so nothing here says whether a backup has ever run" <<<"$out"' \
    "and refuses to conclude from it (said '$out')"
assert 'grep -qF "not the same fact as a backup that has stopped" <<<"$out"' \
    "explicitly (said '$out')"
# Bytes that are not this record at all.
bk_srv dir file "there is no deadline in here"
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "0" ]' "a record this kasbah cannot parse warns (rc $rc)"
assert 'grep -qF "is not a record this kasbah reads" <<<"$out"' "saying so (said '$out')"

# The marker enables backups and the stack is not on the server.
bk_srv absent absent ""
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "0" ]' "a marker naming a stack the server does not have warns (rc $rc)"
assert 'grep -qF "records off-box backups and /apps/.kasbah/backup is not there" <<<"$out"' \
    "saying which is missing (said '$out')"

# The failed run: the case this rule exists to fail.
bk_srv dir file "$(bk_rec sleeping 2000086400 2000082800 1999990000 1999980000 1999983600 failed ' none')"
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "6" ]' "a last backup that failed fails the check (rc $rc)"
assert 'grep -qF "✗ the last backup on deploy@vps FAILED 4h ago (repositories backed up: none)" <<<"$out"' \
    "naming what it did and did not reach (said '$out')"
assert 'grep -qF "docker logs kasbah-backup" <<<"$out"' "and where the reason is (said '$out')"

# The stack that stopped: the state it last recorded has outlived its own
# deadline. Its last run went fine, which is exactly why the age of that run
# cannot be the verdict.
bk_srv dir file "$(bk_rec sleeping 1999900000 1999896000 1999800000 1999780000 1999783600 ok ' demo')"
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "6" ]' "a scheduler past its own deadline fails the check (rc $rc)"
assert 'grep -qF "✗ the backup scheduler on deploy@vps is 27h past its own deadline in state '"'"'sleeping'"'"'" <<<"$out"' \
    "saying how far past and in which state (said '$out')"
assert 'grep -qF "the last run finished 2 day(s) ago" <<<"$out"' \
    "with the run that did work, which is not a contradiction (said '$out')"

# A run that never returned: same verdict, and the state is what tells them apart.
bk_srv dir file "$(bk_rec running 1999990000 0 1999980000 1999980000 0 - -)"
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "6" ]' "a run that never returned fails too (rc $rc)"
assert 'grep -qF "in state '"'"'running'"'"'" <<<"$out"' "named as a wedged run (said '$out')"
assert '! grep -qF "the last run finished" <<<"$out"' \
    "and claims no finished run, because there has never been one (said '$out')"

# A marker whose `backup` is not an object: jq answers that with a type error
# rather than a null, and an unguarded read would end the run before any verdict
# printed.
write_check_payload
write_marker '{"kasbah_version":"0.1.0-dev","apps_path":"/apps","data_path":"/apps/data","cpu_limit":"14.4","mem_limit":"54g","backup":"yes please"}'
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "0" ]' "a marker with a backup field that is not an object still reports (rc $rc)
$out"
assert 'grep -qF "Server (deploy@vps at /apps):" <<<"$out"' "and the section still runs (said '$out')"
srv_section="$(sed -n '/^Server (/,$p' <<<"$out")"
assert '! grep -qF "backup" <<<"$srv_section"' \
    "with B01 not asked, rather than answered off a field it could not read (said '$srv_section')"

# B01 is a fact about the server, not about the project: a project nobody has
# deployed still gets the verdict, because the backups it will need are the same
# backups.
bk_srv dir file "$(bk_rec sleeping 2000086400 2000082800 1999990000 1999980000 1999983600 failed ' none')"
payload_set project_state=absent
payload_set env_state=absent
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "6" ]' "a failed backup fails even where the project is not deployed (rc $rc)"
assert 'grep -qF "✗ the last backup on deploy@vps FAILED" <<<"$out"' "saying so (said '$out')"

# --- Case S13: the two shapes of deadline bash arithmetic refuses ---------------
# A digits-only admission test is not one. A leading zero makes the value an
# invalid *octal* literal — a fatal arithmetic error that ended `server status`
# mid-report with exit 1 — and a digit string past 2^63 makes `[ -gt ]` say
# "integer expression expected" and be silently false, so the record came out
# the other side as a passing backup. Both are records a hand edit or a
# truncated write produces, and `unparsed` exists for exactly them.
for bad_deadline in 01999000009 999999999999999999999999 12x 1e9 " 2000086400"; do
    bk_srv dir file "$(bk_rec sleeping "$bad_deadline" 2000082800 1999990000 1999980000 1999983600 ok ' demo')"
    out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
    assert '[ "$rc" = "0" ]' "a deadline of '$bad_deadline' warns rather than ending the run (rc $rc)
$out"
    assert 'grep -qF "is not a record this kasbah reads" <<<"$out"' \
        "and is refused as unreadable (deadline '$bad_deadline', said '$out')"
    assert 'grep -qF "not a unix time this kasbah can compare" <<<"$out"' \
        "naming what was wrong with it (deadline '$bad_deadline', said '$out')"
    assert '! grep -qF "✓ the last backup" <<<"$out"' \
        "and never as a backup that worked (deadline '$bad_deadline', said '$out')"
    assert '! grep -qF "integer expression" <<<"$out"' \
        "with no shell arithmetic complaint reaching the operator (said '$out')"
done
# The control: the same record with a deadline bash can read is judged, so the
# refusals above are about the value and not about the reader being broken.
bk_srv dir file "$(bk_rec sleeping 2000086400 2000082800 1999990000 1999980000 1999983600 ok ' demo')"
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "0" ]' "the same record with a usable deadline passes (rc $rc)"
assert 'grep -qF "✓ the last backup on deploy@vps finished 4h ago and succeeded" <<<"$out"' \
    "and is judged rather than refused (said '$out')"
# `0` is a real epoch and the writer uses it for "no next run yet", so it must
# not be swept up with the refusals above.
bk_srv dir file "$(bk_rec sleeping 2000086400 0 1999990000 1999980000 1999983600 ok ' demo')"
out="$(check_cli "$srv1" --server deploy@vps)"
assert 'grep -qF "✓ the last backup on deploy@vps" <<<"$out"' \
    "a next_run of 0 is a value the writer really writes, not a refusal (said '$out')"

# A verdict the reader cannot produce, driven straight at B01 with the reader
# stubbed — the arm no payload can reach, and the one that decides what an
# unknown answer looks like. `ok` is not the catch-all: on a rule whose subject
# is that absence is not a value, success must never be what a verdict falls
# into by failing to match.
b01_driver="$tmpdir/b01_driver.sh"
cat > "$b01_driver" <<'B01'
set -euo pipefail
. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/check.sh"
. "$KASBAH_LIB_DIR/check_server.sh"
_CS_TARGET=deploy@vps
MARKER_APPS_PATH=/apps
MARKER_JSON='{"backup":{"enabled":true}}'
_CS_FACT=([backup_dir_state]=dir [backup_status_state]=file [backup_status_b64]="$(printf x | base64 -w0)"
          [now]=2000000000 [backup_haspass]="demo" [backup_projects]="demo=" [backup_mail]=no
          [backup_c_state]=running [backup_c_health]=healthy [docker_error]=)
# The stub is the point: BKR_VERDICT is set to whatever this case asks for, with
# every other field as a healthy record would carry them.
eval "backup_record_read() { BKR_VERDICT=$1; BKR_REASON=''; BKR_STATE=sleeping; BKR_SINCE=1999990000;
      BKR_DEADLINE=2000086400; BKR_NEXT_RUN=2000082800; BKR_STARTED=1999980000;
      BKR_FINISHED=1999983600; BKR_STATUS=ok; BKR_REPOS=' demo'; BKR_OVERDUE=0; BKR_AGE=16400;
      BKR_NOW=2000000000; BKR_CLOCK=server; return ${2:-0}; }"
_CHECK_PASS=0; _CHECK_WARN=0; _CHECK_FAIL=0
_cs_b01_backup
printf 'counts=%s/%s/%s\n' "$_CHECK_PASS" "$_CHECK_WARN" "$_CHECK_FAIL"
B01
b01() { env KASBAH_LIB_DIR="$repo_dir/lib" NO_COLOR=1 bash "$b01_driver" "$@" 2>&1; }

out="$(b01 ok)"
assert 'grep -qF "✓ the last backup on deploy@vps finished 4h ago and succeeded" <<<"$out"' \
    "the stub reaches B01 at all — else every line below is theatre (said '$out')"
assert 'grep -qF "counts=1/0/0" <<<"$out"' "and lands on the pass counter (said '$out')"
for bogus in "" sideways; do
    out="$(b01 "$bogus")"
    assert 'grep -qF "the backup record reader returned" <<<"$out"' \
        "a verdict of '${bogus:-<empty>}' is reported as unknown (said '$out')"
    assert '! grep -qF "✓" <<<"$out"' "and never as a backup that worked (said '$out')"
    assert 'grep -qF "counts=0/1/0" <<<"$out"' "as a warning, not a pass (said '$out')"
done
out="$(b01 "" 1)"
assert 'grep -qF "(exit 1)" <<<"$out"' \
    "with the reader's own exit status, which B01 captured rather than letting errexit have (said '$out')"

# --- Case S14: a repository with no password ------------------------------------
# The runner refuses to back one up, so the *next* run's record reads `failed` —
# but between a deploy creating a project and 02:00 the record still says `ok`
# while `server status` is already printing "no password". Both readers answer
# out of one `_bk_repo_set`, at the same moment, so they cannot disagree for a
# day.
bk_srv dir file "$bk_ok"
BK_PROJECTS="demo= other=" BK_HASPASS="demo mail"
write_check_payload
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "0" ]' "a repository with no password warns rather than failing (rc $rc)
$out"
assert 'grep -qF "⚠ backup repositories on deploy@vps with no password: other" <<<"$out"' \
    "naming it, on the same run whose record still says the last backup worked (said '$out')"
assert 'grep -qF "✓ the last backup on deploy@vps" <<<"$out"' \
    "and both facts are printed, because both are true (said '$out')"
# Two projects sharing a client are one repository, and mail is one of its own:
# the repository set is server init's answer, not a second list.
BK_PROJECTS="demo=acme other=acme" BK_HASPASS="acme"
write_check_payload
out="$(check_cli "$srv1" --server deploy@vps)"
assert 'grep -qF "with no password: mail" <<<"$out"' \
    "the mail repository is one of them (said '$out')"
assert '! grep -qF "no password: acme" <<<"$out"' \
    "and two projects declaring one client are not two (said '$out')"
BK_MAIL=no
write_check_payload
out="$(check_cli "$srv1" --server deploy@vps)"
assert '! grep -qF "with no password" <<<"$out"' \
    "a server with no mail stack needs no mail repository (said '$out')"

# --- Case S14b: a repository password nothing files into any more ----------------
# The other direction, which nothing walked at all. `drop --prune` takes a
# project's directory and its data and never its client's password, so removing
# a client's *last* project leaves a restic password at mode 600 that no
# reporting command named — while `server backup-prune` went on discovering and
# pruning that repository, because it reads repos/*.pass off the disk.
bk_srv dir file "$bk_ok"
BK_PROJECTS="demo=" BK_HASPASS="demo acme" BK_MAIL=no
write_check_payload
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "0" ]' "an orphaned repository password warns rather than failing (rc $rc)
$out"
assert 'grep -qF "⚠ backup repository passwords on deploy@vps that no project files into any more: acme" <<<"$out"' \
    "naming it (said '$out')"
assert 'grep -qF "kasbah never deletes one" <<<"$out"' \
    "and saying kasbah keeps it — deleting it makes the snapshots already off-box
        unreadable, which is the opposite of what this feature is for (said '$out')"
assert '! grep -qF "into any more: demo" <<<"$out"' \
    "while a repository that does have a project is not an orphan (said '$out')"
# The paired negative, one fact changed: give the orphan a project and the
# warning goes. Otherwise "it warned" would pass on a rule that always does.
BK_PROJECTS="demo= other=acme"
write_check_payload
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "0" ]' "and the same server with that project back is clean (rc $rc)"
assert '! grep -qF "no project files into any more" <<<"$out"' \
    "with no orphan reported (said '$out')"
# And the state that produces it: the client's last project is gone, so the
# server has no repositories at all — the early return this rule used to take
# before it ever looked.
BK_PROJECTS="" BK_HASPASS="acme"
write_check_payload
out="$(check_cli "$srv1" --server deploy@vps)"
assert 'grep -qF "into any more: acme" <<<"$out"' \
    "a server with no repositories left still names the password the drop left (said '$out')"
BK_MAIL=no

# --- Case S15: the scheduler container ------------------------------------------
# `docker compose -p kasbah-backup down` leaves the last `sleeping` record
# looking valid for about a day. A container that is not running is an
# observation and not an absence, which is why it is allowed to fail.
for down_state in absent exited created; do
    bk_srv dir file "$bk_ok"
    BK_C_STATE="$down_state" BK_C_HEALTH=none
    write_check_payload
    out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
    assert '[ "$rc" = "6" ]' "a scheduler that is $down_state fails the check (rc $rc)
$out"
    assert 'grep -qF "✗ the backup scheduler on deploy@vps is $down_state, so nothing is being shipped off-box" <<<"$out"' \
        "saying so (said '$out')"
    assert '! grep -qF "✓ the last backup" <<<"$out"' \
        "and the record it left behind is not read as a working backup (said '$out')"
done
# A container of that name from some other compose project is not kasbah's.
bk_srv dir file "$bk_ok"
BK_C_STATE=notours BK_C_HEALTH=none
write_check_payload
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "6" ]' "a container merely named kasbah-backup is not the stack (rc $rc)"
assert 'grep -qF "is not in the kasbah-backup compose project" <<<"$out"' "saying so (said '$out')"
# Docker not answering is not a container that is down.
for unknown in nodocker nodaemon; do
    bk_srv dir file "$bk_ok"
    BK_C_STATE="$unknown" BK_C_HEALTH="$unknown"
    write_check_payload
    out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
    assert '[ "$rc" = "0" ]' "with docker in state '$unknown' B01 warns rather than failing (rc $rc)
$out"
    assert 'grep -qF "cannot be read" <<<"$out"' "saying it could not tell (said '$out')"
    assert '! grep -qF "✗ the backup scheduler" <<<"$out"' \
        "and never claims the scheduler is down (said '$out')"
done

# --- Case S16: a run that succeeded and shipped nothing --------------------------
# `back_up_repo` returns 0 for a repository with no paths, so a run can end
# `ok` with `last_run_repos= none` — a server where nothing left the box. A
# backup-enabled server with no projects yet is the ordinary instance.
bk_srv dir file "$(bk_rec sleeping 2000086400 2000082800 1999990000 1999980000 1999983600 ok ' none')"
BK_PROJECTS="" BK_MAIL=no BK_HASPASS=""
write_check_payload
out="$(check_cli "$srv1" --server deploy@vps)"; rc=$?
assert '[ "$rc" = "0" ]' "a run that shipped nothing warns rather than failing (rc $rc)
$out"
assert 'grep -qF "⚠ the last backup on deploy@vps finished 4h ago and shipped nothing" <<<"$out"' \
    "saying so (said '$out')"
assert 'grep -qF "nothing of this server exists off-box yet" <<<"$out"' \
    "and what that means (said '$out')"
assert '! grep -qF "✓ the last backup" <<<"$out"' \
    "rather than a tick for a backup that backed nothing up (said '$out')"

BK_DIR_STATE=absent BK_STATUS_STATE=absent BK_RECORD=""
BK_HASPASS="" BK_PROJECTS="" BK_MAIL=no BK_C_STATE=absent BK_C_HEALTH=none
write_marker
write_check_payload


# =============================================================================
# `check --fix` — the auto-fixable half of docs/compliance.md
# =============================================================================
# Two things every case here does on purpose.
#
# Whole files are compared with `cmp`, never through `$(cat …)`: command
# substitution strips trailing newlines, so a fix that appended one per run
# would compare equal for ever — which is exactly how 8.3 shipped a file that
# grew a newline every time (docs/phases/08-keep.md → 8.3).
#
# And each `before` carries comments above, inside and below the block being
# edited, blank lines, and hand-spacing, because the whole reason --fix is a
# line editor rather than a yq round trip is that those survive it. An
# assertion that only checked the rule now passes would be satisfied by a
# reformatter.

# fx_project DIR — the make_project scaffold (manifest, template, .gitignore and
# a fragment routing demo-web) with compose.prod.yml taken from stdin.
fx_project() {
    local dir="$1"
    make_project "$dir"
    cat > "$dir/compose.prod.yml"
}

fx_run() { (cd "$1" && "$kasbah" check --fix --yes 2>&1); }

# --- Case F1: C01 into a service written around comments and blank lines -----
f1="$tmpdir/fix-c01"
fx_project "$f1" <<'YAML'
# file header comment
services:

  # above the service
  demo-web:
    # inside, above image
    image: nginx:alpine
    container_name: demo-web

    # inside, near the end
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    networks: [kasbah-net]
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

# below everything
networks:
  kasbah-net:
    external: true
YAML
cat > "$f1/expected" <<'YAML'
# file header comment
services:

  # above the service
  demo-web:
    # inside, above image
    image: nginx:alpine
    container_name: demo-web

    # inside, near the end
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    networks: [kasbah-net]
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    restart: unless-stopped

# below everything
networks:
  kasbah-net:
    external: true
YAML
out="$(fx_run "$f1")"; rc=$?
assert '[ "$rc" = "0" ]' "F1: the fixed project passes (rc $rc)
$out"
assert 'grep -qF "C01 demo-web — add restart: unless-stopped" <<<"$out"' \
    "F1: the plan names the rule and the service (said '$out')"
assert 'cmp -s "$f1/compose.prod.yml" "$f1/expected"' \
    "F1: one inserted line and nothing else$(diff -u "$f1/expected" "$f1/compose.prod.yml" 2>&1 || true)"

# --- Case F2: C02 repaired key by key, so interior comments survive ----------
# A wrong driver, a missing max-size and a whole missing block, in one file. The
# partially-wrong service is the interesting one: replacing its logging: wholesale
# would be simpler code and would eat both comments inside it.
f2="$tmpdir/fix-c02"
fx_project "$f2" <<'YAML'
services:
  demo-web:
    image: nginx:alpine
    container_name: demo-web
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    networks: [kasbah-net]
    logging:
      # why this project rotates the way it does
      driver: syslog
      options:
        # the second one matters more than the first
        max-file: "3"

  demo-worker:
    image: busybox
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    # no logging block at all
    command: ["sleep", "1000"]

networks:
  kasbah-net:
    external: true
YAML
cat > "$f2/expected" <<'YAML'
services:
  demo-web:
    image: nginx:alpine
    container_name: demo-web
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    networks: [kasbah-net]
    logging:
      # why this project rotates the way it does
      driver: json-file
      options:
        # the second one matters more than the first
        max-file: "3"
        max-size: "10m"

  demo-worker:
    image: busybox
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    # no logging block at all
    command: ["sleep", "1000"]
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  kasbah-net:
    external: true
YAML
out="$(fx_run "$f2")"; rc=$?
assert '[ "$rc" = "0" ]' "F2: the fixed project passes (rc $rc)
$out"
assert 'cmp -s "$f2/compose.prod.yml" "$f2/expected"' \
    "F2: driver rewritten, max-size added, both interior comments in place$(diff -u "$f2/expected" "$f2/compose.prod.yml" 2>&1 || true)"
# The positive that pins the same mechanism as the comment survival: the author
# wrote max-file first and it is still first, which a block replaced wholesale
# could not manage — the canonical block this would have written puts max-size
# ahead of it. Line numbers, because "the line exists" is satisfied by a rewrite
# that happens to contain it.
f2_mf="$(grep -n 'max-file' "$f2/compose.prod.yml" | head -1 | cut -d: -f1)"
f2_ms="$(grep -n 'max-size' "$f2/compose.prod.yml" | head -1 | cut -d: -f1)"
assert '[ -n "$f2_mf" ] && [ -n "$f2_ms" ] && [ "$f2_mf" -lt "$f2_ms" ]' \
    "F2: the author's key order survived — max-file (line $f2_mf) still precedes max-size (line $f2_ms)"

# --- Case F3: R03's cascade, C05, and C08's tag rewrite ----------------------
# demo-web keeps a `deploy:` that holds something else; demo-worker's holds
# nothing else and goes entirely. The image carries a registry port, which is a
# colon that is not the tag.
f3="$tmpdir/fix-r03"
fx_project "$f3" <<'YAML'
# a comment above version, which stays: a header and a key comment cannot be
# told apart, and eating a file header would be worse than one stale line
version: "3.8"

services:
  demo-web:
    build:
      context: .
    image: "registry.example:5000/demo-web:1.4.2"   # pinned by hand # twice
    container_name: demo-web
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    networks: [kasbah-net]
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    deploy:
      replicas: 1
      resources:
        limits:
          cpus: "1"
        reservations:
          cpus: "0.25"
          memory: 64M

  demo-side:
    build:
      context: ./side
    image: registry.example:5000/demo-side
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  demo-worker:
    image: busybox
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    mem_reservation: 128m
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    deploy:
      resources:
        reservations:
          memory: 32M

networks:
  kasbah-net:
    external: true
YAML
cat > "$f3/expected" <<'YAML'
# a comment above version, which stays: a header and a key comment cannot be
# told apart, and eating a file header would be worse than one stale line

services:
  demo-web:
    build:
      context: .
    image: "registry.example:5000/demo-web:current"   # pinned by hand # twice
    container_name: demo-web
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    networks: [kasbah-net]
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    deploy:
      replicas: 1
      resources:
        limits:
          cpus: "1"

  demo-side:
    build:
      context: ./side
    image: registry.example:5000/demo-side:current
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  demo-worker:
    image: busybox
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  kasbah-net:
    external: true
YAML
out="$(fx_run "$f3")"; rc=$?
assert '[ "$rc" = "0" ]' "F3: the fixed project passes (rc $rc)
$out"
assert 'grep -qF "C08 demo-web — image: registry.example:5000/demo-web:1.4.2 → registry.example:5000/demo-web:current" <<<"$out"' \
    "F3: the pinned tag is replaced, and the registry port left alone (said '$out')"
# demo-side is the case that tells `image_base` apart from stripping at the last
# colon: there is no tag, so the only colon in the reference is the registry
# port, and `${img%:*}` would tag the registry itself.
assert 'grep -qF "C08 demo-side — image: registry.example:5000/demo-side → registry.example:5000/demo-side:current" <<<"$out"' \
    "F3: an untagged image behind a registry port keeps its port (said '$out')"
assert 'grep -qF "R03 demo-worker — remove deploy (it held nothing else)" <<<"$out"' \
    "F3: an emptied deploy: goes with the reservations it held (said '$out')"
assert 'grep -qF "   # pinned by hand # twice" "$f3/compose.prod.yml"' \
    "F3: the rewritten line keeps its trailing comment, both halves of it"
assert 'cmp -s "$f3/compose.prod.yml" "$f3/expected"' \
    "F3: quotes, the trailing comment, the surviving deploy: and the header all as written$(diff -u "$f3/expected" "$f3/compose.prod.yml" 2>&1 || true)"

# --- Case F4: CRLF, four-space indentation, and a networks mapping ----------
# The file's own line ending and its own indentation step are what inserted
# lines take, so a Windows-authored 4-space compose comes back as one.
f4="$tmpdir/fix-crlf"
fx_project "$f4" <<'YAML'
# a CRLF file
services:
    demo-web:
        image: nginx:alpine
        container_name: demo-web
        restart: unless-stopped
        cpus: ${KASBAH_CPU_LIMIT}
        mem_limit: ${KASBAH_MEM_LIMIT}
        networks:
            internal: {}
        logging:
            driver: json-file
            options:
                max-size: "10m"
                max-file: "3"

networks:
    internal: {}
YAML
sed -i 's/$/\r/' "$f4/compose.prod.yml"
cat > "$f4/expected" <<'YAML'
# a CRLF file
services:
    demo-web:
        image: nginx:alpine
        container_name: demo-web
        restart: unless-stopped
        cpus: ${KASBAH_CPU_LIMIT}
        mem_limit: ${KASBAH_MEM_LIMIT}
        networks:
            internal: {}
            kasbah-net:
        logging:
            driver: json-file
            options:
                max-size: "10m"
                max-file: "3"

networks:
    internal: {}
    kasbah-net:
        external: true
YAML
sed -i 's/$/\r/' "$f4/expected"
out="$(fx_run "$f4")"; rc=$?
assert '[ "$rc" = "0" ]' "F4: the fixed project passes (rc $rc)
$out"
assert 'cmp -s "$f4/compose.prod.yml" "$f4/expected"' \
    "F4: CRLF kept and the file's own 4-space step used for the new nesting$(diff -u "$f4/expected" "$f4/compose.prod.yml" 2>&1 || true)"
# Paired with the byte comparison: a fix that wrote LF lines into a CRLF file
# would still parse and still satisfy C03/C04, so count the CRs directly.
assert '[ "$(tr -cd "\r" < "$f4/compose.prod.yml" | wc -c)" = "$(wc -l < "$f4/compose.prod.yml")" ]' \
    "F4: every line of the result still ends CRLF ($(tr -cd "\r" < "$f4/compose.prod.yml" | wc -c) CRs, $(wc -l < "$f4/compose.prod.yml") lines)"

# --- Case F5: the last service in the file, with no final newline -----------
f5="$tmpdir/fix-nonl"
fx_project "$f5" <<'YAML'
services:
  demo-web:
    image: nginx:alpine
    container_name: demo-web
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    networks:
      internal: {}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
YAML
truncate -s -1 "$f5/compose.prod.yml"
printf 'services:\n  demo-web:\n    image: nginx:alpine\n    container_name: demo-web\n    restart: unless-stopped\n    cpus: ${KASBAH_CPU_LIMIT}\n    mem_limit: ${KASBAH_MEM_LIMIT}\n    networks:\n      internal: {}\n      kasbah-net:\n    logging:\n      driver: json-file\n      options:\n        max-size: "10m"\n        max-file: "3"\n\nnetworks:\n  kasbah-net:\n    external: true' > "$f5/expected"
out="$(fx_run "$f5")"; rc=$?
assert '[ "$rc" = "0" ]' "F5: the fixed project passes (rc $rc)
$out"
assert 'cmp -s "$f5/compose.prod.yml" "$f5/expected"' \
    "F5: a block appended at EOF, and the missing final newline still missing$(diff -u "$f5/expected" "$f5/compose.prod.yml" 2>&1 || true)"
assert '[ "$(tail -c 1 "$f5/compose.prod.yml" | wc -l)" = "0" ]' \
    "F5: the file still ends mid-line, as its author left it"

# --- Case F6: --fix is idempotent -------------------------------------------
# Run it again over every file the cases above left behind and compare bytes.
# `cmp`, not `$(cat …)`: the failure this guards against is a file that gains a
# newline per run, and command substitution cannot see that at all.
for d in "$f1" "$f2" "$f3" "$f4" "$f5"; do
    cp "$d/compose.prod.yml" "$d/first-run"
    cp "$d/kasbah.yml" "$d/first-run-manifest"
    out="$(fx_run "$d")"; rc=$?
    assert '[ "$rc" = "0" ]' "F6 ($(basename "$d")): the second run still passes (rc $rc)"
    assert 'grep -qF "nothing --fix can change" <<<"$out"' \
        "F6 ($(basename "$d")): the second run finds nothing to do (said '$out')"
    assert 'cmp -s "$d/compose.prod.yml" "$d/first-run"' \
        "F6 ($(basename "$d")): compose.prod.yml is byte-identical after a second --fix"
    assert 'cmp -s "$d/kasbah.yml" "$d/first-run-manifest"' \
        "F6 ($(basename "$d")): kasbah.yml is byte-identical after a second --fix"
done

# --- Case F7: the kasbah_version backfill, and only when it is missing -------
f7="$tmpdir/fix-manifest"
make_project "$f7"
grep -v '^kasbah_version:' "$f7/kasbah.yml" > "$f7/k.next" && mv "$f7/k.next" "$f7/kasbah.yml"
cp "$f7/kasbah.yml" "$f7/before"
out="$(fx_run "$f7")"; rc=$?
assert '[ "$rc" = "0" ]' "F7: the backfilled project passes (rc $rc)
$out"
assert 'grep -qxF "kasbah_version: $(cat "$repo_dir/VERSION")" "$f7/kasbah.yml"' \
    "F7: the manifest now names this kasbah ($(cat "$f7/kasbah.yml"))"
assert '[ "$(grep -c "^schema: 1$" "$f7/kasbah.yml")" = 1 ]' \
    "F7: written after schema:, which is still there exactly once"
# The rest of the manifest is untouched: same bytes with that one line removed.
grep -v '^kasbah_version:' "$f7/kasbah.yml" > "$f7/stripped"
assert 'cmp -s "$f7/stripped" "$f7/before"' \
    "F7: nothing else in kasbah.yml moved$(diff -u "$f7/before" "$f7/stripped" 2>&1 || true)"
# A manifest that already names a version keeps the one it names — the rule is
# "if missing", and a version already written is the author's statement.
f7b="$tmpdir/fix-manifest-present"
make_project "$f7b"
sed -i 's/^kasbah_version: .*/kasbah_version: 0.0.1/' "$f7b/kasbah.yml"
cp "$f7b/kasbah.yml" "$f7b/before"
out="$(fx_run "$f7b")"
assert 'cmp -s "$f7b/kasbah.yml" "$f7b/before"' \
    "F7: an existing kasbah_version is not overwritten"
assert 'grep -qxF "kasbah_version: 0.0.1" "$f7b/kasbah.yml"' \
    "F7: and it still says what the author wrote"

# --- Case F8: what --fix will not do ----------------------------------------
# A project failing C07, C09, T02, T03, T05, HK01 and C08-by-absence. The
# fixable rules are fixed; every one of those is still failing afterwards, still
# reported, and the run still exits 6.
f8="$tmpdir/fix-unfixable"
fx_project "$f8" <<'YAML'
services:
  web:
    image: nginx:alpine
    container_name: demo-web
    networks: [kasbah-net]
  cache:
    image: redis:7
    container_name: demo-cache
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    networks: [kasbah-net]
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
  builder:
    build: .
    container_name: demo-builder
    restart: always
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  kasbah-net:
    external: true
YAML
{
    printf 'http:\n  routers:\n    demo:\n      rule: "Host(`traefik.example.com`)"\n'
    printf '      service: demo\n  services:\n    demo:\n      loadBalancer:\n'
    printf '        servers:\n          - url: "http://demo-web:80"\n'
} > "$f8/traefik-dynamic.yml"
printf 'hooks:\n  post-deploy:\n    - "nope echo hi"\n' >> "$f8/kasbah.yml"
out="$(fx_run "$f8")"; rc=$?
assert '[ "$rc" = "6" ]' "F8: the unfixable failures still fail the run (rc $rc)
$out"
assert 'grep -qF "C01 web — add restart: unless-stopped" <<<"$out"' \
    "F8: what it could fix, it fixed (said '$out')"
assert 'grep -qF "C08 builder — builds an image but names no image:" <<<"$out"' \
    "F8: and says which one it declined, with the reason (said '$out')"
assert 'grep -qF "✗ Non-routed services on kasbah-net: cache" <<<"$out"'   "F8: C07 still reported"
assert 'grep -qF "Services on kasbah-net whose name is not" <<<"$out"'      "F8: C09 still reported"
assert 'grep -qF "✗ No router rule references manifest domain" <<<"$out"'   "F8: T02 still reported"
assert 'grep -qF "✗ Routers without entryPoints: demo" <<<"$out"'           "F8: T03 still reported"
assert 'grep -qF "✗ Routers claim reserved hostnames" <<<"$out"'            "F8: T05 still reported"
assert 'grep -qF "✗ Hooks reference unknown container_names: nope" <<<"$out"' "F8: HK01 still reported"
# The paired positive: those rules were not merely *reported* untouched, the
# file really is untouched where they live. A --fix that had renamed `cache` or
# rewritten the fragment would satisfy every grep above by making them pass.
assert 'grep -qxF "  cache:" "$f8/compose.prod.yml"'   "F8: the generically-named service was not renamed"
assert 'grep -qF "traefik.example.com" "$f8/traefik-dynamic.yml"' "F8: the fragment was not rewritten"
assert 'grep -qF "nope echo hi" "$f8/kasbah.yml"'      "F8: the hook command was not rewritten"
assert 'grep -qF "    build: ." "$f8/compose.prod.yml"' "F8: no image: was invented for the built service"
assert '! grep -q "image: builder" "$f8/compose.prod.yml"' "F8: nor one named after the service"

# --- Case F9: a file that will not parse is not a file to rewrite ------------
f9="$tmpdir/fix-malformed"
make_project "$f9"
printf 'services:\n  web:\n   image: [oops\n' > "$f9/compose.prod.yml"
cp "$f9/compose.prod.yml" "$f9/before"
out="$(fx_run "$f9")"; rc=$?
assert '[ "$rc" = "6" ]' "F9: a malformed compose still fails the check (rc $rc)"
assert 'grep -qF "does not parse as YAML — --fix will not pattern-match" <<<"$out"' \
    "F9: --fix says why it refused (said '$out')"
assert 'cmp -s "$f9/compose.prod.yml" "$f9/before"' \
    "F9: and the file is byte-identical afterwards"
assert '[ -z "$(find "$f9" -name "*.kasbah-fix.*" -print -quit)" ]' \
    "F9: no candidate file left in the project tree"

# --- Case F10: the diff is a decision, so it is asked ------------------------
# docs/overview.md → Interactivity: an unset flag means prompt. Without a
# terminal and without --yes the run stops naming the flag, and writes nothing.
f10="$tmpdir/fix-prompt"
fx_project "$f10" <<'YAML'
services:
  demo-web:
    image: nginx:alpine
    container_name: demo-web
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    networks: [kasbah-net]
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  kasbah-net:
    external: true
YAML
cp "$f10/compose.prod.yml" "$f10/before"
out="$(cd "$f10" && "$kasbah" check --fix </dev/null 2>&1)"; rc=$?
assert '[ "$rc" = "1" ]' "F10: no terminal and no --yes is a hard fail (rc $rc)"
assert 'grep -qF "cannot ask: Apply these edits?" <<<"$out"' \
    "F10: naming the question (said '$out')"
assert 'grep -qF "pass --yes instead" <<<"$out"' \
    "F10: and the flag that answers it (said '$out')"
assert 'grep -qF "+    restart: unless-stopped" <<<"$out"' \
    "F10: the diff was shown before the question, not after (said '$out')"
assert 'cmp -s "$f10/compose.prod.yml" "$f10/before"' \
    "F10: an unanswered prompt writes nothing"
assert '[ -z "$(find "$f10" -name "*.kasbah-fix.*" -print -quit)" ]' \
    "F10: and leaves no candidate behind"
# --yes on its own answers nothing, and a flag that silently does nothing is
# worse than one that is refused.
out="$(cd "$f10" && "$kasbah" check --yes 2>&1)"; rc=$?
assert '[ "$rc" = "1" ]' "F10: --yes without --fix is refused (rc $rc)"
assert 'grep -qF "it does nothing on its own" <<<"$out"' "F10: saying so (said '$out')"
# The paired positive: the same project with --yes *and* --fix is written.
out="$(fx_run "$f10")"; rc=$?
assert '[ "$rc" = "0" ]' "F10: --fix --yes applies the same edits (rc $rc)
$out"
assert '! cmp -s "$f10/compose.prod.yml" "$f10/before"' "F10: and the file did change"
assert 'grep -qF "  wrote compose.prod.yml" <<<"$out"' "F10: and it says which file (said '$out')"
assert '[ -z "$(find "$f10" -name "*.kasbah-fix.*" -print -quit)" ]' \
    "F10: with no candidate left over"

# --- Case F11: the real fixture, broken every fixable way, comes back clean --
# tests/fixtures/demo is a compose file whose comments carry the reasoning for
# every choice in it. It is broken here in the awkward shapes an operator would
# leave — a literal cpus:, a flow-mapping network, a removed logging block — and
# has to come back to exit 0 with all of that prose still in it.
f11="$tmpdir/fix-fixture"
mkdir -p "$f11"
cp -a "$repo_dir/tests/fixtures/demo/." "$f11/"
printf '.env\n.kasbah/\n' > "$f11/.gitignore"
comments_before="$(grep -c '#' "$f11/compose.prod.yml")"
# Line-oriented on purpose: sed, so the suite needs nothing yq does not already
# bring, and so the breakage is legible next to the fixture it is applied to.
sed -i -e '1i version: "3.7"' \
       -e '/^    restart: unless-stopped$/d' \
       -e 's/^    cpus: ${KASBAH_CPU_LIMIT}$/    cpus: "0.5"/' \
       -e 's/^    mem_limit: ${KASBAH_MEM_LIMIT}$/    mem_limit: 512m/' \
       -e '/^      - kasbah-net$/d' \
       -e '/^    logging:$/,/^        max-file: "3"$/d' \
       -e 's/^  kasbah-net:$/  kasbah-net: {}/' \
       -e '/^    external: true$/d' \
       "$f11/compose.prod.yml"
sed -i '/^    mem_limit: 512m$/a\    mem_reservation: 64m' "$f11/compose.prod.yml"
grep -v '^kasbah_version:' "$f11/kasbah.yml" > "$f11/k.next" && mv "$f11/k.next" "$f11/kasbah.yml"
out="$(cd "$f11" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]' "F11: the broken fixture fails first (rc $rc)"
assert '[ "$comments_before" -ge 20 ]' \
    "F11: the fixture really does carry prose to lose ($comments_before comment lines)"
out="$(fx_run "$f11")"; rc=$?
assert '[ "$rc" = "0" ]' "F11: and --fix takes it to a clean run (rc $rc)
$out"
assert 'grep -qF "0 failed" <<<"$out"' "F11: with nothing failing (said '$out')"
assert '[ "$(grep -c "#" "$f11/compose.prod.yml")" = "$comments_before" ]' \
    "F11: every one of the $comments_before comment lines survived (found $(grep -c '#' "$f11/compose.prod.yml"))"
assert 'grep -qF "compose publishes the service name" "$f11/compose.prod.yml"' \
    "F11: including the one inside the block that was edited"
assert 'grep -qF "kasbah-net alone, which is what \`init-project\` scaffolds" "$f11/compose.prod.yml"' \
    "F11: and the one inside the networks list that gained a member"

# --- Case F12: a compliant project is left byte-identical --------------------
# The control that makes F11 mean something: --fix that rewrote every file it
# read would pass F11 just as well.
f12="$tmpdir/fix-compliant"
mkdir -p "$f12"
cp -a "$repo_dir/tests/fixtures/demo/." "$f12/"
printf '.env\n.kasbah/\n' > "$f12/.gitignore"
cp "$f12/compose.prod.yml" "$f12/before"
cp "$f12/kasbah.yml" "$f12/before-manifest"
out="$(fx_run "$f12")"; rc=$?
assert '[ "$rc" = "0" ]' "F12: the untouched fixture passes (rc $rc)
$out"
assert 'grep -qF "nothing --fix can change" <<<"$out"' "F12: and --fix says so (said '$out')"
assert 'cmp -s "$f12/compose.prod.yml" "$f12/before"' "F12: compose.prod.yml byte-identical"
assert 'cmp -s "$f12/kasbah.yml" "$f12/before-manifest"' "F12: kasbah.yml byte-identical"

# --- Case F13: --fix is an addition, not a change to the report -------------
# The report a plain `kasbah check` prints is exactly what it printed before the
# flag existed: on a project with nothing to fix, the --fix run is that same
# report with a Fix block in front of it, and the same exit code.
out_plain="$(cd "$f12" && "$kasbah" check 2>&1)"; rc_plain=$?
out_fix="$(cd "$f12" && "$kasbah" check --fix --yes 2>&1)"; rc_fix=$?
out_stripped="$(sed '/^Fix:$/,/^$/d' <<<"$out_fix")"
assert '[ "$rc_plain" = "$rc_fix" ]' "F13: same exit code ($rc_plain vs $rc_fix)"
assert '[ "$out_plain" = "$out_stripped" ]' \
    "F13: same report, line for line$(diff -u <(printf '%s\n' "$out_plain") <(printf '%s\n' "$out_stripped") 2>&1 || true)"
# Paired with it, so "equal" cannot be equal-because-nothing-was-removed: the
# plain run has no Fix block at all, and the --fix run does.
assert '! grep -q "^Fix:$" <<<"$out_plain"' "F13: a plain check prints no Fix block"
assert 'grep -q "^Fix:$" <<<"$out_fix"'     "F13: and a --fix run does"
assert '[ "$out_fix" != "$out_stripped" ]'  "F13: so the strip above removed something"
out="$(cd "$f12" && "$kasbah" check --help 2>&1)"
assert 'grep -qF -- "--fix " <<<"$out"' "F13: --help documents --fix (said '$out')"
assert '! grep -qF "not yet wired in" <<<"$out"' "F13: and no longer says it is unimplemented"

# The same equality on a project that *fails*, since a clean project exercises
# none of the ✗ lines and none of the exit-6 path. $f8 has been through --fix
# already, so it has nothing left to fix and everything left to report.
out_plain="$(cd "$f8" && "$kasbah" check 2>&1)"; rc_plain=$?
out_fix="$(cd "$f8" && "$kasbah" check --fix --yes 2>&1)"; rc_fix=$?
out_stripped="$(sed '/^Fix:$/,/^$/d' <<<"$out_fix")"
assert '[ "$rc_plain" = "6" ]' "F13: the failing project still exits 6 without --fix (rc $rc_plain)"
assert '[ "$rc_plain" = "$rc_fix" ]' "F13: and with it ($rc_plain vs $rc_fix)"
assert '[ "$out_plain" = "$out_stripped" ]' \
    "F13: the failing report is the same line for line$(diff -u <(printf '%s\n' "$out_plain") <(printf '%s\n' "$out_stripped") 2>&1 || true)"
assert '[ "$(grep -c "✗" <<<"$out_plain")" -ge 5 ]' \
    "F13: and it really is a failing report ($(grep -c "✗" <<<"$out_plain") ✗ lines)"
assert '[ "$out_fix" != "$out_stripped" ]' "F13: the strip removed a Fix block here too"

# --- Case F14: three insertions anchored on one line, and an implicit network -
# demo-web's last content line is the last line of its logging.options, so the
# two service-level keys and the options entry are all anchored there and have
# to come out deepest-first: a `restart:` emitted at the options' indentation
# would be a logging option called restart, and it would still parse.
#
# The same service declares no networks: at all, which means compose's implicit
# default. C03 adds kasbah-net there by writing `default` alongside it — joining
# the shared network must not quietly take the service off the one it had, which
# is the topology guess C07 exists because kasbah will not make.
f14="$tmpdir/fix-anchors"
fx_project "$f14" <<'YAML'
services:
  demo-web:
    image: nginx:alpine
    container_name: demo-web
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-file: "3"
YAML
cat > "$f14/expected" <<'YAML'
services:
  demo-web:
    image: nginx:alpine
    container_name: demo-web
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-file: "3"
        max-size: "10m"
    restart: unless-stopped
    networks:
      - default
      - kasbah-net

networks:
  kasbah-net:
    external: true
YAML
out="$(fx_run "$f14")"; rc=$?
assert '[ "$rc" = "0" ]' "F14: the fixed project passes (rc $rc)
$out"
assert 'cmp -s "$f14/compose.prod.yml" "$f14/expected"' \
    "F14: deepest-first, and the implicit default written out$(diff -u "$f14/expected" "$f14/compose.prod.yml" 2>&1 || true)"
# Paired positives, so the byte comparison is not the only thing holding these
# two properties up. Both would still parse if they were wrong: `restart` as a
# logging option is legal YAML, and dropping `default` is legal compose.
assert '[ "$(yq -r ".services[\"demo-web\"].restart" "$f14/compose.prod.yml")" = "unless-stopped" ]' \
    "F14: restart landed on the service, not inside logging.options"
assert '[ "$(yq -r ".services[\"demo-web\"].logging.options | keys | length" "$f14/compose.prod.yml")" = "2" ]' \
    "F14: and logging.options gained exactly the one key it was missing"
assert '[ "$(yq -r ".services[\"demo-web\"].networks | join(\",\")" "$f14/compose.prod.yml")" = "default,kasbah-net" ]' \
    "F14: the service is on kasbah-net and still on the default it had"
assert 'grep -qF "default spelled out so the service keeps the network it had" <<<"$out"' \
    "F14: and the plan says why (said '$out')"

# --- Case F15: rewritten in place, never appended beside ---------------------
# Every rule here fails on a value rather than on a missing key, so the repair
# is a rewrite of the line that is already there. Appending the right key next
# to the wrong one would satisfy the rule just as well — compose and yq both
# take the last of two duplicate keys — and would leave a file saying two
# things. Hence the per-key counts below, which are what tell the two apart.
f15="$tmpdir/fix-rewrite"
fx_project "$f15" <<'YAML'
services:
  demo-web:
    image: nginx:alpine
    container_name: demo-web
    restart: "no"     # compose's default, spelled out
    cpus: "0.5"
    mem_limit: 512m   # sized for the old box
    networks: [kasbah-net]
    logging:
      driver: local
      options:
        max-size:
        max-file: "3"

networks:
  kasbah-net:
    external: false
YAML
cat > "$f15/expected" <<'YAML'
services:
  demo-web:
    image: nginx:alpine
    container_name: demo-web
    restart: "unless-stopped"     # compose's default, spelled out
    cpus: "${KASBAH_CPU_LIMIT}"
    mem_limit: ${KASBAH_MEM_LIMIT}   # sized for the old box
    networks: [kasbah-net]
    logging:
      driver: json-file
      options:
        max-size: 10m
        max-file: "3"

networks:
  kasbah-net:
    external: true
YAML
out="$(fx_run "$f15")"; rc=$?
assert '[ "$rc" = "0" ]' "F15: the fixed project passes (rc $rc)
$out"
assert 'cmp -s "$f15/compose.prod.yml" "$f15/expected"' \
    "F15: five values rewritten where they stood, quoting and the comment kept$(diff -u "$f15/expected" "$f15/compose.prod.yml" 2>&1 || true)"
# Each key appears exactly once. Without these, a --fix that appended
# `restart: unless-stopped` under the `restart: "no"` it was supposed to correct
# would pass every rule and every yq lookup above.
for key in restart cpus mem_limit max-size driver external; do
    assert '[ "$(grep -c "^ *$key:" "$f15/compose.prod.yml")" = 1 ]' \
        "F15: '$key' is written once, not twice ($(grep -c "^ *$key:" "$f15/compose.prod.yml") lines)"
done
assert 'grep -qF "C01 demo-web — restart: no → unless-stopped" <<<"$out"' \
    "F15: and the plan says it rewrote rather than added (said '$out')"
# Both halves of the value/comment split are exercised here, and they are
# different code: `restart:` and `cpus:` are quoted values, scanned to their
# closing quote, while `mem_limit:` is a plain one, ended at the first `#` that
# follows a blank. Only the second keeps a trailing comment through a rewrite,
# so without this line nothing tests that path at all.
assert 'grep -qxF "    mem_limit: \${KASBAH_MEM_LIMIT}   # sized for the old box" "$f15/compose.prod.yml"' \
    "F15: an unquoted value keeps its trailing comment, spacing included"

# --- Case F16: block scalars are text, and the scanner has to know it --------
# `_cf_block_end` walks past blank and comment lines to find a block's last
# content line. Under a `|` or `>` header those lines are not blanks and
# comments, they are the value — so without a rule for it the block's "last
# line" lands in the middle of a shell script and an insertion is spliced into
# it. That splice parses, keeps every top-level and service key, and settles, so
# every guard downstream waves it through while two lines vanish from a string.
#
# Three shapes in one file, and the last-key ones are the ones that bite:
#   demo-mid   a scalar that is the service's *first* key, with more keys after
#              it — the case that already worked, pinned so it stays working,
#              and the witness for _cf_child_indent needing no rule of its own
#              (the header is reached before any of its content).
#   demo-web   a scalar that is the last key, ending in two comment lines.
#   demo-keep  a `|+` that is the last key, ending in two blank lines the header
#              keeps — those newlines are the value, so the insertion has to go
#              after them, not between them and the text.
f16="$tmpdir/fix-scalars"
fx_project "$f16" <<'YAML'
services:
  # the scalar comes first, and its content is deeper than its own header —
  # which is why finding a block's first child never walks into one
  demo-mid:
    entrypoint: |
      set -e
      # inside the scalar, and therefore not a comment
    image: nginx:alpine
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  demo-web:
    image: nginx:alpine
    container_name: demo-web
    networks: [kasbah-net]
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    entrypoint: |
      set -e
      nginx -g 'daemon off;'
      # the trailing comment the author wrote
      # and a second one

  demo-keep:
    image: busybox
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    command: |+
      echo hi


networks:
  kasbah-net:
    external: true
YAML
# The three values as YAML sees them, read *before* the fix so the comparison
# below is against what the author wrote and not against what --fix produced.
f16_mid="$(yq -r '.services["demo-mid"].entrypoint'  "$f16/compose.prod.yml" | od -An -c)"
f16_web="$(yq -r '.services["demo-web"].entrypoint'  "$f16/compose.prod.yml" | od -An -c)"
f16_keep="$(yq -r '.services["demo-keep"].command'   "$f16/compose.prod.yml" | od -An -c)"
cat > "$f16/expected" <<'YAML'
services:
  # the scalar comes first, and its content is deeper than its own header —
  # which is why finding a block's first child never walks into one
  demo-mid:
    entrypoint: |
      set -e
      # inside the scalar, and therefore not a comment
    image: nginx:alpine
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    restart: unless-stopped

  demo-web:
    image: nginx:alpine
    container_name: demo-web
    networks: [kasbah-net]
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    entrypoint: |
      set -e
      nginx -g 'daemon off;'
      # the trailing comment the author wrote
      # and a second one
    restart: unless-stopped

  demo-keep:
    image: busybox
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    command: |+
      echo hi


    restart: unless-stopped
networks:
  kasbah-net:
    external: true
YAML
out="$(fx_run "$f16")"; rc=$?
assert '[ "$rc" = "0" ]' "F16: the fixed project passes (rc $rc)
$out"
assert 'cmp -s "$f16/compose.prod.yml" "$f16/expected"' \
    "F16: each restart: lands after its whole scalar, never inside one$(diff -u "$f16/expected" "$f16/compose.prod.yml" 2>&1 || true)"
# Paired with the byte comparison, and the assertion that actually names the
# damage: the splice is invisible in the *text* diff of a reviewer skimming it —
# it is the string's contents that lose two lines. Compared through od, so a
# `|+`'s trailing newlines count.
assert '[ "$(yq -r ".services[\"demo-mid\"].entrypoint" "$f16/compose.prod.yml" | od -An -c)" = "$f16_mid" ]' \
    "F16: demo-mid's scalar is the same string it was"
assert '[ "$(yq -r ".services[\"demo-web\"].entrypoint" "$f16/compose.prod.yml" | od -An -c)" = "$f16_web" ]' \
    "F16: demo-web's scalar kept the two comment lines that are its text"
assert '[ "$(yq -r ".services[\"demo-keep\"].command" "$f16/compose.prod.yml" | od -An -c)" = "$f16_keep" ]' \
    "F16: demo-keep's |+ kept the trailing newlines that are its value"
# And the negative that would otherwise be vacuous on its own: a `restart:` key
# spliced into a scalar becomes part of the string, so it must not be there.
assert '! grep -qF "restart" <<<"$(yq -r ".services[\"demo-web\"].entrypoint" "$f16/compose.prod.yml")"' \
    "F16: no compose key ended up inside the shell script"
cp "$f16/compose.prod.yml" "$f16/first-run"
out="$(fx_run "$f16")"; rc=$?
assert '[ "$rc" = "0" ]' "F16: and a second run still passes (rc $rc)"
assert 'cmp -s "$f16/compose.prod.yml" "$f16/first-run"' "F16: byte-identical after a second --fix"

# --- Case F17: a `#` inside a quoted value is not a comment ------------------
# YAML ends a plain scalar at a `#` that follows a blank; inside quotes it ends
# nothing. Splitting on the first `#` regardless writes the new value next to
# the tail of the old one's quoting, and the file then carries a stray `"` in
# what reads as a comment. The value is scanned to its closing quote instead,
# and a quote that never closes on the line is refused rather than guessed at.
f17="$tmpdir/fix-hash-in-value"
fx_project "$f17" <<'YAML'
services:
  demo-web:
    image: nginx:alpine
    container_name: demo-web
    networks: [kasbah-net]
    restart: unless-stopped
    cpus: '1.5 # measured on the old box'
    mem_limit: "512m # sized for the box"
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  kasbah-net:
    external: true
YAML
cat > "$f17/expected" <<'YAML'
services:
  demo-web:
    image: nginx:alpine
    container_name: demo-web
    networks: [kasbah-net]
    restart: unless-stopped
    cpus: '${KASBAH_CPU_LIMIT}'
    mem_limit: "${KASBAH_MEM_LIMIT}"
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  kasbah-net:
    external: true
YAML
out="$(fx_run "$f17")"; rc=$?
assert '[ "$rc" = "0" ]' "F17: the fixed project passes (rc $rc)
$out"
assert 'cmp -s "$f17/compose.prod.yml" "$f17/expected"' \
    "F17: both values replaced whole, and no quote left stranded$(diff -u "$f17/expected" "$f17/compose.prod.yml" 2>&1 || true)"
# The paired positive, because "the bytes match" would also hold if --fix had
# refused both and the expected file said so: yq has to read the references.
assert '[ "$(yq -r ".services[\"demo-web\"].cpus" "$f17/compose.prod.yml")" = "\${KASBAH_CPU_LIMIT}" ]' \
    "F17: cpus reads as the variable reference"
assert '[ "$(yq -r ".services[\"demo-web\"].mem_limit" "$f17/compose.prod.yml")" = "\${KASBAH_MEM_LIMIT}" ]' \
    "F17: mem_limit too"
assert '! grep -q "sized for the box" "$f17/compose.prod.yml"' \
    "F17: the old value went whole — no half of it survives as a comment"

# A quoted scalar that runs onto the next line cannot be split by looking at one
# line, so it is refused and the file is left exactly as it was.
f17b="$tmpdir/fix-multiline-quote"
fx_project "$f17b" <<'YAML'
services:
  demo-web:
    image: nginx:alpine
    container_name: demo-web
    networks: [kasbah-net]
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: "512m
      # this is a continuation, not a comment"
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  kasbah-net:
    external: true
YAML
cp "$f17b/compose.prod.yml" "$f17b/before"
out="$(fx_run "$f17b")"; rc=$?
assert '[ "$rc" = "6" ]' "F17: the unsplittable value still fails R02 (rc $rc)"
assert 'grep -qF "R02 demo-web — its mem_limit: is written in a shape --fix cannot rewrite" <<<"$out"' \
    "F17: and --fix says so rather than guessing (said '$out')"
assert 'cmp -s "$f17b/compose.prod.yml" "$f17b/before"' "F17: the file is byte-identical"
assert '! grep -qF "nothing --fix can change" <<<"$out"' \
    "F17: a run that refused something does not also claim there was nothing to change"

# --- Case F18: a candidate that cannot be written says so, and only that -----
# `chmod --reference` copies a read-only mode onto the candidate, and the
# redirection that then fails is reported by the shell before `2>/dev/null` is
# applied — a raw `Permission denied` in front of the tidy message. Running as
# root ignores the write bits entirely, so there is nothing to prove there.
if [ "$(id -u)" != 0 ]; then
    f18="$tmpdir/fix-readonly"
    fx_project "$f18" <<'YAML'
services:
  demo-web:
    image: nginx:alpine
    container_name: demo-web
    networks: [kasbah-net]
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  kasbah-net:
    external: true
YAML
    cp "$f18/compose.prod.yml" "$f18/before"
    # A read-only *file* in a writable directory: the candidate is written while
    # it is still writable, so the fix lands and the file keeps its mode.
    chmod a-w "$f18/compose.prod.yml"
    out="$(fx_run "$f18")"; rc=$?
    f18_mode="$(stat -c '%a' "$f18/compose.prod.yml")"
    chmod u+w "$f18/compose.prod.yml"
    assert '[ "$rc" = "0" ]' "F18: a read-only compose is still fixed (rc $rc)
$out"
    assert '! grep -q "Permission denied" <<<"$out"' \
        "F18: with no raw shell error in the output (said '$out')"
    assert 'grep -qF "restart: unless-stopped" "$f18/compose.prod.yml"' "F18: and the fix really landed"
    assert '[ "$f18_mode" = "444" ]' "F18: the file's mode came through the rename (was $f18_mode)"

    # A read-only *directory*: nothing can be written beside the file, so the
    # run refuses — one tidy message, the reason in the report, file untouched.
    f18b="$tmpdir/fix-readonly-dir"
    fx_project "$f18b" <<'YAML'
services:
  demo-web:
    image: nginx:alpine
    container_name: demo-web
    networks: [kasbah-net]
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  kasbah-net:
    external: true
YAML
    cp "$f18b/compose.prod.yml" "$f18b/before"
    chmod a-w "$f18b"
    out="$(fx_run "$f18b")"; rc=$?
    chmod u+w "$f18b"
    assert '[ "$rc" = "6" ]' "F18: an unwritable directory leaves the failures in place (rc $rc)"
    assert '! grep -q "Permission denied" <<<"$out"' \
        "F18: no raw shell error there either (said '$out')"
    assert 'grep -qF "cannot write beside compose.prod.yml" <<<"$out"' \
        "F18: the message kasbah wrote is the one shown (said '$out')"
    assert 'grep -qF "nothing could be written beside it" <<<"$out"' \
        "F18: and the report says which file was left alone (said '$out')"
    assert 'cmp -s "$f18b/compose.prod.yml" "$f18b/before"' "F18: the file is byte-identical"
    assert '[ -z "$(find "$f18b" -name "*.kasbah-fix.*" -print -quit)" ]' \
        "F18: and no candidate was left behind"
fi

# --- Case F19: the report describes the file --fix just wrote ----------------
# `--fix` renames its candidate over the real file and cmd_check then runs the
# whole rule set over that path. Documents are converted once per file per phase
# and nothing watches mtimes (lib/common.sh -> yaml_load), so "the report is
# about the file that is there now" is a fact somebody has to arrange rather
# than one that falls out: cmd_check converts after the fix, and _cf_commit
# drops what it renamed over. The contract is asserted first, then the seam on
# its own — either mechanism alone would satisfy the contract, so the second
# assertion is what keeps _cf_commit honest.
f19="$tmpdir/fix-reread"
fx_project "$f19" <<'YAML'
services:
  demo-web:
    image: nginx:alpine
    container_name: demo-web
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    networks: [kasbah-net]
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  kasbah-net:
    external: true
YAML
out="$(cd "$f19" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]' "F19: the project fails C01 before anything is fixed (rc $rc)"
out="$(fx_run "$f19")"; rc=$?
assert 'grep -qF "wrote compose.prod.yml" <<<"$out"' \
    "F19: --fix wrote the file (said '$out')"
assert 'grep -qF "✓ All services set restart policy" <<<"$out"' \
    "F19: and the report in the same run reads the file it just wrote (said '$out')"
assert '! grep -qF "✗ Services missing restart policy" <<<"$out"' \
    "F19: rather than the failure it repaired"
assert '[ "$rc" = "0" ]' "F19: so the run ends clean (rc $rc)
$out"
# And the seam itself, since cmd_check reloading after the fix would hide a
# _cf_commit that forgot to say it had rewritten the file: the rename drops the
# conversion cached for the path it landed on.
f19b="$tmpdir/fix-commit-forgets"
mkdir -p "$f19b"
printf 'a: 1\n' > "$f19b/f.yml"
printf 'a: 2\n' > "$f19b/f.new"
out="$(cd "$f19b" && env KASBAH_LIB_DIR="$repo_dir/lib" bash -c '
    set -uo pipefail
    . "$KASBAH_LIB_DIR/check_fix.sh"
    yaml_load f.yml
    _cf_commit f.yml f.new >/dev/null
    yaml_query f.yml ".a"
' 2>&1)"
assert '[ "$out" = "2" ]' \
    "F19: _cf_commit drops the conversion cached for the path it renamed over (said '$out')"

# --- Case F20: one yq fork per file, never one per rule ----------------------
# The linter converts each document once and answers every rule from that, so
# the only `yq` a run may fork is a whole-file read: `-c .` per file, plus
# manifest_require's own sentinel read, which stays as it is because it is where
# a YAML parse error reaches the operator. A rule that goes back to forking per
# service still produces the right report — it just takes ~180 ms per question —
# so nothing else in this suite would notice. This is the pin that does.
#
# The shape is asserted, not a ceiling: which file was read, by which kind of
# read, how many times. A bound would pass by luck on a fixture that never
# reaches the code that regressed, and the `--fix` half in particular has to run
# against a project that really gets fixed — a compliant one never stages a
# candidate and so never exercises the staging or the re-plan.
#
# A shim on PATH records every call and execs the real thing, so the run under
# test is the real run.
shimdir="$tmpdir/forkshim"
mkdir -p "$shimdir"
real_yq="$(command -v yq)"
{
    printf '#!/usr/bin/env bash\n'
    printf 'printf "YQCALL %%s\\\\n" "$*" >> "$YQ_COUNT_FILE"\n'
    printf 'exec %s "$@"\n' "$real_yq"
} > "$shimdir/yq"
chmod +x "$shimdir/yq"

fork_run() { # DIR ARGS...
    local d="$1"; shift
    : > "$tmpdir/forks.log"
    (cd "$d" && PATH="$shimdir:$PATH" YQ_COUNT_FILE="$tmpdir/forks.log" \
        "$kasbah" "$@" >/dev/null 2>&1)
    return 0
}
# `KIND FILE COUNT` per distinct read, sorted. The candidate carries the run's
# pid, so it is folded back to a fixed name; anything that is neither a whole
# file conversion nor the sentinel keeps its raw text and shows up as a stray.
fork_shape() {
    sed -E -e 's/^YQCALL -c \. /convert /' \
           -e 's/^YQCALL -r \.schema .* /sentinel /' \
           -e 's/\.kasbah-fix\.[0-9]+$/.kasbah-fix.PID/' "$tmpdir/forks.log" \
        | sort | uniq -c | awk '{ print $2, $3, $1 }' | sort
}

f20="$tmpdir/forks-plain"
make_project "$f20"
fork_run "$f20" check
got="$(fork_shape)"
want="convert compose.prod.yml 1
convert kasbah.yml 1
convert traefik-dynamic.yml 1
sentinel kasbah.yml 1"
assert '[ "$got" = "$want" ]' \
    "F20: a plain check reads each file once, and kasbah.yml once more for the sentinel
$(diff -u <(printf '%s\n' "$want") <(printf '%s\n' "$got") 2>&1 || true)
        raw:
$(sed 's/^/        /' < "$tmpdir/forks.log")"

# A project with a real C01 violation, so --fix stages a candidate, verifies it
# and re-plans it — the three places that read a document during the fix.
f20b="$tmpdir/forks-fix"
fx_project "$f20b" <<'YAML'
services:
  demo-web:
    image: nginx:alpine
    container_name: demo-web
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    networks: [kasbah-net]
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  kasbah-net:
    external: true
YAML
fork_run "$f20b" check --fix --yes
got="$(fork_shape)"
# Twice each for the project's own files: the fix reads them, then the report
# re-reads what the fix wrote (lib/check.sh — the loads sit after check_fix_run
# deliberately). The candidate is converted once, which is both its parse check
# and what the verifier and the re-plan then query.
want="convert compose.prod.yml 2
convert compose.prod.yml.kasbah-fix.PID 1
convert kasbah.yml 2
convert traefik-dynamic.yml 2
sentinel kasbah.yml 2"
assert '[ "$got" = "$want" ]' \
    "F20: --fix reads each file once per phase, and the candidate once
$(diff -u <(printf '%s\n' "$want") <(printf '%s\n' "$got") 2>&1 || true)
        raw:
$(sed 's/^/        /' < "$tmpdir/forks.log")"
# The fixture really was fixed, so the shape above is the shape of a run that
# went all the way through staging rather than one that found nothing to do.
assert 'grep -qF "restart: unless-stopped" "$f20b/compose.prod.yml"' \
    "F20: and the --fix fixture really was rewritten"

# --- Case F21: a document that does not parse yields no services at all ------
# `yq -c .` will write the documents it managed to read *and* exit non-zero, so
# a multi-document compose file with one broken document has a good half. That
# half is dropped: the rules see one unreadable file rather than a project made
# of whichever documents happened to survive, which is what cmd_check's comment
# about short-circuiting has always promised. Pinned because the failure it
# prevents is silent — T07 passed on this fixture by checking the fragment
# against container_names read out of half a file.
f21="$tmpdir/partial-parse"
make_project "$f21"
{
    printf 'services:\n'
    printf '  demo-web:\n'
    printf '    image: nginx:alpine\n'
    printf '    container_name: demo-web\n'
    printf -- '---\n'
    printf 'services:\n'
    printf '\tbroken: 1\n'
} > "$f21/compose.prod.yml"
# The precondition, asserted rather than assumed: this file really is *partly*
# readable. A fixture that failed outright would satisfy everything below while
# proving nothing.
f21_half="$(cd "$f21" && yq -c '.' compose.prod.yml 2>/dev/null)"; f21_rc=$?
assert '[ "$f21_rc" != 0 ]' "F21: the fixture does not parse (rc $f21_rc)"
assert 'grep -q "demo-web" <<<"$f21_half"' \
    "F21: and yet one of its documents converts (said '$f21_half')"

out="$(cd "$f21" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]' "F21: the run fails (rc $rc)"
assert 'grep -qF "✗ compose.prod.yml does not parse as YAML" <<<"$out"' \
    "F21: and says the file does not parse (said '$out')"
# T07 is the rule that used to answer from the readable half. With no services
# it has nothing to check and says nothing at all — neither its pass line nor
# its failure may appear.
assert '! grep -qF "Fragment loadBalancer URLs target explicit container_names" <<<"$out"' \
    "F21: T07 does not pass on the half that parsed (said '$out')"
assert '! grep -qF "Fragment targets unknown container_names" <<<"$out"' \
    "F21: and does not fail on it either (said '$out')"
assert '! grep -q "demo-web" <<<"$out"' \
    "F21: no rule reports on a service from the half that parsed (said '$out')"

exit "$fail"
