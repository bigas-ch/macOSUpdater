# macOSUpdater

[![CI](https://github.com/bigas-ch/macOSUpdater/actions/workflows/ci.yml/badge.svg)](https://github.com/bigas-ch/macOSUpdater/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Platform: macOS](https://img.shields.io/badge/platform-macOS-lightgrey.svg)
![Shell: zsh + bash 3.2](https://img.shields.io/badge/shell-zsh%20%2B%20bash%203.2-89e051.svg)

A **security-first macOS update manager**: a zsh `fzf` TUI on top of a hardened
root **LaunchDaemon** backend. It runs privileged `softwareupdate` operations
**without keeping a sudo token in RAM** and without prompting for a password on
every run — while keeping the privileged surface minimal, UID-validated and
action-whitelisted.

User-space updates (Homebrew, Mac App Store, npm, pip, gh) run as your normal
user; only Apple's `softwareupdate` is delegated to the root daemon.

---

## Why

Most "update everything" scripts either nag for `sudo` repeatedly or cache a
privileged token. macOSUpdater instead ships a tiny root daemon that does
exactly one thing — run `softwareupdate -i -a` — and is triggered by a
user-owned file. The daemon validates *who* triggered it, accepts only a fixed
set of actions, and never evaluates the trigger content as a shell command. See
[`SECURITY.md`](SECURITY.md) for the full threat model.

## Requirements

- **macOS** (developed and tested against the macOS 26 `softwareupdate` line).
- System **zsh** (daemon) and **bash 3.2** (CLI) — both ship with macOS.
- **[`fzf`](https://github.com/junegunn/fzf)** — only for the interactive menu
  (`brew install fzf`). All subcommands work without it.
- Per-subcommand, optional: **Homebrew** (`brew`, `casks`), **[`mas`](https://github.com/mas-cli/mas)**
  (`apps`), **uv/pipx** (`pip`), **npm/pnpm** (`npm`), **GitHub CLI** (`gh`).
- For development/tests: **[`bats`](https://github.com/bats-core/bats-core)** and **shellcheck**.

## Install

```bash
git clone https://github.com/bigas-ch/macOSUpdater.git
cd macOSUpdater

# One-time, idempotent. Deploys the root LaunchDaemon (asks for sudo once) and
# creates macOSUpdater.app in /Applications (with ~/Applications fallback).
./setup_macOSUpdater_v1.0.0.sh
```

The setup copies the daemon, plist and a CLI client into
`/Library/Application Support/ch.bigas.macOSUpdater/` (all `root:wheel`), loads
the LaunchDaemon `ch.bigas.macOSUpdater`, and creates the log at
`/var/log/macOSUpdater.log`. Re-running is a safe no-op.

## Usage

```text
macOS Update Manager v1.0.0
Usage: macOSUpdater_v1.0.0.sh [argument] [--backup]

  (no argument)   Interactive fzf menu
  all             All available updates
  macos           macOS software + security updates (via the root daemon)
  brew            Homebrew: update → upgrade → autoremove → cleanup
  casks           Homebrew Casks (GUI apps)
  apps            Mac App Store (mas update)
  pip             Python tools (uv / pipx)
  npm             Global Node packages
  gh              GitHub CLI extensions
  --backup        Time Machine backup before 'all' (pre-hook)
```

```bash
./macOSUpdater_v1.0.0.sh                # interactive fzf menu
./macOSUpdater_v1.0.0.sh all            # everything
./macOSUpdater_v1.0.0.sh all --backup   # + Time Machine pre-hook
./macOSUpdater_v1.0.0.sh macos          # macOS updates (delegated to the daemon)
./macOSUpdater_v1.0.0.sh brew           # 4-step Homebrew pipeline
```

Or double-click **macOSUpdater.app** in `/Applications` to open the menu in
Terminal.

> **Quiet by default:** external tools run silently and only print on a real
> error (non-zero exit). Successful steps show `✓ Done`. This suppresses npm
> warning walls (EBADENGINE / deprecated / allow-scripts) without pattern
> filtering.

## How it works

```text
                  ┌─────────────────┐
                  │ You trigger via │
                  │ the zsh CLI     │
                  └────────┬────────┘
                           │ writes
                           ▼
            $HOME/.macOSUpdater_trigger        (action payload)
                           │ WatchPaths
                           ▼
        LaunchDaemon  ch.bigas.macOSUpdater    (root)
        /Library/LaunchDaemons/...
                           │
                  ┌────────┼─────────┐
                  ▼        ▼         ▼
               UID/     Action-   softwareupdate
               owner    whitelist   -i -a
               check
                           │
                           ▼
            $HOME/.macOSUpdater_done           (result marker)
                           │
                           ▼
                    CLI returns + run summary + notification
```

**Security layers** (full detail in [`SECURITY.md`](SECURITY.md)):

- **TOCTOU-closed trigger read** — the daemon opens the trigger with
  `O_NOFOLLOW`, `fstat`s the descriptor, and reads from the *same* fd; check and
  use hit the same inode (no symlink/inode-swap window).
- **Owner-verified constants source** — `_constants.sh` is sourced only after an
  `O_NOFOLLOW` + `fstat` owner check (== daemon EUID); the daemon defends itself
  independently of where it is deployed.
- **Action whitelist** — only `macos_sw` / `macos_sw_restart` / `all`; anything
  else exits `1`. No `eval`, no command substitution on the trigger content.
- **PATH pinning** — `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, external commands by
  absolute path (closes injection via user-writable Homebrew dirs).
- **Fixed install owner** — baked at install time, not derived from `$USER`.
- **Uninstaller allowlist** — every destructive `rm`/`rmdir` validates its target
  against empty input, path traversal and protected system paths.
- **NDJSON logging** — forensic-grade structured log at `/var/log/macOSUpdater.log`.

Watch the daemon live:

```bash
sudo tail -f /var/log/macOSUpdater.log | jq .
```

## Architecture notes

The CLI front-end and the root daemon are **versioned independently**. The
daemon runs as root, so it is touched only for functional/security changes
(action whitelist, UID validation, NDJSON schema) to keep the attack surface
minimal — the CLI can iterate freely without re-deploying the daemon. The daemon
announces its version on every wake:

```json
{"ts":"…","level":"info","event":"daemon_started","msg":"v1.0.0 daemon awakened by trigger"}
```

## Repository layout

```text
macOSUpdater/
├── macOSUpdater_v1.0.0.sh          ← main CLI (bash 3.2)
├── setup_macOSUpdater_v1.0.0.sh    ← installer (LaunchDaemon deploy + .app launcher)
├── uninstall_macOSUpdater.sh       ← uninstaller (allowlist-guarded)
├── macOSUpdater_daemon.sh          ← root LaunchDaemon source (zsh)
├── ch.bigas.macOSUpdater.plist     ← LaunchDaemon plist
├── _constants.sh                   ← single source of truth (paths, labels)
├── assets/                         ← app icon + reproducible generator
├── tests/                          ← bats suite (security, daemon, drift guards, …)
├── .githooks/pre-commit            ← local quality gate (zsh -n + ShellCheck + bats)
├── .github/workflows/ci.yml        ← macOS CI (lint + bats)
├── CHANGELOG.md                    ← Keep a Changelog
├── SECURITY.md                     ← threat model + disclosure
└── LICENSE                         ← MIT
```

## Development & tests

```bash
bats tests/                 # full suite — security, daemon, drift guards, CLI execution
git config core.hooksPath .githooks   # opt into the local pre-commit gate
```

CI runs a lint job (`zsh -n` for the zsh track, `shellcheck -S style` for the
bash CLI) plus the full bats suite on macOS. Tests are designed to run without
touching the live system (`MACUP_SKIP_DAEMON_CHECK=1` where applicable).

## Uninstall

```bash
./uninstall_macOSUpdater.sh -n      # dry-run: shows what would be removed
./uninstall_macOSUpdater.sh         # interactive, with log-backup option
```

Removes the LaunchDaemon, the support directory, the plist, the trigger/done
markers and the `.app` launcher.

## Security

Found a root-relevant issue? Please report it **privately** to
`micha.barth@bigas.ch` — see [`SECURITY.md`](SECURITY.md). Do not open a public
issue for vulnerabilities.

## License

[MIT](LICENSE) © Micha Barth `<micha.barth@bigas.ch>`

Reverse-domain `ch.bigas` is used for the plist bundle identifier.
