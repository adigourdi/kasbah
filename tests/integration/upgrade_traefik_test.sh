#!/usr/bin/env bash
# Integration test: `kasbah server upgrade-traefik` against the live rig, over a
# real Traefik in a real daemon.
#
# What only the rig can show, and what the hermetic suite therefore cannot:
#   * a genuinely different Traefik image really being pulled, really replacing
#     the running proxy, and the proxy really still answering afterwards — read
#     back out of Traefik's own /api/version through its own :443, not out of
#     `docker inspect`;
#   * a **deliberately broken fragment** really failing the dry run: a stub can
#     only replay a log somebody wrote, and this is Traefik itself refusing a
#     file this suite planted;
#   * the throwaway leaving nothing behind — no container, no published port, no
#     second bind of :80;
#   * `server init` re-run after the bump leaving the new tag alone, which is the
#     one thing that stops a managed upgrade being reverted by the next re-run.
#
# The two directions are a pair on purpose. The successful bump is the
# precondition; the broken fragment is the deliverable, and its assertions are
# "the version did not move" — which is vacuous unless something else proves the
# command *can* move it. That is what the first half is for.
#
# The rig is treated as given: this suite never starts, resets or stops it.
#
# Exit status follows test.sh's contract: 0 pass, 1 an assertion failed, 2 the
# suite could not run at all (no rig).

set -uo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
. "$repo_dir/tests/integration/rig_env.sh"
need_yaml2json

apps=/apps
rig_domain=rig.test
dash_user=admin
dash_pass=hunter2hunter2
# Two tags that both exist and are genuinely different builds, neither of them
# the pin in internal/serverinit/args.go — so "the version moved" cannot be satisfied by the
# template's own default.
target_a=v3.6.7
target_b=v3.5.3

fail=0
assert() {
    if ! eval "$1"; then
        echo "  FAIL: $2" >&2
        fail=1
    fi
}

if [ ! -f "$RIG_SSH_CONFIG" ]; then
    echo "error: no $RIG_SSH_CONFIG — start the rig first (tests/rig/rig.sh up)" >&2
    exit 2
fi
if ! rig_reachable; then
    echo "error: the rig did not answer ssh — start it (tests/rig/rig.sh up)" >&2
    exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
rig_env_init "$work" || { echo "error: could not build the scratch ssh environment" >&2; exit 2; }
rig_clean || { echo "error: the rig could not be cleaned" >&2; exit 2; }

# --- A prepared server, with three fragments in the watch directory -----------------
init_out=$(kasbah_cli server init "$RIG_TARGET" \
    --domain="$rig_domain" --email="ops@$rig_domain" \
    --with-dashboard --traefik-auth="$dash_user:$dash_pass" \
    --no-mail --no-backup --acme-staging --yes 2>&1 </dev/null)
init_rc=$?
if [ "$init_rc" != 0 ]; then
    echo "error: server init did not succeed on the rig — nothing below can run" >&2
    printf '%s\n' "$init_out" >&2
    exit 2
fi

# `_mail.yml` and a project fragment, planted rather than deployed: what the dry
# run has to validate is *every* file in the directory, and the mail stack's own
# suite is where the mail stack is proved. The mail fragment is the real
# template, rendered — a hand-written stand-in would not carry the four routers
# it actually declares.
sed "s/__MAIL_PRIMARY_DOMAIN__/$rig_domain/g" "$repo_dir/templates/mail/_mail.yml" > "$work/_mail.yml"
# Two of them backed by real compose projects on their own kasbah networks,
# under <apps>/ as deployed projects are, joined to Traefik as deploy joins
# them: a recreated Traefik has to rejoin both, or each answers 502. A third,
# run by hand outside <apps>, is never joined.
for p in gallery shop; do
cat > "$work/$p.yml" <<YML
http:
  routers:
    gallery-http:
      rule: "Host(\`gallery.$rig_domain\`)"
      entryPoints: [web]
      middlewares: ["http-to-https@file"]
      service: noop@internal
    gallery:
      rule: "Host(\`gallery.$rig_domain\`)"
      entryPoints: [websecure]
      tls:
        certResolver: http
      middlewares: ["security-headers@file", "gzip-compression@file"]
      service: gallery
  services:
    gallery:
      loadBalancer:
        servers:
          - url: "http://gallery-web:80"
YML
sed -i "s/gallery/$p/g" "$work/$p.yml"
printf 'name: %s\nservices:\n  %s-web:\n    image: nginx:alpine\n    container_name: %s-web\n    networks: [kasbah]\nnetworks:\n  kasbah: {}\n' \
    "$p" "$p" "$p" > "$work/$p-compose.yml"
done
rsync -e "ssh -F $RIG_SSH_CONFIG" "$work/_mail.yml" "$work/gallery.yml" "$work/shop.yml" \
    "$RIG_SSH_ALIAS:$apps/traefik/dynamic/" >/dev/null \
    || { echo "error: could not plant the fragments on the rig" >&2; exit 2; }
for p in gallery shop; do
    rig_ssh "mkdir -p $apps/$p && cat > $apps/$p/compose.yml && cd $apps/$p &&
             docker compose -p $p up -d >/dev/null 2>&1 && docker network connect ${p}_kasbah traefik" \
        <"$work/$p-compose.yml" >/dev/null 2>&1 \
        || { echo "error: could not bring up the $p project on its own network" >&2; exit 2; }
done
sed 's/gallery/handrun/g' "$work/gallery-compose.yml" | rig_ssh "mkdir -p /tmp/kasbah-handrun && cat > /tmp/kasbah-handrun/compose.yml &&
    cd /tmp/kasbah-handrun && docker compose -p handrun up -d" >/dev/null 2>&1 \
    || { echo "error: could not bring up the hand-run project" >&2; exit 2; }

# Traefik's own answer about itself, through its own :443 and its own dashboard
# router — so "still serving" and "which version" are one read, and neither is
# `docker inspect` agreeing with itself.
api() {
    rig_ssh "curl -s -m 15 -k --resolve 'traefik.$rig_domain:443:127.0.0.1' -u '$dash_user:$dash_pass' 'https://traefik.$rig_domain/api/$1'" 2>/dev/null
}
served_version() {
    local body; body=$(api version)
    jq -r '.Version // ""' <<<"$body" 2>/dev/null
}
http_code() {
    rig_ssh "curl -s -o /dev/null -m 15 -w '%{http_code}' -H 'Host: $1' http://127.0.0.1/" 2>/dev/null
}
# Traefik picks a new fragment up on a watch tick, not on the rsync's return, so
# the first read after planting one is a race. Bounded, and the elapsed time is
# in the message: a poll that never succeeds must not read as a slow pass.
wait_code() {
    local host="$1" want="$2" waited=0 got=""
    while [ "$waited" -lt 15000 ]; do
        got=$(http_code "$host")
        [ "$got" != "$want" ] || break
        sleep 1; waited=$((waited + 1000))
    done
    printf '%s' "$got"
}
# 200 from the project's nginx through Traefik's :443; 502 when Traefik is not
# on the project's network.
https_code() {
    rig_ssh "curl -sk -o /dev/null -m 15 -w '%{http_code}' --resolve '$1:443:127.0.0.1' https://$1/" 2>/dev/null
}
wait_https() {
    local waited=0 got=""
    while [ "$waited" -lt 15 ]; do
        got=$(https_code "$1")
        [ "$got" != 200 ] || break
        sleep 1; waited=$((waited + 1))
    done
    printf '%s' "$got"
}
traefik_nets() { rig_ssh "docker inspect -f '{{range \$k, \$v := .NetworkSettings.Networks}}{{\$k}} {{end}}' traefik" 2>/dev/null; }
both_serve() {   # both_serve <when>
    local p
    for p in gallery shop; do
        assert '[ "$(wait_https $p.$rig_domain)" = 200 ]' \
            "$1: $p, on its own kasbah network, is served through Traefik (got '$(https_code $p.$rig_domain)', traefik on: $(traefik_nets))"
    done
}
inspected_image() { rig_ssh "docker inspect -f '{{.Config.Image}}' traefik" 2>/dev/null; }
acme_digest() { rig_ssh "openssl dgst -sha256 -r < $apps/data/traefik/letsencrypt/acme.json | cut -d' ' -f1" 2>/dev/null; }
dry_leftovers() { rig_ssh "docker ps -aq --filter label=kasbah.role=traefik-dry-run | wc -l" 2>/dev/null; }
backup_count() { rig_ssh "ls -1 $apps/traefik/backups 2>/dev/null | wc -l" 2>/dev/null; }

pinned=$(sed -n 's/^[[:space:]]*TraefikImage = "\(.*\)"$/\1/p' "$repo_dir/internal/serverinit/args.go")
before_image=$(inspected_image)
before_version=$(served_version)
before_acme=$(acme_digest)
assert '[ "$before_image" = "$pinned" ]' "the rig starts on kasbah's own pin (got '$before_image')"
assert '[ -n "$before_version" ]' "and Traefik answers /api/version through its own dashboard (got '$before_version')"
assert '[ "$(wait_code gallery.$rig_domain 301)" = 301 ]' \
    "the planted project fragment is live and redirecting (got '$(http_code gallery.$rig_domain)')"

both_serve "before any upgrade"
# Two projects on their own networks: neither reaches the other, by name or by
# address, while Traefik reaches both.
reach() { rig_ssh "docker exec $1 wget -q -T 3 -O /dev/null $2 >/dev/null 2>&1 && echo yes || echo no" 2>/dev/null | tr -d '\r'; }
shop_ip=$(rig_ssh "docker inspect -f '{{(index .NetworkSettings.Networks \"shop_kasbah\").IPAddress}}' shop-web" 2>/dev/null | tr -d '\r')
assert '[ -n "$shop_ip" ] && [ "$(reach traefik http://shop-web:80/)" = yes ] && [ "$(reach traefik http://$shop_ip:80/)" = yes ]' \
    "Traefik reaches shop-web by name and by address ($shop_ip)"
assert '[ "$(reach gallery-web http://127.0.0.1/)" = yes ]' "gallery-web answers itself — a no below is the network, not the probe"
assert '[ "$(reach gallery-web http://shop-web:80/)" = no ] && [ "$(reach gallery-web http://$shop_ip:80/)" = no ]' \
    "gallery-web reaches shop-web neither by name nor by address"
# The control: off its network, the same route is a 502. Left off, so the
# upgrade's rejoin is what brings it back.
rig_ssh "docker network disconnect shop_kasbah traefik" >/dev/null 2>&1
shop_off=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
    shop_off=$(https_code "shop.$rig_domain"); [ "$shop_off" != 502 ] || break; sleep 1
done
assert '[ "$shop_off" = 502 ]' "with Traefik off shop_kasbah, shop answers 502 (got '$shop_off')"

# --- Direction one: a real bump ------------------------------------------------------
up_out=$(kasbah_cli server upgrade-traefik "$RIG_TARGET" --version="$target_a" 2>&1 </dev/null)
up_rc=$?
assert '[ "$up_rc" = 0 ]' "the upgrade to $target_a succeeds (rc=$up_rc)
$up_out"
after_image=$(inspected_image)
after_version=$(served_version)
assert '[ "$after_image" = "traefik:$target_a" ]' "the container runs the new tag (got '$after_image')"
assert '[ "$after_version" = "${target_a#v}" ]' \
    "and Traefik itself says so through its own :443 — it is up and serving (got '$after_version')"
assert '[ "$after_version" != "$before_version" ]' \
    "the version genuinely moved (from '$before_version')"
assert '[ "$(http_code gallery.$rig_domain)" = 301 ]' \
    "the project fragment is still routing afterwards (got '$(http_code gallery.$rig_domain)')"
both_serve "after the upgrade recreated Traefik"
assert 'grep -qw gallery_kasbah <<<"$(traefik_nets)" && grep -qw shop_kasbah <<<"$(traefik_nets)"' \
    "Traefik is back on both project networks (on: $(traefik_nets))"
assert 'grep -qF "rejoined 2 project network(s): gallery_kasbah shop_kasbah" <<<"$up_out"' \
    "and the upgrade says it rejoined them (said: $up_out)"
assert '! grep -qw handrun_kasbah <<<"$(traefik_nets)"' \
    "and not a hand-run compose project's kasbah network outside $apps (on: $(traefik_nets))"
assert 'grep -qF "dry run passed" <<<"$up_out"' "the dry run ran and passed (said: $up_out)"
for router in traefik-dashboard@file mail-cert@file webmail@file gallery@file; do
    assert 'grep -qF "$router" <<<"$up_out"' \
        "and reports building $router out of the mounted fragments — every fragment was read"
done
assert '[ "$(dry_leftovers)" = 0 ]' "the throwaway left nothing behind (got '$(dry_leftovers)')"
assert '[ "$(acme_digest)" = "$before_acme" ]' "acme.json is byte-identical afterwards"

# The backup half, read off the server: the directory holds the bytes that were
# there *before*, which is the whole of what this command adds over `server init`.
bdir=$(sed -n 's/.*backed up .* to \(.*\)$/\1/p' <<<"$up_out" | tr -d '\r')
assert '[ -n "$bdir" ]' "the run names where it put the backup (said: $up_out)"
assert '[ "$(backup_count)" = 1 ]' "and made exactly one (got '$(backup_count)')"
backed_image=$(rig_ssh "cat '$bdir/compose.yml'" 2>/dev/null | yaml2json 2>/dev/null | jq -r '.services.traefik.image' 2>/dev/null)
assert '[ "$backed_image" = "$before_image" ]' \
    "the backed-up compose.yml is the one from before the overwrite (got '$backed_image')"
for f in traefik.yml _shared.yml kasbah-upgrade; do
    assert 'rig_ssh "test -f \"$bdir/$f\"" 2>/dev/null' "$f is in the backup too"
done
# Captured first, then matched: a producer piped into `grep -q` races SIGPIPE
# under pipefail, which is the one pattern CLAUDE.md refuses outright.
dyn_listing=$(rig_ssh "ls $apps/traefik/dynamic" 2>/dev/null)
assert '! grep -q backups <<<"$dyn_listing"' \
    "and nothing was written into the watched dynamic directory (got '$dyn_listing')"

# The reason the tag had to leave the template: a re-run of init must not undo
# this. Same flags as the init above, so the only thing that could move the
# image is init deciding it owns the value.
reinit_out=$(kasbah_cli server init "$RIG_TARGET" \
    --domain="$rig_domain" --email="ops@$rig_domain" \
    --with-dashboard --traefik-auth="$dash_user:$dash_pass" \
    --no-mail --no-backup --acme-staging --yes 2>&1 </dev/null)
assert '[ "$?" = 0 ]' "server init re-runs cleanly after an upgrade
$reinit_out"
assert '[ "$(inspected_image)" = "traefik:$target_a" ]' \
    "and leaves the upgraded tag alone — a managed bump survives the next init (got '$(inspected_image)')"
assert '[ "$(served_version)" = "${target_a#v}" ]' "the proxy is still serving that version"
both_serve "after a re-run of init"

# --- Direction two: a broken fragment stops the whole thing ---------------------------
#
# The middleware does not exist, which is the commonest way a project fragment
# is wrong and one the file provider only complains about at router-build time —
# a YAML parse accepts this file, so nothing short of booting Traefik catches it.
rig_ssh "cat > $apps/traefik/dynamic/broken.yml" <<'YML'
http:
  routers:
    broken:
      rule: "Host(`broken.rig.test`)"
      entryPoints: [websecure]
      tls:
        certResolver: http
      middlewares: ["does-not-exist@file"]
      service: broken
  services:
    broken:
      loadBalancer:
        servers:
          - url: "http://nowhere:80"
YML

bad_out=$(kasbah_cli server upgrade-traefik "$RIG_TARGET" --version="$target_b" 2>&1 </dev/null)
bad_rc=$?
assert '[ "$bad_rc" = 1 ]' "a broken fragment fails the upgrade (rc=$bad_rc)
$bad_out"
assert 'grep -qF "does-not-exist@file" <<<"$bad_out"' \
    "and the refusal repeats Traefik's own words about it (said: $bad_out)"
# The negatives, each paired with a positive above: the version moved for a good
# fragment and did not move for a bad one; a backup was made then and not now.
assert '[ "$(inspected_image)" = "traefik:$target_a" ]' \
    "the version did not move (got '$(inspected_image)')"
assert '[ "$(served_version)" = "${target_a#v}" ]' \
    "the proxy is still serving, on the version it was already on (got '$(served_version)')"
assert '[ "$(http_code gallery.$rig_domain)" = 301 ]' \
    "and the project fragment is still routing (got '$(http_code gallery.$rig_domain)')"
assert '[ "$(backup_count)" = 1 ]' \
    "nothing was backed up, so nothing was about to be overwritten (got '$(backup_count)')"
assert '[ "$(dry_leftovers)" = 0 ]' "and the throwaway left nothing behind (got '$(dry_leftovers)')"
assert '[ "$(acme_digest)" = "$before_acme" ]' "acme.json is untouched by a failed run too"

rig_ssh "rm -f $apps/traefik/dynamic/broken.yml" >/dev/null 2>&1

# --- Direction three: a server without a dashboard ------------------------------------
# Off is a recovered state, not a missing value, and the dry run's witness is its
# own anchor router rather than the dashboard's.
off_out=$(kasbah_cli server init "$RIG_TARGET" --no-dashboard \
    --no-mail --no-backup --acme-staging --yes 2>&1 </dev/null)
assert '[ "$?" = 0 ]' "server init --no-dashboard re-runs cleanly
$off_out"
off_shared=$(rig_ssh "cat $apps/traefik/dynamic/_shared.yml" 2>/dev/null)
assert '! grep -qF "traefik-dashboard" <<<"$off_shared"' "the dashboard routers are gone"
off_up=$(kasbah_cli server upgrade-traefik "$RIG_TARGET" --version="$target_b" 2>&1 </dev/null)
off_rc=$?
assert '[ "$off_rc" = 0 ]' "the upgrade to $target_b passes with the dashboard off (rc=$off_rc)
$off_up"
assert 'grep -qF "dry run passed" <<<"$off_up" && grep -qF "gallery@file" <<<"$off_up"' \
    "its dry run read the fragments (said: $off_up)"
assert '! grep -qF "traefik-dashboard@file" <<<"$off_up"' "and built no dashboard router"
assert '[ "$(inspected_image)" = "traefik:$target_b" ]' "the container runs the new tag (got '$(inspected_image)')"
both_serve "after the second upgrade"
assert '[ "$(rig_ssh "cat $apps/traefik/dynamic/_shared.yml" 2>/dev/null)" = "$off_shared" ]' \
    "and _shared.yml is still the off one — the anchor never shipped"
assert '[ "$(dry_leftovers)" = 0 ]' "the throwaway left nothing behind (got '$(dry_leftovers)')"

# A failure's state is left on the rig for inspection; a pass tidies up after
# itself, the same contract every integration suite here follows.
[ "$fail" != 0 ] || rig_clean >/dev/null 2>&1
exit "$fail"
