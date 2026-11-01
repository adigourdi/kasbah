#!/usr/bin/env bash
# Test: kasbah check — Structure rules (S01–S06).

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
. "$repo_dir/tests/cli.sh"
need_yaml2json
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
# The routed service joins the project's own kasbah network and keeps an
# internal one (C03/C04/C07); it is named for the project; limits reference the KASBAH_*
# vars (R01/R02); the fragment's loadBalancer targets the service name, with
# no container_name (T07), and the service declares a healthcheck, so it rolls
# on deploy (C11); the fragment carries both routers for the domain, the redirect on `web` and
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
    restart: unless-stopped
    cpus: \${KASBAH_CPU_LIMIT}
    mem_limit: \${KASBAH_MEM_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://127.0.0.1/"]
    networks: [kasbah, internal]

networks:
  kasbah: {}
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
        printf '        certResolver: http\n'
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
assert 'grep -qF "✓ All routed services join the project'"'"'s kasbah network" <<<"$out"' "C03 pass line"
assert 'grep -qF "✓ The kasbah network is the project'"'"'s own (demo_kasbah)" <<<"$out"'  "C04 pass line"
assert 'grep -qF "✓ No internal services on the kasbah network or kasbah-net" <<<"$out"' "C07 pass line"
assert '! grep -qF "kasbah-net service names" <<<"$out"'                       "C09'"'"'s kasbah-net warn is silent with nothing on kasbah-net"
assert 'grep -qF "✓ Names on the kasbah network are project-prefixed" <<<"$out"' "and C09 passes the names on the project'"'"'s kasbah network"
assert 'grep -qF "✓ No deprecated '"'"'version:'"'"' field" <<<"$out"'          "C05 pass line"
assert 'grep -qF "✓ All services set cpus/mem_limit via KASBAH_* vars" <<<"$out"'  "R01/R02 pass line"
assert 'grep -qF "✓ No resource reservations" <<<"$out"'                            "R03 pass line"
assert 'grep -qF "✓ compose.prod.yml has no traefik.* labels" <<<"$out"'                       "T06 pass line"
assert 'grep -qF "✓ traefik-dynamic.yml exists" <<<"$out"'                                     "T01 pass line"
assert 'grep -qF "✓ At least one router references manifest domain (demo.example.com)" <<<"$out"' "T02 pass line"
assert 'grep -qF "✓ All routers declare entryPoints" <<<"$out"'                                "T03 pass line"
assert 'grep -qF "✓ Secure routers reference http cert resolver" <<<"$out"'             "T04 pass line"
assert 'grep -qF "✓ A router serves demo.example.com on the web entrypoint" <<<"$out"'         "T08 pass line"
assert 'grep -qF "✓ No router claims reserved hostnames" <<<"$out"'                            "T05 pass line"
assert 'grep -qF "✓ No router or service reaches a Traefik internal service other than noop@internal" <<<"$out"' "T09 pass line"
assert 'grep -qF "✓ Fragment loadBalancer URLs target a service, alias or container_name compose defines" <<<"$out"'     "T07 pass line"
assert 'grep -qF "✓ .env.prod.example syntax is valid" <<<"$out"'                              "E01 pass line"
assert 'grep -qF "✓ .env.prod.example has no obvious long secrets" <<<"$out"'                  "E04 pass line"
assert 'grep -qF "✓ .env.prod.example leaves the KASBAH_* prefix to kasbah" <<<"$out"'       "E05 pass line"
assert '! grep -q "Healthchecks:" <<<"$out"'  "Healthchecks: header suppressed (nothing to check)"
assert '! grep -q "Hooks:" <<<"$out"'         "Hooks: header suppressed (no hooks/backup in manifest)"
assert '! grep -qF "built services" <<<"$out"' \
    "C08 says nothing about a project that builds nothing — there is no :current to move"
assert 'grep -qF "✓ All routed services can roll on deploy" <<<"$out"' "C11 pass line"
assert 'grep -qF "28 passed, 0 warning, 0 failed" <<<"$out"'   "summary all pass"

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

# --- Case 6: no kasbah.yml — exit 2 (the manifest reader's contract) -------------
proj6="$tmpdir/no-manifest"
mkdir -p "$proj6"
out="$(cd "$proj6" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "2" ]'                          "no manifest exits 2 (got $rc)"
assert 'grep -qF "No kasbah.yml" <<<"$out"'      "no-manifest message"

# --- Case 7: future schema — exit 1 (the manifest reader's contract) --------------
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
# the manifest's own check of `name` exists to prevent.
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
# CR stripping the manifest reader applies to kasbah.yml.
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
assert 'grep -qF "✗ Routed services on neither the project'"'"'s kasbah network nor kasbah-net: demo-web" <<<"$out"' "C03 fail line"
assert 'grep -qF "✓ No internal services on the kasbah network or kasbah-net" <<<"$out"'     "C07 still passes"

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
assert 'grep -qF "✓ No internal services on the kasbah network or kasbah-net" <<<"$out"'             "as is C07"
assert 'grep -qF "⚠ Routed through the shared kasbah-net: web — every project'"'"'s routed containers reach each other there; move them to a project network under the key kasbah (docs/traefik.md → Network)" <<<"$out"' \
       "and, routed through the shared kasbah-net, it is warned to move (C03)"
assert 'grep -qF "⚠ web will not roll on deploy — the fragment targets its container_name, so it is recreated in place, briefly unrouted" <<<"$out"' \
       "and, routed by container_name, it is told it will not roll (C11)"
assert 'grep -qF "26 passed, 3 warning, 0 failed" <<<"$out"'                    "one line either way (said '$(tail -1 <<<"$out")')"

# --- Case 16c: C11 — a routed service that will not roll → warn -------------
# One line per routed service, naming the first thing that stops the deploy
# swapping it zero-downtime; the exit stays 0.
proj16c="$tmpdir/no-roll"
make_project "$proj16c"
sed -i 's/^    restart: unless-stopped$/    container_name: demo-web-1\n&/' "$proj16c/compose.prod.yml"
out="$(cd "$proj16c" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]' "C11 is a warning, so exit stays 0 (got $rc)"
assert 'grep -qF "⚠ demo-web will not roll on deploy — it sets container_name, so it is recreated in place, briefly unrouted" <<<"$out"' \
       "a container_name stops the roll even when the fragment targets the service (said '$out')"
assert '! grep -qF "can roll on deploy" <<<"$out"' "and C11 prints no pass line beside it"
assert 'grep -qF "27 passed, 1 warning, 0 failed" <<<"$out"' "the warn replaces the pass line (said '$(tail -1 <<<"$out")')"
sed -i '/^    container_name: demo-web-1$/d; s/^    restart: unless-stopped$/    ports: ["8080:80"]\n&/' "$proj16c/compose.prod.yml"
out="$(cd "$proj16c" && "$kasbah" check 2>&1)"
assert 'grep -qF "⚠ demo-web will not roll on deploy — it publishes a host port a second replica cannot bind, so it is recreated in place, briefly unrouted" <<<"$out"' \
       "a published host port stops the roll (said '$out')"
sed -i 's/^    ports: \["8080:80"\]$/    ports: ["80"]/' "$proj16c/compose.prod.yml"
out="$(cd "$proj16c" && "$kasbah" check 2>&1)"
assert 'grep -qF "✓ All routed services can roll on deploy" <<<"$out"' \
       "a container port with no host side binds nothing a second replica would clash on (said '$out')"
sed -i '/^    healthcheck:$/,/^      test:/d' "$proj16c/compose.prod.yml"
out="$(cd "$proj16c" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]' "no compose healthcheck is a warning too (got $rc)"
assert 'grep -qF "⚠ demo-web rolls on deploy only if its image declares a HEALTHCHECK — compose gives it none, and without one it is recreated in place, briefly unrouted" <<<"$out"' \
       "with no compose healthcheck, rolling is the image's to decide (said '$out')"
out="$(cd "$proj16c" && "$kasbah" check --fix --yes 2>&1)"
assert 'grep -qF "nothing --fix can change" <<<"$out"' "and --fix leaves C11 alone (said '$out')"

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
assert 'grep -qF "✓ No internal services on the kasbah network or kasbah-net" <<<"$out"' \
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
        certResolver: http
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

# --- Case 22: T04 — websecure without the http resolver → fail --------------
proj22="$tmpdir/no-cert-resolver"
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
assert 'grep -qF "✗ Websecure routers without tls.certResolver=http: demo" <<<"$out"'          "T04 fail line"
assert '! grep -qF "renamed" <<<"$out"'                                                        "T04 fail line does not name the rename"

# --- Case 22b: T04 — the resolver's former name → fail naming the rename -----
proj22b="$tmpdir/legacy-cert-resolver"
make_project "$proj22b"
cat > "$proj22b/traefik-dynamic.yml" <<'YAML'
http:
  routers:
    demo:
      rule: "Host(`demo.example.com`)"
      entryPoints: [websecure]
      tls:
        certResolver: letsencrypt
      service: noop@internal
    other:
      rule: "Host(`other.example.com`)"
      entryPoints: [websecure]
      tls:
        certResolver: acme
      service: noop@internal
YAML
out="$(cd "$proj22b" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                                                       "T04 legacy name exits 6 (got $rc)"
assert 'grep -qF "✗ certResolver letsencrypt was renamed to http — set tls.certResolver: http on: demo" <<<"$out"' "T04 legacy-name line"
assert 'grep -qF "✗ Websecure routers without tls.certResolver=http: other" <<<"$out"'         "T04 other wrong value keeps the generic line"
assert '! grep -qF "Secure routers reference" <<<"$out"'                                       "T04 legacy name is no pass"
assert 'grep -qF ", 3 failed" <<<"$out"'                                                       "T04 counts each of its two lines as a failure (the third is C07: demo-web on the kasbah network, unrouted)"

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
        certResolver: http
      service: noop@internal
    demo-mail:
      rule: "Host(`mail.demo.example.com`)"
      entryPoints: [websecure]
      tls:
        certResolver: http
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
        certResolver: http
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
assert 'grep -qF "27 passed, 1 warning, 0 failed" <<<"$out"'                       "one line either way (said '$(tail -1 <<<"$out")')"

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
        certResolver: http
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
        certResolver: http
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
assert 'grep -qF "28 passed, 0 warning, 0 failed" <<<"$out"'                             "and nothing warns (said '$(tail -1 <<<"$out")')"

# --- Case 23c: T09 — a router or service reaches api@internal → fail --------
# Routing a hostname to Traefik's own API publishes it with no auth, whatever
# `server init --no-dashboard` said. The redirect router's noop@internal stays.
proj23c="$tmpdir/internal-api"
make_project "$proj23c"
cat > "$proj23c/traefik-dynamic.yml" <<'YAML'
http:
  routers:
    demo-http:
      rule: "Host(`demo.example.com`)"
      entryPoints: [web]
      service: noop@internal
    demo:
      rule: "Host(`demo.example.com`)"
      entryPoints: [websecure]
      tls:
        certResolver: http
      service: api@internal
  services:
    split:
      weighted:
        services:
          - name: dashboard@internal
YAML
out="$(cd "$proj23c" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                                           "T09 fail exits 6 (got $rc)"
assert 'grep -qF "✗ Fragment routes to Traefik'"'"'s internal services (only noop@internal is allowed): demo→api@internal services.split→dashboard@internal" <<<"$out"' \
       "T09 fail line names router, service and the weighted entry (said '$out')"
assert '! grep -qF "noop@internal services" <<<"$out" && ! grep -qF "demo-http→" <<<"$out"' "T09 leaves noop@internal alone"

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
assert 'grep -qF "✗ manifest health.container '"'"'nonexistent-container'"'"' is neither a container_name nor a service in compose" <<<"$out"' "H02 fail line"

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
assert 'grep -qF "28 passed, 0 warning, 0 failed" <<<"$out"'                   "and nothing warns about it (said '$(tail -1 <<<"$out")')"

# --- Case 28: E01 — invalid line → fail --------------------------------------
proj28="$tmpdir/env-bad-syntax"
make_project "$proj28"
# Inject a garbage line that's neither a comment, blank, nor NAME=value.
printf 'this is not valid env syntax\n' >> "$proj28/.env.prod.example"
out="$(cd "$proj28" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                                            "E01 fail exits 6 (got $rc)"
assert 'grep -qF "✗ .env.prod.example has invalid lines" <<<"$out"'                 "E01 fail line"

# --- Case 28b: the four env rules read a line the way Compose does -----------
# internal/env sees leading blanks and an `export ` prefix as an assignment
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
assert 'grep -qF "✓ .env.prod.example syntax is valid" <<<"$out"'            "E01 accepts what the env setup accepts (said '$out')"
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
assert 'grep -qF "27 passed, 1 warning, 0 failed" <<<"$out"'                 "E05 warns instead of passing, one line either way (said '$out')"

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
assert 'grep -qF "✗ Hooks reference names that are neither a container_name nor a service: ghost-container" <<<"$out"' "HK01 fail line"

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
assert 'grep -qF "✗ Backup hook container '"'"'not-in-compose'"'"' is neither a container_name nor a service in compose" <<<"$out"' "HK03 fail line"

# --- Case 35: HK01–03 — full valid hooks + backup → pass --------------------
# Regression guard for the hooks extraction and the container_name set assembly.
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
    printf '        certResolver: http\n'
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
assert 'grep -qF "✓ All hook commands target a container_name or service in compose" <<<"$out"' "HK01 pass line"
assert 'grep -qF "✓ Backup hook has check, command, and extension" <<<"$out"'  "HK02 pass line"
assert 'grep -qF "✓ Backup hook container '"'"'demo-db'"'"' exists in compose" <<<"$out"' "HK03 pass line"

# --- Case 35b: hooks, health and backup name services, not container_names --
proj35b="$tmpdir/hk-services"
make_project "$proj35b"
cat >> "$proj35b/kasbah.yml" <<'YAML'

health:
  container: demo-web
hooks:
  post-deploy:
    - demo-web echo after
backup:
  container: demo-web
  check: "true"
  command: "echo dump"
  extension: txt
YAML
out="$(cd "$proj35b" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]' "service names as hook, health and backup targets pass (got $rc: $out)"
assert 'grep -qF "✓ All hook commands target a container_name or service in compose" <<<"$out"' "HK01 takes a service name"
assert 'grep -qF "✓ manifest health.container '"'"'demo-web'"'"' exists in compose" <<<"$out"' "health.container takes a service name"
assert 'grep -qF "✓ Backup hook container '"'"'demo-web'"'"' exists in compose" <<<"$out"' "HK03 takes a service name"

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
{ printf 'http:\n  routers:\n    demo:\n      rule: "Host(`x.test`)"\n      entryPoints: [websecure]\n      tls:\n        certResolver: http\n      service: noop@internal\n'; } > "$proj37/traefik-dynamic.yml"
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
assert 'grep -qF "⚠ Services with literal resource limits: demo-web(cpus=1.5) — a literal does not follow the host'"'"'s ceiling" <<<"$out"' "R01 warns on a literal cpus locally"
assert '! grep -qF "malformed resource limits" <<<"$out"' "R01/R02 pass a literal"
assert 'grep -qF "✗ Services declare resource reservations: demo-web" <<<"$out"'                "R03 fail line"

# --- Case 40b: R01/R02 malformed literals fail -----------------------------
sed -e 's/^    cpus: "1.5"$/    cpus: 1,5/' -e 's/^    mem_limit: ${KASBAH_MEM_LIMIT}$/    mem_limit: 0/' \
    -e '/^    mem_reservation:/d' "$proj40/compose.prod.yml" > "$proj40/c.next" && mv "$proj40/c.next" "$proj40/compose.prod.yml"
out="$(cd "$proj40" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]' "malformed limits exit 6 (got $rc)"
assert 'grep -qF "✗ Services with missing or malformed resource limits: demo-web(cpus,mem_limit) — each sets cpus: \${KASBAH_CPU_LIMIT} or a positive number" <<<"$out"' \
    "R01/R02 fail '1,5' and a zero size (said '$out')"

# --- Case 41: T07 — fragment targets a name nothing answers to ---------------
proj41="$tmpdir/t07-unknown-target"
make_project "$proj41"
# Compose renames the service and its container; the make_project fragment
# still targets demo-web. The routed set is now empty, so C03/C07 stay quiet —
# T07 is the rule that catches the dangling reference.
cat > "$proj41/compose.prod.yml" <<'YAML'
services:
  demo-app:
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
assert 'grep -qF "✗ Fragment targets names no service answers to: demo-web (target a service on the kasbah network, one of its kasbah aliases, or a container_name)" <<<"$out"' "T07 fail line"

# --- Case 41b: T07 — a kasbah alias, and a service name only on kasbah-net ---
proj41b="$tmpdir/t07-alias"
make_project "$proj41b"
sed -i 's|^    networks: \[kasbah, internal\]|    networks:\n      kasbah:\n        aliases: [demo-site]\n      internal: {}|' "$proj41b/compose.prod.yml"
sed -i 's|http://demo-web:|http://demo-site:|' "$proj41b/traefik-dynamic.yml"
out="$(cd "$proj41b" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]' "a fragment targeting a kasbah alias passes (got $rc: $out)"
assert 'grep -qF "✓ Fragment loadBalancer URLs target a service, alias or container_name compose defines" <<<"$out"' "T07 pass line for an alias"
assert 'grep -qF "✓ All routed services join the project'"'"'s kasbah network" <<<"$out"' "the aliased service counts as routed (C03)"

proj41c="$tmpdir/t07-legacy-service"
make_project "$proj41c"
sed -i 's|^    networks: \[kasbah, internal\]|    networks: [kasbah-net, internal]|; s|^  kasbah: {}|  kasbah-net:\n    external: true|' "$proj41c/compose.prod.yml"
out="$(cd "$proj41c" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]' "a service name on kasbah-net fails T07 (got $rc)"
assert 'grep -qF "✗ Fragment targets services on kasbah-net by name: demo-web — there every project'"'"'s same-named service answers too" <<<"$out"' \
    "T07 says kasbah-net needs a container_name ($out)"
sed -i 's|^    image: nginx:alpine|    image: nginx:alpine\n    container_name: demo-web|' "$proj41c/compose.prod.yml"
out="$(cd "$proj41c" && "$kasbah" check 2>&1)"
assert 'grep -qF "✓ Fragment loadBalancer URLs target a service, alias or container_name compose defines" <<<"$out"' \
    "with container_name set, the legacy shape passes T07"

proj41d="$tmpdir/t07-no-network"
make_project "$proj41d"
sed -i '/^    networks: \[kasbah, internal\]/d' "$proj41d/compose.prod.yml"
out="$(cd "$proj41d" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]' "a routed service on no network fails (got $rc)"
assert 'grep -qF "✗ Fragment targets services on no Traefik network: demo-web — join them to the kasbah network" <<<"$out"' \
    "T07 says it is on no Traefik network, not kasbah-net ($out)"
assert '! grep -qF "kasbah-net by name" <<<"$out"' "and does not talk of kasbah-net"

# --- Case 42: a name kasbah owns on the server -------------------------------
# The project should learn this from `check`, not from the deploy that syncs
# over the shared Traefik stack and then removes it as an orphan. It is a
# manifest rule, so it arrives the same way a bad schema does: the manifest reader
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

# --- Mail (M01) --------------------------------------------------------------
# Local rules, and only when the manifest has a `mail:` block. M03 — "the stack
# on the VPS knows this domain" — is a --server rule and is not here; deploy
# asks the registry that question and warns.
projm="$tmpdir/mail-ok"
make_project "$projm" mailer mailer.example.com
printf 'mail:\n  domain: mailer.example.com\n' >> "$projm/kasbah.yml"
out="$(cd "$projm" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]' "a complete mail: block passes (rc $rc)
        $out"
assert 'grep -qF "Mail claim names domain '\''mailer.example.com'\''" <<<"$out"' \
    "M01 names the claimed domain (said '$out')"

# The control that makes the section conditional mean something: no mail: block,
# no Mail section at all. Without it, every assertion above is satisfied by a
# check that prints the heading unconditionally.
out="$(cd "$tmpdir/ok" && "$kasbah" check 2>&1)"
assert '! grep -qF "Mail:" <<<"$out"' \
    "a project with no mail: block is not asked about mail (said '$out')"

# M01: a block with no domain.
projm2="$tmpdir/mail-nodomain"
make_project "$projm2" mailer2 mailer2.example.com
printf 'mail: {}\n' >> "$projm2/kasbah.yml"
out="$(cd "$projm2" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]' "M01 fails a mail: block with no domain: (rc $rc)"
assert 'grep -qF "mail: has no domain:" <<<"$out"' "saying which field (said '$out')"

# A mail: that is not a block. The operator gets the shape, in deploy's words.
projm3="$tmpdir/mail-scalar"
make_project "$projm3" mailer3 mailer3.example.com
printf 'mail: mailer3.example.com\n' >> "$projm3/kasbah.yml"
out="$(cd "$projm3" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]' "a scalar mail: fails (rc $rc)"
assert 'grep -qF "✗ kasbah.yml: mail: is not a block — it has to be a block with a domain: under it" <<<"$out"' \
    "naming what it found, as deploy does (said '$out')"
assert '! grep -qF "Cannot index" <<<"$out"' "and not a type error (said '$out')"


# =============================================================================
# `check --server USER@HOST` — the VPS-aware rules
# =============================================================================
# The rules themselves, in every state a rig cannot be put into on demand, are
# Go tests (internal/check/server_test.go) driven through a fake session; the
# rig-driven half is tests/integration/check_server_test.sh. What is left here
# is the command line, which needs no server.
srvl="$tmpdir/srv-laststate"
make_project "$srvl"
out="$(cd "$srvl" && "$kasbah" check --server 2>&1)"; rc=$?
assert '[ "$rc" = "1" ]' "a bare --server on a project with no last_server is refused (rc $rc)"
assert 'grep -qF "has never talked to one" <<<"$out"' "saying so (said '$out')"
assert 'grep -qF "last_server" <<<"$out"' "and naming where the value would live (said '$out')"
assert '! grep -qF "Checking" <<<"$out"' "before any report is printed (said '$out')"
out="$(cd "$srvl" && "$kasbah" check --server= 2>&1)"; rc=$?
assert '[ "$rc" = "1" ]' "an empty --server= is refused rather than falling back to it (rc $rc)"
assert 'grep -qF "must name the server to ask" <<<"$out"' "saying so (said '$out')"
out="$(cd "$srvl" && "$kasbah" check --help 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]' "--help exits 0 (rc $rc)"
assert 'grep -qF -- "--server USER@HOST" <<<"$out"' "--help documents the flag (said '$out')"


# =============================================================================
# `check --fix` — the auto-fixable half of docs/compliance.md
# =============================================================================
# Two things every case here does on purpose.
#
# Whole files are compared with `cmp`, never through `$(cat …)`: command
# substitution strips trailing newlines, so a fix that appended one per run
# would compare equal for ever — which is exactly how 8.3 shipped a file that
# grew a newline every time (plan/roadmap/08-keep.md → 8.3).
#
# And each `before` carries comments above, inside and below the block being
# edited, blank lines, and hand-spacing, because the whole reason --fix is a
# line editor rather than a parse-and-dump round trip is that those survive it. An
# assertion that only checked the rule now passes would be satisfied by a
# reformatter.

# fx_project DIR — the make_project scaffold (manifest, template, .gitignore and
# a fragment routing demo-web) with compose.prod.yml taken from stdin.
fx_project() {
    local dir="$1"
    make_project "$dir"
    cat > "$dir/compose.prod.yml"
}

# fx_run DIR — `check --fix --yes` in DIR. Each file it wrote must be what its
# shown diff makes of the file before, through GNU patch: a miss is recorded in
# fx_trips.fail, a success counted in fx_trips.ok, and both judged at the end.
fx_run() {
    local dir="$1" snap rc out f
    snap="$(mktemp -d "$tmpdir/fx-before.XXXXXX")"
    for f in compose.prod.yml kasbah.yml; do
        [ ! -e "$dir/$f" ] || cp "$dir/$f" "$snap/$f"
    done
    out="$(cd "$dir" && "$kasbah" check --fix --yes 2>&1)"; rc=$?
    fx_roundtrip "$dir" "$snap" "$out"
    printf '%s\n' "$out"
    return "$rc"
}

# The diffs are printed back to back from the first `--- a/` and end at the
# first empty line, which no diff line can be.
gnu_patch() {
    local v
    v="$(patch --version 2>/dev/null)" || return 1
    grep -q GNU <<<"${v%%$'\n'*}"
}

fx_roundtrip() {
    local dir="$1" snap="$2" out="$3" diffs msg f
    diffs="$(awk '/^--- a\// { on = 1 } on && /^$/ { exit } on { print }' <<<"$out")"
    [ -n "$diffs" ] || return 0
    gnu_patch || return 0
    msg="$(cd "$snap" && printf '%s\n' "$diffs" | patch --binary --force --fuzz=0 \
        --no-backup-if-mismatch -p1 2>&1)" ||
        { printf '%s: patch failed: %s\n' "$dir" "$msg" >> "$tmpdir/fx_trips.fail"; return 0; }
    if grep -q Hunk <<<"$msg"; then
        printf '%s: not clean: %s\n' "$dir" "$msg" >> "$tmpdir/fx_trips.fail"
    fi
    for f in compose.prod.yml kasbah.yml; do
        [ -e "$snap/$f" ] || continue
        cmp -s "$snap/$f" "$dir/$f" ||
            printf '%s: %s through patch is not the file written\n' "$dir" "$f" >> "$tmpdir/fx_trips.fail"
    done
    echo "$dir" >> "$tmpdir/fx_trips.ok"
}

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
          pids: 100
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
          pids: 100

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
            kasbah:
        logging:
            driver: json-file
            options:
                max-size: "10m"
                max-file: "3"

networks:
    internal: {}
    kasbah: {}
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
printf 'services:\n  demo-web:\n    image: nginx:alpine\n    container_name: demo-web\n    restart: unless-stopped\n    cpus: ${KASBAH_CPU_LIMIT}\n    mem_limit: ${KASBAH_MEM_LIMIT}\n    networks:\n      internal: {}\n      kasbah:\n    logging:\n      driver: json-file\n      options:\n        max-size: "10m"\n        max-file: "3"\n\nnetworks:\n  kasbah: {}' > "$f5/expected"
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
assert 'grep -qxF "kasbah_version: $(kasbah_base_version)" "$f7/kasbah.yml"' \
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
assert 'grep -qF "✗ Hooks reference names that are neither a container_name nor a service: nope" <<<"$out"' "F8: HK01 still reported"
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
# leave — a flow-mapping network, a removed logging block, a reservation — and
# has to come back to exit 0 with all of that prose still in it; its literal
# cpus: and mem_limit: are the author's and stay as written.
f11="$tmpdir/fix-fixture"
mkdir -p "$f11"
cp -a "$repo_dir/tests/fixtures/demo/." "$f11/"
printf '.env\n.kasbah/\n' > "$f11/.gitignore"
comments_before="$(grep -c '#' "$f11/compose.prod.yml")"
# Line-oriented on purpose: sed, so the breakage is legible next to the
# fixture it is applied to.
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
assert 'grep -qxF "    cpus: \"0.5\"" "$f11/compose.prod.yml"' "F11: a literal cpus is the author's, left alone"
assert 'grep -qxF "    mem_limit: 512m" "$f11/compose.prod.yml"' "F11: and so is a literal mem_limit"
assert '[ "$(grep -c "#" "$f11/compose.prod.yml")" = "$comments_before" ]' \
    "F11: every one of the $comments_before comment lines survived (found $(grep -c '#' "$f11/compose.prod.yml"))"
assert 'grep -qF "compose publishes the service name" "$f11/compose.prod.yml"' \
    "F11: including the one inside the block that was edited"
assert 'grep -qF "about the split C03/C07 enforce." "$f11/compose.prod.yml"' \
    "F11: and the one inside the networks list that gained a member"
assert '[ "$(yaml2json "$f11/compose.prod.yml" | jq -r ".services[\"demo-web\"].networks | join(\",\")")" = "internal,kasbah" ]' \
    "F11: the routed service that lost kasbah-net is given the project's own kasbah network"

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
# default. C03 adds kasbah there by writing `default` alongside it — joining
# the routed network must not quietly take the service off the one it had, which
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
      - kasbah

networks:
  kasbah: {}
YAML
out="$(fx_run "$f14")"; rc=$?
assert '[ "$rc" = "0" ]' "F14: the fixed project passes (rc $rc)
$out"
assert 'cmp -s "$f14/compose.prod.yml" "$f14/expected"' \
    "F14: deepest-first, and the implicit default written out$(diff -u "$f14/expected" "$f14/compose.prod.yml" 2>&1 || true)"
# Paired positives, so the byte comparison is not the only thing holding these
# two properties up. Both would still parse if they were wrong: `restart` as a
# logging option is legal YAML, and dropping `default` is legal compose.
assert '[ "$(yaml2json "$f14/compose.prod.yml" | jq -r ".services[\"demo-web\"].restart")" = "unless-stopped" ]' \
    "F14: restart landed on the service, not inside logging.options"
assert '[ "$(yaml2json "$f14/compose.prod.yml" | jq -r ".services[\"demo-web\"].logging.options | keys | length")" = "2" ]' \
    "F14: and logging.options gained exactly the one key it was missing"
assert '[ "$(yaml2json "$f14/compose.prod.yml" | jq -r ".services[\"demo-web\"].networks | join(\",\")")" = "default,kasbah" ]' \
    "F14: the service is on kasbah and still on the default it had"
assert 'grep -qF "default spelled out so the service keeps the network it had" <<<"$out"' \
    "F14: and the plan says why (said '$out')"

# --- Case F15: rewritten in place, never appended beside ---------------------
# Every rule here fails on a value rather than on a missing key, so the repair
# is a rewrite of the line that is already there. Appending the right key next
# to the wrong one would satisfy the rule just as well — compose and kasbah's
# reader both take the last of two duplicate keys — and would leave a file saying two
# things. Hence the per-key counts below, which are what tell the two apart.
f15="$tmpdir/fix-rewrite"
fx_project "$f15" <<'YAML'
services:
  demo-web:
    image: nginx:alpine
    container_name: demo-web
    restart: "no"     # compose's default, spelled out
    cpus: "half"
    mem_limit: lots   # sized for the old box
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
# would pass every rule and every lookup above.
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
# The scanner's blockEnd walks past blank and comment lines to find a block's last
# content line. Under a `|` or `>` header those lines are not blanks and
# comments, they are the value — so without a rule for it the block's "last
# line" lands in the middle of a shell script and an insertion is spliced into
# it. That splice parses, keeps every top-level and service key, and settles, so
# every guard downstream waves it through while two lines vanish from a string.
#
# Three shapes in one file, and the last-key ones are the ones that bite:
#   demo-mid   a scalar that is the service's *first* key, with more keys after
#              it — the case that already worked, pinned so it stays working,
#              and the witness for childIndent needing no rule of its own
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
f16_mid="$(yaml2json "$f16/compose.prod.yml" | jq -r '.services["demo-mid"].entrypoint' | od -An -c)"
f16_web="$(yaml2json "$f16/compose.prod.yml" | jq -r '.services["demo-web"].entrypoint' | od -An -c)"
f16_keep="$(yaml2json "$f16/compose.prod.yml" | jq -r '.services["demo-keep"].command' | od -An -c)"
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
assert '[ "$(yaml2json "$f16/compose.prod.yml" | jq -r ".services[\"demo-mid\"].entrypoint" | od -An -c)" = "$f16_mid" ]' \
    "F16: demo-mid's scalar is the same string it was"
assert '[ "$(yaml2json "$f16/compose.prod.yml" | jq -r ".services[\"demo-web\"].entrypoint" | od -An -c)" = "$f16_web" ]' \
    "F16: demo-web's scalar kept the two comment lines that are its text"
assert '[ "$(yaml2json "$f16/compose.prod.yml" | jq -r ".services[\"demo-keep\"].command" | od -An -c)" = "$f16_keep" ]' \
    "F16: demo-keep's |+ kept the trailing newlines that are its value"
# And the negative that would otherwise be vacuous on its own: a `restart:` key
# spliced into a scalar becomes part of the string, so it must not be there.
assert '! grep -qF "restart" <<<"$(yaml2json "$f16/compose.prod.yml" | jq -r ".services[\"demo-web\"].entrypoint")"' \
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
# refused both and the expected file said so: the references have to be read back.
assert '[ "$(yaml2json "$f17/compose.prod.yml" | jq -r ".services[\"demo-web\"].cpus")" = "\${KASBAH_CPU_LIMIT}" ]' \
    "F17: cpus reads as the variable reference"
assert '[ "$(yaml2json "$f17/compose.prod.yml" | jq -r ".services[\"demo-web\"].mem_limit")" = "\${KASBAH_MEM_LIMIT}" ]' \
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
# `--fix` renames its candidate over the real file and the report then runs the
# whole rule set over that path. Documents are read once per file per phase
# and nothing watches mtimes, so "the report is about the file that is there
# now" is a fact somebody has to arrange rather than one that falls out.
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
# --- Case F21: a document that does not parse yields no services at all ------
# A reader can write the documents it managed to read *and* exit non-zero, so
# a multi-document compose file with one broken document has a good half. That
# half is dropped: the rules see one unreadable file rather than a project made
# of whichever documents happened to survive. Pinned because the failure it
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
# readable — its first document converts on its own. A fixture that failed
# outright would satisfy everything below while proving nothing.
f21_whole="$(cd "$f21" && yaml2json compose.prod.yml 2>/dev/null)"; f21_rc=$?
assert '[ "$f21_rc" != 0 ] && [ -z "$f21_whole" ]' "F21: the fixture does not parse (rc $f21_rc, said '$f21_whole')"
f21_half="$(sed '/^---$/q' "$f21/compose.prod.yml" | yaml2json 2>/dev/null)"
assert 'grep -q "demo-web" <<<"$f21_half"' \
    "F21: and yet its first document converts (said '$f21_half')"

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


# --- A question check cannot answer ends the run with exit 1, said why -------
# A string where a service's mapping belongs: the report stops there.
projq="$tmpdir/unanswerable"
make_project "$projq"
printf 'services:\n  web: nginx\n' > "$projq/compose.prod.yml"
out="$(cd "$projq" && "$kasbah" check 2>"$tmpdir/q.err")"; rc=$?
assert '[ "$rc" = "1" ]' "an unanswerable question is exit 1 (got $rc)"
assert 'grep -qxF "error: cannot check compose.prod.yml: services.web is a string, not a mapping" "$tmpdir/q.err"' \
    "naming the file and the key it could not check (said '$(cat "$tmpdir/q.err")')"
assert '! grep -qF "Summary:" <<<"$out"' "and the report is cut short, with no summary"
# A service name holding a quote is a name like any other: the rules judge it.
printf '%s\n' 'services:' "  'we\"b': {image: nginx}" > "$projq/compose.prod.yml"
out="$(cd "$projq" && "$kasbah" check 2>"$tmpdir/q.err")"; rc=$?
assert '[ "$rc" = "6" ] && grep -qxF "  ✗ Services missing restart policy: we\"b" <<<"$out"' \
    "a name holding a quote is checked, and named in the failure (exit $rc: $out $(cat "$tmpdir/q.err"))"

# --- Per-project networks: the legacy fixture, an external kasbah, mail-dms ----
# tests/fixtures/demo stays on the shared kasbah-net on purpose: 1.x serves it,
# and check passes it with a warning to move.
projn="$tmpdir/legacy-fixture"
mkdir -p "$projn"
cp -a "$repo_dir/tests/fixtures/demo/." "$projn/"
printf '.env\n.kasbah/\n' > "$projn/.gitignore"
out="$(cd "$projn" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]' "the legacy kasbah-net fixture still passes (exit $rc: $out)"
assert 'grep -qF "⚠ Routed through the shared kasbah-net: demo-web — " <<<"$out"' \
    "and is warned to move to a project kasbah network (said '$out')"
out="$(cd "$projn" && "$kasbah" check --fix 2>&1)"; rc=$?
assert 'cmp -s "$projn/compose.prod.yml" "$repo_dir/tests/fixtures/demo/compose.prod.yml"' \
    "--fix leaves a legacy kasbah-net project's compose alone (said '$out')"

projk="$tmpdir/external-kasbah"
make_project "$projk"
sed -i 's/^  kasbah: {}$/  kasbah: {external: true}/' "$projk/compose.prod.yml"
out="$(cd "$projk" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]' "an external kasbah network fails (exit $rc)"
assert 'grep -qF "✗ The kasbah network is declared external — it is the project'"'"'s own" <<<"$out"' \
    "C04 names it (said '$out')"

# A service alias that is another project's container_name answers for it once
# Traefik sits on both networks: every name on the kasbah network is the project's.
projs9="$tmpdir/shadowing-alias"
make_project "$projs9"
sed -i 's/^    networks: \[kasbah, internal\]$/    networks:\n      kasbah: {aliases: [krvb-w]}\n      internal: {}/' "$projs9/compose.prod.yml"
out="$(cd "$projs9" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]' "a foreign alias on the kasbah network fails (exit $rc: $out)"
assert 'grep -qF "✗ Names on the kasbah network that are not '"'"'demo'"'"' or '"'"'demo-*'"'"': krvb-w (alias of demo-web)" <<<"$out"' \
    "C09 names the alias and its service (said '$out')"

projd="$tmpdir/kasbah-with-settings"
make_project "$projd"
sed -i 's/^  kasbah: {}$/  kasbah:\n    driver: bridge/' "$projd/compose.prod.yml"
printf '  shared:\n    name: mail_kasbah\n    external: true\n' >> "$projd/compose.prod.yml"
out="$(cd "$projd" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]' "a kasbah network with settings, and another stack's network, fail (exit $rc)"
assert 'grep -qF "✗ The kasbah network sets driver — declare it as kasbah: {}" <<<"$out"' "C04 names the setting (said '$out')"
assert 'grep -qF "✗ External networks other than kasbah-net: shared (mail_kasbah)" <<<"$out"' "and the foreign network (said '$out')"

projm="$tmpdir/names-mail-dms"
make_project "$projm"
printf '# SMTP_HOST=mail-dms, before the move\n' >> "$projm/.env.prod.example"
out="$(cd "$projm" && "$kasbah" check 2>&1)"
assert '! grep -qF "mail-dms is named" <<<"$out"' "a comment naming mail-dms is not a use of it (said '$out')"
printf 'SMTP_HOST=mail-dms\n' >> "$projm/.env.prod.example"
out="$(cd "$projm" && "$kasbah" check 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]' "naming mail-dms is a warning (exit $rc)"
assert 'grep -qF "⚠ mail-dms is named in .env.prod.example — " <<<"$out"' \
    "and says the template can no longer reach it (said '$out')"
assert 'grep -qF "mail.<domain>:587" <<<"$out"' "pointing at public submission"

# --- The --fix diffs, through GNU patch (fx_run) -----------------------------
if ! gnu_patch; then
    echo "GNU patch is needed: every --fix diff shown here is applied with it" >&2
    [ "$fail" -ne 0 ] || exit 2
fi
trips="$(cat "$tmpdir/fx_trips.ok" 2>/dev/null | wc -l)"
assert '[ ! -s "$tmpdir/fx_trips.fail" ]' "the --fix diffs apply exactly with GNU patch:
$(cat "$tmpdir/fx_trips.fail" 2>/dev/null)"
assert '[ "$trips" -ge 10 ]' "at least 10 --fix diffs went through GNU patch (got $trips)"

exit "$fail"
