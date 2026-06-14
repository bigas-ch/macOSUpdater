#!/usr/bin/env bats
# ══════════════════════════════════════════════════════════════════
#  cli_execution.bats — Subprozess-Execution-Tests für macOSUpdater_v1.0.0.sh
#
#  Modell: der echte CLI wird via `run "$CLI" <subkommando>` mit
#  MACUP_*_OVERRIDE-Seams + PATH-Stubs getrieben (analog daemon.bats).
#  KEINE statischen grep-Asserts — echtes Laufzeitverhalten.
#
#  Sicherheit (M-5): jeder Test seedet softwareupdate- + osascript-Stubs,
#  damit nie ein echter Update-Scan oder eine echte Notification feuert.
#
#  Wichtig: die CLI exit-codet im Non-Interaktiv-Modus IMMER 0 (Z.535-537).
#  Step-Fehler erscheinen nur in der Summary → Asserts auf die run_step-
#  Glyphen "✓ Erledigt: <Label>" / "✗ Fehler: <Label>".
# ══════════════════════════════════════════════════════════════════

setup() {
  CLI=$(ls "${BATS_TEST_DIRNAME}/.."/macOSUpdater_v*.sh 2>/dev/null | head -1)
  [[ -x "$CLI" ]]
  WORK=$(mktemp -d /tmp/.macup_cliexec.XXXXXX)
  STUB="$WORK/bin"; mkdir -p "$STUB"
  TRIG="$WORK/trigger"; DONE="$WORK/done"; NOLOG="$WORK/nolog"   # NOLOG absent → else-Branch (kein tail)
  FAKE_PID=""
  # Sicherheits-Stubs — IMMER vorhanden:
  _stub softwareupdate 'exit 0'   # `softwareupdate -l` → leer → check_reboot meldet "kein Neustart"
  _stub osascript      'exit 0'   # notify_user → keine echte Notification
}

teardown() {
  [[ -n "$FAKE_PID" ]] && kill "$FAKE_PID" 2>/dev/null || true
  rm -rf "$WORK" 2>/dev/null || true
}

# _stub <name> <zeile...> — legt ein ausführbares Stub-Binary in $STUB an
_stub() {
  local name="$1"; shift
  { printf '#!/bin/bash\n'; printf '%s\n' "$@"; } > "$STUB/$name"
  chmod +x "$STUB/$name"
}

# run_cli <arg...> — treibt den echten CLI mit Seam-Overrides + Stub-PATH.
# PATH enthält System-Dirs (für echo/grep/cat/...) OHNE /opt/homebrew bzw.
# /usr/local → brew/mas/npm/uv/pipx/gh sind absent, ausser explizit gestubt.
run_cli() {
  PATH="$STUB:/usr/bin:/bin:/usr/sbin:/sbin" \
  MACUP_TRIGGER_OVERRIDE="$TRIG" \
  MACUP_DONE_OVERRIDE="$DONE" \
  MACUP_LOG_OVERRIDE="$NOLOG" \
  MACUP_SKIP_DAEMON_CHECK=1 \
  run "$CLI" "$@"
}

# make_fake_daemon <marker-content> — schreibt $DONE mit dem gegebenen Inhalt,
# sobald $TRIG erscheint. Simuliert den root-Daemon, der den DONE-Marker mit dem
# Action-rc befüllt (0=ok, !=0=Update-Fehler, "reboot"=Reboot-Sentinel).
make_fake_daemon() {
  local content="$1"
  ( while [[ ! -f "$TRIG" ]]; do sleep 0.05; done; printf '%s' "$content" > "$DONE" ) &
  FAKE_PID=$!
}

@test "X-SMOKE: run_cli treibt den CLI hermetisch (kein Reboot, exit 0)" {
  make_fake_daemon "0"
  run_cli macos
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | grep -cF 'macOS Update Manager')" -ge 1 ]
  [ "$(printf '%s' "$output" | grep -cF 'Kein Neustart erforderlich')" -ge 1 ]
}

# ── Task 4: run_quiet rc-Propagation ─────────────────────────────────────────
# Isolation gegen Live-Deploy: run_cli setzt MACUP_SKIP_DAEMON_CHECK=1 → der
# CLI-Start-Drift-Check + run_setup werden übersprungen (kein sudo/launchctl).

@test "X-QUIET-OK: run_quiet reicht rc 0 durch → npm-Step erfolgreich" {
  _stub npm 'echo "changed 0 packages"; exit 0'
  run_cli npm
  [ "$(printf '%s' "$output" | grep -cF '✓ Erledigt: [Node]')" -ge 1 ]
  [ "$(printf '%s' "$output" | grep -cF '✗ Fehler: [Node]')" -eq 0 ]
}

@test "X-QUIET-FAIL: run_quiet reicht rc != 0 durch + zeigt Fehler-Output nur bei Fehler" {
  _stub npm 'echo "npm ERR! boom-explode"; exit 3'
  run_cli npm
  [ "$(printf '%s' "$output" | grep -cF '✗ Fehler: [Node]')" -ge 1 ]
  [ "$(printf '%s' "$output" | grep -cF 'boom-explode')" -ge 1 ]
}

@test "X-QUIET-SILENT: run_quiet schluckt Output bei Erfolg" {
  _stub npm 'echo "geheimes-geschwaetz-xyz"; exit 0'
  run_cli npm
  [[ "$output" != *"geheimes-geschwaetz-xyz"* ]]
}

# ── Task 5: run_mas rc-Propagation + Fehler-Klassifikation ───────────────────

@test "X-MAS-OK: mas exit 0 + kein Fehler-String → App-Store-Step erfolgreich" {
  _stub mas 'echo "Everything is up-to-date."; exit 0'
  run_cli apps
  [ "$(printf '%s' "$output" | grep -cF '✓ Erledigt: [App Store]')" -ge 1 ]
  [ "$(printf '%s' "$output" | grep -cF '✗ Fehler: [App Store]')" -eq 0 ]
}

@test "X-MAS-FAIL: generischer mas-Fehler → 3 Versuche → rc 1 → Step fehlgeschlagen" {
  _stub mas 'echo "fatal error: disk full"; exit 1'
  run_cli apps
  [ "$(printf '%s' "$output" | grep -cF '✗ Fehler: [App Store]')" -ge 1 ]
  [ "$(printf '%s' "$output" | grep -cF 'nach 3 Versuchen fehlgeschlagen')" -ge 1 ]
}

@test "X-MAS-SUDO-GUARD: mas läuft-als-root wird erkannt (Self-Healing-Branch, kein Hang)" {
  _stub mas \
    'f="'"$WORK"'/mas_calls"; n=$(cat "$f" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$f"' \
    'if [ "$n" -eq 1 ]; then echo "Error: sudo uid 0 not allowed"; exit 1; fi' \
    'echo "Everything is up-to-date."; exit 0'
  run_cli apps
  [[ "$output" == *"✓ Erledigt: [App Store]"* ]]
}

@test "X-MAS-EXIT0-NOISE: mas exit 0 trotz 'error' im Output → Erfolg (Exit-Code ist Wahrheit)" {
  # Prio 5: dem mas-Exit-Code vertrauen statt lokalisierte Fehler-Strings zu
  # greppen. exit 0 mit harmlosem "0 errors" im Output muss Erfolg sein, nicht
  # ein false-fail durch das alte `! grep error`-Gate.
  _stub mas 'echo "Downloaded 0 updates, 0 errors."; exit 0'
  run_cli apps
  [ "$(printf '%s' "$output" | grep -cF '✓ Erledigt: [App Store]')" -ge 1 ]
  [ "$(printf '%s' "$output" | grep -cF '✗ Fehler: [App Store]')" -eq 0 ]
}

@test "X-MAS-LANGC: mas wird mit LANG=C/LC_ALL=C aufgerufen (locale-stabile Strings)" {
  # Prio 5: ohne LANG=C würde auf einer deutschen Maschine ein echter Fehler
  # ("Fehler" statt "error") dem englischen Routing entgehen → silent failure.
  _stub mas 'echo "$LANG|$LC_ALL" > "'"$WORK"'/mas_env"; exit 0'
  run_cli apps
  [ "$(cat "$WORK/mas_env")" = "C|C" ]
}

# ── Task 6: trigger_daemon Verhaltenstests (schliesst B4) ─────────────────────

@test "X-TD-OK: DONE-Marker '0' → macOS-Step erfolgreich" {
  make_fake_daemon "0"
  run_cli macos
  [ "$(printf '%s' "$output" | grep -cF '✓ Erledigt: [macOS]')" -ge 1 ]
  [ "$(printf '%s' "$output" | grep -cF '✗ Fehler: [macOS]')" -eq 0 ]
}

@test "X-TD-FAIL: DONE-Marker '1' (Update-Fehler) → macOS-Step fehlgeschlagen" {
  make_fake_daemon "1"
  run_cli macos
  [[ "$output" == *"✗ Fehler: [macOS]"* ]]
}

@test "X-TD-REBOOT: DONE-Marker 'reboot' (Sentinel) → macOS-Step erfolgreich" {
  make_fake_daemon "reboot"
  run_cli macos
  [[ "$output" == *"✓ Erledigt: [macOS]"* ]]
}

@test "X-TD-EMPTY: leerer DONE-Marker (Legacy-touch) → Erfolg (backward-kompat)" {
  make_fake_daemon ""
  run_cli macos
  [[ "$output" == *"✓ Erledigt: [macOS]"* ]]
}

@test "X-TD-TIMEOUT: DONE-Marker bleibt absent → Timeout → macOS-Step fehlgeschlagen" {
  # KEIN Fake-Daemon → Marker erscheint nie. Timeout-Seam auf 2s statt 900s.
  # Inline-Invocation (nicht run_cli) → MACUP_SKIP_DAEMON_CHECK=1 MUSS explizit gesetzt sein.
  PATH="$STUB:/usr/bin:/bin:/usr/sbin:/sbin" \
  MACUP_TRIGGER_OVERRIDE="$TRIG" \
  MACUP_DONE_OVERRIDE="$DONE" \
  MACUP_LOG_OVERRIDE="$NOLOG" \
  MACUP_SKIP_DAEMON_CHECK=1 \
  MACUP_TRIGGER_TIMEOUT_OVERRIDE=2 \
  run "$CLI" macos
  [[ "$output" == *"✗ Fehler: [macOS]"* ]]
}

# ── Task 7: all --backup No-Op-Regression ────────────────────────────────────

@test "X-BACKUP-ON: 'all --backup' ruft run_backup VOR dem macOS-Step (No-Op-Regression)" {
  _stub tmutil 'touch "'"$WORK"'/backup_ran"; exit 0'
  _stub mas    'echo "up-to-date"; exit 0'
  make_fake_daemon "0"
  run_cli all --backup
  [ -f "$WORK/backup_ran" ]
  [ "$(printf '%s' "$output" | grep -cF '✓ Erledigt: [TimeMachine]')" -ge 1 ]
  local b m
  b=$(printf '%s\n' "$output" | grep -n "TimeMachine] Backup vor Updates" | head -1 | cut -d: -f1)
  m=$(printf '%s\n' "$output" | grep -n "macOS]       Software- + Sicherheitsupdates" | head -1 | cut -d: -f1)
  [ -n "$b" ] && [ -n "$m" ] && (( b < m ))
}

@test "X-BACKUP-OFF: 'all' ohne --backup ruft run_backup NICHT (Gegenprobe)" {
  _stub tmutil 'touch "'"$WORK"'/backup_ran"; exit 0'
  _stub mas    'echo "up-to-date"; exit 0'
  make_fake_daemon "0"
  run_cli all
  [ ! -f "$WORK/backup_ran" ]
  [[ "$output" != *"✓ Erledigt: [TimeMachine]"* ]]
}

# ── Task 8: $ARG-no-eval + Case-Exhaustivität ────────────────────────────────

@test "X-NOEVAL: CLI übergibt User-Input nie an eval (statischer Guard)" {
  ! grep -nE '\beval\b' "$CLI"
}

@test "X-ARG-REJECT: unbekanntes Argument wird abgelehnt (exit 1, kein Dispatch)" {
  run_cli 'all;rm -rf /'
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | grep -cF 'Unbekanntes Argument')" -ge 1 ]
  [ "$(printf '%s' "$output" | grep -cF '✓ Erledigt:')" -eq 0 ]
}

@test "X-CASE-EXHAUSTIV: jeder VALID_ARGS-Eintrag hat einen Dispatch-case-Arm" {
  local valids; valids=$(grep -oE 'VALID_ARGS=\([^)]*\)' "$CLI" | tr -d '()' | sed 's/VALID_ARGS=//')
  [ -n "$valids" ] || { echo "VALID_ARGS nicht gefunden — Test-Setup fehlgeschlagen"; return 1; }
  local a
  for a in $valids; do
    awk '/^if \[\[ -n "\$ARG" \]\]; then/,/^  check_reboot/' "$CLI" | grep -qE "^[[:space:]]*${a}\)" \
      || { echo "FEHLT Dispatch-Arm für: $a"; return 1; }
  done
}

# ── Help-Flags (--help/-h → Usage + exit 0, NICHT als "Unbekanntes Argument") ──

@test "X-HELP-LONG: --help → Usage + Version, exit 0" {
  run_cli --help
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | grep -cF 'Verwendung:')" -ge 1 ]
  [ "$(printf '%s' "$output" | grep -cF 'macOS Update Manager v1.0.0')" -ge 1 ]
  [ "$(printf '%s' "$output" | grep -cF 'Unbekanntes Argument')" -eq 0 ]
}

@test "X-HELP-SHORT: -h → Usage, exit 0" {
  run_cli -h
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | grep -cF 'Verwendung:')" -ge 1 ]
  [ "$(printf '%s' "$output" | grep -cF 'Unbekanntes Argument')" -eq 0 ]
}

@test "X-CLIENT-NODRIFT: CLI ohne Nachbar-setup läuft als Client (kein Drift-Re-Deploy)" {
  local box; box=$(mktemp -d /tmp/.macup_client.XXXXXX)
  cp "$CLI" "$box/macOSUpdater_v1.0.0.sh"
  cp "${BATS_TEST_DIRNAME}/.."/_constants.sh "$box/_constants.sh"
  # KEIN setup daneben → Client-Modus
  make_fake_daemon "0"
  PATH="$STUB:/usr/bin:/bin:/usr/sbin:/sbin" \
  MACUP_TRIGGER_OVERRIDE="$TRIG" MACUP_DONE_OVERRIDE="$DONE" MACUP_LOG_OVERRIDE="$NOLOG" \
  run "$box/macOSUpdater_v1.0.0.sh" macos
  rm -rf "$box"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | grep -cF 'Einrichtung des LaunchDaemon')" -eq 0 ]
  [ "$(printf '%s' "$output" | grep -cF 'wird neu deployed')" -eq 0 ]
}
