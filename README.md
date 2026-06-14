# macOSUpdater

macOS Update Manager mit zwei Tracks. Sicherheits-First-Architektur ohne sudo-Token im RAM.

## Zwei Tracks parallel

| Track | Version | Pfad | Status |
|---|---|---|---|
| **zsh** (production) | `v1.0.0` | `./macOSUpdater_v1.0.0.sh` | Live-deployed |
| **Swift** (Lern-Projekt) | `v1.0.3` | `swift/` (eingefroren) | Eigener Binary-Name |

Beide nutzen denselben LaunchDaemon (`ch.bigas.macOSUpdater`) als Backend für privilegierte Operationen (`softwareupdate`). User-Operations (brew, mas, npm, etc.) laufen im User-Kontext.

## Versionierung — unabhängige Tracks

CLI-Frontends und LaunchDaemon werden **unabhängig versioniert** (siehe Master-Index E-024). Auseinanderlaufende Nummern sind kein Drift, sondern gewollt.

| Komponente | Aktuelle Version | Wann hochziehen |
|---|---|---|
| zsh-CLI (`macOSUpdater_vX.Y.Z.sh`) | v1.0.0 | Subcommand-Erweiterungen, UX-Polishing, Pipe-/Stream-Fixes |
| Swift-CLI (eingefroren, eigener Binary-Name) | v1.0.3 | Eigene Phasen-Roadmap (α…θ → 1.0 → …) |
| LaunchDaemon (`macOSUpdater_daemon.sh`) | v1.0.0 | Nur bei funktionalen Änderungen (Action-Whitelist, UID-Validation, NDJSON-Schema, Sicherheits-Layer) |

**Rationale:** Daemon läuft als root — minimale Edits = minimales Attack-Surface. CLI kann beliebig oft hochgezogen werden ohne Daemon-Touch.

Im Live-Log sichtbar via `daemon_started`-Event:
```json
{"ts":"…","level":"info","event":"daemon_started","msg":"v1.0.0 daemon awakened by trigger"}
```

## Quick-Start

### zsh-Track (Production)
> **Output v1.0.0:** Externe Tools laufen still (`run_quiet`) — Tool-Ausgabe erscheint **nur bei echtem Fehler** (Exit≠0). Erfolgreiche Schritte zeigen nur `✓ Erledigt`. Erstickt npm-Warn-Walls (EBADENGINE/deprecated/allow-scripts) ohne Pattern-Filter.

```bash
cd <projekt>/code

./setup_macOSUpdater_v1.0.0.sh        # einmalig (idempotent); legt auch macOSUpdater.app an

# Doppelklick auf macOSUpdater.app (Applications) öffnet das Menü im Terminal —
# oder direkt per CLI:
./macOSUpdater_v1.0.0.sh              # interaktives fzf-Menü
./macOSUpdater_v1.0.0.sh all          # alle verfügbaren Updates
./macOSUpdater_v1.0.0.sh all --backup # + Time Machine Pre-Hook

# Einzel-Subcommands
./macOSUpdater_v1.0.0.sh macos        # macOS Software-Updates (inkl. Security via -i -a)
./macOSUpdater_v1.0.0.sh brew         # 4-step Homebrew Pipeline
./macOSUpdater_v1.0.0.sh casks        # GUI-Apps via Cask
./macOSUpdater_v1.0.0.sh apps         # Mac App Store (mas)
./macOSUpdater_v1.0.0.sh pip          # uv / pipx
./macOSUpdater_v1.0.0.sh npm          # npm / pnpm global
./macOSUpdater_v1.0.0.sh gh           # GitHub CLI Extensions

# Test-Suite
bats tests/                           # alle Tests grün

# Deinstallation
./uninstall_macOSUpdater.sh -n        # Dry-Run
./uninstall_macOSUpdater.sh           # Interaktiv mit Log-Backup-Option
```

### Swift-Track (Lern-Projekt, eingefroren)
```bash
# Eigener Build (siehe swift/README.md)
cd swift
./build.sh --bundle                   # Release + Codesign + .app-Bundle
# swift-testing 6.3+ braucht lib_TestingInterop aus Voll-Xcode (CLT-only fehlt -L/-rpath):
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test   # Test-Suite (Voll-Xcode)
# Xcode-freie Alternative (gleiche Logik): self-test-Subcommand
```

## Architektur

```
                  ┌─────────────────┐
                  │ User triggert   │
                  │ via zsh-CLI     │
                  └────────┬────────┘
                           │ schreibt
                           ▼
            $HOME/.macOSUpdater_trigger
                           │ WatchPaths
                           ▼
        LaunchDaemon ch.bigas.macOSUpdater
        (root, /Library/LaunchDaemons/...)
                           │
                  ┌────────┼────────┐
                  ▼        ▼        ▼
              UID-     Action-   softwareupdate
              Validation Whitelist  -i -a
                           │
                           ▼
            $HOME/.macOSUpdater_done
                           │
                           ▼
                    User-Tool returnt
                    + Run-Summary
                    + Notification
```

**Sicherheits-Layer:**
- UID-Validation im Daemon (verhindert Privilege-Escalation durch andere User)
- Action-Whitelist mit explizitem `exit 1` (verhindert Shell-Injection)
- Trigger in `$HOME` (FS-Permission als 2. Schicht)
- Defense-in-Depth-Guard beim Constants-Source (Symlink-/Existenz-Reject)
- NDJSON-Logging in `/var/log/macOSUpdater.log` (forensik-tauglich)

## Verzeichnis-Struktur

```
macOSUpdater/
├── README.md                              ← diese Datei
├── _constants.sh                          ← Single Source of Truth (Variante B)
├── macOSUpdater_v1.0.0.sh                 ← Hauptscript (bash 3.2 CLI)
├── setup_macOSUpdater_v1.0.0.sh           ← Setup mit Migration
├── uninstall_macOSUpdater.sh              ← Uninstaller (kein Versionssuffix)
├── macOSUpdater_daemon.sh                 ← LaunchDaemon-Source (zsh, root)
├── ch.bigas.macOSUpdater.plist            ← Plist-Source
├── assets/                                ← App-Icon (für den .app-Launcher)
│   ├── macosupdater.icns                  ← Multi-Resolution-Icon (16–1024 px)
│   ├── macosupdater.svg                   ← Vektor-Quelle (= Generator-Ausgabe)
│   └── macosupdater_icon_gen.py           ← reproduzierbarer Icon-Generator + Build-Doku
├── tests/
│   ├── cli_execution.bats                 ← CLI-Subprozess-Execution (run_quiet/run_mas/trigger_daemon)
│   ├── constants.bats                     ← Constants-Unit-Tests
│   ├── constants_drift.bats               ← Constants ↔ plist Drift-Guard
│   ├── daemon.bats                        ← Daemon-Tests (NDJSON, Owner-Validation, TOCTOU-Closure)
│   ├── hauptscript.bats                   ← Hauptscript-Tests (v0.7.x + v0.8 + Pipe-Cleanup)
│   ├── hauptscript_md5.bats               ← MD5-Drift-Tests
│   ├── installer_drift.bats               ← Setup ↔ Uninstaller Drift-Check
│   ├── migration.bats                     ← Legacy-Migration (Swift-Teardown, Daemon-Rename)
│   ├── security.bats                      ← Prio-0 LPE-Härtungs-Tests
│   └── setup_deploy.bats                  ← Setup/Deploy (root-owned-Chain, Pre-chown-Guard)
├── .githooks/pre-commit                   ← lokales Quality-Gate (zsh -n + ShellCheck + bats)
├── .github/workflows/ci.yml               ← macOS-CI (Lint-Job + bats-Suite)
├── .gitignore
├── LICENSE                                ← MIT
├── CHANGELOG.md                           ← Versionshistorie (Keep a Changelog)
├── SECURITY.md                            ← Threat-Model + Disclosure
├── swift/                                 ← eingefrorener Swift-Lern-Track (nicht Teil des v1.0.0-Release)
├── Verlauf/                               ← zsh-Versions-Snapshots v0.1..v0.8.2
└── .git/                                  ← Lokales Git-Repo
```

## Lessons learned (universelle Patterns)

In `~/.claude/projects/.../memory/`:
- `feedback_bash_pipe_cleanup.md` — `cmd1 | cmd2 &` $! Subshell-Pattern
- `feedback_apple_nsassertion_in_cli.md` — Bundle-Pre-Check vor Apple-Frameworks
- `feedback_uninstaller_pflege.md` — Uninstaller-Co-Pflege bei jeder Erweiterung

## Tag-Stand

```
v1.0.0                      ← zsh: macOSUpdater-Rename + Constants-SoT + Defense-in-Depth
v0.8.2                      ← zsh: macos_sec entfernt (macOS 26 deprecated --background-critical); Daemon v0.7.2
v0.8.1                      ← zsh Pipe-Cleanup-Notice-Fix
v0.8.0                      ← zsh +5 Subcommands
v0.7.3, v0.7.2, v0.7.1, v0.7.0
v0.6.1, v0.6.0
v0.5.0
```

## Identity

**Maintainer**: Micha Barth `<micha.barth@bigas.ch>`
**Domain**: ch.bigas (Reverse-Domain für Plist-Bundle-ID)
