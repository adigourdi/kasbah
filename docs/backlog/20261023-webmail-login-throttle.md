---
description: >
  Cypht's login page has no throttle of its own. Its `brute_force` module keys
  lockouts on `REMOTE_ADDR`, which behind Traefik is always Traefik's address,
  so enabling it would let five failed logins from anyone lock every user out.
  The module is left out of `CYPHT_MODULES` in templates/mail/compose.yml.
state: parked
priority: low
---

## Prompted by

U1 of the SnappyMail → Cypht swap, 2026-10-23. `brute_force` was in the curated
module list, and the implementer found it could never record a failure:
`cypht.sqlite` is created by the entrypoint as root, so the www-data insert fails
with "attempt to write a readonly database", and Cypht swallows the error. Making
it writable was tested and works, but it would turn the module into a shared
lockout: it locks per IP *and* per username, and the IP is Traefik's for every client.

## Evidence

- `modules/brute_force/modules.php` (v2.13.0) reads `$this->request->server['REMOTE_ADDR']`,
  with `brute_force_max_attempts` 5 and `brute_force_lockout_duration` 900 by default.
- The image's `docker/nginx.conf` has no `real_ip` setup; `fastcgi_params` passes
  nginx's `$remote_addr`.
- Ownership fix, tested by the implementer: an entrypoint wrapper
  `touch /var/lib/hm3/cypht.sqlite && chown www-data:www-data /var/lib/hm3 /var/lib/hm3/cypht.sqlite && exec docker-entrypoint.sh`.

## Options

- **Real client IP.** Mount a kasbah-owned nginx.conf with `set_real_ip_from`
  for kasbah-net and `real_ip_header X-Forwarded-For` (Traefik appends the client),
  add the ownership wrapper, and re-enable `brute_force`. Costs a copy of an
  upstream file to re-check on every image bump. Containers on kasbah-net can
  reach `mail-cypht` directly and forge the header.
- **Throttle at Traefik.** A `rateLimit` middleware on the webmail router, keyed on
  the client IP Traefik sees, in `_mail.yml`. This needs no change to the image, but it
  limits all requests, not only failed logins.
