# Security policy

## Supported versions

`found-issues` follows [semantic versioning](https://semver.org/). Security
fixes are issued for the latest `1.x` minor release. Older `0.1.x` versions
were private-development releases and are not supported.

| Version | Supported  |
|---------|------------|
| 1.x     | ✅ Yes     |
| 0.1.x   | ❌ No      |

## Reporting a vulnerability

If you discover a security vulnerability, **do not open a public GitHub
issue**. Instead, use one of these private channels:

1. **Preferred — GitHub Security Advisory**: open a [private security
   advisory](https://github.com/AltDoug/found-issues/security/advisories/new)
   on this repo. Anthropic's recommended path; gives both sides an audit
   trail.
2. **Email**: contact via the public email address on the
   [@AltDoug](https://github.com/AltDoug) GitHub profile, with the subject
   prefix `[found-issues security]`.

Please include:

- A clear description of the vulnerability and its impact
- Reproduction steps (a minimal `docs/found-issues.md` fixture or shell
  command sequence is ideal)
- The plugin version (`found-issues --version`) and how you installed it
- Whether you've shared the issue with anyone else

## What counts as a security issue

Things that warrant private reporting:

- Code execution from a maliciously crafted `docs/found-issues.md` entry,
  shell command in `bin/found-issues`, or hook-emitted JSON
- Privilege escalation or sandbox escape via the Claude Code hook
  interface
- Disclosure of secrets / credentials / personal data through plugin
  state files or hook output
- Path traversal that lets an entry write outside its intended file

## What does not count

These are normal bugs — please open a regular GitHub issue:

- A slash command refuses a valid input
- The format-enforcer hook is too strict / too lenient
- Statusline rendering is wrong on a particular shell
- Cross-platform issues (macOS vs Linux) that don't involve secrets

## Response time

I aim to acknowledge security reports within 72 hours and ship a fix or
mitigation within 7 days for high-severity issues. This is a personal-time
project — please be patient if the timeline slips for lower-severity
issues.

## Disclosure

After a fix is released, I'll credit reporters in the CHANGELOG entry
unless they request anonymity.
