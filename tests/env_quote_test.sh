#!/usr/bin/env bash
# Test: every value `kasbah env set` and the interactive env setup write into
# a .env reads back through `docker compose config` as exactly the value given —
# blanks at either end, ` #`, leading quotes of both kinds, `\`, `$`, `=`. The
# server half runs here, as `kasbah remote setup-env`, against scratch dirs.
set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
. "$repo_dir/tests/cli.sh"

if ! docker compose version >/dev/null 2>&1; then
    echo "docker compose is needed: the values are read back by compose itself" >&2
    exit 2
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
fail=0
n=0

# scratch — a project dir with a one-key template and a compose file reading it.
scratch() {
    n=$((n + 1))
    d="$tmpdir/p$n"
    mkdir -p "$d"
    printf 'KQ=\n' >"$d/.env.prod.example"
    printf 'services:\n  x:\n    image: alpine\n    environment:\n      KQ: ${KQ}\n' >"$d/compose.yml"
}

# readback — KQ as compose reads it; config prints every `$` doubled.
readback() {
    local out
    out=$(cd "$d" && env -u KQ docker compose -p envquote config --format json 2>"$d/config.err") || {
        echo "<compose could not read it: $(tr '\n' ' ' <"$d/config.err")>"
        return
    }
    out=$(jq -r '.services.x.environment.KQ' <<<"$out")
    printf '%s' "${out//\$\$/\$}"
}

check() {
    local how="$1" v="$2" got
    got=$(readback)
    if [ "$got" != "$v" ]; then
        echo "  FAIL: $how: wrote $(grep '^KQ=' "$d/.env"), compose read [$got], want [$v]" >&2
        fail=1
    fi
}

set_values=(
    '  sp  ' 'pa$$ss #frag' "'q" '"dq' 'back\slash' 'a=b=c' 'a$b' "it's \"x\" \$y \\z " ' end\' 'end\'
    '\n literal' '#hash' 'x ${HOME}' $'tab\t#x' "'both\" '"
)
for v in "${set_values[@]}"; do
    scratch
    printf 'KQ=old\n' >"$d/.env"
    size=$(printf '%s' "$v" | wc -c)
    sum=$(printf '%s' "$v" | sha256sum | cut -d' ' -f1)
    if ! { printf '%s %s\n' "$size" "$sum"; printf '%s' "$v"; } |
            "$KASBAH_BIN" remote setup-env set "$d" KQ >/dev/null 2>"$d/set.err"; then
        echo "  FAIL: env set [$v] exited non-zero: $(cat "$d/set.err")" >&2
        fail=1
        continue
    fi
    check "env set" "$v"
done

# The setup trims blanks off a typed answer, as bash's read did.
setup_values=('pa$$ss #frag' "'q" '"dq' 'back\slash' "it's \"x\" \$y \\z" 'end\' '#hash' 'x ${HOME}')
for v in "${setup_values[@]}"; do
    scratch
    if ! printf '%s\n' "$v" | "$KASBAH_BIN" remote setup-env setup "$d" --color=no >/dev/null 2>"$d/setup.err"; then
        echo "  FAIL: the setup with [$v] exited non-zero: $(cat "$d/setup.err")" >&2
        fail=1
        continue
    fi
    check "setup" "$v"
done

exit "$fail"
