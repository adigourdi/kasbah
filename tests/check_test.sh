#!/usr/bin/env bash
# Test: hosting check — Structure rules (S01–S06).

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

# Scaffold a passing project: init-project + a minimal-but-valid
# compose.prod.yml + a traefik-dynamic.yml that together satisfy every
# check group's pass path (Structure, Compose, Resources, Traefik, Env).
# The routed service joins hosting-net explicitly and keeps an internal
# network (C03/C07); limits reference the HOSTING_* vars (R01/R02); the
# fragment's loadBalancer targets the container_name (T07). Healthchecks
# and Hooks sections are silent — manifest has no health/hooks/backup
# blocks, and the only service has no build:.
make_project() {
    local dir="$1" name="${2:-demo}" domain="${3:-demo.example.com}"
    mkdir -p "$dir"
    (cd "$dir" && "$hosting" init-project --name="$name" --domain="$domain" >/dev/null)
    # Unquoted heredoc: $name interpolates, \${HOSTING_*} stays literal.
    cat > "$dir/compose.prod.yml" <<YAML
services:
  app:
    image: nginx:alpine
    container_name: ${name}-web
    restart: unless-stopped
    cpus: \${HOSTING_CPU_LIMIT}
    mem_limit: \${HOSTING_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    networks: [hosting-net, internal]

networks:
  hosting-net:
    external: true
  internal: {}
YAML
    # printf-built so backticks in `Host(`…`)` stay literal (heredoc would
    # require '<<YAML' for $name/$domain interpolation but then evaluate the
    # backticks as command substitution).
    {
        printf 'http:\n'
        printf '  routers:\n'
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
out="$(cd "$proj1" && "$hosting" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                       "golden path exits 0 (got $rc)"
assert 'grep -qF "✓ hosting.yml exists (schema 1)" <<<"$out"'  "S01/S02 pass line"
assert 'grep -qF "✓ compose.prod.yml exists" <<<"$out"'        "S03 pass line"
assert 'grep -qF "✓ .env.prod.example exists" <<<"$out"'       "S04 pass line"
assert 'grep -qF "✓ .gitignore excludes .env" <<<"$out"'       "S05 pass line"
assert 'grep -qF "✓ .gitignore excludes .hosting/" <<<"$out"'  "S06 pass line"
assert 'grep -qF "✓ All services set restart policy" <<<"$out"'                 "C01 pass line"
assert 'grep -qF "✓ All services set json-file logging with rotation" <<<"$out"' "C02 pass line"
assert 'grep -qF "✓ All routed services join hosting-net" <<<"$out"'            "C03 pass line"
assert 'grep -qF "✓ hosting-net declared external" <<<"$out"'                   "C04 pass line"
assert 'grep -qF "✓ No internal services on hosting-net" <<<"$out"'             "C07 pass line"
assert 'grep -qF "✓ No deprecated '"'"'version:'"'"' field" <<<"$out"'          "C05 pass line"
assert 'grep -qF "✓ All services set cpus/mem_limit via HOSTING_* vars" <<<"$out"'  "R01/R02 pass line"
assert 'grep -qF "✓ No resource reservations" <<<"$out"'                            "R03 pass line"
assert 'grep -qF "✓ compose.prod.yml has no traefik.* labels" <<<"$out"'                       "T06 pass line"
assert 'grep -qF "✓ traefik-dynamic.yml exists" <<<"$out"'                                     "T01 pass line"
assert 'grep -qF "✓ At least one router references manifest domain (demo.example.com)" <<<"$out"' "T02 pass line"
assert 'grep -qF "✓ All routers declare entryPoints" <<<"$out"'                                "T03 pass line"
assert 'grep -qF "✓ Secure routers reference letsencrypt cert resolver" <<<"$out"'             "T04 pass line"
assert 'grep -qF "✓ No router claims reserved hostnames" <<<"$out"'                            "T05 pass line"
assert 'grep -qF "✓ Fragment loadBalancer URLs target explicit container_names" <<<"$out"'     "T07 pass line"
assert 'grep -qF "✓ .env.prod.example syntax is valid" <<<"$out"'                              "E01 pass line"
assert 'grep -qF "✓ .env.prod.example has no obvious long secrets" <<<"$out"'                  "E04 pass line"
assert '! grep -q "Healthchecks:" <<<"$out"'  "Healthchecks: header suppressed (nothing to check)"
assert '! grep -q "Hooks:" <<<"$out"'         "Hooks: header suppressed (no hooks/backup in manifest)"
assert 'grep -qF "22 passed, 0 warning, 0 failed" <<<"$out"'   "summary all pass"

# --- Case 2: missing compose.prod.yml — fail, exit 6 -------------------------
# Exit 6 is the documented "compliance check failed" code (docs/cli.md).
proj2="$tmpdir/no-compose"
make_project "$proj2"
rm "$proj2/compose.prod.yml"
out="$(cd "$proj2" && "$hosting" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                "missing compose exits 6 (got $rc)"
assert 'grep -qF "✗ compose.prod.yml missing" <<<"$out"' "S03 fail line"
assert 'grep -qF "1 failed" <<<"$out"'                  "summary reports 1 failed"

# --- Case 3: missing .env.prod.example — fail, exit 6 ------------------------
proj3="$tmpdir/no-env"
make_project "$proj3"
rm "$proj3/.env.prod.example"
out="$(cd "$proj3" && "$hosting" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                  "missing env example exits 6 (got $rc)"
assert 'grep -qF "✗ .env.prod.example missing" <<<"$out"' "S04 fail line"

# --- Case 4: missing .gitignore — warn for both S05 & S06, exit 0 ------------
proj4="$tmpdir/no-gitignore"
make_project "$proj4"
rm "$proj4/.gitignore"
out="$(cd "$proj4" && "$hosting" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                                   "warnings only still exits 0 (got $rc)"
assert 'grep -qF "⚠ .gitignore does not exclude .env" <<<"$out"'           "S05 warn line"
assert 'grep -qF "⚠ .gitignore does not exclude .hosting/" <<<"$out"'      "S06 warn line"
assert 'grep -qF "2 warning, 0 failed" <<<"$out"'                          "summary reports 2 warnings"

# --- Case 5: partial .gitignore (missing only .hosting/) — one warn ----------
proj5="$tmpdir/partial-gitignore"
make_project "$proj5"
# Overwrite with only .env line.
printf '.env\n' > "$proj5/.gitignore"
out="$(cd "$proj5" && "$hosting" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                              "partial gitignore exits 0"
assert 'grep -qF "✓ .gitignore excludes .env" <<<"$out"'              "S05 still passes"
assert 'grep -qF "⚠ .gitignore does not exclude .hosting/" <<<"$out"' "S06 warns"
assert 'grep -qF "1 warning, 0 failed" <<<"$out"'                     "summary reports 1 warning"

# --- Case 6: no hosting.yml — exit 2 (manifest_require contract) -------------
proj6="$tmpdir/no-manifest"
mkdir -p "$proj6"
out="$(cd "$proj6" && "$hosting" check 2>&1)"; rc=$?
assert '[ "$rc" = "2" ]'                          "no manifest exits 2 (got $rc)"
assert 'grep -qF "No hosting.yml" <<<"$out"'      "no-manifest message"

# --- Case 7: future schema — exit 1 (manifest_require contract) --------------
proj7="$tmpdir/future-schema"
mkdir -p "$proj7"
cat > "$proj7/hosting.yml" <<EOF
schema: 99
hosting_version: 0.1.0
name: future
domain: "x.test"
sync: []
EOF
out="$(cd "$proj7" && "$hosting" check 2>&1)"; rc=$?
assert '[ "$rc" = "1" ]'                              "future schema exits 1 (got $rc)"
assert 'grep -qF "newer than this hosting" <<<"$out"' "future schema message"

# --- Case 8: --help works without a project ----------------------------------
out="$(cd "$tmpdir" && "$hosting" check --help 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                "check --help exits 0"
assert 'grep -qF "Usage: hosting check" <<<"$out"'      "check --help prints usage"

# --- Case 9: unknown flag rejected -------------------------------------------
proj9="$tmpdir/unknown-flag"
make_project "$proj9"
out="$(cd "$proj9" && "$hosting" check --bogus 2>&1)"; rc=$?
assert '[ "$rc" = "1" ]'                            "unknown flag exits 1 (got $rc)"
assert 'grep -qF "unknown argument" <<<"$out"'      "unknown flag message"

# --- Case 10: --help in dispatcher lists check -------------------------------
out="$("$hosting" --help 2>&1)"
assert 'grep -qF "check" <<<"$out"' "--help mentions check"

# --- Case 11: full report (incl. "Checking <path>" header) lands on stdout ---
# So users can `hosting check > report.txt` without losing the header.
proj11="$tmpdir/redirect"
make_project "$proj11"
out="$(cd "$proj11" && "$hosting" check 2>/dev/null)"; rc=$?
assert '[ "$rc" = "0" ]'                       "redirected stdout still exits 0"
assert 'grep -qF "Checking $proj11" <<<"$out"' "Checking header is on stdout (not stderr)"
assert 'grep -qF "Structure:" <<<"$out"'       "Structure header is on stdout"
assert 'grep -qF "Summary:" <<<"$out"'         "Summary line is on stdout"

# --- Case 12: CRLF .gitignore — S05/S06 still pass ---------------------------
# Windows-authored .gitignore with CRLF endings should not false-warn — same
# CR-stripping parity that lib/manifest.sh enforces for hosting.yml.
proj12="$tmpdir/crlf-gitignore"
make_project "$proj12"
printf '.env\r\n.hosting/\r\n' > "$proj12/.gitignore"
out="$(cd "$proj12" && "$hosting" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                       "CRLF gitignore exits 0 (got $rc)"
assert 'grep -qF "✓ .gitignore excludes .env" <<<"$out"'       "S05 passes despite CRLF"
assert 'grep -qF "✓ .gitignore excludes .hosting/" <<<"$out"'  "S06 passes despite CRLF"

# --- Case 13: C01 — service missing restart policy → fail, exit 6 -----------
proj13="$tmpdir/no-restart"
make_project "$proj13"
cat > "$proj13/compose.prod.yml" <<'YAML'
services:
  app:
    image: nginx:alpine
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
networks:
  default:
    name: hosting-net
    external: true
YAML
out="$(cd "$proj13" && "$hosting" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                            "C01 fail exits 6 (got $rc)"
assert 'grep -qF "✗ Services missing restart policy: app" <<<"$out"' "C01 fail line names service"

# --- Case 14: C02 — service missing logging rotation → fail, exit 6 ---------
proj14="$tmpdir/no-logging"
make_project "$proj14"
cat > "$proj14/compose.prod.yml" <<'YAML'
services:
  app:
    image: nginx:alpine
    restart: unless-stopped
networks:
  default:
    name: hosting-net
    external: true
YAML
out="$(cd "$proj14" && "$hosting" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                                                    "C02 fail exits 6 (got $rc)"
assert 'grep -qF "✗ Services missing json-file logging with max-size/max-file: app" <<<"$out"' "C02 fail line"

# --- Case 15: C03 — routed service not on hosting-net → fail, exit 6 --------
# Fragment targets demo-web (routed), but the service joins no network.
proj15="$tmpdir/no-hostingnet"
make_project "$proj15"
cat > "$proj15/compose.prod.yml" <<'YAML'
services:
  app:
    image: nginx:alpine
    container_name: demo-web
    restart: unless-stopped
    cpus: ${HOSTING_CPU_LIMIT}
    mem_limit: ${HOSTING_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
YAML
out="$(cd "$proj15" && "$hosting" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                                "C03 fail exits 6 (got $rc)"
assert 'grep -qF "✗ Routed services not on hosting-net: app" <<<"$out"' "C03 fail line"
assert 'grep -qF "✓ No internal services on hosting-net" <<<"$out"'     "C07 still passes"

# --- Case 16: C04 — hosting-net referenced but not external → fail, exit 6 --
proj16="$tmpdir/hostingnet-not-external"
make_project "$proj16"
cat > "$proj16/compose.prod.yml" <<'YAML'
services:
  app:
    image: nginx:alpine
    container_name: demo-web
    restart: unless-stopped
    cpus: ${HOSTING_CPU_LIMIT}
    mem_limit: ${HOSTING_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    networks: [hosting-net, internal]
networks:
  hosting-net: {}
  internal: {}
YAML
out="$(cd "$proj16" && "$hosting" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                                  "C04 fail exits 6 (got $rc)"
assert 'grep -qF "✓ All routed services join hosting-net" <<<"$out"'      "C03 still passes"
assert 'grep -qF "✗ hosting-net not declared external: true" <<<"$out"'   "C04 fail line"

# --- Case 17: C05 — top-level `version:` → warn, exit 0 ---------------------
proj17="$tmpdir/version-field"
make_project "$proj17"
cat > "$proj17/compose.prod.yml" <<'YAML'
version: "3.8"
services:
  app:
    image: nginx:alpine
    container_name: demo-web
    restart: unless-stopped
    cpus: ${HOSTING_CPU_LIMIT}
    mem_limit: ${HOSTING_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    networks: [hosting-net, internal]
networks:
  hosting-net:
    external: true
  internal: {}
YAML
out="$(cd "$proj17" && "$hosting" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                                                "C05 warn exits 0 (got $rc)"
assert 'grep -qF "⚠ compose.prod.yml uses deprecated '"'"'version:'"'"' field" <<<"$out"' "C05 warn line"

# --- Case 18: empty compose (no services) → warn, exit 0 --------------------
# Compose checks beyond C05 have nothing to bite on; emit one warn and run C05.
proj18="$tmpdir/empty-compose"
make_project "$proj18"
: > "$proj18/compose.prod.yml"
out="$(cd "$proj18" && "$hosting" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                                                       "empty compose exits 0 (got $rc)"
assert 'grep -qF "⚠ compose.prod.yml declares no services — skipping Compose checks" <<<"$out"' "no-services warn line"
assert 'grep -qF "✓ No deprecated '"'"'version:'"'"' field" <<<"$out"'                          "C05 still runs"

# --- Case 19: T01 — traefik-dynamic.yml missing → warn, exit 0 ---------------
# Worker-only projects without web routing should not fail the whole check.
# Consistently, such a project has no business on hosting-net (C07) — so the
# fixture keeps the service off it entirely.
proj19="$tmpdir/no-traefik-fragment"
make_project "$proj19"
rm "$proj19/traefik-dynamic.yml"
cat > "$proj19/compose.prod.yml" <<'YAML'
services:
  app:
    image: nginx:alpine
    restart: unless-stopped
    cpus: ${HOSTING_CPU_LIMIT}
    mem_limit: ${HOSTING_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
YAML
out="$(cd "$proj19" && "$hosting" check 2>&1)"; rc=$?
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
out="$(cd "$proj20" && "$hosting" check 2>&1)"; rc=$?
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
out="$(cd "$proj21" && "$hosting" check 2>&1)"; rc=$?
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
out="$(cd "$proj22" && "$hosting" check 2>&1)"; rc=$?
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
out="$(cd "$proj23" && "$hosting" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                                  "T05 fail exits 6 (got $rc)"
assert 'grep -qF "✗ Routers claim reserved hostnames" <<<"$out"'          "T05 fail line"
assert 'grep -qF "demo-mail" <<<"$out"'                                   "T05 names offending router"

# --- Case 24: T06 — service carries traefik.* label → fail ------------------
proj24="$tmpdir/traefik-label"
make_project "$proj24"
cat > "$proj24/compose.prod.yml" <<'YAML'
services:
  app:
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
    name: hosting-net
    external: true
YAML
out="$(cd "$proj24" && "$hosting" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                                                  "T06 fail exits 6 (got $rc)"
assert 'grep -qF "✗ Services carry traefik.* labels (file provider only): app" <<<"$out"' "T06 fail line"

# --- Case 25: H01 — built service without compose healthcheck → warn --------
proj25="$tmpdir/built-no-hc"
make_project "$proj25"
mkdir -p "$proj25/api"
: > "$proj25/api/Dockerfile"
cat > "$proj25/compose.prod.yml" <<'YAML'
services:
  api:
    build: ./api
    container_name: demo-web
    restart: unless-stopped
    cpus: ${HOSTING_CPU_LIMIT}
    mem_limit: ${HOSTING_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    networks: [hosting-net, internal]
networks:
  hosting-net:
    external: true
  internal: {}
YAML
out="$(cd "$proj25" && "$hosting" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                                                                          "H01 warn exits 0 (got $rc)"
assert 'grep -qF "Healthchecks:" <<<"$out"'                                                                       "Healthchecks: header appears"
assert 'grep -qF "⚠ Built services without a compose healthcheck (Dockerfile may declare one): api" <<<"$out"'    "H01 warn line"

# --- Case 26: H02 — manifest health.container not in compose → fail ---------
proj26="$tmpdir/bad-health-container"
make_project "$proj26"
# Append a `health:` block to the manifest.
cat >> "$proj26/hosting.yml" <<'YAML'

health:
  container: nonexistent-container
  timeout: 60s
YAML
out="$(cd "$proj26" && "$hosting" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                                                                                  "H02 fail exits 6 (got $rc)"
assert 'grep -qF "✗ manifest health.container '"'"'nonexistent-container'"'"' not found among compose container_names" <<<"$out"' "H02 fail line"

# --- Case 27: H02 pass — health.container matches a compose container_name --
proj27="$tmpdir/good-health-container"
make_project "$proj27"
cat > "$proj27/compose.prod.yml" <<'YAML'
services:
  app:
    image: nginx:alpine
    container_name: demo-web
    restart: unless-stopped
    cpus: ${HOSTING_CPU_LIMIT}
    mem_limit: ${HOSTING_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    networks: [hosting-net, internal]
networks:
  hosting-net:
    external: true
  internal: {}
YAML
cat >> "$proj27/hosting.yml" <<'YAML'

health:
  container: demo-web
  timeout: 60s
YAML
out="$(cd "$proj27" && "$hosting" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                                                       "H02 pass exits 0 (got $rc)"
assert 'grep -qF "✓ manifest health.container '"'"'demo-web'"'"' exists in compose" <<<"$out"' "H02 pass line"

# --- Case 28: E01 — invalid line → fail --------------------------------------
proj28="$tmpdir/env-bad-syntax"
make_project "$proj28"
# Inject a garbage line that's neither a comment, blank, nor NAME=value.
printf 'this is not valid env syntax\n' >> "$proj28/.env.prod.example"
out="$(cd "$proj28" && "$hosting" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                                            "E01 fail exits 6 (got $rc)"
assert 'grep -qF "✗ .env.prod.example has invalid lines" <<<"$out"'                 "E01 fail line"

# --- Case 29: E02 — .env missing a key from .env.prod.example → warn --------
proj29="$tmpdir/env-missing-key"
make_project "$proj29"
# .env.prod.example has DOMAIN. .env has nothing.
: > "$proj29/.env"
out="$(cd "$proj29" && "$hosting" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                                  "E02 warn exits 0 (got $rc)"
assert 'grep -qF "⚠ .env missing keys vs .env.prod.example: DOMAIN" <<<"$out"'  "E02 warn line"

# --- Case 30: E03 — .env has an extra key not in template → warn ------------
proj30="$tmpdir/env-extra-key"
make_project "$proj30"
cat > "$proj30/.env" <<'ENV'
DOMAIN=demo.example.com
EXTRA_VAR=oops
ENV
out="$(cd "$proj30" && "$hosting" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                                              "E03 warn exits 0 (got $rc)"
assert 'grep -qF "⚠ .env has extra keys not in .env.prod.example: EXTRA_VAR" <<<"$out"' "E03 warn line"

# --- Case 31: E04 — long literal value in template → warn -------------------
proj31="$tmpdir/env-long-secret"
make_project "$proj31"
# 80-char hex-ish value, not a `!`-generator, not a hint.
printf 'API_TOKEN=%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" >> "$proj31/.env.prod.example"
out="$(cd "$proj31" && "$hosting" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                                                          "E04 warn exits 0 (got $rc)"
assert 'grep -qF "⚠ .env.prod.example has values >64 chars (possibly leaked secrets): API_TOKEN" <<<"$out"' "E04 warn line"

# --- Case 32: HK01 — hook references unknown container → fail ----------------
proj32="$tmpdir/hk01-unknown"
make_project "$proj32"
cat > "$proj32/compose.prod.yml" <<'YAML'
services:
  app:
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
    name: hosting-net
    external: true
YAML
cat >> "$proj32/hosting.yml" <<'YAML'

hooks:
  post-deploy:
    - ghost-container echo hi
YAML
out="$(cd "$proj32" && "$hosting" check 2>&1)"; rc=$?
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
    name: hosting-net
    external: true
YAML
cat >> "$proj33/hosting.yml" <<'YAML'

backup:
  container: demo-db
  check: "true"
  command: "pg_dump -U u d"
  # extension intentionally omitted
YAML
out="$(cd "$proj33" && "$hosting" check 2>&1)"; rc=$?
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
    name: hosting-net
    external: true
YAML
cat >> "$proj34/hosting.yml" <<'YAML'

backup:
  container: not-in-compose
  check: "true"
  command: "pg_dump -U u d"
  extension: sql.gz
YAML
out="$(cd "$proj34" && "$hosting" check 2>&1)"; rc=$?
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
    cpus: ${HOSTING_CPU_LIMIT}
    mem_limit: ${HOSTING_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    networks: [hosting-net, internal]
  db:
    image: postgres:16
    container_name: demo-db
    restart: unless-stopped
    cpus: ${HOSTING_CPU_LIMIT}
    mem_limit: ${HOSTING_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    networks: [internal]
networks:
  hosting-net:
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
cat >> "$proj35/hosting.yml" <<'YAML'

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
out="$(cd "$proj35" && "$hosting" check 2>&1)"; rc=$?
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
# service must stay off hosting-net (C07) for the warn-only outcome to hold.
cat > "$proj36/compose.prod.yml" <<'YAML'
services:
  app:
    image: nginx:alpine
    restart: unless-stopped
    cpus: ${HOSTING_CPU_LIMIT}
    mem_limit: ${HOSTING_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
YAML
out="$(cd "$proj36" && "$hosting" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                                        "T01 malformed exits 0 (got $rc)"
assert 'grep -qF "⚠ traefik-dynamic.yml does not parse as YAML" <<<"$out"'      "T01 malformed warn line"
assert '! grep -qF "At least one router references manifest domain" <<<"$out"'  "T02 skipped on parse failure"

# --- Case 37: empty manifest domain → T02 skipped with a warn, exit 0 -------
# init-project allows an empty domain. The Traefik check should warn and skip
# T02 rather than failing on an empty needle.
proj37="$tmpdir/empty-domain"
mkdir -p "$proj37"
(cd "$proj37" && "$hosting" init-project --name=demo >/dev/null 2>&1)
cat > "$proj37/compose.prod.yml" <<'YAML'
services:
  app:
    image: nginx:alpine
    restart: unless-stopped
    cpus: ${HOSTING_CPU_LIMIT}
    mem_limit: ${HOSTING_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
YAML
{ printf 'http:\n  routers:\n    demo:\n      rule: "Host(`x.test`)"\n      entryPoints: [websecure]\n      tls:\n        certResolver: letsencrypt\n      service: noop@internal\n'; } > "$proj37/traefik-dynamic.yml"
out="$(cd "$proj37" && "$hosting" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]'                                                              "empty-domain T02 skip exits 0 (got $rc)"
assert 'grep -qF "⚠ manifest domain is empty — skipping T02" <<<"$out"'               "empty-domain warn line"
assert '! grep -qF "At least one router references manifest domain" <<<"$out"'        "T02 not run on empty domain"
assert 'grep -qF "✓ All routers declare entryPoints" <<<"$out"'                       "T03 still runs on empty domain"

# --- Case 38: C07 — non-routed service on hosting-net → fail ----------------
proj38="$tmpdir/c07-internal-on-shared"
make_project "$proj38"
cat > "$proj38/compose.prod.yml" <<'YAML'
services:
  app:
    image: nginx:alpine
    container_name: demo-web
    restart: unless-stopped
    cpus: ${HOSTING_CPU_LIMIT}
    mem_limit: ${HOSTING_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    networks: [hosting-net, internal]
  db:
    image: postgres:16
    container_name: demo-db
    restart: unless-stopped
    cpus: ${HOSTING_CPU_LIMIT}
    mem_limit: ${HOSTING_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    networks: [hosting-net, internal]
networks:
  hosting-net:
    external: true
  internal: {}
YAML
out="$(cd "$proj38" && "$hosting" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                              "C07 fail exits 6 (got $rc)"
assert 'grep -qF "✗ Non-routed services on hosting-net: db" <<<"$out"' "C07 fail line names db"
assert 'grep -qF "✓ All routed services join hosting-net" <<<"$out"'   "C03 still passes"

# --- Case 39: C07 — default network aliasing hosting-net is banned ----------
proj39="$tmpdir/c07-default-alias"
make_project "$proj39"
cat > "$proj39/compose.prod.yml" <<'YAML'
services:
  app:
    image: nginx:alpine
    container_name: demo-web
    restart: unless-stopped
    cpus: ${HOSTING_CPU_LIMIT}
    mem_limit: ${HOSTING_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
networks:
  default:
    name: hosting-net
    external: true
YAML
out="$(cd "$proj39" && "$hosting" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                                    "default-alias exits 6 (got $rc)"
assert 'grep -qF "✗ default network aliases hosting-net" <<<"$out"'         "C07 default-alias fail line"

# --- Case 40: R01/R02 literal limits + R03 reservations → fail --------------
proj40="$tmpdir/r-rules"
make_project "$proj40"
cat > "$proj40/compose.prod.yml" <<'YAML'
services:
  app:
    image: nginx:alpine
    container_name: demo-web
    restart: unless-stopped
    cpus: "1.5"
    mem_limit: ${HOSTING_MEM_LIMIT}
    mem_reservation: 512m
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    networks: [hosting-net, internal]
networks:
  hosting-net:
    external: true
  internal: {}
YAML
out="$(cd "$proj40" && "$hosting" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                                                  "R rules fail exits 6 (got $rc)"
assert 'grep -qF "✗ Services with missing or literal resource limits: app(cpus)" <<<"$out"' "R01 fail line (literal cpus)"
assert 'grep -qF "✗ Services declare resource reservations: app" <<<"$out"'                "R03 fail line"

# --- Case 41: T07 — fragment targets a hostname with no container_name ------
proj41="$tmpdir/t07-unknown-target"
make_project "$proj41"
# Compose renames the container; the make_project fragment still targets
# demo-web. The routed set is now empty, so C03/C07 stay quiet — T07 is the
# rule that catches the dangling reference.
cat > "$proj41/compose.prod.yml" <<'YAML'
services:
  app:
    image: nginx:alpine
    container_name: demo-renamed
    restart: unless-stopped
    cpus: ${HOSTING_CPU_LIMIT}
    mem_limit: ${HOSTING_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
YAML
out="$(cd "$proj41" && "$hosting" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                                       "T07 fail exits 6 (got $rc)"
assert 'grep -qF "✗ Fragment targets unknown container_names: demo-web" <<<"$out"' "T07 fail line"

# --- Case 42: a name hosting owns on the server -------------------------------
# The project should learn this from `check`, not from the deploy that rsyncs
# over the shared Traefik stack and then removes it as an orphan. It is a
# manifest rule, so it arrives the same way a bad schema does: manifest_require
# refuses and the report short-circuits.
for reserved in traefik data backups; do
    proj42="$tmpdir/reserved-$reserved"
    mkdir -p "$proj42"
    cat > "$proj42/hosting.yml" <<EOF
schema: 1
hosting_version: 0.1.0
name: $reserved
domain: "x.test"
sync: []
EOF
    out="$(cd "$proj42" && "$hosting" check 2>&1)"; rc=$?
    # 1, not 6: a reserved name is a manifest-load refusal that short-circuits
    # before any rule runs, the same as an invalid-regex name. Every other case
    # in this suite pins 6, so pin the number that actually distinguishes them.
    assert '[ "$rc" = "1" ]' "check refuses a project named $reserved with exit 1 (got $rc)"
    assert 'grep -qF "is reserved" <<<"$out"' "and says it is reserved (said '$out')"
    assert 'grep -qF "$reserved" <<<"$out"'   "naming it"
done

exit "$fail"
