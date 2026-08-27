#!/usr/bin/env bash
# Test: lib/backup.sh and templates/backup/ — everything about `--with-backup`
# and `server backup-prune` that does not need a server. Flag parsing, every
# prompt's no-TTY refusal, the marker merge, the env-file merge, the rendering,
# the credential probe's verdict, and the runner's own repository plan, which is
# driven for real against a fake tree.
#
# The rig-driven half — a snapshot really taken, a delete really refused, the
# restore drill — lives in tests/integration/backup_test.sh.

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
kasbah="$repo_dir/bin/kasbah"
runner="$repo_dir/templates/backup/backup.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

export KASBAH_LIB_DIR="$repo_dir/lib"
export KASBAH_TEMPLATE_DIR="$repo_dir/templates"
export KASBAH_VERSION="9.9.9-test"
export NO_COLOR=1

# --- Driver -------------------------------------------------------------------
# The library's own functions, called the way cmd_server_init calls them. Two
# things are stubbed and nothing else: ssh_script, because every case here is
# about a local decision, and rsync, because what ships is asserted from the
# call rather than from a file appearing.
driver="$tmpdir/driver.sh"
cat > "$driver" <<'DRV'
#!/usr/bin/env bash
set -euo pipefail
. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/server_init.sh"

mode="$1"; shift
case "$mode" in
    parse)
        _server_init_parse_args "$@"
        printf 'backup=%s\nrepo_base=%s\nat=%s\njitter=%s\n' \
            "${_SI_BACKUP:-unset}" "${_BK_REPO_BASE:-unset}" \
            "${_BK_AT:-unset}" "${_BK_JITTER:-unset}"
        printf 'daily=%s\nweekly=%s\nmonthly=%s\ntimeout=%s\n' \
            "${_BK_KEEP_DAILY:-unset}" "${_BK_KEEP_WEEKLY:-unset}" "${_BK_KEEP_MONTHLY:-unset}" \
            "${_BK_TIMEOUT:-unset}"
        printf 'env=%s\nnoenv=%s\npass=%s\nbase_origin=%s\n' \
            "${_BK_ENV_GIVEN[*]-}" "${_BK_ENV_NONE:-unset}" "${_BK_PASS_GIVEN[*]-}" \
            "${_BK_REPO_BASE_ORIGIN:-unset}"
        ;;
    check)
        case "$1" in
            repo-base) _bk_check_repo_base --backup-repo-base= "$2" ;;
            at)        _bk_check_at "$2" ;;
            jitter)    _bk_check_jitter "$2" ;;
            keep)      _bk_check_keep --backup-keep-daily= "$2" ;;
            timeout)   _bk_check_timeout "$2" ;;
            repo-name) _bk_check_repo_name --backup-password= "$2" ;;
            env-entry) _bk_check_env_entry --backup-env= "$2" ;;
            password)  _bk_check_password alpha "$2" ;;
        esac
        printf 'ok\n'
        ;;
    redact)
        _bk_redact_url "$1" v
        printf '%s\n' "$v"
        ;;
    jitter)
        _bk_jitter_for "$1" j
        printf '%s\n' "$j"
        ;;
    markerbackup)
        _BK_ENABLED="$1"
        _BK_REPO_BASE="$2"; _BK_AT="$3"; _BK_JITTER="$4"
        _BK_KEEP_DAILY="$5"; _BK_KEEP_WEEKLY="$6"; _BK_KEEP_MONTHLY="$7"
        _BK_TIMEOUT="${8:-900}"
        _bk_marker_json
        ;;
    frommarker)
        _BK_ENABLED=yes
        _BK_REPO_BASE="${FLAG_REPO_BASE:-}"
        _bk_from_marker "$1"
        printf 'repo_base=%s\norigin=%s\nat=%s\njitter=%s\n' \
            "$_BK_REPO_BASE" "${_BK_REPO_BASE_ORIGIN:-none}" "$_BK_AT" "$_BK_JITTER"
        printf 'daily=%s\nweekly=%s\nmonthly=%s\ntimeout=%s\n' \
            "$_BK_KEEP_DAILY" "$_BK_KEEP_WEEKLY" "$_BK_KEEP_MONTHLY" "$_BK_TIMEOUT"
        ;;
    guardenv)
        _BK_FACT=([env_current]="$(cat "$1"; printf x)")
        _BK_FACT[env_current]="${_BK_FACT[env_current]%x}"
        _bk_guard_env_file /apps "${_BK_FACT[env_current]}"
        printf 'guard=ok\n'
        ;;
    mergeenv)
        _BK_REPO_BASE="$1"; shift
        default="$(cat "$1"; printf x)"; default="${default%x}"; shift
        current=""
        if [ -n "$1" ]; then current="$(cat "$1"; printf x)"; current="${current%x}"; fi
        shift
        _BK_ENV_GIVEN=("$@")
        _bk_merge_env "$default" "$current" out
        printf '%s' "$out"
        ;;
    reposet)
        _BK_FACT=([backup_projects]="$1" [backup_mail]="$2")
        _bk_repo_set
        printf 'repos=%s\nfallbacks=%s\n' "${_BK_REPOS[*]-}" "${_BK_PROJECT_FALLBACKS[*]-}"
        ;;
    values)
        # Everything _bk_read would have brought back, from the environment, so
        # that which repositories are asked about is driven rather than stubbed
        # at the prompt.
        _server_init_parse_args deploy@vps "$@"
        _BK_ENABLED=yes
        _BK_FACT=(
            [backup_dir]="${BK_DIR:-absent}"
            [backup_projects]="${BK_PROJECTS:-}"
            [backup_mail]="${BK_MAIL:-no}"
            [backup_haspass]="${BK_HASPASS:-}"
            [env_current]="${BK_ENVCUR:-}"
        )
        _bk_values deploy@vps
        printf 'repo_base=%s\norigin=%s\nat=%s\njitter=%s\n' \
            "$_BK_REPO_BASE" "$_BK_REPO_BASE_ORIGIN" "$_BK_AT" "$_BK_JITTER"
        printf 'retention=%s/%s/%s\ntimeout=%s\n' "$_BK_KEEP_DAILY" "$_BK_KEEP_WEEKLY" "$_BK_KEEP_MONTHLY" "$_BK_TIMEOUT"
        printf 'repos=%s\nnew=%s\nenv_origin=%s\n' \
            "${_BK_REPOS[*]-}" "${_BK_REPOS_NEW[*]-}" "$_BK_ENV_ORIGIN"
        ;;
    render)
        _BK_ENABLED=yes
        _BK_REPO_BASE="$3"; _BK_AT="${4:-02:00}"; _BK_JITTER="${5:-7}"
        _BK_KEEP_DAILY=7; _BK_KEEP_WEEKLY=4; _BK_KEEP_MONTHLY=3; _BK_TIMEOUT="${6:-900}"
        _BK_FACT=([env_current]="${BK_ENVCUR:-}")
        _BK_REPOS_NEW=(${BK_NEWPASS:-})
        for r in ${BK_NEWPASS:-}; do _BK_PASS[$r]="pw-for-$r"; done
        _SI_TMPDIR="$(mktemp -d "$tmp_root/render.XXXXXX")"
        _bk_render "$_SI_TMPDIR" "$1" "$2"
        [ -z "${RENDER_OUT:-}" ] || cp -R "$_SI_TMPDIR"/backup/. "$RENDER_OUT"/
        (cd "$_SI_TMPDIR/backup" && find . -type f -o -type d | sort | while read -r f; do
            printf '%s %s\n' "$(stat -c '%a' "$f")" "$f"
        done)
        rm -rf "$_SI_TMPDIR"
        ;;
    probe)
        # The verdict, driven from what the remote step reported. What is under
        # test is the reading of those numbers, which is the whole security
        # property: fewer snapshots after the delete attempt than before means
        # the credential can delete.
        _BK_ENABLED=yes
        _BK_REPO_BASE="${BK_BASE:-rest:http://x/}"
        _BK_TIMEOUT=900
        # What the server read found: a stack already there, or none.
        _BK_CURRENT=([compose.yml]="${BK_HASSTACK:+name: kasbah-backup}")
        canned="$1"
        ssh_script() { printf '%s' "$canned"; }
        _bk_probe deploy@vps /apps
        printf 'probe=%s\n' "${_BK_FACT[probe]}"
        ;;
    ship)
        # Which transport each secret takes. rsync and ssh_script both record
        # their whole call, so "the password never reaches a remote argv" is an
        # assertion about what was seen rather than about what was intended.
        _BK_ENABLED=yes
        _BK_TMPDIR="$tmp_root/ship"
        mkdir -p "$_BK_TMPDIR/repos"
        printf 'ENVFILE\n' > "$_BK_TMPDIR/env"
        printf 'topsecret\n' > "$_BK_TMPDIR/repos/alpha.pass"
        _BK_ENV_CONTENT='ENVFILE'
        _BK_FACT=([env_current]="")
        _BK_REPOS_NEW=(alpha)
        SSH_TARGET=deploy@vps
        ssh_script() { printf 'ssh_script|%s\n' "$*" >&2; printf 'backup_layout=done\n'; }
        ssh_rsync() { printf 'rsync|%s\n' "$*" >&2; }
        _bk_layout deploy@vps /apps
        _bk_ship_secrets deploy@vps /apps
        printf 'shipped=ok\n'
        ;;
    sync)
        _BK_ENABLED=yes
        _BK_TMPDIR="$tmp_root/sync"
        mkdir -p "$_BK_TMPDIR"
        printf 'COMPOSE\n' > "$_BK_TMPDIR/compose.yml"
        printf 'RUNNER\n' > "$_BK_TMPDIR/backup.sh"
        _BK_CURRENT=([compose.yml]="${SAME_COMPOSE:-}" [backup.sh]="${SAME_RUNNER:-}")
        SSH_TARGET=deploy@vps
        ssh_rsync() { printf 'rsync->%s\n' "${*: -1}" >&2; }
        _bk_sync deploy@vps /apps
        printf 'changed=%s\nrestart=%s\n' "${_BK_CHANGED[*]-}" "${_BK_FACT[restart]}"
        ;;
    bpstage)
        # The per-repository env file backup-prune hands to `docker --env-file`.
        # Same last-wins invariant as the probe's, and the same reason.
        _BP_TARGET=deploy@vps
        _BP_REPO_BASE="$1"; shift
        _BP_ENV_GIVEN=("$@")
        _BP_REPOS=(alpha "$KASBAH_BACKUP_PROBE_REPO")
        _BK_FACT=([pass_alpha]="$(printf 'alpha-pw' | openssl base64 -A)")
        _bp_stage
        for f in "$_BP_TMPDIR"/env/*.env "$_BP_TMPDIR"/pw/*.pass; do
            printf '== %s %s\n' "$(stat -c '%a' "$f")" "${f#"$_BP_TMPDIR"/}"
            cat "$f"
        done
        rm -rf "$_BP_TMPDIR"
        ;;
    bpprune)
        # The plan and the act, end to end. Two things are stubbed and nothing
        # else: the server — the marker and the repository discovery, neither of
        # which this case is about — and restic itself, whose every call is
        # recorded so "which repositories reached the destructive call" is an
        # assertion about what was run rather than about what was printed.
        ssh_connect() { :; }
        ssh_disconnect() { :; }
        marker_read() {
            MARKER_JSON='{"backup":{"enabled":true,"repo_base":"rest:http://b/","retention":{"daily":1,"weekly":1,"monthly":1}}}'
            MARKER_APPS_PATH=/apps
            MARKER_PATH=/apps/.kasbah/server.json
        }
        _bp_discover() { _BK_FACT=([repos]="${BP_REPOS:-alpha beta}"); }
        _bp_stage() { _BP_TMPDIR="$tmp_root/bpprune"; mkdir -p "$_BP_TMPDIR"; }
        _bp_cleanup() { :; }
        _bp_restic() {
            local _r_repo="$1"; shift
            printf '%s %s\n' "$_r_repo" "$*" >> "$BP_CALLS"
            case " $* " in
                *" --dry-run "*)
                    case " ${BP_FAIL_DRY:-} " in
                        *" $_r_repo "*) printf 'Fatal: unable to open repository\n'; return 3 ;;
                    esac ;;
                *" --prune "*)
                    case " ${BP_FAIL_ACT:-} " in
                        *" $_r_repo "*) printf 'Fatal: unable to open repository\n'; return 3 ;;
                    esac ;;
            esac
            printf 'keep 1 snapshot, remove 1 snapshot\n'
            return 0
        }
        cmd_server_backup_prune "$@"
        ;;
    bpparse)
        _bp_parse_args "$@"
        printf 'target=%s\nrepo_base=%s\nenv=%s\nnoenv=%s\nonly=%s\n' \
            "$_BP_TARGET" "${_BP_REPO_BASE:-unset}" "${_BP_ENV_GIVEN[*]-}" \
            "${_BP_ENV_NONE:-unset}" "${_BP_ONLY[*]-}"
        printf 'daily=%s\nweekly=%s\nmonthly=%s\ndry=%s\nyes=%s\n' \
            "${_BP_KEEP_DAILY:-unset}" "${_BP_KEEP_WEEKLY:-unset}" \
            "${_BP_KEEP_MONTHLY:-unset}" "${_BP_DRY_RUN:-unset}" "${_BP_YES:-unset}"
        printf 'network=%s\n' "${_BP_NETWORK:-unset}"
        ;;
esac
DRV

# stdin is closed exactly as it is in tests/server_init_test.sh: several modes
# reach a prompt, and the tri-state rule sends those to a terminal when there is
# one — so without this the suite passes in CI and hangs in the repo owner's own
# shell, with the question swallowed into $tmpdir/err.
drive() { tmp_root="$tmpdir" bash "$driver" "$@" 2>"$tmpdir/err" </dev/null; }
drive_err() { cat "$tmpdir/err"; }

# --- Flag parsing --------------------------------------------------------------
out=$(drive parse deploy@vps); rc=$?
assert '[ "$rc" = "0" ]' "a bare target parses (exit $rc: $(drive_err))"
for k in repo_base at jitter daily weekly monthly; do
    assert 'grep -qxF "$k=unset" <<<"$out"' "$k is unset without its flag (got '$out')"
done
assert 'grep -qxF "env=" <<<"$out"'       "no --backup-env leaves the list empty"
assert 'grep -qxF "noenv=unset" <<<"$out"' "and --no-backup-env unset — the prompt decides"
assert 'grep -qxF "pass=" <<<"$out"'      "and no --backup-password"

out=$(drive parse deploy@vps --with-backup --backup-repo-base=s3:https://h/b/ \
      --backup-at=03:30 --backup-jitter=900 \
      --backup-keep-daily=14 --backup-keep-weekly=8 --backup-keep-monthly=6 \
      --backup-env=AWS_ACCESS_KEY_ID=k --backup-env=AWS_SECRET_ACCESS_KEY=s \
      --backup-password=alpha=pw1 --backup-password=beta=pw2); rc=$?
assert '[ "$rc" = "0" ]' "every backup flag parses (exit $rc: $(drive_err))"
assert 'grep -qxF "repo_base=s3:https://h/b/" <<<"$out"' "--backup-repo-base is kept verbatim (got '$out')"
assert 'grep -qxF "base_origin=flag" <<<"$out"' "and the run says the flag is where it came from"
assert 'grep -qxF "at=03:30" <<<"$out"'   "--backup-at is recorded"
assert 'grep -qxF "jitter=900" <<<"$out"' "--backup-jitter is recorded"
assert 'grep -qxF "daily=14" <<<"$out"'   "--backup-keep-daily is recorded"
assert 'grep -qxF "weekly=8" <<<"$out"'   "--backup-keep-weekly is recorded"
assert 'grep -qxF "monthly=6" <<<"$out"'  "--backup-keep-monthly is recorded"
out2=$(drive parse deploy@vps --backup-timeout=120)
assert 'grep -qxF "timeout=120" <<<"$out2"' "--backup-timeout is recorded (got '$out2')"
out2=$(drive parse deploy@vps)
assert 'grep -qxF "timeout=unset" <<<"$out2"' "and is unset without the flag — the default is settled later"
assert 'grep -qxF "env=AWS_ACCESS_KEY_ID=k AWS_SECRET_ACCESS_KEY=s" <<<"$out"' \
    "--backup-env is repeatable and keeps its order (got '$out')"
assert 'grep -qxF "pass=alpha=pw1 beta=pw2" <<<"$out"' "--backup-password is repeatable"

out=$(drive parse deploy@vps --no-backup-env)
assert 'grep -qxF "noenv=yes" <<<"$out"' "--no-backup-env is an explicit none"

reject() {
    local what="$1" needle="$2"; shift 2
    local o rc
    o=$(drive parse deploy@vps "$@"); rc=$?
    assert '[ "$rc" != "0" ]' "$what is refused (exit $rc: $o)"
    assert 'grep -qF -- "$needle" "$tmpdir/err"' "$what says why (said '$(drive_err)')"
}
reject "a repo base with no trailing slash" "must end in '/'" --backup-repo-base=s3:https://h/b
reject "a repo base with a space"           "whitespace"      "--backup-repo-base=s3:https://h /b/"
reject "a nonsense --backup-at"             "time of day"     --backup-at=25:00
reject "a --backup-at with no colon"        "time of day"     --backup-at=0200
reject "a jitter of a whole day"            "day or more"     --backup-jitter=86400
reject "a non-numeric jitter"               "whole number"    --backup-jitter=10m
reject "a non-numeric retention"            "whole number"    --backup-keep-daily=lots
reject "a non-numeric timeout"              "whole number"    --backup-timeout=fast
reject "a timeout of zero"                  "under 30 seconds" --backup-timeout=0
reject "a timeout of five seconds"          "under 30 seconds" --backup-timeout=5
reject "--backup-env with no ="             "must be KEY=VALUE" --backup-env=AWSKEY
reject "--backup-env with a bad key"        "variable name"   --backup-env=9AWS=x
reject "--backup-env aimed at kasbah's own key" "kasbah owns" --backup-env=KASBAH_BACKUP_REPO_BASE=x
reject "--backup-password with no repo"     "<repo>=<password>" --backup-password=hunter2
reject "--backup-password for a bad repo name" "not a repository name" --backup-password=Alpha=x
reject "--backup-password for a directory kasbah owns" "kasbah owns" --backup-password=traefik=x
reject "--backup-password with an empty password" "must not be empty" --backup-password=alpha=
reject "an unknown backup flag"             "unknown flag"    --backup-everything

# A secret never appears in an error message: --traefik-auth's rule, and this
# value is the one that decrypts a client's whole history.
out=$(drive parse deploy@vps --backup-password=Alpha=s3cr3t-do-not-print); rc=$?
assert '[ "$rc" != "0" ]' "a bad --backup-password fails (exit $rc)"
assert '! grep -qF "s3cr3t-do-not-print" "$tmpdir/err"' \
    "and never quotes the password back (said '$(drive_err)')"
out=$(drive parse deploy@vps --backup-env=9BAD=s3cr3t-do-not-print); rc=$?
assert '[ "$rc" != "0" ]' "a bad --backup-env fails (exit $rc)"
assert '! grep -qF "s3cr3t-do-not-print" "$tmpdir/err"' \
    "and --backup-env's value is not quoted back either (said '$(drive_err)')"

# --- The help text ----------------------------------------------------------------
# `_server_init_usage` is an *unquoted* heredoc, so a backtick in it is a command
# substitution: `--backup-keep-daily=N  retention, applied by <nothing>` is what
# an operator saw, because the shell had run the words instead of printing them.
# The two exports at the top of this file are for the driver, which sources the
# libraries directly. bin/kasbah must not see them: it takes VERSION from beside
# KASBAH_LIB_DIR, and a checkout has no lib/VERSION.
usage_out=$(env -u KASBAH_LIB_DIR -u KASBAH_VERSION "$kasbah" server init --help 2>&1); rc=$?
assert '[ "$rc" = "0" ]' "server init --help exits 0 (exit $rc)"
for flag in --backup-repo-base= --backup-env= --no-backup-env --backup-password= \
            --backup-at= --backup-jitter= --backup-keep-daily= --backup-timeout=; do
    assert 'grep -qF -- "$flag" <<<"$usage_out"' "--help lists $flag (got '$usage_out')"
done
assert '! grep -qF "applied by$" <<<"$usage_out"' \
    "and no line ends where a backtick swallowed its words (got '$usage_out')"
assert 'grep -qF "retention, applied by" <<<"$usage_out" &&
        [ -n "$(sed -n "s/.*retention, applied by //p" <<<"$usage_out")" ]' \
    "the retention line still names what applies it (got '$(grep "retention, applied" <<<"$usage_out")')"
assert '[ -n "$(sed -n "s/.*one repository per //p" <<<"$usage_out")" ]' \
    "and the summary still names what a repository is per
        (got '$(grep "one repository per" <<<"$usage_out")')"

# --- The keys kasbah owns in the restic environment -------------------------------
# The bypass this section exists for: `docker --env-file` is last-wins, so a
# --backup-env=RESTIC_REPOSITORY= would have pointed the credential probe at one
# repository while the scheduled backup wrote to another — and init would then
# have reported "append-only" about a URL nothing had contacted.
for owned in RESTIC_REPOSITORY RESTIC_REPOSITORY_FILE RESTIC_PASSWORD RESTIC_PASSWORD_FILE RESTIC_PASSWORD_COMMAND; do
    out=$(drive parse deploy@vps --backup-env="$owned=anything"); rc=$?
    assert '[ "$rc" != "0" ]' "--backup-env=$owned= is refused (exit $rc: $out)"
    assert 'grep -qF "kasbah owns" "$tmpdir/err"' "and says kasbah owns it (said '$(drive_err)')"
    out=$(drive bpparse deploy@vps --env="$owned=anything"); rc=$?
    assert '[ "$rc" != "0" ]' "and --env=$owned= is refused by backup-prune too (exit $rc)"
done
# The ones that are not kasbah's stay the operator's — the check must not have
# become "no RESTIC_ key at all".
for theirs in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY RESTIC_REST_USERNAME RESTIC_CACHE_DIR B2_ACCOUNT_ID; do
    out=$(drive parse deploy@vps --backup-env="$theirs=v"); rc=$?
    assert '[ "$rc" = "0" ]' "--backup-env=$theirs= is the operator's (exit $rc: $(drive_err))"
done

# An env file already carrying one — written by hand, or by a kasbah too old to
# refuse the flag. Refused rather than copied through, and rather than stripped
# in silence out of a file the operator was told they own.
for owned in RESTIC_REPOSITORY RESTIC_PASSWORD RESTIC_PASSWORD_COMMAND; do
    printf '# theirs\nKASBAH_BACKUP_REPO_BASE=rest:http://x/\nAWS_ACCESS_KEY_ID=k\n%s=sneaky\n' "$owned" \
        > "$tmpdir/env.hostile"
    drive guardenv "$tmpdir/env.hostile" >/dev/null; rc=$?
    assert '[ "$rc" != "0" ]' "an env file setting $owned is refused (exit $rc)"
    assert 'grep -qF "$owned" "$tmpdir/err"' "naming the key (said '$(drive_err)')"
    assert 'grep -qF "Remove the line" "$tmpdir/err"' "and what to do about it"
done
printf '# theirs\nKASBAH_BACKUP_REPO_BASE=rest:http://x/\nAWS_ACCESS_KEY_ID=k\n' > "$tmpdir/env.ok"
assert '[ "$(drive guardenv "$tmpdir/env.ok")" = "guard=ok" ]' \
    "an env file with only the operator's own keys passes"

# --- Redaction -------------------------------------------------------------------
# restic prints `user:***@` in its own output; kasbah printing the password
# beside it in the same paragraph made kasbah less careful than the tool it
# wraps. Display only — nothing stored, shipped or handed to restic is touched.
assert '[ "$(drive redact "rest:http://u:p@10.0.0.1:8000/b/")" = "rest:http://u:***@10.0.0.1:8000/b/" ]' \
    "userinfo is redacted (got '$(drive redact "rest:http://u:p@10.0.0.1:8000/b/")')"
assert '[ "$(drive redact "s3:https://s3.example.com/bucket/")" = "s3:https://s3.example.com/bucket/" ]' \
    "a URL with no userinfo is untouched"
assert '[ "$(drive redact "/srv/backups/")" = "/srv/backups/" ]' \
    "and so is a plain path — nothing here parses a scheme"
assert '[ "$(drive redact "rest:http://user@host/b/")" = "rest:http://user@host/b/" ]' \
    "a bare username carries no secret and is left alone"
assert '[ "$(drive redact "rest:http://u:p@h/a:b@c/")" = "rest:http://u:***@h/a:b@c/" ]' \
    "only the authority is looked at — an @ in the path is not userinfo"
assert '! grep -qF "hunter2" <<<"$(drive redact "rest:http://u:hunter2@h/")"' \
    "and the password is nowhere in the result"

# --- Value checks --------------------------------------------------------------
for good in "s3:https://s3.example.com/bucket/" "rest:http://u:p@10.0.0.1:8000/" "/srv/backups/" "sftp:u@h:/srv/b/"; do
    out=$(drive check repo-base "$good"); rc=$?
    assert '[ "$rc" = "0" ]' "'$good' is a repository base (exit $rc: $(drive_err))"
done
for good in alpha a acme-corp a1; do
    assert '[ "$(drive check repo-name "$good")" = "ok" ]' "'$good' is a repository name"
done
for bad in Alpha 1alpha -alpha "al pha" "al/pha" "" traefik data backups; do
    drive check repo-name "$bad" >/dev/null; rc=$?
    assert '[ "$rc" != "0" ]' "'$bad' is not a repository name (exit $rc)"
done
# The exception, and the one that matters: `mail` is a repository — kasbah's own
# (D7) — so an operator has to be able to name it. It is refused as a project's
# `client:`, which is a different question asked in lib/deploy.sh.
assert '[ "$(drive check repo-name mail)" = "ok" ]' \
    "mail is a repository name: it is the one kasbah keeps the VPS's mailboxes in"
drive check password "$(printf 'a\nb')" >/dev/null; rc=$?
assert '[ "$rc" != "0" ]' "a password with a newline is refused — restic reads one line (exit $rc)"
assert 'grep -qF "first line" "$tmpdir/err"' "and says why (said '$(drive_err)')"

# --- The per-VPS jitter --------------------------------------------------------
# Derived rather than drawn, because the rendered compose file is compared byte
# for byte on every re-run: a random value would recreate the container each
# time init ran.
j1=$(drive jitter deploy@vps); j2=$(drive jitter deploy@vps); j3=$(drive jitter deploy@other)
assert '[ "$j1" = "$j2" ]' "the jitter is the same for one target on two runs ($j1 vs $j2)"
assert '[ "$j1" != "$j3" ]' "and differs between targets ($j1 vs $j3)"
assert '[ "$j1" -ge 0 ] && [ "$j1" -lt 3600 ]' "and lands inside the hour (got $j1)"

# --- The marker ----------------------------------------------------------------
# The field this whole rule exists for. docs/server-setup.md names
# backup.repo_base as the key a newer kasbah writes and an older one must not
# eat — and Phase 2 lost an unknown key from a marker exactly this way.
existing='{"kasbah_version":"0.1.0","apps_path":"/apps","data_path":"/apps/data","cpu_limit":"1.8","mem_limit":"3g","backup":{"enabled":true,"repo_base":"s3:https://old/","from_a_newer_kasbah":42,"retention":{"daily":7,"also_newer":1}},"future_key":{"kept":[1,2]}}'

marker_run() { tmp_root="$tmpdir" bash -c '
    . "$KASBAH_LIB_DIR/common.sh"; . "$KASBAH_LIB_DIR/server_init.sh"
    _server_marker_json "$@"' _ "$@" 2>"$tmpdir/err"; }

m=$(marker_run 0.2.0 /apps /apps/data 3.6 7g "$existing")
assert '[ "$(jq -r .backup.repo_base <<<"$m")" = "s3:https://old/" ]' \
    "a run that is not installing backups leaves repo_base alone (got '$(jq -c .backup <<<"$m")')"
assert '[ "$(jq -r .backup.from_a_newer_kasbah <<<"$m")" = "42" ]' \
    "and a key inside backup: that this kasbah has never heard of"
assert '[ "$(jq -c .future_key <<<"$m")" = "{\"kept\":[1,2]}" ]' \
    "and a top-level one"

b='{"enabled":true,"repo_base":"rest:http://new/","at":"02:00","jitter":11,"timeout":900,"retention":{"daily":7,"weekly":4,"monthly":3}}'
m=$(marker_run 0.2.0 /apps /apps/data 3.6 7g "$existing" "$b")
assert '[ "$(jq -r .backup.repo_base <<<"$m")" = "rest:http://new/" ]' \
    "--with-backup rewrites the fields it owns (got '$(jq -c .backup <<<"$m")')"
assert '[ "$(jq -r .backup.from_a_newer_kasbah <<<"$m")" = "42" ]' \
    "and still leaves an unknown key inside backup: standing"
assert '[ "$(jq -r .backup.retention.also_newer <<<"$m")" = "1" ]' \
    "including one nested inside retention:, which is merged rather than replaced"
assert '[ "$(jq -r .backup.retention.weekly <<<"$m")" = "4" ]' "while the known ones are this run's"
assert '[ "$(jq -r .backup.at <<<"$m")" = "02:00" ]' "the slot is recorded, as docs/backup.md requires"
assert '[ "$(jq -r .backup.jitter <<<"$m")" = "11" ]' "and the jitter"
assert '[ "$(jq -r .backup.timeout <<<"$m")" = "900" ]' \
    "and the bound on one restic call, so backup-prune and a re-run read the same number"

m2=$(marker_run 0.2.0 /apps /apps/data 3.6 7g "$m" "$b")
assert '[ "$m" = "$m2" ]' "merging a backup marker into itself is a no-op, byte for byte"

m=$(marker_run 0.1.0 /apps /apps/data 3.6 7g)
assert '[ "$(jq -r .backup.enabled <<<"$m")" = "false" ]' \
    "a fresh server with no backups records enabled:false (got '$m')"

out=$(drive markerbackup no x 02:00 1 7 4 3)
assert '[ -z "$out" ]' "a disabled run contributes no backup object at all (got '$out')"

# --- Reading it back -----------------------------------------------------------
out=$(drive frommarker "$existing")
assert 'grep -qxF "repo_base=s3:https://old/" <<<"$out"' \
    "a re-run reproduces the repository base off the server (got '$out')"
assert 'grep -qxF "origin=marker" <<<"$out"' "and says where it came from"
assert 'grep -qxF "daily=7" <<<"$out"' "along with the retention it recorded"
out=$(FLAG_REPO_BASE=rest:http://flag/ bash "$driver" frommarker "$existing" 2>"$tmpdir/err")
assert 'grep -qxF "repo_base=rest:http://flag/" <<<"$out"' \
    "and the flag outranks it (got '$out')"

# --- The repository set and D12's fallback ---------------------------------------
out=$(drive reposet "alpha=acme beta=acme gamma=" no)
assert 'grep -qxF "repos=acme gamma" <<<"$out"' \
    "two projects sharing a client share one repository, and one without a record gets its own (got '$out')"
assert 'grep -qxF "fallbacks=gamma" <<<"$out"' \
    "and the one that fell back is named — a project deployed before backups existed is visible, not silent"
out=$(drive reposet "alpha=acme" yes)
assert 'grep -qxF "repos=acme mail" <<<"$out"' "mail gets a repository of its own (D7) (got '$out')"
out=$(drive reposet "" yes)
assert 'grep -qxF "repos=mail" <<<"$out"' "a server with mail and no projects still has one repository"
out=$(drive reposet "alpha=?" no)
assert 'grep -qxF "repos=alpha" <<<"$out"' \
    "a record that is not a repository name falls back to the project name (got '$out')"
assert 'grep -qxF "fallbacks=alpha" <<<"$out"' "and is reported as a fallback"

# --- The prompts, with no terminal ------------------------------------------------
# The tri-state rule: no flag and no terminal is a hard fail naming the flag,
# never an assumed value. Each of these is a value kasbah must not invent.
out=$(BK_PROJECTS="alpha=acme" drive values --with-backup); rc=$?
assert '[ "$rc" != "0" ]' "an unanswerable repository base fails (exit $rc: $out)"
assert 'grep -qF -- "--backup-repo-base=" "$tmpdir/err"' \
    "naming the flag that would have answered (said '$(drive_err)')"

out=$(BK_PROJECTS="alpha=acme" drive values --with-backup --backup-repo-base=rest:http://x/); rc=$?
assert '[ "$rc" != "0" ]' "an unanswerable environment question fails (exit $rc: $out)"
assert 'grep -qF -- "--backup-env=KEY=VALUE or --no-backup-env" "$tmpdir/err"' \
    "naming both flags (said '$(drive_err)')"

out=$(BK_PROJECTS="alpha=acme" drive values --with-backup \
      --backup-repo-base=rest:http://x/ --no-backup-env); rc=$?
assert '[ "$rc" != "0" ]' "an unanswerable repository password fails (exit $rc: $out)"
assert 'grep -qF -- "--backup-password=acme=<value>" "$tmpdir/err"' \
    "naming the flag with the repository in it (said '$(drive_err)')"

# --- Settled values ---------------------------------------------------------------
out=$(BK_PROJECTS="alpha=acme beta=" BK_MAIL=yes drive values --with-backup \
      --backup-repo-base=rest:http://x/ --no-backup-env \
      --backup-password=acme=p1 --backup-password=beta=p2 --backup-password=mail=p3); rc=$?
assert '[ "$rc" = "0" ]' "with every password given, no prompt is reached (exit $rc: $(drive_err))"
assert 'grep -qxF "at=02:00" <<<"$out"'  "the slot defaults to 02:00 (got '$out')"
assert 'grep -qxF "retention=7/4/3" <<<"$out"' "and retention to 7/4/3, as docs/backup.md says"
assert 'grep -qxF "timeout=900" <<<"$out"' \
    "and one restic call is bounded at 900s — the wedge the schedule loop cannot otherwise leave"
assert 'grep -qxF "repos=acme beta mail" <<<"$out"' \
    "the repositories are the clients plus mail (got '$out')"
assert 'grep -qxF "new=acme beta mail" <<<"$out"' "all three need a password written"
assert 'grep -qxF "env_origin=none" <<<"$out"' "--no-backup-env is recorded as such"

# A password already on the server is never asked for and never rewritten: it
# decrypts that client's whole history, and a rotated one is a repository nobody
# can read. Same rule postfix-accounts.cf is under.
out=$(BK_PROJECTS="alpha=acme" BK_HASPASS="acme" drive values --with-backup \
      --backup-repo-base=rest:http://x/ --no-backup-env); rc=$?
assert '[ "$rc" = "0" ]' "a repository whose password is already there is not asked about (exit $rc: $(drive_err))"
assert 'grep -qxF "new=" <<<"$out"' "and nothing is written for it (got '$out')"

out=$(BK_PROJECTS="alpha=acme" BK_HASPASS="acme" drive values --with-backup \
      --backup-repo-base=rest:http://x/ --no-backup-env --backup-password=acme=new); rc=$?
assert '[ "$rc" = "0" ]' "--backup-password for a repository that has one is not a failure (exit $rc)"
assert 'grep -qxF "new=" <<<"$out"' "and does not rewrite it (got '$out')"
assert 'grep -qF "had no effect" "$tmpdir/err"' "but says so (said '$(drive_err)')"

# A password may be given for a repository no project claims yet, so a client can
# be seeded before its first deploy.
out=$(BK_PROJECTS="" drive values --with-backup --backup-repo-base=rest:http://x/ \
      --no-backup-env --backup-password=future=p); rc=$?
assert '[ "$rc" = "0" ]' "a password for a repository nothing claims yet is accepted (exit $rc: $(drive_err))"
assert 'grep -qxF "repos=future" <<<"$out"' "and the repository joins the set (got '$out')"

# The env question is asked once — on the run that creates the file. After that
# the file is the operator's, exactly as <apps>/mail/.env is.
out=$(BK_PROJECTS="" BK_ENVCUR="KASBAH_BACKUP_REPO_BASE=rest:http://x/
AWS_ACCESS_KEY_ID=k" drive values --with-backup --backup-repo-base=rest:http://x/); rc=$?
assert '[ "$rc" = "0" ]' "a server that already has an env file is not asked again (exit $rc: $(drive_err))"
assert 'grep -qxF "env_origin=file" <<<"$out"' "and the file is where the answer comes from (got '$out')"

# --- The env file merge -----------------------------------------------------------
default="$tmpdir/env.default"
printf '# a comment\nKASBAH_BACKUP_REPO_BASE=rest:http://new/\n# yours below\n' > "$default"
current="$tmpdir/env.current"
printf '# a comment\nKASBAH_BACKUP_REPO_BASE=rest:http://old/\n# yours below\nAWS_ACCESS_KEY_ID=theirs\nAWS_SECRET_ACCESS_KEY=alsotheirs\n' > "$current"

out=$(drive mergeenv rest:http://new/ "$default" "$current")
assert 'grep -qxF "KASBAH_BACKUP_REPO_BASE=rest:http://new/" <<<"$out"' \
    "kasbah's own key is rewritten by name (got '$out')"
assert 'grep -qxF "AWS_ACCESS_KEY_ID=theirs" <<<"$out"' \
    "and every other line is copied through untouched — the operator's credentials never leave the server"
assert 'grep -qxF "# yours below" <<<"$out"' "comments included"

out=$(drive mergeenv rest:http://new/ "$default" "$current" AWS_ACCESS_KEY_ID=fresh)
assert 'grep -qxF "AWS_ACCESS_KEY_ID=fresh" <<<"$out"' \
    "a key named on the command line is rewritten in place (got '$out')"
assert '[ "$(grep -c "^AWS_ACCESS_KEY_ID=" <<<"$out")" = "1" ]' "once, not twice"
assert 'grep -qxF "AWS_SECRET_ACCESS_KEY=alsotheirs" <<<"$out"' "and the one beside it is left alone"

out=$(drive mergeenv rest:http://new/ "$default" "$current" NEW_ONE=v)
assert 'grep -qxF "NEW_ONE=v" <<<"$out"' "a key the file does not carry is appended, not dropped"

out=$(drive mergeenv rest:http://new/ "$default" "" )
assert 'grep -qxF "KASBAH_BACKUP_REPO_BASE=rest:http://new/" <<<"$out"' \
    "a server with no env file gets the rendered default (got '$out')"
assert 'grep -qF "# yours below" <<<"$out"' "with its operator section intact"

# The merge is what a re-run compares against, so it has to converge — down to
# the last byte. Captured through a `printf x` sentinel, because $(…) strips
# trailing newlines and a comparison without one cannot see a file that grows by
# a newline on every run. It did: the here-string the merge reads from appends a
# newline of its own.
merge_exact() {
    local o
    o=$( { drive mergeenv "$1" "$2" "$3"; printf x; } )
    printf '%s' "${o%x}"
}
merged=$(merge_exact rest:http://new/ "$default" "$current"; printf x); merged="${merged%x}"
printf '%s' "$merged" > "$tmpdir/env.merged"
again=$(merge_exact rest:http://new/ "$default" "$tmpdir/env.merged"; printf x); again="${again%x}"
assert '[ "$merged" = "$again" ]' \
    "merging a merged env file again changes nothing, byte for byte
        (first  ${#merged} bytes, second ${#again} bytes)"
# And the run that creates the file converges on the second pass too — the shape
# an init has on a server it has just prepared.
first=$(merge_exact rest:http://new/ "$default" ""; printf x); first="${first%x}"
printf '%s' "$first" > "$tmpdir/env.first"
second=$(merge_exact rest:http://new/ "$default" "$tmpdir/env.first"; printf x); second="${second%x}"
assert '[ "$first" = "$second" ]' \
    "and so does the rendered default it starts from (first ${#first} bytes, second ${#second} bytes)"

# --- Rendering --------------------------------------------------------------------
rendered="$tmpdir/rendered"
mkdir -p "$rendered"
out=$(RENDER_OUT="$rendered" BK_NEWPASS="acme mail" drive render /apps /apps/data rest:http://u:p@h:8000/ 02:00 1234); rc=$?
assert '[ "$rc" = "0" ]' "the stack renders (exit $rc: $(drive_err))"
assert 'yq -e . "$rendered/compose.yml" >/dev/null' "and the compose file is valid YAML"
assert 'grep -qxF "600 ./env" <<<"$out"' "the env file is mode 600 — it holds the credentials (got '$out')"
assert 'grep -qxF "600 ./repos/acme.pass" <<<"$out"' "each password file is mode 600"
assert 'grep -qxF "700 ./repos" <<<"$out"' "in a directory nobody else can list"
assert 'grep -qxF "755 ./backup.sh" <<<"$out"' "and the runner is executable"
assert 'grep -qxF "644 ./compose.yml" <<<"$out"' "while the compose file carries no secret and is 644"

assert 'grep -qF "restic/restic:" "$rendered/compose.yml"' "the compose file pins restic"
pin=$(sed -n 's/^KASBAH_RESTIC_IMAGE=//p' "$repo_dir/lib/common.sh")
assert 'grep -qF "image: $pin" "$rendered/compose.yml"' \
    "with lib/common.sh's constant and not a second copy of it (expected $pin)"
assert '! grep -qE "^version:" "$rendered/compose.yml"' "and carries no version: attribute"
assert 'grep -qF "KASBAH_BACKUP_JITTER: 1234" "$rendered/compose.yml"' "the jitter is baked in"
assert 'grep -qF "KASBAH_BACKUP_AT: 02:00" "$rendered/compose.yml"' "and the slot"
assert 'grep -qF "KASBAH_BACKUP_TIMEOUT: 900" "$rendered/compose.yml"' "and the bound on one restic call"
assert 'grep -qF "backup.sh\", \"health\"" "$rendered/compose.yml"' \
    "the stack declares a healthcheck — without one a wedged scheduler is a container
        \`docker ps\` calls running for ever and restart: unless-stopped never acts on"
assert 'grep -qF "/apps/.kasbah/backup/state:/apps/.kasbah/backup/state\"" "$rendered/compose.yml"' \
    "with a writable window for the status file it reads, and nothing wider"
assert '[ "$(grep -c ":ro\"" "$rendered/compose.yml")" = "3" ]' \
    "everything else stays read-only (got $(grep -c ":ro\"" "$rendered/compose.yml") ro mounts)"
assert 'grep -qF "\"/apps:/apps:ro\"" "$rendered/compose.yml"' \
    "the apps path is mounted at its own name, so a snapshot's paths are the server's paths"
assert 'grep -qF "\"/apps/data:/apps/data:ro\"" "$rendered/compose.yml"' "and so is the data path"
assert '! grep -qF "u:p@h" "$rendered/compose.yml"' \
    "the repository URL is nowhere in the compose file — it can carry a credential, and this file is 644"
assert 'grep -qF "u:p@h" "$rendered/env"' "it is in the 600 env file instead"
assert '[ "$(cat "$rendered/repos/acme.pass")" = "pw-for-acme" ]' "the password file holds the password"

# Two renders of the same inputs are the same bytes — that is what makes "a
# re-run changes nothing" checkable at all.
rendered2="$tmpdir/rendered2"; mkdir -p "$rendered2"
RENDER_OUT="$rendered2" BK_NEWPASS="acme mail" drive render /apps /apps/data rest:http://u:p@h:8000/ 02:00 1234 >/dev/null
assert 'diff -r "$rendered" "$rendered2" >/dev/null' "two renders of the same inputs are identical"

# Docker refuses two mounts on one target, so the data mount is left out when
# the two paths are the same. A data path merely *below* the apps path is a
# second, narrower read-only bind and is rendered.
same="$tmpdir/rendered-same"; mkdir -p "$same"
RENDER_OUT="$same" drive render /apps /apps rest:http://x/ >/dev/null; rc=$?
assert '[ "$rc" = "0" ]' "a data path equal to the apps path renders (exit $rc: $(drive_err))"
assert '[ "$(grep -c ":ro\"" "$same/compose.yml")" = "2" ]' \
    "with one bind for the tree and one for localtime, not a duplicate mount point (got $(grep -c ":ro\"" "$same/compose.yml"))"
assert 'yq -e . "$same/compose.yml" >/dev/null' "and is still valid YAML"

outside="$tmpdir/rendered-outside"; mkdir -p "$outside"
RENDER_OUT="$outside" drive render /apps /mnt/vol1 rest:http://x/ >/dev/null
assert 'grep -qF "\"/mnt/vol1:/mnt/vol1:ro\"" "$outside/compose.yml"' \
    "a data path outside the apps path is mounted too"

# The runner is shipped byte for byte from the checkout: everything it needs
# arrives in the container's environment, so there is nothing to render into it
# and the copy on a server can be diffed against this file.
assert 'diff "$repo_dir/templates/backup/backup.sh" "$rendered/backup.sh" >/dev/null' \
    "the runner on the server is this checkout's, byte for byte"

# --- What travels how -------------------------------------------------------------
# The rule this whole file is arranged around: a secret goes by rsync into a
# mode-600 file, never as an argument to a remote step. argv is readable in the
# process table for as long as the step runs.
drive ship >/dev/null; err_out=$(drive_err)
assert 'grep -qF "rsync|" <<<"$err_out"' "the secrets go by rsync (saw '$err_out')"
assert 'grep -qF "backup/repos/alpha.pass" <<<"$err_out"' "the password file among them"
assert 'grep -qF -- "--chmod=F600" <<<"$err_out"' "landing at mode 600 whatever the far side's umask"
assert '! grep -qF "topsecret" <<<"$err_out"' \
    "and the password itself is in no call at all (saw '$err_out')"
ssh_calls=$(grep -F "ssh_script|" <<<"$err_out")
assert '! grep -qF "topsecret" <<<"$ssh_calls"' \
    "least of all in a remote step's argv (saw '$ssh_calls')"
assert '! grep -qF "ENVFILE" <<<"$ssh_calls"' "nor the env file's contents"

# --- Shipping the two owned files ---------------------------------------------------
out=$(drive sync); err_out=$(drive_err)
assert 'grep -qxF "changed=compose.yml backup.sh" <<<"$out"' \
    "both files ship when the server has neither (got '$out')"
assert 'grep -qxF "restart=yes" <<<"$out"' \
    "and a new runner forces a restart — it is bind-mounted, so compose sees no change to recreate for"
out=$(SAME_COMPOSE="COMPOSE
" SAME_RUNNER="RUNNER
" drive sync)
assert 'grep -qxF "changed=" <<<"$out"' "nothing ships when nothing differs (got '$out')"
assert 'grep -qxF "restart=no" <<<"$out"' "and nothing restarts"
out=$(SAME_RUNNER="RUNNER
" drive sync)
assert 'grep -qxF "changed=compose.yml" <<<"$out"' "a changed compose file alone ships alone"
assert 'grep -qxF "restart=no" <<<"$out"' \
    "and does not force a restart — a changed service definition is something \`up -d\` recreates for"

# --- The credential probe's verdict --------------------------------------------------
# The security property, read from the one thing that cannot lie about it: how
# many snapshots were left after the delete attempt. Not the exit status, and not
# the wording — 8.0 measured a `forget` that exited non-zero on restic's own
# argument check without ever reaching the server.
probe_out() {
    printf 'probe_repo=%s\nprobe_stage=%s\nprobe_mid=%s\nprobe_after=%s\nprobe_rc=%s\nprobe_when=%s\nprobe_log_b64=%s\n' \
        "${PROBE_REPO:-rest://x/kasbah.probe}" "$1" "$2" "$3" "$4" "${5:--}" \
        "$(printf 'restic said something' | openssl base64 -A)"
}
# The driver configures rest:http://x/ , so the probe's own repository is this.
PROBE_REPO='rest:http://x/kasbah.probe'
export PROBE_REPO
out=$(drive probe "$(probe_out deleted 2 2 1)"); rc=$?
assert '[ "$rc" = "0" ]' "a credential that could not delete passes (exit $rc: $(drive_err))"
assert 'grep -qxF "probe=append-only" <<<"$out"' "and is recorded as append-only (got '$out')"

out=$(drive probe "$(probe_out deleted 2 1 0)"); rc=$?
assert '[ "$rc" != "0" ]' "a credential that deleted a snapshot is refused (exit $rc)"
assert 'grep -qF "can DELETE" "$tmpdir/err"' "loudly (said '$(drive_err)')"
assert 'grep -qF "No backup stack was started" "$tmpdir/err"' \
    "and says nothing was scheduled to use it"

# The same refusal against a server that already has a stack. The credentials are
# written before the probe — it has to test the ones that will be in effect — so
# a stack that was already running still is, now holding refused credentials.
# "No backup stack was started" would be false there, and it is the sentence an
# operator acts on.
out=$(BK_HASSTACK=yes drive probe "$(probe_out deleted 2 1 0)"); rc=$?
assert '[ "$rc" != "0" ]' "a re-run with credentials that can delete is refused too (exit $rc)"
assert '! grep -qF "No backup stack was started" "$tmpdir/err"' \
    "and does not claim nothing is running (said '$(drive_err)')"
assert 'grep -qF "is still running" "$tmpdir/err"' \
    "it says the stack that was there still is (said '$(drive_err)')"
assert 'grep -qF "kasbah-backup down" "$tmpdir/err"' "and how to stop it"

# The exit status is deliberately not the verdict. A `forget` that fails and
# still removed something is a refusal; one that succeeds and removed nothing is
# not — because it is the history that matters, not what restic said about it.
out=$(drive probe "$(probe_out deleted 2 1 1)"); rc=$?
assert '[ "$rc" != "0" ]' "a delete that took a snapshot is refused even when restic exited non-zero (exit $rc)"
out=$(drive probe "$(probe_out deleted 2 2 0)"); rc=$?
assert '[ "$rc" = "0" ]' "and a forget that exited 0 having removed nothing is not a deletion (exit $rc: $(drive_err))"

# A listing that failed and a repository that listed nothing are the same number
# and opposite facts. Reading the second as the first would refuse a credential
# that was fine and send the operator to replace it.
out=$(drive probe "$(probe_out unlisted 2 0 1 after)"); rc=$?
assert '[ "$rc" != "0" ]' "a listing that failed after the delete attempt is refused (exit $rc)"
assert 'grep -qF "could not list" "$tmpdir/err"' \
    "as unknown rather than as a deletion (said '$(drive_err)')"
assert '! grep -qF "can DELETE" "$tmpdir/err"' \
    "and never accuses the credential of deleting (said '$(drive_err)')"
assert 'grep -qF -- "--backup-timeout=" "$tmpdir/err"' "naming the bound that most often causes it"
assert 'grep -qF "after the delete attempt" "$tmpdir/err"' "and saying which of the two listings it was"
out=$(drive probe "$(probe_out unlisted 0 0 1 before)"); rc=$?
assert '[ "$rc" != "0" ]' "and so is one that failed before it (exit $rc)"
assert 'grep -qF "before the delete attempt" "$tmpdir/err"' "said the other way round (said '$(drive_err)')"

# What was probed and what will be written have to be the same repository. If
# they ever diverge the run stops, rather than reporting a URL it never opened.
elsewhere=$(PROBE_REPO='rest:http://elsewhere/kasbah.probe' probe_out deleted 2 2 1)
out=$(drive probe "$elsewhere"); rc=$?
assert '[ "$rc" != "0" ]' "a probe that opened another repository is an internal failure (exit $rc)"
assert 'grep -qF "are not the same repository" "$tmpdir/err"' "and says so (said '$(drive_err)')"

# The credential in a repository URL is redacted wherever kasbah prints one —
# restic redacts its own, and kasbah printing the password in the same paragraph
# made kasbah the less careful of the two.
secret_probe=$(PROBE_REPO='rest:http://u:hunter2@h/kasbah.probe' probe_out deleted 2 1 0)
out=$(BK_BASE='rest:http://u:hunter2@h/' drive probe "$secret_probe"); rc=$?
assert '[ "$rc" != "0" ]' "a refusal against a credential-bearing URL still refuses (exit $rc)"
assert '! grep -qF "hunter2" "$tmpdir/err"' \
    "and the password is nowhere in the refusal (said '$(drive_err)')"
assert 'grep -qF "u:***@h" "$tmpdir/err"' "which still names the repository (said '$(drive_err)')"
secret_reach=$(PROBE_REPO='rest:http://u:hunter2@h/kasbah.probe' probe_out reach 0 0 1)
out=$(BK_BASE='rest:http://u:hunter2@h/' drive probe "$secret_reach"); rc=$?
assert '! grep -qF "hunter2" "$tmpdir/err"' \
    "nor in the unreachable one (said '$(drive_err)')"

# The paired positive. A credential that cannot even write fails here, with its
# own message — so "the delete was refused" can never be "restic never tried".
out=$(drive probe "$(probe_out reach 0 0 1)"); rc=$?
assert '[ "$rc" != "0" ]' "a credential that cannot reach the repository is refused (exit $rc)"
assert 'grep -qF "cannot reach" "$tmpdir/err"' "with its own diagnosis (said '$(drive_err)')"
assert 'grep -qF -- "--backup-env=KEY=VALUE" "$tmpdir/err"' "naming the flag that supplies credentials"
out=$(drive probe "$(probe_out write 0 0 1)"); rc=$?
assert '[ "$rc" != "0" ]' "a credential that cannot write is refused (exit $rc)"
assert 'grep -qF "cannot write" "$tmpdir/err"' "and said so (said '$(drive_err)')"

# restic groups snapshots by host before applying a retention policy, and
# `docker run` hands out a random hostname — so a probe that did not pin one
# would leave a repository `server backup-prune` can never collapse, growing by
# a snapshot per init run. Asserted against the payload, since the verdict above
# cannot see it.
# To the heredoc's own delimiter, not to the first `}`: the payload carries
# shell functions of its own, and a `,/^}/` range would stop at the first of them.
probe_body=$(sed -n "/^_bk_probe() {/,/^REMOTE\$/p" "$repo_dir/lib/backup.sh")
assert 'grep -qF -- "--hostname kasbah-probe" <<<"$probe_body"' \
    "the probe pins its container's hostname, so its snapshots are one retention group"

# The vacuity guard. Two probe snapshots is what makes forgetting one of them a
# real deletion attempt: forgetting the only snapshot in a repository is the
# "remove everything" case restic refuses on its own argument check, without
# contacting the server (measured in 8.0) — so a one-snapshot probe would pass
# against a credential that can delete everything.
out=$(drive probe "$(probe_out deleted 1 1 1)"); rc=$?
assert '[ "$rc" != "0" ]' "a probe that only managed one snapshot is an internal failure, not a pass (exit $rc)"
assert 'grep -qF "would have proved nothing" "$tmpdir/err"' \
    "and says why (said '$(drive_err)')"

# --- The probe's own environment file, built for real ----------------------------------
# The payload extracted from lib/backup.sh and run against a stub docker, because
# what matters is the file that reaches `--env-file` and nothing else can show
# it. `docker --env-file` is last-wins, so the order of these lines *is* the
# invariant: kasbah's two keys go in last, after the operator's block.
probe_payload="$tmpdir/probe_payload.sh"
awk '/<<'"'"'REMOTE'"'"'$/{buf=""; inb=1; next} inb && /^REMOTE$/{if (buf ~ /probe_stage=deleted/) printf "%s", buf; inb=0; next} inb{buf = buf $0 "\n"}' \
    "$repo_dir/lib/backup.sh" > "$probe_payload"
assert '[ -s "$probe_payload" ]' "the credential probe's remote payload was found in lib/backup.sh"

probe_tree="$tmpdir/probetree"
mkdir -p "$probe_tree/.kasbah/backup" "$tmpdir/stub"
cat > "$tmpdir/stub/docker" <<'STUB'
#!/usr/bin/env bash
# Copies whatever --env-file it was handed, then fails: the probe stops at
# `reach`, which is all this case needs to see the file.
prev=""
for a in "$@"; do
    [ "$prev" != "--env-file" ] || cp "$a" "$PROBE_ENV_COPY"
    prev="$a"
done
echo "stub docker: no daemon here" >&2
exit 1
STUB
chmod 0755 "$tmpdir/stub/docker"

printf 'KASBAH_BACKUP_REPO_BASE=rest:http://real/\nAWS_ACCESS_KEY_ID=theirs\nRESTIC_REPOSITORY=rest:http://sneaky/\nRESTIC_PASSWORD=sneaky\nKASBAH_BACKUP_SOMETHING=x\n' \
    > "$probe_tree/.kasbah/backup/env"
out=$(PATH="$tmpdir/stub:$PATH" PROBE_ENV_COPY="$tmpdir/probe.env" \
      bash "$probe_payload" img "$probe_tree" kasbah.probe probe-pw 900 \
      "RESTIC_REPOSITORY RESTIC_REPOSITORY_FILE RESTIC_PASSWORD RESTIC_PASSWORD_FILE RESTIC_PASSWORD_COMMAND" 2>&1); rc=$?
assert '[ "$rc" = "0" ]' "the probe payload runs (exit $rc: $out)"
assert 'grep -qxF "probe_stage=reach" <<<"$out"' "and reports the stub's failure as unreachable (got '$out')"
assert 'grep -qxF "probe_repo=rest:http://real/kasbah.probe" <<<"$out"' \
    "it reports the repository it built from the env file, not from a flag (got '$out')"

envcopy=$(cat "$tmpdir/probe.env")
assert '[ -s "$tmpdir/probe.env" ]' "the stub captured the --env-file (got '$envcopy')"
assert '[ "$(tail -2 "$tmpdir/probe.env" | head -1)" = "RESTIC_REPOSITORY=rest:http://real/kasbah.probe" ]' \
    "kasbah's repository is written last, where docker's last-wins makes it win (file: $envcopy)"
assert '[ "$(tail -1 "$tmpdir/probe.env")" = "RESTIC_PASSWORD_FILE=/probe/pass" ]' \
    "and its password file after it (file: $envcopy)"
assert 'grep -qxF "AWS_ACCESS_KEY_ID=theirs" "$tmpdir/probe.env"' "the operator's own keys are carried through"
assert '! grep -qF "sneaky" "$tmpdir/probe.env"' \
    "and a RESTIC_ key kasbah owns is dropped outright, not merely outranked (file: $envcopy)"
assert '! grep -qF "KASBAH_BACKUP_SOMETHING" "$tmpdir/probe.env"' "as is kasbah's own namespace"

# --- The server read's project list, run for real ---------------------------------------
# A non-default --data-path puts a directory called something other than `data`
# beside the projects. Excluding by *name* offered it as a repository — one init
# would ask for a password for and the runner would never write to, because the
# runner excludes by path.
read_payload="$tmpdir/read_payload.sh"
awk '/<<'"'"'REMOTE'"'"'$/{buf=""; inb=1; next} inb && /^REMOTE$/{if (buf ~ /backup_projects=/) printf "%s", buf; inb=0; next} inb{buf = buf $0 "\n"}' \
    "$repo_dir/lib/backup.sh" > "$read_payload"
assert '[ -s "$read_payload" ]' "the backup read's remote payload was found in lib/backup.sh"

read_tree="$tmpdir/readtree"
mkdir -p "$read_tree/.kasbah/backup/repos" "$read_tree/alpha" "$read_tree/traefik" \
         "$read_tree/mail" "$read_tree/backups" "$read_tree/vol/alpha"
printf 'acme\n' > "$read_tree/alpha/.kasbah-client"
printf 'mail\n' > "$read_tree/mail/.env"
reserved_list=$(bash -c '. "$KASBAH_LIB_DIR/common.sh"; . "$KASBAH_LIB_DIR/manifest.sh"; printf "%s" ".kasbah ${KASBAH_RESERVED_NAMES[*]}"')
out=$(bash "$read_payload" "$read_tree" "$read_tree/vol" "$reserved_list" 2>&1); rc=$?
assert '[ "$rc" = "0" ]' "the read payload runs (exit $rc: $out)"
projects=$(sed -n 's/^backup_projects=//p' <<<"$out")
assert '[ "$projects" = "alpha=acme" ]' \
    "a non-default data path is not a project, so no repository is invented for it (got '$projects')"
assert 'grep -qxF "backup_mail=yes" <<<"$out"' "and the mail stack is still seen"

# The same tree with the default data path: `data` is excluded by the reserved
# list, so the two rules agree where they overlap.
mkdir -p "$read_tree/data"
out=$(bash "$read_payload" "$read_tree" "$read_tree/data" "$reserved_list" 2>&1)
projects=$(sed -n 's/^backup_projects=//p' <<<"$out")
assert '[ "$projects" = "alpha=acme vol=" ]' \
    "and with the default data path it is the reserved name data that drops out (got '$projects')"

# A client record naming something kasbah owns comes back as `?` — the caller
# falls it back to the project's own name rather than filing it into the mail
# repository, which holds every mailbox on the server.
printf 'mail\n' > "$read_tree/alpha/.kasbah-client"
out=$(bash "$read_payload" "$read_tree" "$read_tree/data" "$reserved_list" 2>&1)
projects=$(sed -n 's/^backup_projects=//p' <<<"$out")
assert '[ "${projects%% *}" = "alpha=?" ]' \
    "a client record naming a reserved name is refused at the read (got '$projects')"
printf 'acme\n' > "$read_tree/alpha/.kasbah-client"

# --- server backup-prune's command line -----------------------------------------------
out=$(drive bpparse deploy@vps); rc=$?
assert '[ "$rc" = "0" ]' "a bare target parses (exit $rc: $(drive_err))"
assert 'grep -qxF "target=deploy@vps" <<<"$out"' "the target is kept"
assert 'grep -qxF "repo_base=unset" <<<"$out"' "the base is unset — the marker's is the default"
assert 'grep -qxF "daily=unset" <<<"$out"' "and so is the retention"

out=$(drive bpparse deploy@vps --repo-base=s3:https://h/b/ --env=AWS_ACCESS_KEY_ID=k \
      --repo=acme --repo=mail --keep-daily=1 --keep-weekly=2 --keep-monthly=3 \
      --docker-network=some-net --dry-run --yes); rc=$?
assert '[ "$rc" = "0" ]' "every flag parses (exit $rc: $(drive_err))"
assert 'grep -qxF "repo_base=s3:https://h/b/" <<<"$out"' "--repo-base is recorded"
assert 'grep -qxF "env=AWS_ACCESS_KEY_ID=k" <<<"$out"'   "--env is recorded"
assert 'grep -qxF "only=acme mail" <<<"$out"'            "--repo is repeatable"
assert 'grep -qxF "dry=yes" <<<"$out"'                   "--dry-run is recorded"
assert 'grep -qxF "yes=yes" <<<"$out"'                   "--yes is recorded"
assert 'grep -qxF "network=some-net" <<<"$out"'          "--docker-network is recorded"
drive bpparse deploy@vps --docker-network="not a network" >/dev/null; rc=$?
assert '[ "$rc" != "0" ]' "--docker-network with a bad name fails (exit $rc)"

drive bpparse >/dev/null; rc=$?
assert '[ "$rc" != "0" ]' "backup-prune with no target fails (exit $rc)"
assert 'grep -qF "USER@HOST" "$tmpdir/err"' "naming what it wanted (said '$(drive_err)')"
drive bpparse deploy@vps --repo=Alpha >/dev/null; rc=$?
assert '[ "$rc" != "0" ]' "--repo with a bad name fails (exit $rc)"
drive bpparse deploy@vps --nonsense >/dev/null; rc=$?
assert '[ "$rc" != "0" ]' "an unknown flag fails (exit $rc)"
assert 'grep -qF "unknown flag" "$tmpdir/err"' "and says so"

# Every checker is shared with `server init`, and each one has to name *this*
# command and *this* command's flag. Pinned, because asserting only the exit
# status let three messages name a command it is not and flags it does not have.
bp_reject() {
    local what="$1" needle="$2"; shift 2
    local rc
    drive bpparse deploy@vps "$@" >/dev/null; rc=$?
    assert '[ "$rc" != "0" ]' "$what is refused (exit $rc)"
    assert 'grep -qF -- "$needle" "$tmpdir/err"' "$what says so in this command's words (said '$(drive_err)')"
    assert '! grep -qF "server init" "$tmpdir/err"' "and does not name server init (said '$(drive_err)')"
    assert '! grep -qF -- "--backup-" "$tmpdir/err"' "or a --backup- flag it does not have (said '$(drive_err)')"
}
bp_reject "--env= with a bad key"        "server backup-prune: the key of --env= is '9BAD'" --env=9BAD=v
bp_reject "--env= with no ="             "server backup-prune: --env= must be KEY=VALUE"    --env=NOEQUALS
bp_reject "--keep-daily= with a word"    "server backup-prune: --keep-daily=lots"           --keep-daily=lots
bp_reject "--keep-weekly= with a word"   "server backup-prune: --keep-weekly=lots"          --keep-weekly=lots
bp_reject "--keep-monthly= with a word"  "server backup-prune: --keep-monthly=lots"         --keep-monthly=lots
bp_reject "--repo-base= with no slash"   "server backup-prune: --repo-base=s3:https://h/b"  --repo-base=s3:https://h/b
bp_reject "--repo= with a bad name"      "server backup-prune: --repo=Alpha is not a repository name" --repo=Alpha
bp_reject "--repo= naming a kasbah directory" "server backup-prune: --repo=traefik"         --repo=traefik

# And init's own messages still name init, so the parameterisation did not just
# move the wrong name somewhere else.
out=$(drive parse deploy@vps --backup-keep-daily=lots); rc=$?
assert 'grep -qF "server init: --backup-keep-daily=lots" "$tmpdir/err"' \
    "server init still speaks as itself (said '$(drive_err)')"

# A repository base carrying a credential is redacted in the refusal too.
drive bpparse deploy@vps --repo-base='rest:http://u:hunter2@h/b' >/dev/null; rc=$?
assert '[ "$rc" != "0" ]' "a credential-bearing base with no trailing slash is refused (exit $rc)"
assert '! grep -qF "hunter2" "$tmpdir/err"' "without printing the credential (said '$(drive_err)')"

# --- backup-prune's staged credentials ------------------------------------------------
out=$(drive bpstage "rest:http://b/" AWS_ACCESS_KEY_ID=k); rc=$?
assert '[ "$rc" = "0" ]' "the prune credentials stage (exit $rc: $(drive_err))"
assert 'grep -qxF "600 env/alpha.env" <<<"$(sed -n "s/^== //p" <<<"$out")"' \
    "each env file is mode 600 (got '$out')"
assert 'grep -qxF "600 pw/alpha.pass" <<<"$(sed -n "s/^== //p" <<<"$out")"' "and each password file"
alpha_env=$(sed -n '/^== 600 env\/alpha.env$/,/^== /p' <<<"$out" | sed '1d;/^== /d')
assert '[ "$(sed -n 2p <<<"$alpha_env")" = "RESTIC_REPOSITORY=rest://b/alpha" ] ||
        [ "$(sed -n 2p <<<"$alpha_env")" = "RESTIC_REPOSITORY=rest:http://b/alpha" ]' \
    "the operator's entry comes first and kasbah's repository after it (got '$alpha_env')"
assert '[ "$(sed -n 1p <<<"$alpha_env")" = "AWS_ACCESS_KEY_ID=k" ]' \
    "with the operator's own key first (got '$alpha_env')"
assert '[ "$(sed -n 3p <<<"$alpha_env")" = "RESTIC_PASSWORD_FILE=/pw/alpha.pass" ]' \
    "and kasbah's password file last, where docker's last-wins makes it win"

# With no --env at all the file must carry no blank line: `printf '%s\n'` over an
# empty array writes one, and a stray newline in a credential file is the kind of
# thing that works until the day something parses it strictly.
out=$(drive bpstage "rest:http://b/")
alpha_env=$(sed -n '/^== 600 env\/alpha.env$/,/^== /p' <<<"$out" | sed '1d;/^== /d')
assert '[ "$(grep -c "" <<<"$alpha_env")" = "2" ]' \
    "an empty environment stages exactly kasbah's two lines (got '$alpha_env')"
assert '! grep -qx "" <<<"$alpha_env"' "and no blank line among them"

# --- backup-prune's plan, its act, and where its report goes --------------------------
# `docker` is stubbed onto PATH only so the command's own prerequisite check
# passes: every restic call is intercepted in the driver above, so nothing here
# reaches a daemon and the suite does not need one.
bp_stub="$tmpdir/bpstub"
mkdir -p "$bp_stub"
printf '#!/bin/sh\nexit 0\n' > "$bp_stub/docker"
chmod 0755 "$bp_stub/docker"
bp_calls="$tmpdir/bp.calls"
prune_drive() {
    : > "$bp_calls"
    tmp_root="$tmpdir" BP_CALLS="$bp_calls" PATH="$bp_stub:$PATH" \
        bash "$driver" bpprune deploy@vps --repo-base=rest:http://b/ --no-env \
        --keep-daily=1 --keep-weekly=1 --keep-monthly=1 "$@" \
        >"$tmpdir/bpout" 2>"$tmpdir/err" </dev/null
}
bp_out() { cat "$tmpdir/bpout"; }

prune_drive --yes; rc=$?
assert '[ "$rc" = "0" ]' "a prune of three repositories exits 0 (exit $rc: $(drive_err))"
# docs/cli.md: the plan and the outcome both go to stdout, so a redirected run
# keeps its own report. This is the command that deletes backup history — an
# empty prune.log is the worst place for this defect to live.
assert 'grep -qF "Retention on deploy@vps" "$tmpdir/bpout"' \
    "the retention header is on stdout (stdout was '$(bp_out)')"
assert 'grep -qF "alpha — what would be removed" "$tmpdir/bpout"' "and the plan"
assert 'grep -qF "alpha — forgetting and pruning" "$tmpdir/bpout"' "and the act"
assert 'grep -qF "Pruned 3 repositories" "$tmpdir/bpout"' "and the closing count"
assert 'grep -qF "keep 1 snapshot, remove 1 snapshot" "$tmpdir/bpout"' "and restic's own lines"
assert '[ ! -s "$tmpdir/err" ]' \
    "with nothing on stderr on a clean run — only warning: and error: lines go there (said '$(drive_err)')"

# The probe repository is in the default set, which is what makes the closing
# count three: the two the server has passwords for, plus kasbah's own.
assert 'grep -qxF "kasbah.probe forget --prune --keep-daily 1 --keep-weekly 1 --keep-monthly 1" "$bp_calls"' \
    "the probe repository is pruned with the rest (calls: $(cat "$bp_calls"))"

# A repository whose dry run failed is *skipped*, and the act must honour that:
# the operator confirmed a plan that did not include it, and a transient dry-run
# failure would otherwise put the destructive call against a repository whose
# plan nobody saw.
BP_FAIL_DRY=beta prune_drive --yes; rc=$?
assert '[ "$rc" = "0" ]' "a prune whose dry run failed on one repository still exits 0 (exit $rc: $(drive_err))"
assert 'grep -qF "beta — restic exited 3 above; this repository is skipped" "$tmpdir/err"' \
    "saying so as a warning, on stderr (said '$(drive_err)')"
assert '! grep -q "^beta forget --prune" "$bp_calls"' \
    "and beta never reaches forget --prune (calls: $(cat "$bp_calls"))"
assert 'grep -q "^alpha forget --prune" "$bp_calls"' \
    "while the repositories that did plan are pruned (calls: $(cat "$bp_calls"))"
assert 'grep -qF "Pruned 2 repositories" "$tmpdir/bpout"' \
    "and the count is of what was pruned, not of what was discovered (stdout was '$(bp_out)')"

# Every dry run failing is not a prune with nothing to do: it is a run that
# could read nothing, and it refuses rather than confirming an empty plan.
BP_FAIL_DRY="alpha beta kasbah.probe" prune_drive --yes; rc=$?
assert '[ "$rc" != "0" ]' "a prune that could plan nothing fails (exit $rc)"
assert '! grep -q "forget --prune" "$bp_calls"' "having pruned nothing (calls: $(cat "$bp_calls"))"

# --dry-run stops before the act and says so on stdout with the rest of it.
prune_drive --dry-run; rc=$?
assert '[ "$rc" = "0" ]' "--dry-run exits 0 (exit $rc: $(drive_err))"
assert 'grep -qF -- "--dry-run: nothing was removed" "$tmpdir/bpout"' "and says so on stdout"
assert '! grep -q "forget --prune" "$bp_calls"' "having run no destructive call"

# A failed *act* is still a failure, and names how many of the planned set.
BP_FAIL_ACT=alpha prune_drive --yes; rc=$?
assert '[ "$rc" != "0" ]' "a repository the act could not prune fails the run (exit $rc)"
assert 'grep -qF "1 of 3 repositories were not pruned" "$tmpdir/err"' \
    "counted against the plan (said '$(drive_err)')"

# --repo=kasbah.probe: the flag's own --help names the probe repository as part
# of the default set, and pruning only it is the obvious use of the flag — it
# grows by two snapshots per init run. The `.` is exactly what a repository
# *name* may not carry, so the two checks are deliberately different.
out=$(drive bpparse deploy@vps --repo=kasbah.probe); rc=$?
assert '[ "$rc" = "0" ]' "--repo=kasbah.probe parses (exit $rc: $(drive_err))"
assert 'grep -qxF "only=kasbah.probe" <<<"$out"' "and is kept (got '$out')"
prune_drive --yes --repo=kasbah.probe; rc=$?
assert '[ "$rc" = "0" ]' "and prunes (exit $rc: $(drive_err))"
assert 'grep -qxF "kasbah.probe forget --prune --keep-daily 1 --keep-weekly 1 --keep-monthly 1" "$bp_calls"' \
    "the probe repository (calls: $(cat "$bp_calls"))"
assert '! grep -q "^alpha " "$bp_calls"' "and nothing else (calls: $(cat "$bp_calls"))"
# The dot is still refused everywhere a repository *name* is taken: --repo= is
# wider on purpose, and widening the charset would have been the wrong fix.
drive check repo-name kasbah.probe >/dev/null; rc=$?
assert '[ "$rc" != "0" ]' "and a --backup-password= repository named kasbah.probe is still refused (exit $rc)"

# lib/server_init.sh is where _si_render_template lives, and lib/backup.sh does
# not source it: three of its four entry points load it alone. A render from one
# of those is refused by name rather than dying on an undefined function.
render_alone=$(KASBAH_LIB_DIR="$repo_dir/lib" bash -c '
    set -uo pipefail
    . "$KASBAH_LIB_DIR/common.sh"
    . "$KASBAH_LIB_DIR/backup.sh"
    declare -F _si_render_template >/dev/null && { echo "server_init was loaded after all"; exit 0; }
    _BK_ENABLED=yes
    _bk_render /tmp/nowhere /apps /apps/data' 2>&1); rc=$?
assert '[ "$rc" != "0" ]' "_bk_render on a bare lib/backup.sh refuses (exit $rc: $render_alone)"
assert 'grep -qF "needs lib/server_init.sh loaded" <<<"$render_alone"' \
    "naming the file it is missing (said '$render_alone')"
assert '! grep -qF "command not found" <<<"$render_alone"' "rather than dying on an undefined function"

# --- The runner ---------------------------------------------------------------------
# Driven for real against a fake tree. The runner ships to a busybox container,
# so busybox is what runs it here when it is on the machine; bash is the fallback
# and is said out loud, because a bashism would survive it.
runner_sh=bash
runner_note="bash (busybox is not installed — a bashism would survive this run)"
if command -v busybox >/dev/null 2>&1; then
    runner_sh="busybox sh"
    runner_note="busybox sh, which is what the restic image runs"
fi
echo "  note: the runner is driven under $runner_note" >&2

# The structural half of the same question, which does not depend on which shell
# is here: the runner is POSIX sh and the constructs below would all work under
# bash and none of them under ash.
body=$(grep -v '^ *#' "$runner")
for bashism in '[[ ' 'local ' 'declare ' 'readarray' '<<<' 'BASH_REMATCH'; do
    assert '! grep -qF -- "$bashism" <<<"$body"' \
        "the runner uses no '$bashism' — it runs under busybox ash, which has no such thing"
done
assert '! grep -qE "\\$\\{[A-Za-z_][A-Za-z0-9_]*//" <<<"$body"' \
    "and no \${x//y/z}, which ash does not have either"

# The reserved list the runner carries is the one in lib/manifest.sh. A payload
# inside a container can source nothing, so the list is copied — and a copy with
# nothing pinning it to the original is drift no suite can see
# (tests/norm_path_test.sh's answer to the same problem).
runner_reserved=$(sed -n 's/^RESERVED="\(.*\)"$/\1/p' "$runner")
lib_reserved=$(bash -c '. "$KASBAH_LIB_DIR/common.sh"; . "$KASBAH_LIB_DIR/manifest.sh"; printf "%s" "${KASBAH_RESERVED_NAMES[*]}"')
assert '[ "$runner_reserved" = "$lib_reserved" ]' \
    "the runner's reserved list is KASBAH_RESERVED_NAMES (runner '$runner_reserved', lib '$lib_reserved')"

tree="$tmpdir/tree"
mkdir -p "$tree/apps/.kasbah/backup/repos" \
         "$tree/apps/alpha/backups" "$tree/apps/beta" "$tree/apps/gamma" \
         "$tree/apps/traefik" "$tree/apps/mail" "$tree/apps/backups" \
         "$tree/data/alpha" "$tree/data/mail"
printf 'A=1\n' > "$tree/apps/alpha/.env"
printf 'B=1\n' > "$tree/apps/beta/.env"
printf 'G=1\n' > "$tree/apps/gamma/.env"
printf 'M=1\n' > "$tree/apps/mail/.env"
printf 'acme\n' > "$tree/apps/alpha/.kasbah-client"
printf 'acme\r\n' > "$tree/apps/beta/.kasbah-client"
printf 'not a repo name\n' > "$tree/apps/gamma/.kasbah-client"
: > "$tree/apps/.kasbah/backup/repos/acme.pass"

run_runner() {
    env KASBAH_BACKUP_APPS="$tree/apps" KASBAH_BACKUP_DATA="$tree/data" \
        KASBAH_BACKUP_AT="${AT:-02:00}" KASBAH_BACKUP_JITTER="${JIT:-0}" \
        $runner_sh "$runner" "$@" 2>"$tmpdir/err"
}
# The same, with the report and the warnings together: what an operator reads in
# `docker logs kasbah-backup` is both streams interleaved, and the lines that
# matter most — a repository with no password, a project that fell back — are on
# stderr.
run_runner_all() {
    env KASBAH_BACKUP_APPS="$tree/apps" KASBAH_BACKUP_DATA="$tree/data" \
        KASBAH_BACKUP_AT="${AT:-02:00}" KASBAH_BACKUP_JITTER="${JIT:-0}" \
        $runner_sh "$runner" "$@" 2>&1
}

out=$(run_runner plan); rc=$?
assert '[ "$rc" = "0" ]' "the runner plans a tree (exit $rc: $(drive_err))"
assert 'grep -qxF "project alpha acme record" <<<"$out"' \
    "a project with a client record files under it (got '$out')"
assert 'grep -qxF "project beta acme record" <<<"$out"' \
    "a CRLF-authored record is read the same way — the file is one a human may edit"
assert 'grep -qxF "project gamma gamma invalid" <<<"$out"' \
    "a record that is not a repository name falls back to the project's own name"
assert 'grep -qF "not a repository name" "$tmpdir/err"' "and says so out loud (said '$(drive_err)')"

assert 'grep -qxF "repo acme yes" <<<"$out"' "the shared repository knows it has a password"
assert 'grep -qxF "repo gamma no" <<<"$out"' "and one without knows it has none"
assert 'grep -qxF "repo mail no" <<<"$out"'  "mail is a repository of its own (D7)"

# docs/backup.md → Scope, for one project: the data bind mount, the dumps, and
# the .env — and only the ones that are there.
repo_block() {
    awk -v want="$1" '$1 == "repo" { inb = ($2 == want); next } inb && $1 == "path" { print }' <<<"$2"
}
paths=$(repo_block acme "$out")
assert 'grep -qxF "path $tree/data/alpha" <<<"$paths"'        "the data bind mount is in scope"
assert 'grep -qxF "path $tree/apps/alpha/backups" <<<"$paths"' "the hook-produced dumps are"
assert 'grep -qxF "path $tree/apps/alpha/.env" <<<"$paths"'    "and the .env, the only copy of the project's secrets"
assert 'grep -qxF "path $tree/apps/beta/.env" <<<"$paths"' \
    "and a second project with the same client lands in the same repository"
assert '! grep -qF "$tree/data/beta" <<<"$paths"' \
    "while a data directory that is not there is not listed (got '$paths')"

mailpaths=$(repo_block mail "$out")
assert 'grep -qxF "path $tree/data/mail" <<<"$mailpaths"'   "mail's data is in its own repository"
assert 'grep -qxF "path $tree/apps/mail/.env" <<<"$mailpaths"' "with its .env"
assert '! grep -qF "$tree/apps/alpha" <<<"$mailpaths"' \
    "and no project's files (got '$mailpaths')"

# The four kasbah owns are never projects.
for owned in traefik mail data backups; do
    assert '! grep -qxF "project $owned $owned fallback" <<<"$out"' \
        "$owned is kasbah's, not a project (got '$out')"
done

# The fallback, on its own: a project deployed before backups existed has no
# record at all, and that is the case D12 exists to make visible.
rm -f "$tree/apps/alpha/.kasbah-client"
out=$(run_runner plan)
assert 'grep -qxF "project alpha alpha fallback" <<<"$out"' \
    "a project with no record at all falls back to its own name (got '$out')"
printf 'acme\n' > "$tree/apps/alpha/.kasbah-client"

# A run with no credentials says which repositories were not backed up, rather
# than exiting quietly.
out=$(run_runner_all once); rc=$?
assert '[ "$rc" != "0" ]' "a run with no env file fails (exit $rc)"
assert 'grep -qF "nothing says where the repository is" <<<"$out"' "and says why (got '$out')"

printf 'KASBAH_BACKUP_REPO_BASE=/nowhere/\n' > "$tree/apps/.kasbah/backup/env"
out=$(run_runner_all once); rc=$?
assert 'grep -qF "no password" <<<"$out"' \
    "a repository with no password is named rather than skipped in silence (got '$out')"
assert 'grep -qF "filed under their own name" <<<"$out"' \
    "and so is every project that fell back (got '$out')"

# --- The schedule ---------------------------------------------------------------------
# 1700000000 is 2023-11-14 22:13:20 UTC. TZ is pinned so the answer does not
# depend on where the suite runs; the container mounts /etc/localtime for the
# same reason the slot is a local time at all.
out=$(TZ=UTC AT=02:00 JIT=0 run_runner next 1700000000)
assert 'grep -qF "next run in 13600s" <<<"$out"' \
    "the wait to 02:00 is computed from the time of day (got '$out')"
out=$(TZ=UTC AT=02:00 JIT=137 run_runner next 1700000000)
assert 'grep -qF "next run in 13737s" <<<"$out"' "and the jitter is added to the slot (got '$out')"
out=$(TZ=UTC AT=23:00 JIT=0 run_runner next 1700000000)
assert 'grep -qF "next run in 2800s" <<<"$out"' "a slot later today is later today (got '$out')"
out=$(TZ=UTC AT=22:13 JIT=0 run_runner next 1700000000)
assert 'grep -qF "next run in 86380s" <<<"$out"' \
    "and a slot that has just gone is tomorrow, never zero (got '$out')"
out=$(TZ=UTC AT=02:00 JIT=0 run_runner next)
assert '[[ "$out" =~ ^next\ run\ in\ [0-9]+s ]]' "with no argument it uses the clock (got '$out')"

out=$(run_runner_all nonsense); rc=$?
assert '[ "$rc" != "0" ]' "an unknown mode fails (exit $rc)"
assert 'grep -qF "schedule, once, plan, next, health" <<<"$out"' "naming the ones there are (got '$out')"

# --- The bound, and the state that makes a wedge visible ---------------------------
# A scheduler wedged inside restic never returns to `sleep`: the container stays
# "running", backs nothing up, and `restart: unless-stopped` has nothing to act
# on. Two things answer that — a bound on every restic call, and a healthcheck
# that can tell a wedged run from a sleeping one.
body=$(grep -v '^ *#' "$runner")
# Single-quoted on purpose: what is being looked for is the literal text of the
# runner, and expanding $timeout_s here would ask this suite for a variable that
# is the runner's.
runner_bound='timeout -k 10 "$timeout_s" restic'
assert 'grep -qF -- "$runner_bound" <<<"$body"' \
    "every restic call in the runner is bounded (restic_repo: $(grep -A6 "^restic_repo" "$runner" | tail -1))"
# One caller, and it goes through the bound: a second spelling of `restic …`
# anywhere in the script would be a path out of it.
bare_restic=$(grep -cE '^[[:space:]]*restic ' <<<"$body")
assert '[ "$bare_restic" = "0" ]' \
    "and no line runs restic without one (found $bare_restic:
        $(grep -nE '^[[:space:]]*restic ' <<<"$body"))"

run_state_dir="$tree/apps/.kasbah/backup/state"
mkdir -p "$run_state_dir"
# No status file at all: a container that has not reported in is not healthy,
# whatever else is true of it.
rm -f "$run_state_dir/status"
out=$(run_runner_all health); rc=$?
assert '[ "$rc" != "0" ]' "a scheduler that has written no status is unhealthy (exit $rc: $out)"
assert 'grep -qF "has not reported in" <<<"$out"' "and says why (got '$out')"

printf 'state=sleeping\ndeadline=%s\n' "$(( $(date +%s) + 600 ))" > "$run_state_dir/status"
out=$(run_runner_all health); rc=$?
assert '[ "$rc" = "0" ]' "a sleeper inside its deadline is healthy (exit $rc: $out)"
assert 'grep -qF "sleeping" <<<"$out"' "and says what it is doing (got '$out')"

printf 'state=running\ndeadline=%s\n' "$(( $(date +%s) - 60 ))" > "$run_state_dir/status"
out=$(run_runner_all health); rc=$?
assert '[ "$rc" != "0" ]' "a run that outlived its own deadline is unhealthy (exit $rc: $out)"
assert 'grep -qF "outlived its deadline" <<<"$out"' "which is exactly the wedge (got '$out')"

printf 'state=sleeping\ndeadline=%s\n' "$(( $(date +%s) - 60 ))" > "$run_state_dir/status"
out=$(run_runner_all health); rc=$?
assert '[ "$rc" != "0" ]' "and so is a sleep that never woke (exit $rc: $out)"

printf 'state=running\ndeadline=nonsense\n' > "$run_state_dir/status"
out=$(run_runner_all health); rc=$?
assert '[ "$rc" != "0" ]' "a status file with no usable deadline is unhealthy, not healthy (exit $rc: $out)"

# The shapes a digits-only gate admits and arithmetic does not. The first is the
# dangerous one: `01700000000` is a *valid* octal, so nothing errors — the number
# silently changes. The rest make `[ -gt ]` say `Illegal number`, and a false
# comparison here reads as **inside** the deadline, which is how one record came
# out `unhealthy` from docker, `unknown` from `server status` and `warn` from
# `check --server` all at once.
for bad in 01700000000 01999000009 1000000000000000000 999999999999999999999999; do
    printf 'state=running\ndeadline=%s\n' "$bad" > "$run_state_dir/status"
    out=$(run_runner_all health); rc=$?
    assert '[ "$rc" != "0" ]' \
        "deadline=$bad is not a unix time the healthcheck can compare (exit $rc: $out)"
    assert 'grep -qF "not a unix time" <<<"$out"' \
        "and it says so rather than judging it (got '$out')"
done
# The paired positive, so the four above are the gate and not a healthcheck that
# fails on everything: eighteen digits is the cap, and the value at the cap that
# is already past is judged rather than refused.
printf 'state=running\ndeadline=999999999999999999\n' > "$run_state_dir/status"
out=$(run_runner_all health); rc=$?
assert '[ "$rc" = "0" ]' "an 18-digit deadline is compared, not refused (exit $rc: $out)"

# One rule, two implementations. lib/backup_record.sh's `_bkr_epoch` is bash on a
# workstation; the runner's `is_epoch` is POSIX sh inside a container that can
# source nothing, so the code cannot be shared and the *answers* are pinned
# instead. This is the drift that shipped: the runner went on admitting any digit
# string long after the reader stopped.
epoch_fn="$tmpdir/is_epoch.sh"
{
    sed -n '/^is_epoch() {$/,/^}$/p' "$runner"
    printf 'if is_epoch "$1"; then echo yes; else echo no; fi\n'
} > "$epoch_fn"
assert '[ "$(grep -c "" "$epoch_fn")" -gt 4 ]' \
    "is_epoch was extracted from the runner (got $(grep -c "" "$epoch_fn") lines)"
for v in 0 1 1787000000 999999999999999999 01700000000 01999000009 \
         1000000000000000000 999999999999999999999999 "" abc 12a -1 "+1" " 1" "1 " 007; do
    runner_says=$($runner_sh "$epoch_fn" "$v")
    lib_says=$(bash -c '. "$KASBAH_LIB_DIR/common.sh"; . "$KASBAH_LIB_DIR/backup_record.sh"
        if _bkr_epoch "$1" v; then echo yes; else echo no; fi' _ "$v")
    assert '[ "$runner_says" = "$lib_says" ]' \
        "is_epoch and _bkr_epoch agree on '$v' (runner said '$runner_says', lib said '$lib_says')"
done

# A real run leaves the record behind: what ran, when it finished, and how it
# went. Nothing but `docker logs` knew before, and a log is not a thing another
# command can read.
rm -f "$run_state_dir/status"
printf 'KASBAH_BACKUP_REPO_BASE=/nowhere/\n' > "$tree/apps/.kasbah/backup/env"
run_runner_all once >/dev/null 2>&1
assert '[ -f "$run_state_dir/status" ]' "a run writes the status file"
assert 'grep -qxF "state=sleeping" "$run_state_dir/status"' \
    "and leaves it saying the scheduler is waiting for the next slot — a run driven by
        \`docker exec … once\` has to leave the same record the loop would
        (got '$(tr "\n" " " < "$run_state_dir/status")')"
assert 'grep -qE "^deadline=[0-9]+$" "$run_state_dir/status"' "with a deadline the healthcheck can read"
assert 'grep -qE "^next_run=[0-9]{9,}$" "$run_state_dir/status"' "and when the next run is due"
assert 'grep -qE "^last_run_started=[0-9]{9,}$" "$run_state_dir/status"' "and when this one started"
assert 'grep -qE "^last_run_finished=[0-9]{9,}$" "$run_state_dir/status"' "and when it ended"
assert 'grep -qxF "last_run_status=failed" "$run_state_dir/status"' \
    "and how it went — this one had no credentials, and something other than
        \`docker logs\` has to be able to know that"
assert 'grep -qxF "timeout=900" "$run_state_dir/status"' "and the bound it was running under"
# The healthcheck accepts what the run left behind: a record a run writes and a
# healthcheck then rejects is a stack that goes unhealthy every night.
out=$(run_runner_all health); rc=$?
assert '[ "$rc" = "0" ]' "and the healthcheck accepts it (exit $rc: $out)"

# The wedge itself, without waiting for one: a bound of the minimum against a
# restic that never returns. The run has to come back, and say which repository
# it gave up on.
# `exec`, not a plain `sleep`: timeout(1) signals the process it started, and a
# shell that forked a child would be killed while the child kept the capture's
# pipe open — the command substitution would then wait on the orphan and this
# case would hang instead of measuring anything. restic is a single process, so
# `exec` is also the shape being stood in for.
cat > "$tmpdir/stub-restic" <<'STUB'
#!/bin/sh
exec sleep 300
STUB
# Three seconds, not the flag's 30-second floor: the runner reads the bound out
# of its environment and applies it, and what is under test is that it applies
# one at all. `--backup-timeout=` is what refuses a value this small, and that
# refusal has its own case above.
chmod 0755 "$tmpdir/stub-restic"
mkdir -p "$tmpdir/sbin"; cp "$tmpdir/stub-restic" "$tmpdir/sbin/restic"
# Bounded from the outside as well, at twenty times the bound under test: a
# runner that had lost its own would otherwise hang this suite rather than fail
# it, and a suite that hangs reports nothing at all.
#
# Written to a file rather than captured in `$( )`. timeout(1) signals the
# process it started, and the stub's descendants keep a *pipe* open after it —
# so a command substitution waits on them and the outer bound is as ineffective
# as the inner one it stands in for. A file has nobody to wait for. Measured:
# under `$( )` this case ran 600 s against an unbounded runner before the
# harness cut it off.
started=$(date +%s)
timeout 60 env KASBAH_BACKUP_APPS="$tree/apps" KASBAH_BACKUP_DATA="$tree/data" \
    KASBAH_BACKUP_TIMEOUT=3 PATH="$tmpdir/sbin:$PATH" \
    $runner_sh "$runner" once >"$tmpdir/wedge.out" 2>&1; rc=$?
out=$(cat "$tmpdir/wedge.out")
elapsed=$(( $(date +%s) - started ))
assert '[ "$rc" != "0" ]' "a restic that never returns makes the run fail (exit $rc)"
assert '[ "$elapsed" -lt 30 ]' \
    "and the run comes back inside its bound rather than wedging (took ${elapsed}s)
        output: $out"
assert 'grep -qF "could not initialise the repository" <<<"$out"' \
    "naming the repository it gave up on (got '$out')"

exit "$fail"
