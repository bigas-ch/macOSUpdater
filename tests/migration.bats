#!/usr/bin/env bats
# ══════════════════════════════════════════════════════════════════
#  migration.bats — hermetische Old→New-Migrations-Harness (2b).
#
#  TDD-Äquivalent zum nicht-rot-testbaren Live-Akt (2c, OPUS §0.3):
#  legt einen Alt-Install (ch.bigas.OSXforgedUpdater) in die Sandbox,
#  ruft den Setup-Migrations-Pfad und asserted — Alt label-keyed
#  ausgebootet + entfernt, Alt-Log archiviert, Neu deployt + geladen.
#  Keine Live-System-Berührung (sudo/launchctl = Stubs in temp-Sandbox).
# ══════════════════════════════════════════════════════════════════

load setup_test_helper

setup() {
  SETUP="${BATS_TEST_DIRNAME}/../setup_macOSUpdater_v1.0.0.sh"
  SETUP_SANDBOXES=()
  [[ -f "$SETUP" ]]
}

teardown() { clean_sandboxes; }

# Simulierten Alt-Install in die Sandbox legen + Alt-Label als "geladen" markieren.
# Lenkt die Legacy-Pfade des teardown via OVERRIDE-Seams in die Sandbox.
seed_legacy_install() {
  LEG_PLIST="$SBOX/Library/LaunchDaemons/ch.bigas.OSXforgedUpdater.plist"
  LEG_DAEMON="$SBOX/usr/local/bin/OSXforgedUpdater_daemon.sh"
  LEG_LOG="$SBOX/var/log/OSXforgedUpdater.log"
  echo "<plist>old</plist>" > "$LEG_PLIST"
  echo "#old daemon" > "$LEG_DAEMON"
  echo "old log" > "$LEG_LOG"
  export MACUP_LEGACY_FU_PLIST_OVERRIDE="$LEG_PLIST"
  export MACUP_LEGACY_FU_DAEMON_OVERRIDE="$LEG_DAEMON"
  export MACUP_LEGACY_FU_LOG_OVERRIDE="$LEG_LOG"
  mark_loaded "ch.bigas.OSXforgedUpdater"
}

@test "M-1: Alt-Label ch.bigas.OSXforgedUpdater wird label-keyed ausgebootet" {
  make_sandbox; setup_env; seed_legacy_install
  run zsh -c "source '$SETUP'; teardown_legacy_daemons"
  [ "$status" -eq 0 ]
  grep -qF "bootout system/ch.bigas.OSXforgedUpdater" "$LCTL_LOG"
  run grep -qxF "ch.bigas.OSXforgedUpdater" "$LCTL_LOADED"
  [ "$status" -ne 0 ]
  [ ! -f "$LEG_PLIST" ]
  [ ! -f "$LEG_DAEMON" ]
}

@test "M-2: Alt-Log wird archiviert (.legacy), nicht gelöscht" {
  make_sandbox; setup_env; seed_legacy_install
  run zsh -c "source '$SETUP'; teardown_legacy_daemons"
  [ "$status" -eq 0 ]
  [ -f "${LEG_LOG}.legacy" ]
  [ ! -f "$LEG_LOG" ]
}

@test "M-3: Voll-Migration — Alt weg + Neu da + Neu-Label geladen" {
  make_sandbox; setup_env; seed_legacy_install
  run zsh -c "source '$SETUP'; teardown_legacy_daemons; deploy_daemon"
  [ "$status" -eq 0 ]
  # Alt ausgebootet + entfernt
  [ ! -f "$LEG_PLIST" ]
  [ ! -f "$LEG_DAEMON" ]
  run grep -qxF "ch.bigas.OSXforgedUpdater" "$LCTL_LOADED"
  [ "$status" -ne 0 ]
  # Neu deployt (Variante-B-Constants + Daemon) + geladen
  [ -f "$T_DAEMON_DIR/_constants.sh" ]
  [ -f "$T_DAEMON_DIR/macOSUpdater_daemon.sh" ]
  grep -qxF "ch.bigas.macOSUpdater" "$LCTL_LOADED"
  grep -qF "load $T_PLIST" "$LCTL_LOG"
}

@test "M-4: Kein Alt-Install geladen → Teardown idempotenter No-Op (rc 0, kein bootout)" {
  make_sandbox; setup_env
  export MACUP_LEGACY_FU_PLIST_OVERRIDE="$SBOX/none.plist"
  export MACUP_LEGACY_FU_DAEMON_OVERRIDE="$SBOX/none.sh"
  export MACUP_LEGACY_FU_LOG_OVERRIDE="$SBOX/none.log"
  run zsh -c "source '$SETUP'; teardown_legacy_daemons"
  [ "$status" -eq 0 ]
  run grep -qF "bootout" "$LCTL_LOG"
  [ "$status" -ne 0 ]
}

@test "M-5: migrate_legacy ist mit teardown_legacy_daemons verdrahtet" {
  # KRITISCH: make_sandbox/setup_env setzt MACUP_SETUP_LIB=1 → der Sourcing-Guard
  # verhindert, dass das blosse `source` setup_main real ausführt (sonst echtes
  # sudo/launchctl gegen das Live-System). Reine Inspektion der Funktion.
  make_sandbox; setup_env
  run zsh -c "source '$SETUP'; typeset -f migrate_legacy | grep -q teardown_legacy_daemons && echo WIRED"
  [[ "$output" == *"WIRED"* ]]
}
