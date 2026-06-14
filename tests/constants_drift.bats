#!/usr/bin/env bats
# ══════════════════════════════════════════════════════════════════
#  constants_drift.bats — erzwingt Sync der nicht-sourcenden Flächen
#  (plist) mit _constants.sh. Variante B: alles SOLLTE sourcen, aber
#  die plist (XML) kann nicht — daher gebackene Literale + dieser Guard.
# ══════════════════════════════════════════════════════════════════

setup() {
  ROOT="${BATS_TEST_DIRNAME}/.."
  CONST="$ROOT/_constants.sh"
  PLIST=$(ls "$ROOT"/ch.bigas.macOSUpdater.plist 2>/dev/null | head -1)
  source "$CONST"
  [[ -f "$PLIST" ]]
}

@test "CD-1: plist Label == MACUP_LABEL" {
  grep -qF "<string>${MACUP_LABEL}</string>" "$PLIST"
}

@test "CD-2: plist StandardOut/ErrorPath == MACUP_LOG" {
  grep -qF "<string>${MACUP_LOG}</string>" "$PLIST"
}

@test "CD-3: plist ProgramArguments zeigt auf MACUP_DAEMON_SCRIPT" {
  grep -qF "<string>${MACUP_DAEMON_SCRIPT}</string>" "$PLIST"
}

@test "CD-4: plist nutzt __WATCH_PATH__-Platzhalter (setup injiziert in 2b)" {
  grep -qF "__WATCH_PATH__" "$PLIST"
}

@test "CD-5: plist PATH = nur System-Dirs (Prio-0 C-2, kein homebrew/local)" {
  grep -qF "<string>/usr/bin:/bin:/usr/sbin:/sbin</string>" "$PLIST"
  # Negationen als `run …; [ status -ne 0 ]` — nackte `! grep`-Zeile an nicht-finaler
  # Position entkommt der bats-errexit (false green). Siehe Memory
  # feedback-bats-last-command-assertion.
  run grep -qF "/opt/homebrew/bin" "$PLIST"; [ "$status" -ne 0 ]
  run grep -qF "/usr/local/bin" "$PLIST"; [ "$status" -ne 0 ]
}

@test "CD-6: plist enthält keinen Alt-Namen" {
  ! grep -q "OSXforgedUpdater" "$PLIST"
}
