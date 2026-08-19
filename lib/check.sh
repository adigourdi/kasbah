# kasbah — check command (compliance linter)
# Sourced by bin/kasbah. Do not execute directly.

[ -n "${_KASBAH_CHECK_LOADED:-}" ] && return 0
_KASBAH_CHECK_LOADED=1

. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/manifest.sh"
# The env rules read keys and diff them with the same code the VPS runs.
. "$KASBAH_LIB_DIR/env.sh"

_check_usage() {
    cat <<EOF
Usage: kasbah check

Runs structural checks against the current project. Exit 0 if no failures
(warnings are informational). See docs/compliance.md for the full rule set.

Implemented: Structure (S01–S06), Compose (C01–C05, C07, C08), Resources (R01–R03),
Traefik (T01–T07), Healthchecks (H01–H02), Env (E01–E05), Hooks (HK01–HK03).
Mail (M*), R04, and the --fix / --server modes are not yet wired in.
EOF
}

# Counters and per-line buffer; cmd_check resets them each run.
_CHECK_PASS=0
_CHECK_WARN=0
_CHECK_FAIL=0

_check_pass() { _CHECK_PASS=$((_CHECK_PASS + 1)); printf '  ✓ %s\n' "$1"; }
_check_warn() { _CHECK_WARN=$((_CHECK_WARN + 1)); printf '  ⚠ %s\n' "$1"; }
_check_fail() { _CHECK_FAIL=$((_CHECK_FAIL + 1)); printf '  ✗ %s\n' "$1"; }

# .gitignore-excludes-PATTERN: true iff a line matches PATTERN exactly. We
# don't try to interpret negations or globs here — `init-project` writes
# literal lines, and the rule is "is this line present", not "would git
# actually ignore the path" (which would need `git check-ignore`). The `tr`
# strips trailing CR so a CRLF-authored .gitignore (Windows editors) doesn't
# false-warn — same parity as manifest.sh's CR stripping.
_gitignore_has() {
    [ -f .gitignore ] && tr -d '\r' < .gitignore | grep -qxF "$1"
}

cmd_check() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) _check_usage; return 0 ;;
            *)         die "check: unknown argument '$1'" ;;
        esac
    done

    _CHECK_PASS=0
    _CHECK_WARN=0
    _CHECK_FAIL=0

    # Report goes to stdout (the ✓/⚠/✗ lines do, too) so `kasbah check >
    # report.txt` captures the whole thing. Diagnostics from helpers (info/
    # warn/err) keep going to stderr.
    printf 'Checking %s\n\n' "$PWD"

    echo "Structure:"

    # S01 + S02: manifest_require enforces kasbah.yml exists, parses, and
    # validates schema. On failure it exits non-zero (2 if missing, 1 if
    # invalid) — that matches the docs' intent: structural failure should
    # short-circuit the whole check.
    manifest_require
    _check_pass "kasbah.yml exists (schema $MANIFEST_SCHEMA)"

    # S03
    if [ -f compose.prod.yml ]; then
        _check_pass "compose.prod.yml exists"
    else
        _check_fail "compose.prod.yml missing"
    fi

    # S04
    if [ -f .env.prod.example ]; then
        _check_pass ".env.prod.example exists"
    else
        _check_fail ".env.prod.example missing"
    fi

    # S05
    if _gitignore_has '.env'; then
        _check_pass ".gitignore excludes .env"
    else
        _check_warn ".gitignore does not exclude .env"
    fi

    # S06
    if _gitignore_has '.kasbah/'; then
        _check_pass ".gitignore excludes .kasbah/"
    else
        _check_warn ".gitignore does not exclude .kasbah/"
    fi

    # Compose-derived data is reused by Traefik (T06), Healthchecks (H01,
    # H02), and Hooks (HK01, HK03). Compute it once at the top so every
    # downstream section gets the same view, and a single yq parse error in
    # compose.prod.yml short-circuits all of them cleanly.
    local services=""
    if [ -f compose.prod.yml ]; then
        services="$(yq -r '(.services // {}) | keys | .[]' compose.prod.yml 2>/dev/null || true)"
    fi

    _check_compose_section "$services"
    _check_resources_section "$services"
    _check_traefik_section "$services"
    _check_healthcheck_section "$services"
    _check_env_section
    _check_hooks_section "$services"

    echo
    printf 'Summary: %d passed, %d warning, %d failed\n' \
        "$_CHECK_PASS" "$_CHECK_WARN" "$_CHECK_FAIL"

    [ "$_CHECK_FAIL" -eq 0 ] || exit "$KASBAH_EXIT_COMPLIANCE_FAIL"
}

# Compose rules (C01–C05). Skipped quietly when compose.prod.yml is missing —
# S03 has already failed for that case and shouting twice adds noise. The
# `services` arg is the newline-separated service list precomputed by
# cmd_check; an empty value means either "file missing" or "yq parse
# failure / no services".
_check_compose_section() {
    local services="$1"
    [ -f compose.prod.yml ] || return 0

    echo
    echo "Compose:"

    # Re-run the parse here just to detect "file exists but invalid YAML" —
    # we want a clean ✗ line in the Compose section rather than just an
    # empty services list silently triggering the no-services warn.
    if ! yq -r '.' compose.prod.yml >/dev/null 2>&1; then
        _check_fail "compose.prod.yml does not parse as YAML"
        return 0
    fi

    if [ -z "$services" ]; then
        _check_warn "compose.prod.yml declares no services — skipping Compose checks"
        # C05 is independent of services — still run it.
        _check_c05_version
        return 0
    fi

    _check_c01_restart "$services"
    _check_c02_logging "$services"
    _check_c03_c04_c07_networks "$services"
    _check_c05_version
    # Silent on a project that builds nothing: the rule is about the tag deploy
    # moves, and a stock-only project has none to move.
    if _compose_any_built "$services"; then
        _check_c08_built_current "$services"
    fi
}

# C08: every service with a `build:` key names an `image:` tagged `:current`.
# The whole cutover is deploy retagging `<image>:<version>` as `<image>:current`
# on the server, and `build-push` strips whatever tag the compose file carries
# before tagging `<image>:<version>` — so a service pinned to `app:1.2.3` gets a
# `:current` nothing references, and `compose up -d` keeps running the pinned
# image. That deploy reports success and changes nothing, which is why this is a
# failure rather than a warning (docs/build-deploy.md → image tags on the VPS).
_check_c08_built_current() {
    local services="$1" svc has_build image
    local bad=()

    while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        has_build="$(yq -r ".services[\"$svc\"] | has(\"build\")" compose.prod.yml 2>/dev/null || echo false)"
        [ "$has_build" = "true" ] || continue

        image="$(yq -r ".services[\"$svc\"].image // \"\"" compose.prod.yml 2>/dev/null || echo "")"
        if [ -z "$image" ] || [ "$image" = null ]; then
            bad+=("$svc (no image:)")
            continue
        fi
        # Anchored on the whole tag, not on the substring: `app:current-rc1`
        # and an untagged `mycurrentapp` both contain the word and neither is
        # what deploy moves. A suffix match is all this needs beyond that — the
        # tag is always last, so a registry with a port
        # (reg.example:5000/app:current) is matched correctly without splitting
        # the reference, and an untagged image (`app`, which Compose reads as
        # `app:latest`) fails, which is right.
        case "$image" in
            *:current) ;;
            *) bad+=("$svc ($image)") ;;
        esac
    done <<<"$services"

    if [ "${#bad[@]}" -eq 0 ]; then
        _check_pass "All built services reference their image as :current"
    else
        _check_fail "Built services whose image: is not tagged :current: ${bad[*]} — deploy moves <image>:current, so a pinned tag keeps the old image running"
    fi
}

# C01: every service sets restart: unless-stopped (or stronger).
# Compose's default is "no", which we treat as missing. on-failure[:N] is
# accepted because some services (e.g. one-shot init helpers) legitimately
# don't want unconditional restarts.
_check_c01_restart() {
    local services="$1" svc r
    local valid='^(unless-stopped|always|on-failure(:[0-9]+)?)$'
    local bad=()
    while IFS= read -r svc; do
        r="$(yq -r ".services[\"$svc\"].restart // \"\"" compose.prod.yml 2>/dev/null || echo "")"
        [[ "$r" =~ $valid ]] || bad+=("$svc")
    done <<<"$services"

    if [ "${#bad[@]}" -eq 0 ]; then
        _check_pass "All services set restart policy"
    else
        _check_fail "Services missing restart policy: ${bad[*]}"
    fi
}

# C02: every service sets logging.driver=json-file with both max-size and
# max-file. Without rotation a runaway container can fill the VPS disk.
_check_c02_logging() {
    local services="$1" svc drv ms mf
    local bad=()
    while IFS= read -r svc; do
        drv="$(yq -r ".services[\"$svc\"].logging.driver // \"\""              compose.prod.yml 2>/dev/null || echo "")"
        ms="$(yq  -r ".services[\"$svc\"].logging.options[\"max-size\"] // \"\"" compose.prod.yml 2>/dev/null || echo "")"
        mf="$(yq  -r ".services[\"$svc\"].logging.options[\"max-file\"] // \"\"" compose.prod.yml 2>/dev/null || echo "")"
        if [ "$drv" != "json-file" ] || [ -z "$ms" ] || [ -z "$mf" ]; then
            bad+=("$svc")
        fi
    done <<<"$services"

    if [ "${#bad[@]}" -eq 0 ]; then
        _check_pass "All services set json-file logging with rotation"
    else
        _check_fail "Services missing json-file logging with max-size/max-file: ${bad[*]}"
    fi
}

# C03 + C04 + C07: only Traefik-routed services join kasbah-net. A service
# is "routed" iff its explicit container_name appears as a hostname in the
# fragment's loadBalancer server URLs. Routed services must join kasbah-net
# (C03), kasbah-net must be external (C04), and nothing else may join it
# (C07) — compose registers service names as DNS aliases on every attached
# network, so generic names (postgres) on the shared network round-robin
# across projects. The old `networks: { default: { name: kasbah-net } }`
# shape is banned outright: it puts every service on the shared network.
_check_c03_c04_c07_networks() {
    local services="$1" svc
    local default_name default_ext hn_ext
    default_name="$(yq -r '.networks.default.name // ""'                compose.prod.yml)"
    default_ext="$(yq  -r '.networks.default.external // false'         compose.prod.yml)"
    hn_ext="$(yq       -r '.networks["kasbah-net"].external // false'  compose.prod.yml)"

    local default_aliases_hn=0
    [ "$default_name" = "kasbah-net" ] && default_aliases_hn=1

    local routed_hosts
    routed_hosts="$(_traefik_routed_hosts | sort -u)"

    local bad_c03=() bad_c07=()
    local any_uses_hn=0 any_routed=0
    while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        local has_hn joined=0 routed=0 cn
        # `.networks` may be a list (["a", "b"]) or a dict ({a: {…}, b: {…}}).
        # Normalize to a list of names, then check membership.
        has_hn="$(yq -r "
            .services[\"$svc\"].networks
            | if . == null then []
              elif type == \"object\" then keys
              else .
              end
            | any(. == \"kasbah-net\")
        " compose.prod.yml 2>/dev/null || echo "false")"

        if [ "$has_hn" = "true" ]; then
            joined=1
        elif [ "$default_aliases_hn" = 1 ]; then
            # Services with no explicit networks key inherit the default;
            # an explicit list overrides it entirely.
            local has_nets
            has_nets="$(yq -r ".services[\"$svc\"] | has(\"networks\")" compose.prod.yml 2>/dev/null || echo false)"
            [ "$has_nets" = "true" ] || joined=1
        fi

        cn="$(yq -r ".services[\"$svc\"].container_name // \"\"" compose.prod.yml 2>/dev/null)"
        if [ -n "$cn" ] && [ "$cn" != "null" ] && [ -n "$routed_hosts" ] \
            && grep -qxF -- "$cn" <<<"$routed_hosts"; then
            routed=1
            any_routed=1
        fi

        [ "$joined" = 1 ] && any_uses_hn=1
        if [ "$routed" = 1 ] && [ "$joined" = 0 ]; then
            bad_c03+=("$svc")
        fi
        # Under the banned default-alias shape C07 reports the pattern itself,
        # not a per-service list.
        if [ "$routed" = 0 ] && [ "$joined" = 1 ] && [ "$default_aliases_hn" = 0 ]; then
            bad_c07+=("$svc")
        fi
    done <<<"$services"

    # C03
    if [ "${#bad_c03[@]}" -gt 0 ]; then
        _check_fail "Routed services not on kasbah-net: ${bad_c03[*]}"
    elif [ "$any_routed" = 1 ]; then
        _check_pass "All routed services join kasbah-net"
    else
        _check_pass "No Traefik-routed services in compose"
    fi

    # C04 — only meaningful if a service actually joins kasbah-net.
    if [ "$any_uses_hn" = 1 ]; then
        if [ "$hn_ext" = "true" ] || { [ "$default_aliases_hn" = 1 ] && [ "$default_ext" = "true" ]; }; then
            _check_pass "kasbah-net declared external"
        else
            _check_fail "kasbah-net not declared external: true"
        fi
    fi

    # C07
    if [ "$default_aliases_hn" = 1 ]; then
        _check_fail "default network aliases kasbah-net — every service joins the shared network; join it explicitly per routed service and keep the rest on a project-internal network"
    elif [ "${#bad_c07[@]}" -gt 0 ]; then
        _check_fail "Non-routed services on kasbah-net: ${bad_c07[*]}"
    else
        _check_pass "No internal services on kasbah-net"
    fi
}

# C05: a top-level `version:` field is deprecated by modern Compose and
# silently ignored. Warn rather than fail — the file still works.
_check_c05_version() {
    local v
    v="$(yq -r '.version // ""' compose.prod.yml)"
    if [ -n "$v" ]; then
        _check_warn "compose.prod.yml uses deprecated 'version:' field"
    else
        _check_pass "No deprecated 'version:' field"
    fi
}

# ----------------------------------------------------------------------------
# Resources (R01–R03; R04 needs --server)
# ----------------------------------------------------------------------------
# Hard limits via the kasbah-managed vars only (see docs/server-setup.md).
# Literal values are rejected so limits scale with the host instead of
# fossilizing one VPS's numbers. Section is silent when compose is missing,
# unparseable, or empty — S03 / the Compose section already reported that.

_check_resources_section() {
    local services="$1"
    [ -f compose.prod.yml ] || return 0
    [ -n "$services" ] || return 0
    yq -r '.' compose.prod.yml >/dev/null 2>&1 || return 0

    echo
    echo "Resources:"
    _check_r01_r02_limits "$services"
    _check_r03_reservations "$services"
}

# R01/R02: every service sets cpus: ${KASBAH_CPU_LIMIT} and
# mem_limit: ${KASBAH_MEM_LIMIT} — exactly those var references. Missing
# and literal values both fail.
_check_r01_r02_limits() {
    local services="$1" svc cpus mem
    local bad=()
    while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        local wrong=""
        cpus="$(yq -r ".services[\"$svc\"].cpus // \"\"" compose.prod.yml 2>/dev/null || echo "")"
        mem="$(yq  -r ".services[\"$svc\"].mem_limit // \"\"" compose.prod.yml 2>/dev/null || echo "")"
        [ "$cpus" = '${KASBAH_CPU_LIMIT}' ] || wrong="cpus"
        if [ "$mem" != '${KASBAH_MEM_LIMIT}' ]; then
            wrong="${wrong:+$wrong,}mem_limit"
        fi
        [ -z "$wrong" ] || bad+=("$svc($wrong)")
    done <<<"$services"
    if [ "${#bad[@]}" -eq 0 ]; then
        _check_pass "All services set cpus/mem_limit via KASBAH_* vars"
    else
        _check_fail "Services with missing or literal resource limits: ${bad[*]}"
    fi
}

# R03: reservations are banned — kasbah's limits are anti-takeover
# ceilings, not scheduler hints.
_check_r03_reservations() {
    local services="$1" svc bad=()
    while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        local resv memr
        resv="$(yq -r ".services[\"$svc\"].deploy.resources.reservations // null" compose.prod.yml 2>/dev/null || echo null)"
        memr="$(yq -r ".services[\"$svc\"].mem_reservation // \"\"" compose.prod.yml 2>/dev/null || echo "")"
        if [ "$resv" != "null" ] || { [ -n "$memr" ] && [ "$memr" != "null" ]; }; then
            bad+=("$svc")
        fi
    done <<<"$services"
    if [ "${#bad[@]}" -eq 0 ]; then
        _check_pass "No resource reservations"
    else
        _check_fail "Services declare resource reservations: ${bad[*]}"
    fi
}

# ----------------------------------------------------------------------------
# Traefik (T01–T07)
# ----------------------------------------------------------------------------
# Routing is declared via file-provider fragments (see docs/traefik.md). T06
# scans compose.prod.yml for `traefik.*` labels (the docker provider is not
# wired in). T01–T05 inspect the project's own traefik-dynamic.yml; T07
# cross-checks its loadBalancer targets against compose container_names.
#
# T01 is a warn (not fail) so worker-only projects without web routing don't
# tip the whole check. When the file is missing or malformed, T02–T05 are
# skipped — there's nothing to verify.

_check_traefik_section() {
    local services="$1"

    echo
    echo "Traefik:"

    # Section order matches the docs example: T01 → T02 → T03 → T04 → T05 →
    # T06. T06 (compose-label scan) is independent of traefik-dynamic.yml,
    # so it runs unconditionally — even when T01 short-circuited T02–T05.
    local routers="" parsed=0
    if [ ! -f traefik-dynamic.yml ]; then
        _check_warn "traefik-dynamic.yml missing — skipping T02–T05"
    elif ! routers="$(yq -r '(.http.routers // {}) | keys | .[]' traefik-dynamic.yml 2>/dev/null)"; then
        # T01 is a warn (per docs/compliance.md). A malformed file is the
        # same user-facing condition as a missing one — routing is broken
        # either way — so use the same level rather than flipping to fail.
        _check_warn "traefik-dynamic.yml does not parse as YAML — skipping T02–T05"
    else
        _check_pass "traefik-dynamic.yml exists"
        parsed=1
    fi

    if [ "$parsed" = 1 ]; then
        if [ -n "$MANIFEST_DOMAIN" ]; then
            _check_t02_domain_router "$routers"
        else
            _check_warn "manifest domain is empty — skipping T02 (router/domain match)"
        fi
        _check_t03_entrypoints "$routers"
        _check_t04_letsencrypt "$routers"
        _check_t05_reserved_hostnames "$routers"
        _check_t07_fragment_targets "$services"
    fi

    _check_t06_no_labels "$services"
}

# T06: no service in compose.prod.yml carries a `traefik.*` label. Labels can
# be a list (["k=v","k"]) or a map ({k: v}); we normalize to a list of keys
# and check the prefix on each.
_check_t06_no_labels() {
    local services="$1" svc bad=()
    if [ -z "$services" ]; then
        _check_pass "compose.prod.yml has no traefik.* labels"
        return 0
    fi
    while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        local has
        has="$(yq -r "
            .services[\"$svc\"].labels
            | if . == null then []
              elif type == \"object\" then keys
              else map(tostring | sub(\"=.*\"; \"\"))
              end
            | any(startswith(\"traefik.\"))
        " compose.prod.yml 2>/dev/null || echo "false")"
        [ "$has" = "true" ] && bad+=("$svc")
    done <<<"$services"
    if [ "${#bad[@]}" -eq 0 ]; then
        _check_pass "compose.prod.yml has no traefik.* labels"
    else
        _check_fail "Services carry traefik.* labels (file provider only): ${bad[*]}"
    fi
}

# T02: at least one router's `rule` references the manifest domain. Substring
# match — we'd rather false-pass on a redirect-only router that mentions the
# domain than parse Host()/HostRegexp/HostHeader properly here. Tightens
# later when --server mode lands.
_check_t02_domain_router() {
    local routers="$1" r found=0
    while IFS= read -r r; do
        [ -z "$r" ] && continue
        local rule
        rule="$(yq -r ".http.routers[\"$r\"].rule // \"\"" traefik-dynamic.yml)"
        if [[ "$rule" == *"$MANIFEST_DOMAIN"* ]]; then
            found=1
            break
        fi
    done <<<"$routers"
    if [ "$found" = 1 ]; then
        _check_pass "At least one router references manifest domain ($MANIFEST_DOMAIN)"
    else
        _check_fail "No router rule references manifest domain ($MANIFEST_DOMAIN)"
    fi
}

# T03: every router declares a non-empty entryPoints list. Routers without
# one fall back to all entryPoints, which is rarely what the author wanted.
_check_t03_entrypoints() {
    local routers="$1" r bad=()
    while IFS= read -r r; do
        [ -z "$r" ] && continue
        local n
        n="$(yq -r ".http.routers[\"$r\"].entryPoints // [] | length" traefik-dynamic.yml)"
        [ "$n" = "0" ] && bad+=("$r")
    done <<<"$routers"
    if [ "${#bad[@]}" -eq 0 ]; then
        _check_pass "All routers declare entryPoints"
    else
        _check_fail "Routers without entryPoints: ${bad[*]}"
    fi
}

# T04: any router on `websecure` references tls.certResolver=letsencrypt.
# Without it Traefik won't request a cert and the route will 404 on TLS.
_check_t04_letsencrypt() {
    local routers="$1" r bad=()
    while IFS= read -r r; do
        [ -z "$r" ] && continue
        local secure cert
        secure="$(yq -r ".http.routers[\"$r\"].entryPoints // [] | any(. == \"websecure\")" traefik-dynamic.yml)"
        [ "$secure" = "true" ] || continue
        cert="$(yq -r ".http.routers[\"$r\"].tls.certResolver // \"\"" traefik-dynamic.yml)"
        [ "$cert" = "letsencrypt" ] || bad+=("$r")
    done <<<"$routers"
    if [ "${#bad[@]}" -eq 0 ]; then
        _check_pass "Secure routers reference letsencrypt cert resolver"
    else
        _check_fail "Websecure routers without tls.certResolver=letsencrypt: ${bad[*]}"
    fi
}

# T07: every hostname in the fragment's loadBalancer server URLs must be an
# explicit container_name in compose. Container names are unique per host
# (Docker errors on duplicates), unlike service-name DNS aliases — this is
# what makes fragment targets collision-proof on the shared network. Skipped
# when compose has no services (already warned) or the fragment has no
# loadBalancer services (redirect-only projects).
_check_t07_fragment_targets() {
    local services="$1"
    [ -n "$services" ] || return 0
    local hosts
    hosts="$(_traefik_routed_hosts | sort -u)"
    if [ -z "$hosts" ]; then
        _check_pass "Fragment has no loadBalancer server URLs to verify"
        return 0
    fi
    local names
    names="$(_compose_container_names "$services" | sort -u)"
    local bad=() h
    while IFS= read -r h; do
        [ -z "$h" ] && continue
        grep -qxF -- "$h" <<<"$names" || bad+=("$h")
    done <<<"$hosts"
    if [ "${#bad[@]}" -eq 0 ]; then
        _check_pass "Fragment loadBalancer URLs target explicit container_names"
    else
        _check_fail "Fragment targets unknown container_names: ${bad[*]} (set container_name in compose.prod.yml)"
    fi
}

# T05: heuristic — any router rule whose Host() argument's first DNS label is
# `traefik`, `mail`, or `webmail` is treated as claiming a kasbah-owned
# subdomain. The strict spec says `traefik.<server-apex>` etc., but the
# server apex isn't available locally. The first-label check catches the
# common-mistake shape (project tries to add its own dashboard/mail router)
# while accepting domains like `mailhog.example.com` that just happen to
# start with mail-adjacent text.
_check_t05_reserved_hostnames() {
    local routers="$1" r bad=()
    while IFS= read -r r; do
        [ -z "$r" ] && continue
        local rule
        rule="$(yq -r ".http.routers[\"$r\"].rule // \"\"" traefik-dynamic.yml)"
        # Walk every Host(`…`) match in the rule. ${s#*"$match"} chops off
        # everything up through the matched substring, advancing the loop.
        local s="$rule"
        while [[ "$s" =~ Host\(\`([^\`]+)\`\) ]]; do
            local host="${BASH_REMATCH[1]}"
            local first="${host%%.*}"
            case "$first" in
                traefik|mail|webmail) bad+=("$r→$host") ;;
            esac
            s="${s#*"${BASH_REMATCH[0]}"}"
        done
    done <<<"$routers"
    if [ "${#bad[@]}" -eq 0 ]; then
        _check_pass "No router claims reserved hostnames (traefik.*, mail.*, webmail.*)"
    else
        _check_fail "Routers claim reserved hostnames: ${bad[*]}"
    fi
}

# ----------------------------------------------------------------------------
# Healthchecks (H01, H02)
# ----------------------------------------------------------------------------
# Section header is suppressed when there's nothing to check (no built
# services and no manifest health block) — the alternative would be an empty
# "Healthchecks:" block on every stock-image project, which is just noise.

_check_healthcheck_section() {
    local services="$1"
    local has_built=0 has_health=0

    # Conditions must be split into `if` (not `&&` chains) — under set -e a
    # chained `cond && set_flag=1` whose `cond` is false makes the whole
    # statement evaluate to non-zero, killing the script outside a conditional.
    if [ -f compose.prod.yml ] && [ -n "$services" ] && _compose_any_built "$services"; then
        has_built=1
    fi
    if _manifest_has_block ".health"; then
        has_health=1
    fi

    if [ "$has_built" = 0 ] && [ "$has_health" = 0 ]; then
        return 0
    fi

    echo
    echo "Healthchecks:"
    [ "$has_built"  = 1 ] && _check_h01_build_healthchecks "$services"
    [ "$has_health" = 1 ] && _check_h02_health_container   "$services"
    return 0
}

# H01 (warn): every service with a `build:` key has a compose-level
# `healthcheck:`. We can't see HEALTHCHECK directives inside the Dockerfile,
# so a built image with its own HEALTHCHECK still trips this — hence warn,
# not fail. Author can ignore if Dockerfile already declares one.
_check_h01_build_healthchecks() {
    local services="$1" svc bad=()
    while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        local has_build hc
        has_build="$(yq -r ".services[\"$svc\"] | has(\"build\")" compose.prod.yml 2>/dev/null || echo false)"
        [ "$has_build" = "true" ] || continue
        hc="$(yq -r ".services[\"$svc\"].healthcheck // null" compose.prod.yml 2>/dev/null)"
        [ "$hc" = "null" ] && bad+=("$svc")
    done <<<"$services"
    if [ "${#bad[@]}" -eq 0 ]; then
        _check_pass "All built services declare a compose healthcheck"
    else
        _check_warn "Built services without a compose healthcheck (Dockerfile may declare one): ${bad[*]}"
    fi
}

# H02 (fail): when the manifest's health: names a container, it must match an
# explicit container_name in compose. Auto-generated names depend on the running
# compose project name, which we can't resolve locally — so the convention is
# "set container_name on the service you want to wait on".
#
# `container:` itself is optional. Without it the deploy waits on every container
# in the compose project, which is what docs/project-manifest.md says health:
# defaults to — so a block carrying only `timeout:` is how that path's budget is
# raised, and failing it made the documented default unreachable.
_check_h02_health_container() {
    local services="$1" container names
    container="$(yq -r '.health.container // ""' "$KASBAH_MANIFEST_FILE")"
    if [ -z "$container" ] || [ "$container" = "null" ]; then
        _check_pass "manifest health: names no container — the deploy waits on every container with a healthcheck"
        return 0
    fi
    # Capture into a here-string before grep -q. Piping `_compose_container_names`
    # straight into `grep -q` raced: grep exits at first match, the producer's
    # next yq write hits SIGPIPE, pipefail propagates, errexit kills the script.
    names="$(_compose_container_names "$services")"
    if grep -qxF -- "$container" <<<"$names"; then
        _check_pass "manifest health.container '$container' exists in compose"
    else
        _check_fail "manifest health.container '$container' not found among compose container_names"
    fi
}

# ----------------------------------------------------------------------------
# Env (E01–E05)
# ----------------------------------------------------------------------------
# Skipped silently if .env.prod.example is missing — S04 has already failed
# for that case.

_check_env_section() {
    [ -f .env.prod.example ] || return 0
    echo
    echo "Env:"
    _check_e01_syntax
    _check_e02_e03_drift
    _check_e04_long_values
    _check_e05_reserved_prefix
}

# E01: every line is empty, a comment (`#…`), or an assignment in the shape
# lib/env.sh reads (ENV_ASSIGN_RE — Compose's, so `export FOO=1` and a leading
# blank both count). Anything else (e.g. `FOO BAR=baz`, `=value`, `1FOO=bar`)
# setup-env.sh preserves verbatim instead of prompting for, so the key the
# author meant never reaches .env.
_check_e01_syntax() {
    local f=.env.prod.example bad=() lineno=0 line
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ $ENV_ASSIGN_RE ]] && continue
        bad+=("$lineno")
    done < "$f"
    if [ "${#bad[@]}" -eq 0 ]; then
        _check_pass ".env.prod.example syntax is valid"
    else
        _check_fail ".env.prod.example has invalid lines (line numbers: ${bad[*]})"
    fi
}

# E02/E03: only run when .env exists. env_drift (lib/env.sh) is the same
# function the deploy path and the VPS-side setup call, KASBAH_* exemption
# included; this only reports its two lists.
_check_e02_e03_drift() {
    [ -f .env ] || return 0
    env_drift .env.prod.example .env
    if [ -z "$ENV_DRIFT_MISSING" ]; then
        _check_pass ".env has no missing keys vs .env.prod.example"
    else
        _check_warn ".env missing keys vs .env.prod.example: $ENV_DRIFT_MISSING"
    fi
    if [ -z "$ENV_DRIFT_EXTRA" ]; then
        _check_pass ".env has no extra keys vs .env.prod.example"
    else
        _check_warn ".env has extra keys not in .env.prod.example: $ENV_DRIFT_EXTRA"
    fi
}

# E04: a literal long value in a committed template is almost always a leaked
# secret. `!`-generators and `#`-only hint lines are exempt; an inline
# `value # comment` is split on the first space-hash and only the value side
# is measured.
_check_e04_long_values() {
    local f=.env.prod.example bad=() line key val val_only
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        [[ "$line" =~ $ENV_ASSIGN_RE ]] || continue
        key="${BASH_REMATCH[2]}"
        val="${BASH_REMATCH[3]}"
        [[ "$val" =~ ^[[:space:]]*! ]] && continue
        [[ "$val" =~ ^[[:space:]]*# ]] && continue
        val_only="$(printf '%s' "$val" | sed -E 's/[[:space:]]+#.*$//')"
        [ "${#val_only}" -gt 64 ] && bad+=("$key")
    done < "$f"
    if [ "${#bad[@]}" -eq 0 ]; then
        _check_pass ".env.prod.example has no obvious long secrets"
    else
        _check_warn ".env.prod.example has values >64 chars (possibly leaked secrets): ${bad[*]}"
    fi
}

# E05 (warn): a key the template opens with `KASBAH_`. Setup skips it and the
# managed block owns it, so the line only misleads — warn, because a fail here
# would be the only env rule able to push `check` to exit 6.
_check_e05_reserved_prefix() {
    local bad=() key keys
    keys="$(env_extract_keys .env.prod.example)"
    while IFS= read -r key; do
        case "$key" in "$ENV_RESERVED_PREFIX"*) bad+=("$key") ;; esac
    done <<<"$keys"
    if [ "${#bad[@]}" -eq 0 ]; then
        _check_pass ".env.prod.example leaves the ${ENV_RESERVED_PREFIX}* prefix to kasbah"
    else
        _check_warn ".env.prod.example defines reserved ${ENV_RESERVED_PREFIX}* keys (kasbah injects these): ${bad[*]}"
    fi
}

# ----------------------------------------------------------------------------
# Hooks (HK01–HK03)
# ----------------------------------------------------------------------------
# Section header is suppressed when the manifest has neither a `hooks:` nor
# a `backup:` block. HK01 + HK03 both validate against the same
# container_names set, so we compute it once.

_check_hooks_section() {
    local services="$1"
    local has_hooks=0 has_backup=0
    if _manifest_has_block ".hooks"; then  has_hooks=1;  fi
    if _manifest_has_block ".backup"; then has_backup=1; fi
    if [ "$has_hooks" = 0 ] && [ "$has_backup" = 0 ]; then
        return 0
    fi

    echo
    echo "Hooks:"

    # Pre-compute the container_name set. Empty when no service sets one;
    # in that case every HK01/HK03 lookup will miss, which is what we want
    # — the convention is "set container_name on anything you exec into".
    local container_names
    container_names="$(_compose_container_names "$services" | sort -u)"

    [ "$has_hooks" = 1 ] && _check_hk01_hook_targets "$container_names"
    if [ "$has_backup" = 1 ]; then
        _check_hk02_backup_fields
        _check_hk03_backup_container "$container_names"
    fi
    return 0
}

# HK01: every hook string's first whitespace-delimited token (the target
# container) is present in the compose container_name set. Unknown
# containers fail rather than warn — the hook will literally not run on
# deploy if the name is wrong.
_check_hk01_hook_targets() {
    local container_names="$1"
    local hooks
    hooks="$(yq -r '.hooks // {} | to_entries[] | .value[]?' "$KASBAH_MANIFEST_FILE" 2>/dev/null)"
    if [ -z "$hooks" ]; then
        _check_pass "Hooks block is empty"
        return 0
    fi
    local bad=() h c
    while IFS= read -r h; do
        [ -z "$h" ] && continue
        c="${h%%[[:space:]]*}"
        if ! grep -qxF -- "$c" <<<"$container_names"; then
            bad+=("$c")
        fi
    done <<<"$hooks"
    if [ "${#bad[@]}" -eq 0 ]; then
        _check_pass "All hook commands target known container_names"
    else
        # Hooks run via `docker exec <name>`, which needs the literal
        # container — compose's auto-generated `<project>_<svc>_1` won't
        # match a hook that names just the service. Hint at the cause.
        _check_fail "Hooks reference unknown container_names: ${bad[*]} (set container_name on the target service in compose.prod.yml)"
    fi
}

# HK02: backup hook needs check + command + extension. Without all three,
# either the backup never runs or the resulting file has no extension.
_check_hk02_backup_fields() {
    local missing=() f v
    for f in check command extension; do
        v="$(yq -r ".backup[\"$f\"] // \"\"" "$KASBAH_MANIFEST_FILE")"
        if [ -z "$v" ] || [ "$v" = "null" ]; then
            missing+=("$f")
        fi
    done
    if [ "${#missing[@]}" -eq 0 ]; then
        _check_pass "Backup hook has check, command, and extension"
    else
        _check_fail "Backup hook missing required field(s): ${missing[*]}"
    fi
}

# HK03: backup container resolves to a known compose container_name. Same
# rationale as HK01.
_check_hk03_backup_container() {
    local container_names="$1" c
    c="$(yq -r '.backup.container // ""' "$KASBAH_MANIFEST_FILE")"
    if [ -z "$c" ] || [ "$c" = "null" ]; then
        _check_fail "Backup hook missing 'container' field"
        return 0
    fi
    if grep -qxF -- "$c" <<<"$container_names"; then
        _check_pass "Backup hook container '$c' exists in compose"
    else
        _check_fail "Backup hook container '$c' not found among compose container_names"
    fi
}

# ----------------------------------------------------------------------------
# Helpers reused across H/HK sections
# ----------------------------------------------------------------------------

# True (exit 0) iff the manifest has a non-null value at the given jq path
# (e.g. ".health", ".hooks", ".backup"). Used to gate whole sections.
_manifest_has_block() {
    local path="$1" v
    v="$(yq -r "$path // null" "$KASBAH_MANIFEST_FILE" 2>/dev/null)"
    [ "$v" != "null" ] && [ -n "$v" ]
}

# True (exit 0) iff at least one service in `services` has a `build:` key.
_compose_any_built() {
    local services="$1" svc
    while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        local hb
        hb="$(yq -r ".services[\"$svc\"] | has(\"build\")" compose.prod.yml 2>/dev/null || echo false)"
        [ "$hb" = "true" ] && return 0
    done <<<"$services"
    return 1
}

# Hostnames targeted by the fragment's loadBalancer server URLs
# (http://<host>:<port> → <host>), one per line. Empty when the fragment is
# missing, malformed, or has no loadBalancer services. Used by the network
# rules (C03/C07 routed-service detection) and T07.
_traefik_routed_hosts() {
    [ -f traefik-dynamic.yml ] || return 0
    { yq -r '(.http.services // {}) | to_entries[] | (.value.loadBalancer.servers // [])[] | .url // ""' \
        traefik-dynamic.yml 2>/dev/null || true; } \
        | sed -E 's#^[A-Za-z0-9+.-]+://##; s#[:/].*$##' | awk 'NF'
    return 0
}

# Print every explicit container_name from compose.prod.yml, one per line.
# Services without container_name are skipped (auto-generated names depend
# on the compose project name, which is set at runtime on the VPS).
_compose_container_names() {
    local services="$1" svc cn
    while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        cn="$(yq -r ".services[\"$svc\"].container_name // \"\"" compose.prod.yml 2>/dev/null)"
        [ -n "$cn" ] && [ "$cn" != "null" ] && printf '%s\n' "$cn"
    done <<<"$services"
    # Loop ends with read returning 1 (EOF); under errexit a bare
    # `var=$(_compose_container_names …)` would propagate that. Pin to 0.
    return 0
}
