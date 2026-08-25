# kasbah — the VPS-aware half of `kasbah check` (--server)
# Sourced by lib/check.sh, never on its own: the ✓/⚠/✗ printers and the
# counters live there. Do not execute directly.

[ -n "${_KASBAH_CHECK_SERVER_LOADED:-}" ] && return 0
_KASBAH_CHECK_SERVER_LOADED=1

. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/ssh.sh"
. "$KASBAH_LIB_DIR/marker.sh"
. "$KASBAH_LIB_DIR/env.sh"
. "$KASBAH_LIB_DIR/acme.sh"
# For last_server: `check --server` is on docs/project-manifest.md's list of
# commands that read and write it, so a bare `--server` means the server this
# project last talked to.
. "$KASBAH_LIB_DIR/state.sh"

# `kasbah check --server USER@HOST` adds the six rules docs/compliance.md lists
# under that heading to the local run: the project directory, `.env` drift
# against the *current* `.env.prod.example`, M03, the health container's health,
# certificate status out of Traefik's acme.json, and R04. It also tightens T05
# from a first-label heuristic to the exact hostnames this server's Traefik and
# mail stack claim — see `check_server_reserved_hosts`.
#
# **It writes nothing.** Every remote step is a read: `[ -f ]`, `openssl base64
# -A -in`, and `docker inspect`. There is no mkdir, no touch, no redirection
# onto the server's filesystem, and no `docker` verb that changes anything. The
# integration suite digests the apps and data trees across a run rather than
# taking this paragraph's word for it.
#
# Two round trips: `marker_read` discovers the apps path, the data path and the
# host's limits, then one batched step brings back everything else. The far side
# never needs jq, yq or python3 — files come back as base64 and are parsed here,
# which is the same rule the mail registry and the server marker are read under.

_CS_TARGET=""
declare -A _CS_FACT=()
# Decoded payloads. `_CS_ENV` holds the project's secrets and `_CS_ACME` holds
# private key material: neither is ever printed, and nothing below writes either
# to a file.
_CS_ENV=""
_CS_ACME=""
_CS_REGISTRY=""
_CS_SHARED=""
# T05's answer, in two halves, because the two hostname families have two
# sources and either can be unreadable on its own:
#   _CS_RESERVED   the exact hostnames whose source *was* read, one per line;
#   _CS_HEURISTIC  the first DNS labels whose source was not, one per line —
#                  those fall back to the local first-label heuristic, so an
#                  unreadable file can never turn a claim into a silent pass.
# _CS_RESERVED_NOTE is the sentence for the case where neither was read.
_CS_RESERVED=""
_CS_HEURISTIC=""
_CS_RESERVED_NOTE=""
_CS_APEX=""
_CS_MAIL_PRIMARY=""

# --- Discovery ------------------------------------------------------------------

# The manifest's mail domain, read under the same shape guard the local Mail
# section reads it under: `.mail.domain` against a `mail: example.com` is a jq
# type error, and the operator would get kasbah's internal filter rather than
# the mistake in their manifest.
_cs_manifest_mail_domain() {
    local kind d
    kind="$(yq -r '.mail | type' "$KASBAH_MANIFEST_FILE" 2>/dev/null || true)"
    [ "${kind%$'\r'}" = object ] || return 0
    d="$(yq -r '.mail.domain // ""' "$KASBAH_MANIFEST_FILE" 2>/dev/null || true)"
    printf '%s' "${d%$'\r'}"
    return 0
}

_cs_manifest_health_container() {
    local c
    c="$(yq -r '.health.container // ""' "$KASBAH_MANIFEST_FILE" 2>/dev/null || true)"
    c="${c%$'\r'}"
    [ "$c" != null ] || c=""
    printf '%s' "$c"
    return 0
}

# Folds the report into the fact table and checks the key set before any of it
# is read: a truncated step must not be absorbed into a passing verdict.
#
# **The raw output is never echoed**, which is where this parts company with
# `_ss_absorb_checked`. That helper clips to twenty lines of 120 bytes and
# prints them, and this payload carries acme.json — 120 bytes of
# `Account.PrivateKey` on stderr is 120 bytes of private key on stderr. What a
# reader needs to tell a truncated step from a rejected one is which keys
# arrived, and those are names kasbah chose.
_cs_absorb_checked() {
    local _ac_out="$1"; shift
    local _ac_line _ac_key _ac_seen="" _ac_missing=()

    while IFS= read -r _ac_line; do
        _ac_line="${_ac_line%$'\r'}"
        case $_ac_line in *=*) _CS_FACT[${_ac_line%%=*}]="${_ac_line#*=}" ;; esac
    done <<<"$_ac_out"

    for _ac_key in "$@"; do
        if [ -n "${_CS_FACT[$_ac_key]+set}" ]; then
            _ac_seen="$_ac_seen $_ac_key"
        else
            _ac_missing+=("$_ac_key")
        fi
    done
    if [ "${#_ac_missing[@]}" -gt 0 ]; then
        err "the check probe on $_CS_TARGET reported no ${_ac_missing[*]}"
        err_cont "the step was truncated, or the remote shell rejected it. Its output is not"
        err_cont "shown: it carries acme.json, which holds private key material. What did"
        err_cont "arrive:${_ac_seen:- nothing}"
        exit 1
    fi
    return 0
}

# base64 -d into <outvar> without letting a bad payload end the run silently: a
# plain `x="$(… | base64 -d)"` is fatal under errexit, so the process would die
# before the caller's message about a corrupt payload could run. Written as a
# `||` list, which errexit exempts, so the caller decides what a failure means.
_cs_b64_into() {
    local _bd_out="$2" _bd_val=""
    printf -v "$_bd_out" '%s' ""
    [ -n "$1" ] || return 0
    _bd_val="$(printf '%s' "$1" | base64 -d 2>/dev/null)" || return 1
    printf -v "$_bd_out" '%s' "$_bd_val"
    return 0
}

# check_server_stored_target OUTVAR — the server this project last talked to,
# for a bare `--server`. The refusal is _ops_resolve_target's, in the same
# shape: a remedy the reader can act on, naming the file the value lives in.
check_server_stored_target() {
    local _st_out="$1" _st_stored=""

    state_get last_server _st_stored
    if [ -z "$_st_stored" ] || [ "$_st_stored" = null ]; then
        err "check: --server was given no server, and this project has never talked to one"
        err_cont "pass it once — \`kasbah check --server user@vps\` — and it is remembered in"
        err_cont "$KASBAH_STATE_FILE as last_server"
        exit 1
    fi
    printf -v "$_st_out" '%s' "$_st_stored"
    return 0
}

# check_server_connect TARGET — the connection, the marker and the one batched
# read, in that order. Runs before the local sections so T05 can be answered
# against this server's real hostnames rather than the first-label heuristic.
check_server_connect() {
    _CS_TARGET="$1"

    ssh_connect "$_CS_TARGET"
    # ssh_target_parse has normalised it; report what ssh was actually given.
    _CS_TARGET="$SSH_TARGET"
    marker_read "$_CS_TARGET"

    _cs_collect
    _cs_decode

    # Recorded once the server has answered, not once the rules have: the
    # operation this command performed is the read, and its verdicts are about
    # the project rather than about which server was asked
    # (docs/project-manifest.md → the write rule, and `kasbah exec`'s reading
    # of it). Local, and the only thing this command writes anywhere.
    state_record last_server "$_CS_TARGET"
    return 0
}

_cs_collect() {
    local out rc=0

    out=$(ssh_script "$MARKER_APPS_PATH" "$MARKER_DATA_PATH" "$MANIFEST_NAME" \
                     "$(_cs_manifest_health_container)" <<'REMOTE'
set -uo pipefail
export LC_ALL=C
apps=$1
data=$2
name=$3
health=$4
dir="$apps/$name"
acme="$data/traefik/letsencrypt/acme.json"

# One line per value: the reader parses this output as a protocol, so a
# command's multi-line complaint would arrive as extra keys. Every file travels
# base64'd on one line. openssl rather than coreutils' `base64 -w0`: openssl is
# on the prerequisites table and base64 is not.
b64() {
    local enc=""
    if [ -f "$2" ] && [ -r "$2" ]; then
        enc=$(openssl base64 -A -in "$2" 2>/dev/null) || enc=""
    fi
    printf '%s=%s\n' "$1" "$enc"
}

# Six states, because they have six different remedies — and in particular
# because a file that is there and cannot be read is the acme.json case an
# operator can act on, while "absent" and "empty" are not the same news either.
fstate() {
    local p="$2" s=""
    if   [ ! -e "$p" ];  then s=absent
    elif [ -d "$p" ];    then s=dir
    elif [ ! -f "$p" ];  then s=notfile
    elif [ ! -r "$p" ];  then s=unreadable
    elif [ ! -s "$p" ];  then s=empty
    else                      s=file
    fi
    printf '%s=%s\n' "$1" "$s"
}

if   [ -d "$dir" ]; then printf 'project_state=dir\n'
elif [ -e "$dir" ]; then printf 'project_state=notdir\n'
else                     printf 'project_state=absent\n'
fi

fstate env_state      "$dir/.env"
b64    env_b64        "$dir/.env"
fstate registry_state "$apps/mail/kasbah.yml"
b64    registry_b64   "$apps/mail/kasbah.yml"
fstate shared_state   "$apps/traefik/dynamic/_shared.yml"
b64    shared_b64     "$apps/traefik/dynamic/_shared.yml"
fstate acme_state     "$acme"
b64    acme_b64       "$acme"

# State and health are two facts: a container that is `restarting` has no
# health status yet and one without a HEALTHCHECK never will, and neither is
# the same answer as "there is no such container".
#
# And "there is no such container" is not the same answer as "the daemon is not
# answering" either — `docker inspect` fails identically for both, and an
# operator told their container is not running when dockerd is down goes and
# looks at the wrong thing. So a failed inspect is followed by one `docker
# version`, which is the cheapest question that separates them; its stderr
# travels back flattened to one line, because this output is a protocol.
docker_error=""
if [ -z "$health" ]; then
    printf 'health_state=skipped\nhealth_health=skipped\n'
elif ! command -v docker >/dev/null 2>&1; then
    printf 'health_state=nodocker\nhealth_health=nodocker\n'
else
    s=$(docker inspect -f '{{.State.Status}}' "$health" 2>/dev/null) || s=""
    if [ -z "$s" ]; then
        if derr=$(docker version --format '{{.Server.Version}}' 2>&1 >/dev/null); then
            s=absent
        else
            s=nodaemon
            docker_error=$(printf '%s' "$derr" | tr -d '\r' | tr '\n' ' ')
        fi
    fi
    h=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
        "$health" 2>/dev/null) || h=""
    [ -n "$h" ] || h=none
    printf 'health_state=%s\n' "$s"
    printf 'health_health=%s\n' "$h"
fi
while [ "${docker_error% }" != "$docker_error" ]; do docker_error="${docker_error% }"; done
printf 'docker_error=%s\n' "$docker_error"
exit 0
REMOTE
    ) || rc=$?

    [ "$rc" -eq 0 ] \
        || die "could not read $MARKER_APPS_PATH on $_CS_TARGET (the remote step exited $rc, see above)"

    _cs_absorb_checked "$out" \
        project_state env_state env_b64 registry_state registry_b64 \
        shared_state shared_b64 acme_state acme_b64 \
        health_state health_health docker_error
    return 0
}

# The three payloads, decoded once. A blob that is not base64 leaves its
# variable empty and the rule that reads it says so — the alternative is a
# decode failure killing the run under errexit before any verdict prints.
_cs_decode() {
    _cs_b64_into "${_CS_FACT[env_b64]}"      _CS_ENV      || _CS_ENV=""
    _cs_b64_into "${_CS_FACT[registry_b64]}" _CS_REGISTRY || _CS_REGISTRY=""
    _cs_b64_into "${_CS_FACT[shared_b64]}"   _CS_SHARED   || _CS_SHARED=""
    _cs_b64_into "${_CS_FACT[acme_b64]}"     _CS_ACME     || _CS_ACME=""

    local rc=0
    traefik_dashboard_apex "$_CS_SHARED" _CS_APEX || rc=$?
    [ "$rc" -eq 0 ] || _CS_APEX=""
    rc=0
    yaml_get "$_CS_REGISTRY" '.primary_domain // ""' _CS_MAIL_PRIMARY || rc=$?
    [ "$rc" -eq 0 ] || _CS_MAIL_PRIMARY=""

    _cs_build_reserved
    return 0
}

# The hostnames kasbah owns on *this* server, which is what T05 is really about:
# `traefik.<apex>` is the dashboard's, and `mail.<primary>` / `webmail.<primary>`
# are the two the mail fragment claims.
#
# **Per family, and that is the whole point.** The dashboard hostname comes out
# of <apps>/traefik/dynamic/_shared.yml and the mail pair out of the registry,
# so one of the two can be unreadable, reshaped by a Traefik upgrade, or hand
# edited while the other is fine. A set built as one list would then be
# non-empty — and the exact-match branch would run with `traefik.<apex>` guarded
# by nothing at all: not by the set, because it is not in it, and not by the
# heuristic, because that branch was skipped. A project claiming the dashboard
# hostname would pass T05 in silence. So each family answers for itself: known
# means exact, unknown means the local first-label heuristic for that family's
# labels, and nothing is ever unguarded.
#
# The mail pair falls back to the apex when there is no registry to read a
# primary out of, and that is exact rather than heuristic: `server init
# --with-mail` defaults primary_domain to the apex, so `mail.<apex>` and
# `webmail.<apex>` are precisely what this server would claim the day mail is
# enabled. A registry that names some *other* primary is the case where
# `mail.<apex>` is genuinely not reserved, and reading it is what tells them
# apart.
_cs_build_reserved() {
    local base=""
    _CS_RESERVED=""
    _CS_HEURISTIC=""
    _CS_RESERVED_NOTE=""

    if [ -n "$_CS_APEX" ]; then
        _CS_RESERVED="traefik.$_CS_APEX"
    else
        _CS_HEURISTIC="traefik"
    fi

    base="$_CS_MAIL_PRIMARY"
    [ -n "$base" ] || base="$_CS_APEX"
    if [ -n "$base" ]; then
        _CS_RESERVED="${_CS_RESERVED:+$_CS_RESERVED$'\n'}mail.$base"
        _CS_RESERVED="$_CS_RESERVED"$'\n'"webmail.$base"
    else
        _CS_HEURISTIC="${_CS_HEURISTIC:+$_CS_HEURISTIC$'\n'}mail"
        _CS_HEURISTIC="$_CS_HEURISTIC"$'\n'"webmail"
    fi

    if [ -z "$_CS_RESERVED" ]; then
        _CS_RESERVED_NOTE=" — heuristic: $_CS_TARGET was asked and neither its dashboard fragment nor a mail registry could be read"
    fi
    return 0
}

# The exact hostnames for T05, one per line. Empty means every family fell back.
check_server_reserved_hosts() {
    printf '%s' "$_CS_RESERVED"
    return 0
}

# The first labels T05 must still match by heuristic, one per line. Empty means
# every family was read off the server.
check_server_heuristic_labels() {
    printf '%s' "$_CS_HEURISTIC"
    return 0
}

# The sentence for a run that could read neither source, appended to the
# heuristic's own line so an operator who asked a server knows it could not tell
# them anything. Empty otherwise: when one family is exact, the line already
# names which of them is the heuristic's.
check_server_reserved_note() {
    printf '%s' "$_CS_RESERVED_NOTE"
    return 0
}

# --- The rules ------------------------------------------------------------------

check_server_section() {
    echo
    printf 'Server (%s at %s):\n' "$_CS_TARGET" "$MARKER_APPS_PATH"

    _cs_project_dir
    _cs_env_drift
    _cs_m03_mail_domain
    _cs_health
    _cs_cert
    _cs_r04_limits
    return 0
}

# Does the project dir exist on the VPS? A warning rather than a failure:
# docs/compliance.md calls `check --server` a pre-deploy sanity check, and a
# project that has not been deployed yet is the ordinary state that check is run
# in. Every rule below that needs the directory says it is skipped rather than
# reporting a verdict about a tree that is not there.
_cs_project_dir() {
    local dir="$MARKER_APPS_PATH/$MANIFEST_NAME"
    case "${_CS_FACT[project_state]}" in
        dir)
            _check_pass "$dir exists on $_CS_TARGET"
            ;;
        notdir)
            _check_fail "$dir on $_CS_TARGET exists and is not a directory — a deploy would try to write the project into it"
            ;;
        *)
            _check_warn "$dir does not exist on $_CS_TARGET — nothing has been deployed there yet, so the server rules below have nothing to read"
            ;;
    esac
    return 0
}

# E02/E03 against the server's real `.env`, compared with *this checkout's*
# `.env.prod.example` — the current one, which is the whole point of asking the
# server rather than trusting the copy that was shipped with the last deploy.
#
# `env_drift` is the same function in the same bytes that runs on the VPS as
# scripts/setup-env.sh, so the local check and the remote one cannot drift apart
# by agreeing to differ (docs/compliance.md → Env). It takes paths, and the
# server's `.env` is deliberately not written to one: it holds the project's
# secrets, so it is handed over as a process substitution and read out of the
# pipe. Only key *names* are ever printed.
_cs_env_drift() {
    [ "${_CS_FACT[project_state]}" = dir ] || return 0

    if [ ! -f .env.prod.example ]; then
        _check_warn "no .env.prod.example in this checkout, so $MARKER_APPS_PATH/$MANIFEST_NAME/.env on $_CS_TARGET cannot be checked for drift (S04 has already failed)"
        return 0
    fi

    case "${_CS_FACT[env_state]}" in
        file|empty) ;;
        absent)
            _check_warn "$MARKER_APPS_PATH/$MANIFEST_NAME/.env does not exist on $_CS_TARGET — the next deploy will run the interactive setup to write one"
            return 0
            ;;
        unreadable)
            _check_warn "$MARKER_APPS_PATH/$MANIFEST_NAME/.env on $_CS_TARGET cannot be read by this user, so its keys cannot be compared with .env.prod.example"
            return 0
            ;;
        *)
            _check_fail "$MARKER_APPS_PATH/$MANIFEST_NAME/.env on $_CS_TARGET is not a regular file (it is ${_CS_FACT[env_state]}) — compose reads that path as the project's environment"
            return 0
            ;;
    esac

    if [ -z "$_CS_ENV" ] && [ "${_CS_FACT[env_state]}" = file ]; then
        _check_warn "$MARKER_APPS_PATH/$MANIFEST_NAME/.env on $_CS_TARGET did not come back as readable bytes, so its keys cannot be compared with .env.prod.example"
        return 0
    fi

    ENV_DRIFT_MISSING=""
    ENV_DRIFT_EXTRA=""
    env_drift .env.prod.example <(printf '%s' "$_CS_ENV")

    if [ -z "$ENV_DRIFT_MISSING" ]; then
        _check_pass ".env on $_CS_TARGET has no missing keys vs .env.prod.example"
    else
        _check_warn ".env on $_CS_TARGET is missing keys vs .env.prod.example: $ENV_DRIFT_MISSING"
    fi
    if [ -z "$ENV_DRIFT_EXTRA" ]; then
        _check_pass ".env on $_CS_TARGET has no extra keys vs .env.prod.example"
    else
        _check_warn ".env on $_CS_TARGET has extra keys not in .env.prod.example: $ENV_DRIFT_EXTRA"
    fi
    return 0
}

# M03: the mail stack on this server knows the domain the manifest claims. The
# registry at <apps>/mail/kasbah.yml is the single answer to "does this VPS's
# mail stack serve X?" (docs/mail.md), and it is read one key at a time — never
# as one combined parse — so a newline inside a value cannot smuggle an extra
# list entry into the answer.
#
# Fail, not warn, and that is the difference between this and `kasbah deploy`:
# deploy warns because an unmet claim costs mail rather than the site, and
# stopping a deploy over an unpublished MX record is the worse failure. `check`
# is where the same fact is a named rule with a level (docs/compliance.md → M03).
_cs_m03_mail_domain() {
    local domain reg="$MARKER_APPS_PATH/mail/kasbah.yml"
    domain="$(_cs_manifest_mail_domain)"
    [ -n "$domain" ] || return 0

    if [ "${_CS_FACT[registry_state]}" = absent ]; then
        _check_fail "$MANIFEST_NAME claims the mail domain '$domain', and there is no mail stack on $_CS_TARGET ($reg is not there) — enable it with: kasbah server init $_CS_TARGET --with-mail"
        return 0
    fi
    if [ -z "$_CS_REGISTRY" ]; then
        _check_warn "$MANIFEST_NAME claims the mail domain '$domain', and $reg on $_CS_TARGET is ${_CS_FACT[registry_state]} — the registry is the only thing that answers whether this stack serves a domain, so the claim cannot be checked"
        return 0
    fi

    local rc=0 count="" primary="" d="" i=0
    yaml_get "$_CS_REGISTRY" '(.domains // []) | length' count || rc=$?
    if [ "$rc" -ne 0 ]; then
        _check_warn "$MANIFEST_NAME claims the mail domain '$domain', and $reg on $_CS_TARGET does not parse as YAML — the claim cannot be checked against a registry kasbah cannot read"
        return 0
    fi
    case $count in ''|*[!0-9]*) count=0 ;; esac

    # The primary is served by the stack it is the MX for whether or not anyone
    # wrote it under domains: — the same rule `server init` renders the file
    # under and `server add-mail-domain` reads it under.
    yaml_get "$_CS_REGISTRY" '.primary_domain // ""' primary || primary=""
    if [ "$primary" = "$domain" ]; then
        _check_pass "the mail stack on $_CS_TARGET serves '$domain' (its primary_domain)"
        return 0
    fi

    while [ "$i" -lt "$count" ]; do
        yaml_get "$_CS_REGISTRY" "(.domains // [])[$i] // \"\"" d || d=""
        i=$((i + 1))
        [ -n "$d" ] || continue
        if [ "$d" = "$domain" ]; then
            _check_pass "the mail stack on $_CS_TARGET serves '$domain' (listed under domains:)"
            return 0
        fi
    done

    _check_fail "the mail stack on $_CS_TARGET does not serve '$domain' — $reg lists ${primary:-no primary_domain} and $count domain(s); add it with: kasbah server add-mail-domain $_CS_TARGET $domain"
    return 0
}

# Is the manifest's health.container currently healthy, if deployed? H02 has
# already checked that the name exists in compose; this is the same name asked
# of the running server.
_cs_health() {
    local c state="${_CS_FACT[health_state]}" health="${_CS_FACT[health_health]}"
    c="$(_cs_manifest_health_container)"
    [ -n "$c" ] || return 0
    [ "$state" != skipped ] || return 0

    if [ "$state" = nodocker ]; then
        _check_warn "no docker on $_CS_TARGET, so the health of '$c' cannot be read"
        return 0
    fi
    # Reported as itself, not folded into "not running": the container may well
    # be fine, and the thing to look at is the daemon.
    if [ "$state" = nodaemon ]; then
        _check_warn "the docker daemon on $_CS_TARGET is not answering, so the health of '$c' cannot be read — nothing here says the container is down (docker said: ${_CS_FACT[docker_error]:-nothing})"
        return 0
    fi
    if [ "$state" = absent ]; then
        if [ "${_CS_FACT[project_state]}" = dir ]; then
            _check_warn "manifest health.container '$c' is not running on $_CS_TARGET — the project is deployed, so either it was stopped or the container is named something else there"
        else
            _check_warn "manifest health.container '$c' is not running on $_CS_TARGET (nothing has been deployed there yet)"
        fi
        return 0
    fi

    case "$health" in
        healthy)
            _check_pass "manifest health.container '$c' is $state and healthy on $_CS_TARGET"
            ;;
        unhealthy)
            _check_fail "manifest health.container '$c' is $state and UNHEALTHY on $_CS_TARGET — Traefik keeps routing to it, so this is live"
            ;;
        starting)
            _check_warn "manifest health.container '$c' is $state and still starting on $_CS_TARGET"
            ;;
        none)
            _check_warn "manifest health.container '$c' is $state on $_CS_TARGET and declares no healthcheck, so nothing there reports health (H01)"
            ;;
        *)
            _check_warn "manifest health.container '$c' is $state on $_CS_TARGET and reports health '$health'"
            ;;
    esac
    return 0
}

# Certificate status for the manifest domain, out of Traefik's acme.json.
#
# Nothing here prints the store, a certificate's `.key` or the resolver's
# account key — see lib/acme.sh. What is reported is the issuer, the expiry and
# the days left, and **not** an age: `notBefore` is backdated ~58.5 minutes by
# Let's Encrypt, so a certificate cannot say when it was issued.
_cs_cert() {
    local acme="$MARKER_DATA_PATH/traefik/letsencrypt/acme.json"
    local d="$MANIFEST_DOMAIN"

    if [ -z "$d" ]; then
        _check_warn "the manifest names no domain, so there is no certificate to look for in $acme"
        return 0
    fi

    case "${_CS_FACT[acme_state]}" in
        absent)
            _check_warn "no certificate store at $acme on $_CS_TARGET — \`kasbah server init\` creates it, so this server's Traefik is not the one kasbah prepared"
            return 0
            ;;
        empty)
            _check_warn "the certificate store at $acme on $_CS_TARGET is empty — Traefik has not issued anything yet, so '$d' is served with its self-signed default"
            return 0
            ;;
        unreadable)
            _check_warn "$acme on $_CS_TARGET cannot be read by this user, so the certificate for '$d' cannot be checked — the store is mode 600 and owned by the deploy user on a server kasbah prepared"
            return 0
            ;;
        file) ;;
        *)
            _check_warn "$acme on $_CS_TARGET is ${_CS_FACT[acme_state]}, not a regular file — Traefik bind-mounts that path as its certificate store"
            return 0
            ;;
    esac

    if [ -z "$_CS_ACME" ]; then
        _check_warn "$acme on $_CS_TARGET did not come back as readable bytes, so the certificate for '$d' cannot be checked"
        return 0
    fi

    acme_lookup "$_CS_ACME" "$d"
    case "$ACME_STATE" in
        found)      _cs_cert_verdict "$d" ;;
        empty)      _check_warn "the certificate store at $acme on $_CS_TARGET holds no certificates — nothing has been issued for '$d' yet" ;;
        nomatch)    _check_warn "no certificate for '$d' in $acme on $_CS_TARGET ($ACME_COUNT in the store) — Traefik issues one when a router claims the hostname and it resolves to this server" ;;
        notjson)    _check_warn "$acme on $_CS_TARGET does not parse as JSON, so the certificate for '$d' cannot be read (its bytes are not shown: the store holds private key material)" ;;
        noresolver) _check_warn "$acme on $_CS_TARGET has no '$ACME_RESOLVER' store — that resolver name is a frozen contract, so either the schema has shifted with a Traefik upgrade or this Traefik is configured with another one" ;;
        notarray)   _check_warn "$acme on $_CS_TARGET holds a '$ACME_RESOLVER' whose Certificates is a $ACME_KIND, not a list — the store's schema is not the one this kasbah reads" ;;
        nocert)     _check_warn "the entry for '$d' in $acme on $_CS_TARGET carries no certificate field — the store's schema is not the one this kasbah reads" ;;
        notbase64)  _check_warn "the certificate for '$d' in $acme on $_CS_TARGET is not base64 — the store's schema is not the one this kasbah reads" ;;
        *)          _check_warn "the certificate for '$d' in $acme on $_CS_TARGET is not a certificate openssl reads" ;;
    esac
    return 0
}

# Expiry is the verdict, and it has three bands. Traefik renews at 30 days
# remaining, so a certificate inside two weeks has already failed to renew
# twice and somebody has to look at why.
_cs_cert_verdict() {
    local d="$1" via="" issuer="${ACME_ISSUER:-unknown issuer}"
    [ "$ACME_MAIN" = "$d" ] || via=" (as a SAN of $ACME_MAIN)"

    if [ -z "$ACME_DAYS" ]; then
        _check_warn "certificate for '$d'$via from $issuer expires $ACME_NOTAFTER (unparseable date, so no days remaining)"
        return 0
    fi
    if [ "$ACME_DAYS" -lt 0 ]; then
        _check_fail "certificate for '$d'$via EXPIRED $(( -ACME_DAYS )) day(s) ago ($ACME_NOTAFTER, $issuer) — Traefik renews at 30 days remaining, so renewal has been failing"
        return 0
    fi
    if [ "$ACME_DAYS" -le 14 ]; then
        _check_warn "certificate for '$d'$via expires in $ACME_DAYS day(s) ($ACME_NOTAFTER, $issuer) — Traefik renews at 30 days remaining, so renewal has already missed its window"
        return 0
    fi
    _check_pass "certificate for '$d'$via valid for $ACME_DAYS more day(s) (until $ACME_NOTAFTER, $issuer)"
    return 0
}

# R04: the limits the containers actually get, against the ceiling this host
# was measured at. `server init` computes 90% of the host's cores and RAM into
# the marker, deploy injects those two numbers into the project's `.env` as
# KASBAH_CPU_LIMIT / KASBAH_MEM_LIMIT, and compose interpolates them into every
# service's `cpus:` and `mem_limit:` (R01/R02 pin that they are references and
# not literals). So the effective limit is what that `.env` says today, and the
# ceiling is what the marker says.
#
# Above the ceiling fails: the whole point of the number is that one project
# cannot take the host. Below it warns, because deliberately tighter is allowed
# — but it is nearly always a `.env` that stopped being rewritten, so it is not
# silent either.
_cs_r04_limits() {
    [ "${_CS_FACT[project_state]}" = dir ] || return 0
    case "${_CS_FACT[env_state]}" in file|empty) ;; *) return 0 ;; esac

    local cpu="" mem=""
    _cs_env_value "$_CS_ENV" KASBAH_CPU_LIMIT cpu
    _cs_env_value "$_CS_ENV" KASBAH_MEM_LIMIT mem

    if [ -z "$cpu" ] && [ -z "$mem" ]; then
        _check_warn "$MARKER_APPS_PATH/$MANIFEST_NAME/.env on $_CS_TARGET carries no KASBAH_CPU_LIMIT or KASBAH_MEM_LIMIT, so there is no effective limit to compare with the host's ${MARKER_CPU_LIMIT} cpus / ${MARKER_MEM_LIMIT} — every deploy rewrites that block, so it has been edited out"
        return 0
    fi

    local verdict=ok note=""
    local cpu_v mem_v

    _cs_cmp_cpu "$cpu" "$MARKER_CPU_LIMIT" cpu_v
    _cs_cmp_mem "$mem" "$MARKER_MEM_LIMIT" mem_v

    case "$cpu_v" in
        above)   verdict=above; note="cpus $cpu > $MARKER_CPU_LIMIT" ;;
        below)   verdict=below; note="cpus $cpu < $MARKER_CPU_LIMIT" ;;
        unknown) note="cpus '${cpu:-unset}' is not a number" ;;
    esac
    case "$mem_v" in
        above)   note="${note:+$note; }mem_limit $mem > $MARKER_MEM_LIMIT"
                 verdict=above ;;
        below)   note="${note:+$note; }mem_limit $mem < $MARKER_MEM_LIMIT"
                 [ "$verdict" = above ] || verdict=below ;;
        unknown) note="${note:+$note; }mem_limit '${mem:-unset}' is not a size" ;;
    esac

    case "$verdict" in
        above)
            _check_fail "effective resource limits on $_CS_TARGET are above the host's 90% ceiling: $note — kasbah's limits are anti-takeover ceilings, and one project over them can take the host down"
            ;;
        below)
            _check_warn "effective resource limits on $_CS_TARGET are below the host's 90% ceiling: $note — deliberately tighter is allowed, but every deploy rewrites the KASBAH_* block, so this is usually a stale .env"
            ;;
        *)
            if [ -n "$note" ]; then
                _check_warn "effective resource limits on $_CS_TARGET could not all be compared with the host's ${MARKER_CPU_LIMIT} cpus / ${MARKER_MEM_LIMIT}: $note"
            else
                _check_pass "effective resource limits on $_CS_TARGET match the host's 90% ceiling ($cpu cpus, $mem)"
            fi
            ;;
    esac
    return 0
}

# _cs_env_value CONTENT KEY OUTVAR — the value of one assignment, last one wins,
# which is how compose and dotenv read a file with a key repeated. Read through
# ENV_ASSIGN_RE, the same shape lib/env.sh reads assignments under, so
# `export KASBAH_CPU_LIMIT=1` counts here exactly as it does there.
_cs_env_value() {
    local _ev_content="$1" _ev_key="$2" _ev_out="$3" _ev_line
    printf -v "$_ev_out" '%s' ""
    [ -n "$_ev_content" ] || return 0
    while IFS= read -r _ev_line; do
        _ev_line="${_ev_line%$'\r'}"
        [[ "$_ev_line" =~ $ENV_ASSIGN_RE ]] || continue
        [ "${BASH_REMATCH[2]}" = "$_ev_key" ] || continue
        printf -v "$_ev_out" '%s' "${BASH_REMATCH[3]}"
    done <<<"$_ev_content"
    # The loop ends on read returning 1 at EOF; under errexit a bare call would
    # propagate that.
    return 0
}

# above / below / same / unknown. awk rather than `[ -gt ]` because a cpu limit
# is a decimal — `14.4` is what `server init` writes — and bash refuses one.
_cs_cmp_cpu() {
    local _cc_a="${1%$'\r'}" _cc_b="${2%$'\r'}" _cc_out="$3" _cc_v
    printf -v "$_cc_out" '%s' unknown
    [[ "$_cc_a" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 0
    [[ "$_cc_b" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 0
    _cc_v=$(awk -v a="$_cc_a" -v b="$_cc_b" \
        'BEGIN { if (a > b) print "above"; else if (a < b) print "below"; else print "same" }')
    printf -v "$_cc_out" '%s' "$_cc_v"
    return 0
}

# The same for a memory size, in the spellings compose accepts (`54g`, `512m`,
# a bare byte count). Compared in bytes, so `1024m` and `1g` are the same limit.
_cs_cmp_mem() {
    local _cm_out="$3" _cm_a _cm_b
    printf -v "$_cm_out" '%s' unknown
    _cs_mem_bytes "$1" _cm_a || return 0
    _cs_mem_bytes "$2" _cm_b || return 0
    if   [ "$_cm_a" -gt "$_cm_b" ]; then printf -v "$_cm_out" '%s' above
    elif [ "$_cm_a" -lt "$_cm_b" ]; then printf -v "$_cm_out" '%s' below
    else                                 printf -v "$_cm_out" '%s' same
    fi
    return 0
}

# _cs_mem_bytes VALUE OUTVAR — 1 when the value is not a size compose reads.
_cs_mem_bytes() {
    local _mb_v="${1%$'\r'}" _mb_out="$2" _mb_n _mb_unit _mb_mult=1
    _mb_v="${_mb_v,,}"
    [[ "$_mb_v" =~ ^([0-9]+)(b|k|kb|m|mb|g|gb)?$ ]] || return 1
    _mb_n="${BASH_REMATCH[1]}"
    _mb_unit="${BASH_REMATCH[2]}"
    case "$_mb_unit" in
        k|kb) _mb_mult=1024 ;;
        m|mb) _mb_mult=$((1024 * 1024)) ;;
        g|gb) _mb_mult=$((1024 * 1024 * 1024)) ;;
    esac
    printf -v "$_mb_out" '%s' "$((_mb_n * _mb_mult))"
    return 0
}
