---
description: >
  `release.sh` and its hermetic suite are in; what is left is the signing key
  pair, which only the user can make (it takes a password): `./release.sh
  keygen`, then commit `release.pub` at the repo root — until then
  `release.sh` refuses to release and the self-update verifier has no key to
  embed.
state: blocked
priority: normal
after: "the user runs `./release.sh keygen` on this workstation"
---

## Work

- [ ] `release.pub` committed (user runs `./release.sh keygen`)
