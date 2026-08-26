# kasbah — server init command
# Sourced by bin/kasbah. Do not execute directly.

[ -n "${_KASBAH_SERVER_INIT_LOADED:-}" ] && return 0
_KASBAH_SERVER_INIT_LOADED=1

. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/prompt.sh"
. "$KASBAH_LIB_DIR/ssh.sh"
# The --with-backup half: its flags are parsed here, and everything it then does
# lives there. Sourced at the top rather than lazily because init is where it is
# used, and because backup.sh needs this file's template renderer — one of the
# two has to be loaded first and a load guard makes the pairing free.
. "$KASBAH_LIB_DIR/backup.sh"

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
#
# --with-mail adds four more, and where each one sits is load-bearing. Its read
# joins the others at the front, before anything is created, because whether the
# postmaster account is already seeded decides whether this run asks for a
# password at all. Its layout-and-seed and its file sync land *before* Traefik
# starts, so Traefik boots with <apps>/traefik/dynamic/_mail.yml already in the
# watch directory and requests both certificates at configuration load. Its
# start comes *after* Traefik is healthy, which is docs/server-setup.md's
# ordering rule: DMS reads mail.<domain>'s certificate out of acme.json, and
# nothing puts one there until the cert-trigger router is live. The marker still
# goes last.
#
# --with-backup adds five, all of them after the two stacks are up and all of
# them in lib/backup.sh. Its read joins the others at the front, because which
# projects are on the server is what decides how many repository passwords this
# run asks for. Then the tree and the credentials land, the credential probe
# runs against the storage those credentials actually reach, and only then are
# the compose file and the runner shipped and the scheduler started — so a
# credential that can delete its own history is refused *before* anything is
# scheduled to use it. The marker still goes last.

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
_SI_POSTMASTER_PASSWORD=""

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
_SI_TRAEFIK_IMAGE=""
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

# The mail stack. Three kasbah-owned files, two of them in <apps>/mail and the
# third in Traefik's watch directory, plus a registry whose two values a re-run
# reads back rather than regenerating — the same rule the dashboard domain and
# the ACME address follow, for the same reason.
_SI_MAIL_ENABLED=no
_SI_MAIL_FILES=(compose.yml kasbah.yml _mail.yml)
declare -A _SI_MAIL_KEY=(
    [compose.yml]=mail_compose_b64
    [kasbah.yml]=mail_registry_b64
    [_mail.yml]=mail_fragment_b64
)
# Where each one lands, relative to the apps path. _mail.yml is Traefik's, not
# the mail stack's: it is a file-provider fragment and has to sit where the
# watcher looks.
declare -A _SI_MAIL_DEST=(
    [compose.yml]=mail/compose.yml
    [kasbah.yml]=mail/kasbah.yml
    [_mail.yml]=traefik/dynamic/_mail.yml
)
declare -A _SI_MAIL_CURRENT=()
_SI_MAIL_PROJECT=mail
_SI_MAIL_PRIMARY=""
_SI_MAIL_DOMAINS=()
_SI_MAIL_PRIMARY_ORIGIN=""
# The seeded postmaster line, `user@domain|{SHA512-CRYPT}$6$…`, or empty when
# the server already has an account and this run must not touch it.
_SI_MAIL_ACCOUNT_LINE=""
_SI_MAIL_ACCOUNT_ORIGIN=""
_SI_MAIL_CHANGED=()

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
  --postmaster-password=<pw> password for postmaster@<mail domain>, seeded
                         before DMS first starts; hashed here, never sent
  --with-backup|--no-backup  install the restic backup stack, or skip it
  --backup-repo-base=<url>   where snapshots go; kasbah appends <client> to it
  --backup-env=KEY=VALUE     environment restic needs to reach it (repeatable)
  --no-backup-env            state that it needs none
  --backup-password=<repo>=<pw>  the restic password for one repository
  --backup-at=HH:MM      daily slot, local time (default 02:00)
  --backup-jitter=<s>    seconds added to the slot (default: derived per server)
  --backup-keep-daily=N  retention, applied by "server backup-prune"
  --backup-keep-weekly=N
  --backup-keep-monthly=N
  --backup-timeout=<s>   bound on one restic invocation (default 900)
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

--with-mail scaffolds <apps>/mail (compose.yml, .env, kasbah.yml), writes the
cert-trigger and webmail routers to <apps>/traefik/dynamic/_mail.yml, seeds the
postmaster account and the DKIM signing config before DMS first starts, and
brings the stack up after Traefik. The mail domain defaults to --domain's apex;
it is read back out of <apps>/mail/kasbah.yml on a re-run, so an edit there
survives. The postmaster password is asked for once — a re-run against a server
that already has the account neither asks nor changes it. See docs/mail.md.

--with-backup scaffolds <apps>/.kasbah/backup — a compose stack that sleeps
until the daily slot and then pushes restic snapshots of every project's data,
hook-produced dumps and .env off the box, one repository per "client:" plus one
for mail. kasbah never parses the repository URL and never generates a
repository password. Before the stack is started, init writes a probe object
with the credentials in effect and tries to delete it again: a credential that
can delete its own history is refused, because that is the one property the
whole feature rests on. See docs/backup.md.
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

# The postmaster password. Nothing but its hash is ever written, so the YAML
# scalar rules do not apply — what does is that `openssl passwd -6 -stdin` reads
# exactly one line, so a value carrying a newline would be silently truncated to
# the part before it and the operator would be locked out of an account whose
# password they believe they know.
#
# A trailing carriage return is stripped rather than refused, because a password
# read out of a CRLF file is the ordinary CRLF case and the stripped form is
# what a Unix tool would have hashed anyway. The strip happens in the two places
# the value arrives — the flag's own case in _server_init_parse_args, beside
# --domain's and --email's, and prompt_secret — so this checker only ever sees
# an already-stripped value and refuses a *newline*, which no strip can save.
_si_check_postmaster_password() {
    local p="$1"
    [ -n "$p" ] || die "server init: --postmaster-password= must not be empty"
    case $p in
        *$'\n'*) die "server init: --postmaster-password= must not contain a newline — only the first line would be hashed" ;;
    esac
    return 0
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
    # Where --backup-password='s two halves land while they are being checked.
    # The pair is kept whole in _BK_PASS_GIVEN; only the validation needs them
    # apart, and it must happen here so a typo costs no connection.
    local _si_bk_repo="" _si_bk_pass=""

    _SI_TARGET=""
    _SI_MAIL=""
    _SI_BACKUP=""
    _SI_DOMAIN=""
    _SI_EMAIL=""
    _SI_AUTH=""
    _SI_ACME_STAGING=""
    _SI_ACME_RESET_CHOICE=""
    _SI_YES=""
    _SI_POSTMASTER_PASSWORD=""
    _BK_REPO_BASE=""
    _BK_REPO_BASE_ORIGIN=""
    _BK_AT=""
    _BK_JITTER=""
    _BK_KEEP_DAILY=""
    _BK_KEEP_WEEKLY=""
    _BK_KEEP_MONTHLY=""
    _BK_TIMEOUT=""
    _BK_ENV_GIVEN=()
    _BK_ENV_NONE=""
    _BK_PASS_GIVEN=()

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
            # Validated, never echoed, for the reason --traefik-auth is not.
            # Stripped of a trailing \r like --domain and --email above, and for
            # a sharper consequence: a password scripted out of a CRLF file
            # would otherwise hash with the carriage return in it, and the
            # account it seeds would be one nobody can log into — on the one
            # file init then deliberately refuses to rewrite.
            --postmaster-password=*)
                           _SI_POSTMASTER_PASSWORD="${1#*=}"
                           _SI_POSTMASTER_PASSWORD="${_SI_POSTMASTER_PASSWORD%$'\r'}"
                           _si_check_postmaster_password "$_SI_POSTMASTER_PASSWORD" ;;
            --with-backup) _server_init_set_bool backup yes ;;
            --no-backup)   _server_init_set_bool backup no ;;
            # The third of these flags that can carry a credential, and the one
            # that cannot be kept off a terminal: --backup-env= and
            # --backup-password= are never echoed at all, the way --traefik-auth
            # is not, but the repository base has to be *named* — in the run's
            # summary, in every refusal, and in the server marker, which is mode
            # 644 by contract. So it is echoed with its userinfo redacted the way
            # restic redacts its own (_bk_redact_url), and `_bk_values` says once
            # that a credential in the URL is a credential in a world-readable
            # file.
            --backup-repo-base=*)
                           _BK_REPO_BASE="${1#*=}"; _BK_REPO_BASE="${_BK_REPO_BASE%$'\r'}"
                           _bk_check_repo_base --backup-repo-base= "$_BK_REPO_BASE"
                           _BK_REPO_BASE_ORIGIN=flag ;;
            # Validated, never echoed, for the reason --traefik-auth is not: both
            # values carry a credential, and an error message is the one place it
            # would end up on a terminal and in every CI log that keeps one.
            --backup-env=*)      _bk_check_env_entry --backup-env= "${1#*=}"; _BK_ENV_GIVEN+=("${1#*=}") ;;
            --no-backup-env)     _BK_ENV_NONE=yes ;;
            --backup-password=*) _bk_split_password "${1#*=}" _si_bk_repo _si_bk_pass
                                 _BK_PASS_GIVEN+=("${1#*=}") ;;
            --backup-at=*)       _BK_AT="${1#*=}"; _BK_AT="${_BK_AT%$'\r'}"
                                 _bk_check_at "$_BK_AT" ;;
            --backup-jitter=*)   _BK_JITTER="${1#*=}"; _BK_JITTER="${_BK_JITTER%$'\r'}"
                                 _bk_check_jitter "$_BK_JITTER" ;;
            --backup-keep-daily=*)   _BK_KEEP_DAILY="${1#*=}";   _bk_check_keep --backup-keep-daily= "$_BK_KEEP_DAILY" ;;
            --backup-keep-weekly=*)  _BK_KEEP_WEEKLY="${1#*=}";  _bk_check_keep --backup-keep-weekly= "$_BK_KEEP_WEEKLY" ;;
            --backup-keep-monthly=*) _BK_KEEP_MONTHLY="${1#*=}"; _bk_check_keep --backup-keep-monthly= "$_BK_KEEP_MONTHLY" ;;
            --backup-timeout=*)      _BK_TIMEOUT="${1#*=}"; _BK_TIMEOUT="${_BK_TIMEOUT%$'\r'}"
                                     _bk_check_timeout "$_BK_TIMEOUT" ;;
            -h|--help)     _server_init_usage; exit 0 ;;
            # Only the flag's *name* is quoted back. An unknown flag is most
            # often a mistyped known one, and `--traefik-auths=admin:hunter2`
            # would otherwise put the password in the message and in every CI
            # log that keeps one. The name is what diagnoses a typo; the value
            # adds nothing, so it is never printed — for any flag, rather than
            # for a list of names that can always miss one.
            -*)            die "server init: unknown flag '${1%%=*}' (expected --apps-path=, --data-path=, --domain=, --email=, --traefik-auth=, --acme-staging, --reset-acme/--keep-acme, --with-mail/--no-mail, --postmaster-password=, --with-backup/--no-backup, --backup-repo-base=, --backup-env=/--no-backup-env, --backup-password=, --backup-at=, --backup-jitter=, --backup-keep-daily=/-weekly=/-monthly=, --backup-timeout=, --yes)" ;;
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
# and knows nothing about the rest. `backup` is the one that matters today — it
# carries repo_base, and a plain re-run of init must not take an operator's
# backup configuration with it. Same for any key a newer kasbah wrote and this
# one has never heard of.
#
# The seventh argument is what `--with-backup` decided, or empty. Empty leaves
# whatever `backup` is already there untouched, which is `--no-backup`'s
# documented behaviour: init scaffolds backups and never removes them. When it
# is given it is *merged into* the existing object, and its `retention` is
# merged into the existing retention rather than replacing it — a key inside
# `backup` written by a newer kasbah survives exactly as a top-level one does.
#
# `+` keeps the left operand's key order for keys both sides carry, so a second
# run against an unchanged server renders the same bytes as the first. That is
# what makes the marker something a re-run can compare against.
_server_marker_json() {
    local existing="${6:-}" backup="${7:-}"
    jq -n \
        --argjson existing "${existing:-null}" \
        --argjson backup "${backup:-null}" \
        --arg version "$1" \
        --arg apps_path "$2" \
        --arg data_path "$3" \
        --arg cpu_limit "$4" \
        --arg mem_limit "$5" \
        '(($existing // {}) as $e
          | ($e + {
                kasbah_version: $version,
                apps_path: $apps_path,
                data_path: $data_path,
                cpu_limit: $cpu_limit,
                mem_limit: $mem_limit
            })
          | if $backup == null then
                (if has("backup") then . else . + { backup: { enabled: false } } end)
            else
                .backup = ((($e.backup // {}) + ($backup | del(.retention)))
                           + { retention: ((($e.backup.retention) // {}) + ($backup.retention // {})) })
            end)'
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

    yaml_get "$_xa_content" "$_xa_users | length"    _xa_count || _xa_rc=$?
    [ "$_xa_rc" -eq 0 ] || return "$_xa_rc"
    yaml_get "$_xa_content" "$_xa_users | .[0] // \"\"" _xa_entry || _xa_rc=$?
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

# The apex the dashboard router already hangs off lives in lib/common.sh as
# `traefik_dashboard_apex`: `check --server` reads the same rule out of the same
# file to tighten T05 to the exact `traefik.<apex>` match, and one rule has one
# reader. Read back off the server rather than stored in the marker, so the file
# in effect stays the single source of truth — a rule the operator rewrote into
# some other shape simply yields nothing, and the flag or the prompt answers
# instead.

_si_extract_email() {
    local _xe_content="$1" _xe_out="$2"
    yaml_get "$_xe_content" \
        '.certificatesResolvers.letsencrypt.acme.email // ""' "$_xe_out"
}

# The endpoint the stack on the server is *configured* with — which is not the
# same fact as the one that issued the certificates sitting in acme.json, and
# the gap between them is what the caller has to reason about. Unlike the three
# values beside it this one is never reused: the flag decides the endpoint on
# every run, and this is read only to be compared against it.
_si_extract_ca() {
    local _xc_content="$1" _xc_out="$2"
    yaml_get "$_xc_content" \
        '.certificatesResolvers.letsencrypt.acme.caServer // ""' "$_xc_out"
}

# The Traefik image the stack on the server already runs, read out of its own
# compose.yml. The fourth value a re-run reproduces rather than decides, and the
# newest: `server upgrade-traefik` moves the tag after validating it, and an
# init that re-rendered the template's pin over the top would silently undo a
# managed upgrade the next time anyone touched the server (docs/traefik.md ->
# Ownership).
#
# Narrow on purpose. Only the official repository with a Docker tag on it is
# reproduced; anything else — a mirror, a digest pin, a value with a newline in
# it — falls back to this kasbah's pin with a warning, because the value is
# substituted into a YAML scalar and into a `docker run` argument, and a
# compose.yml is a file an operator can write anything into.
_si_extract_image() {
    local _xi_content="$1" _xi_out="$2" _xi_ref="" _xi_rc=0

    yaml_get "$_xi_content" '.services.traefik.image // ""' _xi_ref || _xi_rc=$?
    [ "$_xi_rc" -eq 0 ] || return "$_xi_rc"

    printf -v "$_xi_out" '%s' ""
    [ -n "$_xi_ref" ] || return 0
    [[ "$_xi_ref" =~ ^traefik:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || return 0
    printf -v "$_xi_out" '%s' "$_xi_ref"
    return 0
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

# SHA512-CRYPT, because that is the one thing docker-mailserver's own account
# file holds: `setup email add` shells out to `doveadm pw -s SHA512-CRYPT` and
# writes `<address>|{SHA512-CRYPT}$6$…` (verified against the pinned 15.1.0
# image, both that a hash from `openssl passwd -6` verifies under that prefix
# and that a wrong password does not). openssl is on the *workstation's*
# unchecked list beside htpasswd; it is also a remote prerequisite, but the
# hashing happens here so the password never crosses the wire, exactly as
# _si_bcrypt does for the dashboard.
#
# `-stdin` rather than a positional argument: `openssl passwd -6 "$pass"` puts
# the password in the process table, where any other user of this workstation
# can read it for as long as it runs.
_si_sha512_crypt() {
    local _sc_pass="$1" _sc_out="$2"
    local _sc_hash="" _sc_rc=0
    local _sc_re='^\$6\$[^$]+\$[./A-Za-z0-9]+$'

    command -v openssl >/dev/null 2>&1 \
        || die "cannot hash the postmaster password: no openssl on PATH (it is what produces the SHA512-CRYPT hash docker-mailserver's account file holds)"

    _sc_hash=$(printf '%s\n' "$_sc_pass" | openssl passwd -6 -stdin) || _sc_rc=$?
    _sc_hash="${_sc_hash%$'\r'}"
    if [ "$_sc_rc" -ne 0 ] || ! [[ "$_sc_hash" =~ $_sc_re ]]; then
        err "could not produce a SHA512-CRYPT hash for the postmaster password (openssl exited $_sc_rc)"
        err_cont "expected one line of '\$6\$<salt>\$<hash>' — see openssl's own error above"
        exit 1
    fi
    printf -v "$_sc_out" '%s' "$_sc_hash"
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
    local compose="${_SI_TRAEFIK_CURRENT[compose.yml]}"
    local stored_domain="" stored_email="" stored_auth="" stored_ca="" user="" pass=""
    local stored_image=""
    local shared_rc=0 static_rc=0 ca_rc=0 compose_rc=0

    traefik_dashboard_apex "$shared" stored_domain || shared_rc=$?
    [ "$shared_rc" -ne 0 ] || _si_extract_auth "$shared" stored_auth || shared_rc=$?
    _si_extract_email "$static" stored_email || static_rc=$?
    _si_extract_ca "$static" stored_ca || ca_rc=$?
    _si_extract_image "$compose" stored_image || compose_rc=$?

    # The image is the one recovered value with a default behind it, so an
    # unreadable compose.yml costs nothing: init owns that file and is about to
    # replace it. A value it will not reproduce is said out loud rather than
    # reverted in silence — the operator is about to lose it.
    if [ -n "$stored_image" ] && [ "$compose_rc" -eq 0 ]; then
        _SI_TRAEFIK_IMAGE="$stored_image"
    else
        _SI_TRAEFIK_IMAGE="$KASBAH_TRAEFIK_IMAGE"
        [ -z "$compose" ] \
            || warn "the traefik image in compose.yml on $_SI_TARGET is not one kasbah reproduces — rendering $KASBAH_TRAEFIK_IMAGE (a managed bump is \`kasbah server upgrade-traefik --version=\`)"
    fi

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

# The substitution table the renderer reads. A global rather than a parameter
# because bash passes no associative array by value, and one table rather than
# one per stack because the renderer is shared: `_server_init_traefik_render`
# and `_server_init_mail_render` fill it and then hand files to
# `_si_render_template`, so neither carries a private copy of the substitution
# loop.
declare -A _SI_SUBST=()

# One template rendered into one destination. `__NAME__` is the placeholder form
# because it collides with nothing in the files it appears in: YAML gives `_` no
# meaning (`@` may not even start a plain scalar), and the `${1}` in _shared.yml's
# redirect middlewares is a different shape, so the guard below cannot mistake
# one for the other.
#
# A token the renderer has no value for is a hard failure, and it is looked for
# in the *template* rather than in the output: an operator whose --apps-path
# happens to contain __STAGE__ has done nothing wrong, and must not be told
# kasbah's templates are out of step. Substituted values are never rescanned,
# which is the same property from the other side.
_si_render_template() {
    local _rt_src="$1" _rt_dst="$2" _rt_label="$3"
    local _rt_content _rt_out _rt_rest _rt_tok _rt_key

    [ -f "$_rt_src" ] || die "the $_rt_label template $_rt_src is missing"
    mkdir -p "${_rt_dst%/*}" || die "could not create ${_rt_dst%/*}"

    _rt_content="$(cat "$_rt_src"; printf x)" || die "could not read $_rt_src"
    _rt_content="${_rt_content%x}"

    # One left-to-right pass: each token is replaced where it stands and the
    # text that replaces it is never looked at again.
    _rt_out=""
    _rt_rest="$_rt_content"
    while [[ "$_rt_rest" =~ __[A-Z0-9_]+__ ]]; do
        _rt_tok="${BASH_REMATCH[0]}"
        _rt_key="${_rt_tok#__}"; _rt_key="${_rt_key%__}"
        [ -n "${_SI_SUBST[$_rt_key]+set}" ] \
            || die "internal: the $_rt_label template uses $_rt_tok, which the renderer has no value for — templates and renderer are out of step"
        _rt_out+="${_rt_rest%%"$_rt_tok"*}${_SI_SUBST[$_rt_key]}"
        _rt_rest="${_rt_rest#*"$_rt_tok"}"
    done

    printf '%s' "$_rt_out$_rt_rest" > "$_rt_dst" || die "could not write $_rt_dst"
    chmod 644 "$_rt_dst" || die "could not set mode 644 on $_rt_dst"
    return 0
}

# Renders the Traefik templates into a temp directory. Every rendered file is
# then parsed before it is allowed near the server.
_server_init_traefik_render() {
    local rel dst yq_err
    local tpl="${KASBAH_TEMPLATE_DIR:-}"

    [ -n "$tpl" ] || die "internal: KASBAH_TEMPLATE_DIR is not set"
    [ -d "$tpl/traefik" ] \
        || die "the Traefik templates are missing (looked in $tpl/traefik) — this kasbah installation is incomplete"
    command -v yq >/dev/null \
        || die "yq is required to render the Traefik stack (install yq and retry)"

    _SI_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/kasbah-traefik.XXXXXX")" \
        || die "could not create a temp directory to render the Traefik stack in"

    _SI_SUBST=(
        [APPS_PATH]="$_SI_APPS_PATH"
        [DATA_PATH]="$_SI_DATA_PATH"
        [ACME_EMAIL]="$_SI_ACME_EMAIL"
        [ACME_CA]="$_SI_ACME_CA"
        [DASHBOARD_DOMAIN]="$_SI_DASHBOARD_DOMAIN"
        [DASHBOARD_AUTH]="$_SI_AUTH_ENTRY"
        [TRAEFIK_IMAGE]="$_SI_TRAEFIK_IMAGE"
    )

    for rel in "${_SI_TRAEFIK_FILES[@]}"; do
        dst="$_SI_TMPDIR/$rel"
        _si_render_template "$tpl/traefik/$rel" "$dst" "$rel"

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


# --- The mail stack -------------------------------------------------------------

# `--with-mail` scaffolds <apps>/mail and the Traefik fragment that makes it
# reachable (docs/mail.md). Three files are kasbah's and are re-rendered every
# run — compose.yml, kasbah.yml, and traefik/dynamic/_mail.yml. Two more are
# seeded once and never touched again: postfix-accounts.cf, because it holds
# every account on the server, and rspamd's dkim_signing.conf, because DMS's own
# `setup config dkim` helper extends it. The .env is a third thing again: kasbah
# owns three keys in it by name and copies every other line through, which is
# how a relay credential set by hand survives a re-run without ever leaving the
# server.
#
# The registry is <apps>/mail/kasbah.yml and nothing else asks "does this stack
# serve X?" of any other file. `.env`'s kasbah-owned values are *derived* from
# it and rewritten on every run, so there is one writer per fact and the two
# cannot drift.

# What is on the server now: the three kasbah-owned files, and the two facts
# that decide whether this run seeds anything. Read before anything is created
# and before the postmaster question is asked — whether that question needs
# asking at all is a fact about the server, exactly like the dashboard
# credentials.
#
# Base64 on one line for the same reason the Traefik read uses it: this output
# is a key=value protocol and a YAML file sent raw would arrive as a dozen keys.
_server_init_read_mail() {
    local out rc=0 rel enc dec

    [ "$_SI_MAIL_ENABLED" = yes ] || return 0

    out=$(ssh_script "$_SI_APPS_PATH" "$_SI_DATA_PATH" <<'REMOTE'
set -uo pipefail
export LC_ALL=C
dir="$1/mail"
frag="$1/traefik/dynamic/_mail.yml"
mdata="$2/mail"

emit() {
    local enc=""
    if [ -f "$2" ]; then enc=$(openssl base64 -A -in "$2" 2>/dev/null) || enc=""; fi
    printf '%s=%s\n' "$1" "$enc"
}

emit mail_compose_b64  "$dir/compose.yml"
emit mail_registry_b64 "$dir/kasbah.yml"
emit mail_fragment_b64 "$frag"

# Three states, because the verdict differs for each. `empty` is a file that
# exists and holds no account — a run that died between creating the tree and
# seeding it — and is seeded like an absent one. `present` is the state that
# must never be written over: it is every mailbox on the server.
accounts="$mdata/dms/config/postfix-accounts.cf"
state=absent
if [ -f "$accounts" ]; then
    state=empty
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%$'\r'}
        case $line in
            ''|'#'*) ;;
            *) state=present; break ;;
        esac
    done < "$accounts"
fi
printf 'mail_accounts=%s\n' "$state"

# Deliberately *not* reported here: whether the Rspamd DKIM override already
# exists. Nothing on this side decides anything with it — the seed step is
# copy-if-missing and tests the file where it is about to write it, and reports
# mail_dkim_seed=kept/seeded, which is what the caller and the summary read. A
# fact with no verdict behind it is a fact that reads as a safety mechanism and
# is not one, so it is left to whichever later command grows a use for it.

# Refused rather than worked around, and here rather than in mkdir: a file where
# the mail directory belongs stops the whole stack, and `mkdir -p` says
# "File exists" about it.
if [ -e "$dir" ] && [ ! -d "$dir" ]; then printf 'mail_dir=notdir\n'
elif [ -d "$dir" ];                  then printf 'mail_dir=dir\n'
else                                      printf 'mail_dir=absent\n'
fi
exit 0
REMOTE
    ) || rc=$?

    [ "$rc" -eq 0 ] \
        || die "could not read the mail stack on $_SI_TARGET (the remote step exited $rc, see above)"

    _si_absorb_checked "the mail stack read" "$out" \
        mail_compose_b64 mail_registry_b64 mail_fragment_b64 \
        mail_accounts mail_dir

    case "${_SI_FACT[mail_accounts]}" in
        absent|empty|present) ;;
        *) die "the mail stack read on $_SI_TARGET reported mail_accounts='${_SI_FACT[mail_accounts]}', which this kasbah does not know" ;;
    esac
    case "${_SI_FACT[mail_dir]}" in
        absent|dir) ;;
        notdir)
            err "$_SI_APPS_PATH/mail on $_SI_TARGET exists and is not a directory"
            err_cont "that is where the shared mail stack lives — its compose file, its .env and"
            err_cont "its registry. Look at it, remove it, and re-run. Nothing has been changed."
            exit 1
            ;;
        *) die "the mail stack read on $_SI_TARGET reported mail_dir='${_SI_FACT[mail_dir]}', which this kasbah does not know" ;;
    esac

    _SI_MAIL_CURRENT=()
    for rel in "${_SI_MAIL_FILES[@]}"; do
        enc="${_SI_FACT[${_SI_MAIL_KEY[$rel]}]}"
        # The `printf x` sentinel keeps trailing newlines, which $(…) strips.
        dec=$( { printf '%s' "$enc" | base64 -d 2>/dev/null; printf x; } )
        _SI_MAIL_CURRENT[$rel]="${dec%x}"
    done
    return 0
}

# The registry's two values, reproduced from the server when it has them and
# invented once when it does not. Same rule as the dashboard domain, and for a
# sharper reason: `primary_domain` is the MX target and the name both
# certificates are issued for, so a re-run that quietly moved it would abandon
# two certificates and every DNS record pointing at them.
#
# The default is --domain's apex, not a prompt. It is not an assumption: the
# operator has already named that apex on this command line or on an earlier
# run, `traefik.<apex>` is served from it, and mail.<apex>/webmail.<apex> are
# the names docs/mail.md uses throughout. An operator who wants a different one
# edits kasbah.yml once and every later run honours it.
_server_init_mail_registry() {
    local stored_primary="" stored_count="" stored_domain="" i=0
    local rc=0
    local registry="${_SI_MAIL_CURRENT[kasbah.yml]}"

    yaml_get "$registry" '.primary_domain // ""' stored_primary || rc=$?
    if [ "$rc" -ne 0 ]; then
        err "$_SI_APPS_PATH/mail/kasbah.yml on $_SI_TARGET could not be read as YAML"
        err_cont "that file is the mail stack's registry — the one thing that says which"
        err_cont "domains this server's mail handles — and kasbah reproduces what is in it"
        err_cont "rather than regenerating it. Guessing past a file it cannot parse would"
        err_cont "move the MX hostname and abandon two certificates. Fix it, or remove it to"
        err_cont "start the registry over from --domain."
        exit 1
    fi

    if [ -n "$stored_primary" ]; then
        _SI_MAIL_PRIMARY="$stored_primary"
        _SI_MAIL_PRIMARY_ORIGIN=reused
    else
        _SI_MAIL_PRIMARY="$_SI_DASHBOARD_DOMAIN"
        _SI_MAIL_PRIMARY_ORIGIN=domain
    fi
    _si_check_yaml_scalar "the mail primary domain" "$_SI_MAIL_PRIMARY"
    _is_fqdn "$_SI_MAIL_PRIMARY" \
        || die "server init: the mail stack's primary domain is '$_SI_MAIL_PRIMARY', which is not a domain name (it is the MX target, and mail.<domain> is what DMS's certificate is issued for)"

    # Read one at a time rather than as a block, so a domain carrying a newline
    # cannot smuggle a second list entry into the rendered file.
    _SI_MAIL_DOMAINS=()
    yaml_get "$registry" '(.domains // []) | length' stored_count || rc=$?
    [ "$rc" -eq 0 ] || die "internal: the mail registry parsed once and not twice"
    case $stored_count in ''|*[!0-9]*) stored_count=0 ;; esac
    while [ "$i" -lt "$stored_count" ]; do
        yaml_get "$registry" "(.domains // [])[$i] // \"\"" stored_domain || rc=$?
        [ "$rc" -eq 0 ] || die "internal: the mail registry parsed once and not twice"
        i=$((i + 1))
        [ -n "$stored_domain" ] || continue
        _si_check_yaml_scalar "a domain in the mail registry" "$stored_domain"
        _is_fqdn "$stored_domain" \
            || die "server init: $_SI_APPS_PATH/mail/kasbah.yml lists '$stored_domain' under domains:, which is not a domain name"
        _SI_MAIL_DOMAINS+=("$stored_domain")
    done

    # The primary is always served by the stack it is the MX for, so it is in
    # the list whether or not anyone wrote it there. Prepended rather than
    # appended: the list is read in order and the primary is the one every other
    # domain's MX points at.
    local d found=no
    for d in ${_SI_MAIL_DOMAINS[@]+"${_SI_MAIL_DOMAINS[@]}"}; do
        [ "$d" != "$_SI_MAIL_PRIMARY" ] || { found=yes; break; }
    done
    if [ "$found" != yes ]; then
        _SI_MAIL_DOMAINS=("$_SI_MAIL_PRIMARY" ${_SI_MAIL_DOMAINS[@]+"${_SI_MAIL_DOMAINS[@]}"})
    fi
    return 0
}

# The postmaster account, which exists because Dovecot panics within 120 s if
# postfix-accounts.cf holds none (docs/mail.md → Pre-seeding). Asked for on the
# workstation and hashed here; only the hash travels, exactly as the dashboard
# password does.
#
# Asked **once**. A server that already has an account is not asked again and
# not written to: the file holds every mailbox on the host, and a re-run of init
# that rotated the postmaster password would be a re-run that locked somebody
# out.
_server_init_mail_values() {
    local pass="" hash=""

    [ "$_SI_MAIL_ENABLED" = yes ] || return 0

    _server_init_mail_registry

    if [ "${_SI_FACT[mail_accounts]}" = present ]; then
        _SI_MAIL_ACCOUNT_LINE=""
        _SI_MAIL_ACCOUNT_ORIGIN=existing
        _si_postmaster_flag_unused
        return 0
    fi

    if [ -n "$_SI_POSTMASTER_PASSWORD" ]; then
        pass="$_SI_POSTMASTER_PASSWORD"
        _SI_MAIL_ACCOUNT_ORIGIN=flag
    else
        prompt_secret postmaster-password \
            "Password for postmaster@$_SI_MAIL_PRIMARY (seeded before DMS starts; DMS will not boot without an account)" \
            "" pass
        _si_check_postmaster_password "$pass"
        _SI_MAIL_ACCOUNT_ORIGIN=prompt
    fi

    _si_sha512_crypt "$pass" hash
    # The shape docker-mailserver's own file provisioner writes: one line of
    # `<address>|<scheme><hash>`, delimiter `|`, scheme prefix included
    # (verified against the pinned image's helpers/database/db.sh).
    _SI_MAIL_ACCOUNT_LINE="postmaster@$_SI_MAIL_PRIMARY|{SHA512-CRYPT}$hash"
    return 0
}

# --postmaster-password on a run that already has an account. A warning rather
# than a refusal, for the reason a spare --reset-acme is: a fleet script sets it
# once and meets servers that are already seeded, and failing those runs is what
# would make the flag unusable. It is emphatically not an offer to rotate — that
# is `docker exec mail-dms setup email update`.
_si_postmaster_flag_unused() {
    [ -n "$_SI_POSTMASTER_PASSWORD" ] || return 0
    warn "--postmaster-password had no effect: postmaster is already in"
    warn "$_SI_DATA_PATH/mail/dms/config/postfix-accounts.cf on $_SI_TARGET, and init never rewrites that file"
    warn "to change the password: ssh $_SI_TARGET 'docker exec -it mail-dms setup email update postmaster@$_SI_MAIL_PRIMARY'"
    return 0
}

# Renders the mail templates beside the Traefik ones, into the same temp
# directory the EXIT trap already removes. Only the three YAML files are parsed
# before shipping — .env and the Rspamd override are not YAML, and both are
# handled by the seed step rather than rsynced.
_server_init_mail_render() {
    local rel dst yq_err d domains=""
    local tpl="${KASBAH_TEMPLATE_DIR:-}"

    [ "$_SI_MAIL_ENABLED" = yes ] || return 0

    [ -n "$tpl" ] || die "internal: KASBAH_TEMPLATE_DIR is not set"
    [ -d "$tpl/mail" ] \
        || die "the mail templates are missing (looked in $tpl/mail) — this kasbah installation is incomplete"
    [ -n "$_SI_TMPDIR" ] || die "internal: the mail render ran before the Traefik one made a temp directory"

    # Built here rather than in the template because the list has a variable
    # number of entries. Every element has already been checked as a domain
    # name, so nothing in it can start a second YAML key.
    for d in "${_SI_MAIL_DOMAINS[@]}"; do
        domains+="${domains:+$'\n'}  - $d"
    done

    _SI_SUBST=(
        [APPS_PATH]="$_SI_APPS_PATH"
        [DATA_PATH]="$_SI_DATA_PATH"
        [MAIL_PRIMARY_DOMAIN]="$_SI_MAIL_PRIMARY"
        [MAIL_HOSTNAME]="mail.$_SI_MAIL_PRIMARY"
        [MAIL_DOMAINS]="$domains"
    )

    for rel in "${_SI_MAIL_FILES[@]}"; do
        dst="$_SI_TMPDIR/mail/$rel"
        _si_render_template "$tpl/mail/$rel" "$dst" "mail $rel"

        # The same guarantee the Traefik render gives, and one file here carries
        # a sharper version of it: _mail.yml lands in the directory Traefik
        # watches, so a document that does not parse is a fragment the running
        # proxy rejects while going on answering /ping.
        if ! yq_err="$(yq -e . "$dst" 2>&1 >/dev/null)"; then
            err "the rendered mail $rel is not valid YAML — refusing to ship it"
            err_cont "${yq_err:-yq rejected the file and said nothing}"
            err_cont "a substituted value is the likely cause; this run rendered it with:"
            err_cont "  primary domain  $_SI_MAIL_PRIMARY"
            err_cont "  domains         ${_SI_MAIL_DOMAINS[*]}"
            err_cont "  apps / data     $_SI_APPS_PATH, $_SI_DATA_PATH"
            exit 1
        fi
    done

    # Not YAML and not shipped by rsync: the seed step decides whether either
    # one may be written at all, so both are rendered here and handed over as
    # arguments.
    _si_render_template "$tpl/mail/env" "$_SI_TMPDIR/mail/env" "mail .env"
    _si_render_template "$tpl/mail/rspamd-dkim-signing.conf" \
        "$_SI_TMPDIR/mail/dkim_signing.conf" "mail dkim_signing.conf"
    return 0
}

# The mail tree, the .env, and the two files that are seeded once. All of it
# before Traefik starts, and all of it before DMS could possibly run: the
# postmaster account and the DKIM override both have to be in place *before* the
# container's first boot, one because Dovecot panics without an account and the
# other because DMS's dkim helper writes its own default over an override that
# is not already there.
#
# Nothing here is destructive. The .env is merged key by key, the two seeds are
# written only when absent, and the mail data directories are mkdir -p.
#
# The account arrives as an argument, so it is in the remote `bash`'s argv for
# as long as the step runs. What is in it is the SHA512-CRYPT *hash*: the
# password was typed on the workstation and hashed there, and never crosses the
# wire in any form. That much it shares with the dashboard's bcrypt entry —
# hashed on the workstation, never the cleartext — and no more: the bcrypt entry
# is rendered into _shared.yml and rsynced, so it never enters any argv, while
# this hash sits in the remote process table for the length of this step. Both
# are hashes, so what is exposed there is a hash. The .env travels the same way
# and carries no secret; the operator's relay block is the one thing in that
# file this step never sends and never reads back.
_server_init_mail_layout() {
    local out rc=0 env_default dkim

    [ "$_SI_MAIL_ENABLED" = yes ] || return 0

    env_default="$(cat "$_SI_TMPDIR/mail/env"; printf x)" || die "could not read the rendered mail .env"
    env_default="${env_default%x}"
    dkim="$(cat "$_SI_TMPDIR/mail/dkim_signing.conf"; printf x)" || die "could not read the rendered dkim_signing.conf"
    dkim="${dkim%x}"

    out=$(ssh_script "$_SI_APPS_PATH" "$_SI_DATA_PATH" "$_SI_MAIL_PRIMARY" \
                     "$env_default" "$dkim" "$_SI_MAIL_ACCOUNT_LINE" <<'REMOTE'
set -uo pipefail
export LC_ALL=C
apps=$1
data=$2
primary=$3
env_default=$4
dkim=$5
account_line=$6

dir="$apps/mail"
mdata="$data/mail"

fail() { printf 'remote: %s\n' "$*" >&2; exit 1; }

# Every bind-mount source, created here because Docker materialises a missing
# one as a root-owned *directory* — the same trap acme.json is guarded against,
# and the reason everything below the apps path is otherwise the deploy user's.
#
# Only snappymail/ itself, never the tree inside it, and that is not tidiness.
# SnappyMail's entrypoint chowns its whole data directory to its own uid at mode
# 750 on first boot, so from the second run on the deploy user cannot traverse
# it — and `mkdir -p a/b/c` walks *into* `a` even when the whole path is already
# there, while `mkdir -p a` on an existing `a` succeeds without entering it
# (measured both ways). A kasbah that pre-created
# snappymail/_data_/_default_/domains therefore worked once and then failed
# every re-run with "mkdir: cannot create directory '.../snappymail':
# Permission denied". It has no reason to: SnappyMail builds that tree itself,
# domains/ included, which is where a per-project config is seeded
# (docs/mail.md). What kasbah owes it is the bind-mount source, because Docker
# materialises a missing one as a *root*-owned directory — the same trap
# acme.json is guarded against.
for d in "$dir" \
         "$mdata/dms/mail-data" "$mdata/dms/mail-state" "$mdata/dms/mail-logs" \
         "$mdata/dms/config/rspamd/override.d" \
         "$mdata/snappymail"; do
    mkdir -p "$d" || fail "could not create $d"
done

# The .env, and the one file here with two owners. Three keys are kasbah's and
# are rewritten by name on every run; every other line is copied through
# untouched, which is what lets a relay credential set by hand survive without
# ever crossing the wire. A key kasbah owns that the file does not carry is
# appended rather than silently dropped.
env_file="$dir/.env"
if [ -e "$env_file" ] && [ ! -f "$env_file" ]; then
    fail "$env_file exists and is not a regular file"
fi
if [ ! -f "$env_file" ]; then
    tmp="$env_file.tmp.$$"
    printf '%s' "$env_default" > "$tmp" || fail "could not write $tmp"
    chmod 600 "$tmp" || fail "could not set mode 600 on $tmp"
    mv -f "$tmp" "$env_file" || fail "could not install $env_file"
    printf 'mail_env=created\n'
else
    # The values kasbah owns, pulled out of the rendered default so this side
    # never has to know their spelling twice.
    want_hostname=""; want_domain=""; want_data=""
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%$'\r'}
        case $line in
            MAIL_HOSTNAME=*) want_hostname=${line#*=} ;;
            DOMAIN=*)        want_domain=${line#*=} ;;
            DATA_PATH=*)     want_data=${line#*=} ;;
        esac
    done <<EOF
$env_default
EOF

    merged=""
    saw_hostname=no; saw_domain=no; saw_data=no
    while IFS= read -r line || [ -n "$line" ]; do
        stripped=${line%$'\r'}
        case $stripped in
            MAIL_HOSTNAME=*) line="MAIL_HOSTNAME=$want_hostname"; saw_hostname=yes ;;
            DOMAIN=*)        line="DOMAIN=$want_domain";          saw_domain=yes ;;
            DATA_PATH=*)     line="DATA_PATH=$want_data";         saw_data=yes ;;
        esac
        merged="$merged$line
"
    done < "$env_file"
    [ "$saw_hostname" = yes ] || merged="${merged}MAIL_HOSTNAME=$want_hostname
"
    [ "$saw_domain" = yes ]   || merged="${merged}DOMAIN=$want_domain
"
    [ "$saw_data" = yes ]     || merged="${merged}DATA_PATH=$want_data
"

    current=$(cat "$env_file"; printf x) || fail "could not read $env_file"
    current=${current%x}
    if [ "$current" = "$merged" ]; then
        printf 'mail_env=unchanged\n'
    else
        tmp="$env_file.tmp.$$"
        printf '%s' "$merged" > "$tmp" || fail "could not write $tmp"
        chmod 600 "$tmp" || fail "could not set mode 600 on $tmp"
        mv -f "$tmp" "$env_file" || fail "could not install $env_file"
        printf 'mail_env=rewritten\n'
    fi
fi

# Every run, on every branch, exactly as the layout step chmods acme.json: the
# mode is a fact about the file rather than about this run, and the two branches
# that write are not the ones that need it. An .env left 644 by a hand edit or
# by an older kasbah is otherwise `mail_env=unchanged` forever, with
# docs/server-setup.md's tree describing a mode that never converges — and the
# thing being kept from the rest of the machine is the operator's relay
# credential, which this step never reads and never re-sends.
chmod 600 "$env_file" || fail "could not set mode 600 on $env_file"

# The postmaster account. Written only when the caller decided one was needed —
# it hands over an empty line otherwise — and even then only onto a file with no
# account in it. This file holds every mailbox on the server.
accounts="$mdata/dms/config/postfix-accounts.cf"
if [ -e "$accounts" ] && [ ! -f "$accounts" ]; then
    fail "$accounts exists and is not a regular file"
fi
if [ -z "$account_line" ]; then
    printf 'mail_account=kept\n'
elif [ -s "$accounts" ]; then
    printf 'mail_account=kept\n'
else
    tmp="$accounts.tmp.$$"
    printf '%s\n' "$account_line" > "$tmp" || fail "could not write $tmp"
    chmod 600 "$tmp" || fail "could not set mode 600 on $tmp"
    mv -f "$tmp" "$accounts" || fail "could not install $accounts"
    printf 'mail_account=seeded\n'
fi

# The Rspamd DKIM override, copy-if-missing. Once DMS has run `setup config
# dkim` this file names real key paths, and re-shipping kasbah's copy over it
# would break signing for a domain added after this run.
dkim_file="$mdata/dms/config/rspamd/override.d/dkim_signing.conf"
if [ -e "$dkim_file" ] && [ ! -f "$dkim_file" ]; then
    fail "$dkim_file exists and is not a regular file"
fi
if [ -f "$dkim_file" ]; then
    printf 'mail_dkim_seed=kept\n'
else
    tmp="$dkim_file.tmp.$$"
    printf '%s' "$dkim" > "$tmp" || fail "could not write $tmp"
    chmod 644 "$tmp" || fail "could not set mode 644 on $tmp"
    mv -f "$tmp" "$dkim_file" || fail "could not install $dkim_file"
    printf 'mail_dkim_seed=seeded\n'
fi

printf 'mail_layout=done\n'
exit 0
REMOTE
    ) || rc=$?

    [ "$rc" -eq 0 ] \
        || die "could not lay out the mail stack on $_SI_TARGET (the remote step exited $rc, see above)"

    _si_absorb_checked "the mail layout step" "$out" \
        mail_layout mail_env mail_account mail_dkim_seed
    return 0
}

# Ships only what differs, the same rule and the same rsync as the Traefik
# stack. _mail.yml goes to Traefik's watch directory rather than to <apps>/mail,
# so the destination is looked up rather than derived from the name.
_server_init_mail_sync() {
    local rel rendered dest
    local changed=()

    [ "$_SI_MAIL_ENABLED" = yes ] || return 0

    for rel in "${_SI_MAIL_FILES[@]}"; do
        rendered="$(cat "$_SI_TMPDIR/mail/$rel"; printf x)" \
            || die "could not read $_SI_TMPDIR/mail/$rel"
        rendered="${rendered%x}"
        [ "$rendered" != "${_SI_MAIL_CURRENT[$rel]}" ] || continue
        changed+=("$rel")
    done

    _SI_MAIL_CHANGED=(${changed[@]+"${changed[@]}"})
    [ "${#changed[@]}" -gt 0 ] || return 0

    for rel in "${changed[@]}"; do
        dest="$_SI_APPS_PATH/${_SI_MAIL_DEST[$rel]}"
        ssh_rsync -pt --chmod=F644 "$_SI_TMPDIR/mail/$rel" "$SSH_TARGET:$dest" >/dev/null \
            || die "could not ship the mail $rel to $_SI_TARGET:$dest"
    done
    return 0
}

# Starts the stack, and waits for exactly one of its two containers.
#
# SnappyMail is waited for because it settles in about ten seconds whatever else
# is true. **DMS is not**, and that is not a shortcut: `SSL_TYPE: letsencrypt`
# makes a certificate for mail.<domain> a *boot requirement*, so on a first run
# DMS crashloops until Traefik finishes the HTTP-01 exchange and writes the
# certificate into acme.json — 30-90 s on a real host (the original project's own setup
# guide records the same window). Where the challenge cannot validate at all —
# no public DNS, which is every test rig — it crashloops forever, and a wait
# would turn "mail is not reachable from the internet yet" into "init failed".
# Its state is reported instead, and the caller says what it means.
_server_init_mail_start() {
    local out rc=0

    [ "$_SI_MAIL_ENABLED" = yes ] || return 0

    out=$(ssh_script "$_SI_APPS_PATH" "$_SI_MAIL_PROJECT" 180 <<'REMOTE'
set -uo pipefail
export LC_ALL=C
apps=$1
project=$2
timeout_s=$3

fail() { printf 'remote: %s\n' "$*" >&2; exit 1; }

cd "$apps/mail" || fail "could not enter $apps/mail"

# -p on every call, for the reason templates/traefik/compose.yml gives: `name:`
# in the file is the weakest source of the project name and COMPOSE_PROJECT_NAME
# in this login shell outranks it.
dc() { docker compose -p "$project" "$@"; }

dc up -d || fail "docker compose -p $project up -d failed in $apps/mail"

sm=$(dc ps -a -q mail-snappymail 2>/dev/null) || sm=""
[ -n "$sm" ] || fail "compose reported no mail-snappymail container after up -d"
dms=$(dc ps -a -q mail-dms 2>/dev/null) || dms=""
[ -n "$dms" ] || fail "compose reported no mail-dms container after up -d"

health_of() {
    docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null \
        || printf gone
}

deadline=$((SECONDS + timeout_s))
health=""
while :; do
    health=$(health_of "$sm")
    [ "$health" != healthy ] || break
    if [ "$health" = none ]; then
        printf 'remote: the mail-snappymail container declares no healthcheck — compose.yml lost it\n' >&2
        dc ps -a >&2 || true
        exit 1
    fi
    running=$(docker inspect -f '{{.State.Running}}' "$sm" 2>/dev/null) || running=false
    if [ "$running" != true ]; then
        printf 'remote: mail-snappymail is not running (health %s) — it exited instead of coming up\n' "$health" >&2
        dc ps -a >&2 || true
        dc logs --no-color --tail 60 mail-snappymail >&2 || true
        exit 1
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
        printf 'remote: mail-snappymail did not report healthy within %ss (last health: %s)\n' "$timeout_s" "$health" >&2
        dc ps -a >&2 || true
        dc logs --no-color --tail 60 mail-snappymail >&2 || true
        exit 1
    fi
    sleep 2
done

printf 'mail_snappymail_health=%s\n' "$health"
printf 'mail_dms_state=%s\n' "$(docker inspect -f '{{.State.Status}}' "$dms" 2>/dev/null)"
printf 'mail_dms_health=%s\n' "$(health_of "$dms")"
printf 'mail_dms_restarts=%s\n' "$(docker inspect -f '{{.RestartCount}}' "$dms" 2>/dev/null)"
printf 'mail_dms_image=%s\n' "$(docker inspect -f '{{.Config.Image}}' "$dms" 2>/dev/null)"
exit 0
REMOTE
    ) || rc=$?

    [ "$rc" -eq 0 ] \
        || die "could not start the mail stack on $_SI_TARGET (the remote step exited $rc, see above)"

    _si_absorb_checked "the mail start" "$out" \
        mail_snappymail_health mail_dms_state mail_dms_health \
        mail_dms_restarts mail_dms_image
    return 0
}

# What the mail stack ended up as, and — when DMS is not healthy — what that
# most likely means. Not being healthy at this instant is ordinary rather than
# wrong, so it is said out loud rather than left for the operator to find in
# `docker ps` and misread.
_server_init_report_mail() {
    local shipped="nothing re-rendered"

    [ "$_SI_MAIL_ENABLED" = yes ] || return 0

    [ "${#_SI_MAIL_CHANGED[@]}" -eq 0 ] || shipped="shipped ${_SI_MAIL_CHANGED[*]}"
    info "  mail: $_SI_APPS_PATH/mail ($shipped)"
    info "        domains: ${_SI_MAIL_DOMAINS[*]} (primary $_SI_MAIL_PRIMARY, $_SI_MAIL_PRIMARY_ORIGIN)"
    info "        routers: mail.$_SI_MAIL_PRIMARY (cert-trigger, no backend), https://webmail.$_SI_MAIL_PRIMARY"
    info "        .env ${_SI_FACT[mail_env]}, postmaster ${_SI_FACT[mail_account]}, dkim override ${_SI_FACT[mail_dkim_seed]}"
    info "        snappymail ${_SI_FACT[mail_snappymail_health]}, dms ${_SI_FACT[mail_dms_state]} (${_SI_FACT[mail_dms_health]}, ${_SI_FACT[mail_dms_restarts]} restarts)"
    info "        setup guide: kasbah server mail-setup-guide $_SI_TARGET"

    [ "${_SI_FACT[mail_dms_health]}" != healthy ] || { _server_init_mail_guide; return 0; }

    # Two different things look the same at this instant, and the warning has to
    # be true of both. A container that was just created or recreated is inside
    # its healthcheck's 60 s start_period and will go green on its own; a
    # container that cannot find its certificate crashloops. Restarts tell them
    # apart *once they have happened*, and at the moment this runs they usually
    # have not — so the message names the certificate trap without asserting it,
    # rather than telling an operator their perfectly ordinary re-run is a
    # crashloop.
    warn "mail-dms is ${_SI_FACT[mail_dms_state]} and its healthcheck says '${_SI_FACT[mail_dms_health]}' (${_SI_FACT[mail_dms_restarts]} restarts so far)."
    warn "that is expected right after a start: the healthcheck has a 60 s start_period."
    warn "if it does not settle, the reason is almost always the certificate."
    warn "  SSL_TYPE=letsencrypt makes one for mail.$_SI_MAIL_PRIMARY a *boot* requirement, so"
    warn "  DMS restarts until Traefik has finished the HTTP-01 exchange and written it into"
    warn "  acme.json — 30-90 s on a first run, and forever if that hostname does not resolve"
    warn "  to this host from the public internet. Check in a minute:"
    warn "  ssh $_SI_TARGET 'docker inspect -f \"{{.State.Health.Status}}\" mail-dms'"
    warn "  ssh $_SI_TARGET 'docker logs --tail 40 mail-dms'"
    _server_init_mail_guide
    return 0
}

# The walkthrough, printed once: on the run that created the stack, and never
# again (docs/mail.md). `mail_dir` is read before anything is created, so
# `absent` there is exactly "this run is the one that made it" — and a re-run
# gets the one-line pointer above instead, because an operator re-running init
# is not looking for a 150-line guide.
#
# server_mail.sh is sourced here rather than at the top of this file: it sources
# *this* one for the template renderer, and a load guard only makes that safe
# once every function in here is defined.
_server_init_mail_guide() {
    [ "${_SI_FACT[mail_dir]:-}" = absent ] || return 0

    . "$KASBAH_LIB_DIR/server_mail.sh"
    _SM_TARGET="$_SI_TARGET"
    _SM_APPS_PATH="$_SI_APPS_PATH"
    _SM_DATA_PATH="$_SI_DATA_PATH"
    _SM_PRIMARY="$_SI_MAIL_PRIMARY"
    _SM_DOMAINS=("${_SI_MAIL_DOMAINS[@]}")
    # Init never asks the server for its own address, so the guide renders the
    # placeholder here and the standalone command fills it in.
    _SM_HOST_ADDR=""
    printf '\n'
    _sm_guide_print
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
    # Answered here and acted on much later: the mail stack's own questions
    # cannot be asked until the server has been read, and this one decides
    # whether that read happens at all.
    if prompt_bool mail "Scaffold the mail stack (DMS + SnappyMail) on $_SI_TARGET?" "$_SI_MAIL"; then
        _SI_MAIL_ENABLED=yes
    else
        _SI_MAIL_ENABLED=no
    fi
    if prompt_bool backup "Install the restic backup stack on $_SI_TARGET?" "$_SI_BACKUP"; then
        _BK_ENABLED=yes
    else
        _BK_ENABLED=no
        # Said before anything is asked or opened: a flag that will do nothing
        # is worth naming while the operator is still at the prompt.
        _bk_flags_unused
    fi

    ssh_connect "$_SI_TARGET"

    _server_init_probe
    _server_init_read_marker
    _server_init_elevation
    _server_init_preflight "$_SI_TARGET" "$_SI_APPS_PATH" "$_SI_ELEVATE"
    _server_init_check_marker
    _server_init_check_pointer
    _server_limits "${_SI_FACT[nproc]}" "${_SI_FACT[memtotal_kb]}"

    # The backup configuration this server already records, so a re-run with no
    # backup flags reproduces it instead of asking again — and so `--no-backup`
    # against a server that has it says so rather than looking like a removal.
    [ "$_BK_ENABLED" != yes ] || _bk_from_marker "$_SI_MARKER_EXISTING"
    _bk_note_left_alone "$_SI_TARGET" "$_SI_APPS_PATH" "$_SI_MARKER_EXISTING"

    # Everything the Traefik stack needs is settled — asked for or recovered
    # from the server — and rendered before the first directory is created, so
    # a run nobody can answer and a template that will not render both cost
    # nothing on the far side.
    _server_init_read_traefik
    _server_init_read_mail
    _bk_read "$_SI_TARGET" "$_SI_APPS_PATH" "$_SI_DATA_PATH"
    _server_init_traefik_values
    _server_init_mail_values
    _bk_values "$_SI_TARGET"
    _server_init_traefik_render
    _server_init_mail_render
    _bk_render "$_SI_TMPDIR" "$_SI_APPS_PATH" "$_SI_DATA_PATH"

    # Computed once every value it records is settled, and written by the last
    # step of all. Its `backup` object is what --with-backup decided, or nothing
    # — and nothing means the object already on the server is left alone.
    local marker_json backup_json
    backup_json="$(_bk_marker_json)"
    marker_json="$(_server_marker_json "$KASBAH_VERSION" "$_SI_APPS_PATH" \
        "$_SI_DATA_PATH" "$_SI_CPU_LIMIT" "$_SI_MEM_LIMIT" "$_SI_MARKER_EXISTING" "$backup_json")"

    _server_init_layout
    _server_init_traefik_sync
    # Before the Traefik start, deliberately. _mail.yml is a file-provider
    # fragment, so a Traefik that comes up with it already in the watch
    # directory requests both certificates at configuration load rather than
    # waiting for the watcher — which is about ten seconds of head start on the
    # certificate DMS cannot boot without. The seeds land here for a harder
    # reason: they have to exist before DMS's *first* start, and that is the
    # step after next.
    _server_init_mail_layout
    _server_init_mail_sync
    _server_init_acme_reset
    _server_init_traefik_start
    # docs/server-setup.md's ordering rule, and the only part of it that is not
    # free: mail needs the Traefik stack running, because DMS reads
    # mail.<domain>'s certificate out of acme.json and nothing puts one there
    # until the cert-trigger router above is live.
    #
    # This half of the rule already defends itself, and by accident:
    # templates/mail/compose.yml declares kasbah-net `external: true`, and the
    # Traefik start is what creates it — so a mail start moved above it dies in
    # `docker compose up` on a network that does not exist. That is a loud
    # failure rather than a wrong one, which is why no test asserts this
    # ordering directly; the fragment-before-Traefik ordering above has no such
    # backstop and is pinned in tests/integration/server_init_mail_test.sh.
    _server_init_mail_start

    # The backup stack, last of the things that are started, and in this order
    # for one reason: the credentials have to be on the server before the probe
    # can test the ones that will actually be in effect, and the stack must not
    # be started with a credential the probe then refuses. So the tree and the
    # secrets land, the probe runs, and only a credential that could write and
    # could not delete gets a scheduler. A refusal leaves the credentials where
    # they are — the next run reuses them — and no marker, because that is still
    # the last thing init writes.
    _bk_layout "$_SI_TARGET" "$_SI_APPS_PATH"
    _bk_ship_secrets "$_SI_TARGET" "$_SI_APPS_PATH"
    _bk_probe "$_SI_TARGET" "$_SI_APPS_PATH"
    _bk_sync "$_SI_TARGET" "$_SI_APPS_PATH"
    _bk_start "$_SI_TARGET" "$_SI_APPS_PATH"

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
    _server_init_report_mail
    _bk_report "$_SI_TARGET" "$_SI_APPS_PATH"
    info "  marker: $_SI_APPS_PATH/.kasbah/server.json (${_SI_FACT[marker]})"
    info "  pointer: $KASBAH_APPS_POINTER -> $_SI_APPS_PATH (${_SI_FACT[pointer]})"
}
