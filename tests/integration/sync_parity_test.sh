#!/usr/bin/env bash
# Integration: kasbah's own sync (internal/treesync, `kasbah remote sync`)
# against the rsync invocations it replaced, on the rig as the deploy user.
#
# Every case runs twice into two destinations prepared identically: once with
# the old command line (`rsync -rlpt -s src/ dst/`, `rsync -lpt -s src dst`,
# `rsync -pt --chmod=F644 -s src dst`) and once with `kasbah __sync`, which is
# the code deploy, rollback and env use. The two trees must then be identical:
# type, mode, owner, size, mtime to the nanosecond, link target and content
# hash, plus rig_files_snapshot's listing — and both runs must agree on
# success. While kasbah runs, rsync is gone from the rig and is a failing stub
# on this workstation's PATH, so nothing of kasbah's can lean on it.
#
# KASBAH_SYNC_TIMING=1 adds the timing table (a realistic tree, 5,000 small
# files, one 500 MB file — fresh and unchanged), which is measurement, not a
# check.
#
# Exit status follows test.sh's contract: 0 pass, 1 an assertion failed, 2 the
# suite could not run at all.
set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
. "$repo_dir/tests/integration/rig_env.sh"

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

tmpdir="$(mktemp -d)"
hidden=""
cleanup() {
    [ -z "$hidden" ] || rig_ssh "sudo mv -f /usr/bin/rsync.hidden /usr/bin/rsync" >/dev/null 2>&1
    # The deploy user's home is not rig_clean's: nothing is left in it.
    [ -z "${base:-}" ] || [ -n "${KASBAH_SYNC_KEEP:-}" ] ||
        rig_ssh "chmod -R u+rwx $base 2>/dev/null; rm -rf $base" >/dev/null 2>&1
    chmod -R u+rwx "$tmpdir" 2>/dev/null
    if [ -n "${KASBAH_SYNC_KEEP:-}" ]; then echo "kept: $tmpdir" >&2; else rm -rf "$tmpdir"; fi
}
trap cleanup EXIT

real_rsync=$(command -v rsync) || { echo "error: rsync is the reference and is not installed here" >&2; exit 2; }
if [ ! -f "$RIG_SSH_CONFIG" ] || ! rig_reachable; then
    echo "error: the rig did not answer ssh — is it up? tests/rig/rig.sh up" >&2
    exit 2
fi
if ! rig_env_init "$tmpdir/env" || ! rig_clean; then
    echo "error: could not prepare the scratch HOME or clean the rig" >&2
    exit 2
fi
if ! kasbah_cli server init "$RIG_TARGET" --no-mail --no-backup --domain=rig.test --email=ops@rig.test \
        --traefik-auth="dashadmin:rig-dashboard-pw" >"$tmpdir/init.out" 2>&1 </dev/null; then
    echo "error: server init failed on a cleaned rig:" >&2
    cat "$tmpdir/init.out" >&2
    exit 2
fi

# kasbah never runs rsync: a stub that fails loudly sits first on its PATH.
stub="$tmpdir/stub"
mkdir -p "$stub"
printf '#!/bin/sh\necho "rsync $*" >> "%s/rsync-calls"\nexit 99\n' "$tmpdir" > "$stub/rsync"
chmod 0755 "$stub/rsync"

assert '[ "$(env PATH="$RIG_SHIM_DIR:$stub:$PATH" sh -c "command -v rsync")" = "$stub/rsync" ]' \
    "the failing rsync stub is the one kasbah's PATH finds"

# Outside the apps tree: its setgid directories hand their group down, which
# rsync's own chmod of each directory would undo and kasbah's keeps.
base=/home/$RIG_SSH_USER/parity
rig_ssh "rm -rf $base && mkdir -p $base/r $base/k $base/out-r $base/out-k" >/dev/null 2>&1 || exit 2

hide_rsync() {
    rig_ssh "sudo mv /usr/bin/rsync /usr/bin/rsync.hidden" >/dev/null 2>&1 && hidden=1
    assert '[ -n "$hidden" ] && [ -z "$(rig_ssh "command -v rsync" 2>/dev/null)" ]' \
        "rsync is gone from the rig while kasbah runs"
}
show_rsync() { rig_ssh "sudo mv -f /usr/bin/rsync.hidden /usr/bin/rsync" >/dev/null 2>&1 && hidden=""; }

# old MODE SRC DEST — the rsync command line kasbah 1.0.1 ran for MODE.
old() {
    local mode=$1 src=$2 dest=$3 flags
    case $mode in
        dir) flags=(-rlpt -s); src+=/; dest+=/ ;;
        file) flags=(-lpt -s) ;;
        fragment) flags=(-pt --chmod=F644 -s) ;;
    esac
    "$real_rsync" -e "ssh -F $RIG_SSH_CONFIG" "${flags[@]}" "$src" "$RIG_TARGET:$dest"
}
new() {
    PATH="$stub:$PATH" kasbah_cli __sync "$RIG_TARGET" "$@"
}

# both CASE MODE SRC DEST — rsync into r/, kasbah into k/; rcs in $rc_r $rc_k.
both() {
    local c=$1 mode=$2 src=$3 dest=$4
    old "$mode" "$src" "$base/r/$dest" >"$tmpdir/$c.r.out" 2>&1; rc_r=$?
    hide_rsync
    new "$mode" "$src" "$base/k/$dest" >"$tmpdir/$c.k.out" 2>&1; rc_k=$?
    show_rsync
}

# rig_list ROOT — one line per entry: type mode owner size (files) mtime path
# target, NULs for separators so any name survives; then every file's sha256.
rig_list() {
    rig_ssh "bash -s $(printf '%q' "$1")" <<'REMOTE'
cd "$1" || exit 1
find . -printf '%y %m %u:%g %s %T@ %p -> %l\0' | LC_ALL=C sort -z | tr '\n\0' '?\n' |
    sed -E 's/^([dl] [0-7]+ [^ ]+) [0-9]+ /\1 - /'
find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
REMOTE
}

# same [-D] CASE ROOT_R ROOT_K — the two trees are identical, both ways of
# looking. -D drops directory mtimes: a one-file sync manages none, so its
# parent's is the moment the file landed, a different one on each side.
undated() { sed -E 's/^(d [^ ]+ [^ ]+ -) [0-9.]+ /\1 /'; }
# received LIST|SNAP — directories with the group given the owner's bits, as
# treesync's dirMode lays them down; applied to both sides alike.
received() {
    local l m rest
    while IFS= read -r l; do
        case $1:$l in
            list:"d "*) m=${l#d }; rest=${m#* }; m=${m%% *}
                        l="d $(printf '%o' $(( 8#$m | ((8#$m & 8#700) >> 3) ))) $rest" ;;
            snap:*" d") rest=${l% d}; m=${rest##* }; rest=${rest% *}; m=${rest##* }
                        l="${rest% *} $(printf '%o' $(( 8#$m | ((8#$m & 8#700) >> 3) ))) ${l##* $m }" ;;
        esac
        printf '%s\n' "$l"
    done
}
same() {
    local blank=cat
    [ "$1" != -D ] || { blank=undated; shift; }
    local c=$1 r=$2 k=$3 d
    rig_list "$r" | $blank | received list >"$tmpdir/$c.r.list" 2>&1
    rig_list "$k" | $blank | received list >"$tmpdir/$c.k.list" 2>&1
    d=$(diff "$tmpdir/$c.r.list" "$tmpdir/$c.k.list")
    assert '[ -z "$d" ] && [ -s "$tmpdir/$c.r.list" ]' "$c: kasbah's tree is rsync's
$d"
    rig_files_snapshot -r "$r" | sed "s|^$r||" | received snap >"$tmpdir/$c.r.snap"
    rig_files_snapshot -r "$k" | sed "s|^$k||" | received snap >"$tmpdir/$c.k.snap"
    d=$(diff "$tmpdir/$c.r.snap" "$tmpdir/$c.k.snap")
    assert '[ -z "$d" ]' "$c: and rig_files_snapshot agrees
$d"
}
agree() {
    local c=$1
    assert '[ "$((rc_r == 0))" = "$((rc_k == 0))" ]' "$c: rsync exited $rc_r and kasbah $rc_k
        rsync: $(cat "$tmpdir/$c.r.out")
        kasbah: $(cat "$tmpdir/$c.k.out")"
}
# inodes ROOT — every non-directory's inode, to see what a run replaced.
inodes() { rig_ssh "cd $(printf '%q' "$1") && find . ! -type d -printf '%i %p\0' | LC_ALL=C sort -z | tr '\n\0' '?\n'" 2>/dev/null; }

# pin DIR — every directory under DIR to a time in the past. A directory whose
# mtime falls in the second the copy runs keeps the copy's own (rsync compares
# whole seconds; TestDirMtimeSecond holds kasbah to it), which would make the
# two sides differ by when each ran rather than by what each did.
pin() { find "$1" -type d -exec touch -d '2018-03-03 03:03:03.75' {} +; }

# --- The corpus ---------------------------------------------------------------
src="$tmpdir/src"
mk() { mkdir -p "$(dirname "$1")" && printf '%s' "$2" > "$1" && chmod "$3" "$1" && touch -d "$4" "$1"; }
mk "$src/plain" $'plain\n' 644 '2021-01-01 00:00:00.5'
mk "$src/secret" $'s\n' 600 '2019-05-05 05:05:05.25'
mk "$src/exec" $'#!/bin/sh\n' 755 '2020-02-02 02:02:02.123456789'
mk "$src/private" $'p\n' 700 '2021-01-01 00:00:00.5'
mk "$src/suid" $'u\n' 4755 '2021-01-01 00:00:00.5'
mk "$src/sgid" $'g\n' 2755 '2021-01-01 00:00:00.5'
mk "$src/empty" '' 644 '2019-05-05 05:05:05.25'
mk "$src/sticky/f" $'x\n' 644 '2021-01-01'
mk "$src/ro/inner" $'ro\n' 444 '2019-05-05'
mk "$src/a/b/c/d/e/f/g/h/deep.txt" $'deep\n' 644 '2021-01-01'
mk "$src/ünïcødé ✓/fichier é" $'u\n' 644 '2021-01-01'
mk "$src/with space" $'sp\n' 644 '2021-01-01'
mk "$src/new"$'\n'"line" $'nl\n' 644 '2021-01-01'
mk "$src/bad"$'\xff\xfe'"bytes" $'nb\n' 644 '2021-01-01'
mk "$src/-leading-dash" $'dash\n' 644 '2021-01-01'
mk "$src/$(printf 'n%.0s' {1..255})" $'long\n' 644 '2021-01-01'
long="$src"
for c in a b c d e f g h i j k l; do long+="/$(printf "$c%.0s" {1..200})"; done
mk "$long/f" $'very long path\n' 644 '2021-01-01'
mkdir -p "$src/emptydir"
ln -s /etc/passwd "$src/abs"
ln -s plain "$src/rel"
ln -s nowhere/at/all "$src/dangling"
ln -s ../.. "$src/a/up"
touch -h -d '2020-01-02 03:04:05.123456789' "$src/abs" "$src/rel" "$src/dangling" "$src/a/up"
mkfifo "$src/fifo"
chmod 1777 "$src/sticky"
chmod 555 "$src/ro"
pin "$src"
touch -d '2017-07-07 07:07:07.123456789' "$src/a/b" "$src/ünïcødé ✓"

# --- A tree: fresh, unchanged, then changed --------------------------------------
both tree dir "$src" tree
agree tree
assert '[ "$rc_k" = 0 ]' "the corpus syncs (kasbah: $(cat "$tmpdir/tree.k.out"))"
assert 'grep -qF "skipping non-regular file \"fifo\"" "$tmpdir/tree.k.out"' \
    "the fifo is skipped with rsync's message (said: $(cat "$tmpdir/tree.k.out"))"
same tree "$base/r/tree" "$base/k/tree"

inodes "$base/r/tree" >"$tmpdir/ino.r.0"; inodes "$base/k/tree" >"$tmpdir/ino.k.0"
both rerun dir "$src" tree
agree rerun
same rerun "$base/r/tree" "$base/k/tree"
inodes "$base/r/tree" >"$tmpdir/ino.r.1"; inodes "$base/k/tree" >"$tmpdir/ino.k.1"
assert 'cmp -s "$tmpdir/ino.k.0" "$tmpdir/ino.k.1"' "an unchanged rerun replaces nothing, as rsync's does"
assert 'cmp -s "$tmpdir/ino.r.0" "$tmpdir/ino.r.1"' "(the control: rsync's rerun replaced nothing either)"

# The quick check's corners: same size and second with new content (skipped by
# both), a mode-only change, an mtime-only change, a sub-second-only change,
# new and vanished files, and a file and a directory trading places.
chmod u+w "$src/ro"
printf 'PLAIN\n' > "$src/plain"; touch -d '2021-01-01 00:00:00.9' "$src/plain"
chmod 640 "$src/secret"
touch -d '2022-02-02' "$src/exec"
touch -d '2020-02-02 02:02:02.9' "$src/private"
mk "$src/ro/added" $'new\n' 644 '2023-03-03'
rm -f "$src/empty"
rm -rf "$src/emptydir"; mk "$src/emptydir" $'now a file\n' 644 '2023-03-03'
rm -f "$src/with space"; mk "$src/with space/inside" $'now a dir\n' 644 '2023-03-03'
chmod 555 "$src/ro"
pin "$src"
both changed dir "$src" tree
agree changed
same changed "$base/r/tree" "$base/k/tree"

# The quick check against prepared destinations: same content with only the
# sub-second mtime differing, and different content of the same size within
# the same whole second. rsync skips both, keeping the destination's bytes and
# mtime; so must kasbah.
qc="$tmpdir/qc"
mk "$qc/subsec" AAAA 644 @1577836800.1
mk "$qc/samesec" AAAA 644 @1577836800.1
pin "$qc"
for side in r k; do
    rig_ssh "mkdir -p $base/$side/qc && cd $base/$side/qc && echo -n AAAA > subsec && echo -n BBBB > samesec &&
             touch -d @1577836800.9 subsec samesec && touch -d '2018-03-03 03:03:03.75' ." >/dev/null 2>&1
done
both qc dir "$qc" qc
agree qc
same qc "$base/r/qc" "$base/k/qc"
for side in r k; do
    assert '[ "$(rig_ssh "cat $base/$side/qc/samesec; stat -c %.9Y $base/$side/qc/samesec $base/$side/qc/subsec" 2>/dev/null | tr "\n" " ")" = "BBBB1577836800.900000000 1577836800.900000000 " ]' \
        "$side: both files were skipped — the destination's bytes and mtimes stayed"
done

# --- Type changes against prepared destinations ------------------------------------
tc="$tmpdir/tc"
mk "$tc/a/f" 1 644 2020-01-01;      mk "$tc/b" 1 644 2020-01-01
mk "$tc/c" 1 644 2020-01-01;        ln -s t "$tc/d"; ln -s t "$tc/e"; ln -s t "$tc/g"
mk "$tc/h" 1 644 2020-01-01;        mk "$tc/i/f" 1 644 2020-01-01
mk "$tc/j/f" 1 644 2020-01-01;      mk "$tc/k" 1 644 2020-01-01
mkfifo "$tc/l";                     mk "$tc/m/f" 1 644 2020-01-01
mk "$tc/n" AAAA 644 '2020-01-01 00:00:00.1'
mk "$tc/o" same 644 2020-01-01;     mk "$tc/p" new 644 2020-01-01
mk "$tc/q/f" new 644 2021-01-01;    chmod 555 "$tc/q"
touch -h -d 2020-01-01 "$tc/d" "$tc/e" "$tc/g"
pin "$tc"
for side in r k; do
    rig_ssh "bash -s $base/$side/tc $base/out-$side" <<'REMOTE' >/dev/null 2>&1
d=$1 out=$2
mkdir -p "$d" "$out"
echo old > "$d/a"; mkdir "$d/b"; mkdir -p "$d/c" "$d/d"; echo k > "$d/c/keep"; echo k > "$d/d/keep"
mkdir "$d/e"; echo old > "$d/g"; ln -s /etc/passwd "$d/h"; ln -s "$out" "$d/i"
mkfifo "$d/j" "$d/k"; echo old > "$d/l"; mkdir "$d/m"; echo x > "$d/m/extra"; echo top > "$d/top"
echo BBBB > "$d/n"; touch -d '2020-01-01 00:00:00.9' "$d/n"
echo same > "$d/o"; chmod 600 "$d/o"; touch -d 2020-01-01 "$d/o"
echo old > "$d/p"; chmod 000 "$d/p"
mkdir "$d/q"; echo old > "$d/q/f"; chmod 555 "$d/q"
find "$d" -exec touch -h -d '2000-01-01 00:00:00.5' {} +
REMOTE
done
both tc dir "$tc" tc
agree tc
assert '[ "$rc_k" != 0 ]' "a non-empty directory in a file's way fails the run, as it fails rsync's"
for what in "cannot delete non-empty directory: c" "cannot delete non-empty directory: d"; do
    assert 'grep -qF "$what" "$tmpdir/tc.k.out" && grep -qF "$what" "$tmpdir/tc.r.out"' "both say: $what"
done
same tc "$base/r/tc" "$base/k/tc"
assert '[ -z "$(rig_ssh "ls -A $base/out-k" 2>/dev/null)" ]' \
    "a symlink in the destination where a directory goes is replaced, never followed out"
rig_ssh "chmod -R u+w $base/r/tc $base/k/tc" >/dev/null 2>&1

# --- The destination root ------------------------------------------------------------
one="$tmpdir/one"; mk "$one/f" 1 644 2020-01-01; pin "$one"
for side in r k; do
    rig_ssh "mkdir -p $base/$side/rootlink-target && ln -s rootlink-target $base/$side/rootlink && echo x > $base/$side/rootfile && ln -s /nonexistent/x $base/$side/rootdangling" >/dev/null 2>&1
done
both root-new dir "$one" root-new;               agree root-new; same root-new "$base/r/root-new" "$base/k/root-new"
both root-link dir "$one" rootlink;              agree root-link; same root-link "$base/r/rootlink-target" "$base/k/rootlink-target"
both root-file dir "$one" rootfile;              agree root-file
assert '[ "$rc_k" != 0 ]' "a file where the root goes is refused"
both root-dangling dir "$one" rootdangling;      agree root-dangling
assert '[ "$rc_k" != 0 ]' "a dangling symlink where the root goes is refused"
both root-orphan dir "$one" no/parent;           agree root-orphan
assert '[ "$rc_k" != 0 ]' "a root whose parent is missing is not created, as rsync does not create it"

# --- One file: `rsync -lpt src dst` ---------------------------------------------------
fs="$tmpdir/fs"
mk "$fs/compose.prod.yml" $'services: {}\n' 640 '2021-06-06 06:06:06.66'
ln -s ../shared/env "$fs/link"; touch -h -d '2020-01-01 00:00:00.5' "$fs/link"
mkfifo "$fs/fifo"
# Symlinks point beside each case's directory, relatively, so the two sides'
# link texts match.
for side in r k; do
    rig_ssh "bash -s $base/$side/fm" <<'REMOTE' >/dev/null 2>&1
d=$1
mkdir -p "$d/1" "$d/2/dst" "$d/3" "$d/4" "$d/5" "$d/6" "$d/7" "$d/8/dst/compose.prod.yml" "$d/9" "$d/dirlink"
ln -s ../dirlink "$d/3/dst"
echo kept > "$d/filelink"; ln -s ../filelink "$d/4/dst"; ln -s /nope "$d/5/dst"
echo k > "$d/8/dst/compose.prod.yml/keep"; echo old > "$d/9/dst"
find "$d" -exec touch -h -d '2000-01-01 00:00:00.5' {} +
REMOTE
done
for c in "1 compose.prod.yml" "2 compose.prod.yml" "3 compose.prod.yml" "4 compose.prod.yml" \
         "5 compose.prod.yml" "6 link" "7 fifo" "8 compose.prod.yml" "9 link"; do
    set -- $c
    both "fm$1" file "$fs/$2" "fm/$1/dst"; agree "fm$1"
done
assert '[ "$rc_k" = 0 ]' "a symlink over a file (said: $(cat "$tmpdir/fm9.k.out"))"
same -D fm "$base/r/fm" "$base/k/fm"
assert '[ "$(rig_ssh "cat $base/k/fm/filelink" 2>/dev/null)" = "kept" ]' \
    "a destination that is a symlink to a file is replaced, its target untouched"
assert '[ "$(rig_ssh "ls -A $base/k/fm/dirlink" 2>/dev/null)" = "compose.prod.yml" ]' \
    "a destination that is a symlink to a directory takes the file inside, as rsync's does"

# --- The fragment: `rsync -pt --chmod=F644 src dst` --------------------------------------
fr="$tmpdir/fr"
mk "$fr/traefik-dynamic.yml" $'http: {}\n' 600 '2022-02-02 00:00:00.2'
for side in r k; do
    rig_ssh "mkdir -p $base/$side/fr && echo old > $base/$side/fr/b.yml && chmod 600 $base/$side/fr/b.yml" >/dev/null 2>&1
done
both fr-a fragment "$fr/traefik-dynamic.yml" fr/a.yml; agree fr-a
both fr-b fragment "$fr/traefik-dynamic.yml" fr/b.yml; agree fr-b
same -D fr "$base/r/fr" "$base/k/fr"
assert '[ "$(rig_ssh "stat -c %a $base/k/fr/a.yml" 2>/dev/null)" = 644 ]' "the fragment lands 644 whatever the source's mode"
# The one deliberate difference: rsync without -l skips a symlinked fragment
# and exits 0, so the route never shipped; kasbah ships what it points at.
ln -s traefik-dynamic.yml "$fr/linked.yml"
both fr-link fragment "$fr/linked.yml" fr/link.yml
assert '[ "$rc_r" = 0 ] && grep -qF "skipping non-regular file" "$tmpdir/fr-link.r.out" &&
        [ -z "$(rig_ssh "ls $base/r/fr/link.yml" 2>/dev/null)" ]' "(the control: rsync skipped the symlinked fragment)"
assert '[ "$rc_k" = 0 ] && [ "$(rig_ssh "cat $base/k/fr/link.yml" 2>/dev/null)" = "http: {}" ]' \
    "kasbah ships the symlinked fragment's content (said: $(cat "$tmpdir/fr-link.k.out"))"

# --- Scale: 2,000 files in one session, and a rerun that sends none ----------------------
many="$tmpdir/many"
mkdir -p "$many"
for i in $(seq -w 1 2000); do printf '%s\n' "$i" > "$many/f$i"; done
pin "$many"
both many dir "$many" many; agree many
same many "$base/r/many" "$base/k/many"
inodes "$base/k/many" >"$tmpdir/many.0"
both many2 dir "$many" many; agree many2
inodes "$base/k/many" >"$tmpdir/many.1"
assert 'cmp -s "$tmpdir/many.0" "$tmpdir/many.1"' "an unchanged rerun of 2,000 files replaces none"

assert '[ ! -s "$tmpdir/rsync-calls" ]' "kasbah never ran rsync ($(cat "$tmpdir/rsync-calls" 2>/dev/null))"
assert '[ -z "$(rig_ssh "find $base -name '"'"'.kasbah-sync.*'"'"'" 2>/dev/null)" ]' "no staging file outlived a run"

# --- Timing (opt-in) ---------------------------------------------------------------------
timed() { local t0 t1; t0=$(date +%s.%N); "$@" >/dev/null 2>&1; t1=$(date +%s.%N); awk "BEGIN { printf \"%.2f\", $t1 - $t0 }"; }
if [ "${KASBAH_SYNC_TIMING:-}" = 1 ]; then
    real="$tmpdir/real"
    mkdir -p "$real"
    git -C "$repo_dir" archive HEAD | tar -x -C "$real"
    small="$tmpdir/small"
    mkdir -p "$small"
    for i in $(seq -w 1 5000); do printf '%s\n' "$i" > "$small/f$i"; done
    big="$tmpdir/big"
    mkdir -p "$big"
    head -c 500M /dev/urandom > "$big/blob"
    printf '\n%-32s %10s %10s\n' "case (seconds)" rsync kasbah
    noop_k=$(timed new file "$one/f" "$base/k/noop")
    noop_r=$(timed old file "$one/f" "$base/r/noop")
    printf '%-32s %10s %10s\n' "1-byte file (fixed cost)" "$noop_r" "$noop_k"
    for c in "real:$(find "$real" | wc -l) entries" "small:5,000 files" "big:one 500 MB file"; do
        d=${c%%:*}
        for pass in fresh unchanged; do
            tr=$(timed old dir "$tmpdir/$d" "$base/r/t-$d")
            tk=$(timed new dir "$tmpdir/$d" "$base/k/t-$d")
            printf '%-32s %10s %10s\n' "${c#*:}, $pass" "$tr" "$tk"
        done
    done
    same timing-big "$base/r/t-big" "$base/k/t-big"
    rig_ssh "rm -rf $base/r/t-big $base/k/t-big" >/dev/null 2>&1
fi

rig_ssh "chmod -R u+w $base; rm -rf $base" >/dev/null 2>&1
exit $fail
