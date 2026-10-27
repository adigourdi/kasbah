---
description: >
  `internal/yamlx` + `internal/jv` reproduce kislyuk `yq` 3.1.0's output byte for
  byte (a Python-object model, `0755` as octal, jq 1.7 number spelling, 4.9 MB of
  goldens) to stay equal to the Bash tool — which no longer exists. Decide whether
  the reader keeps that contract or moves to plain YAML 1.2 as `go.yaml.in/yaml/v3`
  reads it; the `check` rules that read compose values, and CLAUDE.md's hard
  convention, change with it.
state: ready
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

## Ruling (2026-10-27)

Drop it all: "`yq` was an old dependency when we were fully bash, now we're go
and go only, so drop anything related to it … we stay standard and clean, and
do not build/maintain special stuff for jq/yq." YAML reads as `yaml.v3` reads
it, JSON as `encoding/json` does, `check` rules are plain Go, and the test
suites need no host `yq`. An ordered map stays where kasbah writes JSON whose
key order must hold (server.json, state.json, the `traefik.yml` edit).

## Work

- [x] Tests read YAML through `tools/yaml2json` (built into `dist/`, never
      released) piped to `jq`; no suite and no doc needs host `yq`
- [x] `internal/yamlx` on plain `yaml.v3`: the Python-object model, the
      goldens, `regen.sh` and the parity test deleted
- [ ] The shared tree loses its jq semantics and becomes `internal/tree`:
      JSON through `encoding/json`, Go accessors in place of
      `Alt`/`Truthy`/`ToString`/`Raw`, no jq-shaped error text; every package
      but `check` migrated
- [ ] `check` rules as plain Go queries; `internal/check/jq.go` and the
      tree's last jq helpers deleted

## References

- `internal/yamlx/`, `internal/jv/`, `internal/yamlx/testdata/regen.sh`
- `CLAUDE.md` hard conventions (YAML line), `docs/compliance.md` §rule evaluation
- `docs/phases/10-recast.md` task 10.3 (why yq-exact was chosen)
