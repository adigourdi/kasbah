#!/usr/bin/env bash
# Test: --env-seed=FILE on env, deploy and rollback is refused on the
# workstation before anything connects — missing, not a regular file, open to
# others, a KASBAH_* key, a line that is not KEY=value — and never prints a
# seed line. Then the server half, run here as `kasbah remote setup-env`: a
# seed on a headless setup's stdin renders .env, staging nothing; a staged one
# is read only by the setup naming its token and is gone afterwards.
set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
. "$repo_dir/tests/cli.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

# An ssh that only records: nothing here may reach it.
mkdir -p "$tmpdir/bin"
ssh_log="$tmpdir/ssh.log"
: >"$ssh_log"
printf '#!/bin/sh\necho "$*" >>"%s"\nexit 255\n' "$ssh_log" >"$tmpdir/bin/ssh"
chmod +x "$tmpdir/bin/ssh"
export PATH="$tmpdir/bin:$PATH"

project="$tmpdir/demo"
mkdir -p "$project"
printf 'schema: 1\nkasbah_version: 0.1.0\nname: demo\ndomain: demo.test\nsync:\n  - .env.prod.example\n' >"$project/kasbah.yml"
printf 'A=1\nB_SECRET=\n' >"$project/.env.prod.example"
git -C "$project" init -q
git -C "$project" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m x

seed() { # seed NAME MODE BODY — a seed file outside the project
    printf '%s' "$3" >"$tmpdir/$1"
    chmod "$2" "$tmpdir/$1"
    printf '%s' "$tmpdir/$1"
}
good="$(seed good 600 'A=2
B_SECRET=s3cret
')"
cases=(
    "missing|$tmpdir/nope|no such file"
    "a directory|$tmpdir/bin|not a regular file"
    "group readable|$(seed group 640 'A=s3cret
')|open to others (mode 0640)"
    "world readable|$(seed world 604 'A=s3cret
')|chmod 600"
    "reserved|$(seed reserved 600 'A=1
KASBAH_MEM_LIMIT=1g
')|line 2 sets KASBAH_MEM_LIMIT"
    "malformed|$(seed malformed 600 '# comment

this is not a pair s3cret
')|line 3 is not KEY=value"
    "CRLF reserved|$(seed crlf 600 $'A=1\r\nKASBAH_X=1\r\n')|line 2 sets KASBAH_X"
)
for cmd in "env" "deploy" "rollback 1.0.0"; do
    for c in "${cases[@]}"; do
        IFS='|' read -r name path want <<<"$c"
        # shellcheck disable=SC2086
        out="$(cd "$project" && "$KASBAH_BIN" $cmd deploy@vps "--env-seed=$path" 2>&1)"; rc=$?
        assert '[ "$rc" = "1" ]' "$cmd: a $name seed exits 1 (rc $rc: $out)"
        assert 'grep -qF -- "$want" <<<"$out"' "$cmd: saying '$want' (said '$out')"
        assert '! grep -qF s3cret <<<"$out"' "$cmd: never printing a seed line (said '$out')"
    done
    # shellcheck disable=SC2086
    out="$(cd "$project" && "$KASBAH_BIN" $cmd deploy@vps --env-seed 2>&1)"; rc=$?
    assert '[ "$rc" = "1" ] && grep -qF -- "--env-seed=FILE" <<<"$out"' "$cmd: a bare --env-seed is refused (rc $rc: $out)"
    # shellcheck disable=SC2086
    out="$("$KASBAH_BIN" $cmd --help 2>&1)"
    assert 'grep -qF -- "--env-seed=FILE" <<<"$out"' "$cmd --help lists --env-seed (said '$out')"
done
assert '[ ! -s "$ssh_log" ]' "no refusal opened a connection (ssh saw: $(cat "$ssh_log"))"

# --- The server half ---------------------------------------------------------------
d="$tmpdir/srv/demo"
mkdir -p "$d"
cp "$project/.env.prod.example" "$d/"
tok=0123456789abcdef
payload() { # payload BODY — SetHeader then the body
    local sum
    sum="$(printf '%s' "$1" | sha256sum)"
    printf '%s %s\n%s' "${#1}" "${sum%% *}" "$1"
}
stage() { payload "$1" | "$KASBAH_BIN" remote setup-env seed "$d" "$tok"; }
seeds() { find "$d" -maxdepth 1 -name '.kasbah-env-seed*' | wc -l; }
body="$(<"$good")"$'\n'

# Headless: the seed rides on the setup's own stdin, nothing staged.
out="$(payload "$body" | "$KASBAH_BIN" remote setup-env setup "$d" --color=no --headless --seed 2>&1)"; rc=$?
assert '[ "$rc" = "0" ]' "a headless setup renders .env from the seed on its stdin (rc $rc: $out)"
assert '[ "$(cat "$d/.env")" = "$(printf "A=2\nB_SECRET=s3cret")" ]' ".env holds the seeded values as written ($(cat "$d/.env"))"
assert '! grep -qF s3cret <<<"$out"' "and prints none of them (said '$out')"
assert '[ "$(seeds)" = 0 ]' "and stages nothing"

rm -f "$d/.env"
out="$(payload $'A=2\n' | "$KASBAH_BIN" remote setup-env setup "$d" --headless --seed 2>&1)"; rc=$?
assert '[ "$rc" = "5" ] && grep -qF "does not answer: B_SECRET" <<<"$out"' "a partial seed headless exits 5 naming the key (rc $rc: $out)"
assert '[ ! -e "$d/.env" ]' "writing nothing"

out="$(printf 'DB_PASSWORD=my secret\nA=1\n' | "$KASBAH_BIN" remote setup-env setup "$d" --headless --seed 2>&1)"; rc=$?
assert '[ "$rc" = "1" ] && ! grep -qF "my" <<<"$out" && [ ! -e "$d/.env" ]' "a seed with no header is refused without quoting it (rc $rc: $out)"

# Interactive: staged under the run's token, read by the setup naming it.
out="$(stage "$body")"; rc=$?
assert '[ "$rc" = "0" ] && [ "$out" = "staged=yes" ]' "a seed stages (rc $rc: $out)"
assert '[ "$(stat -c %a "$d/.kasbah-env-seed.$tok")" = "600" ]' "at mode 600 ($(stat -c %a "$d/.kasbah-env-seed.$tok" 2>&1))"
out="$("$KASBAH_BIN" remote setup-env setup "$d" --seed=fedcba9876543210 </dev/null 2>&1)"; rc=$?
assert '[ "$rc" = "1" ] && grep -qF "no staged seed" <<<"$out" && [ -e "$d/.kasbah-env-seed.$tok" ]' "another run's token reads nothing of it (rc $rc: $out)"
out="$("$KASBAH_BIN" remote setup-env setup "$d" --color=no --seed=$tok </dev/null 2>&1)"; rc=$?
assert '[ "$rc" = "0" ] && [ "$(seeds)" = 0 ]' "the setup naming the token renders .env and removes the seed (rc $rc: $out)"

stage "$body" >/dev/null
tok=fedcba9876543210 stage "$body" >/dev/null
out="$("$KASBAH_BIN" remote setup-env drift "$d" 2>&1)"; rc=$?
assert '[ "$rc" = "0" ] && [ "$(seeds)" = 0 ]' "the drift step removes every seed left behind (rc $rc: $out)"

out="$(printf '9 abc\nA=1\n' | "$KASBAH_BIN" remote setup-env seed "$d" "$tok" 2>&1)"; rc=$?
assert '[ "$rc" = "1" ] && [ "$(seeds)" = 0 ]' "a payload that does not match its header stages nothing (rc $rc: $out)"

exit "$fail"
