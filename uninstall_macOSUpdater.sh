#!/bin/zsh
# ══════════════════════════════════════════════════════════════════
#  uninstall_macOSUpdater.sh — v1.0.0 (2026-06-13)
#  Komplette Deinstallation des macOSUpdater-Tools.
# ══════════════════════════════════════════════════════════════════
#  Entfernt:
#    • LaunchDaemon ch.bigas.macOSUpdater (+ legacy com.micha.updater
#      + legacy ch.bigas.OSXforgedUpdater)
#    • Daemon-Binary /Library/Application Support/ch.bigas.macOSUpdater/macOSUpdater_daemon.sh
#    • Co-deploytes /Library/Application Support/ch.bigas.macOSUpdater/_constants.sh
#    • Daemon-Verzeichnis /Library/Application Support/ch.bigas.macOSUpdater/ (nach Datei-Removal)
#    • Plist /Library/LaunchDaemons/ch.bigas.macOSUpdater.plist
#    • Trigger $HOME/.macOSUpdater_trigger (+ legacy)
#    • Done-Marker $HOME/.macOSUpdater_done (+ legacy)
#    • Logs /var/log/macOSUpdater.log* (mit Backup-Option)
#    • App-Launcher /Applications/macOSUpdater.app (+ ~/Applications-Fallback)
#    • Source-Verzeichnis (inkl. Verlauf/, .git/, tests/) — User-Choice
#
#  Argumente:
#    (kein)  → interaktive Deinstallation mit Bestätigungen
#    -n      → Dry-Run (zeigt was entfernt würde, ohne Aktion)
# ══════════════════════════════════════════════════════════════════

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_constants.sh"
DRY_RUN=0
[[ "${1:-}" == "-n" ]] && DRY_RUN=1

# ── Override-Seams (NUR Tests; in Production NICHT setzen) ───────────
# '-' (nicht ':-') bei SUDO bewusst: erlaubt einen explizit leeren "kein-sudo"-
# Seam für hermetische Tests. Spiegelt das setup-Muster.
SUDO="${MACUP_SUDO_OVERRIDE-sudo}"
LAUNCHCTL="${MACUP_LAUNCHCTL_OVERRIDE:-launchctl}"

# ── Pfade (primary — via Constants, test-überschreibbar) ────────────
DAEMON_DIR="${MACUP_DAEMON_DIR_OVERRIDE:-$MACUP_DAEMON_DIR}"
DAEMON_DST="$DAEMON_DIR/${MACUP_DAEMON_SCRIPT##*/}"
DEPLOYED_CONSTANTS="$DAEMON_DIR/_constants.sh"
PLIST_DST="${MACUP_PLIST_DST_OVERRIDE:-$MACUP_PLIST_DST}"
TRIGGER="$HOME/${MACUP_TRIGGER_BASENAME}"
DONE_MARKER="$HOME/${MACUP_DONE_BASENAME}"
LOG="${MACUP_LOG_OVERRIDE:-$MACUP_LOG}"
DEPLOYED_CLI="$DAEMON_DIR/macOSUpdater_v1.0.0.sh"
APP_DST="${MACUP_APP_DIR_OVERRIDE:-/Applications}/macOSUpdater.app"
APP_DST_USER="$HOME/Applications/macOSUpdater.app"

# ── Legacy v0.6 (com.micha.updater) ──────────────────────────────────
LEGACY_DAEMON="/usr/local/bin/micha_updater_daemon.sh"
LEGACY_PLIST="/Library/LaunchDaemons/com.micha.updater.plist"
LEGACY_TRIGGER="/tmp/.micha_update_trigger"
LEGACY_TRIGGER_TMP="/tmp/.macOSUpdater_trigger"
LEGACY_DONE="$HOME/.micha_update_done"
LEGACY_LOG="/var/log/micha_updater.log"
LEGACY_LOG_ARCHIVED="/var/log/micha_updater.log.legacy_v0.5"

# ── Legacy v0.x (ch.bigas.OSXforgedUpdater) — Migration zu macOSUpdater ──
LEGACY_FU_DAEMON="/usr/local/bin/OSXforgedUpdater_daemon.sh"
LEGACY_FU_PLIST="/Library/LaunchDaemons/ch.bigas.OSXforgedUpdater.plist"
LEGACY_FU_LABEL="ch.bigas.OSXforgedUpdater"
LEGACY_FU_LOG="/var/log/OSXforgedUpdater.log"
LEGACY_FU_TRIGGER="$HOME/.OSXforgedUpdater_trigger"
LEGACY_FU_TRIGGER_TMP="/tmp/.OSXforgedUpdater_trigger"
LEGACY_FU_DONE="$HOME/.OSXforgedUpdater_done"

ok()    { echo -e "  ${GREEN}✓${NC}  $*"; }
warn()  { echo -e "  ${YELLOW}⚠️${NC}   $*"; }
fail()  { echo -e "  ${RED}✗${NC}  $*" >&2; }
info()  { echo -e "  ${CYAN}ℹ${NC}  $*"; }
dry()   { echo -e "  ${DIM}↳ [dry-run]${NC}  $*"; }
step()  { echo -e "\n${BOLD}── $*${NC}"; }

# ── F1: Schutz vor vergifteten Removal-Zielen ───────────────────────
# Ein manipuliertes/ungeguardetes _constants.sh kann DAEMON_DIR/PLIST auf
# System-Pfade lenken → destruktives `$SUDO rm -rf`. Vor jedem rm wird das Ziel
# gegen leere Eingabe, Path-Traversal und geschützte System-/Top-Level-Pfade
# geprüft. Legitime Ziele (Sandbox /tmp/…, /Library/…/ch.bigas, /var/log/macOSUpdater*,
# $HOME/.macOSUpdater*, /usr/local/bin/*_daemon.sh, Source-Dir) passieren; nackte
# Roots werden hart abgelehnt — egal woher der Pfad stammt.
assert_safe_target() {
  local target="$1"
  if [[ -z "$target" ]]; then
    fail "F1-Guard: leeres Removal-Ziel abgelehnt"; exit 1
  fi
  if [[ "$target" == *..* ]]; then
    fail "F1-Guard: Path-Traversal im Removal-Ziel abgelehnt: $target"; exit 1
  fi
  local norm="${target%/}"; [[ -z "$norm" ]] && norm="/"
  case "$norm" in
    /|"$HOME"|/System|/System/*|/usr|/usr/bin|/usr/bin/*|/usr/sbin|/usr/sbin/*|/usr/lib|/usr/lib/*|/usr/local|/usr/local/bin|/bin|/bin/*|/sbin|/sbin/*|/etc|/etc/*|/var|/var/log|/var/db|/var/folders|/Library|"/Library/Application Support"|/Library/LaunchDaemons|/Library/Frameworks|/Users|/Applications|/private|/private/var|/private/etc|/private/tmp|/tmp|/opt|/cores|/Volumes|/dev)
      fail "F1-Guard: geschützter System-/Top-Level-Pfad als Removal-Ziel abgelehnt: $target"; exit 1 ;;
  esac
}

# ── Aktion-Wrapper: bei dry-run nur loggen ──────────────────────────
do_rm() {
  local target="$1" use_sudo="${2:-0}"
  assert_safe_target "$target"
  if (( DRY_RUN )); then
    [[ -e "$target" ]] && dry "rm: $target" || dry "skip (nicht vorhanden): $target"
    return 0
  fi
  if [[ -e "$target" ]]; then
    if (( use_sudo )); then
      $SUDO rm -f "$target"
    else
      rm -f "$target" 2>/dev/null || $SUDO rm -f "$target"
    fi
    ok "Entfernt: $target"
  fi
}

do_unload() {
  local plist="$1"
  if (( DRY_RUN )); then
    [[ -f "$plist" ]] && dry "launchctl unload: $plist"
    return 0
  fi
  if [[ -f "$plist" ]]; then
    $SUDO $LAUNCHCTL unload "$plist" 2>/dev/null || true
    ok "Unloaded: $(basename "$plist")"
  fi
}

do_rmdir() {
  local target="$1"
  assert_safe_target "$target"
  if (( DRY_RUN )); then
    [[ -d "$target" ]] && dry "rmdir: $target"
    return 0
  fi
  if [[ -d "$target" ]]; then
    rmdir "$target" 2>/dev/null || $SUDO rmdir "$target" 2>/dev/null \
      || { rm -rf "$target" 2>/dev/null || $SUDO rm -rf "$target"; }
    ok "Verzeichnis entfernt: $target"
  fi
}

# ── Hauptablauf — gekapselt, damit Tests via MACUP_UNINSTALL_LIB=1 nur die
#    Helfer + Pfade sourcen können, ohne den interaktiven Flow zu starten.
uninstall_main() {
# ── Header + Übersicht ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}${RED}════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${RED}  🗑️  macOSUpdater — UNINSTALL${NC}"
(( DRY_RUN )) && echo -e "${BOLD}${YELLOW}  [DRY-RUN — keine echten Änderungen]${NC}"
echo -e "${BOLD}${RED}════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BOLD}Diese Aktion entfernt:${NC}"
echo -e "  ${DIM}•${NC} LaunchDaemon ch.bigas.macOSUpdater (+ legacy com.micha.updater + legacy ${LEGACY_FU_LABEL})"
echo -e "  ${DIM}•${NC} Daemon-Binary $DAEMON_DST"
echo -e "  ${DIM}•${NC} Plist $PLIST_DST"
echo -e "  ${DIM}•${NC} App-Launcher $APP_DST (+ ~/Applications-Fallback)"
echo -e "  ${DIM}•${NC} Trigger + Done-Marker (current + legacy)"
echo -e "  ${DIM}•${NC} Logs in /var/log/ (mit Backup-Option)"
echo -e "  ${DIM}•${NC} Source-Verzeichnis $SCRIPT_DIR (Verlauf/, .git/, tests/) — auf Wunsch"
echo ""
echo -e "${YELLOW}${BOLD}Diese Aktion ist nicht reversibel (außer Logs sind gesichert).${NC}"
echo ""

# ── Hauptbestätigung ────────────────────────────────────────────────
if (( ! DRY_RUN )); then
  read -n 1 -p "Wirklich fortfahren? (y/N): " confirm; echo
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo -e "\n${DIM}Abgebrochen — keine Änderungen.${NC}\n"
    exit 0
  fi
fi

# ── Log-Backup-Frage ────────────────────────────────────────────────
BACKUP_DIR=""
if (( ! DRY_RUN )); then
  echo ""
  read -n 1 -p "Logdateien vor Löschung auf Desktop sichern? (Y/n): " backup; echo
  if [[ "$backup" != "n" && "$backup" != "N" ]]; then
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_DIR="$HOME/Desktop/macOSUpdater_log_backup_$TIMESTAMP"
    mkdir -p "$BACKUP_DIR"
    for log_file in "$LOG" "$LEGACY_LOG" "$LEGACY_LOG_ARCHIVED" "$LEGACY_FU_LOG"; do
      if [[ -r "$log_file" ]]; then
        cp -p "$log_file" "$BACKUP_DIR/$(basename "$log_file")" 2>/dev/null \
          || $SUDO cp -p "$log_file" "$BACKUP_DIR/$(basename "$log_file")"
        ok "Gesichert: $log_file"
      fi
    done
  fi
else
  dry "Log-Backup-Frage wäre hier gestellt"
fi

# ── sudo-Auth ───────────────────────────────────────────────────────
if (( ! DRY_RUN )); then
  echo ""
  echo -e "  ${YELLOW}🔐 Bitte mit Touch ID oder Passwort bestätigen:${NC}"
  if ! $SUDO -v; then
    fail "Authentifizierung fehlgeschlagen — Abbruch."; exit 1
  fi
fi

# ── Schritt 1: LaunchDaemons entladen ───────────────────────────────
step "1/5  LaunchDaemons entladen"
do_unload "$PLIST_DST"
do_unload "$LEGACY_FU_PLIST"
do_unload "$LEGACY_PLIST"

# ── Schritt 2: Plists + Daemon-Binaries entfernen ───────────────────
step "2/5  Plists + Daemon-Binaries entfernen"
do_rm "$PLIST_DST" 1
do_rm "$DAEMON_DST" 1
do_rm "$DEPLOYED_CONSTANTS" 1
do_rm "$DEPLOYED_CLI" 1
do_rm "$LEGACY_FU_PLIST" 1
do_rm "$LEGACY_FU_DAEMON" 1
do_rm "$LEGACY_PLIST" 1
do_rm "$LEGACY_DAEMON" 1
# Daemon-Verzeichnis entfernen, nachdem alle enthaltenen Dateien weg sind
do_rmdir "$DAEMON_DIR"
# App-Launcher entfernen (system- und user-seitig)
do_rmdir "$APP_DST"
do_rmdir "$APP_DST_USER"

# ── Schritt 3: Logs entfernen (inkl. v0.7 Rotations-Generationen) ───
step "3/5  Logs entfernen"
do_rm "$LOG" 1
# v0.7 Log-Rotation: .1 bis .5 Generationen
for gen in 1 2 3 4 5; do
  do_rm "${LOG}.${gen}" 1
done
do_rm "$LEGACY_FU_LOG" 1
do_rm "$LEGACY_LOG" 1
do_rm "$LEGACY_LOG_ARCHIVED" 1

# ── Schritt 4: Trigger + Done-Marker (transient) ────────────────────
step "4/5  Transient-Files entfernen"
do_rm "$TRIGGER" 0
do_rm "$LEGACY_FU_TRIGGER" 0
do_rm "$LEGACY_FU_TRIGGER_TMP" 0
do_rm "$LEGACY_FU_DONE" 0
do_rm "$LEGACY_TRIGGER_TMP" 0
do_rm "$LEGACY_TRIGGER" 0
do_rm "$DONE_MARKER" 0
do_rm "$LEGACY_DONE" 0

# ── Schritt 5: Source-Verzeichnis (User-Choice) ─────────────────────
step "5/5  Source-Verzeichnis"
echo -e "  ${DIM}Verzeichnis: $SCRIPT_DIR${NC}"
if [[ -d "$SCRIPT_DIR/.git" ]]; then
  echo -e "  ${DIM}Enthält Git-Repo (committed Änderungen gehen verloren).${NC}"
fi
if [[ -d "$SCRIPT_DIR/Verlauf" ]]; then
  local verlauf_count
  verlauf_count=$(find "$SCRIPT_DIR/Verlauf" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  echo -e "  ${DIM}Verlauf/ enthält $verlauf_count Versionen-Snapshots.${NC}"
fi
echo ""

if (( DRY_RUN )); then
  dry "Source-Verzeichnis-Frage wäre hier gestellt; bei Y würde rm -rf $SCRIPT_DIR ausgeführt"
else
  read -n 1 -p "  Source-Verzeichnis (inkl. Verlauf/ + .git/ + tests/) wirklich entfernen? (y/N): " final; echo
  if [[ "$final" == "y" || "$final" == "Y" ]]; then
    cd "$HOME"  # cwd-Schutz vor invalid working dir
    rm -rf "$SCRIPT_DIR"
    ok "Entfernt: $SCRIPT_DIR"
  else
    warn "Source-Verzeichnis behalten: $SCRIPT_DIR"
    info "Manuelles Cleanup mit: rm -rf '$SCRIPT_DIR'"
  fi
fi

# ── Final-Status ────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════${NC}"
if (( DRY_RUN )); then
  echo -e "${BOLD}${YELLOW}  ℹ️  DRY-RUN abgeschlossen — keine Änderungen${NC}"
else
  echo -e "${BOLD}${GREEN}  ✅ Deinstallation abgeschlossen${NC}"
  [[ -n "$BACKUP_DIR" ]] && [[ -d "$BACKUP_DIR" ]] && echo -e "  ${CYAN}Logs gesichert in:${NC} $BACKUP_DIR"
fi
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════${NC}"
echo ""
}

# ── Ausführen nur bei direktem Start (nicht beim Sourcen in Tests) ──
if [[ "${MACUP_UNINSTALL_LIB:-0}" != "1" ]]; then
  set -uo pipefail
  uninstall_main "$@"
fi
