# kasbah — the mail stack's own server commands
# Sourced by libexec/kasbah-bash. Do not execute directly.

[ -n "${_KASBAH_SERVER_MAIL_LOADED:-}" ] && return 0
_KASBAH_SERVER_MAIL_LOADED=1

. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/ssh.sh"
. "$KASBAH_LIB_DIR/marker.sh"
# For _si_render_template and the mail templates it renders: <apps>/mail/kasbah.yml
# has exactly one renderer, in templates/mail/kasbah.yml, and `add-mail-domain`
# rewriting it by hand would be a second one — the drift docs/mail.md's "this
# file is the registry, and nothing else is" exists to prevent. Sourcing
# server_init.sh is how this file gets it; the load guard makes it free when
# init is the caller.
. "$KASBAH_LIB_DIR/server_init.sh"

# Two commands that talk to a mail stack `kasbah server init --with-mail` has
# already put on the server (docs/mail.md):
#
#   add-mail-domain USER@HOST <domain>  joins <domain> to the shared stack
#   mail-setup-guide USER@HOST          prints the post-install walkthrough
#
# Both read <apps>/mail/kasbah.yml — the registry, and the only thing asked
# "does this stack serve X?" — by base64ing it back and parsing it with the
# workstation's yq. The VPS has no yq, jq or python3 and keeping it that way is
# deliberate.
#
# Where the tree is comes from lib/marker.sh, the same discovery `deploy` and
# `env` use: these commands act on a server kasbah has already prepared, so the
# pointer and the marker are both there to be read, and the marker is where the
# data path comes from. Neither takes --apps-path.

_SM_TARGET=""
_SM_DOMAIN=""
_SM_APPS_PATH=""
_SM_DATA_PATH=""

# What the read step brought back.
declare -A _SM_FACT=()
_SM_REGISTRY=""
_SM_ALIASES=""
_SM_PRIMARY=""
_SM_DOMAINS=()
# The address this ssh session reached the server on. Best effort: it is what
# the server sees as the local end of the connection, which is the public IP for
# a VPS reached over the internet and something else entirely behind NAT — so
# every place it is printed says where it came from.
_SM_HOST_ADDR=""
# Where the registry is rendered before it is shipped. A global, not a local:
# the EXIT trap that removes it fires long after the function that made it has
# returned, and under `set -u` a trap naming an out-of-scope local is a run that
# ends in "unbound variable" instead of in its own report.
_SM_TMPDIR=""

_sm_cleanup() {
    [ -n "$_SM_TMPDIR" ] || return 0
    rm -rf "$_SM_TMPDIR"
    _SM_TMPDIR=""
    return 0
}

# --- The shared read ------------------------------------------------------------

_sm_absorb() {
    local _ab_out="$1"; shift
    local _ab_line _ab_key _ab_missing=()

    while IFS= read -r _ab_line; do
        _ab_line="${_ab_line%$'\r'}"
        case $_ab_line in *=*) _SM_FACT[${_ab_line%%=*}]="${_ab_line#*=}" ;; esac
    done <<<"$_ab_out"

    for _ab_key in "$@"; do
        [ -n "${_SM_FACT[$_ab_key]+set}" ] || _ab_missing+=("$_ab_key")
    done
    [ "${#_ab_missing[@]}" -eq 0 ] \
        || die "the mail read on $_SM_TARGET reported no ${_ab_missing[*]} — the step was truncated, or the remote shell rejected it"
    return 0
}

# base64 back into a variable, keeping trailing newlines: the `printf x`
# sentinel is there because $(…) strips them and a registry that lost its last
# newline is a registry this command would rewrite on every run.
_sm_b64_into() {
    local _bi_out="$2" _bi_dec
    _bi_dec=$( { printf '%s' "$1" | base64 -d 2>/dev/null; printf x; } )
    printf -v "$_bi_out" '%s' "${_bi_dec%x}"
    return 0
}

# Everything both commands read, in one round trip, and nothing is written by
# it: `mail-setup-guide` is read-only against the server and this is the whole
# of what it does there.
_sm_read() {
    local out rc=0

    out=$(ssh_script "$_SM_APPS_PATH" "$_SM_DATA_PATH" <<'REMOTE'
set -uo pipefail
export LC_ALL=C
dir="$1/mail"
aliases="$2/mail/dms/config/postfix-virtual.cf"

emit() {
    local enc=""
    if [ -f "$2" ] && [ -r "$2" ]; then enc=$(openssl base64 -A -in "$2" 2>/dev/null) || enc=""; fi
    printf '%s=%s\n' "$1" "$enc"
}

if [ -e "$dir" ] && [ ! -d "$dir" ]; then printf 'mail_dir=notdir\n'
elif [ -d "$dir" ];                  then printf 'mail_dir=dir\n'
else                                      printf 'mail_dir=absent\n'
fi
if [ -f "$dir/.env" ]; then printf 'mail_env=yes\n'; else printf 'mail_env=no\n'; fi

emit mail_registry_b64 "$dir/kasbah.yml"
# The alias file as bytes, and nothing about it as a state. Every reason it
# might not arrive — not there, not a file, not readable by this user because
# docker-mailserver rewrote it as root — lands on the same verdict on the other
# side: kasbah cannot see the alias, so it tries to write it, and the write step
# reports what actually happened. A state word here would be a fact with no
# verdict behind it, which reads as a safety mechanism and is not one.
emit mail_aliases_b64  "$aliases"

# The local end of this ssh connection as the server sees it — field 3 of
# SSH_CONNECTION. Empty rather than guessed when the variable is not set.
addr=""
if [ -n "${SSH_CONNECTION:-}" ]; then
    set -- $SSH_CONNECTION
    [ $# -lt 3 ] || addr=$3
fi
printf 'host_addr=%s\n' "$addr"
exit 0
REMOTE
    ) || rc=$?

    [ "$rc" -eq 0 ] \
        || die "could not read the mail stack on $_SM_TARGET (the remote step exited $rc, see above)"

    _sm_absorb "$out" mail_dir mail_env mail_registry_b64 mail_aliases_b64 host_addr

    case "${_SM_FACT[mail_dir]}" in
        dir) ;;
        absent|notdir)
            err "there is no mail stack at $_SM_APPS_PATH/mail on $_SM_TARGET"
            err_cont "that directory is where the shared stack lives — its compose file, its .env"
            err_cont "and its registry. Install it with:"
            err_cont "  kasbah server init $_SM_TARGET --with-mail"
            exit 1
            ;;
        *) die "the mail read on $_SM_TARGET reported mail_dir='${_SM_FACT[mail_dir]}', which this kasbah does not know" ;;
    esac

    # A stack with a registry and no .env is one `server init --with-mail` did
    # not finish: compose interpolates MAIL_HOSTNAME, DOMAIN and DATA_PATH out
    # of that file, so nothing here can start. The domain is still added — the
    # registry is the thing this command owns — and the operator is told the
    # stack it was added to cannot come up as it stands.
    if [ "${_SM_FACT[mail_env]}" != yes ]; then
        warn "$_SM_APPS_PATH/mail on $_SM_TARGET has no .env, so that stack cannot start as it stands"
        warn "compose reads MAIL_HOSTNAME, DOMAIN and DATA_PATH out of it — re-run:"
        warn "  kasbah server init $_SM_TARGET --with-mail"
    fi

    _sm_b64_into "${_SM_FACT[mail_registry_b64]}" _SM_REGISTRY
    _sm_b64_into "${_SM_FACT[mail_aliases_b64]}"  _SM_ALIASES
    _SM_HOST_ADDR="${_SM_FACT[host_addr]}"
    return 0
}

# The registry, read one key at a time. Not as one combined parse: a newline
# inside a domain value cannot then smuggle an extra list entry past the
# per-entry check below, which is the rule `server init` reads it under.
_sm_read_registry() {
    local rc=0 count="" d="" i=0

    [ -n "$_SM_REGISTRY" ] || {
        err "$_SM_APPS_PATH/mail/kasbah.yml on $_SM_TARGET is missing or empty"
        err_cont "that file is the mail stack's registry — the one thing that says which"
        err_cont "domains this server's mail handles. Re-run:"
        err_cont "  kasbah server init $_SM_TARGET --with-mail"
        exit 1
    }

    yaml_get "$_SM_REGISTRY" '.primary_domain // ""' _SM_PRIMARY || rc=$?
    if [ "$rc" -ne 0 ]; then
        err "$_SM_APPS_PATH/mail/kasbah.yml on $_SM_TARGET could not be read as YAML"
        err_cont "kasbah reproduces what is in that file rather than regenerating it, so a"
        err_cont "file it cannot parse is one it will not rewrite. Fix it and re-run."
        exit 1
    fi
    [ -n "$_SM_PRIMARY" ] \
        || die "$_SM_APPS_PATH/mail/kasbah.yml on $_SM_TARGET has no primary_domain: — it is the MX target and the name both certificates are issued for, and nothing here can invent it"
    _is_fqdn "$_SM_PRIMARY" \
        || die "$_SM_APPS_PATH/mail/kasbah.yml on $_SM_TARGET has primary_domain: '$_SM_PRIMARY', which is not a domain name"

    _SM_DOMAINS=()
    yaml_get "$_SM_REGISTRY" '(.domains // []) | length' count || rc=$?
    [ "$rc" -eq 0 ] || die "internal: the mail registry parsed once and not twice"
    case $count in ''|*[!0-9]*) count=0 ;; esac
    while [ "$i" -lt "$count" ]; do
        yaml_get "$_SM_REGISTRY" "(.domains // [])[$i] // \"\"" d || rc=$?
        [ "$rc" -eq 0 ] || die "internal: the mail registry parsed once and not twice"
        i=$((i + 1))
        [ -n "$d" ] || continue
        _is_fqdn "$d" \
            || die "$_SM_APPS_PATH/mail/kasbah.yml on $_SM_TARGET lists '$d' under domains:, which is not a domain name"
        _SM_DOMAINS+=("$d")
    done

    # The primary is served by the stack it is the MX for whether or not anyone
    # wrote it there, and it leads the list — the same rule `server init`
    # renders the file under.
    local found=no
    for d in ${_SM_DOMAINS[@]+"${_SM_DOMAINS[@]}"}; do
        [ "$d" != "$_SM_PRIMARY" ] || { found=yes; break; }
    done
    [ "$found" = yes ] \
        || _SM_DOMAINS=("$_SM_PRIMARY" ${_SM_DOMAINS[@]+"${_SM_DOMAINS[@]}"})
    return 0
}

# --- add-mail-domain ------------------------------------------------------------

_sm_add_usage() {
    cat <<EOF
Usage: kasbah server add-mail-domain USER@HOST <domain>

Joins <domain> to the VPS's shared mail stack (docs/mail.md → Multi-domain).
Two things change: the domain joins domains: in <apps>/mail/kasbah.yml — the
registry, and the only thing asked whether this stack serves a domain — and
postmaster@<domain> is aliased to the primary mailbox in docker-mailserver's
postfix-virtual.cf, which is also what makes Postfix accept mail for it.

Adding a domain twice is a no-op that says so.

No router is added: mail.<primary> and webmail.<primary> are the stack's
hostnames and an app domain needs no MX of its own — it needs an MX record
pointing at mail.<primary>. Run \`kasbah server mail-setup-guide USER@HOST\`
for the records this domain needs, and generate its DKIM keys on the VPS.
EOF
}

_sm_add_parse_args() {
    _SM_TARGET=""
    _SM_DOMAIN=""

    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) _sm_add_usage; exit 0 ;;
            -*)        die "server add-mail-domain: unknown flag '${1%%=*}' (this command takes USER@HOST and a domain)" ;;
            *)
                if [ -z "$_SM_TARGET" ]; then
                    _SM_TARGET="${1%$'\r'}"
                elif [ -z "$_SM_DOMAIN" ]; then
                    _SM_DOMAIN="${1%$'\r'}"
                else
                    die "server add-mail-domain: unexpected argument '$1' (USER@HOST and one domain)"
                fi
                ;;
        esac
        shift
    done

    [ -n "$_SM_TARGET" ] \
        || die "server add-mail-domain: USER@HOST is required (the user kasbah deploys as is not optional)"
    [ -n "$_SM_DOMAIN" ] \
        || die "server add-mail-domain: a domain is required (kasbah server add-mail-domain $_SM_TARGET example.com)"
    # The same check every entry already in the registry is held to, and the
    # reason there is one check rather than two: _is_fqdn's alphabet is letters,
    # digits, hyphen and dot, so a value it accepts cannot carry a newline, a
    # quote or a colon into the YAML this command renders.
    _is_fqdn "$_SM_DOMAIN" \
        || die "server add-mail-domain: '$_SM_DOMAIN' is not a domain name (it goes under domains: in the mail registry, and every entry there is one)"
    return 0
}

# The registry, re-rendered from its own template with the new list. Rendering
# rather than appending is what keeps one writer for the file's shape: a run of
# `server init` renders it the same way from the same template, so the two
# cannot produce different files for the same list.
_sm_render_registry() {
    local out="$1" d domains="" tpl="${KASBAH_TEMPLATE_DIR:-}" yq_err

    [ -n "$tpl" ] || die "internal: KASBAH_TEMPLATE_DIR is not set"
    command -v yq >/dev/null \
        || die "yq is required to render the mail registry (install yq and retry)"

    for d in "${_SM_DOMAINS[@]}"; do
        domains+="${domains:+$'\n'}  - $d"
    done

    _SI_SUBST=(
        [MAIL_PRIMARY_DOMAIN]="$_SM_PRIMARY"
        [MAIL_DOMAINS]="$domains"
    )
    _si_render_template "$tpl/mail/kasbah.yml" "$out" "mail kasbah.yml"

    if ! yq_err="$(yq -e . "$out" 2>&1 >/dev/null)"; then
        err "the rendered mail registry is not valid YAML — refusing to ship it"
        err_cont "${yq_err:-yq rejected the file and said nothing}"
        err_cont "rendered with primary $_SM_PRIMARY, domains ${_SM_DOMAINS[*]}"
        exit 1
    fi
    return 0
}

# The write. Two files, and only one of them is kasbah's: the registry is
# replaced whole through a temp file and a rename, so a run that dies mid-write
# cannot leave half a registry; postfix-virtual.cf belongs to docker-mailserver
# and is only ever *appended* to, and only when the alias is not already in it.
#
# DMS watches that file and reloads on a change, so no restart is needed. When
# it cannot be written — DMS rewrites it as root once `setup alias` has been
# used — the caller says which command to run instead rather than this step
# elevating.
_sm_write() {
    local registry="$1" alias_line="$2" out rc=0

    out=$(ssh_script "$_SM_APPS_PATH" "$_SM_DATA_PATH" "$registry" "$alias_line" <<'REMOTE'
set -uo pipefail
export LC_ALL=C
dir="$1/mail"
cfg="$2/mail/dms/config"
aliases="$cfg/postfix-virtual.cf"
registry=$3
alias_line=$4

fail() { printf 'remote: %s\n' "$*" >&2; exit 1; }

tmp="$dir/.kasbah.yml.$$"
printf '%s' "$registry" > "$tmp" || fail "could not write $tmp"
chmod 644 "$tmp" 2>/dev/null || true
mv -f "$tmp" "$dir/kasbah.yml" || { rm -f "$tmp"; fail "could not replace $dir/kasbah.yml"; }
printf 'registry=written\n'

# Appended with a leading newline only when the file does not already end in
# one: a last line with no terminator would otherwise swallow the alias.
state=skipped
if [ -n "$alias_line" ]; then
    state=failed
    if [ ! -d "$cfg" ]; then
        state=noconfig
    elif [ -e "$aliases" ] && [ ! -f "$aliases" ]; then
        state=notfile
    else
        {
            if [ -s "$aliases" ]; then
                last=$(tail -c 1 "$aliases" 2>/dev/null; printf x)
                [ "$last" = $'\nx' ] || printf '\n'
            fi
            printf '%s\n' "$alias_line"
        } >> "$aliases" 2>/dev/null && state=added
    fi
fi
printf 'alias=%s\n' "$state"
exit 0
REMOTE
    ) || rc=$?

    [ "$rc" -eq 0 ] \
        || die "could not write the mail registry on $_SM_TARGET (the remote step exited $rc, see above) — nothing else was changed"
    _sm_absorb "$out" registry alias
    # Read, not merely required to be present: the remote writes through a temp
    # file and a rename and prints this last, so any other value is a step that
    # reported something this kasbah does not know how to believe.
    [ "${_SM_FACT[registry]}" = written ] \
        || die "the registry write on $_SM_TARGET reported registry='${_SM_FACT[registry]}', which this kasbah does not know — $_SM_APPS_PATH/mail/kasbah.yml may be half-written"
    return 0
}

# What the operator still has to do, and cannot be done from here: DKIM keys are
# generated by DMS's own helper on the VPS (docs/mail.md → what kasbah does NOT
# do), the signing override names them per domain, and DNS is nobody's to
# publish but the domain owner's.
_sm_add_followup() {
    local d="$1"

    printf '\nStill to do for %s — none of it is kasbah'\''s to do:\n\n' "$d"
    printf '1. Generate its DKIM keys, on the VPS:\n'
    printf '     ssh %s '\''docker exec mail-dms setup config dkim keytype rsa     selector mail domain %s'\''\n' "$_SM_TARGET" "$d"
    printf '     ssh %s '\''docker exec mail-dms setup config dkim keytype ed25519 selector ed   domain %s'\''\n' "$_SM_TARGET" "$d"
    printf '\n2. Add a block for it to the Rspamd signing override, which kasbah wrote\n'
    printf '   once for %s and never rewrites:\n' "$_SM_PRIMARY"
    printf '     %s/mail/dms/config/rspamd/override.d/dkim_signing.conf\n\n' "$_SM_DATA_PATH"
    printf '     domain {\n'
    printf '         %s {\n' "$d"
    printf '             selectors [\n'
    printf '                 { path = "/tmp/docker-mailserver/rspamd/dkim/rsa-2048-mail-%s.private.txt"; selector = "mail"; },\n' "$d"
    printf '                 { path = "/tmp/docker-mailserver/rspamd/dkim/ed25519-ed-%s.private.txt"; selector = "ed"; }\n' "$d"
    printf '             ]\n'
    printf '         }\n'
    printf '     }\n\n'
    printf '3. Publish its DNS records — MX, SPF, DMARC and the two DKIM keys:\n'
    printf '     kasbah server mail-setup-guide %s\n' "$_SM_TARGET"
    return 0
}

cmd_server_add_mail_domain() {
    local d line alias_line="" registry="" known=no aliased=no

    _sm_add_parse_args "$@"

    # Made before the connection, and so is its trap: lib/ssh.sh chains its
    # master teardown onto whatever EXIT trap it finds when ssh_connect runs, so
    # a trap installed afterwards would replace that chain and strand the
    # master. Same order `server init` uses, for the same reason.
    _SM_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/kasbah-mail.XXXXXX")" \
        || die "could not create a temp directory"
    trap '_sm_cleanup' EXIT

    ssh_connect "$_SM_TARGET"
    marker_read "$_SM_TARGET"
    _SM_APPS_PATH="$MARKER_APPS_PATH"
    _SM_DATA_PATH="$MARKER_DATA_PATH"

    _sm_read
    _sm_read_registry

    for d in "${_SM_DOMAINS[@]}"; do
        [ "$d" != "$_SM_DOMAIN" ] || { known=yes; break; }
    done

    # postmaster@<domain> routed to the primary mailbox: the alias
    # docs/mail.md's multi-domain list calls for, and the thing that makes
    # Postfix accept mail for the domain at all — DMS builds its list of
    # accepted domains out of postfix-accounts.cf and postfix-virtual.cf.
    alias_line="postmaster@$_SM_DOMAIN postmaster@$_SM_PRIMARY"
    # An empty payload is a file that is empty, not there, or one this user
    # cannot read, and all three mean the same thing here: no alias was seen, so
    # one is written. That is the safe direction — the write step is what
    # discovers a file it cannot append to, and says so.
    while IFS= read -r line; do
        line="${line%$'\r'}"
        [ "$line" != "$alias_line" ] || { aliased=yes; break; }
    done <<<"$_SM_ALIASES"

    if [ "$known" = yes ] && [ "$aliased" = yes ]; then
        info "$_SM_DOMAIN is already served by the mail stack on $_SM_TARGET — nothing to do"
        info "  registry: $_SM_APPS_PATH/mail/kasbah.yml lists it under domains:"
        info "  alias:    $alias_line"
        return 0
    fi

    [ "$known" = yes ] || _SM_DOMAINS+=("$_SM_DOMAIN")
    [ "$aliased" = no ] || alias_line=""

    _sm_render_registry "$_SM_TMPDIR/kasbah.yml"
    registry="$(cat "$_SM_TMPDIR/kasbah.yml"; printf x)" || die "could not read the rendered registry"
    registry="${registry%x}"

    _sm_write "$registry" "$alias_line"

    info "Added $_SM_DOMAIN to the mail stack on $_SM_TARGET"
    info "  registry: $_SM_APPS_PATH/mail/kasbah.yml — domains: ${_SM_DOMAINS[*]}"
    case "${_SM_FACT[alias]}" in
        added)   info "  alias:    $alias_line (docker-mailserver reloads on its own)" ;;
        skipped) info "  alias:    postmaster@$_SM_DOMAIN was already aliased" ;;
        noconfig)
            warn "docker-mailserver's config directory is not at $_SM_DATA_PATH/mail/dms/config yet, so"
            warn "postmaster@$_SM_DOMAIN has no alias. The stack has to have run once. Then:"
            warn "  ssh $_SM_TARGET 'docker exec mail-dms setup alias add postmaster@$_SM_DOMAIN postmaster@$_SM_PRIMARY'"
            ;;
        *)
            warn "could not append to $_SM_DATA_PATH/mail/dms/config/postfix-virtual.cf, so"
            warn "postmaster@$_SM_DOMAIN has no alias and Postfix will not accept mail for it."
            warn "docker-mailserver rewrites that file as root once its own helper has been used;"
            warn "let it do this one too:"
            warn "  ssh $_SM_TARGET 'docker exec mail-dms setup alias add postmaster@$_SM_DOMAIN postmaster@$_SM_PRIMARY'"
            ;;
    esac
    _sm_add_followup "$_SM_DOMAIN"
    return 0
}

# --- mail-setup-guide -----------------------------------------------------------

_sm_guide_usage() {
    cat <<EOF
Usage: kasbah server mail-setup-guide USER@HOST

Prints the mail stack's post-install walkthrough, rendered for this server:
its primary domain, every domain in <apps>/mail/kasbah.yml, and the DNS
records each of them needs. Ported from the original project's mail/SETUP.md.

Read-only. It reads the registry and changes nothing on the server.
EOF
}

_sm_guide_parse_args() {
    _SM_TARGET=""

    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) _sm_guide_usage; exit 0 ;;
            -*)        die "server mail-setup-guide: unknown flag '${1%%=*}' (this command takes USER@HOST)" ;;
            *)
                [ -z "$_SM_TARGET" ] \
                    || die "server mail-setup-guide: unexpected argument '$1' (USER@HOST is given once)"
                _SM_TARGET="${1%$'\r'}"
                ;;
        esac
        shift
    done

    [ -n "$_SM_TARGET" ] \
        || die "server mail-setup-guide: USER@HOST is required (the guide is rendered for one server's registry)"
    return 0
}

# The zone records, rendered for the registry rather than shown as an example.
# The primary carries the stack's own names — the two A records, the hostname's
# SPF, TLS reporting and service discovery — and every domain, primary included,
# carries the four that make mail for it deliverable.
#
# Apex A records are deliberately absent: those belong to whatever serves the
# site, and this guide is not the place a mail command tells an operator where
# to point their website.
_sm_guide_dns() {
    local ip="${_SM_HOST_ADDR:-<VPS IP>}" d

    printf '; ---------- %s: the stack'\''s own names ----------\n' "$_SM_PRIMARY"
    printf 'mail.%s.               IN A     %s\n' "$_SM_PRIMARY" "$ip"
    printf 'webmail.%s.            IN A     %s\n' "$_SM_PRIMARY" "$ip"
    printf 'mail.%s.               IN TXT   "v=spf1 a -all"\n' "$_SM_PRIMARY"
    printf '_smtp._tls.%s.         IN TXT   "v=TLSRPTv1; rua=mailto:postmaster@%s"\n' "$_SM_PRIMARY" "$_SM_PRIMARY"
    printf '_imaps._tcp.%s.        IN SRV   0 1 993 mail.%s.\n' "$_SM_PRIMARY" "$_SM_PRIMARY"
    printf '_submissions._tcp.%s.  IN SRV   0 1 465 mail.%s.\n' "$_SM_PRIMARY" "$_SM_PRIMARY"
    printf '_submission._tcp.%s.   IN SRV   0 1 587 mail.%s.\n' "$_SM_PRIMARY" "$_SM_PRIMARY"

    for d in "${_SM_DOMAINS[@]}"; do
        printf '\n; ---------- %s ----------\n' "$d"
        printf '%s.                    IN MX    10 mail.%s.\n' "$d" "$_SM_PRIMARY"
        printf '%s.                    IN TXT   "v=spf1 mx ip4:%s ~all"\n' "$d" "$ip"
        printf '_dmarc.%s.             IN TXT   "v=DMARC1; p=none; rua=mailto:postmaster@%s; fo=1"\n' "$d" "$_SM_PRIMARY"
        printf 'mail._domainkey.%s.    IN TXT   "<rsa-2048-mail-%s.public.dns.txt>"\n' "$d" "$d"
        printf 'ed._domainkey.%s.      IN TXT   "<ed25519-ed-%s.public.dns.txt>"\n' "$d" "$d"
    done
    return 0
}

# Printed on stdout, all of it: this is the command's output, not its
# diagnostics, and `kasbah server mail-setup-guide you@vps > mail-setup.txt` has
# to capture the whole thing.
_sm_guide_print() {
    local d ip="${_SM_HOST_ADDR:-<VPS IP>}" addr_note=""

    [ -z "$_SM_HOST_ADDR" ] \
        || addr_note=" (the address this ssh session reached — substitute the public one if the server is behind NAT)"

    cat <<EOF
Mail setup — $_SM_TARGET
========================

Primary domain: $_SM_PRIMARY
Domains served: ${_SM_DOMAINS[*]}
VPS address:    $ip$addr_note
Stack:          $_SM_APPS_PATH/mail   data: $_SM_DATA_PATH/mail

Everything below runs on the VPS. docker-mailserver has no admin web UI; its
CLI is \`docker exec mail-dms setup …\`, and \`setup help\` lists all of it.

0. Prerequisites — kasbah cannot check either of these, and both are fatal
---------------------------------------------------------------------------
[ ] Reverse DNS (PTR) on the VPS IP is set to mail.$_SM_PRIMARY. It is set in
    the VPS provider's control panel, not in your zone, and receivers reject
    or spam-file mail from a host whose PTR does not match its HELO name.
[ ] Port 25 **outbound** is not blocked by the provider. Many block it by
    default (OVH, Hetzner, AWS, GCP) and will unblock on request. If they will
    not, use an outbound relay — step 6.
[ ] mail.$_SM_PRIMARY and webmail.$_SM_PRIMARY resolve to the VPS from the
    public internet. Traefik asks Let's Encrypt for both the moment it loads
    the fragment, and DMS will not boot without the first one's certificate.

1. Check the stack
---------------------------------------------------------------------------
    ssh $_SM_TARGET 'docker inspect -f "{{.State.Health.Status}}" mail-dms'
    ssh $_SM_TARGET 'docker logs --tail 40 mail-dms'

On a first run DMS may crashloop for 30-90 s with

    Unable to find key and/or cert for '$_SM_PRIMARY' in '/etc/letsencrypt/acme.json'

while Traefik finishes the HTTP-01 exchange. That is expected. If it never
settles, mail.$_SM_PRIMARY does not resolve to this host from the outside.

    https://webmail.$_SM_PRIMARY — webmail, and it should answer 200
    https://mail.$_SM_PRIMARY — answers 418 by design. Nothing is served there;
    the name exists so that Traefik asks for its certificate.

2. Generate DKIM keys — dual signing, Ed25519 primary with RSA fallback
---------------------------------------------------------------------------
Per domain. kasbah does not generate keys and never will: they are the one
thing here that cannot be regenerated without breaking every receiver holding
the old one.

EOF
    for d in "${_SM_DOMAINS[@]}"; do
        printf "    ssh %s 'docker exec mail-dms setup config dkim keytype rsa     selector mail domain %s'\n" "$_SM_TARGET" "$d"
        printf "    ssh %s 'docker exec mail-dms setup config dkim keytype ed25519 selector ed   domain %s'\n" "$_SM_TARGET" "$d"
    done
    cat <<EOF

The keys land in $_SM_DATA_PATH/mail/dms/config/rspamd/dkim/. The flat,
one-line public forms are the ones to paste into DNS:

    ssh $_SM_TARGET 'cat $_SM_DATA_PATH/mail/dms/config/rspamd/dkim/*.public.dns.txt'

kasbah seeded the signing override for $_SM_PRIMARY before DMS first started —
which is what stops DMS's helper writing its own single-selector default over
it — and never rewrites it. **A domain added later needs its own block added by
hand** to

    $_SM_DATA_PATH/mail/dms/config/rspamd/override.d/dkim_signing.conf

Rspamd reloads on its own; no restart.

3. Publish DNS, for this server's registry
---------------------------------------------------------------------------
EOF
    printf '\n'
    _sm_guide_dns
    cat <<EOF

The two DKIM lines are placeholders — paste the matching .public.dns.txt
contents from step 2. Apex A records are not listed: those belong to whatever
serves each site.

Start DMARC at p=none, read the rua reports for a few days, then tighten to
p=quarantine and only later to p=reject. Tighten SPF's ~all to -all once every
sender is listed.

    dig +short MX $_SM_PRIMARY
    dig +short TXT mail._domainkey.$_SM_PRIMARY
    dig +short TXT _dmarc.$_SM_PRIMARY

4. Mailboxes
---------------------------------------------------------------------------
postmaster@$_SM_PRIMARY already exists — \`server init --with-mail\` seeded it,
because Dovecot panics within 120 s if the account file is empty. Every other
address is created out of band, deliberately: deploys do not touch user data
(docs/mail.md → Account management).

    ssh -t $_SM_TARGET 'docker exec -it mail-dms setup email add noreply@$_SM_PRIMARY'
    ssh -t $_SM_TARGET 'docker exec -it mail-dms setup email update postmaster@$_SM_PRIMARY'
    ssh    $_SM_TARGET 'docker exec mail-dms setup email list'
    ssh    $_SM_TARGET 'docker exec mail-dms setup alias add hello@$_SM_PRIMARY noreply@$_SM_PRIMARY'

Each additional domain already has postmaster@<domain> aliased to
postmaster@$_SM_PRIMARY — that is what \`kasbah server add-mail-domain\` writes,
and what makes Postfix accept mail for the domain at all.

5. Webmail
---------------------------------------------------------------------------
    ssh $_SM_TARGET 'docker exec mail-snappymail cat /var/lib/snappymail/_data_/_default_/admin_password.txt'

Then https://webmail.$_SM_PRIMARY/?admin as \`admin\`, and change that password
immediately. Users log in at https://webmail.$_SM_PRIMARY with their full
address.

A domain's IMAP/SMTP config can be pre-seeded from a project's manifest:

    mail:
      domain: <domain>
      snappymail_domain: ./mail/snappymail-domain.json

\`kasbah deploy\` copies that file in **if it is not already there**, and never
over one SnappyMail has since edited. Its host must be mail.$_SM_PRIMARY — the
certificate is issued for that name and SnappyMail verifies it.

6. Outbound relay, if the IP is blocked or has poor reputation
---------------------------------------------------------------------------
Fill these three in $_SM_APPS_PATH/mail/.env — they are the operator's half of
that file, and kasbah copies them through untouched on every re-run:

    DEFAULT_RELAY_HOST=[smtp-relay.brevo.com]:587
    RELAY_USER=<smtp-login>
    RELAY_PASSWORD=<smtp-key>

    ssh $_SM_TARGET 'cd $_SM_APPS_PATH/mail && docker compose -p mail up -d'

7. Prove it end to end
---------------------------------------------------------------------------
[ ] Send from an outside account to postmaster@$_SM_PRIMARY, read it in webmail.
[ ] Reply, and confirm it arrives and is not in spam.
[ ] https://www.mail-tester.com/ — aim for 10/10, from each domain that sends.
[ ] https://mxtoolbox.com/SuperTool.aspx on each domain: MX, SPF, DKIM, DMARC.
[ ] ssh $_SM_TARGET 'docker logs mail-dms 2>&1 | grep -i rspamd | tail -20'

8. Back up the DKIM keys
---------------------------------------------------------------------------
$_SM_DATA_PATH/mail/dms/config/rspamd/dkim/ is the one directory here that
cannot be rebuilt. A regenerated key is a different key, and every receiver
holding the old one fails verification until its cache expires.

    ssh $_SM_TARGET 'tar czf - -C $_SM_DATA_PATH/mail dms/config' > dms-config-\$(date +%F).tar.gz

Mailboxes live in $_SM_DATA_PATH/mail/dms/mail-data/, webmail settings in
$_SM_DATA_PATH/mail/snappymail/.
EOF
    return 0
}

cmd_server_mail_setup_guide() {
    _sm_guide_parse_args "$@"

    ssh_connect "$_SM_TARGET"
    marker_read "$_SM_TARGET"
    _SM_APPS_PATH="$MARKER_APPS_PATH"
    _SM_DATA_PATH="$MARKER_DATA_PATH"

    _sm_read
    _sm_read_registry
    _sm_guide_print
    return 0
}
