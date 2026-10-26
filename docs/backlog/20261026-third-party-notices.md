---
description: >
  Every release binary compiles in code whose licences require their notices to
  travel with binary copies — the Go standard library and golang.org/x/crypto
  and x/sys (BSD-3-Clause), go.yaml.in/yaml/v3 (MIT, and Apache-2.0 with a
  NOTICE file) — and no release carries them. Choose how a release ships them,
  in release.sh or in the binary — kasbah's own MIT notice with them, which
  its licence asks of every copy too.
state: needs-decision
priority: normal
urgency: Before the first public release ([[go-public]]).
---

## Prompted by

Choosing kasbah's own licence on 2026-10-26 (MIT, `LICENSE`). Asked whether
shipping the dependencies' notices was really necessary, the answer from their
licence texts is yes.

## Evidence

- BSD-3-Clause, clause 2 (`golang.org/x/crypto@v0.58.0/LICENSE`, the same text
  in `x/sys` and in Go's own `LICENSE`): "Redistributions in binary form must
  reproduce the above copyright notice, this list of conditions and the
  following disclaimer in the documentation and/or other materials provided
  with the distribution." The standard library is in every Go binary.
- `go.yaml.in/yaml/v3@v3.0.5/LICENSE`: MIT for the files ported from libyaml,
  Apache-2.0 for the rest, with a `NOTICE` that Apache-2.0 §4(d) requires
  distributions to include.
- `release.sh` stages the two binaries, `get.sh`, `checksums.txt` and its
  signature, and nothing else; no licence text is embedded in the binary.

## To decide

1. **Where the notices go.**
   - *In the binary* — embedded text printed by a command or flag. Travels with
     every copy, including the one kasbah ships to each server, and needs no
     new asset.
   - *As a release asset* — a `THIRD_PARTY_NOTICES` file staged by
     `release.sh stage` and covered by `checksums.txt`. Adding an asset renames
     nothing frozen, but `get.sh` and `self-update` downloads ignore it, so a
     binary copied on its own has no notices.

## Work

- [ ] Generate the notice text from kasbah's `LICENSE`, `go.mod`'s dependency
      set and Go's own licence, and a test that fails when a dependency is
      added without one
- [ ] Ship it the chosen way; `docs/overview.md` (Distribution) and
      `docs/files.md` describe it
