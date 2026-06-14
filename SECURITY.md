# Security Policy

macOSUpdater ships a **root LaunchDaemon** that runs `softwareupdate` on behalf
of a user-owned trigger file. Security is the primary design goal: a bug in the
daemon potentially runs as root. This document describes what is defended, what
is explicitly out of scope, and how to report a vulnerability.

## Supported versions

| Version | Supported |
|---------|-----------|
| 1.0.0   | ✅        |
| < 1.0.0 | ❌ (pre-release snapshots) |

## Reporting a vulnerability

Please report security issues **privately**, not via public issues:

- Email: `micha.barth@bigas.ch`

Include reproduction steps and the affected file/line. You will get an
acknowledgement; fixes for confirmed root-relevant issues are prioritised.

## Threat model

The dangerous primitive is the root daemon consuming a user-controlled trigger.
The boundary defended is: **an unprivileged or non-owner local user must not be
able to escalate to root** through the daemon, its installer, or its uninstaller.

### In scope (actively defended)

- **TOCTOU on the trigger read.** The daemon opens the trigger with
  `sysopen O_NOFOLLOW`, `fstat`s the file descriptor and reads from the *same*
  fd. Check (owner of the opened inode == expected install owner) and use hit
  the same inode — no symlink/inode-swap window. Symlink, missing file,
  owner mismatch and unresolvable owner each abort with a logged event.
- **Owner-verified constants source.** The daemon sources `_constants.sh` only
  after the same `O_NOFOLLOW` + `fstat` closure with owner == daemon EUID
  (root in production); the verified bytes are sourced from the fd itself. The
  daemon defends itself independently of where it is deployed.
- **Action whitelist.** Only `macos_sw`, `macos_sw_restart` and `all` are
  dispatched; any other payload logs `unknown_action` and exits. No `eval`,
  no command substitution on the trigger content — no shell injection as root.
- **PATH pinning.** The daemon forces `PATH=/usr/bin:/bin:/usr/sbin:/sbin`,
  closing PATH injection via user-writable `/opt/homebrew/bin` etc. All external
  commands are called by absolute path.
- **Fixed install owner.** The expected owner is baked at install time, not
  derived from `$USER`; another logged-in user cannot redirect the trigger.
- **Installer hardening.** The owner name is validated against
  `^[A-Za-z0-9_.-]+$` before being injected into the daemon and plist
  (sed-injection guard); symlink / root-owned pre-checks guard every privileged
  write.
- **Uninstaller allowlist.** Every destructive `rm`/`rmdir` validates its target
  (rejects empty input, path traversal, and protected system/top-level paths)
  before any `sudo rm` runs — a poisoned `_constants.sh` cannot steer a
  `sudo rm -rf` onto system paths.
- **Injection-safe logging.** NDJSON output escapes free-text `msg`, keeps `uid`
  numeric, and emits `event`/`action` as literal/whitelisted values.

### Out of scope (by design)

- **An attacker who already has write access to the user's tool files.**
  Replacing the CLI/daemon source itself is the same trust boundary; the
  uninstaller allowlist mitigates the worst outcome but this is not treated as a
  crossed boundary.
- **Compromise of root itself.** If root is already controlled, the daemon
  offers no additional protection — that is outside the model.

## Deliberate trade-offs

1. **The log is world-readable (`/var/log/macOSUpdater.log`, mode 644).** It
   contains the triggering uid and an action history, but no secrets. Readable
   logging is intentional (forensics by design).
