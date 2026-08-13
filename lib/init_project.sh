# hosting — init-project command
# Sourced by bin/hosting. Do not execute directly.

[ -n "${_HOSTING_INIT_PROJECT_LOADED:-}" ] && return 0
_HOSTING_INIT_PROJECT_LOADED=1

. "$HOSTING_LIB_DIR/common.sh"
. "$HOSTING_LIB_DIR/state.sh"

_init_project_usage() {
    cat <<EOF
Usage: hosting init-project [--name=<name>] [--domain=<fqdn>]

Scaffolds hosting metadata in the current directory:
  - hosting.yml           (manifest)
  - .env.prod.example     (env template skeleton)
  - .hosting/state.json   (project state)
  - .gitignore entries for .env and .hosting/

Does not create compose.prod.yml — that is user-authored.
EOF
}

cmd_init_project() {
    local name="" domain=""
    local name_given=0 domain_given=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --name=*)   name="${1#*=}"; name_given=1 ;;
            --domain=*) domain="${1#*=}"; domain_given=1 ;;
            -h|--help)  _init_project_usage; return 0 ;;
            *)          die "init-project: unknown argument '$1' (expected --name=X or --domain=X)" ;;
        esac
        shift
    done

    if [ "$name_given" = 1 ] && [ -z "$name" ]; then
        die "--name=<name> must not be empty"
    fi
    [ -n "$name" ] || name="$(basename "$PWD")"
    if ! [[ "$name" =~ ^[a-z][a-z0-9-]*$ ]]; then
        die "invalid project name '$name' (must match ^[a-z][a-z0-9-]*\$)"
    fi

    if [ "$domain_given" = 1 ] && ! _is_fqdn "$domain"; then
        die "invalid domain '$domain' (expected FQDN like app.example.com)"
    fi

    command -v jq >/dev/null || die "jq is required (install jq and retry)"

    # Pre-check every target path before writing anything, so we fail cleanly.
    local targets=(hosting.yml .env.prod.example .hosting/state.json)
    local t
    for t in "${targets[@]}"; do
        [ ! -e "$t" ] || die "$t already exists — refusing to overwrite"
    done

    # Snapshot .gitignore up front so the unwind path can restore it, even if
    # failure happens before _update_gitignore runs. The `; printf x` sentinel
    # protects trailing newlines, which `$(...)` otherwise strips.
    if [ -f .gitignore ]; then
        _INIT_GITIGNORE_EXISTED=1
        _INIT_GITIGNORE_SAVED="$(cat .gitignore; printf x)"
    else
        _INIT_GITIGNORE_EXISTED=0
        _INIT_GITIGNORE_SAVED=""
    fi
    _INIT_MADE_DIR=""

    # errtrace makes the ERR trap propagate into functions; without it, a
    # failure inside _write_manifest / state_init / etc. would skip cleanup.
    set -E
    trap '_init_cleanup' ERR

    _write_manifest "$name" "$domain"
    _write_env_example "$domain"
    if [ ! -d .hosting ]; then
        mkdir .hosting
        _INIT_MADE_DIR=.hosting
    fi
    state_init
    _update_gitignore

    trap - ERR

    info "Initialized hosting project '$name'"
    if [ -n "$domain" ]; then
        info "  domain: $domain"
    else
        warn "domain is empty — edit hosting.yml before deploying"
    fi
    echo
    _print_compose_snippet "$name" "$domain"
}

_init_cleanup() {
    rm -f hosting.yml .env.prod.example .hosting/state.json
    [ -n "${_INIT_MADE_DIR:-}" ] && rmdir "$_INIT_MADE_DIR" 2>/dev/null
    if [ "${_INIT_GITIGNORE_EXISTED:-0}" = 1 ]; then
        # Strip the trailing 'x' sentinel that protected the captured newlines.
        local g="${_INIT_GITIGNORE_SAVED:-}"
        printf '%s' "${g%x}" > .gitignore
    elif [ -f .gitignore ]; then
        rm -f .gitignore
    fi
    return 0
}

_write_manifest() {
    local name="$1" domain="$2"
    {
        printf 'schema: 1\n'
        printf 'hosting_version: %s\n' "$HOSTING_VERSION"
        printf '\n'
        printf 'name: %s\n' "$name"
        printf 'domain: "%s"\n' "$domain"
        printf '\n'
        printf 'sync:\n'
        printf '  - compose.prod.yml -> compose.yml\n'
        printf '  - .env.prod.example\n'
    } > hosting.yml
}

_write_env_example() {
    local domain="$1"
    {
        printf '# =============================================================================\n'
        printf '# Production Configuration\n'
        printf '# =============================================================================\n'
        printf '\n'
        printf '# --- Domain ---\n'
        printf 'DOMAIN=%s\n' "$domain"
    } > .env.prod.example
}

_update_gitignore() {
    local f=.gitignore
    [ -f "$f" ] || : > "$f"
    # Ensure trailing newline before appending so we don't join to an existing line.
    if [ -s "$f" ] && [ "$(tail -c 1 "$f" | wc -l)" -eq 0 ]; then
        printf '\n' >> "$f"
    fi
    grep -qxF '.env' "$f"      || printf '.env\n'      >> "$f"
    grep -qxF '.hosting/' "$f" || printf '.hosting/\n' >> "$f"
}

_print_compose_snippet() {
    local name="$1" domain="${2:-<your-domain>}"
    cat <<EOF
Next step: author compose.prod.yml. Starter snippet:

  services:
    app:
      image: nginx:alpine
      container_name: ${name}-web
      restart: unless-stopped
      cpus: \${HOSTING_CPU_LIMIT}
      mem_limit: \${HOSTING_MEM_LIMIT}
      logging:
        driver: json-file
        options:
          max-size: "10m"
          max-file: "3"
      networks: [hosting-net, internal]

  networks:
    hosting-net:
      external: true
    internal: {}

  Only Traefik-routed containers join hosting-net; everything else stays on
  the project-internal network (see docs/traefik.md). The HOSTING_* limits
  are injected into .env at deploy.

Routing is declared in traefik-dynamic.yml at the project root (see
docs/traefik.md). Starter:

  http:
    routers:
      ${name}:
        rule: "Host(\`${domain}\`)"
        entryPoints: [websecure]
        tls:
          certResolver: letsencrypt
        middlewares: ["security-headers@file", "gzip-compression@file"]
        service: ${name}
    services:
      ${name}:
        loadBalancer:
          servers:
            - url: "http://${name}-web:80"

Then run \`hosting check\` to validate structure.
EOF
}
