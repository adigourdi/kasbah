---
description: >
  docs/phases/README.md's cross-phase rules still describe the Bash tool: rule 3
  speaks of yq as kasbah's YAML reader, rule 4 asks for load-guarded helpers and
  points at check.sh, rule 8 forbids projects vendoring "kasbah bash", and rule
  2's frozen-contract list is an older subset of CLAUDE.md's. Reword them for
  the Go tool, or reduce the section to a pointer to CLAUDE.md.
state: ready
priority: low
---

## Prompted by

Reviewing CLAUDE.md on 2026-10-26 to make it near-static. The phases index
carries its own copy of the repo's rules, written in Phase 0 for the Bash tool,
and nothing has rewritten it since Phase 10 deleted the last Bash.

## Evidence

- `docs/phases/README.md`, "Cross-phase rules":
  - 2 lists `kasbah-net`, the entrypoints, the certresolver, the `_shared.yml`
    names, `versions.log`'s fields and the `KASBAH_` prefix — but not the
    manifest schema, the release tags and assets, or the installer URL that
    CLAUDE.md's Frozen contracts adds.
  - 3: "yq is the kislyuk wrapper (jq dialect). Do not write mikefarah v4
    syntax" — still true of the test suites, which write jq-syntax `yq`
    (`tests/release_test.sh`, `tests/check_test.sh`, several rig suites), but
    kasbah itself reads YAML with `internal/yamlx`; the rule now concerns tests
    only.
  - 4: "`set -euo pipefail` everywhere … see check.sh comments; helpers sourced
    with load guards" — `check.sh` no longer exists, and the test suites run
    under `set -uo pipefail` (CLAUDE.md, Shell scripts).
  - 8: "VPS-side helpers are kasbah-owned … projects never vendor kasbah bash"
    — the server now runs only the kasbah binary.

## Work

- [ ] Rules 1, 5–7 stay or point at CLAUDE.md; 2 and 4 are rewritten for the
      Go tool, 3 is scoped to the test suites, 8 is removed — so the rules have
      one home
