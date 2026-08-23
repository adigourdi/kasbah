# kasbah — server init command
# Sourced by bin/kasbah. Do not execute directly.

[ -n "${_KASBAH_SERVER_INIT_LOADED:-}" ] && return 0
_KASBAH_SERVER_INIT_LOADED=1

. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/prompt.sh"
. "$KASBAH_LIB_DIR/ssh.sh"

# `kasbah server init` lays out the directory tree every later command assumes
# and records what it found in the server marker. It checks prerequisites and
# never installs them (docs/server-setup.md), and it is safe to re-run: a second
# run against an unchanged host leaves the tree byte-identical.
#
# Seven remote steps over one connection, and nothing is created until every
# read among them has been judged. The probe collects every fact the verdicts
# need in a single round trip, because a check that fetches its own value is a
# check that can silently read a fact that never arrived
# (docs/phases/01-rig.md, from 1.3). The second reads any marker already on the
# server. The third reads the Traefik stack already on the server, which is what
# the fresh render is compared against. The fourth creates the layout, the fifth
# starts Traefik, and the sixth writes the marker — last among the things that
# signal completion, because its presence is the "init completed" signal. The
# seventh writes /etc/kasbah/apps-path, immediately after the marker: a run that
# dies before the marker leaves no pointer either.

# The parsed command line.
_SI_TARGET=""
_SI_APPS_PATH=""
_SI_DATA_PATH=""
_SI_MAIL=""
_SI_BACKUP=""
_SI_DOMAIN=""
_SI_EMAIL=""
_SI_AUTH=""
_SI_ACME_STAGING=""
_SI_ACME_RESET_CHOICE=""
_SI_YES=""

# What the probe brought back, and what was derived from it.
declare -A _SI_FACT=()
_SI_ELEVATE=""
_SI_CPU_LIMIT=""
_SI_MEM_LIMIT=""
_SI_MARKER_EXISTING=""
_SI_MARKER_PRESENT=no

# The Traefik stack: the three files kasbah owns, what is on the server now,
# what the run resolved to render with, and what shipping decided.
_SI_TRAEFIK_FILES=(compose.yml traefik.yml dynamic/_shared.yml)
declare -A _SI_TRAEFIK_KEY=(
    [compose.yml]=traefik_compose_b64
    [traefik.yml]=traefik_static_b64
    [dynamic/_shared.yml]=traefik_shared_b64
)
declare -A _SI_TRAEFIK_CURRENT=()
_SI_TRAEFIK_PROJECT=traefik
_SI_DASHBOARD_DOMAIN=""
_SI_ACME_EMAIL=""
# Let's Encrypt's own two directories, and nothing else: kasbah has no private
# CA to point at, so the endpoint is a switch rather than a value.
_SI_ACME_CA_PRODUCTION="https://acme-v02.api.letsencrypt.org/directory"
_SI_ACME_CA_STAGING="https://acme-staging-v02.api.letsencrypt.org/directory"
_SI_ACME_CA=""
_SI_ACME_CA_STORED=""
# How much is known about the certificate store and about the endpoint that
# filled it: known/nofield/unreadable/nocontent against absent/notfile/empty/
# nonempty. Only the pairing decides whether anything is at risk.
_SI_ACME_CA_ORIGIN=""
_SI_ACME_STORE=""
_SI_ACME_RESET=no
_SI_ACME_KEPT=""
_SI_AUTH_ENTRY=""
_SI_AUTH_ORIGIN=""
_SI_TRAEFIK_CHANGED=()
_SI_TRAEFIK_RESTART=no
_SI_TMPDIR=""

_server_init_usage() {
    cat <<EOF
Usage: kasbah server init USER@HOST [flags]

Prepares a VPS to host projects: checks the prerequisites, creates the
directory layout, renders and starts the shared Traefik stack, and writes
the server marker, and records the apps path at $KASBAH_APPS_POINTER so
every project command can find this server without being told. Idempotent.

Flags:
  --apps-path=<dir>      root directory on the VPS (default /apps)
  --data-path=<dir>      bind-mount root (default <apps-path>/data)
  --domain=<apex>        the dashboard is served at traefik.<apex>
  --email=<addr>         ACME registration address for Let's Encrypt
  --traefik-auth=user:pass   dashboard basic auth; hashed with bcrypt here
  --acme-staging         issue from Let's Encrypt's staging CA (untrusted
                         certificates, far looser rate limits)
  --reset-acme|--keep-acme   what to do with a certificate store whose CA
                         nothing on the server records
  --with-mail|--no-mail      scaffold the mail stack, or skip it
  --with-backup|--no-backup  install restic backups, or skip them
  --yes                  confirm a switch away from a stated endpoint

Every *feature* flag is tri-state: leaving one off asks. --acme-staging and
--yes are not — production is the default and never asks, and --yes only
answers a confirmation that a stated CA change raises. Domain, email and the
dashboard credentials are only asked for once — a re-run reuses what is
already on the server, since bcrypt salts randomly and a fresh hash would
rewrite the stack on every run.

The ACME endpoint is production unless --acme-staging says otherwise, on
every run: a re-run without the flag against a staging server is how you
switch back. Where that would strand certificates, init archives acme.json
and re-issues, and asks first. See docs/server-setup.md for the
prerequisites table and the layout.
EOF
}

# --- Command line -------------------------------------------------------------

# Rejects a second, contradicting --with-x/--no-x rather than letting the last
# one win: the two spellings exist to make an intent explicit, and a command
# line that states both intents has none.
_server_init_set_bool() {
    local _sb_value="$2" _sb_name="_SI_${1^^}"
    local _sb_yes="${3:---with-$1}" _sb_no="${4:---no-$1}"
    if [ -n "${!_sb_name}" ] && [ "${!_sb_name}" != "$_sb_value" ]; then
        die "server init: $_sb_yes and $_sb_no cannot both be given"
    fi
    printf -v "$_sb_name" '%s' "$_sb_value"
}

# Normalises a path flag into <outvar>: absolute, no trailing slash, no relative
# segment. Everything below the apps path is built from these two strings on the
# far side, so a surprise here becomes a surprise in mkdir — and both paths are
# also substituted into the Traefik compose file's quoted bind-mount strings.
_server_init_path() {
    local _sp_flag="$1" _sp_value="${2%$'\r'}" _sp_out="$3"

    [ -n "$_sp_value" ] || die "server init: --$_sp_flag= must not be empty"
    case $_sp_value in
        /*) ;;
        *)  die "server init: --$_sp_flag=$_sp_value must be an absolute path" ;;
    esac
    case $_sp_value in
        *$'\n'*) die "server init: --$_sp_flag= must not contain a newline" ;;
    esac
    _si_check_yaml_scalar "--$_sp_flag=" "$_sp_value"

    # Valid YAML is not enough for these two. They land in compose's volume
    # short syntax, which compose interpolates and then splits before Traefik
    # ever sees the file — so both characters below produce a document that
    # parses perfectly and means something else. `$` is expanded on the *VPS*
    # against the remote login shell (`/apps/$HOME` mounted /apps//home/you/…,
    # and an unset `${STAGE}` collapses to a different existing directory than
    # the layout step created, while the marker records the literal). `:`
    # re-partitions source from target (`/d:ata` mounted `/d` and left
    # acme.json unmounted). Neither has a legitimate use in an operator-typed
    # path.
    case $_sp_value in
        *'$'*) die "server init: --$_sp_flag= must not contain '\$' — the path is written into a compose bind mount, which compose expands on the server" ;;
        *:*)   die "server init: --$_sp_flag= must not contain ':' — the path is written into a compose bind mount, where ':' separates source from target" ;;
    esac

    case $_sp_value in
        *//*|*/./*|*/../*|*/..|*/.)
            die "server init: --$_sp_flag=$_sp_value must be a normalised path (no '.', '..' or empty segment)" ;;
    esac

    # A run of slashes is already out on the normalisation rule above, so the
    # only value that empties here is a single "/".
    while [ "${_sp_value: -1}" = / ]; do _sp_value="${_sp_value%/}"; done
    [ -n "$_sp_value" ] \
        || die "server init: --$_sp_flag=/ must not be the filesystem root"

    printf -v "$_sp_out" '%s' "$_sp_value"
}

# The three Traefik values, checked where they are typed. Each one is baked
# into a config file that Traefik parses on the far side, so a malformed value
# becomes a stack that will not start — cheaper to refuse here, and with a
# message about the input rather than about YAML.

# Every value below is substituted into a double-quoted YAML scalar. `"` ends
# that scalar and `\` starts an escape, so either one silently turns the rest of
# the file into something else — and for dynamic/_shared.yml that means
# tls.options.default never registers and *every* project's HTTPS router stops
# starting, while /ping keeps answering 200. Refused at the input, and the
# rendered file is parsed before it ships (see _server_init_traefik_render):
# this check is the good message, that one is the guarantee.
_si_check_yaml_scalar() {
    local _cy_what="$1" _cy_value="$2"
    case $_cy_value in
        *'"'*)  die "server init: $_cy_what must not contain a double quote — it is written into a quoted YAML value" ;;
        *'\'*)  die "server init: $_cy_what must not contain a backslash — it is written into a quoted YAML value" ;;
    esac
    # `[:cntrl:]` rather than `[![:print:]]`: the negative form asks "is every
    # byte printable", which under LC_ALL=C — routine in CI — is false for any
    # UTF-8 path, username or SMTPUTF8 address, and refuses `/srv/café` with a
    # message about control characters. Matching control characters positively
    # means the same bytes are rejected in every locale and nothing else is.
    case $_cy_value in
        *[[:cntrl:]]*) die "server init: $_cy_what must not contain control characters" ;;
    esac
}

_si_check_domain() {
    local d="$1"
    [ -n "$d" ] || die "server init: --domain= must not be empty"
    _is_fqdn "$d" \
        || die "server init: --domain=$d is not a domain name (expected an apex like example.com — the dashboard is served at traefik.<domain>)"
}

# Deliberately not an RFC 5322 parser: this address goes to Let's Encrypt,
# which validates it properly, and what pays for itself here is catching the
# typo before it is baked into the static config.
_si_check_email() {
    local e="$1"
    [ -n "$e" ] || die "server init: --email= must not be empty"
    case $e in
        *[[:space:]]*) die "server init: --email= must not contain whitespace" ;;
    esac
    _si_check_yaml_scalar "--email=" "$e"
    [[ "$e" =~ ^[^@]+@[^@]+$ ]] \
        || die "server init: --email=$e is not an email address (expected one @, with something either side)"
}

# `[[:space:]]` covers the carriage return too, which is the CRLF tolerance
# this value needs: a username silently carrying a \r would authenticate
# against a hash nobody can reproduce.
_si_check_auth_user() {
    local u="$1"
    [ -n "$u" ] || die "server init: the dashboard username must not be empty (--traefik-auth=user:pass)"
    case $u in
        *:*)           die "server init: the dashboard username must not contain a colon (--traefik-auth=user:pass splits on the first one)" ;;
        *[[:space:]]*) die "server init: the dashboard username must not contain whitespace" ;;
    esac
    _si_check_yaml_scalar "the dashboard username" "$u"
}

_si_check_auth_pass() {
    local p="$1"
    [ -n "$p" ] || die "server init: the dashboard password must not be empty (--traefik-auth=user:pass)"
    case $p in
        *$'\n'*) die "server init: the dashboard password must not contain a newline" ;;
    esac
}

_si_check_auth() {
    local v="$1"
    case $v in
        *:*) ;;
        *)   die "server init: --traefik-auth= must be user:pass" ;;
    esac
    _si_check_auth_user "${v%%:*}"
    _si_check_auth_pass "${v#*:}"
}

# Splits an already-checked user:pass at the first colon. The password may
# contain colons; the username may not, which is also what htpasswd assumes.
_si_parse_auth() {
    local _pa_value="$1" _pa_user_out="$2" _pa_pass_out="$3"
    _si_check_auth "$_pa_value"
    printf -v "$_pa_user_out" '%s' "${_pa_value%%:*}"
    printf -v "$_pa_pass_out" '%s' "${_pa_value#*:}"
}

_server_init_parse_args() {
    local apps="" data=""
    local apps_given=0 data_given=0

    _SI_TARGET=""
    _SI_MAIL=""
    _SI_BACKUP=""
    _SI_DOMAIN=""
    _SI_EMAIL=""
    _SI_AUTH=""
    _SI_ACME_STAGING=""
    _SI_ACME_RESET_CHOICE=""
    _SI_YES=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --apps-path=*) apps="${1#*=}"; apps_given=1 ;;
            --data-path=*) data="${1#*=}"; data_given=1 ;;
            --domain=*)    _SI_DOMAIN="${1#*=}"; _SI_DOMAIN="${_SI_DOMAIN%$'\r'}"
                           _si_check_domain "$_SI_DOMAIN" ;;
            --email=*)     _SI_EMAIL="${1#*=}";  _SI_EMAIL="${_SI_EMAIL%$'\r'}"
                           _si_check_email "$_SI_EMAIL" ;;
            # Validated, never echoed: the value carries a password, and an
            # error message is the one place it would end up on a terminal.
            --traefik-auth=*) _SI_AUTH="${1#*=}"; _si_check_auth "$_SI_AUTH" ;;
            --acme-staging) _SI_ACME_STAGING=yes ;;
            --reset-acme)  _server_init_set_bool acme_reset_choice yes --reset-acme --keep-acme ;;
            --keep-acme)   _server_init_set_bool acme_reset_choice no  --reset-acme --keep-acme ;;
            --yes)         _SI_YES=yes ;;
            --with-mail)   _server_init_set_bool mail yes ;;
            --no-mail)     _server_init_set_bool mail no ;;
            --with-backup) _server_init_set_bool backup yes ;;
            --no-backup)   _server_init_set_bool backup no ;;
            -h|--help)     _server_init_usage; exit 0 ;;
            # Only the flag's *name* is quoted back. An unknown flag is most
            # often a mistyped known one, and `--traefik-auths=admin:hunter2`
            # would otherwise put the password in the message and in every CI
            # log that keeps one. The name is what diagnoses a typo; the value
            # adds nothing, so it is never printed — for any flag, rather than
            # for a list of names that can always miss one.
            -*)            die "server init: unknown flag '${1%%=*}' (expected --apps-path=, --data-path=, --domain=, --email=, --traefik-auth=, --acme-staging, --reset-acme/--keep-acme, --with-mail/--no-mail, --with-backup/--no-backup, --yes)" ;;
            *)
                [ -z "$_SI_TARGET" ] \
                    || die "server init: unexpected argument '$1' (USER@HOST is given once)"
                # Stripped here as well as in ssh_target_parse: a target read
                # out of a CRLF file is otherwise named with a stray carriage
                # return in every message this command prints before connecting.
                _SI_TARGET="${1%$'\r'}"
                ;;
        esac
        shift
    done

    [ -n "$_SI_TARGET" ] \
        || die "server init: USER@HOST is required (the user kasbah deploys as is not optional)"

    # An empty --apps-path= is a stated intent that cannot be honoured, so it
    # fails rather than falling back to the default the operator just overrode.
    [ "$apps_given" = 1 ] || apps="$KASBAH_DEFAULT_APPS_PATH"
    _server_init_path apps-path "$apps" _SI_APPS_PATH
    [ "$data_given" = 1 ] || data="$_SI_APPS_PATH/data"
    _server_init_path data-path "$data" _SI_DATA_PATH

    return 0
}

# --- Resource limits ----------------------------------------------------------

# 90% of the host as anti-takeover ceilings (docs/server-setup.md). Integer
# arithmetic throughout, and that is the point: a float formatter renders 14,4
# under a comma locale, and a marker whose bytes depend on the operator's
# LC_NUMERIC cannot satisfy "a second run changes nothing".
#
#   cpu_limit  nproc x 0.9, one decimal — exact, since nproc x 9 is a count of
#              tenths and nothing is rounded away.
#   mem_limit  whole GiB (10485760 = 1 GiB in kB, x 10, so the x 0.9 and the
#              unit conversion floor in a single division), and whole MiB below
#              one GiB. The granularity changes rather than clamping: a floor of
#              1g on a 512 MiB host would be a ceiling above the machine's total
#              memory, which is the opposite of what a ceiling is for.
_server_limits() {
    local cores="$1" mem_kb="$2" tenths gib mib

    [[ "$cores" =~ ^[1-9][0-9]*$ ]] || die "internal: nproc '$cores' is not a core count"
    [[ "$mem_kb" =~ ^[1-9][0-9]*$ ]] || die "internal: MemTotal '$mem_kb' is not a size in kB"

    tenths=$((cores * 9))
    _SI_CPU_LIMIT="$((tenths / 10)).$((tenths % 10))"

    gib=$((mem_kb * 9 / 10485760))
    if [ "$gib" -ge 1 ]; then
        _SI_MEM_LIMIT="${gib}g"
    else
        mib=$((mem_kb * 9 / 10240))
        [ "$mib" -ge 1 ] || mib=1
        _SI_MEM_LIMIT="${mib}m"
    fi
}

# --- Server marker ------------------------------------------------------------

# The shape is docs/server-setup.md's. Built with jq so a path containing a
# quote is escaped rather than emitted as broken JSON, and so the key order is
# fixed — the file is compared byte for byte on every re-run.
#
# An existing marker is merged into, never replaced: this command owns five keys
# and knows nothing about the rest. `backup` is the one that matters today —
# Phase 8 puts a repo_base beside `enabled`, and a plain re-run of init must not
# take an operator's backup configuration with it. Same for any key a newer
# kasbah wrote and this one has never heard of.
_server_marker_json() {
    local existing="${6:-}"
    jq -n \
        --argjson existing "${existing:-null}" \
        --arg version "$1" \
        --arg apps_path "$2" \
        --arg data_path "$3" \
        --arg cpu_limit "$4" \
        --arg mem_limit "$5" \
        '(($existing // {}) + {
            kasbah_version: $version,
            apps_path: $apps_path,
            data_path: $data_path,
            cpu_limit: $cpu_limit,
            mem_limit: $mem_limit
        })
        | if has("backup") then . else . + { backup: { enabled: false } } end'
}

# --- Preflight ----------------------------------------------------------------

# Folds a remote step's key=value report into the fact table.
_si_absorb() {
    local line
    while IFS= read -r line; do
        line="${line%$'\r'}"
        case $line in *=*) _SI_FACT[${line%%=*}]="${line#*=}" ;; esac
    done <<<"$1"
    return 0
}

# One session, every fact, reported as key=value. The script always exits 0: the
# verdicts are local, so a non-zero status can only mean the transport failed.
_server_init_probe() {
    local out rc=0 line key
    local missing=()

    out=$(ssh_script "$_SI_APPS_PATH" "$_SI_DATA_PATH" "$KASBAH_APPS_POINTER" <<'REMOTE'
set -uo pipefail
export LC_ALL=C
apps=$1
data=$2
pointer=$3

# One line per value: the reader parses this output as a protocol, and a
# command's multi-line complaint would arrive as extra keys. The trailing space
# `flat` leaves behind is trimmed here rather than at every call site, because
# "16 " is not an integer to any test that later reads it.
kv() {
    local v="$2"
    while [ "${v: -1}" = " " ]; do v="${v% }"; done
    printf '%s=%s\n' "$1" "$v"
}
flat() { tr -d '\r' | tr '\n' ' '; }

kv user "$(id -un)"
kv group "$(id -gn)"

# `docker version` rather than `docker info`: the prerequisites table's ">= 24"
# is about the daemon, and this script never elevates, so a daemon that answers
# is also the "can run docker without sudo" row. Both halves are reported —
# which of the two rows failed depends on whether docker is there at all.
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

# flock is here for the same reason the others are: scripts/remote-deploy.sh
# holds the deploy lock with it and refuses to run without one, and a
# prerequisite discovered mid-deploy arrives after the rsync and the .env render.
for c in rsync openssl gzip flock; do
    if command -v "$c" >/dev/null 2>&1; then kv "have_$c" yes; else kv "have_$c" no; fi
done

# Asked, never assumed: a sudo that would prompt has nowhere to read a password
# from here, and the run must say so instead of hanging on it.
if sudo -n true >/dev/null 2>&1; then sudo_ok=yes; else sudo_ok=no; fi
kv sudo_nopasswd "$sudo_ok"

# The pointer's own spelling, reduced to the form every path flag is normalised
# into (see _server_init_path): CR and trailing blanks off, empty and `.`
# segments dropped, no trailing slash. Without this, a pointer reading
# `/srv/apps/` is a *different* string from `--apps-path=/srv/apps`, and the
# refusal below would prescribe re-running with the very flag it just refused.
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

# The server's own record of where it was prepared: its first line, normalised.
# Five states, because init's verdict differs for each — absent, present with a
# value, something other than a file, readable by nobody here, and a directory
# this user cannot enter, where "is there a pointer at all?" cannot be answered
# without root.
pointer_dir=${pointer%/*}
pointer_state=absent
pointer_value=""
# Root's eyes when this user's will not do, exactly as the apps path is asked
# about twice: `[ -e ]` answers "no" both for a file that is not there and for
# one behind a directory this user cannot traverse, and only one of those is an
# unprepared server. A pointer left at mode 600 is one no deploy user can read,
# which init repairs — but only once it knows what it says, because what it says
# may be another tree entirely. An empty read never stands in for that.
if [ -e "$pointer" ] && [ ! -f "$pointer" ]; then
    pointer_state=notfile
elif [ -f "$pointer" ]; then
    pointer_state=present
    if [ -r "$pointer" ]; then
        IFS= read -r pointer_value < "$pointer" || pointer_value=""
    elif [ "$sudo_ok" = yes ]; then
        pointer_value=$(sudo -n cat "$pointer" 2>/dev/null) || pointer_value=""
        pointer_value=${pointer_value%%$'\n'*}
        [ -n "$pointer_value" ] || pointer_state=unreadable
    else
        pointer_state=unreadable
    fi
elif [ -d "$pointer_dir" ] && [ ! -x "$pointer_dir" ]; then
    if [ "$sudo_ok" = yes ] && sudo -n test -e "$pointer" 2>/dev/null; then
        if sudo -n test -f "$pointer" 2>/dev/null; then
            pointer_state=present
            pointer_value=$(sudo -n cat "$pointer" 2>/dev/null) || pointer_value=""
            pointer_value=${pointer_value%%$'\n'*}
            [ -n "$pointer_value" ] || pointer_state=unreadable
        else
            pointer_state=notfile
        fi
    elif [ "$sudo_ok" != yes ]; then
        pointer_state=unreachable
    fi
fi
pointer_value=$(norm_path "$pointer_value")
kv pointer_state "$pointer_state"
kv pointer_value "$pointer_value"

# One state per path rather than a spread of booleans, because the states are
# mutually exclusive and each one has its own verdict. `dangling` is a real
# case: a symlink with nothing behind it answers -e with "no" and then fails
# `mkdir -p` with "File exists".
path_state() {
    if [ -L "$1" ] && [ ! -e "$1" ]; then printf dangling
    elif [ ! -e "$1" ];              then printf absent
    elif [ -d "$1" ];                then printf dir
    else                                  printf notdir
    fi
}

# The nearest ancestor this user can stat. Reached only when the path itself
# cannot be seen, and the difference between the two reasons for that is the
# whole point of the block below.
nearest_visible() {
    local p="$1"
    while [ ! -e "$p" ] && [ "$p" != / ]; do
        p=${p%/*}
        [ -n "$p" ] || p=/
    done
    printf '%s' "$p"
}

apps_state=$(path_state "$apps")
apps_base=$(nearest_visible "$apps")

# "The deploy user cannot see it" and "it is not there" are different facts, and
# only one of them may be elevated over. A directory behind a parent this user
# cannot traverse answers -e with false exactly like an absent one — and the
# chown that would follow runs as root, which can see it perfectly well. So the
# question is put a second time, with the eyes that would do the work.
apps_root_state=unknown
apps_root_owner=""
if [ "$apps_state" = absent ] && [ "$sudo_ok" = yes ]; then
    if sudo -n test -e "$apps" 2>/dev/null; then
        apps_root_state=exists
        apps_root_owner=$(sudo -n stat -c '%U:%G' "$apps" 2>/dev/null | flat)
    else
        apps_root_state=absent
    fi
fi
# Either answer makes it unusable: kasbah will not adopt what root can see and
# this user cannot, and it cannot work below a wall it cannot cross either,
# since everything under the apps path is written unelevated.
if [ "$apps_state" = absent ]; then
    if [ "$apps_root_state" = exists ]; then
        apps_state=unreachable
    elif [ "$apps_base" != "$apps" ] && [ ! -x "$apps_base" ]; then
        apps_state=unreachable
    fi
fi

kv apps_state "$apps_state"
kv apps_root_state "$apps_root_state"
kv apps_root_owner "$apps_root_owner"
kv apps_base "$apps_base"
kv apps_base_owner "$(stat -c '%U:%G' "$apps_base" 2>/dev/null | flat)"
kv apps_base_mode "$(stat -c '%a' "$apps_base" 2>/dev/null | flat)"

# -O asks the kernel whether this uid owns it — no stat parsing, no name
# lookup. The owner's *name* is only ever quoted back in a message.
if [ -O "$apps" ]; then kv apps_owned yes; else kv apps_owned no; fi
if [ -w "$apps" ] && [ -x "$apps" ]; then kv apps_writable yes; else kv apps_writable no; fi
kv apps_owner "$(stat -c '%U:%G' "$apps" 2>/dev/null | flat)"

# Why the write was refused, when the path is this user's own and still not
# writable: a read-only mount and a stripped mode are the same `-w` and want
# opposite advice. The errno is the only thing that tells them apart, so it is
# asked for directly. LC_ALL=C above keeps the wording stable.
apps_write_error=""
if [ "$apps_state" = dir ] && [ -O "$apps" ] && [ ! -w "$apps" ]; then
    apps_write_error=$(touch "$apps/.kasbah-write-probe" 2>&1 | flat)
    rm -f "$apps/.kasbah-write-probe" 2>/dev/null
fi
kv apps_write_error "$apps_write_error"

kv data_state "$(path_state "$data")"
if [ -w "$data" ] && [ -x "$data" ]; then kv data_writable yes; else kv data_writable no; fi
kv data_owner "$(stat -c '%U:%G' "$data" 2>/dev/null | flat)"

# A data path at or below the apps path needs no separate check: the apps path
# is either the deploy user's already or about to be, so everything from there
# down is creatable. One outside it has its own parent, which may belong to
# anyone. `--data-path` equal to `--apps-path` is inside, not outside — it is an
# odd configuration, not an error, and walking off to / for its parent produced
# a refusal that contradicted itself.
case $data in
    "$apps"|"$apps"/*) kv data_scope inside ;;
    *)                 kv data_scope outside ;;
esac
base=$(nearest_visible "$data")
kv data_base "$base"
if [ -w "$base" ] && [ -x "$base" ]; then kv data_base_writable yes; else kv data_base_writable no; fi

kv nproc "$(nproc 2>/dev/null | flat)"
# Read in the shell: awk is not on the prerequisites table, and this is the one
# fact the marker cannot be written without.
memtotal_kb=""
while read -r field value _; do
    if [ "$field" = "MemTotal:" ]; then memtotal_kb=$value; break; fi
done < /proc/meminfo
kv memtotal_kb "$memtotal_kb"

exit 0
REMOTE
    ) || rc=$?

    [ "$rc" -eq 0 ] \
        || die "could not collect prerequisites from $_SI_TARGET (the remote probe exited $rc)"
    [ -n "$out" ] \
        || die "the prerequisite probe on $_SI_TARGET succeeded and reported nothing (its output was lost, or the login shell swallowed it)"

    _SI_FACT=()
    _si_absorb "$out"

    # The key set is validated as a protocol before any verdict reads a value: a
    # fact that never arrived must not be absorbed into a passing check.
    for key in user group have_docker docker_server docker_error \
               compose_version have_rsync have_openssl have_gzip have_flock sudo_nopasswd \
               pointer_state pointer_value \
               apps_state apps_owned apps_writable apps_owner apps_write_error \
               apps_root_state apps_root_owner apps_base apps_base_owner apps_base_mode \
               data_state data_writable data_owner data_scope data_base data_base_writable \
               nproc memtotal_kb; do
        [ -n "${_SI_FACT[$key]+set}" ] || missing+=("$key")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        err "the prerequisite probe on $_SI_TARGET reported no ${missing[*]}"
        err_cont "the probe was truncated, or the remote shell rejected it — raw output:"
        while IFS= read -r line; do err_cont "| $line"; done <<<"$out"
        exit 1
    fi
    return 0
}

# Elevation happens on exactly one condition: the apps path does not exist, so
# root has to create it and hand it over. Everything below it is then written
# unelevated, which is what keeps /apps/data free of mixed ownership
# (docs/server-setup.md).
#
# The state this deliberately does *not* elevate for is a path that exists and
# belongs to somebody else. Chowning it would be a seizure: `--apps-path=/var/www`
# on a real VPS would hand a live document root to the deploy user, with its
# contents left in mixed ownership. That is a refusal below, naming the one
# command an operator can run if they meant it.
#
# `absent` means absent to root as well, not merely invisible to the deploy user
# — see the probe. The layout asks once more before it creates anything, because
# between this decision and that chown there is a window, and the chown is the
# irreversible half.
_server_init_elevation() {
    if [ "${_SI_FACT[apps_state]}" = absent ]; then
        _SI_ELEVATE=yes
    else
        _SI_ELEVATE=no
    fi
}

# The leading component of a version, with the `v` some tools print stripped:
# `docker compose version --short` says 2.29.7 on one machine and v2.29.7 on the
# next, and a preflight that reads the second as "not a number" would fail a
# host that is fine.
_si_major() {
    local v="${1#v}"
    printf '%s' "${v%%.*}"
}

# Every row of docs/server-setup.md's prerequisites table, checked against the
# probe. All failures are reported together — a server three rows short should
# cost one round trip, not three.
_server_init_preflight() {
    local target="$1" apps="$2" needs_sudo="$3"
    local rows=() cmd have major row
    local user="${_SI_FACT[user]}" group="${_SI_FACT[group]}"
    local owner="$user:$group"

    if [ "${_SI_FACT[have_docker]}" != yes ]; then
        rows+=("Docker >= 24 — no docker command on the remote."
               "  Install Docker Engine: https://docs.docker.com/engine/install/")
    elif [ -z "${_SI_FACT[docker_server]}" ]; then
        rows+=("the SSH user can run docker without sudo — \`docker version\` failed as ${_SI_FACT[user]}."
               "  ${_SI_FACT[docker_error]}"
               "  sudo usermod -aG docker ${_SI_FACT[user]}   (then open a new session)")
    else
        major="$(_si_major "${_SI_FACT[docker_server]}")"
        if ! [[ "$major" =~ ^[0-9]+$ ]] || [ "$major" -lt 24 ]; then
            rows+=("Docker >= 24 — the daemon reports ${_SI_FACT[docker_server]}."
                   "  Upgrade Docker Engine: https://docs.docker.com/engine/install/")
        fi
    fi

    # Major >= 2, not == 2: v2 is a floor, not a version to match. The rig
    # already ships Compose 5.4.0 (docs/phases/01-rig.md).
    major="$(_si_major "${_SI_FACT[compose_version]}")"
    if [ -z "${_SI_FACT[compose_version]}" ]; then
        rows+=("Docker Compose v2 — \`docker compose version\` produced nothing."
               "  The compose plugin is missing: install docker-compose-plugin.")
    elif ! [[ "$major" =~ ^[0-9]+$ ]] || [ "$major" -lt 2 ]; then
        rows+=("Docker Compose v2 — the plugin reports ${_SI_FACT[compose_version]}."
               "  kasbah's compose files need include: and v2 syntax.")
    fi

    for cmd in rsync openssl gzip; do
        have="${_SI_FACT[have_$cmd]}"
        if [ "$have" != yes ]; then
            rows+=("rsync, openssl, gzip on the remote — $cmd is missing."
                   "  deploy and env setup both need it; install it with the distro's package manager.")
        fi
    done

    # Its own row, because it is the one tool the shipped scripts use that is
    # not coreutils, and because the alternative to catching it here is catching
    # it in rd_lock, mid-deploy, after the files are already on the server.
    if [ "${_SI_FACT[have_flock]}" != yes ]; then
        rows+=("flock (util-linux) on the remote — it is missing."
               "  scripts/remote-deploy.sh takes the deploy lock with it and will not run"
               "  without one; install util-linux with the distro's package manager.")
    fi

    # The apps path, in the four states it can be in. Only the first is
    # elevated over; the rest are the operator's to resolve, because kasbah
    # taking ownership of a directory it did not create is not a repair.
    case "${_SI_FACT[apps_state]}" in
        absent)
            if [ "${_SI_FACT[sudo_nopasswd]}" != yes ]; then
                rows+=("passwordless sudo — \`sudo -n true\` failed as $user."
                       "  $apps does not exist, and it lives outside the deploy user's home,"
                       "  so only root can create it. Grant NOPASSWD sudo, or run this once"
                       "  by hand and re-run init:"
                       "  ssh $target 'sudo mkdir -p $apps && sudo chown $owner $apps'")
            fi
            ;;
        dangling)
            rows+=("$apps is a symlink to nothing."
                   "  Point it somewhere or remove it — \`mkdir -p\` fails on it with"
                   "  \"File exists\", which is not a diagnosis anybody enjoys.")
            ;;
        unreachable)
            if [ "${_SI_FACT[apps_root_state]}" = exists ]; then
                rows+=("$apps exists and belongs to ${_SI_FACT[apps_root_owner]}, and $user cannot see it."
                       "  Only root can, which is why this is a refusal: kasbah would have to take the"
                       "  directory over to use it, and it never takes over one it did not create.")
            else
                rows+=("$apps cannot be reached by $user."
                       "  ${_SI_FACT[apps_base]} is not traversable by them (owner ${_SI_FACT[apps_base_owner]}, mode ${_SI_FACT[apps_base_mode]}),"
                       "  so kasbah cannot even tell whether $apps exists.")
            fi
            rows+=("  Everything below the apps path is written as $user, so a path they cannot"
                   "  enter is no use even once it exists. Pick one they can, with --apps-path=<dir>.")
            ;;
        notdir)
            rows+=("$apps exists and is not a directory."
                   "  Remove it, or point init elsewhere with --apps-path=<dir>.")
            ;;
        dir)
            if [ "${_SI_FACT[apps_owned]}" != yes ]; then
                rows+=("$apps already exists and belongs to ${_SI_FACT[apps_owner]}, not $user."
                       "  kasbah only elevates to create the apps path; it never takes over one"
                       "  it did not create, because everything below would end up in mixed"
                       "  ownership. If this path really is meant for kasbah, hand it over:"
                       "  ssh $target 'sudo chown $owner $apps'")
            elif [ "${_SI_FACT[apps_writable]}" != yes ]; then
                case "${_SI_FACT[apps_write_error]}" in
                    *"Read-only file system"*)
                        rows+=("$apps belongs to $user and is on a read-only filesystem."
                               "  ${_SI_FACT[apps_write_error]}"
                               "  No mode change fixes that: remount it read-write, or pick another"
                               "  path with --apps-path=<dir>.")
                        ;;
                    *)
                        rows+=("$apps belongs to $user but is not writable by them."
                               "  ssh $target 'chmod u+rwx $apps'")
                        ;;
                esac
            fi
            ;;
    esac

    # The data path is created unelevated like everything else, so what matters
    # is whether the deploy user can write where it is going. Below the apps
    # path that is settled by the row above; outside it, it is a question of its
    # own — and one worth asking here rather than half way through the layout.
    case "${_SI_FACT[data_state]}" in
        dangling)
            rows+=("the data path $_SI_DATA_PATH is a symlink to nothing."
                   "  Point it somewhere or remove it.")
            ;;
        notdir)
            rows+=("the data path $_SI_DATA_PATH exists and is not a directory."
                   "  Remove it, or point init elsewhere with --data-path=<dir>.")
            ;;
        dir)
            if [ "${_SI_FACT[data_writable]}" != yes ]; then
                rows+=("the data path $_SI_DATA_PATH exists and is not writable by $user (owner ${_SI_FACT[data_owner]})."
                       "  ssh $target 'sudo chown $owner $_SI_DATA_PATH'")
            fi
            ;;
        absent)
            if [ "${_SI_FACT[data_scope]}" = outside ] \
                && [ "${_SI_FACT[data_base_writable]}" != yes ]; then
                rows+=("the data path $_SI_DATA_PATH cannot be created: ${_SI_FACT[data_base]} is not writable by $user."
                       "  It sits outside $apps, so kasbah cannot get there unelevated. Create it once:"
                       "  ssh $target 'sudo mkdir -p $_SI_DATA_PATH && sudo chown $owner $_SI_DATA_PATH'")
            fi
            ;;
    esac

    if ! [[ "${_SI_FACT[nproc]}" =~ ^[1-9][0-9]*$ ]]; then
        rows+=("resource limits — the remote reported nproc='${_SI_FACT[nproc]}'."
               "  The marker's cpu_limit is 90% of that and cannot be computed.")
    fi
    if ! [[ "${_SI_FACT[memtotal_kb]}" =~ ^[1-9][0-9]*$ ]]; then
        rows+=("resource limits — /proc/meminfo reported MemTotal='${_SI_FACT[memtotal_kb]}'."
               "  The marker's mem_limit is 90% of that and cannot be computed.")
    fi

    [ "${#rows[@]}" -gt 0 ] || return 0

    err "$target does not meet the prerequisites for kasbah server init:"
    for row in "${rows[@]}"; do err_cont "$row"; done
    err_cont "kasbah checks prerequisites and never installs them — see docs/server-setup.md"
    exit 1
}

# --- The marker already on the server -------------------------------------------

# Read before anything is created, because what it says can stop the run.
# Absence reports itself with exit 3 rather than with empty output, and the two
# are then treated differently: no marker is the ordinary first run, while a
# marker that exists and holds nothing usable is a refusal like any other
# unreadable one. A zero-byte file is not an invitation to overwrite.
_server_init_read_marker() {
    local out rc=0

    out=$(ssh_script "$_SI_APPS_PATH" <<'REMOTE'
set -uo pipefail
marker="$1/.kasbah/server.json"

if [ -e "$marker" ] && [ ! -f "$marker" ]; then
    printf 'remote: %s exists and is not a regular file\n' "$marker" >&2
    exit 1
fi
[ -f "$marker" ] || exit 3
cat "$marker"
REMOTE
    ) || rc=$?

    case $rc in
        0) _SI_MARKER_PRESENT=yes; _SI_MARKER_EXISTING="$out" ;;
        3) _SI_MARKER_PRESENT=no;  _SI_MARKER_EXISTING="" ;;
        *) die "could not read $_SI_APPS_PATH/.kasbah/server.json on $_SI_TARGET (the remote step exited $rc, see above)" ;;
    esac
    return 0
}

# docs/server-setup.md's compatibility rule, the half that has a remedy: a
# kasbah binary operates on a VPS whose marker shares its major version, and an
# older tool facing a newer marker refuses rather than writing fields it does
# not understand. (The mirror case — newer tool, older-major marker — is
# specified as "refuse until `kasbah migrate`", and that command does not exist
# yet; refusing with no way forward would be worse than the drift.)
_server_init_check_marker() {
    local path="$_SI_APPS_PATH/.kasbah/server.json" version major ours

    [ "$_SI_MARKER_PRESENT" = yes ] || return 0

    if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$_SI_MARKER_EXISTING"; then
        err "$path on $_SI_TARGET is not a JSON object"
        err_cont "kasbah will not overwrite a marker it cannot read — look at it, then remove"
        err_cont "it and re-run to start the server's record over"
        exit 1
    fi

    version="$(jq -r '.kasbah_version // "" | tostring' <<<"$_SI_MARKER_EXISTING")"
    major="$(_si_major "$version")"
    ours="$(_si_major "$KASBAH_VERSION")"
    if ! [[ "$major" =~ ^[0-9]+$ ]] || ! [[ "$ours" =~ ^[0-9]+$ ]]; then
        warn "$path records kasbah_version '$version'; this kasbah is $KASBAH_VERSION"
        warn "the two cannot be compared, so no compatibility check was made"
        return 0
    fi
    if [ "$major" -gt "$ours" ]; then
        err "$path was written by kasbah $version, and this is kasbah $KASBAH_VERSION"
        err_cont "a newer major on the server means fields this binary does not know about"
        err_cont "upgrade kasbah locally, or point at a server this version manages"
        exit 1
    fi
    return 0
}

# --- The pointer at /etc/kasbah/apps-path --------------------------------------

# One kasbah instance per server, because one Traefik holds :80 and :443 — so a
# server that already carries a pointer is refused a *different* apps path here,
# before anything is created. Re-running init at the path the pointer names is
# the ordinary idempotent case and passes straight through.
#
# The refusal is what `lib/marker.sh`'s exit-4 message used to be able only to
# warn about: rendering a second stack under the frozen `traefik` compose
# project recreates the running proxy against it, off the other tree's dynamic/
# and acme.json, and takes every site on the host down.
_server_init_check_pointer() {
    local state="${_SI_FACT[pointer_state]}" value="${_SI_FACT[pointer_value]}"

    case $state in
        absent) return 0 ;;
        notfile)
            err "$KASBAH_APPS_POINTER on $_SI_TARGET exists and is not a regular file"
            err_cont "that path is the server's record of where it was prepared, and kasbah"
            err_cont "writes one absolute path there. Look at it, remove it, and re-run."
            exit 1
            ;;
        unreachable)
            err "${KASBAH_APPS_POINTER%/*} on $_SI_TARGET cannot be entered by ${_SI_FACT[user]}, and there is no sudo to look with"
            err_cont "so whether this server already records an apps path cannot be told, and"
            err_cont "this run would prepare $_SI_APPS_PATH. If the two differ that stands a second"
            err_cont "Traefik beside the one already holding :80 and :443, so kasbah stops here."
            err_cont "Make it traversable — it is mode 755 on a server kasbah prepared:"
            err_cont "  ssh $_SI_TARGET 'sudo chmod 755 ${KASBAH_APPS_POINTER%/*}'"
            exit 1
            ;;
        unreadable)
            err "$KASBAH_APPS_POINTER on $_SI_TARGET cannot be read, by ${_SI_FACT[user]} or by root"
            err_cont "it records where this server was prepared, and this run would prepare"
            err_cont "$_SI_APPS_PATH — which, if the two differ, stands a second Traefik beside the"
            err_cont "one already holding :80 and :443. kasbah will not guess. Read the file"
            err_cont "yourself and remove it if $_SI_APPS_PATH is the tree this server runs from."
            exit 1
            ;;
    esac

    case $value in
        /?*) ;;
        *)
            err "$KASBAH_APPS_POINTER on $_SI_TARGET holds '$value', which is not an absolute path"
            err_cont "kasbah will not write over a pointer it cannot read: whatever apps path"
            err_cont "this server was prepared at, that file was meant to name it, and this run"
            err_cont "would prepare $_SI_APPS_PATH instead. If $_SI_APPS_PATH is the tree this"
            err_cont "server really runs from, remove $KASBAH_APPS_POINTER and re-run — init"
            err_cont "writes it again."
            exit 1
            ;;
    esac

    [ "$value" != "$_SI_APPS_PATH" ] || return 0

    err "$_SI_TARGET is already prepared at $value, and this run would prepare it at $_SI_APPS_PATH"
    err_cont "$KASBAH_APPS_POINTER records $value. One server runs one kasbah, because one"
    err_cont "Traefik holds :80 and :443: preparing a second tree here would render a rival"
    err_cont "stack under the frozen 'traefik' compose project, recreate the running proxy"
    err_cont "against it — off this tree's dynamic/ and acme.json rather than $value's —"
    err_cont "and take every site on the server down. Nothing has been changed."
    err_cont "To manage the server that is there, re-run with --apps-path set to the directory"
    err_cont "$value resolves to — for a plain path that is $value itself, and kasbah's flags"
    err_cont "take no '..' segment — or with no --apps-path if that is the default."
    err_cont "To move the server to $_SI_APPS_PATH, take the existing stack down first and"
    err_cont "remove $KASBAH_APPS_POINTER."
    exit 1
}

# Written immediately after the marker, and never before it: the marker is the
# "init completed" signal, so a run that dies earlier leaves no pointer and the
# /apps fallback still describes the server truthfully.
#
# Root-owned, mode 644, one absolute path on a line — every project command
# reads it as whatever user it deploys as. Left alone when it already says that,
# down to the mode and the owner, so a re-run on a host whose sudo has since
# been taken away still succeeds.
_server_init_pointer() {
    local out rc=0

    out=$(ssh_script "$_SI_APPS_PATH" "$KASBAH_APPS_POINTER" <<'REMOTE'
set -uo pipefail
export LC_ALL=C
apps=$1
pointer=$2
dir=${pointer%/*}

# The staging file goes with the failure: every path out of this step from here
# on has already created it, and a run that stops half way must not leave a copy
# of the apps path in /tmp on the server.
staged=""
fail() { [ -z "$staged" ] || rm -f "$staged"; printf 'remote: %s\n' "$*" >&2; exit 1; }

if [ -e "$pointer" ] && [ ! -f "$pointer" ]; then
    fail "$pointer exists and is not a regular file"
fi

# Already right, down to the mode and the owner. `-r` first, because a pointer
# this user cannot read is one to rewrite rather than one to read: 644 and root
# are half of what "already right" means, and a failed redirect would say so
# only in stderr nobody is reading.
if [ -f "$pointer" ] && [ -r "$pointer" ]; then
    current=""
    IFS= read -r current < "$pointer" || current=""
    current=${current%$'\r'}
    meta=$(stat -c '%a %u' "$pointer" 2>/dev/null) || meta=""
    if [ "$current" = "$apps" ] && [ "$meta" = "644 0" ]; then
        printf 'pointer=unchanged\n'
        exit 0
    fi
fi

# Asked, never assumed, and reported rather than refused here: what a missing
# sudo costs depends on the apps path, and that verdict is the caller's.
sudo_cmd=""
if [ "$(id -u)" != 0 ]; then
    if sudo -n true >/dev/null 2>&1; then
        sudo_cmd="sudo -n"
    else
        printf 'pointer=nosudo\n'
        exit 0
    fi
fi

# Staged where this user can write, then installed as root and renamed into
# place: a command reading the pointer must never catch a half-written one.
staged="${TMPDIR:-/tmp}/kasbah-apps-path.$$"
tmp="$pointer.tmp.$$"
printf '%s\n' "$apps" > "$staged" || fail "could not stage the pointer at $staged"
$sudo_cmd mkdir -p "$dir" || fail "sudo mkdir -p $dir failed"
$sudo_cmd chmod 755 "$dir" || fail "sudo chmod 755 $dir failed"
$sudo_cmd cp "$staged" "$tmp" || fail "could not write $tmp"
rm -f "$staged"
$sudo_cmd chown 0:0 "$tmp" || fail "could not give $tmp to root"
$sudo_cmd chmod 644 "$tmp" || fail "could not set mode 644 on $tmp"
$sudo_cmd mv -f "$tmp" "$pointer" || fail "could not install $pointer"
printf 'pointer=written\n'
exit 0
REMOTE
    ) || rc=$?

    [ "$rc" -eq 0 ] \
        || die "could not write $KASBAH_APPS_POINTER on $_SI_TARGET (the remote step exited $rc, see above)"

    _si_absorb_checked "the pointer step" "$out" pointer
    _server_init_pointer_verdict
}

# What a pointer that could not be written costs, which is not the same
# everywhere: at the default apps path every project command finds the server
# anyway, so the pointer is a convenience and its absence is a warning. Anywhere
# else it is the only thing that makes the server discoverable, and a server
# prepared where nothing can find it is the bug this file exists to close.
_server_init_pointer_verdict() {
    local state="${_SI_FACT[pointer]}" user="${_SI_FACT[user]}"

    case $state in
        written|unchanged) return 0 ;;
        nosudo) ;;
        *) die "the pointer step on $_SI_TARGET reported '$state', which this kasbah does not know" ;;
    esac

    if [ "$_SI_APPS_PATH" != "$KASBAH_DEFAULT_APPS_PATH" ]; then
        err "could not write $KASBAH_APPS_POINTER on $_SI_TARGET — \`sudo -n\` is not available to $user"
        err_cont "$_SI_TARGET is prepared at $_SI_APPS_PATH and nothing can find it: that file is"
        err_cont "how \`kasbah deploy\` and \`kasbah env\` discover a server prepared anywhere other"
        err_cont "than $KASBAH_DEFAULT_APPS_PATH. Without it they look under $KASBAH_DEFAULT_APPS_PATH, find no marker"
        err_cont "and exit 4. Grant NOPASSWD sudo and re-run, or create it once by hand:"
        err_cont "  ssh $_SI_TARGET 'sudo mkdir -p ${KASBAH_APPS_POINTER%/*} && printf \"%s\\n\" $_SI_APPS_PATH | sudo tee $KASBAH_APPS_POINTER >/dev/null && sudo chmod 644 $KASBAH_APPS_POINTER'"
        exit 1
    fi

    warn "could not write $KASBAH_APPS_POINTER on $_SI_TARGET — \`sudo -n\` is not available to $user"
    warn "nothing is broken: $_SI_APPS_PATH is where every project command looks when there is no"
    warn "pointer. It would only matter if this server were ever re-prepared elsewhere."
    return 0
}

# --- Remote layout ------------------------------------------------------------

# Creates everything except the marker, in the order docs/server-setup.md fixes:
# the apps path (elevated, once), the tree below it (unelevated), then acme.json
# as a file.
#
# The marker is a separate step on purpose. Its presence is the "init completed"
# signal, so whatever a later unit adds — rendering the Traefik stack, starting
# it — belongs between this function and _server_init_marker, never after it.
_server_init_layout() {
    local out rc=0

    out=$(ssh_script "$_SI_APPS_PATH" "$_SI_DATA_PATH" "$_SI_ELEVATE" \
                     "${_SI_FACT[user]}:${_SI_FACT[group]}" <<'REMOTE'
set -uo pipefail
export LC_ALL=C
apps=$1
data=$2
elevate=$3
owner=$4

fail() { printf 'remote: %s\n' "$*" >&2; exit 1; }

if [ "$elevate" = yes ]; then
    # Asked with root's eyes, immediately before acting on the answer. The
    # preflight decided this path was absent; if root disagrees now — a race, or
    # anything the earlier look got wrong — the chown below would be a seizure,
    # so it does not happen.
    if sudo -n test -e "$apps"; then
        fail "$apps exists after all (root sees it, owner $(sudo -n stat -c '%U:%G' "$apps" 2>/dev/null)) — kasbah creates the apps path, it never takes over one that is already there"
    fi
    # -p for the parents, and a bare mkdir for the component being taken
    # ownership of: an existing directory is then EEXIST and an error, instead
    # of a silent no-op followed by a chown of somebody else's directory.
    parent=${apps%/*}
    [ -n "$parent" ] || parent=/
    sudo -n mkdir -p "$parent" || fail "sudo mkdir -p $parent failed"
    sudo -n mkdir "$apps" || fail "sudo mkdir $apps failed — it exists already, and kasbah only chowns what it created"
    sudo -n chown "$owner" "$apps" || fail "sudo chown $owner $apps failed"
    printf 'elevated=yes\n'
else
    printf 'elevated=no\n'
fi

for d in "$apps/.kasbah" "$apps/backups" "$apps/traefik/dynamic" \
         "$data" "$data/traefik/letsencrypt"; do
    mkdir -p "$d" || fail "could not create $d"
done

# Docker materialises a missing bind-mount source as a *directory*, which breaks
# Traefik and later DMS, so the file exists before anything can mount it. The
# guard is -f: a directory answers -e and -r alike (docs/phases/01-rig.md).
acme="$data/traefik/letsencrypt/acme.json"
if [ -e "$acme" ] && [ ! -f "$acme" ]; then
    fail "$acme exists and is not a regular file — Traefik needs a file there. Remove it (rm -rf '$acme') and re-run."
fi
if [ -f "$acme" ]; then
    printf 'acme=existed\n'
else
    touch "$acme" || fail "could not create $acme"
    printf 'acme=created\n'
fi
chmod 600 "$acme" || fail "could not set mode 600 on $acme"

exit 0
REMOTE
    ) || rc=$?

    [ "$rc" -eq 0 ] \
        || die "could not lay out $_SI_APPS_PATH on $_SI_TARGET (the remote step exited $rc, see above)"

    _SI_FACT[elevated]=""
    _SI_FACT[acme]=""
    _si_absorb "$out"
}

# The last thing init does. Written only when its content differs, so a re-run
# does not even move the mtime.
_server_init_marker() {
    local marker_json="$1" out rc=0

    out=$(ssh_script "$_SI_APPS_PATH" "$marker_json" <<'REMOTE'
set -uo pipefail
apps=$1
marker_json=$2

fail() { printf 'remote: %s\n' "$*" >&2; exit 1; }

marker="$apps/.kasbah/server.json"
if [ -e "$marker" ] && [ ! -f "$marker" ]; then
    fail "$marker exists and is not a regular file"
fi
current=""
[ ! -f "$marker" ] || current=$(cat "$marker") || fail "could not read $marker"
if [ "$current" = "$marker_json" ]; then
    printf 'marker=unchanged\n'
else
    # Rendered and renamed: another kasbah run reading the marker must never
    # catch a half-written one.
    tmp="$marker.tmp.$$"
    printf '%s\n' "$marker_json" > "$tmp" || fail "could not write $tmp"
    chmod 644 "$tmp" || fail "could not set mode 644 on $tmp"
    mv -f "$tmp" "$marker" || fail "could not install $marker"
    printf 'marker=written\n'
fi

exit 0
REMOTE
    ) || rc=$?

    [ "$rc" -eq 0 ] \
        || die "could not write the server marker on $_SI_TARGET (the remote step exited $rc, see above)"

    _SI_FACT[marker]=""
    _si_absorb "$out"
}

# --- The Traefik stack ----------------------------------------------------------

# Three files, rendered on the workstation and shipped: compose.yml, the static
# traefik.yml, and the dynamic dynamic/_shared.yml. They are rendered here and
# not on the far side because **Traefik expands environment variables in
# neither its static nor its dynamic configuration** — the ACME address, the
# dashboard domain and the basic-auth hash have to arrive as literal bytes.
# That is also why the stack has no `.env`: with nothing left for compose to
# interpolate, a file of variables would be a knob the container never receives
# (docs/phases/01-rig.md).

# A remote step's output, checked as a protocol before any of it is read: a
# fact that never arrived must not be absorbed into a passing verdict
# (docs/phases/01-rig.md, from 1.3).
_si_absorb_checked() {
    local _ac_what="$1" _ac_out="$2"; shift 2
    local _ac_key _ac_line
    local _ac_missing=()

    _si_absorb "$_ac_out"
    for _ac_key in "$@"; do
        [ -n "${_SI_FACT[$_ac_key]+set}" ] || _ac_missing+=("$_ac_key")
    done
    if [ "${#_ac_missing[@]}" -gt 0 ]; then
        err "$_ac_what on $_SI_TARGET reported no ${_ac_missing[*]}"
        err_cont "the step was truncated, or the remote shell rejected it — raw output:"
        while IFS= read -r _ac_line; do err_cont "| $_ac_line"; done <<<"$_ac_out"
        exit 1
    fi
    return 0
}

# What is on the server now, so the fresh render can be compared against it
# byte for byte: an unchanged file is not shipped, and Traefik is not restarted
# (docs/server-setup.md, idempotency rules). The same read is where a re-run
# recovers the dashboard credentials it must not regenerate, and where it learns
# whether acme.json holds anything — every ACME decision below turns on that,
# and asking later would mean a second round trip after the questions.
_server_init_read_traefik() {
    local out rc=0 rel enc dec

    out=$(ssh_script "$_SI_APPS_PATH" "$_SI_DATA_PATH" <<'REMOTE'
set -uo pipefail
export LC_ALL=C
dir="$1/traefik"
acme="$2/traefik/letsencrypt/acme.json"

# Base64 on one line: this output is a key=value protocol, and a YAML file sent
# raw would arrive as a dozen keys. openssl is on the prerequisites table;
# coreutils' `base64 -w0` is not. An unreadable or absent file reports empty,
# which reads downstream as "nothing to compare against" — the file is then
# shipped, which is the safe direction.
emit() {
    local enc=""
    if [ -f "$2" ]; then enc=$(openssl base64 -A -in "$2" 2>/dev/null) || enc=""; fi
    printf '%s=%s\n' "$1" "$enc"
}

emit traefik_compose_b64 "$dir/compose.yml"
emit traefik_static_b64  "$dir/traefik.yml"
emit traefik_shared_b64  "$dir/dynamic/_shared.yml"

# Whether there are certificates to lose, which is the question an ACME
# endpoint switch actually turns on — the config says what is configured, only
# the store says what is stored. Reported as a state rather than a byte count:
# nothing downstream wants the size, and "not a regular file" is a fourth
# answer that a number cannot carry.
if   [ ! -e "$acme" ]; then printf 'acme_store=absent\n'
elif [ ! -f "$acme" ]; then printf 'acme_store=notfile\n'
elif [ -s "$acme" ];  then printf 'acme_store=nonempty\n'
else                       printf 'acme_store=empty\n'
fi
exit 0
REMOTE
    ) || rc=$?

    [ "$rc" -eq 0 ] \
        || die "could not read the Traefik stack on $_SI_TARGET (the remote step exited $rc, see above)"

    _si_absorb_checked "the Traefik stack read" "$out" \
        traefik_compose_b64 traefik_static_b64 traefik_shared_b64 acme_store

    _SI_ACME_STORE="${_SI_FACT[acme_store]}"
    case $_SI_ACME_STORE in
        absent|notfile|empty|nonempty) ;;
        *) die "the Traefik stack read on $_SI_TARGET reported acme_store='$_SI_ACME_STORE', which this kasbah does not know" ;;
    esac

    _SI_TRAEFIK_CURRENT=()
    for rel in "${_SI_TRAEFIK_FILES[@]}"; do
        enc="${_SI_FACT[${_SI_TRAEFIK_KEY[$rel]}]}"
        # The `printf x` sentinel keeps trailing newlines, which $(…) strips —
        # without it every comparison below would be against a file that is one
        # byte shorter than the one on the server.
        dec=$( { printf '%s' "$enc" | base64 -d 2>/dev/null; printf x; } )
        _SI_TRAEFIK_CURRENT[$rel]="${dec%x}"
    done
    return 0
}

# One keyed lookup against a YAML document held in a variable. Exit 2 means the
# document did not parse, which every caller keeps distinct from "the key is not
# there": kasbah reuses what is on the server rather than regenerating it, and
# a file it cannot read is a file it cannot reuse from.
_si_yaml_get() {
    local _yg_content="$1" _yg_filter="$2" _yg_out="$3" _yg_val=""

    printf -v "$_yg_out" '%s' ""
    [ -n "$_yg_content" ] || return 0
    _yg_val=$(printf '%s' "$_yg_content" | yq -r "$_yg_filter" 2>/dev/null) || return 2
    case $_yg_val in null) _yg_val="" ;; esac
    printf -v "$_yg_out" '%s' "${_yg_val%$'\r'}"
    return 0
}

# The dashboard's own basic-auth entry. bcrypt salts randomly, so hashing the
# same password twice gives different bytes: without reuse, every re-run would
# rewrite the file and "a second run changes nothing" would be unsatisfiable.
#
# Keyed to the middleware that carries it, not scanned for. docs/traefik.md
# invites operators to add their own middlewares under dynamic/, and a
# basicAuth of theirs sorting above traefik-dashboard-auth would otherwise be
# adopted as the dashboard's — quietly replacing the dashboard credentials on
# the next re-run, and reporting it as reuse. Going through yq also reads the
# inline `users: ["…"]` spelling, which a line scanner does not.
_si_extract_auth() {
    local _xa_content="$1" _xa_out="$2" _xa_entry="" _xa_count="" _xa_rc=0
    local _xa_users='(.http.middlewares["traefik-dashboard-auth"].basicAuth.users // [])'

    _si_yaml_get "$_xa_content" "$_xa_users | length"    _xa_count || _xa_rc=$?
    [ "$_xa_rc" -eq 0 ] || return "$_xa_rc"
    _si_yaml_get "$_xa_content" "$_xa_users | .[0] // \"\"" _xa_entry || _xa_rc=$?
    [ "$_xa_rc" -eq 0 ] || return "$_xa_rc"

    printf -v "$_xa_out" '%s' ""
    case $_xa_count in ''|0) return 0 ;; esac

    # An htpasswd entry, whatever the algorithm: reuse reproduces what is in
    # effect, so an operator who moved the dashboard to apr1 keeps apr1. What it
    # will not do is carry something shapeless back into the file and call it
    # credentials.
    case $_xa_entry in
        *$'\n'*|'') _xa_entry="" ;;
        *:*)        printf -v "$_xa_out" '%s' "$_xa_entry"; return 0 ;;
        *)          ;;
    esac
    err "the dashboard credentials in dynamic/_shared.yml are not an htpasswd entry"
    err_cont "traefik-dashboard-auth.basicAuth.users[0] holds '${_xa_entry:-<not a string>}', and kasbah"
    err_cont "reuses that entry verbatim rather than regenerating it — it cannot reuse this one."
    err_cont "Fix it, or pass --traefik-auth=user:pass to set the credentials outright."
    exit 1
}

# The apex the dashboard router already hangs off. Read back off the server
# rather than stored in the marker, so the file in effect stays the single
# source of truth. A rule the operator rewrote into some other shape simply
# yields nothing, and the flag or the prompt answers instead.
_si_extract_domain() {
    local _xd_content="$1" _xd_out="$2" _xd_rule="" _xd_rc=0
    local _xd_re='^Host\(`traefik\.([^`]+)`\)$'

    _si_yaml_get "$_xd_content" '.http.routers["traefik-dashboard"].rule // ""' _xd_rule \
        || _xd_rc=$?
    [ "$_xd_rc" -eq 0 ] || return "$_xd_rc"

    printf -v "$_xd_out" '%s' ""
    if [[ "$_xd_rule" =~ $_xd_re ]]; then
        printf -v "$_xd_out" '%s' "${BASH_REMATCH[1]}"
    fi
    return 0
}

_si_extract_email() {
    local _xe_content="$1" _xe_out="$2"
    _si_yaml_get "$_xe_content" \
        '.certificatesResolvers.letsencrypt.acme.email // ""' "$_xe_out"
}

# The endpoint the stack on the server is *configured* with — which is not the
# same fact as the one that issued the certificates sitting in acme.json, and
# the gap between them is what the caller has to reason about. Unlike the three
# values beside it this one is never reused: the flag decides the endpoint on
# every run, and this is read only to be compared against it.
_si_extract_ca() {
    local _xc_content="$1" _xc_out="$2"
    _si_yaml_get "$_xc_content" \
        '.certificatesResolvers.letsencrypt.acme.caServer // ""' "$_xc_out"
}

# bcrypt, as docs/cli.md promises. apr1 via `openssl passwd` was rejected as a
# real weakening — salted MD5, ~1k iterations — for no gain.
#
# The password arrives on stdin (`-i`) rather than in argv (`-b`): `htpasswd
# -nbB user pass` puts the password in the process table, where any other user
# of the workstation can read it for as long as it runs.
_si_bcrypt() {
    local _bc_user="$1" _bc_pass="$2" _bc_out="$3"
    local _bc_line="" _bc_rc=0
    local _bc_re=':\$2[aby]\$[0-9]{2}\$'

    if command -v htpasswd >/dev/null 2>&1; then
        _bc_line=$(printf '%s\n' "$_bc_pass" | htpasswd -niB "$_bc_user") || _bc_rc=$?
    elif command -v docker >/dev/null 2>&1; then
        _bc_line=$(printf '%s\n' "$_bc_pass" \
            | docker run --rm -i httpd:2-alpine htpasswd -niB "$_bc_user") || _bc_rc=$?
    else
        err "cannot hash the dashboard password: no htpasswd on PATH, and no docker to borrow one from"
        err_cont "install apache2-utils (Debian/Ubuntu) or httpd-tools (RHEL), or make"
        err_cont "\`docker run --rm httpd:2-alpine\` work here"
        exit 1
    fi

    _bc_line="${_bc_line%$'\r'}"
    if [ "$_bc_rc" -ne 0 ] || ! [[ "$_bc_line" =~ $_bc_re ]] \
       || [ "${_bc_line%%:*}" != "$_bc_user" ] || [ "${_bc_line#*$'\n'}" != "$_bc_line" ]; then
        err "could not produce a bcrypt hash for the dashboard password (htpasswd exited $_bc_rc)"
        err_cont "expected one line of '$_bc_user:\$2y\$..' — see htpasswd's own error above"
        exit 1
    fi
    printf -v "$_bc_out" '%s' "$_bc_line"
    return 0
}

# Flag wins, else what the server already has, else ask. The middle branch is
# the one that makes a re-run a no-op, and it is why these questions are put
# after the connection rather than beside the mail and backup ones: whether
# they need asking at all is a fact about the server.
#
# Nothing is created before this returns, so an unanswerable question still
# costs nothing.
# A file kasbah is about to reuse a value out of, that it could not read.
# Refused rather than worked around: the alternative is inventing a fresh value
# and overwriting whatever the operator had, which for the dashboard means
# rotating their credentials because their YAML had a typo in it.
_si_unreadable_stack() {
    local _us_file="$1" _us_flag="$2"
    err "$_SI_APPS_PATH/traefik/$_us_file on $_SI_TARGET could not be read as YAML"
    err_cont "kasbah reuses what is already on the server instead of regenerating it, so it"
    err_cont "will not guess past a file it cannot parse — that would overwrite whatever is"
    err_cont "in there. Fix the file, or delete it, or pass $_us_flag to settle the value."
    exit 1
}

_server_init_traefik_values() {
    local shared="${_SI_TRAEFIK_CURRENT[dynamic/_shared.yml]}"
    local static="${_SI_TRAEFIK_CURRENT[traefik.yml]}"
    local stored_domain="" stored_email="" stored_auth="" stored_ca="" user="" pass=""
    local shared_rc=0 static_rc=0 ca_rc=0

    _si_extract_domain "$shared" stored_domain || shared_rc=$?
    [ "$shared_rc" -ne 0 ] || _si_extract_auth "$shared" stored_auth || shared_rc=$?
    _si_extract_email "$static" stored_email || static_rc=$?
    _si_extract_ca "$static" stored_ca || ca_rc=$?

    # First, because it is the only question here that can end the run and the
    # only one whose answer nothing else depends on: a dashboard password typed
    # and bcrypted before a confirmation the operator then declines is work
    # thrown away, and a secret on a terminal for no reason.
    _si_settle_acme_ca "$stored_ca" "$ca_rc"

    # A stored value is reproduced verbatim and not re-validated: it is already
    # the configuration in effect, and re-rendering it into the same bytes is
    # the whole point. Only a value this run is about to invent gets checked.
    # An unreadable file is fatal only where a value was actually needed from
    # it — with the flag given there is nothing to recover and nothing to lose.
    if [ -n "$_SI_DOMAIN" ]; then
        _SI_DASHBOARD_DOMAIN="$_SI_DOMAIN"
    elif [ "$shared_rc" -ne 0 ]; then
        _si_unreadable_stack dynamic/_shared.yml --domain=
    elif [ -n "$stored_domain" ]; then
        _SI_DASHBOARD_DOMAIN="$stored_domain"
    else
        prompt_value domain \
            "Apex domain for $_SI_TARGET (the dashboard is served at traefik.<domain>)" \
            "" _SI_DASHBOARD_DOMAIN
        _si_check_domain "$_SI_DASHBOARD_DOMAIN"
    fi

    if [ -n "$_SI_EMAIL" ]; then
        _SI_ACME_EMAIL="$_SI_EMAIL"
    elif [ "$static_rc" -ne 0 ]; then
        _si_unreadable_stack traefik.yml --email=
    elif [ -n "$stored_email" ]; then
        _SI_ACME_EMAIL="$stored_email"
    else
        prompt_value email \
            "Email address to register with Let's Encrypt" "" _SI_ACME_EMAIL
        _si_check_email "$_SI_ACME_EMAIL"
    fi

    if [ -n "$_SI_AUTH" ]; then
        _si_parse_auth "$_SI_AUTH" user pass
        _si_bcrypt "$user" "$pass" _SI_AUTH_ENTRY
        _SI_AUTH_ORIGIN=flag
    elif [ "$shared_rc" -ne 0 ]; then
        _si_unreadable_stack dynamic/_shared.yml --traefik-auth=
    elif [ -n "$stored_auth" ]; then
        _SI_AUTH_ENTRY="$stored_auth"
        _SI_AUTH_ORIGIN=reused
    else
        prompt_value  traefik-auth \
            "Username for the dashboard at traefik.$_SI_DASHBOARD_DOMAIN" "" user
        prompt_secret traefik-auth \
            "Password for $user" "" pass
        _si_check_auth_user "$user"
        _si_check_auth_pass "$pass"
        _si_bcrypt "$user" "$pass" _SI_AUTH_ENTRY
        _SI_AUTH_ORIGIN=prompt
    fi
    return 0
}

# "production" or "staging" for the two endpoints kasbah renders, and nothing
# for anything else. A URL that is neither must never be *named* as one of them:
# the label is what the operator checks the warning against, and a wrong one
# turns a warning about their own configuration into a warning about a
# configuration they do not have.
_si_ca_label() {
    local _cl_url="$1" _cl_out="$2"
    case $_cl_url in
        "$_SI_ACME_CA_PRODUCTION") printf -v "$_cl_out" '%s' production ;;
        "$_SI_ACME_CA_STAGING")    printf -v "$_cl_out" '%s' staging ;;
        *)                         printf -v "$_cl_out" '%s' "" ;;
    esac
}

# The endpoint is the one Traefik value the server gets no vote on: the flag
# decides it, production by default, so a re-run without --acme-staging is what
# moves a staging server back.
#
# What the server *is* asked is whether anything would be lost by that. Traefik
# files certificates by resolver rather than by endpoint, so entries the old CA
# issued stay in acme.json and stay in use — a staging certificate served to
# the public, or a production one an operator believes they have moved off —
# and the only way out is to start the store again from empty. Two facts decide
# it, and only their pairing:
#
#   the store is empty,     nothing to lose whatever the CA was: silent, always,
#   absent, or not a file   which is every fresh server and so every first init.
#                           (A non-file is refused by the layout step, later and
#                           with a better message than one from here.)
#   the store has content,
#   and the config records
#   which CA filled it      equal is a no-op; different is the switch, confirmed
#                           with --yes, and declining aborts.
#   the store has content,
#   and nothing records
#   what filled it          kasbah cannot tell, so this is a choice rather than a
#                           confirmation: --reset-acme or --keep-acme, and keep
#                           proceeds. Every server prepared before caServer
#                           existed is in this state, and an abort would leave
#                           them with no way to run init at all. This run records
#                           the endpoint, so it is asked once.
#
# Nothing has been created, rendered or shipped when this returns, which is what
# lets the confirmation cost nothing when it is declined.
_si_settle_acme_ca() {
    local _sa_stored="$1" _sa_rc="$2"

    if [ -n "$_SI_ACME_STAGING" ]; then
        _SI_ACME_CA="$_SI_ACME_CA_STAGING"
    else
        _SI_ACME_CA="$_SI_ACME_CA_PRODUCTION"
    fi

    if [ "$_sa_rc" -ne 0 ]; then
        _SI_ACME_CA_ORIGIN=unreadable
    elif [ -n "$_sa_stored" ]; then
        _SI_ACME_CA_ORIGIN=known
        _SI_ACME_CA_STORED="$_sa_stored"
    elif [ -z "${_SI_TRAEFIK_CURRENT[traefik.yml]}" ]; then
        # The stack read reports empty for a file that is absent, unreadable or
        # zero-length alike, and the operator's move is the same for all three.
        _SI_ACME_CA_ORIGIN=nocontent
    else
        _SI_ACME_CA_ORIGIN=nofield
    fi

    _SI_ACME_RESET=no
    _SI_ACME_KEPT=""

    if [ "$_SI_ACME_STORE" = nonempty ] && [ "$_SI_ACME_CA_ORIGIN" != known ]; then
        _si_choose_acme_unknown
        return 0
    fi

    # Every path below leaves the unknown-store question unasked, so
    # --reset-acme and --keep-acme have nothing here to answer. The two are not
    # symmetrical about that: one of them states an intent a switch cannot
    # honour, and the other is merely spare.
    if [ "$_SI_ACME_STORE" = nonempty ] && [ "$_SI_ACME_CA_STORED" != "$_SI_ACME_CA" ]; then
        [ "$_SI_ACME_RESET_CHOICE" != no ] || _si_keep_acme_conflict
        _si_acme_choice_unused "this run is switching away from the endpoint that server states"
        _si_confirm_acme_switch
        return 0
    fi

    if [ "$_SI_ACME_STORE" = nonempty ]; then
        _si_acme_choice_unused "traefik.yml there records the CA that filled acme.json"
    else
        _si_acme_choice_unused "acme.json there holds nothing to decide about"
    fi
    return 0
}

# --keep-acme where the store must be reset for the run to mean anything. Both
# the flag and the switch are stated intents and only one can happen, which is
# the objection _server_init_set_bool already makes to --reset-acme --keep-acme
# on one command line — made here too, rather than resolved by whichever branch
# reads its flag last. The direction of the refusal is fixed: a store the
# operator asked to keep is never the one kasbah archives.
_si_keep_acme_conflict() {
    err "server init: --keep-acme cannot be honoured on $_SI_TARGET"
    err_cont "the server states one ACME endpoint and this run renders another, and every"
    err_cont "certificate in acme.json was issued by the one being left behind — keeping the"
    err_cont "store and switching CA cannot both happen:"
    err_cont "  $_SI_ACME_CA_STORED -> $_SI_ACME_CA"
    err_cont "re-run without --keep-acme to be asked, or with --yes to switch and reset."
    err_cont "nothing was created, shipped or restarted."
    exit 1
}

# A choice flag passed to a run that never reaches the choice. A warning and not
# a refusal: passing the pair is how the unknown-store question is answered
# without a terminal, and a fleet script that sets it once must not fail on
# every server that turned out not to need it.
_si_acme_choice_unused() {
    local _cu_flag=--reset-acme
    [ -n "$_SI_ACME_RESET_CHOICE" ] || return 0
    [ "$_SI_ACME_RESET_CHOICE" != no ] || _cu_flag=--keep-acme
    warn "$_cu_flag had no effect: it answers what to do with a certificate store"
    warn "whose CA nothing on $_SI_TARGET records, and $1"
    return 0
}

# A switch away from an endpoint the server states. Declining aborts: the
# likeliest way to arrive here is a mistyped flag, and re-running with the right
# one costs nothing because nothing has happened yet.
_si_confirm_acme_switch() {
    local from="" to="" stay=""

    _si_ca_label "$_SI_ACME_CA_STORED" from
    _si_ca_label "$_SI_ACME_CA" to

    if [ "$from" = staging ]; then
        warn "$_SI_TARGET is configured for the Let's Encrypt staging CA and this run renders $to"
        warn "  $_SI_ACME_CA_STORED -> $_SI_ACME_CA"
        stay="re-run with --acme-staging"
    elif [ "$from" = production ]; then
        warn "$_SI_TARGET is configured for the Let's Encrypt production CA and this run renders $to"
        warn "  $_SI_ACME_CA_STORED -> $_SI_ACME_CA"
        stay="re-run without --acme-staging"
    else
        # No flag reproduces this URL, so none is offered. Telling the operator
        # to "re-run with --acme-staging" to keep what they have would move them
        # to Let's Encrypt staging and reset the store — the loss the warning is
        # about, caused by the advice about it.
        warn "$_SI_TARGET is configured for an ACME endpoint kasbah does not render:"
        warn "  $_SI_ACME_CA_STORED -> $_SI_ACME_CA"
        warn "it was set outside kasbah. kasbah renders Let's Encrypt production or"
        warn "staging and nothing else, so this run would replace it with $to."
        stay="leave the endpoint as it is — no kasbah flag reproduces it"
    fi
    warn "no certificate in acme.json survives the switch: the store is archived beside"
    warn "itself, re-created empty, and re-issued from scratch on the next request."

    if ! prompt_confirm yes \
        "Switch $_SI_TARGET to the Let's Encrypt $to CA and reset acme.json?" "$_SI_YES"; then
        err "server init: declined — $_SI_TARGET is unchanged"
        err_cont "nothing was created, shipped or restarted. To keep what is there, $stay."
        exit 1
    fi
    _SI_ACME_RESET=yes
    return 0
}

# A store with certificates in it and nothing that says which CA issued them.
# A choice with its own flag pair rather than a confirmation, and deliberately
# **not** answered by --yes: --yes means "I accept the destructive act I asked
# for", and nobody asked for this one — kasbah raised it about state it cannot
# interpret, and answering it takes knowing which CA issued those certificates,
# which a blanket --yes in a CI script cannot supply. Keeping proceeds, loudly,
# because there is no reading of this question under which refusing to run is
# the safe answer.
_si_choose_acme_unknown() {
    local to=""
    _si_ca_label "$_SI_ACME_CA" to

    case $_SI_ACME_CA_ORIGIN in
        unreadable) warn "$_SI_APPS_PATH/traefik/traefik.yml on $_SI_TARGET does not parse, so the endpoint it configures cannot be read" ;;
        nocontent)  warn "$_SI_APPS_PATH/traefik/traefik.yml on $_SI_TARGET is missing, empty or unreadable, so nothing states which endpoint this server uses" ;;
        *)          warn "$_SI_APPS_PATH/traefik/traefik.yml on $_SI_TARGET parses but names no caServer under certificatesResolvers.letsencrypt.acme" ;;
    esac
    warn "acme.json is not empty, and nothing here says which CA issued what is in it."
    warn "this run configures the Let's Encrypt $to CA. If the certificates in the store"
    warn "came from the other one, Traefik keeps serving them until they renew and then"
    warn "replaces them with $to ones — resetting the store now is what avoids that."

    if prompt_choice reset-acme keep-acme \
        "Reset acme.json on $_SI_TARGET (archives it, forces re-issue from the $to CA)?" \
        "$_SI_ACME_RESET_CHOICE"; then
        _SI_ACME_RESET=yes
        return 0
    fi

    warn "keeping acme.json. $_SI_TARGET is being configured for the $to CA with a"
    warn "certificate store of unknown provenance — if it holds certificates from the"
    warn "other endpoint, they stay in service until they renew."
    warn "this run records the endpoint in traefik.yml, so you are asked this once."
    _SI_ACME_KEPT=unknown
    return 0
}

# Renders the templates into a temp directory. `__NAME__` is the placeholder
# form because it collides with nothing in the files it appears in: YAML gives
# `_` no meaning (`@` may not even start a plain scalar), and the `${1}` in
# _shared.yml's redirect middlewares is a different shape, so the guard below
# cannot mistake one for the other.
#
# A token the renderer has no value for is a hard failure, and it is looked for
# in the *template* rather than in the output: an operator whose --apps-path
# happens to contain __STAGE__ has done nothing wrong, and must not be told
# kasbah's templates are out of step. Substituted values are never rescanned,
# which is the same property from the other side.
#
# Every rendered file is then parsed before it is allowed near the server.
_server_init_traefik_render() {
    local rel src dst content out rest tok key yq_err
    local tpl="${KASBAH_TEMPLATE_DIR:-}"
    declare -A subst=(
        [APPS_PATH]="$_SI_APPS_PATH"
        [DATA_PATH]="$_SI_DATA_PATH"
        [ACME_EMAIL]="$_SI_ACME_EMAIL"
        [ACME_CA]="$_SI_ACME_CA"
        [DASHBOARD_DOMAIN]="$_SI_DASHBOARD_DOMAIN"
        [DASHBOARD_AUTH]="$_SI_AUTH_ENTRY"
    )

    [ -n "$tpl" ] || die "internal: KASBAH_TEMPLATE_DIR is not set"
    [ -d "$tpl/traefik" ] \
        || die "the Traefik templates are missing (looked in $tpl/traefik) — this kasbah installation is incomplete"
    command -v yq >/dev/null \
        || die "yq is required to render the Traefik stack (install yq and retry)"

    _SI_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/kasbah-traefik.XXXXXX")" \
        || die "could not create a temp directory to render the Traefik stack in"

    for rel in "${_SI_TRAEFIK_FILES[@]}"; do
        src="$tpl/traefik/$rel"
        dst="$_SI_TMPDIR/$rel"
        [ -f "$src" ] || die "the Traefik template $src is missing"
        mkdir -p "${dst%/*}" || die "could not create ${dst%/*}"

        content="$(cat "$src"; printf x)" || die "could not read $src"
        content="${content%x}"

        # One left-to-right pass: each token is replaced where it stands and the
        # text that replaces it is never looked at again.
        out=""
        rest="$content"
        while [[ "$rest" =~ __[A-Z0-9_]+__ ]]; do
            tok="${BASH_REMATCH[0]}"
            key="${tok#__}"; key="${key%__}"
            [ -n "${subst[$key]+set}" ] \
                || die "internal: the $rel template uses $tok, which the renderer has no value for — templates and renderer are out of step"
            out+="${rest%%"$tok"*}${subst[$key]}"
            rest="${rest#*"$tok"}"
        done
        content="$out$rest"

        printf '%s' "$content" > "$dst" || die "could not write $dst"
        chmod 644 "$dst" || die "could not set mode 644 on $dst"

        # The guarantee behind the input checks. A quote or a backslash in any
        # substituted value ends the YAML scalar it sits in, and for
        # dynamic/_shared.yml that costs tls.options.default — which
        # traefik.yml points every websecure entrypoint at, so *every* project's
        # HTTPS router stops starting. Traefik keeps answering /ping through all
        # of it, so the health wait would pass and init would report success.
        # Nothing unparseable reaches the server.
        if ! yq_err="$(yq -e . "$dst" 2>&1 >/dev/null)"; then
            err "the rendered Traefik $rel is not valid YAML — refusing to ship it"
            err_cont "${yq_err:-yq rejected the file and said nothing}"
            err_cont "a substituted value is the likely cause; this run rendered it with:"
            err_cont "  domain          $_SI_DASHBOARD_DOMAIN"
            err_cont "  acme email      $_SI_ACME_EMAIL"
            err_cont "  dashboard user  ${_SI_AUTH_ENTRY%%:*}"
            err_cont "  apps / data     $_SI_APPS_PATH, $_SI_DATA_PATH"
            exit 1
        fi
    done
    return 0
}

# Ships only what differs. rsync writes a temp file and renames, so Traefik's
# watcher sees one atomic replace of a dynamic file rather than a truncated
# one — the same reason anything generated for another process to read gets the
# rename treatment (docs/phases/01-rig.md).
#
# Only traefik.yml sets the restart flag. It is the static config, which Traefik
# reads once at startup; dynamic/_shared.yml is picked up by the file watcher,
# and a changed compose.yml is a changed service definition, which `up -d`
# recreates on its own.
_server_init_traefik_sync() {
    local rel rendered dest
    local changed=()

    _SI_TRAEFIK_RESTART=no
    for rel in "${_SI_TRAEFIK_FILES[@]}"; do
        rendered="$(cat "$_SI_TMPDIR/$rel"; printf x)" || die "could not read $_SI_TMPDIR/$rel"
        rendered="${rendered%x}"
        [ "$rendered" != "${_SI_TRAEFIK_CURRENT[$rel]}" ] || continue
        changed+=("$rel")
        [ "$rel" != traefik.yml ] || _SI_TRAEFIK_RESTART=yes
    done

    _SI_TRAEFIK_CHANGED=(${changed[@]+"${changed[@]}"})
    [ "${#changed[@]}" -gt 0 ] || return 0

    for rel in "${changed[@]}"; do
        dest="$_SI_APPS_PATH/traefik/$rel"
        ssh_rsync -pt --chmod=F644 "$_SI_TMPDIR/$rel" "$SSH_TARGET:$dest" >/dev/null \
            || die "could not ship the Traefik $rel to $_SI_TARGET:$dest"
    done
    return 0
}

# Empties the certificate store for a CA switch, between the new traefik.yml
# landing and the restart that makes Traefik read it. Not in the layout step:
# acme.json is bind-mounted as a *file*, so a running Traefik holds the inode
# and would keep writing to the archive.
# The restart re-resolves the mount (measured), which is why the reset may only
# happen where one is guaranteed to follow.
#
# The archive is a sibling and never a deletion: on production -> staging the
# file being set aside holds real certificates, and re-issuing them costs
# rate-limit budget that a `rm` would spend for nothing.
_server_init_acme_reset() {
    local out rc=0 stamp

    if [ "$_SI_ACME_RESET" != yes ]; then
        _SI_FACT[acme_reset]=skipped
        _SI_FACT[acme_archive]=""
        return 0
    fi
    [ "$_SI_TRAEFIK_RESTART" = yes ] \
        || die "internal: the ACME endpoint changed but traefik.yml did not — the reset would outlive nothing"

    # The stamp is taken here because the remote side is coreutils and bash and
    # nothing else, and one clock beats each host's.
    stamp="$(date -u +%Y%m%dT%H%M%SZ)" || die "internal: could not read the clock"

    out=$(ssh_script "$_SI_DATA_PATH/traefik/letsencrypt/acme.json" "$stamp" <<'REMOTE'
set -uo pipefail
export LC_ALL=C
acme=$1
stamp=$2

fail() { printf 'remote: %s\n' "$*" >&2; exit 1; }

if [ -e "$acme" ] && [ ! -f "$acme" ]; then
    fail "$acme exists and is not a regular file — Traefik needs a file there. Remove it (rm -rf '$acme') and re-run."
fi

archive=""
if [ -f "$acme" ]; then
    archive="$acme.$stamp"
    [ ! -e "$archive" ] || fail "$archive is already there — kasbah will not write over an archived certificate store"
    mv "$acme" "$archive" || fail "could not archive $acme as $archive"
    chmod 600 "$archive" || fail "could not set mode 600 on $archive"
fi
printf 'acme_archive=%s\n' "$archive"

# Re-created here rather than left to the restart that follows, for the reason
# the layout step creates it at all: Docker materialises a missing bind-mount
# source as a directory.
: > "$acme" || fail "could not create $acme"
chmod 600 "$acme" || fail "could not set mode 600 on $acme"
printf 'acme_reset=done\n'
exit 0
REMOTE
    ) || rc=$?

    [ "$rc" -eq 0 ] \
        || die "could not reset acme.json on $_SI_TARGET (the remote step exited $rc, see above)"

    _si_absorb_checked "the acme.json reset" "$out" acme_reset acme_archive
    return 0
}

# Starts the stack and waits for the healthcheck, with a real diagnostic rather
# than a bare timeout: a Traefik that will not come up says why in its own logs,
# and making the operator go and fetch them is a waste of a round trip.
_server_init_traefik_start() {
    local out rc=0

    out=$(ssh_script "$_SI_APPS_PATH" "$_SI_TRAEFIK_PROJECT" "$_SI_TRAEFIK_RESTART" 120 <<'REMOTE'
set -uo pipefail
export LC_ALL=C
apps=$1
project=$2
restart=$3
timeout_s=$4

fail() { printf 'remote: %s\n' "$*" >&2; exit 1; }

cd "$apps/traefik" || fail "could not enter $apps/traefik"

# Every compose invocation carries -p. `name:` in the compose file is the
# weakest source of the project name: COMPOSE_PROJECT_NAME in this login shell
# outranks it, and `down` removes by project label rather than by the services
# the file lists (docs/phases/01-rig.md — nine unrelated containers were once
# in range of exactly this).
dc() { docker compose -p "$project" "$@"; }

started_at() { docker inspect -f '{{.State.StartedAt}}' "$1" 2>/dev/null || printf ''; }

before=""
cid=$(dc ps -a -q traefik 2>/dev/null) || cid=""
[ -z "$cid" ] || before=$(started_at "$cid")

dc up -d || fail "docker compose -p $project up -d failed in $apps/traefik"

cid=$(dc ps -a -q traefik 2>/dev/null) || cid=""
[ -n "$cid" ] || fail "compose reported no traefik container after up -d"

# The static config is bind-mounted, so compose sees no change in the service
# definition and leaves the container alone: only an explicit restart makes
# Traefik re-read traefik.yml. Skipped when this same `up -d` created or
# recreated the container, which read the new file on its way up — restarting a
# process that started two seconds ago is downtime bought for nothing.
mid=$(started_at "$cid")
if [ "$restart" = yes ] && [ -n "$before" ] && [ "$before" = "$mid" ]; then
    dc restart traefik || fail "docker compose -p $project restart traefik failed"
fi

diagnose() {
    printf 'remote: %s\n' "$1" >&2
    dc ps -a >&2 || true
    dc logs --no-color --tail 60 >&2 || true
}

deadline=$((SECONDS + timeout_s))
health=""
while :; do
    health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null) \
        || health=gone
    [ "$health" != healthy ] || break
    if [ "$health" = none ]; then
        diagnose "the traefik container declares no healthcheck — compose.yml lost it"
        exit 1
    fi
    running=$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null) || running=false
    if [ "$running" != true ]; then
        diagnose "traefik is not running (health $health) — it exited instead of coming up"
        exit 1
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
        diagnose "traefik did not report healthy within ${timeout_s}s (last health: $health)"
        exit 1
    fi
    sleep 2
done

after=$(started_at "$cid")
if [ -z "$before" ]; then action=started
elif [ "$before" != "$after" ]; then action=restarted
else action=running
fi

name=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null) || name=""
printf 'traefik_action=%s\n' "$action"
printf 'traefik_health=%s\n' "$health"
printf 'traefik_started_at=%s\n' "$after"
printf 'traefik_image=%s\n' "$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null)"
printf 'traefik_container=%s\n' "${name#/}"
exit 0
REMOTE
    ) || rc=$?

    if [ "$rc" -ne 0 ]; then
        err "could not start Traefik on $_SI_TARGET (the remote step exited $rc, see above)"
        # The one destructive thing this command does, said on the one path where
        # the operator cannot see it succeed: after a reset the certificates
        # exist only in the archive, and a failed start is when that matters.
        [ "${_SI_FACT[acme_reset]:-}" != done ] \
            || err_cont "acme.json was reset before this — the previous store is at ${_SI_FACT[acme_archive]}"
        exit 1
    fi

    _si_absorb_checked "the Traefik start" "$out" \
        traefik_action traefik_health traefik_started_at traefik_image traefik_container
    return 0
}

# --- Command ------------------------------------------------------------------

# The rendered stack lives in a temp directory until it is shipped. The trap is
# installed before ssh_connect on purpose: lib/ssh.sh chains its master teardown
# onto whatever EXIT trap already exists, and can only reach one that is already
# there.
_server_init_cleanup() {
    [ -z "$_SI_TMPDIR" ] || rm -rf "$_SI_TMPDIR"
    _SI_TMPDIR=""
    return 0
}

cmd_server_init() {
    _server_init_parse_args "$@"
    command -v jq >/dev/null || die "jq is required (install jq and retry)"
    trap '_server_init_cleanup' EXIT

    # Both questions are asked before anything is opened or created: a run that
    # cannot be answered must cost nothing, and a feature that would be a silent
    # no-op must not be accepted at all.
    if prompt_bool mail "Scaffold the mail stack (DMS + SnappyMail) on $_SI_TARGET?" "$_SI_MAIL"; then
        err "server init: mail is not implemented yet — it is scaffolded in Phase 7 (docs/mail.md)"
        err_cont "re-run with --no-mail; adding mail later is a re-run of init"
        exit 1
    fi
    if prompt_bool backup "Install restic backups on $_SI_TARGET?" "$_SI_BACKUP"; then
        err "server init: backup is not implemented yet — it is scaffolded in Phase 8 (docs/backup.md)"
        err_cont "re-run with --no-backup; adding backups later is a re-run of init"
        exit 1
    fi

    ssh_connect "$_SI_TARGET"

    _server_init_probe
    _server_init_read_marker
    _server_init_elevation
    _server_init_preflight "$_SI_TARGET" "$_SI_APPS_PATH" "$_SI_ELEVATE"
    _server_init_check_marker
    _server_init_check_pointer
    _server_limits "${_SI_FACT[nproc]}" "${_SI_FACT[memtotal_kb]}"

    local marker_json
    marker_json="$(_server_marker_json "$KASBAH_VERSION" "$_SI_APPS_PATH" \
        "$_SI_DATA_PATH" "$_SI_CPU_LIMIT" "$_SI_MEM_LIMIT" "$_SI_MARKER_EXISTING")"

    # Everything the Traefik stack needs is settled — asked for or recovered
    # from the server — and rendered before the first directory is created, so
    # a run nobody can answer and a template that will not render both cost
    # nothing on the far side.
    _server_init_read_traefik
    _server_init_traefik_values
    _server_init_traefik_render

    _server_init_layout
    _server_init_traefik_sync
    _server_init_acme_reset
    _server_init_traefik_start
    _server_init_marker "$marker_json"
    _server_init_pointer

    info "Prepared $_SI_TARGET"
    # The one moment kasbah elevates, and the one moment it creates the file
    # Docker would otherwise turn into a directory: both are worth saying out
    # loud, and both are silent on a re-run.
    [ "${_SI_FACT[elevated]}" != yes ] \
        || info "  created $_SI_APPS_PATH with sudo, owner ${_SI_FACT[user]}:${_SI_FACT[group]}"
    [ "${_SI_FACT[acme]}" != created ] \
        || info "  touched $_SI_DATA_PATH/traefik/letsencrypt/acme.json as a file, mode 600"
    info "  apps: $_SI_APPS_PATH   data: $_SI_DATA_PATH"
    info "  limits: cpu $_SI_CPU_LIMIT, mem $_SI_MEM_LIMIT (90% of ${_SI_FACT[nproc]} cores, ${_SI_FACT[memtotal_kb]} kB)"
    local shipped="nothing re-rendered"
    [ "${#_SI_TRAEFIK_CHANGED[@]}" -eq 0 ] || shipped="shipped ${_SI_TRAEFIK_CHANGED[*]}"
    info "  traefik: ${_SI_FACT[traefik_action]}, ${_SI_FACT[traefik_health]}, ${_SI_FACT[traefik_image]} ($shipped)"
    local acme_from=""
    [ -z "$_SI_ACME_CA_STORED" ] || [ "$_SI_ACME_CA_STORED" = "$_SI_ACME_CA" ] \
        || acme_from="$_SI_ACME_CA_STORED -> "
    info "  acme: $acme_from$_SI_ACME_CA"
    if [ "${_SI_FACT[acme_reset]}" = done ]; then
        info "        acme.json reset, previous store archived as ${_SI_FACT[acme_archive]}"
    elif [ "$_SI_ACME_KEPT" = unknown ]; then
        # The one outcome a run can end in without kasbah knowing it is correct.
        info "        acme.json kept and NOT reset — nothing records which CA issued what is in it"
    fi
    info "  dashboard: https://traefik.$_SI_DASHBOARD_DOMAIN (basic auth, credentials $_SI_AUTH_ORIGIN)"
    info "  marker: $_SI_APPS_PATH/.kasbah/server.json (${_SI_FACT[marker]})"
    info "  pointer: $KASBAH_APPS_POINTER -> $_SI_APPS_PATH (${_SI_FACT[pointer]})"
}
