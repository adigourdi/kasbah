# kasbah — server status command
# Sourced by bin/kasbah. Do not execute directly.

[ -n "${_KASBAH_SERVER_STATUS_LOADED:-}" ] && return 0
_KASBAH_SERVER_STATUS_LOADED=1

. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/ssh.sh"
# For KASBAH_RESERVED_NAMES alone — a server command has no manifest to read.
# The list is what a project may not be called *because* those directories are
# kasbah's own under <apps>/, which is the same question status asks when it
# decides what is a project, so the two must not drift apart.
. "$KASBAH_LIB_DIR/manifest.sh"
# For vlog_parse_line: the last line of a project's versions.log is the same
# frozen format the history commands read, and one format has one parser.
. "$KASBAH_LIB_DIR/versions_log.sh"
# For acme_lookup: Traefik's certificate store has one reader (lib/acme.sh),
# written for `check --server` and consumed here — two commands answering
# "when does this expire" out of two parsers is how the two answers drift.
. "$KASBAH_LIB_DIR/acme.sh"

# `kasbah server status USER@HOST` reports what a prepared VPS is running: the
# docker and compose versions, the shared Traefik stack, and every project under
# the apps path with the last line of its versions.log.
#
# Read-only. The remote script asks docker four questions — `version`,
# `compose version`, `ps`, `inspect`, all of them reads — opens files for
# reading, and pipes what it read through `tr` and `openssl base64`. There is no
# mkdir, no touch, and no redirection onto the server's filesystem. The
# integration suite digests the whole apps tree, mtimes included, across a
# status run rather than taking this paragraph's word for it.
#
# One round trip. Every fact comes back from a single ssh session as key=value
# lines, and the key set is checked as a protocol before any line of output
# reads a value: a fact that never arrived must not be printed as a verdict
# (docs/phases/01-rig.md, from 1.3). The remote side never assumes jq or yq —
# the prerequisites table promises rsync, openssl, gzip and bash — so the marker
# travels back as bytes and is parsed here.
#
# **Still one round trip**, with five more things to report than the minimal
# status had: the per-project domain, certificate expiry, disk, the mail stack
# and per-container health are all folded into the same single probe. Each of
# them read on its own is what turns this command into several ssh sessions,
# which is what makes a rig's `maxstartups 10` refuse one of them.
#
# Nothing is parsed on the far side that can be parsed here. The fragments and
# the mail registry come back as bytes and meet the workstation's yq; acme.json
# comes back as bytes and meets lib/acme.sh, the same reader `check --server`
# uses. The one exception is the data path, which the reads for the certificate
# store and the data disk hang off: it is scraped out of the marker without a
# JSON parser and then checked against jq's answer here, because the alternative
# is a second round trip to learn it.

_SS_TARGET=""
_SS_APPS_PATH=""
# What --apps-path was given as (empty when it was not), and how the path above
# was arrived at: `flag`, `pointer` or `default`.
_SS_APPS_FLAG=""
_SS_APPS_SOURCE=""

# What the one remote step brought back, and what was read out of the marker.
declare -A _SS_FACT=()
_SS_MARKER=""
_SS_MARKER_APPS=""
_SS_MARKER_DATA=""
_SS_MARKER_VERSION=""
_SS_MARKER_CPU=""
_SS_MARKER_MEM=""

# The project table, decoded from the remote payload into parallel arrays.
_SS_P_NAME=()
_SS_P_TOTAL=()
_SS_P_RUNNING=()
_SS_P_LOGSTATE=()
_SS_P_LOG=()
# Per project: the state of its Traefik fragment, the fragment itself, and one
# line of `<name-b64> <state> <health>` per container the project owns.
_SS_P_FRAGSTATE=()
_SS_P_FRAG=()
_SS_P_CONT=()

# The files the probe brought back whole. `_SS_ACME` is Traefik's certificate
# store: it holds `.letsencrypt.Account.PrivateKey` and every certificate's
# `.key`, so nothing writes it to disk, echoes it, or puts it in a message —
# see _ss_absorb_checked, which is where a diagnostic would otherwise spill it.
_SS_ACME=""
_SS_SHARED=""
_SS_REGISTRY=""
_SS_DASH_HOST=""
_SS_MAIL_PRIMARY=""
_SS_MAIL_DOMAINS=()
# Whether the path the probe used for the two data-side reads is the one the
# marker records. The probe scrapes it out of the marker's bytes without a JSON
# parser (there is none on the far side); this is the parser's answer against
# the scrape, and a disagreement makes both reads unreportable rather than
# wrong.
_SS_DATA_TRUSTED=no

# Keys whose *values* must never reach a diagnostic. The probe's report is
# echoed back when it looks truncated, and two of the files in it carry
# credentials: acme.json holds the ACME account key and every certificate's
# private key, and `_shared.yml` holds the dashboard's **bcrypt hash**. The
# hash is short enough today that the 120-byte clip would not reach past the
# fragment's first line — but nothing pins that, the file gains a line whenever
# a middleware is added, and an offline-crackable credential on stderr is not
# worth the one array element it costs to keep off.
_SS_SECRET_KEYS=(acme_b64 shared_b64)

# The fixed names kasbah owns under the apps path (docs/server-setup.md → What
# init creates). The bind-mount root is not always among them — `--data-path`
# can put it inside the apps path under any name — so that one is dropped later,
# from the marker, in _ss_decode_projects.
#
# Everything else is reported as a project, including a name no deploy of this
# kasbah could have made: a name rule cannot tell a stray directory from one a
# different kasbah deployed, and a status that hides what it does not recognise
# is worse than one that shows it.
_SS_RESERVED=(.kasbah "${KASBAH_RESERVED_NAMES[@]}")

_server_status_usage() {
    cat <<EOF
Usage: kasbah server status USER@HOST [--apps-path=<dir>]

Prints what a prepared server is running: docker and compose versions, the
shared Traefik stack, and every project under the apps path with its last
versions.log entry. Read-only — it changes nothing on the server.

Flags:
  --apps-path=<dir>   where the server was prepared. Without it, status reads
                      $KASBAH_APPS_POINTER — the server's own record — and
                      falls back to $KASBAH_DEFAULT_APPS_PATH when there is none. The flag is
                      the escape hatch for a server whose pointer is gone.

It also prints the filesystem behind the apps and data paths, the mail stack,
each project's domain out of its Traefik fragment, and what Traefik's ACME
store says about every hostname on the server.
EOF
}

# --- Command line ---------------------------------------------------------------

# Absolute and normalised, because everything read on the far side hangs off it
# and a surprise here becomes a surprise in a path that does not exist. The
# stricter bans `server init` puts on the same flag — `$` and `:` — are about
# the value being written into a compose bind mount, which status never does.
_ss_apps_path() {
    local _ap_value="${1%$'\r'}"

    [ -n "$_ap_value" ] || die "server status: --apps-path= must not be empty"
    case $_ap_value in
        /*) ;;
        *)  die "server status: --apps-path=$_ap_value must be an absolute path" ;;
    esac
    case $_ap_value in
        *$'\n'*) die "server status: --apps-path= must not contain a newline" ;;
    esac
    case $_ap_value in
        *//*|*/./*|*/../*|*/..|*/.)
            die "server status: --apps-path=$_ap_value must be a normalised path (no '.', '..' or empty segment)" ;;
    esac

    while [ "${_ap_value: -1}" = / ]; do _ap_value="${_ap_value%/}"; done
    [ -n "$_ap_value" ] \
        || die "server status: --apps-path=/ must not be the filesystem root"

    printf -v _SS_APPS_FLAG '%s' "$_ap_value"
}

_server_status_parse_args() {
    local apps="" apps_given=0

    _SS_TARGET=""
    _SS_APPS_PATH=""
    _SS_APPS_FLAG=""
    _SS_APPS_SOURCE=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --apps-path=*) apps="${1#*=}"; apps_given=1 ;;
            -h|--help)     _server_status_usage; exit 0 ;;
            -*)            die "server status: unknown flag '${1%%=*}' (expected --apps-path=)" ;;
            *)
                [ -z "$_SS_TARGET" ] \
                    || die "server status: unexpected argument '$1' (USER@HOST is given once)"
                _SS_TARGET="${1%$'\r'}"
                ;;
        esac
        shift
    done

    [ -n "$_SS_TARGET" ] \
        || die "server status: USER@HOST is required (the user kasbah deploys as is not optional)"

    # An empty --apps-path= is a stated intent that cannot be honoured, so it
    # fails rather than falling back to the path the operator just overrode.
    # Without the flag the path is left for the probe to discover, which is
    # where the pointer is read.
    [ "$apps_given" = 1 ] || return 0
    _ss_apps_path "$apps"
    return 0
}

# --- The one remote step ----------------------------------------------------------

# Folds the report into the fact table and checks the key set before any of it
# is read: a truncated step must not be absorbed into a passing verdict.
#
# The raw output is echoed back on failure, clipped to twenty lines of 120
# bytes: several of these values are base64 blobs that grow with the server, and
# a diagnostic that scrolls a megabyte of them past the reader diagnoses nothing.
#
# **One of those blobs is acme.json**, which holds Traefik's ACME account key
# and every certificate's private key, so the clip alone is not enough: 120
# bytes of a private key on stderr is 120 bytes of a private key on stderr. The
# redaction lives *in this helper* rather than in a second copy of it beside —
# `check --server` wrote its own absorb because it is in another file, but
# `status` has exactly one, and two copies of a thirty-line function in one file
# are two things to keep in step. A line whose key is secret is reported by name
# and length only; the key is what a reader needs to tell a truncated step from
# a rejected one, and the value never was.
#
# Redaction is by key *prefix*, which is what a truncated read leaves: the far
# side emits `acme_b64=<one line, no newlines in base64>` and truncation removes
# the tail, so a partial secret line still begins with its key. A line with no
# `=` at all is the remote shell's own complaint and is shown — that is the
# whole diagnostic value of this path.
_ss_absorb_checked() {
    local _ac_out="$1"; shift
    local _ac_line _ac_key _ac_shown=0 _ac_secret=0 _ac_s
    local _ac_missing=()

    while IFS= read -r _ac_line; do
        _ac_line="${_ac_line%$'\r'}"
        case $_ac_line in *=*) _SS_FACT[${_ac_line%%=*}]="${_ac_line#*=}" ;; esac
    done <<<"$_ac_out"

    for _ac_key in "$@"; do
        [ -n "${_SS_FACT[$_ac_key]+set}" ] || _ac_missing+=("$_ac_key")
    done
    if [ "${#_ac_missing[@]}" -gt 0 ]; then
        err "the status probe on $_SS_TARGET reported no ${_ac_missing[*]}"
        err_cont "the step was truncated, or the remote shell rejected it — raw output:"
        while IFS= read -r _ac_line; do
            _ac_shown=$((_ac_shown + 1))
            if [ "$_ac_shown" -gt 20 ]; then
                err_cont "| … and more, not shown"
                break
            fi
            _ac_key=""
            _ac_secret=0
            case $_ac_line in *=*) _ac_key="${_ac_line%%=*}" ;; esac
            # Compared literally, never as a case pattern: the keys in this
            # line came off the wire, and a `*` among them would be a glob.
            for _ac_s in "${_SS_SECRET_KEYS[@]}"; do
                [ "$_ac_key" = "$_ac_s" ] || continue
                _ac_secret=1
                break
            done
            if [ "$_ac_secret" = 1 ]; then
                err_cont "| $_ac_key= ($(( ${#_ac_line} - ${#_ac_key} - 1 )) bytes, not shown: it holds private key material)"
            else
                [ "${#_ac_line}" -le 120 ] \
                    || _ac_line="${_ac_line:0:120}… (${#_ac_line} bytes in all)"
                err_cont "| $_ac_line"
            fi
        done <<<"$_ac_out"
        exit 1
    fi
    return 0
}

# base64 -d into <outvar>, without letting a bad payload end the run silently.
# A plain `x="$(… | base64 -d)"` is fatal under errexit, so the process dies
# before the caller's message about a corrupt payload can run — a status that
# exits 1 having printed nothing at all, which is worse than a wrong line.
# Written as a `||` list, which errexit exempts, so the caller decides what a
# failure means.
#
# The command substitution drops trailing newlines. The row table ends with one
# and does not need it — it is read line by line — while a project name and a
# versions.log line carry none, and jq does not care how the marker ends.
_ss_b64_decode() {
    local _bd_out="$2" _bd_val=""
    _bd_val="$(printf '%s' "$1" | base64 -d 2>/dev/null)" || return 1
    printf -v "$_bd_out" '%s' "$_bd_val"
    return 0
}

# The same, for a positional field of the project table, where `-` means "this
# value is empty". The row is split on whitespace and a run of it collapses, so
# an empty field in the middle would shift every field after it left by one —
# the far side sends `-`, which is not in the base64 alphabet, and this is where
# it comes back off.
_ss_b64_field() {
    local _bf_out="$2"
    if [ "$1" = - ]; then
        printf -v "$_bf_out" '%s' ""
        return 0
    fi
    _ss_b64_decode "$1" "$_bf_out" || return 1
    return 0
}

_server_status_collect() {
    local out rc=0

    out=$(ssh_script "$_SS_APPS_FLAG" "$KASBAH_DEFAULT_APPS_PATH" \
                     "$KASBAH_APPS_POINTER" "${_SS_RESERVED[*]}" <<'REMOTE'
set -uo pipefail
export LC_ALL=C
apps=$1
default=$2
pointer=$3
reserved=" $4 "

# One line per value: the reader parses this output as a protocol, so a
# command's multi-line complaint would arrive as extra keys. Anything that can
# carry a newline or a space of its own — the marker, a project name, a
# versions.log line — is base64'd instead.
kv() {
    local v="$2"
    while [ "${v: -1}" = " " ]; do v="${v% }"; done
    printf '%s=%s\n' "$1" "$v"
}
flat() { tr -d '\r' | tr '\n' ' '; }
# openssl rather than coreutils' `base64 -w0`: openssl is on the prerequisites
# table and base64 is not.
b64() { openssl base64 -A 2>/dev/null; }

# Non-empty lines in a string, counted without a subprocess.
count_lines() {
    local n=0 l
    if [ -n "$1" ]; then
        while IFS= read -r l; do
            [ -n "$l" ] || continue
            n=$((n + 1))
        done <<<"$1"
    fi
    printf '%s' "$n"
}

# Where to look, decided here so that one round trip covers both the pointer
# and everything read out of the tree it names. The flag wins when it was given;
# otherwise the server's own record does; otherwise the default. A pointer that
# is present and does not name an absolute path is reported as it stands and
# refused on the caller's side — the reads below then describe the default tree,
# which nothing prints.
# The pointer's own spelling, reduced to the form every kasbah path flag is
# normalised into: CR and trailing blanks off, empty and `.` segments dropped,
# no trailing slash. `/apps/`, `//apps` and `/apps/.` all name `/apps`, and only
# the normalised form compares equal to what init recorded.
norm_path() {
    local p="$1" out="" seg IFS=/
    set -f
    p=${p%$'\r'}
    while [ -n "$p" ]; do
        case ${p: -1} in
            ' '|$'\t') p=${p%?} ;;
            *) break ;;
        esac
    done
    case $p in
        /*) ;;
        *) printf '%s' "$p"; return 0 ;;
    esac
    for seg in $p; do
        [ -n "$seg" ] && [ "$seg" != . ] || continue
        out="$out/$seg"
    done
    [ -n "$out" ] || out=/
    printf '%s' "$out"
}

pointer_dir=${pointer%/*}
pointer_state=absent
pointer_value=""
if [ -e "$pointer" ] && [ ! -f "$pointer" ]; then
    pointer_state=notfile
elif [ -f "$pointer" ] && [ ! -r "$pointer" ]; then
    # World-readable is the contract; status never elevates, so a pointer it
    # cannot read is reported as that rather than as an empty one.
    pointer_state=unreadable
elif [ -f "$pointer" ]; then
    pointer_state=present
    IFS= read -r pointer_value < "$pointer" || pointer_value=""
    pointer_value=$(norm_path "$pointer_value")
elif [ -d "$pointer_dir" ] && [ ! -x "$pointer_dir" ]; then
    # `[ -e ]` answers "no" for a file behind a directory this user cannot
    # traverse, exactly as it does for one that is not there. Reading the
    # default tree on that answer would report a different server as this one.
    pointer_state=unreachable
fi
if [ -n "$apps" ]; then
    apps_source=flag
else
    case $pointer_value in
        /?*) apps=$pointer_value; apps_source=pointer ;;
        *)   apps=$default;       apps_source=default ;;
    esac
fi
kv pointer_state "$pointer_state"
kv pointer_value "$pointer_value"
kv apps_path "$apps"
kv apps_source "$apps_source"

if command -v docker >/dev/null 2>&1; then kv have_docker yes; else kv have_docker no; fi
docker_out=$(docker version --format '{{.Server.Version}}' 2>&1); docker_rc=$?
if [ "$docker_rc" -eq 0 ]; then
    kv docker_server "$(printf '%s' "$docker_out" | flat)"
    kv docker_error ""
else
    kv docker_server ""
    kv docker_error "$(printf '%s' "$docker_out" | flat)"
fi
kv compose_version "$(docker compose version --short 2>/dev/null | flat)"

apps_state=absent
if [ -d "$apps" ]; then apps_state=dir
elif [ -e "$apps" ]; then apps_state=notdir
fi
kv apps_state "$apps_state"

# The marker's bytes, not its meaning: no jq on the far side, so the caller
# parses it. A zero-byte file is reported as such rather than as an absent one —
# absence is an unprepared server, emptiness is a broken marker.
marker="$apps/.kasbah/server.json"
marker_state=absent
marker_b64=""
if [ -e "$marker" ] && [ ! -f "$marker" ]; then
    marker_state=notfile
elif [ -f "$marker" ]; then
    if [ ! -s "$marker" ]; then
        marker_state=empty
    else
        marker_b64=$(openssl base64 -A -in "$marker" 2>/dev/null) || marker_b64=""
        if [ -n "$marker_b64" ]; then marker_state=ok; else marker_state=unreadable; fi
    fi
fi
kv marker_state "$marker_state"
kv marker_b64 "$marker_b64"

# The data path, needed on *this* side for the two reads that hang off it — the
# certificate store and the disk figure — and there is no jq here to get it out
# of the marker properly. So it is scraped, reported as `probe_data_path`, and
# the caller compares it with what jq read out of the same bytes: a scrape that
# disagrees with the parser is refused there rather than quietly describing some
# other tree. Two round trips would be the alternative, and the single trip is
# what keeps a rig's `maxstartups` from biting.
data=""
if [ "$marker_state" = ok ]; then
    while IFS= read -r line; do
        line=${line%$'\r'}
        case $line in
            *'"data_path"'*)
                v=${line#*'"data_path"'}
                v=${v#*:}
                case $v in
                    *'"'*) v=${v#*'"'}; data=${v%%'"'*} ;;
                esac
                break
                ;;
        esac
    done < "$marker"
fi
kv probe_data_path "$data"

# Six states for a file, because they have six different remedies: acme.json is
# mode 600 and a store that is there and unreadable is something an operator
# acts on, while absent and empty are not the same news either.
fstate() {
    local p="$2" s=""
    if   [ -z "$p" ];    then s=nopath
    elif [ ! -e "$p" ];  then s=absent
    elif [ -d "$p" ];    then s=dir
    elif [ ! -f "$p" ];  then s=notfile
    elif [ ! -r "$p" ];  then s=unreadable
    elif [ ! -s "$p" ];  then s=empty
    else                      s=file
    fi
    kv "$1" "$s"
}
encfile() {
    local enc=""
    if [ -n "$2" ] && [ -f "$2" ] && [ -r "$2" ]; then
        enc=$(openssl base64 -A -in "$2" 2>/dev/null) || enc=""
    fi
    kv "$1" "$enc"
}

# `df -Pk`, not `du`: the question a status answers is whether the host is about
# to run out of room, and it must answer it in constant time. A `du` walk of a
# data path holding a mail spool would make the report's cost a function of how
# much mail the server has. The line travels base64'd — a filesystem or a mount
# point can carry a space — and is split on this side.
disk() {
    local st=nopath enc="" out="" l="" last=""
    if [ -n "$2" ]; then
        if [ ! -e "$2" ]; then
            st=absent
        else
            out=$(df -Pk "$2" 2>/dev/null) || out=""
            while IFS= read -r l; do
                [ -n "$l" ] || continue
                last=$l
            done <<<"$out"
            case $last in
                ''|Filesystem*) st=error ;;
                *) st=ok; enc=$(printf '%s' "$last" | b64) ;;
            esac
        fi
    fi
    kv "${1}_state" "$st"
    kv "${1}_b64" "$enc"
}
disk apps_df "$apps"
disk data_df "$data"

# The certificate store. It holds private key material — `.Account.PrivateKey`
# and every entry's `.key` — so the caller redacts it out of every diagnostic;
# nothing here writes it anywhere but this pipe.
acme=""
[ -z "$data" ] || acme="$data/traefik/letsencrypt/acme.json"
fstate acme_state  "$acme"
encfile acme_b64   "$acme"

# The dashboard fragment, for the hostname Traefik's own router claims — the
# apex is deliberately not in the marker, so this file is the only record of it.
fstate shared_state "$apps/traefik/dynamic/_shared.yml"
encfile shared_b64  "$apps/traefik/dynamic/_shared.yml"

# The mail stack. Absent is an ordinary state — a server prepared without
# --with-mail — and not a fault, so every key still arrives.
mail_dir=absent
if   [ -d "$apps/mail" ]; then mail_dir=dir
elif [ -e "$apps/mail" ]; then mail_dir=notdir
fi
kv mail_dir_state "$mail_dir"
fstate mail_registry_state "$apps/mail/kasbah.yml"
encfile mail_registry_b64  "$apps/mail/kasbah.yml"

# By compose labels, exactly as Traefik is found above: a container merely
# *named* mail-dms did not come from kasbah's stack. One inspect per container,
# three facts out of it — the restart count is here because a DMS that cannot
# find its certificate restarts forever, and the count is what says so.
mailc() {
    local ids="" id="" line="" st=absent hl="" rs=""
    if [ "$docker_rc" -ne 0 ]; then
        st=nodocker
    else
        ids=$(docker ps -a --filter label=com.docker.compose.project=mail \
                          --filter "label=com.docker.compose.service=$2" \
                          --format '{{.ID}}' 2>/dev/null) || ids=""
        id=${ids%%$'\n'*}
    fi
    if [ -n "$id" ]; then
        line=$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} {{.RestartCount}}' \
                   "$id" 2>/dev/null | flat) || line=""
        read -r st hl rs <<<"$line"
        [ -n "$st" ] || st=unknown
    fi
    kv "${1}_state" "$st"
    kv "${1}_health" "$hl"
    kv "${1}_restarts" "$rs"
}
mailc mail_dms   mail-dms
mailc mail_web   mail-snappymail

# Traefik by its compose labels, which is the frozen contract: the project name
# is `traefik` wherever the stack was rendered. A container merely *named*
# traefik did not come from kasbah's stack, and reporting it as the proxy would
# be worse than reporting none.
cid=""
if [ "$docker_rc" -eq 0 ]; then
    ids=$(docker ps -a --filter label=com.docker.compose.project=traefik \
                      --filter label=com.docker.compose.service=traefik \
                      --format '{{.ID}}' 2>/dev/null) || ids=""
    cid=${ids%%$'\n'*}
fi
if [ -n "$cid" ]; then
    name=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | flat)
    kv traefik_present yes
    kv traefik_state    "$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null | flat)"
    kv traefik_health   "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null | flat)"
    kv traefik_image    "$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null | flat)"
    kv traefik_image_id "$(docker inspect -f '{{.Image}}' "$cid" 2>/dev/null | flat)"
    kv traefik_container "${name#/}"
else
    kv traefik_present no
    kv traefik_state ""
    kv traefik_health ""
    kv traefik_image ""
    kv traefik_image_id ""
    kv traefik_container ""
fi

# One row per project: everything under the apps path that is not one of
# kasbah's own directories. dotglob is on because `.kasbah` is skipped by name
# rather than by being hidden, and a project that is not a directory at all is
# reported as that rather than skipped.
rows=""
count=0
if [ "$apps_state" = dir ]; then
    shopt -s nullglob dotglob
    for path in "$apps"/*; do
        name=${path##*/}
        case $reserved in *" $name "*) continue ;; esac
        count=$((count + 1))

        total=0
        running=0
        logstate=missing
        last=""
        fragstate=absent
        fragb64=""
        contb64=""

        # The project's Traefik fragment, whether or not the directory beside it
        # can be entered: the two are different files with different owners, and
        # a project whose directory a root deploy locked still routes.
        frag="$apps/traefik/dynamic/$name.yml"
        if [ -e "$frag" ] && [ ! -f "$frag" ]; then
            fragstate=notfile
        elif [ -f "$frag" ] && [ ! -r "$frag" ]; then
            fragstate=unreadable
        elif [ -f "$frag" ]; then
            fragb64=$(openssl base64 -A -in "$frag" 2>/dev/null) || fragb64=""
            if [ -n "$fragb64" ]; then fragstate=ok; else fragstate=empty; fi
        fi

        if [ ! -d "$path" ]; then
            logstate=notdir
        else
            if [ "$docker_rc" -eq 0 ]; then
                ids=$(docker ps -a --filter "label=com.docker.compose.project=$name" -q 2>/dev/null) || ids=""
                total=$(count_lines "$ids")
                # Every container of the project, in one inspect rather than one
                # per container: name, state and health, which is the health
                # Traefik's line has and nothing else did.
                if [ -n "$ids" ]; then
                    info=$(docker inspect -f '{{.Name}} {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
                               $ids 2>/dev/null) || info=""
                    while IFS=' ' read -r cname cstate chealth; do
                        [ -n "$cname" ] || continue
                        cname=${cname#/}
                        [ -n "$cstate" ] || cstate=unknown
                        [ -n "$chealth" ] || chealth=none
                        contb64="$contb64$(printf '%s %s %s' \
                            "$(printf '%s' "$cname" | b64)" "$cstate" "$chealth")
"
                    done <<<"$info"
                    contb64=$(printf '%s' "$contb64" | b64)
                fi
                ids=$(docker ps --filter "label=com.docker.compose.project=$name" -q 2>/dev/null) || ids=""
                running=$(count_lines "$ids")
            fi

            log="$path/versions.log"
            # Every "cannot" is its own state. A deploy that ran under sudo
            # leaves directories this user cannot enter (docs/server-setup.md
            # warns about exactly that ownership mix), and both of the cases
            # below otherwise read as "there is no log here" — which is the same
            # answer a project that has never been deployed gives.
            if [ ! -r "$path" ] || [ ! -x "$path" ]; then
                logstate=noaccess
            elif [ -e "$log" ] && [ ! -f "$log" ]; then
                logstate=notfile
            elif [ -f "$log" ] && [ ! -r "$log" ]; then
                logstate=unreadable
            elif [ -f "$log" ]; then
                # The last line that carries anything. `|| [ -n "$line" ]` keeps
                # a final line with no newline after it, and blank lines are
                # skipped so a log ending in one still reports its last entry.
                # A read that fails anyway — an I/O error, a race with a chmod —
                # reports unreadable rather than a short log, and its complaint
                # is dropped so it cannot arrive as extra protocol keys.
                if { while IFS= read -r line || [ -n "$line" ]; do
                         line=${line%$'\r'}
                         [ -n "${line//[[:space:]]/}" ] || continue
                         last=$line
                     done < "$log"; } 2>/dev/null; then
                    if [ -n "$last" ]; then logstate=ok; else logstate=empty; fi
                else
                    logstate=unreadable
                    last=""
                fi
            fi
        fi

        # Eight positional fields, and every base64 one is `-` when it holds
        # nothing. An empty field would not survive the trip: the reader splits
        # the row on whitespace, which collapses a run of it, so one empty value
        # in the middle would shift every field after it left by one. `-` is not
        # in the base64 alphabet, so it cannot be mistaken for a payload.
        lastb64=$(printf '%s' "$last" | b64)
        [ -n "$lastb64" ] || lastb64=-
        [ -n "$fragb64" ] || fragb64=-
        [ -n "$contb64" ] || contb64=-
        rows="$rows$(printf '%s %s %s %s %s %s %s %s' \
            "$(printf '%s' "$name" | b64)" "$total" "$running" "$logstate" \
            "$lastb64" "$fragstate" "$fragb64" "$contb64")
"
    done
fi
kv project_count "$count"
kv projects_b64 "$(printf '%s' "$rows" | b64)"

exit 0
REMOTE
    ) || rc=$?

    [ "$rc" -eq 0 ] \
        || die "could not read the state of $_SS_TARGET (the remote step exited $rc, see above)"
    [ -n "$out" ] \
        || die "the status probe on $_SS_TARGET succeeded and reported nothing (its output was lost, or the login shell swallowed it)"

    _SS_FACT=()
    _ss_absorb_checked "$out" \
        pointer_state pointer_value apps_path apps_source \
        have_docker docker_server docker_error compose_version \
        apps_state marker_state marker_b64 probe_data_path \
        apps_df_state apps_df_b64 data_df_state data_df_b64 \
        acme_state acme_b64 shared_state shared_b64 \
        mail_dir_state mail_registry_state mail_registry_b64 \
        mail_dms_state mail_dms_health mail_dms_restarts \
        mail_web_state mail_web_health mail_web_restarts \
        traefik_present traefik_state traefik_health traefik_image \
        traefik_image_id traefik_container \
        project_count projects_b64

    _ss_resolve_apps_path
    return 0
}

# The path everything below reads, taken from the probe rather than assumed: it
# is the flag when there was one, and the server's own record when there was
# not. A pointer that exists and names nothing usable is refused rather than
# silently replaced by the default — the operator asked about a server, and the
# only record of which tree that is has been damaged.
_ss_resolve_apps_path() {
    local apps="${_SS_FACT[apps_path]}" source="${_SS_FACT[apps_source]}"

    # Every refusal below is about a record status was going to *use*. Under
    # --apps-path it consults none of them, which is what the flag is for: it is
    # the way through a server whose pointer is damaged, and refusing there
    # would prescribe the flag the operator has already passed.
    if [ "$source" != flag ] && [ "${_SS_FACT[pointer_state]}" = notfile ]; then
        err "$KASBAH_APPS_POINTER on $_SS_TARGET exists and is not a regular file"
        err_cont "that path is the server's record of where it was prepared, and status reads"
        err_cont "it when no --apps-path is given. Look at it, or pass --apps-path=<dir>."
        exit 1
    fi
    if [ "$source" != flag ] && [ "${_SS_FACT[pointer_state]}" = unreachable ]; then
        err "${KASBAH_APPS_POINTER%/*} on $_SS_TARGET cannot be entered by the user status connected as"
        err_cont "so whether this server records an apps path cannot be told from here, and"
        err_cont "reading $KASBAH_DEFAULT_APPS_PATH on that answer could report a different server as this one."
        err_cont "Pass --apps-path=<dir>, or make it traversable — it is mode 755 on a server"
        err_cont "kasbah prepared."
        exit 1
    fi
    if [ "$source" != flag ] && [ "${_SS_FACT[pointer_state]}" = unreadable ]; then
        err "$KASBAH_APPS_POINTER on $_SS_TARGET cannot be read by the user status connected as"
        err_cont "it records where this server was prepared, and status never elevates to read"
        err_cont "it. Reading $KASBAH_DEFAULT_APPS_PATH instead could report a different server as this one."
        err_cont "Pass --apps-path=<dir>, or fix the mode: it is world-readable by contract"
        err_cont "and \`kasbah server init\` rewrites it as root."
        exit 1
    fi
    if [ "$source" != flag ] && [ "${_SS_FACT[pointer_state]}" = present ]; then
        case "${_SS_FACT[pointer_value]}" in
            /?*) ;;
            *)
                err "$KASBAH_APPS_POINTER on $_SS_TARGET holds '${_SS_FACT[pointer_value]}', which is not an absolute path"
                err_cont "that file is where status looks when no --apps-path is given, and reading"
                err_cont "$KASBAH_DEFAULT_APPS_PATH instead would report a different server as if it were this one."
                err_cont "Pass --apps-path=<dir>, or repair the pointer with \`kasbah server init\`."
                exit 1
                ;;
        esac
    fi

    case $apps in
        /?*) ;;
        *) die "the status probe on $_SS_TARGET reported apps_path='$apps', which is not an absolute path" ;;
    esac
    case $source in
        flag|pointer|default) ;;
        *) die "the status probe on $_SS_TARGET reported apps_source='$source', which this kasbah does not know" ;;
    esac

    _SS_APPS_PATH="$apps"
    _SS_APPS_SOURCE="$source"
    return 0
}

# --- The marker -------------------------------------------------------------------

# Exit 4 is the same verdict `kasbah deploy` reaches, and for the same reason it
# never prints a bare `kasbah server init <target>`: run against a server
# prepared somewhere other than the default, that command renders a second
# Traefik stack under the frozen `traefik` compose project, recreates the
# running proxy against it, and takes every site on the host down. What status
# can offer instead — and deploy cannot, because it is a project command — is
# the flag that looks elsewhere.
#
# Where it looked is now the pointer's answer unless --apps-path overrode it, so
# the two situations left are "never prepared" and "prepared, and the record of
# where is gone or wrong".
_ss_no_marker() {
    local marker_path="$_SS_APPS_PATH/.kasbah/server.json"

    err "$_SS_TARGET has no server marker at $marker_path"
    [ "${_SS_FACT[apps_state]}" != absent ] \
        || err_cont "($_SS_APPS_PATH is not there either — the probe found nothing at that path.)"
    case $_SS_APPS_SOURCE in
        flag)
            err_cont "That path is the one --apps-path named, and status looked there and nowhere else."
            # The operator who reached for the escape hatch and guessed is
            # exactly the one the server's own record helps.
            [ "${_SS_FACT[pointer_state]}" != present ] \
                || err_cont "($KASBAH_APPS_POINTER on this server records ${_SS_FACT[pointer_value]}.)"
            ;;
        pointer) err_cont "That path is what $KASBAH_APPS_POINTER records, so the server's own note of" ;;
        *)       err_cont "That file is what \`kasbah server init\` writes last, and $KASBAH_APPS_POINTER —" ;;
    esac
    case $_SS_APPS_SOURCE in
        pointer) err_cont "where it was prepared points at a tree with no marker in it." ;;
        default) err_cont "the server's own record of where it was prepared — is not there either." ;;
    esac
    err_cont "So this is one of two situations, and they have different answers:"
    err_cont "  * the server has never been prepared, and initialising it is the answer."
    err_cont "  * it is prepared somewhere else. Point status at that tree:"
    err_cont "      kasbah server status $_SS_TARGET --apps-path=<dir>"
    err_cont "Do not re-run init until you know which. Pointed at the wrong apps path it"
    err_cont "renders a second Traefik stack under the frozen 'traefik' compose project,"
    err_cont "which recreates the running proxy against it and takes every site down."
    exit "$KASBAH_EXIT_NO_REMOTE_STATE"
}

_server_status_read_marker() {
    local path="$_SS_APPS_PATH/.kasbah/server.json"

    # The apps path itself, before the file inside it: "there is no marker" and
    # "that is not a directory" are different servers, and the probe already
    # knows which one this is.
    case "${_SS_FACT[apps_state]}" in
        dir|absent) ;;
        notdir) die "$_SS_APPS_PATH on $_SS_TARGET exists and is not a directory — point status elsewhere with --apps-path=<dir>" ;;
        *)      die "$_SS_APPS_PATH on $_SS_TARGET is in a state the probe called '${_SS_FACT[apps_state]}', which this kasbah does not know" ;;
    esac

    case "${_SS_FACT[marker_state]}" in
        ok) ;;
        absent) _ss_no_marker ;;
        notfile) die "$path on $_SS_TARGET exists and is not a regular file" ;;
        empty)   die "$path on $_SS_TARGET is empty — kasbah server init did not finish, or something truncated it" ;;
        *)       die "$path on $_SS_TARGET could not be read" ;;
    esac

    _ss_b64_decode "${_SS_FACT[marker_b64]}" _SS_MARKER \
        || die "the status probe on $_SS_TARGET sent $path back as something that is not base64"
    jq -e 'type == "object"' >/dev/null 2>&1 <<<"$_SS_MARKER" \
        || die "$path on $_SS_TARGET is not a JSON object — look at it before running anything else against this server"

    _SS_MARKER_APPS="$(jq -r '.apps_path // "" | tostring' <<<"$_SS_MARKER")"
    _SS_MARKER_DATA="$(jq -r '.data_path // "" | tostring' <<<"$_SS_MARKER")"
    _SS_MARKER_VERSION="$(jq -r '.kasbah_version // "" | tostring' <<<"$_SS_MARKER")"
    _SS_MARKER_CPU="$(jq -r '.cpu_limit // "" | tostring' <<<"$_SS_MARKER")"
    _SS_MARKER_MEM="$(jq -r '.mem_limit // "" | tostring' <<<"$_SS_MARKER")"
    return 0
}

# --- The project table ------------------------------------------------------------

# `<name-b64> <total> <running> <logstate> <log-b64>`, one row per project. The
# two free-form values travel base64'd, so a project directory whose name
# carries a space — or a versions.log line, which always does — cannot be
# mistaken for another column.
#
# One row is dropped here rather than on the far side: the bind-mount root, when
# `--data-path` put it inside the apps path under a name the remote step could
# not know. The static list it filters with is kasbah's three reserved names,
# and `--data-path=<apps>/store` is neither reserved nor a project — it is
# kasbah's own directory, and the marker is the only thing that says so.
_ss_decode_projects() {
    local table row name_b64 total running logstate log_b64 rest name log
    local fragstate frag_b64 cont_b64 frag cont
    local data_dir="" described=0

    _SS_P_NAME=()
    _SS_P_TOTAL=()
    _SS_P_RUNNING=()
    _SS_P_LOGSTATE=()
    _SS_P_LOG=()
    _SS_P_FRAGSTATE=()
    _SS_P_FRAG=()
    _SS_P_CONT=()

    case "$_SS_MARKER_DATA" in
        "$_SS_APPS_PATH"/?*)
            data_dir="${_SS_MARKER_DATA#"$_SS_APPS_PATH"/}"
            # Only a direct child is one of the entries the walk saw.
            case $data_dir in */*) data_dir="" ;; esac
            ;;
    esac

    _ss_b64_decode "${_SS_FACT[projects_b64]}" table \
        || die "the status probe on $_SS_TARGET sent a project table that is not base64"

    while IFS= read -r row; do
        [ -n "$row" ] || continue
        read -r name_b64 total running logstate log_b64 fragstate frag_b64 cont_b64 rest <<<"$row"
        if [ -z "$name_b64" ] || [ -z "$logstate" ] || [ -z "$fragstate" ] \
           || [ -z "$frag_b64" ] || [ -z "$cont_b64" ] || [ -n "$rest" ]; then
            err "the status probe on $_SS_TARGET returned a project row it did not build: '$row'"
            exit 1
        fi
        described=$((described + 1))
        _ss_b64_decode "$name_b64" name \
            || die "the status probe on $_SS_TARGET sent a project name that is not base64: '$name_b64'"
        _ss_b64_field "$log_b64" log \
            || die "the status probe on $_SS_TARGET sent $name's versions.log line as something that is not base64"
        _ss_b64_field "$frag_b64" frag \
            || die "the status probe on $_SS_TARGET sent $name's Traefik fragment as something that is not base64"
        _ss_b64_field "$cont_b64" cont \
            || die "the status probe on $_SS_TARGET sent $name's container list as something that is not base64"
        [ "$name" != "$data_dir" ] || continue

        _SS_P_NAME+=("$name")
        _SS_P_TOTAL+=("$total")
        _SS_P_RUNNING+=("$running")
        _SS_P_LOGSTATE+=("$logstate")
        _SS_P_LOG+=("$log")
        _SS_P_FRAGSTATE+=("$fragstate")
        _SS_P_FRAG+=("$frag")
        _SS_P_CONT+=("$cont")
    done <<<"$table"

    # The count and the table are two statements about the same walk, so a
    # disagreement means one of them was truncated in transit. Counted before
    # the data directory is dropped, since the far side counted it too.
    if [ "$described" != "${_SS_FACT[project_count]}" ]; then
        err "the status probe on $_SS_TARGET counted ${_SS_FACT[project_count]} projects and described $described"
        err_cont "the payload was truncated — nothing below it can be trusted"
        exit 1
    fi
    return 0
}

# --- The files the probe brought back ------------------------------------------------

# The three whole files, decoded once, and the two facts read out of two of
# them. A blob that is not base64 leaves its variable empty and the line that
# reads it says so — and in acme.json's case the complaint never quotes the
# blob, which is the same rule the diagnostic in _ss_absorb_checked follows.
_ss_decode_extras() {
    local apex="" rc=0 count="" d="" i=0

    _ss_b64_decode "${_SS_FACT[acme_b64]}"          _SS_ACME     || _SS_ACME=""
    _ss_b64_decode "${_SS_FACT[shared_b64]}"        _SS_SHARED   || _SS_SHARED=""
    _ss_b64_decode "${_SS_FACT[mail_registry_b64]}" _SS_REGISTRY || _SS_REGISTRY=""

    # The dashboard's hostname, out of the fragment that is the only record of
    # the server's apex — it is deliberately not in the marker.
    _SS_DASH_HOST=""
    rc=0
    traefik_dashboard_apex "$_SS_SHARED" apex || rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$apex" ]; then
        _SS_DASH_HOST="traefik.$apex"
    fi

    # The mail registry, one key at a time and one *index* at a time: a newline
    # inside a value cannot then smuggle an extra domain past the list, which is
    # the rule `server init`, `add-mail-domain` and `deploy` all read it under.
    _SS_MAIL_PRIMARY=""
    _SS_MAIL_DOMAINS=()
    rc=0
    yaml_get "$_SS_REGISTRY" '.primary_domain // ""' _SS_MAIL_PRIMARY || rc=$?
    if [ "$rc" -ne 0 ]; then
        _SS_MAIL_PRIMARY=""
    else
        rc=0
        yaml_get "$_SS_REGISTRY" '(.domains // []) | length' count || rc=$?
        [ "$rc" -eq 0 ] || count=0
        case $count in ''|*[!0-9]*) count=0 ;; esac
        while [ "$i" -lt "$count" ]; do
            rc=0
            yaml_get "$_SS_REGISTRY" "(.domains // [])[$i] // \"\" | tostring" d || rc=$?
            i=$((i + 1))
            [ "$rc" -eq 0 ] && [ -n "$d" ] || continue
            _SS_MAIL_DOMAINS+=("$d")
        done
    fi

    # The probe had no JSON parser and scraped the data path out of the marker's
    # bytes; jq has now read the same bytes properly. They agree on every marker
    # kasbah wrote. When they do not, the two reads that hang off that path —
    # the certificate store and the data disk figure — describe a tree nobody
    # asked about, so they are reported as unread rather than as facts.
    _SS_DATA_TRUSTED=no
    if [ -n "$_SS_MARKER_DATA" ] && [ "${_SS_FACT[probe_data_path]}" = "$_SS_MARKER_DATA" ]; then
        _SS_DATA_TRUSTED=yes
    fi
    return 0
}

# The hostnames one project's fragment claims, one per line, in the order they
# appear and without repeats. Exit 2 when the fragment does not parse as YAML.
#
# One indexed read per router, never one combined parse: a value carrying a
# newline would otherwise arrive as two entries, and this list decides which
# hostname a certificate line is printed about. The routers are indexed through
# `to_entries` rather than looked up by name, so a router *key* is never
# interpolated into a jq filter either.
_ss_fragment_hosts() {
    local _fh_content="$1" _fh_out="$2"
    local _fh_n="" _fh_i=0 _fh_rule="" _fh_s="" _fh_host="" _fh_acc="" _fh_rc=0

    printf -v "$_fh_out" '%s' ""
    [ -n "$_fh_content" ] || return 0

    yaml_get "$_fh_content" '(.http.routers // {}) | length' _fh_n || _fh_rc=$?
    [ "$_fh_rc" -eq 0 ] || return 2
    case $_fh_n in ''|*[!0-9]*) return 2 ;; esac

    while [ "$_fh_i" -lt "$_fh_n" ]; do
        _fh_rc=0
        yaml_get "$_fh_content" \
            "((.http.routers // {}) | to_entries)[$_fh_i].value.rule // \"\" | tostring" \
            _fh_rule || _fh_rc=$?
        _fh_i=$((_fh_i + 1))
        [ "$_fh_rc" -eq 0 ] || continue
        _fh_s="$_fh_rule"
        # Every Host(`…`) in the rule, not just the first: a router may claim
        # several. ${s#*"$match"} chops off everything up through the match,
        # which is what advances the loop.
        while [[ "$_fh_s" =~ Host\(\`([^\`]+)\`\) ]]; do
            _fh_host="${BASH_REMATCH[1]}"
            _fh_s="${_fh_s#*"${BASH_REMATCH[0]}"}"
            # A here-string, never a pipe into grep -q: grep exits at the first
            # match and the producer takes a SIGPIPE that pipefail propagates.
            if [ -z "$_fh_acc" ] || ! grep -qxF -- "$_fh_host" <<<"$_fh_acc"; then
                _fh_acc="$_fh_acc$_fh_host"$'\n'
            fi
        done
    done

    printf -v "$_fh_out" '%s' "${_fh_acc%$'\n'}"
    return 0
}

# --- Output --------------------------------------------------------------------------

# Kibibytes as df counts them, rendered the way df -h renders them. Integer
# arithmetic with one decimal place: a status line does not need bc.
_ss_human_kb() {
    local _hk_v="$1" _hk_out="$2" _hk_unit=K _hk_div=1 _hk_n=""

    case $_hk_v in ''|*[!0-9]*) printf -v "$_hk_out" '%s' "?"; return 0 ;; esac
    if   [ "$_hk_v" -ge 1073741824 ]; then _hk_unit=T; _hk_div=1073741824
    elif [ "$_hk_v" -ge 1048576 ];    then _hk_unit=G; _hk_div=1048576
    elif [ "$_hk_v" -ge 1024 ];       then _hk_unit=M; _hk_div=1024
    fi
    if [ "$_hk_div" = 1 ]; then
        printf -v "$_hk_out" '%s%s' "$_hk_v" "$_hk_unit"
        return 0
    fi
    _hk_n=$(( _hk_v * 10 / _hk_div ))
    printf -v "$_hk_out" '%s.%s%s' "$((_hk_n / 10))" "$((_hk_n % 10))" "$_hk_unit"
    return 0
}

# `df -Pk`'s last line, turned into a sentence. OUTVAR is left empty when the
# line is not one this reader understands, and the caller says so rather than
# printing a figure it made up.
_ss_disk_sentence() {
    local _dl_b64="$1" _dl_out="$2" _dl_fs_out="$3"
    local _dl_line="" _dl_fs="" _dl_total="" _dl_used="" _dl_avail="" _dl_cap="" _dl_mount=""
    local _dl_ht="" _dl_hu="" _dl_ha=""

    printf -v "$_dl_out" '%s' ""
    printf -v "$_dl_fs_out" '%s' ""
    _ss_b64_field "$_dl_b64" _dl_line || return 1
    [ -n "$_dl_line" ] || return 1

    read -r _dl_fs _dl_total _dl_used _dl_avail _dl_cap _dl_mount <<<"$_dl_line"
    case $_dl_total in ''|*[!0-9]*) return 1 ;; esac
    case $_dl_used  in ''|*[!0-9]*) return 1 ;; esac
    case $_dl_avail in ''|*[!0-9]*) return 1 ;; esac

    _ss_human_kb "$_dl_total" _dl_ht
    _ss_human_kb "$_dl_used"  _dl_hu
    _ss_human_kb "$_dl_avail" _dl_ha
    printf -v "$_dl_out" '%s of %s used (%s), %s free — %s on %s' \
        "$_dl_hu" "$_dl_ht" "${_dl_cap:-?}" "$_dl_ha" "$_dl_fs" "${_dl_mount:-?}"
    printf -v "$_dl_fs_out" '%s on %s' "$_dl_fs" "${_dl_mount:-?}"
    return 0
}

# The filesystems the two paths live on, which is the question a status can
# answer in constant time: `du` over a data path holding a mail spool would make
# the report cost what the server happens to hold.
_ss_print_disk() {
    local apps_line="" apps_fs="" data_line="" data_fs="" rc=0

    case "${_SS_FACT[apps_df_state]}" in
        ok)
            rc=0
            _ss_disk_sentence "${_SS_FACT[apps_df_b64]}" apps_line apps_fs || rc=$?
            if [ "$rc" -eq 0 ]; then
                printf 'Disk: %s  %s\n' "$_SS_APPS_PATH" "$apps_line"
            else
                printf 'Disk: %s  unknown — df answered in a shape this kasbah does not read\n' "$_SS_APPS_PATH"
            fi
            ;;
        absent) printf 'Disk: %s  unknown — the path is not there\n' "$_SS_APPS_PATH" ;;
        *)      printf 'Disk: %s  unknown — df did not answer\n' "$_SS_APPS_PATH" ;;
    esac

    # The data path is usually inside the apps path and on the same filesystem,
    # and repeating one figure as two facts invites a reader to add them up.
    if [ "$_SS_DATA_TRUSTED" != yes ]; then
        printf '      %s  not read — %s\n' "${_SS_MARKER_DATA:-<no data path in the marker>}" \
            "the probe and the marker disagree about where the data path is"
        return 0
    fi
    case "${_SS_FACT[data_df_state]}" in
        ok)
            rc=0
            _ss_disk_sentence "${_SS_FACT[data_df_b64]}" data_line data_fs || rc=$?
            if [ "$rc" -ne 0 ]; then
                printf '      %s  unknown — df answered in a shape this kasbah does not read\n' "$_SS_MARKER_DATA"
            elif [ -n "$apps_fs" ] && [ "$data_fs" = "$apps_fs" ]; then
                printf '      %s  the same filesystem\n' "$_SS_MARKER_DATA"
            else
                printf '      %s  %s\n' "$_SS_MARKER_DATA" "$data_line"
            fi
            ;;
        absent) printf '      %s  unknown — the path is not there\n' "$_SS_MARKER_DATA" ;;
        *)      printf '      %s  unknown — df did not answer\n' "$_SS_MARKER_DATA" ;;
    esac
    return 0
}

# What the certificate store can answer at all, said once. Every hostname below
# is then either given a certificate line or given none — the alternative is the
# same sentence about an unreadable store repeated under every project.
_SS_ACME_READY=no
_ss_print_certs() {
    local path="${_SS_MARKER_DATA:-<data>}/traefik/letsencrypt/acme.json"

    _SS_ACME_READY=no
    if [ "$_SS_DATA_TRUSTED" != yes ]; then
        printf '  Certificates: not read — the probe and the marker disagree about the data path\n'
        return 0
    fi
    case "${_SS_FACT[acme_state]}" in
        file) ;;
        absent)
            printf '  Certificates: no store at %s — this Traefik is not the one kasbah prepared\n' "$path"
            return 0 ;;
        empty)
            printf '  Certificates: the store at %s is empty — nothing has been issued yet\n' "$path"
            return 0 ;;
        unreadable)
            printf '  Certificates: %s cannot be read by %s — it is mode 600 and owned by the deploy user\n' \
                "$path" "$_SS_TARGET"
            return 0 ;;
        *)
            printf '  Certificates: %s is %s, not a regular file\n' "$path" "${_SS_FACT[acme_state]}"
            return 0 ;;
    esac

    if [ -z "$_SS_ACME" ]; then
        printf '  Certificates: %s did not come back as readable bytes\n' "$path"
        return 0
    fi

    # One lookup for a hostname nothing claims, purely to learn the store's
    # shape and how many certificates are in it. Its bytes are never printed:
    # the file holds the ACME account key and every certificate's private key.
    acme_lookup "$_SS_ACME" ""
    case "$ACME_STATE" in
        notjson)
            printf '  Certificates: %s does not parse as JSON (its bytes are not shown — it holds private key material)\n' "$path" ;;
        noresolver)
            printf "  Certificates: %s has no '%s' store — the schema has shifted, or this Traefik uses another resolver\\n" \
                "$path" "$ACME_RESOLVER" ;;
        notarray)
            printf "  Certificates: %s holds a '%s' whose Certificates is a %s, not a list\\n" \
                "$path" "$ACME_RESOLVER" "$ACME_KIND" ;;
        empty)
            printf '  Certificates: none issued yet (the store at %s is empty)\n' "$path" ;;
        *)
            printf '  Certificates: %s in %s\n' "$ACME_COUNT" "$path"
            _SS_ACME_READY=yes ;;
    esac
    return 0
}

# One hostname's certificate, indented under whatever claims it. Printed only
# when the store answered at all — _ss_print_certs said why otherwise.
_ss_cert_line() {
    local host="$1" indent="$2" via="" issuer=""

    [ "$_SS_ACME_READY" = yes ] || return 0
    acme_lookup "$_SS_ACME" "$host"
    [ "$ACME_MAIN" = "$host" ] || via=" (as a SAN of $ACME_MAIN)"

    case "$ACME_STATE" in
        found) ;;
        nomatch)   printf '%sno certificate — Traefik issues one when the hostname resolves here\n' "$indent"; return 0 ;;
        nocert)    printf '%sthe store entry carries no certificate field\n' "$indent"; return 0 ;;
        notbase64) printf '%sthe store entry is not base64\n' "$indent"; return 0 ;;
        nopem)     printf '%sthe store entry is not a certificate openssl reads\n' "$indent"; return 0 ;;
        *)         printf '%sno certificate (%s)\n' "$indent" "$ACME_STATE"; return 0 ;;
    esac

    # The issuer is not decoration: it is what separates a certificate from
    # Let's Encrypt's staging CA — which browsers reject — from a real one, and
    # kasbah renders `caServer` into traefik.yml where a hand edit reaches it.
    issuer="${ACME_ISSUER:-unknown issuer}"

    # Traefik renews at 30 days remaining, so a smaller number means renewal has
    # already missed its window and somebody has to look at why.
    if [ -z "$ACME_DAYS" ]; then
        printf '%scertificate%s expires %s, %s (unparseable date, so no days remaining)\n' \
            "$indent" "$via" "$ACME_NOTAFTER" "$issuer"
    elif [ "$ACME_DAYS" -lt 0 ]; then
        printf '%scertificate%s EXPIRED %s day(s) ago (%s, %s) — renewal has been failing\n' \
            "$indent" "$via" "$(( -ACME_DAYS ))" "$ACME_NOTAFTER" "$issuer"
    elif [ "$ACME_DAYS" -le 14 ]; then
        printf '%scertificate%s expires in %s day(s) (%s, %s) — Traefik renews at 30, so renewal has missed its window\n' \
            "$indent" "$via" "$ACME_DAYS" "$ACME_NOTAFTER" "$issuer"
    else
        printf '%scertificate%s valid for %s more day(s) (until %s, %s)\n' \
            "$indent" "$via" "$ACME_DAYS" "$ACME_NOTAFTER" "$issuer"
    fi
    return 0
}

# The mail stack. Absent is an ordinary state — a server prepared without
# --with-mail — and is reported as one, not as a fault.
_ss_print_mail() {
    local d state health restarts detail=""

    case "${_SS_FACT[mail_dir_state]}" in
        absent)
            printf 'Mail: not installed — no %s/mail (kasbah server init --with-mail scaffolds it)\n' "$_SS_APPS_PATH"
            return 0 ;;
        notdir)
            printf 'Mail: %s/mail exists and is not a directory\n' "$_SS_APPS_PATH"
            return 0 ;;
    esac

    printf 'Mail: %s/mail\n' "$_SS_APPS_PATH"
    for d in dms web; do
        case $d in
            dms) state="${_SS_FACT[mail_dms_state]}"; health="${_SS_FACT[mail_dms_health]}"
                 restarts="${_SS_FACT[mail_dms_restarts]}"; detail=mail-dms ;;
            *)   state="${_SS_FACT[mail_web_state]}";  health="${_SS_FACT[mail_web_health]}"
                 restarts="${_SS_FACT[mail_web_restarts]}"; detail=mail-snappymail ;;
        esac
        case $state in
            absent)   printf '  %-16s absent — the stack is scaffolded and not running\n' "$detail" ;;
            nodocker) printf '  %-16s unknown — docker did not answer\n' "$detail" ;;
            *)
                # The restart count is not decoration: a DMS that cannot find a
                # certificate for mail.<primary> restarts until one appears, and
                # the count is the only thing that says which of the two it is.
                printf '  %-16s %s (%s)%s\n' "$detail" "$state" \
                    "${health:-none}" \
                    "$([ "${restarts:-0}" = 0 ] || printf ', %s restart(s)' "$restarts")"
                ;;
        esac
    done

    if [ "${_SS_FACT[mail_registry_state]}" != file ]; then
        printf '  registry %s/mail/kasbah.yml: %s — the one record of which domains this stack serves\n' \
            "$_SS_APPS_PATH" "${_SS_FACT[mail_registry_state]}"
        return 0
    fi
    if [ -z "$_SS_MAIL_PRIMARY" ]; then
        printf '  registry %s/mail/kasbah.yml: no primary_domain — it is the MX target and the name both certificates are issued for\n' \
            "$_SS_APPS_PATH"
        return 0
    fi

    printf '  Primary: %s   Domains: %s\n' "$_SS_MAIL_PRIMARY" \
        "$(printf '%s' "${_SS_MAIL_DOMAINS[*]:-none}")"
    for d in "mail.$_SS_MAIL_PRIMARY" "webmail.$_SS_MAIL_PRIMARY"; do
        printf '  %s\n' "$d"
        _ss_cert_line "$d" '      '
    done
    return 0
}


# Whatever the container itself says, rather than a state kasbah infers: a
# stopped Traefik and a running-but-unhealthy one are different problems.
_ss_print_traefik() {
    local health

    if [ "${_SS_FACT[traefik_present]}" != yes ]; then
        if [ "${_SS_FACT[have_docker]}" != yes ] || [ -n "${_SS_FACT[docker_error]}" ]; then
            printf 'Traefik: unknown — docker did not answer\n'
        else
            printf "Traefik: absent — no container in compose project 'traefik'\n"
        fi
        return 0
    fi

    # A container was found, so an empty value here is an inspect that did not
    # answer — a race with a `docker rm`, or a daemon that went away between two
    # calls. The key arrived, which is all the protocol check can see; printing
    # `Traefik:  (healthy)` off it would be the plausible-looking line this
    # command exists not to produce.
    if [ -z "${_SS_FACT[traefik_state]}" ] || [ -z "${_SS_FACT[traefik_health]}" ] \
       || [ -z "${_SS_FACT[traefik_image]}" ]; then
        printf 'Traefik: unknown — docker named a container and then did not describe it\n'
        printf '  state %s / health %s / image %s\n' \
            "${_SS_FACT[traefik_state]:-<none>}" "${_SS_FACT[traefik_health]:-<none>}" \
            "${_SS_FACT[traefik_image]:-<none>}"
        return 0
    fi

    health="${_SS_FACT[traefik_health]}"
    case $health in
        none) printf 'Traefik: %s (no healthcheck)\n' "${_SS_FACT[traefik_state]}" ;;
        *)    printf 'Traefik: %s (%s)\n' "${_SS_FACT[traefik_state]}" "$health" ;;
    esac
    # The tag it was created from and the image that tag resolved to. The second
    # is what says whether two servers on `traefik:v3.7.10` are running the same
    # bytes: a tag can be re-pushed, an id cannot. Shortened the way docker's own
    # output shortens it — 12 hex digits after the algorithm.
    printf '  Image: %s (%s)\n' \
        "${_SS_FACT[traefik_image]}" "${_SS_FACT[traefik_image_id]:0:19}"
    printf '  Container: %s\n' "${_SS_FACT[traefik_container]}"
    return 0
}

_ss_print_projects() {
    local i name state version deployed detail ts action backup kasbah note
    local width=14

    printf 'Projects:\n'
    if [ "${#_SS_P_NAME[@]}" -eq 0 ]; then
        printf '  none — no project directory under %s\n' "$_SS_APPS_PATH"
        return 0
    fi

    # The column is as wide as the widest name, with 14 as the floor so the
    # ordinary server looks like the sample in docs/server-setup.md. A fixed 14
    # is not a column: `gallery-website` is fifteen characters and pushed every
    # field on its row one place right, which is what the real host showed.
    for name in "${_SS_P_NAME[@]}"; do
        [ "${#name}" -le "$width" ] || width="${#name}"
    done

    for i in "${!_SS_P_NAME[@]}"; do
        name="${_SS_P_NAME[$i]}"
        version="-"
        deployed=""
        note=""

        case "${_SS_P_LOGSTATE[$i]}" in
            ok)
                if vlog_parse_line "${_SS_P_LOG[$i]}" ts action version backup kasbah; then
                    deployed="$action $ts"
                    [ -z "$kasbah" ] || deployed="$deployed (kasbah $kasbah)"
                else
                    version="?"
                    note="versions.log's last line is not a kasbah entry: ${_SS_P_LOG[$i]}"
                fi
                ;;
            missing)    note="no versions.log — never deployed by kasbah, or dropped" ;;
            empty)      note="versions.log is empty" ;;
            notfile)    note="versions.log exists and is not a regular file" ;;
            unreadable) note="versions.log cannot be read by the ssh user" ;;
            noaccess)   note="the directory cannot be read by the ssh user — a deploy that ran as root leaves this" ;;
            notdir)     note="not a directory — kasbah deploys into directories only" ;;
            *)          note="unknown versions.log state '${_SS_P_LOGSTATE[$i]}'" ;;
        esac

        # The counts say what docker reports and the word says what it means:
        # `1/1 running`, `0/2 stopped`, `1/3 partial` (docs/server-setup.md's
        # sample). The word is not decoration — `0/1 running` is a small lie,
        # and "is this site up" is the question the column is read for.
        if [ "${_SS_P_LOGSTATE[$i]}" = notdir ]; then
            state="-"
        elif [ "${_SS_FACT[have_docker]}" != yes ] || [ -n "${_SS_FACT[docker_error]}" ]; then
            state="?"
        elif [ "${_SS_P_TOTAL[$i]}" = 0 ]; then
            state="no containers"
        elif [ "${_SS_P_RUNNING[$i]}" = "${_SS_P_TOTAL[$i]}" ]; then
            state="${_SS_P_RUNNING[$i]}/${_SS_P_TOTAL[$i]} running"
        elif [ "${_SS_P_RUNNING[$i]}" = 0 ]; then
            state="0/${_SS_P_TOTAL[$i]} stopped"
        else
            state="${_SS_P_RUNNING[$i]}/${_SS_P_TOTAL[$i]} partial"
        fi

        # One row per project, and the last column is either the deploy it last
        # recorded or why there is none — never both, since a line that parsed
        # is not a line to explain.
        detail="$deployed"
        [ -n "$detail" ] || detail="$note"
        printf '  %-*s %-14s %-10s %s\n' "$width" "$name" "$state" "$version" "$detail"
        _ss_print_project_hosts "$i" "$name"
        _ss_print_project_containers "$i"
    done
    return 0
}

# What the project's Traefik fragment claims, and what the certificate store
# says about each hostname. The fragment is parsed *here*, with the
# workstation's yq: the VPS has no yq, jq or python3 and keeping it that way is
# deliberate (docs/mail.md), so the file travels back base64'd like every other
# one status reads.
_ss_print_project_hosts() {
    local i="$1" name="$2" hosts="" host="" rc=0
    local path="$_SS_APPS_PATH/traefik/dynamic/$name.yml"

    case "${_SS_P_FRAGSTATE[$i]}" in
        ok) ;;
        absent)
            # Silent for a directory that is plainly not a kasbah project:
            # every stray directory under the apps path is listed above, and a
            # line about a routing file none of them was ever going to have is
            # noise. A project kasbah deployed having none is the real news.
            if [ "${_SS_P_LOGSTATE[$i]}" = ok ] || [ "${_SS_P_TOTAL[$i]}" != 0 ]; then
                printf '      no Traefik fragment at %s — nothing routes to this project\n' "$path"
            fi
            return 0 ;;
        empty)      printf '      %s is empty — nothing routes to this project\n' "$path"; return 0 ;;
        unreadable) printf '      %s cannot be read by the ssh user\n' "$path"; return 0 ;;
        notfile)    printf '      %s exists and is not a regular file\n' "$path"; return 0 ;;
        *)          printf '      unknown fragment state %s\n' "${_SS_P_FRAGSTATE[$i]}"; return 0 ;;
    esac

    _ss_fragment_hosts "${_SS_P_FRAG[$i]}" hosts || rc=$?
    if [ "$rc" -ne 0 ]; then
        printf '      %s does not parse as YAML, so this project'"'"'s domain cannot be read\n' "$path"
        return 0
    fi
    if [ -z "$hosts" ]; then
        printf '      %s declares no Host() rule, so this project claims no domain\n' "$path"
        return 0
    fi

    while IFS= read -r host; do
        [ -n "$host" ] || continue
        printf '      %s\n' "$host"
        _ss_cert_line "$host" '          '
    done <<<"$hosts"
    return 0
}

# Per-container state and health — the health Traefik'"'"'s own line has had since
# the minimal status, and no other container did. A project whose containers are
# all running and healthy says so in one line rather than one per container:
# the row above already carries the count, and the reason to print names is that
# one of them is not what the count implies.
_ss_print_project_containers() {
    local i="$1" line cname cstate chealth listed=0 odd=0

    [ -n "${_SS_P_CONT[$i]}" ] || return 0
    while IFS=' ' read -r cname cstate chealth; do
        [ -n "$cname" ] || continue
        listed=$((listed + 1))
        [ "$cstate" = running ] || odd=1
        case $chealth in ''|none|healthy) ;; *) odd=1 ;; esac
    done <<<"${_SS_P_CONT[$i]}"

    [ "$listed" -gt 0 ] || return 0
    if [ "$odd" = 0 ]; then
        printf '      %s container(s), all running and none unhealthy\n' "$listed"
        return 0
    fi
    while IFS=' ' read -r cname cstate chealth; do
        [ -n "$cname" ] || continue
        _ss_b64_decode "$cname" line || line="<name not base64>"
        printf '      %-24s %s (%s)\n' "$line" "$cstate" "${chealth:-none}"
    done <<<"${_SS_P_CONT[$i]}"
    return 0
}

_server_status_print() {
    printf 'VPS: %s (connected)\n' "$_SS_TARGET"
    if [ -n "${_SS_FACT[docker_server]}" ]; then
        printf 'Docker: %s, Compose: %s\n' \
            "${_SS_FACT[docker_server]}" "${_SS_FACT[compose_version]:-unknown}"
    else
        printf 'Docker: unavailable — %s\n' "${_SS_FACT[docker_error]:-no docker command on the remote}"
    fi
    # Where the root came from, because "status read the wrong tree" and "the
    # server records a different one" are different problems and only the
    # source tells them apart.
    printf 'Root: %s (%s)  Data: %s\n' \
        "$_SS_APPS_PATH" "$_SS_APPS_SOURCE" "${_SS_MARKER_DATA:-unknown}"
    printf 'Marker: kasbah %s, cpu %s, mem %s\n' \
        "${_SS_MARKER_VERSION:-unknown}" "${_SS_MARKER_CPU:-unknown}" "${_SS_MARKER_MEM:-unknown}"
    _ss_print_disk

    # The marker is the record of where init put things; the apps path is where
    # this run looked. They disagree when a prepared tree was moved, and every
    # path printed above the line is the one that was actually read.
    if [ -n "$_SS_MARKER_APPS" ] && [ "$_SS_MARKER_APPS" != "$_SS_APPS_PATH" ]; then
        warn "the marker records apps_path=$_SS_MARKER_APPS, and this status read $_SS_APPS_PATH"
    fi

    printf '\n'
    _ss_print_traefik
    _ss_print_certs
    if [ -n "$_SS_DASH_HOST" ]; then
        printf '  Dashboard: %s\n' "$_SS_DASH_HOST"
        _ss_cert_line "$_SS_DASH_HOST" '      '
    fi
    printf '\n'
    _ss_print_mail
    printf '\n'
    _ss_print_projects
    return 0
}

# --- Command ----------------------------------------------------------------------

cmd_server_status() {
    _server_status_parse_args "$@"
    command -v jq >/dev/null || die "jq is required (install jq and retry)"

    ssh_connect "$_SS_TARGET"

    _server_status_collect
    _server_status_read_marker
    _ss_decode_projects
    # After the marker, because two of the files the probe brought back are only
    # trustworthy once jq has confirmed the data path they were read from.
    _ss_decode_extras

    # Only a difference in majors is worth a word: within one, docs/overview.md's
    # compatibility policy says everything interoperates. Unlike `server init`
    # this is a warning rather than a refusal — a read-only report that will not
    # print because the server is ahead of the reader is missing at the moment it
    # is most wanted. Versions that cannot be compared add nothing here; the
    # Marker line prints what the file says either way.
    local marker_major="${_SS_MARKER_VERSION%%.*}" ours="${KASBAH_VERSION%%.*}"
    if [[ "$marker_major" =~ ^[0-9]+$ ]] && [[ "$ours" =~ ^[0-9]+$ ]] \
       && [ "$marker_major" != "$ours" ]; then
        warn "the marker was written by kasbah $_SS_MARKER_VERSION and this is kasbah $KASBAH_VERSION"
        warn "different majors — fields this version does not know about are not shown"
    fi

    _server_status_print
}
