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

# Scaffold a passing project: init-project + a minimal-but-valid compose.prod.yml
# that satisfies all Compose rules (C01–C05).
make_project() {
    local dir="$1" name="${2:-demo}" domain="${3:-demo.example.com}"
    mkdir -p "$dir"
    (cd "$dir" && "$hosting" init-project --name="$name" --domain="$domain" >/dev/null)
    cat > "$dir/compose.prod.yml" <<'YAML'
services:
  app:
    image: nginx:alpine
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
assert 'grep -qF "✓ All services join hosting-net" <<<"$out"'                   "C03 pass line"
assert 'grep -qF "✓ hosting-net declared external" <<<"$out"'                   "C04 pass line"
assert 'grep -qF "✓ No deprecated '"'"'version:'"'"' field" <<<"$out"'          "C05 pass line"
assert 'grep -qF "10 passed, 0 warning, 0 failed" <<<"$out"'   "summary all pass"

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

# --- Case 15: C03 — service not on hosting-net → fail, exit 6 ---------------
# No hosting-net alias on default, no explicit service reference.
proj15="$tmpdir/no-hostingnet"
make_project "$proj15"
cat > "$proj15/compose.prod.yml" <<'YAML'
services:
  app:
    image: nginx:alpine
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
YAML
out="$(cd "$proj15" && "$hosting" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                              "C03 fail exits 6 (got $rc)"
assert 'grep -qF "✗ Services not on hosting-net: app" <<<"$out"'      "C03 fail line"

# --- Case 16: C04 — hosting-net referenced but not external → fail, exit 6 --
proj16="$tmpdir/hostingnet-not-external"
make_project "$proj16"
cat > "$proj16/compose.prod.yml" <<'YAML'
services:
  app:
    image: nginx:alpine
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    networks: [hosting-net]
networks:
  hosting-net: {}
YAML
out="$(cd "$proj16" && "$hosting" check 2>&1)"; rc=$?
assert '[ "$rc" = "6" ]'                                                  "C04 fail exits 6 (got $rc)"
assert 'grep -qF "✓ All services join hosting-net" <<<"$out"'             "C03 still passes"
assert 'grep -qF "✗ hosting-net not declared external: true" <<<"$out"'   "C04 fail line"

# --- Case 17: C05 — top-level `version:` → warn, exit 0 ---------------------
proj17="$tmpdir/version-field"
make_project "$proj17"
cat > "$proj17/compose.prod.yml" <<'YAML'
version: "3.8"
services:
  app:
    image: nginx:alpine
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

exit "$fail"
