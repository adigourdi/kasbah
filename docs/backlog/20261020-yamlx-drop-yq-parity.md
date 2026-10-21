---
description: >
  `internal/yamlx` + `internal/jv` reproduce kislyuk `yq` 3.1.0's output byte for
  byte (a Python-object model, `0755` as octal, jq 1.7 number spelling, 4.9 MB of
  goldens) to stay equal to the Bash tool — which no longer exists. Decide whether
  the reader keeps that contract or moves to plain YAML 1.2 as `go.yaml.in/yaml/v3`
  reads it; the `check` rules that read compose values, and CLAUDE.md's hard
  convention, change with it.
state: needs-decision
priority: low
---

## Prompted by

Reviewing the Bash→Go session (`d5b16191`, Phase 10) the day after it closed. The
yq-exact reader was the right call *while both versions coexisted*: `check` was
proven equal to Bash over 672 projects by parsing the way `yq` did. With Bash
deleted (`be5f6b7`), the parity target is gone and the quirks are preserved for
their own sake: "a byte-exact reimplementation of `yq` 3.1.0's output … now Bash
is gone it's a quirk being preserved for its own sake".

## Evidence

- `internal/yamlx` models values as Python holds them before `json.dump` + jq
  (`obj` with `*big.Int`, Python key identity, `!!omap` pairs) — `internal/yamlx/yamlx.go`.
- `internal/jv/json.go:14` parses JSON "as jq 1.7 does" (BOM, nan/inf, loose numbers).
- 2.1k lines across both packages; `internal/yamlx/testdata` is 4.9 MB of goldens
  regenerated from the real `yq` (`testdata/regen.sh`), so changing the contract
  needs a `yq` install to re-prove.
- 24 non-test files import `yamlx`/`jv`; `CLAUDE.md:40` records the contract as a
  hard convention; `docs/compliance.md:212` ties rule evaluation to "the parsed
  tree (the one `yq -c .` prints)".

## To decide

1. **Keep or drop the contract.** Keep: nothing to do beyond rewording CLAUDE.md
   to say *why* (compose files are read as a YAML 1.2-with-octal tree, the goldens
   pin it). Drop: read with `yaml/v3` defaults; the diff is mostly `0755`-style
   octal, number formatting, and merge-key/anchor edge cases — enumerate it from
   the goldens before choosing.
2. **What depends on the old reading on servers.** Manifests and markers kasbah
   wrote are its own format (schema 1); `check` reads user compose files only on
   the workstation. If nothing server-side depends on yq semantics, there is no
   migration, only a behaviour change in `check` output — which must then go
   through `docs/compliance.md` and the rule goldens in the same change.
3. **Does `jv` survive?** If `check` no longer needs jq number spelling, `jv` may
   go entirely, or shrink to what `kasbah remote` reports still use.

## References

- `internal/yamlx/`, `internal/jv/`, `internal/yamlx/testdata/regen.sh`
- `CLAUDE.md` hard conventions (YAML line), `docs/compliance.md` §rule evaluation
- `docs/phases/10-recast.md` task 10.3 (why yq-exact was chosen)
