# kasbah — Traefik's ACME store, read on the workstation
# Sourced by lib/check_server.sh. Do not execute directly.

[ -n "${_KASBAH_ACME_LOADED:-}" ] && return 0
_KASBAH_ACME_LOADED=1

. "$KASBAH_LIB_DIR/common.sh"

# `<data>/traefik/letsencrypt/acme.json` is Traefik's certificate store: one
# JSON object keyed by resolver name, each holding an `Account` and a
# `Certificates` array. `server init` touches the file before Traefik ever
# mounts it and Traefik writes it in place without changing the owner, so the
# deploy user reads it without sudo (measured on the real host, Phase 7).
#
# **The file is secret.** `.<resolver>.Account.PrivateKey` and every
# certificate's `.key` are private key material, and reading it here means the
# whole file crosses the wire and lands in a shell variable. Nothing in this
# file writes it to disk, echoes it, or puts it in an error message — a
# diagnostic about a store that would not parse says what shape it had, never
# what was in it. Callers that fold remote output into a fact table need their
# own redaction for the same reason: `_ss_absorb_checked`'s clip-and-print
# diagnostic would spill key bytes onto stderr.
#
# **`notBefore` is not issuance time.** Let's Encrypt backdates it by ~58.5
# minutes — measured three times now, twice in Phase 6 and once in Phase 7 — so
# a rule reading it as "when this was issued" calls a fresh certificate an hour
# old. Nothing here reads it: expiry (`notAfter`) and the days left are the two
# facts a certificate can actually answer for.
#
# **The schema shifts between Traefik versions**, so every read below is
# defensive and each way of failing is a different answer: a file that is not
# JSON, a resolver key that is not there, a `Certificates` that is not an array,
# an empty store and a store with no entry for the domain are five states an
# operator acts on differently, and collapsing them into "no certificate" throws
# away the only thing that says what to do next.

# The resolver kasbah's Traefik is configured with — a frozen contract
# (docs/traefik.md), which is why it is a constant rather than a discovered
# value: a store keyed by anything else is a Traefik nobody here configured.
ACME_RESOLVER=letsencrypt

# What acme_lookup found, and about which certificate.
#
#   ACME_STATE   notjson    the content is not a JSON object
#                noresolver no `<resolver>` key — a schema shift, or a Traefik
#                           configured with another resolver name
#                notarray   `<resolver>.Certificates` is not an array
#                empty      the store holds no certificates
#                nomatch    certificates, none of them for this domain
#                nocert     the entry has no `certificate` field
#                notbase64  its `certificate` is not base64
#                nopem      the decoded bytes are not a certificate openssl reads
#                found      everything below is filled in
ACME_STATE=""
ACME_KIND=""        # the type that was there, when ACME_STATE=notarray
ACME_COUNT=0        # certificates in the store, whatever the verdict
# The matched entry's `domain.main`, so a SAN match can say which certificate it
# found. Its `Store` and the rest of its SAN list are deliberately not exported:
# nothing outside this file reads them, and a fact with test coverage and no
# reader reads as though a live mechanism were covered (Phase 7, 7.1b). A later
# command that wants them adds back what it actually uses.
ACME_MAIN=""
ACME_ISSUER=""
ACME_NOTAFTER=""
ACME_DAYS=""        # whole days until notAfter; negative when expired

# _acme_jq CONTENT OUTVAR FILTER [jq-arg...] — one keyed lookup against the
# store held in a variable. Exit 2 means the document did not parse, which the
# caller keeps distinct from "the key is not there". The content goes down a
# pipe rather than into a file or an argv entry: it is key material.
_acme_jq() {
    local _aj_content="$1" _aj_out="$2" _aj_filter="$3" _aj_val=""
    shift 3

    printf -v "$_aj_out" '%s' ""
    [ -n "$_aj_content" ] || return 2
    _aj_val=$(printf '%s' "$_aj_content" | jq -r "$@" "$_aj_filter" 2>/dev/null) || return 2
    case $_aj_val in null) _aj_val="" ;; esac
    printf -v "$_aj_out" '%s' "${_aj_val%$'\r'}"
    return 0
}

# The issuer and the expiry of one PEM chain, from the base64 Traefik stores it
# as. 1 = not base64, 2 = not something openssl reads as a certificate.
#
# The leaf is first in the chain, which is what `openssl x509` reads, and the
# chain itself is public — unlike the `.key` beside it, which nothing here
# touches.
_acme_cert_facts() {
    local _cf_b64="$1" _cf_pem="" _cf_out="" _cf_line _cf_exp _cf_now

    _cf_pem=$(printf '%s' "$_cf_b64" | base64 -d 2>/dev/null) || return 1
    [ -n "$_cf_pem" ] || return 1
    _cf_out=$(printf '%s\n' "$_cf_pem" | openssl x509 -noout -issuer -enddate 2>/dev/null) \
        || return 2

    while IFS= read -r _cf_line; do
        _cf_line="${_cf_line%$'\r'}"
        case $_cf_line in
            issuer=*)   ACME_ISSUER="${_cf_line#issuer=}" ;;
            notAfter=*) ACME_NOTAFTER="${_cf_line#notAfter=}" ;;
        esac
    done <<<"$_cf_out"
    [ -n "$ACME_NOTAFTER" ] || return 2

    # A date openssl printed and date(1) will not parse leaves ACME_DAYS empty
    # rather than reporting a made-up number of days.
    _cf_exp=$(date -d "$ACME_NOTAFTER" +%s 2>/dev/null) || return 0
    _cf_now=$(date +%s)
    ACME_DAYS=$(( (_cf_exp - _cf_now) / 86400 ))
    return 0
}

# True when entry <index>'s `domain.sans` carries <domain>, read one index at a
# time — never as one `join`ed string split back on spaces.
#
# This is the rule the certificate list itself is walked under (below), and the
# registry readers in lib/server_mail.sh and lib/deploy.sh are written under, and
# it is not stylistic. A SAN holding a space — in a store some other Traefik
# wrote, in one that has been tampered with — turns a joined string into two
# tokens, and `certificate valid for N days` would then be reported for a
# hostname the certificate does not cover. One read per entry cannot do that.
_acme_sans_match() {
    local _sm_content="$1" _sm_resolver="$2" _sm_i="$3" _sm_domain="$4"
    local _sm_n="" _sm_j=0 _sm_san=""

    _acme_jq "$_sm_content" _sm_n \
        ".[\$r].Certificates[$_sm_i].domain.sans // [] | length" \
        --arg r "$_sm_resolver" || _sm_n=0
    case $_sm_n in ''|*[!0-9]*) _sm_n=0 ;; esac

    while [ "$_sm_j" -lt "$_sm_n" ]; do
        _acme_jq "$_sm_content" _sm_san \
            ".[\$r].Certificates[$_sm_i].domain.sans[$_sm_j] // \"\" | tostring" \
            --arg r "$_sm_resolver" || _sm_san=""
        [ "$_sm_san" != "$_sm_domain" ] || return 0
        _sm_j=$((_sm_j + 1))
    done
    return 1
}

# acme_lookup CONTENT DOMAIN [RESOLVER] — the store's answer about one hostname.
# Always returns 0; ACME_STATE is the answer.
#
# The certificates are walked one index at a time rather than filtered in a
# single jq expression, for the reason the mail registry is read that way: one
# entry whose shape is not what this version of Traefik wrote must change the
# answer for that entry alone, not take the whole read down with it.
acme_lookup() {
    local content="$1" domain="$2" resolver="${3:-$ACME_RESOLVER}"
    local v="" rc=0 i=0 main="" found=-1

    ACME_STATE=""
    ACME_KIND=""
    ACME_COUNT=0
    ACME_MAIN=""
    ACME_ISSUER=""
    ACME_NOTAFTER=""
    ACME_DAYS=""

    command -v jq >/dev/null || die "jq is required to read acme.json (install jq and retry)"

    _acme_jq "$content" v 'type' || rc=$?
    if [ "$rc" -ne 0 ] || [ "$v" != object ]; then
        ACME_STATE=notjson
        return 0
    fi

    _acme_jq "$content" v 'has($r)' --arg r "$resolver" || rc=$?
    if [ "$rc" -ne 0 ] || [ "$v" != true ]; then
        ACME_STATE=noresolver
        return 0
    fi

    _acme_jq "$content" v '.[$r].Certificates | type' --arg r "$resolver" || rc=$?
    if [ "$rc" -ne 0 ]; then
        ACME_STATE=notjson
        return 0
    fi
    case $v in
        array)  ;;
        ""|null) ACME_STATE=empty; return 0 ;;
        *)      ACME_STATE=notarray; ACME_KIND="$v"; return 0 ;;
    esac

    _acme_jq "$content" v '.[$r].Certificates | length' --arg r "$resolver" || v=0
    case $v in ''|*[!0-9]*) v=0 ;; esac
    ACME_COUNT="$v"
    if [ "$ACME_COUNT" -eq 0 ]; then
        ACME_STATE=empty
        return 0
    fi

    while [ "$i" -lt "$ACME_COUNT" ]; do
        _acme_jq "$content" main ".[\$r].Certificates[$i].domain.main // \"\"" \
            --arg r "$resolver" || main=""
        if [ "$main" = "$domain" ]; then
            found="$i"
        elif _acme_sans_match "$content" "$resolver" "$i" "$domain"; then
            found="$i"
        fi
        if [ "$found" -ge 0 ]; then
            ACME_MAIN="$main"
            break
        fi
        i=$((i + 1))
    done

    if [ "$found" -lt 0 ]; then
        ACME_STATE=nomatch
        return 0
    fi

    _acme_jq "$content" v ".[\$r].Certificates[$found].certificate // \"\"" \
        --arg r "$resolver" || v=""
    if [ -z "$v" ]; then
        ACME_STATE=nocert
        return 0
    fi

    rc=0
    _acme_cert_facts "$v" || rc=$?
    case $rc in
        0) ACME_STATE=found ;;
        1) ACME_STATE=notbase64 ;;
        *) ACME_STATE=nopem ;;
    esac
    return 0
}
