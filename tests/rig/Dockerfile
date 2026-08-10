# Fake VPS for hosting's integration tests: a container running its own
# dockerd behind sshd, so every hosting command exercises the real
# "SSH in, drive Docker over there" path instead of a local shortcut.
#
# Deliberately bare: no /apps, no hosting layout. Creating those here would
# hide whether `hosting server init` really builds them from nothing.
FROM debian:bookworm-slim

# Unpinned: whatever Docker's apt repo served on the day this image was last
# built is what the rig runs, indefinitely. Compose pairs `build:` with a fixed
# image name, so `up` never rebuilds on its own — refreshing these versions is
# an explicit rebuild, which is rig.sh's job. To reproduce a version regression:
#   HOSTING_RIG_DOCKER_VERSION=5:27.1.1-1~debian.12~bookworm \
#     docker compose -f tests/rig/compose.yml build
ARG DOCKER_APT_VERSION=

# rsync/openssl/gzip are not incidental: they are three rows of the
# prerequisites table in docs/server-setup.md, which the rig must satisfy for
# the integration suite to be a real check of it.
#
# openssh-server's postinst generates host keys; they are deleted again so the
# image ships no private key at all. The entrypoint regenerates them per
# container.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg \
         -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian %s stable\n' \
         "$(dpkg --print-architecture)" \
         "$(. /etc/os-release && echo "$VERSION_CODENAME")" \
         > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
         "docker-ce${DOCKER_APT_VERSION:+=$DOCKER_APT_VERSION}" \
         "docker-ce-cli${DOCKER_APT_VERSION:+=$DOCKER_APT_VERSION}" \
         containerd.io \
         docker-buildx-plugin \
         docker-compose-plugin \
         openssh-server \
         sudo \
         rsync \
         openssl \
         gzip \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/ssh/ssh_host_*


# A VPS deploy user, not root: root SSH is off (see the sshd drop-in below),
# and membership in `docker` is what makes `docker` work without sudo — its
# own row of the prerequisites table. Passwordless sudo mirrors what a real
# deploy user usually has, for later phases that need it.
RUN useradd --create-home --shell /bin/bash stevedore \
    && usermod -aG docker stevedore \
    && printf 'stevedore ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/stevedore \
    && chmod 0440 /etc/sudoers.d/stevedore

RUN printf '%s\n' \
        'PermitRootLogin no' \
        'PasswordAuthentication no' \
        'KbdInteractiveAuthentication no' \
        'PubkeyAuthentication yes' \
        > /etc/ssh/sshd_config.d/rig.conf

COPY entrypoint.sh /usr/local/bin/rig-entrypoint
RUN chmod 0755 /usr/local/bin/rig-entrypoint

EXPOSE 22 80 443

ENTRYPOINT ["/usr/local/bin/rig-entrypoint"]
