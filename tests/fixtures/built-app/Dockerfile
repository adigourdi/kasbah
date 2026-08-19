# The one image tests/integration/ship_test.sh builds, ships over ssh and looks
# for on the rig. Tiny on purpose: `docker save | gzip` runs on every rig suite,
# and every layer here is paid for twice — once over the wire, once in /tmp.
FROM nginx:alpine

# The page the deploy suites grep for. Distinctive enough that an nginx welcome
# page, a Traefik 404 and a 502 all fail to contain it.
RUN printf '%s\n' \
        '<!doctype html>' \
        '<html lang="en"><head><meta charset="utf-8">' \
        '<title>kasbah built-app fixture</title></head><body>' \
        '<h1>kasbah built-app fixture</h1>' \
        '<p id="marker">served-by-built-app-from-an-image-shipped-over-ssh</p>' \
        '</body></html>' \
    > /usr/share/nginx/html/index.html

# Declared in the image rather than in compose, so it travels inside the tarball
# and `docker image inspect` on the server can show that what arrived is this
# build and not a coincidence. A compose-level healthcheck would override it,
# which is why there is none there. wget is busybox's, already in nginx:alpine.
HEALTHCHECK --interval=5s --timeout=3s --start-period=2s --retries=6 \
    CMD wget -q -O /dev/null http://127.0.0.1/ || exit 1
