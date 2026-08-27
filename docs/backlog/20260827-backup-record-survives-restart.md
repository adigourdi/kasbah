# The backup record forgets the last run whenever its container restarts

**Size:** S

## Purpose

Found on the rig during 8.5 (2026-08-27), while ordering the integration
suite's states — it cost a **false failure** before it was understood, which is
how it got noticed at all.

`templates/backup/backup.sh` holds the last run's facts in **shell variables**,
so they die with the process. When the scheduler container restarts — a reboot,
a `docker compose up`, a crash, a `backup.sh` re-ship — the next record it
writes says `sleeping` with `last_run_started=0`. A stack that has backed up
faithfully for months then reads as one that **has never fired**, until its next
run completes.

The readers built in 8.5 report that honestly rather than guessing, so the
consequence is a **warning for up to a day after every reboot** — from both
`kasbah server status` and `check --server`'s B01. That is correct behaviour
given what the record says, and the wrong thing to fix in the reader: the reader
cannot invent a fact the writer discarded.

Out of scope for 8.5 by construction — that task was chartered as *readers
only*, and the writer was explicitly off-limits.

## Evidence

- `templates/backup/backup.sh` — `LAST_RUN_*` are shell variables, not read back
  from `<apps>/.kasbah/backup/state/status` at start-up.
- Observed on the rig: a stop/start before the no-password window made the suite
  read `never` for a stack that had just run, and the suite now asserts the
  behaviour where it happens rather than reasoning about it.
- Documented as expected in `docs/backup.md` → The schedule, so the warning is
  not mistaken for a defect in the meantime.

## Options

- **Read the existing record at start-up** and carry `last_run_*` forward before
  writing the first `sleeping` state. Smallest change, fixes it completely, and
  the file is already parsed by `lib/backup_record.sh` on the workstation side —
  though the runner is POSIX `sh` and would need its own reader.
- **Write the record incrementally** — update `last_run_*` at the end of each
  run and never rewrite those keys from memory. Arguably the right shape: the
  record becomes the state rather than a dump of it.
- **Leave it**, since the window closes on its own within a day and the
  behaviour is now documented. Costs an operator one confusing warning after
  every reboot, on the feature where a spurious warning is most likely to train
  someone to ignore a real one.

## Size

S — but it touches the one script in the repo that is POSIX `sh` rather than
bash, and any change to the writer needs 8.5's eight reader states re-driven,
since they are all keyed off what it writes.
