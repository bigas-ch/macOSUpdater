#!/usr/bin/env bats
# ══════════════════════════════════════════════════════════════════
#  installer_drift.bats — Drift-Check Setup vs. Uninstaller
#
#  Stellt sicher dass JEDER Pfad, den der Setup-Script installiert,
#  auch im Uninstaller's Removal-Set steht. Verhindert Drift bei
#  Weiterentwicklung (verbindliche Regel ab v0.6).
#
#  Bei Drift fail: Setup oder Uninstaller anpassen, bis beide
#  Listen identisch sind. Pre-Commit-Gate.
# ══════════════════════════════════════════════════════════════════

setup() {
  ROOT="${BATS_TEST_DIRNAME}/.."
  # Versions-agnostisch: Glob nimmt aktuelle Version (Hauptordner-Regel garantiert genau eine)
  SETUP_SCRIPT=$(ls "$ROOT"/setup_macOSUpdater_v*.sh 2>/dev/null | head -1)
  HAUPTSCRIPT=$(ls "$ROOT"/macOSUpdater_v*.sh 2>/dev/null | head -1)
  UNINSTALLER="$ROOT/uninstall_macOSUpdater.sh"
  [[ -f "$SETUP_SCRIPT" ]]
  [[ -f "$HAUPTSCRIPT" ]]
  [[ -f "$UNINSTALLER" ]]
}

# Helper: prüft ob ein Pfad als String im Uninstaller vorkommt.
# Erlaubt Match auf den Basisteil (ohne $HOME/$SCRIPT_DIR-Expansion).
in_uninstaller() {
  local needle="$1"
  grep -qF "$needle" "$UNINSTALLER"
}

# ══════════════════════════════════════════════════════════════════
#  Primary-Pfade (macOSUpdater v1.0.0) → müssen im Uninstaller stehen
# ══════════════════════════════════════════════════════════════════

@test "Drift v1.0: /Library/Application Support/ch.bigas.macOSUpdater/macOSUpdater_daemon.sh im Uninstaller" {
  in_uninstaller "/Library/Application Support/ch.bigas.macOSUpdater/macOSUpdater_daemon.sh"
}

@test "Drift v1.0: /Library/LaunchDaemons/ch.bigas.macOSUpdater.plist im Uninstaller" {
  in_uninstaller "/Library/LaunchDaemons/ch.bigas.macOSUpdater.plist"
}

@test "Drift v1.0: /var/log/macOSUpdater.log im Uninstaller" {
  in_uninstaller "/var/log/macOSUpdater.log"
}

@test "Drift v1.0: .macOSUpdater_trigger im Uninstaller (primary)" {
  in_uninstaller ".macOSUpdater_trigger"
}

@test "Drift v1.0: .macOSUpdater_done im Uninstaller" {
  in_uninstaller ".macOSUpdater_done"
}

@test "Drift v1.0: deploytes _constants.sh im Uninstaller (Variante-B-Co-Deploy)" {
  source "$ROOT/_constants.sh"
  in_uninstaller "$MACUP_DAEMON_DIR/_constants.sh"
}

@test "Drift v1.0: Daemon-Dir wird im Uninstaller entfernt (nach Datei-Removal)" {
  source "$ROOT/_constants.sh"
  in_uninstaller "$MACUP_DAEMON_DIR"
  # rmdir/rm -rf des Verzeichnisses vorhanden (do_rmdir-Helper)
  grep -qE 'do_rmdir|rm -rf.*DAEMON_DIR|rmdir.*DAEMON_DIR' "$UNINSTALLER"
}

@test "Drift v1.0: Log-Rotations-Generationen werden entfernt (.1 bis .5)" {
  grep -qE 'LOG\..*1.*2.*3.*4.*5|for gen in 1 2 3 4 5' "$UNINSTALLER"
}

# ══════════════════════════════════════════════════════════════════
#  Legacy OSXforgedUpdater (Migration v0.x → v1.0) → Removal-Block vorhanden
# ══════════════════════════════════════════════════════════════════

@test "Drift legacy OSXforgedUpdater: Daemon-Pfad im Uninstaller" {
  in_uninstaller "/usr/local/bin/OSXforgedUpdater_daemon.sh"
}

@test "Drift legacy OSXforgedUpdater: Plist im Uninstaller" {
  in_uninstaller "/Library/LaunchDaemons/ch.bigas.OSXforgedUpdater.plist"
}

@test "Drift legacy OSXforgedUpdater: Log im Uninstaller" {
  in_uninstaller "/var/log/OSXforgedUpdater.log"
}

@test "Drift legacy OSXforgedUpdater: Trigger im Uninstaller" {
  in_uninstaller ".OSXforgedUpdater_trigger"
}

@test "Drift legacy OSXforgedUpdater: Done-Marker im Uninstaller" {
  in_uninstaller ".OSXforgedUpdater_done"
}

# ══════════════════════════════════════════════════════════════════
#  Legacy-Pfade (Migration v0.5 → v0.6) → ebenfalls im Uninstaller
# ══════════════════════════════════════════════════════════════════

@test "Drift v0.6 legacy: /usr/local/bin/micha_updater_daemon.sh im Uninstaller" {
  in_uninstaller "/usr/local/bin/micha_updater_daemon.sh"
}

@test "Drift v0.6 legacy: com.micha.updater.plist im Uninstaller" {
  in_uninstaller "/Library/LaunchDaemons/com.micha.updater.plist"
}

@test "Drift v0.6 legacy: /var/log/micha_updater.log im Uninstaller" {
  in_uninstaller "/var/log/micha_updater.log"
}

@test "Drift v0.6 legacy: /tmp/.micha_update_trigger im Uninstaller" {
  in_uninstaller "/tmp/.micha_update_trigger"
}

@test "Drift v0.6 legacy: .micha_update_done im Uninstaller" {
  in_uninstaller ".micha_update_done"
}

# ══════════════════════════════════════════════════════════════════
#  Konsistenz: aufgelöste Constants-Werte müssen im Uninstaller stehen
#  (Setup sourct _constants.sh → Pfade sind Variablen, kein Literal;
#  daher gegen aufgelöste Werte aus Constants prüfen, nicht grep auf Setup)
# ══════════════════════════════════════════════════════════════════

@test "Drift v1.0: MACUP_DAEMON_SCRIPT (aufgelöst) im Uninstaller" {
  source "$ROOT/_constants.sh"
  in_uninstaller "$MACUP_DAEMON_SCRIPT"
}

@test "Drift v1.0: MACUP_PLIST_DST (aufgelöst) im Uninstaller" {
  source "$ROOT/_constants.sh"
  in_uninstaller "$MACUP_PLIST_DST"
}

@test "Drift v1.0: MACUP_LOG (aufgelöst) im Uninstaller" {
  source "$ROOT/_constants.sh"
  in_uninstaller "$MACUP_LOG"
}

@test "Drift v0.6: alle /var/log/... Pfade aus Setup im Uninstaller" {
  local log_paths
  log_paths=$(grep -oE '"/var/log/[^"]+"' "$SETUP_SCRIPT" | sort -u | tr -d '"')
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    if ! in_uninstaller "$path"; then
      echo "DRIFT: Setup-Log-Pfad '$path' fehlt im Uninstaller!" >&2
      return 1
    fi
  done <<< "$log_paths"
}

@test "Drift v0.6: Uninstaller hat 5-Step-Struktur (LaunchDaemons → Plists+Bin → Logs → Transient → Source)" {
  grep -qE "1/5.*LaunchDaemons" "$UNINSTALLER"
  grep -qE "2/5.*Plists" "$UNINSTALLER"
  grep -qE "3/5.*Logs" "$UNINSTALLER"
  grep -qE "4/5.*Transient" "$UNINSTALLER"
  grep -qE "5/5.*Source" "$UNINSTALLER"
}

@test "Drift v0.6: Uninstaller hat Dry-Run-Mode" {
  grep -qE 'DRY_RUN=1|"-n"' "$UNINSTALLER"
}

@test "Drift v0.6: Uninstaller hat Log-Backup-Option" {
  grep -qE "Logdateien.*sichern|BACKUP_DIR" "$UNINSTALLER"
}

# ══════════════════════════════════════════════════════════════════
#  Phase 6: CLI-Co-Deploy + .app-Launcher Symmetrie
# ══════════════════════════════════════════════════════════════════

@test "D-CLI-SYMM: deployter CLI wird vom Uninstaller erfasst" {
  # setup co-deployt macOSUpdater_v1.0.0.sh nach $DAEMON_DIR; Uninstaller entfernt
  # $DAEMON_DIR komplett (do_rmdir) + den CLI explizit.
  grep -qF 'macOSUpdater_v1.0.0.sh' "${BATS_TEST_DIRNAME}/../setup_macOSUpdater_v1.0.0.sh"
  grep -qE 'do_rmdir "\$DAEMON_DIR"' "${BATS_TEST_DIRNAME}/../uninstall_macOSUpdater.sh"
}

@test "D-APP-SYMM: Launcher .app wird deployt UND entfernt" {
  grep -qF 'macOSUpdater.app' "${BATS_TEST_DIRNAME}/../setup_macOSUpdater_v1.0.0.sh"
  grep -qF 'macOSUpdater.app' "${BATS_TEST_DIRNAME}/../uninstall_macOSUpdater.sh"
}
