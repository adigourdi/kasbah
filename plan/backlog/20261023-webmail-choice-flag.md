---
description: >
  The mail stack ships one hard-wired webmail client with no way to pick
  another. Let `server init` take the client as the flag's value, as in
  `--with-mail=roundcube`, with Cypht as the default, in internal/serverinit,
  templates/mail/ and the mail registry.
state: needs-decision
priority: low
---

## Prompted by

This came up while comparing SnappyMail's replacements on 2026-10-23. Cypht
won for its combined inbox, but Roundcube is the steadier project (larger user base,
longer release record), so the user wants both on offer:
"allow people to choose the client with `--with-mail=roundcube`".

## Evidence

- `--with-mail`/`--no-mail` is a yes/no `prompt.Given` today
  (`internal/serverinit/args.go:27`, `internal/serverinit/run.go:43`). No
  init flag takes a value from a fixed set yet, so `internal/prompt` would need a
  multiple-choice question (`Bool` and the two-flag `Choice` are all it has).
- The webmail container name is load-bearing in `_mail.yml`'s backend URL
  (`docs/mail.md`, Components), so each client brings its own fragment variant
  or the fragment gets the backend as a parameter.

## To decide

1. **Flag shape.** Should bare `--with-mail` mean the default client (Cypht)? Should there
   be a `--with-mail=none` (DMS only, no webmail) value? The convention requires that an
   unset flag prompts, so with no flag init asks "mail?" and then "which client?".
   Without a TTY it must fail naming the flag.
2. **Where the choice is recorded.** Probably `<apps>/mail/kasbah.yml` (the mail
   registry), so re-runs, `server status` and `check --server` know which client is
   running. Readers already ignore unknown keys, but the registry's format is kasbah's own.
3. **Switching on an existing server.** A re-run of init with a different value:
   swap the client, or refuse and name the step that would do it.

Settled: the manifest has no per-domain webmail key. Cypht needs none (every
address signs in against the one DMS), so `snappymail_domain:` was removed from
schema 1. A client that needs per-domain config brings its own mechanism.

## Work

- [ ] multiple-choice flag and prompt in `internal/prompt`, wired into `server init`
- [ ] one compose service per client in `templates/mail/compose.yml` (or a
      template per client), rendered by the choice
- [ ] the choice recorded in the mail registry and shown by `server status`
- [ ] rig: init with each client serves `webmail.<domain>`
- [ ] docs: `cli.md`, `mail.md`, `server-setup.md`, `files.md`

## References

- `internal/prompt/prompt.go:137`, `internal/serverinit/run.go:43`
- `docs/cli.md:28-36` (the `--with-mail` flags)
- `docs/mail.md` → Webmail (the Cypht service this flag would choose against)
