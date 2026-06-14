#!/usr/bin/env bats
# ══════════════════════════════════════════════════════════════════
#  constants.bats — Unit-Tests für _constants.sh (Single Source of Truth)
#  Verifiziert: sourcebar in bash UND zsh, korrekte Werte, keine
#  externen Kommandos (rein deklarativ).
# ══════════════════════════════════════════════════════════════════

setup() {
  CONST="${BATS_TEST_DIRNAME}/../_constants.sh"
  [[ -f "$CONST" ]]
}

@test "C-1: _constants.sh ist in bash sourcebar und setzt MACUP_NAME" {
  run bash -c "source '$CONST'; echo \"\$MACUP_NAME\""
  [ "$status" -eq 0 ]
  [ "$output" = "macOSUpdater" ]
}

@test "C-2: _constants.sh ist in zsh sourcebar und setzt MACUP_NAME" {
  run zsh -c "source '$CONST'; echo \"\$MACUP_NAME\""
  [ "$status" -eq 0 ]
  [ "$output" = "macOSUpdater" ]
}

@test "C-3: Label = ch.bigas.macOSUpdater" {
  run bash -c "source '$CONST'; echo \"\$MACUP_LABEL\""
  [ "$output" = "ch.bigas.macOSUpdater" ]
}

@test "C-4: Daemon-Script-Pfad in root-owned Chain (nicht /usr/local/bin)" {
  run bash -c "source '$CONST'; echo \"\$MACUP_DAEMON_SCRIPT\""
  [ "$output" = "/Library/Application Support/ch.bigas.macOSUpdater/macOSUpdater_daemon.sh" ]
  [[ "$output" != *"/usr/local/bin/"* ]]
}

@test "C-5: Plist-Dst, Log, Trigger-/Done-Basenames korrekt" {
  run bash -c "source '$CONST'; printf '%s|%s|%s|%s' \"\$MACUP_PLIST_DST\" \"\$MACUP_LOG\" \"\$MACUP_TRIGGER_BASENAME\" \"\$MACUP_DONE_BASENAME\""
  [ "$output" = "/Library/LaunchDaemons/ch.bigas.macOSUpdater.plist|/var/log/macOSUpdater.log|.macOSUpdater_trigger|.macOSUpdater_done" ]
}

@test "C-6: _constants.sh enthält keinen Alt-Namen (altes Tool)" {
  ! grep -q "OSXforgedUpdater" "$CONST"
}

@test "C-7: _constants.sh ist rein deklarativ (keine Kommando-Substitution / Pipes)" {
  # Nur Kommentare (#...), Leerzeilen und VAR="..."-Zuweisungen erlaubt.
  # [[:space:]] statt \s — BSD-grep auf macOS kennt \s nicht zuverlässig.
  ! grep -vE '^[[:space:]]*(#|$|[A-Z_]+=)' "$CONST"
}
