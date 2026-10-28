---
description: >
  Every deploy needs HEAD tagged first, which makes the fix-and-ship loop two
  commands and a tag name to invent. When HEAD carries no `v*` tag, have
  `deploy` find the latest reachable one, ask major/minor/patch (`--bump=`),
  tag, push the tag and continue, in internal/deploy and the version resolver
  build-push shares.
state: ready
priority: normal
---

## Prompted by

Design review, 2026-10-28, user: "maybe we can make deploy find latest tag,
and ask if the release is major/minor/patch or something, and it increases and
tags and pushes before proceeding?"

build-push and deploy already refuse a dirty tree unless `--dirty`
(`build-deploy.md` → Versioning contract), so a tag cut from HEAD here is
clean by construction.

## Work

- [ ] prompt with the three candidates computed from the latest tag; `--bump=major|minor|patch` answers it headless; no tag at all → ask for the first version
- [ ] tag, `git push origin v<ver>` (warn and continue with no origin, as build-push does), then proceed as a clean deploy
- [ ] build-push gets the same path, since it is the command that needs the tag first
