---
description: A bug report on GitHub arrives with no version, command or log
cause: the repository has no issue templates
where: .github/ISSUE_TEMPLATE/
state: blocked
priority: normal
after:
  - "[[info-and-help-commands]] — the template asks for `kasbah info`"
  - "[[debug-trace-and-log]] — the template asks for the failure's log"
---

## Prompted by

2026-11-13, the repository just public: a report a maintainer can act on
needs the build, the command and what kasbah ran.

## Work

- [ ] Bug template: `kasbah info` output, the command run, the debug log
      (redacted by kasbah), what was expected
- [ ] Feature template, short; disable blank issues or point them at it
- [ ] CONTRIBUTING.md says where reports go and what to attach
