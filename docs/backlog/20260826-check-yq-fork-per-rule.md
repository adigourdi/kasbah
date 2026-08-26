# `kasbah check` forks a Python `yq` per rule — the unit suite's dominant cost

**Size:** M

## Purpose

Surfaced by 8.4's review (2026-08-26), while judging whether `check --fix` had made
`tests/check_test.sh` slow. It had not, and the measurement is the point: the new
fifteen cases run at **exactly** the suite's pre-existing per-case rate, so the cost
is not in that change and cannot be fixed there.

The reviewer's words, worth keeping verbatim because they name where the time
actually goes:

> That is 15 cases at ~10.6s, which is *exactly* the existing suite's per-case rate
> (7m26 / 42 cases ≈ 10.6s). The cost is the pre-existing design — a full
> `init-project` plus one or more full `kasbah check` CLI runs per case, with every
> rule forking a Python `yq` (~87ms each; a plain check on a one-service project
> forks 41). … If you want the time back, it is not in this diff: it is in
> collapsing the per-rule `yq` forks (`_cf_yq` immediately followed by `_cf_has` on
> the same path in C01, R01/R02, C02 — two forks answering one question) and in the
> same pattern in `lib/check.sh`.

This matters beyond one suite: `./test.sh` must pass before every commit, and
`check_test.sh` is now its longest single suite by a wide margin.

## Evidence

- `tests/check_test.sh`: **7m26s** before 8.4, **10m02s** after (measured on this
  workstation, 2026-08-26). The 8.4 block alone is 2m40s standalone.
- A plain `kasbah check` on a **one-service** project forks `yq` **41 times**, at
  ~87 ms each — roughly 3.5 s of process startup for a linter that reads two files.
- `--fix` adds only ~19 forks / ~1.6 s on that project, half of it the idempotency
  re-plan, which is load-bearing and was proved to fire.
- The doubled-fork pattern: `_cf_yq` immediately followed by `_cf_has` on the same
  path — two forks answering one question — in C01, R01/R02 and C02, and the same
  shape throughout `lib/check.sh`.

## Options

- **Read the document once into a shell-side structure**, and answer every rule from
  it. Biggest win; largest change; risks re-introducing exactly the "two readers of
  one question" defect this project keeps finding, unless the single read stays the
  only reader.
- **Collapse the doubled forks only** (`_cf_yq` + `_cf_has` → one call returning
  both presence and value). Small, safe, mechanical; recovers maybe a third.
- **Batch per rule-family** — one `yq` expression answering all of C01/C02/R01/R02
  per service. Middle ground.
- **Leave it.** The tool is fast enough for an operator running it by hand once; it
  is the *suite* that pays, and the suite is not the product.

Not attempted in Phase 8 deliberately: it touches every rule in a 1200-line linter
that four commits in that phase already depend on, and 8.4's own reviewer
recommended against holding that change for it.
