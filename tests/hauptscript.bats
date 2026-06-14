#!/usr/bin/env bats
# ══════════════════════════════════════════════════════════════════
#  hauptscript_v0.7.bats — Tests für v0.7-Features im Hauptscript
#
#  Coverage:
#    T-NF  notify_user-Function vorhanden + osascript-Aufruf
#    T-PF  Trigger-Pfad zeigt auf $HOME (nicht /tmp)
#    T-PF  Done-Marker in $HOME
# ══════════════════════════════════════════════════════════════════

setup() {
  ROOT="${BATS_TEST_DIRNAME}/.."
  HAUPTSCRIPT=$(ls "$ROOT"/macOSUpdater_v*.sh 2>/dev/null | head -1)
  [[ -f "$HAUPTSCRIPT" ]]
}

@test "T-NF-1: notify_user-Function definiert" {
  grep -qE "^notify_user\(\)" "$HAUPTSCRIPT"
}

@test "T-NF-2: notify_user nutzt osascript für display notification" {
  grep -qE 'osascript.*display notification' "$HAUPTSCRIPT"
}

@test "T-NF-3: notify_user wird in print_run_summary aufgerufen" {
  # In der print_run_summary-Function sollte notify_user am Ende stehen
  awk '/^print_run_summary\(\)/,/^}$/' "$HAUPTSCRIPT" | grep -q "notify_user"
}

@test "T-NF-4: notify_user differenziert Erfolg vs. Fehler" {
  # Sollte sowohl ✓ als auch ⚠️ Pfade haben
  awk '/^notify_user\(\)/,/^}$/' "$HAUPTSCRIPT" | grep -qE "fail_count.*0"
  awk '/^notify_user\(\)/,/^}$/' "$HAUPTSCRIPT" | grep -qE "ok_count|erfolgreich|fehlgeschlagen"
}

@test "T-PF-1: TRIGGER nutzt MACUP_TRIGGER_OVERRIDE-Seam mit \$HOME-Default" {
  grep -qE 'TRIGGER="\$\{MACUP_TRIGGER_OVERRIDE:-\$HOME/\$\{MACUP_TRIGGER_BASENAME\}\}"' "$HAUPTSCRIPT"
}

@test "T-PF-2: DONE_MARKER nutzt MACUP_DONE_OVERRIDE-Seam mit \$HOME-Default" {
  grep -qE 'DONE_MARKER="\$\{MACUP_DONE_OVERRIDE:-\$HOME/\$\{MACUP_DONE_BASENAME\}\}"' "$HAUPTSCRIPT"
}

@test "T-PF-LOG: LOG nutzt MACUP_LOG_OVERRIDE-Seam mit MACUP_LOG-Default" {
  grep -qE 'LOG="\$\{MACUP_LOG_OVERRIDE:-\$MACUP_LOG\}"' "$HAUPTSCRIPT"
}

@test "T-PF-3: Daemon-Plist-Pfad via MACUP_PLIST_DST (regression)" {
  grep -qE 'PLIST_DST="\$MACUP_PLIST_DST"' "$HAUPTSCRIPT"
}

@test "T-PF-4: Hauptscript Version = 1.0.0" {
  grep -qE '^VERSION="1\.0\.0"' "$HAUPTSCRIPT"
}

@test "T-PF-5: Hauptscript sourct _constants.sh" {
  grep -qE 'source "\$SCRIPT_DIR/_constants\.sh"' "$HAUPTSCRIPT"
}

# ══════════════════════════════════════════════════════════════════
#  T-V8 — v0.8.0 neue Subcommands (κ1-κ5 + --backup)
# ══════════════════════════════════════════════════════════════════

@test "T-V8-1: have_tool-Helper-Function definiert" {
  grep -qE '^have_tool\(\)' "$HAUPTSCRIPT"
}

@test "T-V8-2: 5 neue Functions vorhanden (casks/pip/npm/gh/backup)" {
  grep -qE '^run_casks\(\)' "$HAUPTSCRIPT"
  grep -qE '^run_pip\(\)' "$HAUPTSCRIPT"
  grep -qE '^run_npm\(\)' "$HAUPTSCRIPT"
  grep -qE '^run_gh\(\)' "$HAUPTSCRIPT"
  grep -qE '^run_backup\(\)' "$HAUPTSCRIPT"
}

@test "T-V8-3: VALID_ARGS enthält neue Subcommands" {
  grep -qE 'VALID_ARGS=\(.*casks.*pip.*npm.*gh' "$HAUPTSCRIPT"
}

@test "T-V8-4: --backup Flag wird geparsed (DO_BACKUP=true)" {
  grep -qE '\-\-backup\) DO_BACKUP=true' "$HAUPTSCRIPT"
}

@test "T-V8-4b: DO_BACKUP=false-Default steht VOR der --backup-Parse-Zeile (No-Op-Regression)" {
  # Bug (v0.8.0): die unbedingte Initialisierung `DO_BACKUP=false` stand NACH der
  # Argument-Parse-Schleife und klobberte das dort gesetzte `DO_BACKUP=true` →
  # --backup war ein kompletter No-Op (run_all sah immer false). Der Default MUSS
  # vor der Parse-Zeile stehen, sonst überlebt das geparste true nicht.
  local init_line parse_line
  init_line=$(grep -nE '^DO_BACKUP=false' "$HAUPTSCRIPT" | head -1 | cut -d: -f1)
  parse_line=$(grep -nE '\-\-backup\) DO_BACKUP=true' "$HAUPTSCRIPT" | head -1 | cut -d: -f1)
  [ -n "$init_line" ]
  [ -n "$parse_line" ]
  [ "$init_line" -lt "$parse_line" ]
}

@test "T-V8-4c: trigger_daemon liest DONE_MARKER-Inhalt (rc statt nur Existenz)" {
  # Silent-Failure-Härtung: der Daemon schreibt den Action-rc in den Marker,
  # trigger_daemon muss ihn LESEN (nicht nur auf Existenz prüfen).
  awk '/^trigger_daemon\(\)/,/^}$/' "$HAUPTSCRIPT" | grep -qE 'cat "\$DONE_MARKER"'
}

@test "T-V8-4d: trigger_daemon wertet non-zero Marker-rc als Fehler" {
  # Ein fehlgeschlagenes-aber-beendetes Update (Marker-Inhalt ≠0) muss als
  # Fehler durchschlagen, nicht als „✓". Leerer Marker bleibt Legacy-Erfolg.
  local body
  body=$(awk '/^trigger_daemon\(\)/,/^}$/' "$HAUPTSCRIPT")
  grep -qE 'marker_rc' <<< "$body"
  grep -qE '!= "0"' <<< "$body"
}

@test "T-V8-4e: trigger_daemon wertet 'reboot'-Marker als Erfolg (Reboot-Pfad)" {
  # macos_sw_restart schreibt 'reboot' als Erfolgs-Sentinel, weil der Daemon beim
  # Reboot stirbt bevor er den rc schreibt. Die CLI darf das NICHT als Fehler werten.
  awk '/^trigger_daemon\(\)/,/^}$/' "$HAUPTSCRIPT" | grep -qE '!= "reboot"'
}

@test "T-V8-4f: trigger_daemon nutzt MACUP_TRIGGER_TIMEOUT_OVERRIDE (Default 900)" {
  awk '/^trigger_daemon\(\)/,/^}$/' "$HAUPTSCRIPT" | grep -qE 'max_wait="\$\{MACUP_TRIGGER_TIMEOUT_OVERRIDE:-900\}"'
  ! awk '/^trigger_daemon\(\)/,/^}$/' "$HAUPTSCRIPT" | grep -qE 'waited < 900'
}

@test "T-V8-4g: Drift-Check/run_setup hinter MACUP_SKIP_DAEMON_CHECK gegated (Live-Deploy-Schutz)" {
  # Schliesst den M-5-Hazard: hermetische e2e-Tests dürfen den Live-Daemon nicht
  # real (sudo) redeployen. Der Skip-Guard MUSS vor dem Drift-Check stehen.
  # v1.0.0: Guard ist mit OPERATOR_MODE-Check kombiniert (Client-Modus überspringt ebenfalls).
  grep -qE 'if \[\[ "\$\{MACUP_SKIP_DAEMON_CHECK:-\}" == "1"' "$HAUPTSCRIPT"
}

@test "T-V8-5: STEP_KEYS hat neue Items (casks/pip/npm/gh/backup)" {
  grep -qE 'STEP_KEYS=.*casks.*pip.*npm.*gh.*backup' "$HAUPTSCRIPT"
}

@test "T-V8-6: run_casks ruft brew upgrade --cask" {
  awk '/^run_casks\(\)/,/^}$/' "$HAUPTSCRIPT" | grep -qE 'brew upgrade --cask'
}

@test "T-V8-7: run_pip versucht uv tool upgrade ODER pipx upgrade-all" {
  awk '/^run_pip\(\)/,/^}$/' "$HAUPTSCRIPT" | grep -qE 'uv tool upgrade'
  awk '/^run_pip\(\)/,/^}$/' "$HAUPTSCRIPT" | grep -qE 'pipx upgrade-all'
}

@test "T-V8-8: run_backup nutzt tmutil startbackup --auto --block" {
  awk '/^run_backup\(\)/,/^}$/' "$HAUPTSCRIPT" | grep -qE 'tmutil startbackup --auto --block'
}

@test "T-V8-9: Tool-Detection mit have_tool führt zu graceful skip" {
  # run_casks: prüft brew, returnt 0 wenn nicht da
  awk '/^run_casks\(\)/,/^}$/' "$HAUPTSCRIPT" | grep -qE 'have_tool brew'
  awk '/^run_npm\(\)/,/^}$/' "$HAUPTSCRIPT" | grep -qE 'have_tool npm'
  awk '/^run_gh\(\)/,/^}$/' "$HAUPTSCRIPT" | grep -qE 'have_tool gh'
}

@test "T-V8-9b: run_brew gated via have_tool brew (kein Spurious-Failure ohne brew)" {
  # Konsistenz mit casks/pip/npm/gh: ohne brew darf run_brew nicht 4 Steps
  # als Fehler in die Summary kippen, sondern graceful skippen. Self-Gate in
  # run_brew deckt run_all UND das direkte `brew`-Argument ab.
  awk '/^run_brew\(\)/,/^}$/' "$HAUPTSCRIPT" | grep -qE 'have_tool brew'
}

# ══════════════════════════════════════════════════════════════════
#  T-V71 — v0.7.1-Features
# ══════════════════════════════════════════════════════════════════

@test "T-V71-1: HOMEBREW_NO_ENV_HINTS=1 wird exportiert" {
  grep -qE 'export HOMEBREW_NO_ENV_HINTS=1' "$HAUPTSCRIPT"
}

@test "T-V71-2: HOMEBREW_NO_INSTALL_CLEANUP=1 wird exportiert" {
  grep -qE 'export HOMEBREW_NO_INSTALL_CLEANUP=1' "$HAUPTSCRIPT"
}

@test "T-V71-3: pretty_print_ndjson-Function definiert" {
  grep -qE '^pretty_print_ndjson\(\)' "$HAUPTSCRIPT"
}

@test "T-V71-4: pretty_print_ndjson nutzt jq für NDJSON-Lines" {
  awk '/^pretty_print_ndjson\(\)/,/^}$/' "$HAUPTSCRIPT" | grep -q "jq -r"
}

@test "T-V71-5: trigger_daemon merkt Log-Offset vor Trigger (Item 1 Option B)" {
  awk '/^trigger_daemon\(\)/,/^}$/' "$HAUPTSCRIPT" | grep -qE 'log_offset.*wc -l'
}

@test "T-V71-6: trigger_daemon nutzt tail -n +N statt nur tail -f" {
  awk '/^trigger_daemon\(\)/,/^}$/' "$HAUPTSCRIPT" | grep -qE 'tail -n \+\$\(\(log_offset \+ 1\)\)'
}

@test "T-V71-7: trigger_daemon pipet tail in pretty_print_ndjson" {
  awk '/^trigger_daemon\(\)/,/^}$/' "$HAUPTSCRIPT" | grep -qE 'tail.*\| pretty_print_ndjson'
}

# ══════════════════════════════════════════════════════════════════
#  T-V72 — v0.7.2 Bugfix (Pipe-Cleanup-Hänger)
# ══════════════════════════════════════════════════════════════════

@test "T-V72-1: trigger_daemon kapselt Pipe in Subshell { ... ; } &" {
  # v0.8.1: optionales `2>/dev/null` zwischen `}` und `&` (Notice-Suppression
  # via stderr-Redirect am Fork-Punkt — siehe Hauptscript-Kommentar v0.8.1).
  awk '/^trigger_daemon\(\)/,/^}$/' "$HAUPTSCRIPT" | grep -qE '\{ tail.*\| pretty_print_ndjson; \}( 2>/dev/null)? &'
}

@test "T-V72-2: trigger_daemon nutzt subshell_pid statt TAIL_PID" {
  awk '/^trigger_daemon\(\)/,/^}$/' "$HAUPTSCRIPT" | grep -qE 'subshell_pid=\$!'
}

@test "T-V72-3: trigger_daemon ruft pkill -P für Children-Cleanup" {
  awk '/^trigger_daemon\(\)/,/^}$/' "$HAUPTSCRIPT" | grep -qE 'pkill -P.*subshell_pid'
}

@test "T-V72-4: trigger_daemon hat KEIN nacktes TAIL_PID mehr (Variable Uniqueness)" {
  ! awk '/^trigger_daemon\(\)/,/^}$/' "$HAUPTSCRIPT" | grep -qE 'TAIL_PID='
}

@test "T-V73-1: trigger_daemon nutzt disown für saubere UX (keine Terminated-Notices)" {
  awk '/^trigger_daemon\(\)/,/^}$/' "$HAUPTSCRIPT" | grep -qE 'disown.*subshell_pid'
}

@test "T-V72-5: Cleanup-Reihenfolge: pkill -P → kill → wait" {
  # Sicherstellen dass pkill -P VOR kill kommt (Children erst, dann Parent)
  local trigger_body
  trigger_body=$(awk '/^trigger_daemon\(\)/,/^}$/' "$HAUPTSCRIPT")
  local pkill_line kill_line wait_line
  # v0.8.1: Hauptscript hat `kill  "$subshell_pid"` und `wait  "$subshell_pid"`
  # mit zwei Spaces (visuelle Spaltenausrichtung). Whitespace-tolerantes Regex.
  pkill_line=$(echo "$trigger_body" | grep -nE 'pkill +-P' | head -1 | cut -d: -f1)
  kill_line=$(echo "$trigger_body" | grep -nE 'kill +"\$subshell_pid"' | head -1 | cut -d: -f1)
  wait_line=$(echo "$trigger_body" | grep -nE 'wait +"\$subshell_pid"' | head -1 | cut -d: -f1)
  [ "$pkill_line" -lt "$kill_line" ]
  [ "$kill_line" -lt "$wait_line" ]
}

# ══════════════════════════════════════════════════════════════════
#  T-V82 — Output-Suppression (run_quiet): nur echte Fehler zeigen
# ══════════════════════════════════════════════════════════════════

@test "T-V82-1: run_quiet-Function definiert" {
  grep -qE "^run_quiet\(\)" "$HAUPTSCRIPT"
}

@test "T-V82-2: run_quiet zeigt Output nur bei Exit≠0" {
  # Guard '(( _rc != 0 ))' + printf des abgefangenen Outputs
  awk '/^run_quiet\(\)/,/^}$/' "$HAUPTSCRIPT" | grep -qE '_rc != 0'
  awk '/^run_quiet\(\)/,/^}$/' "$HAUPTSCRIPT" | grep -qE "printf '%s"
}

@test "T-V82-3: run_npm leitet npm/pnpm durch run_quiet (kein nackter Aufruf)" {
  awk '/^run_npm\(\)/,/^}$/' "$HAUPTSCRIPT" | grep -qE 'run_quiet npm update -g'
  # kein nacktes 'npm update -g' ohne run_quiet-Präfix
  ! awk '/^run_npm\(\)/,/^}$/' "$HAUPTSCRIPT" | grep -qE '^[[:space:]]*npm update -g'
}

@test "T-V82-4: Homebrew-Steps laufen via run_quiet" {
  grep -qE 'homebrew_update\)[[:space:]]*run_quiet brew update' "$HAUPTSCRIPT"
  grep -qE 'homebrew_upgrade\)[[:space:]]*run_quiet brew upgrade' "$HAUPTSCRIPT"
}

@test "T-V82-5: run_pip/run_gh/run_casks nutzen run_quiet" {
  awk '/^run_pip\(\)/,/^}$/'   "$HAUPTSCRIPT" | grep -qE 'run_quiet uv tool upgrade'
  awk '/^run_gh\(\)/,/^}$/'    "$HAUPTSCRIPT" | grep -qE 'run_quiet gh extension upgrade'
  awk '/^run_casks\(\)/,/^}$/' "$HAUPTSCRIPT" | grep -qE 'run_quiet brew upgrade --cask'
}
