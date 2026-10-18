#!/usr/bin/env bash
# Test: plain `kasbah check` in Go answers as the Bash implementation does —
# the same stdout byte for byte (every rule's verdict line, the section
# headers, the summary) and the same exit code — over a corpus of projects:
# the fixtures, odd and broken inputs written here, the YAML documents
# tests/yamlx captured placed into minimal projects, any directories named in
# KASBAH_PARITY_PROJECTS (colon-separated), and every project
# tests/check_test.sh builds, by running that suite through a KASBAH_BIN shim
# that compares each plain `check` before handing it to the real binary.
#
# Lives until the Bash tool does (docs/phases/10-recast.md, 10.14).

set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
. "$repo_dir/tests/cli.sh"
real_bin="$KASBAH_BIN"
bash_bin="$repo_dir/libexec/kasbah-bash"

for tool in yq jq; do
    command -v "$tool" >/dev/null || { echo "parity: $tool is required by the Bash side" >&2; exit 2; }
done

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
corpus="$tmpdir/corpus"
mkdir -p "$corpus"

# --- The comparison -----------------------------------------------------------

# The Bash side runs under C.UTF-8, the reading the Go binary fixes for every
# locale; the Go side runs under each of these and must not notice.
export PARITY_LOCALES="unset C C.UTF-8 en_US.UTF-8 fr_FR.UTF-8"

# go_in LOCALE ARGS… — the Go binary under one locale ("unset": none at all).
go_in() {
    local loc="$1"; shift
    if [ "$loc" = unset ]; then
        env -u LC_ALL -u LC_CTYPE -u LC_COLLATE -u LANG -u LANGUAGE "$PARITY_GO" "$@"
    else
        env -u LC_CTYPE -u LC_COLLATE LC_ALL="$loc" LANG="$loc" "$PARITY_GO" "$@"
    fi
}

# compare DIR OUT — one line on stdout: "same DIR" or "DIFF DIR …", the outputs
# kept in OUT for the report.
compare() {
    local d="$1" out="$2" brc=0 grc loc why=""
    mkdir -p "$out"
    (cd "$d" && LC_ALL=C.UTF-8 "$PARITY_BASH" check >"$out/bash.out" 2>"$out/bash.err") || brc=$?
    for loc in $PARITY_LOCALES; do
        grc=0
        (cd "$d" && go_in "$loc" check >"$out/go.$loc.out" 2>"$out/go.$loc.err") || grc=$?
        if [ "$brc" != "$grc" ] || ! cmp -s "$out/bash.out" "$out/go.$loc.out"; then
            why="$why go[$loc] rc=$grc"
            cp "$out/go.$loc.out" "$out/go.out"
        fi
    done
    if [ -z "$why" ]; then
        echo "same $d"
    else
        echo "DIFF $d (bash rc=$brc;$why) — $out"
    fi
}
export -f compare go_in
export PARITY_BASH="$bash_bin" PARITY_GO="$real_bin"

# --- The corpus ---------------------------------------------------------------

n=0
# mk — a fresh passing project, the shape check_test.sh's make_project builds.
mk() {
    n=$((n + 1))
    p="$corpus/p$n"
    mkdir -p "$p"
    printf 'schema: 1\nkasbah_version: 0.1.0-dev\n\nname: demo\ndomain: "demo.example.com"\n' > "$p/kasbah.yml"
    printf '# template\nDOMAIN=demo.example.com\n' > "$p/.env.prod.example"
    printf '.env\n.kasbah/\n' > "$p/.gitignore"
    cat > "$p/compose.prod.yml" <<'YAML'
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
    cat > "$p/traefik-dynamic.yml" <<'YAML'
http:
  routers:
    demo-http:
      rule: "Host(`demo.example.com`)"
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
}
# put FILE CONTENT — replace one file of the newest project.
put() { printf '%s' "$2" > "$p/$1"; }

for f in "$repo_dir"/tests/fixtures/*/; do
    n=$((n + 1)); cp -a "$f" "$corpus/p$n"
done

# The captured documents, each as the compose file, the fragment and the
# manifest of an otherwise passing project.
for y in "$repo_dir"/internal/yamlx/testdata/captured/*.yml; do
    mk; cp "$y" "$p/compose.prod.yml"
    mk; cp "$y" "$p/traefik-dynamic.yml"
    mk; cp "$y" "$p/kasbah.yml"
done

# Whole-file shapes, in each of the three YAML roles.
for role in compose.prod.yml traefik-dynamic.yml kasbah.yml; do
    mk; put "$role" ''
    mk; put "$role" $'# only a comment\n'
    mk; put "$role" $'key: [unclosed\n'
    mk; put "$role" $'just a string\n'
    mk; put "$role" $'- a\n- b\n'
    mk; put "$role" $'42\n'
    mk; put "$role" $'\xef\xbb\xbf'"$(cat "$p/$role")"
    mk; sed -i 's/$/\r/' "$p/$role"
    mk; printf -- '---\n%s\n---\n%s\n' "$(cat "$p/$role")" "$(cat "$p/$role")" > "$p/$role.new"; mv "$p/$role.new" "$p/$role"
    mk; printf -- '%s\n---\n- x\n' "$(cat "$p/$role")" > "$p/$role.new"; mv "$p/$role.new" "$p/$role"
    mk; printf -- '%s\n---\nbroken: [\n' "$(cat "$p/$role")" > "$p/$role.new"; mv "$p/$role.new" "$p/$role"
    mk; rm "$p/$role"
    mk; rm "$p/$role"; mkdir "$p/$role"
done

# Manifests.
mk; put kasbah.yml $'schema: 2\nname: demo\n'
mk; put kasbah.yml $'schema: "1"\nname: demo\ndomain: ""\n'
mk; put kasbah.yml $'schema: 1.0\nname: demo\n'
mk; put kasbah.yml $'schema: 1\nname: Demo\n'
mk; put kasbah.yml $'schema: 1\nname: traefik\n'
mk; put kasbah.yml $'schema: 1\nname: demo\n'
mk; put kasbah.yml $'schema: 1\nname: demo\ndomain: |\n  a\n  b\n'
for client in '' 'acme' 'Acme' 'mail' '1abc' '42' 'true' '[a]' '"acme\r"' '{a: 1}' '|\n  acme\n'; do
    mk; printf 'schema: 1\nname: demo\ndomain: demo.example.com\nclient: %b\n' "$client" > "$p/kasbah.yml"
done
for block in 'health: {container: demo-web}' 'health: {container: nope}' 'health: {timeout: 30}' \
    'health: 30' 'health: [a]' 'health: false' 'health: 0' 'health: {container: ""}' \
    'hooks: {pre_deploy: ["demo-web echo hi", "nope run", "  lead", ""]}' 'hooks: {}' 'hooks: []' \
    'hooks: "demo-web x"' 'hooks: {a: "demo-web x"}' 'hooks: {a: [{x: 1}], b: [[demo-web]]}' 'hooks: [[demo-web go]]' \
    'backup: {container: demo-web, check: a, command: b, extension: c}' 'backup: {container: nope}' \
    'backup: {check: a}' 'backup: x' 'backup: [1]' 'backup: {container: null, check: 0, command: false, extension: ""}' \
    'mail: example.com' 'mail: {}' 'mail: {domain: example.com}' 'mail: [a]' 'mail: 7' 'mail: {domain: null}' \
    'mail: {domain: example.com, snappymail_domain: sm.json}' 'mail: {domain: example.com, snappymail_domain: none.json}'; do
    for sm in '' '{"a": 1}' '{a: 1}' 'null' 'false' '1 2' ' '; do
        case "$block" in *sm.json*) ;; *) [ -z "$sm" ] || continue ;; esac
        mk; printf '%s\n' "$block" >> "$p/kasbah.yml"
        [ -z "$sm" ] || printf '%s' "$sm" > "$p/sm.json"
    done
done

# Compose shapes.
svc() { # svc YAML-FOR-THE-SERVICE-BODY — a one-service compose file.
    mk; printf 'services:\n  demo-web:\n%s\nnetworks:\n  kasbah-net:\n    external: true\n' "$1" > "$p/compose.prod.yml"
}
base='    container_name: demo-web
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging: {driver: json-file, options: {max-size: 10m, max-file: "3"}}'
svc "$base"$'\n    networks: [kasbah-net]'
svc "$base"$'\n    networks: {kasbah-net: {}}'
svc "$base"$'\n    networks: kasbah-net'
svc "$base"$'\n    networks: 5'
svc "$base"
for r in 'no' 'always' 'on-failure' 'on-failure:3' 'on-failure:x' '"unless-stopped "' '[always]' '{a: 1}' '1'; do
    svc "${base/restart: unless-stopped/restart: $r}"$'\n    networks: [kasbah-net]'
done
for c in '0.5' '"${KASBAH_CPU_LIMIT}"' '${KASBAH_MEM_LIMIT}' '1e3' 'null'; do
    svc "${base/cpus: \$\{KASBAH_CPU_LIMIT\}/cpus: $c}"$'\n    networks: [kasbah-net]'
done
for extra in 'deploy: {resources: {reservations: {cpus: "1"}}}' 'mem_reservation: 1g' 'mem_reservation: null' \
    'deploy: {resources: {reservations: null}}' 'deploy: x' 'labels: ["traefik.enable=true"]' \
    'labels: {traefik.http.routers.x: y}' 'labels: [a=b, "x=traefik.y"]' 'labels: "traefik.x"' 'labels: 3' \
    'labels: ["a=b\ntraefik.c"]' 'labels: [1, true]' 'build: .' $'build: .\n    image: app:current' \
    $'build: .\n    image: app:1.2' $'build: .\n    image: reg:5000/app' $'build: .\n    image: app:current-rc1' \
    $'build: .\n    image: app:current\n    healthcheck: {test: x}' 'logging: {driver: json-file}' \
    'logging: x' 'container_name: [a]' 'container_name: 7'; do
    svc "$base"$'\n    networks: [kasbah-net]\n    '"$extra"
done
mk; put compose.prod.yml $'services:\n  demo-web: nginx\n'
mk; put compose.prod.yml $'services: [a, b]\n'
mk; put compose.prod.yml $'services: x\n'
mk; put compose.prod.yml $'services: {}\nversion: "3"\n'
mk; put compose.prod.yml $'version: "3.8"\nservices:\n  web: {image: x}\n'
mk; put compose.prod.yml $'services:\n  "": {image: x}\n  b: {image: y}\n'
mk; put compose.prod.yml $'services:\n  "a\\"b": {image: x}\n'
mk; put compose.prod.yml $'services:\n  "a\\\\nb": {image: x}\n'
mk; put compose.prod.yml $'services:\n  postgres: {image: x, networks: [kasbah-net]}\n  demo-web: {container_name: demo-web, networks: [kasbah-net]}\nnetworks: {kasbah-net: {external: true}}\n'
mk; put compose.prod.yml $'services:\n  web: {container_name: demo-web}\n  db: {image: pg}\nnetworks:\n  default: {name: kasbah-net, external: true}\n'
mk; put compose.prod.yml $'services:\n  web: {container_name: demo-web, networks: [internal]}\nnetworks:\n  default: {name: kasbah-net}\n'
mk; put compose.prod.yml $'services:\n  demo-web: {container_name: demo-web}\nnetworks: x\n'
mk; put compose.prod.yml $'services:\n  demo-web: {container_name: demo-web}\nnetworks: {kasbah-net: x}\n'
mk; put compose.prod.yml $'services:\n  demo: {container_name: demo-web, networks: [kasbah-net]}\n  demo-api: {networks: [kasbah-net]}\n  demox: {networks: [kasbah-net]}\nnetworks: {kasbah-net: {external: "true"}}\n'

# Fragments.
frag() { mk; printf 'http:\n%s\n' "$1" > "$p/traefik-dynamic.yml"; }
frag $'  routers:\n    a: {rule: "Host(`other.example.com`)", entryPoints: [websecure], tls: {certResolver: letsencrypt}}'
frag $'  routers:\n    a: {rule: "Host(`demo.example.com`)", entryPoints: [websecure], tls: {certResolver: le}}'
frag $'  routers:\n    a: {rule: "Host(`demo.example.com`)"}'
for ep in '[]' '""' '"web"' '0' '-2' '{}' '{a: web}' 'true' 'null' '[web, websecure]'; do
    frag $'  routers:\n    a: {rule: "Host(`demo.example.com`)", entryPoints: '"$ep"$', tls: {certResolver: letsencrypt}}'
done
frag $'  routers:\n    a: {rule: "Host(`traefik.example.com`) || Host(`demo.example.com`)", entryPoints: [web]}\n    b: {rule: "Host(`mail.x.y`)&&Host(`webmail`)&&Host(`mailhog.x`)&&Host(``)", entryPoints: [web]}'
frag $'  routers:\n    a: {rule: [x], entryPoints: [web]}'
frag $'  routers:\n    a: x'
frag $'  routers: [a, b]'
frag $'  routers: x'
frag $'  routers:\n    a: {rule: "Host(`demo.example.com`)", entryPoints: [web]}\n  services:\n    s1: {loadBalancer: {servers: [{url: "http://Zeta:80"}, {url: "https://a.b-c/x"}, {url: "zz"}, {url: "http://_u:1"}, {url: "http://a-b"}, {url: "http://ab"}, {url: ""}, {url: 8080}, {url: [1]}, {url: "  "}]}}\n    s2: {loadBalancer: {servers: x}}'
frag $'  routers:\n    a: {rule: "Host(`demo.example.com`)", entryPoints: [web]}\n  services:\n    s1: {loadBalancer: {servers: [{url: "http://demo-web:80"}, "x"]}}'
frag $'  routers:\n    a: {rule: "Host(`demo.example.com`)", entryPoints: [web]}\n  services: [{loadBalancer: {servers: [{url: "http://q"}]}}]'
frag $'  routers:\n    "a\\"x": {rule: "Host(`demo.example.com`)", entryPoints: [web]}'
mk; put kasbah.yml $'schema: 1\nname: demo\ndomain: ""\n'

# Env templates and drift.
tpl() { mk; printf '%b' "$1" > "$p/.env.prod.example"; [ $# -lt 2 ] || printf '%b' "$2" > "$p/.env"; }
tpl 'A=1\nB=2\n' 'A=1\n'
tpl 'A=1\n' 'A=1\nB=2\nKASBAH_X=1\n'
tpl 'b=1\nB=1\na_b=1\nab=1\nA_B=1\nAB=1\n_a=1\nZ=1\nB1=1\nB_1=1\nx2=1\nX10=1\n' ''
tpl '' 'b=1\nB=1\na_b=1\nab=1\nA_B=1\nAB=1\n_a=1\nZ=1\nB1=1\nB_1=1\n'
tpl 'export FOO=1\n  BAR=2\n\tBAZ=3\nFOO BAR=baz\n=v\n1FOO=x\n# c\n   # c\n\n   \n'
tpl 'A=1\r\nB=2\r\n' 'A=1\r\n'
tpl 'A=1' 'B=2'
tpl 'K=\xff\n#\xff\n\xe2\x80\x83K2=1\n\xc2\xa0K3=1\nK4=\xc3\xa9\n'
tpl 'LONG=0123456789012345678901234567890123456789012345678901234567890123456789\nGEN=! openssl rand -hex 64 0123456789012345678901234567890123456789\nHINT=# 0123456789012345678901234567890123456789012345678901234567890123456789\nIN=short # 0123456789012345678901234567890123456789012345678901234567890123456789\nEXACT=0123456789012345678901234567890123456789012345678901234567890123\nUNI=ééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééé\nNOSP=a#0123456789012345678901234567890123456789012345678901234567890123456789\n'
tpl 'KASBAH_CPU_LIMIT=1\nMY_KASBAH=2\nKASBAH_=3\nKASBAH_CPU_LIMIT=4\n'
tpl 'A=1\0B\n'
mk; rm "$p/.gitignore"
mk; put .gitignore $'.env\r\n.kasbah/\r\n'
mk; put .gitignore $'node_modules\n.env\n'
mk; put .gitignore $' .env\n.kasbah\n'
mk; put .gitignore $'.env'

if [ -n "${KASBAH_PARITY_PROJECTS:-}" ]; then
    IFS=: read -r -a extra <<<"$KASBAH_PARITY_PROJECTS"
    for d in "${extra[@]}"; do
        [ -n "$d" ] || continue
        n=$((n + 1)); cp -a "$d" "$corpus/p$n"
    done
fi

results="$tmpdir/results"
(cd "$corpus" && printf '%s\0' "$corpus"/p*/ | sed -z 's#/$##' \
    | xargs -0 -P "$(nproc)" -n1 bash -c 'compare "$1" "$1.parity"' _) > "$results"

# --- check_test.sh, every plain `check` compared on the way through -----------

shim="$tmpdir/kasbah"
log="$tmpdir/suite.log"
cat > "$shim" <<SHIM
#!/usr/bin/env bash
set -uo pipefail
if [ "\$#" = 1 ] && [ "\$1" = check ]; then
    # Out of the suite's own yq fork count (F20), which is about the Go run.
    YQ_COUNT_FILE=/dev/null compare "\$PWD" "\$(mktemp -d "$tmpdir/suite.XXXXXX")" >> "$log"
fi
exec "$real_bin" "\$@"
SHIM
chmod 0755 "$shim"
: > "$log"
suite_rc=0
KASBAH_BIN="$shim" bash "$repo_dir/tests/check_test.sh" >"$tmpdir/suite.out" 2>&1 || suite_rc=$?
cat "$log" >> "$results"

# --- Verdict ------------------------------------------------------------------

total="$(wc -l < "$results")"
diffs="$(grep -c '^DIFF' "$results" || true)"
suite_runs="$(wc -l < "$log")"
echo "check parity: $total projects ($suite_runs from check_test.sh), $diffs differing"
fail=0
if [ "$suite_rc" != 0 ]; then
    echo "  FAIL: check_test.sh through the shim exited $suite_rc:" >&2
    tail -20 "$tmpdir/suite.out" >&2
    fail=1
fi
if [ "$suite_runs" -lt 50 ]; then
    echo "  FAIL: the shim saw only $suite_runs plain checks from check_test.sh" >&2
    fail=1
fi
if [ "$diffs" != 0 ]; then
    fail=1
    # Captured first: `grep | head | while` would SIGPIPE under pipefail.
    report="$(grep '^DIFF' "$results" | head -20)" || true
    while IFS= read -r line; do
        echo "  FAIL: $line" >&2
        o="${line##* — }"
        diff "$o/bash.out" "$o/go.out" 2>&1 | sed -n '1,10s/^/        /p' >&2 || true
    done <<<"$report"
fi

if [ "$fail" = 0 ]; then
    echo "PASS: check_parity_test"
else
    echo "FAIL: check_parity_test" >&2
    exit 1
fi
