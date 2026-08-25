#!/usr/bin/env bash
# Test: kasbah check — Structure rules (S01–S06).

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
assert 'grep -qF "25 passed, 0 warning, 0 failed" <<<"$out"'   "summary all pass"

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
assert 'grep -qF "24 passed, 1 warning, 0 failed" <<<"$out"'                    "one line either way (said '$(tail -1 <<<"$out")')"

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
assert 'grep -qF "24 passed, 1 warning, 0 failed" <<<"$out"'                       "one line either way (said '$(tail -1 <<<"$out")')"

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
assert 'grep -qF "25 passed, 0 warning, 0 failed" <<<"$out"'                             "and nothing warns (said '$(tail -1 <<<"$out")')"

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
assert 'grep -qF "25 passed, 0 warning, 0 failed" <<<"$out"'                   "and nothing warns about it (said '$(tail -1 <<<"$out")')"

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
assert 'grep -qF "24 passed, 1 warning, 0 failed" <<<"$out"'                 "E05 warns instead of passing, one line either way (said '$out')"

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

exit "$fail"
