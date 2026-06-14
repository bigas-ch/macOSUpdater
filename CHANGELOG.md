# Changelog

All notable changes to **macOSUpdater** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_Nothing pending._

## [1.0.0] - 2026-06-14

First public release. Renamed from the internal `OSXforgedUpdater` line; the
zsh production track is the supported tool, the Swift track is frozen and not
part of this release.

### Added
- App icon (`assets/macosupdater.icns`) plus reproducible vector source and
  generator (`macosupdater.svg`, `macosupdater_icon_gen.py`).
- App launcher (`macOSUpdater.app`, `/Applications` with `~/Applications`
  fallback) created by `setup` via `osacompile`; the CLI is co-deployed to
  Application Support and runs there as a client (no drift check / re-deploy).
  The uninstaller removes the launcher and the co-deployed CLI.
- Hybrid lint gate in `.githooks/pre-commit` and CI: `zsh -n` for the zsh track
  (daemon, setup, uninstall, helper — ShellCheck cannot parse zsh, SC1071) and
  `shellcheck -S style` for the bash CLI and the sourced `_constants.sh`.
- Dedicated `--help` / `-h` handling (usage + exit 0) instead of the
  "unknown argument" path.
- `LICENSE` (MIT), `CHANGELOG.md`, `SECURITY.md`.

### Security
- **TOCTOU-closed trigger read**: the root daemon opens the user trigger via
  `sysopen O_NOFOLLOW`, `fstat`s the descriptor (owner of the opened inode) and
  reads from the same fd — check and use hit the same inode, no symlink/inode
  swap window.
- **Owner-verified constants source (F2)**: the daemon sources `_constants.sh`
  only after an analogous `O_NOFOLLOW` + `fstat` owner check (== daemon EUID,
  i.e. root in production); the verified content is sourced from the same fd.
  The daemon now defends itself independently of the deploy location.
- **Uninstaller allowlist guard (F1)**: every destructive `rm`/`rmdir` validates
  its target against empty input, path traversal and protected system/top-level
  paths before any `sudo rm` runs.
- Action whitelist on the trigger payload (`macos_sw` / `macos_sw_restart` /
  `all`, everything else `exit 1`) — no `eval`, no command substitution as root.
- PATH pinning (`/usr/bin:/bin:/usr/sbin:/sbin`) against PATH injection via
  user-writable Homebrew dirs; fixed install owner instead of `$USER`;
  `sed`-injection guard on the owner name; root-owned deploy guards.

### Changed
- `run_mas` trusts the `mas` exit code and forces `LANG=C`/`LC_ALL=C`
  (no locale-dependent silent false-pass).
- Touch-ID setup appends to `/etc/pam.d/sudo_local` (`tee -a`) instead of
  overwriting it (F3) — foreign PAM directives are preserved.
- README test counts and file tree made honest.

### Removed
- `macos_sec` / `--background-critical` (deprecated on macOS 26; security and
  config-data updates ride along `softwareupdate -i -a`).

## [0.8.2] - earlier
- zsh: removed `macos_sec`; daemon at v0.7.2.

## [0.8.1] - earlier
- zsh: pipe-cleanup notice fix.

## [0.8.0] - earlier
- zsh: five additional subcommands (casks, apps, pip, npm, gh) and `--backup`.

## [0.7.0] - [0.7.3] - earlier
- NDJSON structured logging, log rotation, trigger path under `$HOME`,
  pipe-cleanup bugfix.

## [0.5.0] - [0.6.1] - earlier
- Early LaunchDaemon-based releases (legacy `com.micha.updater`).
