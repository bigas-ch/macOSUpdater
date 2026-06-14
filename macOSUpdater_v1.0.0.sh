#!/bin/bash
# ══════════════════════════════════════════════════════════════════
#  macOS Update Manager v1.0.0
#  Interaktives fzf-Menü oder direkt via Argument
# ══════════════════════════════════════════════════════════════════
#  v0.8.2 (2026-06-05, macOS 26.5.1): macos_sec-Schritt entfernt.
#  `softwareupdate --background-critical` ist auf macOS 26 deprecated
#  und installierte nichts synchron — Security-/Config-Data-Updates
#  laufen über `softwareupdate -i -a` (macos_sw / Daemon-Action all)
#  mit. macos_sec aus Menü, run_macos, STEP_KEYS und Daemon raus.
#  Zusätzlich: Output-Bereinigung — externe Tools (brew, mas, uv/pipx,
#  npm/pnpm, gh) laufen via run_quiet still; Tool-Ausgabe erscheint NUR
#  bei echtem Fehler (Exit≠0). Erstickt die npm-Warn-Walls (EBADENGINE,
#  deprecated, allow-scripts) tool-agnostisch ohne fragiles grep-Filtern.
# ══════════════════════════════════════════════════════════════════
#  v0.8.1 Bugfix: "Terminated: 15"-Notice nach Daemon-Cleanup
#  unterdrücken. v0.7.3-disown reichte nicht — die Pipe-Subshell
#  printete weiterhin Job-Notices über stderr der Hauptshell.
#  Fix: stderr-FD während Kill-Fenster temporär nach /dev/null
#  umlenken (`exec 3>&2 2>/dev/null ... exec 2>&3 3>&-`), 50 ms
#  Buffer für asynchrone Notices, dann restore. Kein Funktions-
#  Verhalten geändert — rein kosmetisch.
# ══════════════════════════════════════════════════════════════════
#  Sicherheit: Kein sudo, kein Passwort, kein Token im RAM.
#  macOS Updates  → LaunchDaemon (root), kein Passwort nötig
#  App Store      → mas direkt als User (kein sudo nötig)
#  Homebrew       → direkt (kein sudo nötig)
#  Self-Healing   → Fehler werden erkannt, behoben, neu gestartet
# ══════════════════════════════════════════════════════════════════
#  Argumente:
#    (kein Argument)  → interaktives fzf-Menü
#    all              → alle Updates (macOS + brew + casks + apps + pip + npm + gh)
#    macos            → macOS Software-Updates (inkl. Security via -i -a)
#    brew             → brew update → upgrade → autoremove → cleanup
#    casks            → brew upgrade --cask (GUI-Apps) — v0.8.0 NEU
#    apps             → App Store (mas update)
#    pip              → uv tool upgrade --all / pipx upgrade-all — v0.8.0 NEU
#    npm              → npm update -g — v0.8.0 NEU
#    gh               → gh extension upgrade --all — v0.8.0 NEU
#    --backup         → Time Machine backup vor Updates (mit `all`) — v0.8.0 NEU
# ══════════════════════════════════════════════════════════════════

VERSION="1.0.0"
SCRIPT_NAME="macOS Update Manager"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; DIM='\033[2m'
BOLD='\033[1m'; NC='\033[0m'

# ── Usage-Ausgabe (für --help/-h mit exit 0 UND unbekanntes Argument mit exit 1) ──
print_usage() {
  echo -e "Verwendung: ${BOLD}$(basename "$0") [Argument] [--backup]${NC}"
  echo ""
  echo -e "  ${CYAN}(kein Argument)${NC}  Interaktives fzf-Menü"
  echo -e "  ${CYAN}all${NC}              Alle verfügbaren Updates"
  echo -e "  ${CYAN}macos${NC}            macOS Software- + Sicherheitsupdates"
  echo -e "  ${CYAN}brew${NC}             Homebrew: update → upgrade → autoremove → cleanup"
  echo -e "  ${CYAN}casks${NC}            Homebrew Casks (GUI-Apps)"
  echo -e "  ${CYAN}apps${NC}             App Store (mas update)"
  echo -e "  ${CYAN}pip${NC}              Python-Tools (uv / pipx)"
  echo -e "  ${CYAN}npm${NC}              Globale Node-Packages"
  echo -e "  ${CYAN}gh${NC}               GitHub CLI Extensions"
  echo -e "  ${CYAN}--backup${NC}         Time Machine Backup vor 'all' (Pre-Hook)"
  echo ""
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_constants.sh"
# ── ENV-Overrides (NUR für Tests; in Production NICHT setzen) ─────
#    MACUP_TRIGGER_OVERRIDE          — abweichender Trigger-Pfad
#    MACUP_DONE_OVERRIDE             — abweichender Done-Marker-Pfad
#    MACUP_LOG_OVERRIDE              — abweichender Log-Pfad
#    MACUP_TRIGGER_TIMEOUT_OVERRIDE  — Poll-Deadline in s (Default 900; s. trigger_daemon)
#    MACUP_SKIP_DAEMON_CHECK=1       — Drift-Check + run_setup überspringen (kein Live-Deploy)
# Spiegelt die MACUP_*_OVERRIDE-Seams des Daemons → hermetische CLI-Execution-Tests.
TRIGGER="${MACUP_TRIGGER_OVERRIDE:-$HOME/${MACUP_TRIGGER_BASENAME}}"
DONE_MARKER="${MACUP_DONE_OVERRIDE:-$HOME/${MACUP_DONE_BASENAME}}"
LOG="${MACUP_LOG_OVERRIDE:-$MACUP_LOG}"
DAEMON_SRC="$SCRIPT_DIR/macOSUpdater_daemon.sh"
DAEMON_DST="$MACUP_DAEMON_SCRIPT"
PLIST_SRC="$SCRIPT_DIR/ch.bigas.macOSUpdater.plist"
PLIST_DST="$MACUP_PLIST_DST"
# v0.8.0: zusätzliches --backup-Flag (kann VOR oder NACH Action-Argument stehen)
# Default-Init MUSS vor der Parse-Schleife stehen — eine spätere unbedingte
# Zuweisung würde das hier geparste DO_BACKUP=true klobbern (No-Op-Bug v0.8.0).
ARG=""
DO_BACKUP=false
SHOW_HELP=false
for arg in "$@"; do
  case "$arg" in
    -h|--help) SHOW_HELP=true ;;
    --backup) DO_BACKUP=true ;;
    *) [[ -z "$ARG" ]] && ARG="$arg" ;;
  esac
done

# --help/-h: Version + Usage ausgeben und sauber beenden (exit 0) — vor clear,
# Header, Drift-Check und Menü-Logik. KEIN "Unbekanntes Argument"-Pfad.
if $SHOW_HELP; then
  echo -e "${BOLD}${BLUE}${SCRIPT_NAME} v${VERSION}${NC}"
  print_usage
  exit 0
fi

# v0.7.1 Item 3: Brew-Hint-Rauschen unterdrücken (Marketing-Lines aus Output)
export HOMEBREW_NO_ENV_HINTS=1
export HOMEBREW_NO_INSTALL_CLEANUP=1

# Tracking für Run-Summary (Erfolg vs. Fehler pro Schritt)
RESULTS_OK=()
RESULTS_FAIL=()

# ── Header ───────────────────────────────────────────────────────
[[ -z "$ARG" ]] && clear
echo -e "${BOLD}${BLUE}${SCRIPT_NAME} v${VERSION}${NC}"
echo -e "${DIM}──────────────────────────────────────────${NC}"
echo

# ── Argument-Validierung ─────────────────────────────────────────
# v0.8.0: erweitert um casks, pip, npm, gh
VALID_ARGS=(all macos brew casks apps pip npm gh)
if [[ -n "$ARG" ]]; then
  is_valid=false
  for v in "${VALID_ARGS[@]}"; do
    [[ "$ARG" == "$v" ]] && is_valid=true && break
  done
  if ! $is_valid; then
    echo -e "${RED}Unbekanntes Argument: '$ARG'${NC}"
    echo ""
    print_usage
    exit 1
  fi
fi

# ── fzf-Check für Menü-Modus (Arg-Modus prüft inline vor Fall-through) ──
if [[ -z "$ARG" ]] && ! command -v fzf &>/dev/null; then
  echo -e "${RED}fzf nicht gefunden.${NC}"
  echo -e "Installieren mit: ${CYAN}brew install fzf${NC}"
  exit 1
fi

# ── Setup-Funktion ───────────────────────────────────────────────
run_setup() {
  local SETUP="$SCRIPT_DIR/setup_macOSUpdater_v1.0.0.sh"
  if [[ ! -x "$SETUP" ]]; then
    echo -e "${RED}✗ setup_macOSUpdater_v1.0.0.sh nicht gefunden in $SCRIPT_DIR${NC}"
    exit 1
  fi
  "$SETUP" || { echo -e "${RED}✗ Setup fehlgeschlagen.${NC}"; exit 1; }
  echo
}

# ── Betriebsmodus: Operator (Source-Repo, setup daneben) vs. Client (Deploy-Ort) ──
# Nur im Operator-Modus vergleicht der CLI Source<->Live-Daemon und re-deployt bei
# Drift. Der deployte CLI (Client) hat kein setup daneben -> reiner Trigger-Client.
OPERATOR_MODE=false
[[ -x "$SCRIPT_DIR/setup_macOSUpdater_v1.0.0.sh" ]] && OPERATOR_MODE=true

# ── Daemon+Plist-Check: installieren oder aktualisieren ──────────
# v0.6.1: Plist-MD5 zusätzlich zum Daemon-MD5 — fängt Plist-Drift
# (WatchPaths, EnvironmentVariables, Label-Änderungen) ab.
DAEMON_NEEDS_SETUP=false
# MACUP_SKIP_DAEMON_CHECK=1 (NUR Tests): Drift-Check + run_setup überspringen —
# verhindert, dass hermetische Execution-Tests den Live-Daemon real (sudo) redeployen.
# $OPERATOR_MODE == false (Client): Drift-Check + Re-Deploy ebenfalls überspringen —
# der deployte CLI hat kein setup daneben und ist reiner Trigger-Client.
if [[ "${MACUP_SKIP_DAEMON_CHECK:-}" == "1" || "$OPERATOR_MODE" == "false" ]]; then
  :
elif [[ ! -f "$PLIST_DST" ]] || [[ ! -f "$DAEMON_DST" ]]; then
  echo -e "${YELLOW}⚙️  Einmalige Einrichtung des LaunchDaemon...${NC}"
  DAEMON_NEEDS_SETUP=true
else
  # Daemon-MD5 (Variable Uniqueness: pro Datei eigene Variablen)
  if [[ -f "$DAEMON_SRC" ]]; then
    DAEMON_SRC_SUM=$(md5 -q "$DAEMON_SRC" 2>/dev/null)
    DAEMON_DST_SUM=$(md5 -q "$DAEMON_DST" 2>/dev/null)
    if [[ "$DAEMON_SRC_SUM" != "$DAEMON_DST_SUM" ]]; then
      echo -e "${YELLOW}⚙️  Daemon-Script aktualisiert — wird neu deployed...${NC}"
      DAEMON_NEEDS_SETUP=true
    fi
  fi
  # Plist-MD5 (v0.6.1 NEU)
  if [[ -f "$PLIST_SRC" ]]; then
    PLIST_SRC_SUM=$(md5 -q "$PLIST_SRC" 2>/dev/null)
    PLIST_DST_SUM=$(md5 -q "$PLIST_DST" 2>/dev/null)
    if [[ "$PLIST_SRC_SUM" != "$PLIST_DST_SUM" ]]; then
      echo -e "${YELLOW}⚙️  Plist aktualisiert — wird neu deployed...${NC}"
      DAEMON_NEEDS_SETUP=true
    fi
  fi
fi
[[ "$OPERATOR_MODE" == "true" ]] && $DAEMON_NEEDS_SETUP && run_setup

# ── Pretty-Print für NDJSON-Live-Stream (v0.7.1 Item 4) ──────────
# Liest stdin Zeile für Zeile. NDJSON-Lines (beginnen mit '{') werden
# kompakt formatiert via jq. Plain-Text-Lines (softwareupdate-stdout)
# werden 1:1 durchgereicht. Verhindert Wand aus JSON im Terminal.
pretty_print_ndjson() {
  while IFS= read -r line; do
    if [[ "$line" == \{* ]]; then
      # NDJSON: kompakt mit Glyphen je nach Event-Typ
      echo "$line" | jq -r '
        (.ts // "" | .[11:19]) as $time |
        (
          if .event == "step_started" then "▶"
          elif .event == "step_completed" then "✓"
          elif .event == "step_failed" then "✗"
          elif .event == "owner_mismatch" or .event == "unknown_action" or .event == "trigger_missing" or .event == "expected_owner_unresolvable" then "⛔"
          elif .event == "daemon_started" then "▷"
          elif .event == "daemon_completed" then "▣"
          elif .event == "owner_validated" then "🔓"
          else "·"
          end
        ) as $glyph |
        (.step // .action // "") as $context |
        (if .duration_ms then " (\(.duration_ms)ms)" else "" end) as $dur |
        "[\($time)] \($glyph) \($context // "")\($dur) — \(.msg // .event)"
      ' 2>/dev/null || echo "$line"
    else
      echo "$line"
    fi
  done
}

# ── Daemon-Trigger (nur für softwareupdate) ──────────────────────
trigger_daemon() {
  local action="$1"
  local max_wait="${MACUP_TRIGGER_TIMEOUT_OVERRIDE:-900}"
  rm -f "$DONE_MARKER" 2>/dev/null || true
  # v0.7.1 Item 1 (Option B): merke Log-Länge VOR Trigger, damit tail
  # nur neue Zeilen anzeigt (Backlog aus alten Runs unsichtbar).
  local log_offset=0
  [[ -r "$LOG" ]] && log_offset=$(wc -l < "$LOG" | tr -d ' ')
  echo "$action" > "$TRIGGER"
  echo -e "${DIM}  ⏳ Warte auf Daemon...${NC}"
  sleep 1
  if [[ -r "$LOG" ]]; then
    # v0.7.2 Bugfix: Pipe in Subshell `{ ... ; } &` kapseln, damit eine
    # einzige PID alle Pipe-Komponenten dominiert. Vorher (v0.7.1):
    # `tail | pretty &; PID=$!` → $! war nur rechte Pipe-Komponente,
    # tail (links) blieb am File hängen, wait blockierte ewig.
    # Fix: pkill -P $subshell_pid killt alle Children (tail + jq-Aufrufe),
    # dann kill subshell_pid + wait → sauberer Cleanup in <100ms.
    # v0.8.1 Bugfix: stderr der Subshell direkt am Fork-Punkt nach
    # /dev/null umleiten. Hintergrund: die Notice "Terminated: 15
    # tail | pretty_print_ndjson" wird von der INNEREN Subshell
    # gedruckt, sobald pkill ihre Pipe-Komponenten killt. Subshells
    # erben FDs statisch beim Fork — spätere exec-Reassignments in der
    # Hauptshell greifen dort nicht mehr (deshalb v0.7.3-disown nicht
    # half). Da pretty_print_ndjson bereits jq-Errors via 2>/dev/null
    # unterdrückt und tail im -f-Modus keine relevanten stderr-Outputs
    # produziert, ist die globale stderr-Unterdrückung der Subshell
    # unkritisch — Funktional-Errors bleiben über die Daemon-Logs
    # ($LOG) sichtbar.
    { tail -n +$((log_offset + 1)) -f "$LOG" | pretty_print_ndjson; } 2>/dev/null &
    local subshell_pid=$!
    disown "$subshell_pid" 2>/dev/null || true
    local waited=0
    while [[ ! -f "$DONE_MARKER" ]] && (( waited < max_wait )); do
      sleep 1; (( waited++ ))
    done
    pkill -P "$subshell_pid" 2>/dev/null || true
    kill  "$subshell_pid" 2>/dev/null || true
    wait  "$subshell_pid" 2>/dev/null || true
  else
    echo -e "${YELLOW}  ⚠️  Log nicht lesbar — Update läuft im Hintergrund${NC}"
    local waited=0
    while [[ ! -f "$DONE_MARKER" ]] && (( waited < max_wait )); do
      sleep 1; (( waited++ ))
    done
  fi
  # v1.0.0: Marker trägt den Daemon-Action-rc (statt nur zu existieren).
  # Fehlend → Timeout/Crash (Daemon nie fertig). Leer → Legacy-touch (Erfolg
  # wie vor v1.0.0). 'reboot' → Reboot-Sentinel aus macos_sw_restart (Daemon
  # stirbt beim Reboot vorm rc-Write) = Erfolg. Numerisch ≠0 → fehlgeschlagenes-
  # aber-beendetes Update → Fehler durchreichen (schliesst die Silent-Failure:
  # vorher meldete jeder beendete Lauf „✓", auch wenn softwareupdate rc≠0 gab).
  local result=0
  if [[ ! -f "$DONE_MARKER" ]]; then
    result=1
  else
    local marker_rc; marker_rc=$(cat "$DONE_MARKER" 2>/dev/null)
    [[ -n "$marker_rc" && "$marker_rc" != "0" && "$marker_rc" != "reboot" ]] && result=1
  fi
  rm -f "$DONE_MARKER" 2>/dev/null || true
  return $result
}

# ── mas update mit Self-Healing ──────────────────────────────────
run_mas() {
  local attempt=1 max_attempts=3
  while (( attempt <= max_attempts )); do
    # LANG=C/LC_ALL=C → locale-stabile englische Strings fürs Routing unten
    # (sonst entgeht ein lokalisierter Fehler dem Grep → silent failure).
    local output; output=$(LANG=C LC_ALL=C mas update 2>&1)
    local exit_code=$?
    # Der mas-Exit-Code ist die Wahrheit: exit 0 = Erfolg. Kein zusätzliches
    # Fehler-String-Greppen mehr (das erzeugte false-fail bei harmlosem
    # "0 errors" und false-pass bei nicht-englischem Locale).
    (( exit_code == 0 )) && return 0
    # Nicht-Erfolg → nach behebbaren Ursachen routen (LANG=C-stabil):
    if echo "$output" | grep -qi "sudo uid\|sudo\|root"; then
      echo -e "${YELLOW}  ⚠️  mas läuft als root — korrigiere...${NC}"
      unset SUDO_ASKPASS; export MAS_DISABLE_SUDO=1
      (( attempt++ )); sleep 1; continue
    fi
    if echo "$output" | grep -qi "sign in\|apple id\|not signed"; then
      echo -e "${YELLOW}  ⚠️  Nicht im App Store angemeldet.${NC}"
      open -a "App Store"; sleep 5; (( attempt++ )); continue
    fi
    if echo "$output" | grep -qi "network\|internet\|connection\|timeout"; then
      echo -e "${YELLOW}  ⚠️  Netzwerkfehler — warte 5s...${NC}"
      sleep 5; (( attempt++ )); continue
    fi
    echo -e "${RED}  ✗ Unbekannter Fehler (exit: $exit_code).${NC}"
    printf '%s\n' "$output"
    (( attempt++ ))
  done
  echo -e "${RED}  ✗ mas update nach $max_attempts Versuchen fehlgeschlagen.${NC}"
  return 1
}

# ── Result-Tracking ──────────────────────────────────────────────
reset_results() {
  RESULTS_OK=()
  RESULTS_FAIL=()
}

print_run_summary() {
  echo
  echo -e "${DIM}══════════════════════════════════════════${NC}"
  echo -e "${BOLD}Zusammenfassung${NC}"
  echo -e "${DIM}══════════════════════════════════════════${NC}"
  if (( ${#RESULTS_OK[@]} == 0 && ${#RESULTS_FAIL[@]} == 0 )); then
    echo -e "${DIM}Keine Schritte ausgeführt.${NC}"
  fi
  if (( ${#RESULTS_OK[@]} > 0 )); then
    echo -e "${GREEN}${BOLD}Erfolgreich (${#RESULTS_OK[@]}):${NC}"
    for r in "${RESULTS_OK[@]}"; do
      echo -e "  ${GREEN}✓${NC} $r"
    done
  fi
  if (( ${#RESULTS_FAIL[@]} > 0 )); then
    (( ${#RESULTS_OK[@]} > 0 )) && echo
    echo -e "${RED}${BOLD}Mit Fehlern (${#RESULTS_FAIL[@]}):${NC}"
    for r in "${RESULTS_FAIL[@]}"; do
      echo -e "  ${RED}✗${NC} $r"
    done
  fi
  echo -e "${DIM}══════════════════════════════════════════${NC}"
  notify_user
}

# ── macOS UserNotification (v0.7) ─────────────────────────────────
# Erscheint im Notification-Center; essentiell für Cron/CI-Runs ohne TTY.
notify_user() {
  local total=$(( ${#RESULTS_OK[@]} + ${#RESULTS_FAIL[@]} ))
  (( total == 0 )) && return 0
  local ok_count=${#RESULTS_OK[@]} fail_count=${#RESULTS_FAIL[@]}
  local title="macOSUpdater v${VERSION}"
  local message subtitle
  if (( fail_count > 0 )); then
    message="⚠️  ${fail_count}/${total} Schritte fehlgeschlagen"
    subtitle="Log: $LOG"
    osascript -e "display notification \"$message\" with title \"$title\" subtitle \"$subtitle\"" 2>/dev/null || true
  else
    message="✓ ${ok_count} Schritte erfolgreich"
    osascript -e "display notification \"$message\" with title \"$title\"" 2>/dev/null || true
  fi
}

# ── v0.8.0: Tool-Detection-Helper ────────────────────────────────
# Returnt 0 wenn Binary im PATH oder unter /opt/homebrew/bin existiert.
have_tool() {
  command -v "$1" >/dev/null 2>&1
}

# ── v0.8.2: Output-Suppression — nur echte Fehler zeigen ─────────
# Führt ein Kommando still aus und fängt stdout+stderr ab. Bei Exit≠0
# wird der abgefangene Output (= der echte Fehler) ausgegeben, bei
# Erfolg geschluckt. Tool-agnostisch → überlebt künftiges Tool-
# Geschwätz (npm EBADENGINE/deprecated/allow-scripts etc.) ohne
# brüchige Pattern-Listen. Rückgabewert = Exit-Code des Kommandos.
run_quiet() {
  local _out _rc
  _out=$("$@" 2>&1); _rc=$?
  (( _rc != 0 )) && printf '%s\n' "$_out"
  return $_rc
}

# ── v0.8.0: Casks (Homebrew GUI-Apps) ────────────────────────────
run_casks() {
  if ! have_tool brew; then
    echo -e "${YELLOW}  ⚠️  brew nicht gefunden — skip${NC}"
    return 0
  fi
  run_quiet brew upgrade --cask
}

# ── v0.8.0: Python-Tools (uv tool / pipx) ────────────────────────
run_pip() {
  local rc=0 did_anything=false
  if have_tool uv; then
    run_quiet uv tool upgrade --all || rc=$?
    did_anything=true
  fi
  if have_tool pipx; then
    run_quiet pipx upgrade-all || rc=$?
    did_anything=true
  fi
  if ! $did_anything; then
    echo -e "${YELLOW}  ⚠️  Weder uv noch pipx installiert — skip${NC}"
  fi
  return $rc
}

# ── v0.8.0: Globale Node-Packages ─────────────────────────────────
run_npm() {
  if ! have_tool npm; then
    echo -e "${YELLOW}  ⚠️  npm nicht gefunden — skip${NC}"
    return 0
  fi
  local rc=0
  run_quiet npm update -g || rc=$?
  if have_tool pnpm; then
    run_quiet pnpm update -g || rc=$?
  fi
  return $rc
}

# ── v0.8.0: GitHub CLI Extensions ─────────────────────────────────
run_gh() {
  if ! have_tool gh; then
    echo -e "${YELLOW}  ⚠️  gh nicht gefunden — skip${NC}"
    return 0
  fi
  run_quiet gh extension upgrade --all
}

# ── v0.8.0: Time Machine Backup (Pre-Hook für all) ───────────────
run_backup() {
  if ! have_tool tmutil; then
    echo -e "${YELLOW}  ⚠️  tmutil nicht gefunden — skip${NC}"
    return 0
  fi
  echo -e "${CYAN}  Time Machine Backup wird gestartet (kann mehrere Minuten dauern)...${NC}"
  # --auto: nutzt aktuelles Backup-Volume; --block: wartet bis fertig
  tmutil startbackup --auto --block 2>&1
}

# ── Gruppen-Runner ───────────────────────────────────────────────
run_step() {
  local key="$1" label="$2" rc=0
  echo; echo -e "${CYAN}${BOLD}▶ ${label}${NC}"
  echo -e "${DIM}──────────────────────────────────────────${NC}"
  case "$key" in
    macos_all)           trigger_daemon "all" ;;
    macos_sw)            trigger_daemon "macos_sw" ;;
    appstore)            run_mas ;;
    homebrew_update)     run_quiet brew update ;;
    homebrew_upgrade)    run_quiet brew upgrade ;;
    homebrew_autoremove) run_quiet brew autoremove ;;
    homebrew_cleanup)    run_quiet brew cleanup ;;
    casks)               run_casks ;;
    pip)                 run_pip ;;
    npm)                 run_npm ;;
    gh)                  run_gh ;;
    backup)              run_backup ;;
  esac
  rc=$?
  if (( rc == 0 )); then
    echo -e "${GREEN}✓ Erledigt: ${label}${NC}"
    RESULTS_OK+=("$label")
  else
    echo -e "${RED}✗ Fehler: ${label} (exit $rc)${NC}"
    RESULTS_FAIL+=("$label")
  fi
  return $rc
}

run_macos() {
  run_step "macos_sw"  "[macOS]       Software-Updates installieren"
}

run_brew() {
  # Konsistent mit casks/pip/npm/gh: ohne brew graceful skippen statt 4 Steps
  # als Spurious-Failures in die Summary zu kippen. Deckt run_all UND das
  # direkte `brew`-Argument ab (ein Self-Gate statt Wrapper an jeder Aufrufstelle).
  if ! have_tool brew; then
    echo -e "${YELLOW}  ⚠️  brew nicht gefunden — skip${NC}"
    return 0
  fi
  run_step "homebrew_update"     "[Homebrew]    brew update"
  run_step "homebrew_upgrade"    "[Homebrew]    brew upgrade"
  run_step "homebrew_autoremove" "[Homebrew]    brew autoremove"
  run_step "homebrew_cleanup"    "[Homebrew]    brew cleanup"
}

run_apps() {
  run_step "appstore" "[App Store]   mas update"
}

run_casks_step() {
  run_step "casks" "[Homebrew]    brew upgrade --cask"
}

run_pip_step() {
  run_step "pip" "[Python]      uv / pipx upgrade"
}

run_npm_step() {
  run_step "npm" "[Node]        npm update -g (+pnpm)"
}

run_gh_step() {
  run_step "gh" "[GitHub CLI]  gh extension upgrade --all"
}

run_all() {
  echo -e "${BOLD}${YELLOW}★ Alle Updates werden ausgeführt…${NC}"
  echo -e "${DIM}──────────────────────────────────────────${NC}"
  # v0.8.0: --backup Pre-Hook
  if $DO_BACKUP; then
    run_step "backup" "[TimeMachine] Backup vor Updates"
  fi
  run_step "macos_all" "[macOS]       Software- + Sicherheitsupdates"
  run_brew
  # v0.8.0: opt-in via Tool-Detection — skip wenn nicht installiert
  if have_tool brew; then run_casks_step; fi
  run_apps
  run_pip_step
  run_npm_step
  run_gh_step
}

# ── Abschluss-Check (Neustart) ───────────────────────────────────
check_reboot() {
  echo; echo -e "${DIM}──────────────────────────────────────────${NC}"
  local needsReboot
  needsReboot=$(softwareupdate -l 2>/dev/null | grep -i restart || true)
  if [[ -n "$needsReboot" ]]; then
    echo -e "${YELLOW}⚠  Neustart erforderlich nach Updates.${NC}"
    read -r -n 1 -p "Jetzt neu starten? (y/n): " restart_antwort; echo
    if [[ "$restart_antwort" == "y" || "$restart_antwort" == "Y" ]]; then
      trigger_daemon "macos_sw_restart"
    else
      echo -e "${DIM}Neustart übersprungen — bitte später manuell ausführen.${NC}"
    fi
  else
    echo -e "${GREEN}✓ Kein Neustart erforderlich.${NC}"
  fi
}

# ══════════════════════════════════════════════════════════════════
#  Dispatch: Argument → direkt ausführen, sonst fzf-Menü
# ══════════════════════════════════════════════════════════════════
if [[ -n "$ARG" ]]; then
  reset_results
  case "$ARG" in
    all)   run_all   ;;
    macos) run_macos ;;
    brew)  run_brew  ;;
    casks) run_casks_step ;;
    apps)  run_apps  ;;
    pip)   run_pip_step ;;
    npm)   run_npm_step ;;
    gh)    run_gh_step ;;
  esac
  check_reboot
  print_run_summary
  echo

  # Non-interaktiv (cron, CI): direkt beenden statt auf Tastendruck zu warten.
  if [[ ! -t 0 ]]; then
    echo -e "${BOLD}${GREEN}✓ Fertig.${NC}"; echo
    exit 0
  fi
  if ! command -v fzf &>/dev/null; then
    echo -e "${YELLOW}fzf nicht gefunden — Menü-Modus nicht verfügbar.${NC}"
    echo -e "${DIM}Installieren mit: brew install fzf${NC}"; echo
    exit 0
  fi

  read -n 1 -s -r -p "Taste drücken für Menü..."
  # Fall-through ins fzf-Menü (clear erfolgt automatisch in der Loop-Spitze)
fi

# ══════════════════════════════════════════════════════════════════
#  fzf Haupt-Loop (kein Argument)
# ══════════════════════════════════════════════════════════════════
STEP_KEYS=("all" "macos_sw" "homebrew_update" "homebrew_upgrade" "homebrew_autoremove" "homebrew_cleanup" "casks" "appstore" "pip" "npm" "gh" "backup")
STEP_LABELS=(
  "[★ Alle]      Alle Updates ausführen"
  "[macOS]       Software-Updates installieren"
  "[Homebrew]    brew update"
  "[Homebrew]    brew upgrade"
  "[Homebrew]    brew autoremove"
  "[Homebrew]    brew cleanup"
  "[Homebrew]    brew upgrade --cask (GUI-Apps)"
  "[App Store]   mas update"
  "[Python]      uv / pipx upgrade"
  "[Node]        npm update -g (+pnpm)"
  "[GitHub CLI]  gh extension upgrade --all"
  "[TimeMachine] Backup (Pre-Hook für 'all')"
)

while true; do
  clear
  echo -e "${BOLD}${BLUE}${SCRIPT_NAME} v${VERSION}${NC}"
  echo -e "${DIM}──────────────────────────────────────────${NC}"; echo

  SELECTED=$(printf '%s\n' "${STEP_LABELS[@]}" | fzf \
    --multi \
    --header="Enter: starten  Tab: mehrere wählen  Ctrl-A: alle  Esc: beenden" \
    --header-first --prompt="  Schritte wählen › " \
    --pointer="▶" --marker=" ✓" --height=65% --border=rounded \
    --border-label=" macOS Update Manager v${VERSION} " \
    --color="header:italic:blue,marker:green,pointer:yellow,border:dim,label:bold:blue" \
    --bind "tab:toggle+down" --bind "shift-tab:toggle+up" \
    --bind "ctrl-a:select-all" --bind "ctrl-d:deselect-all" \
    --bind "ctrl-c:abort" --bind "esc:abort" \
    --info=inline --cycle --reverse) || true

  if [[ -z "$SELECTED" ]]; then
    echo -e "\n${YELLOW}Beendet.${NC}\n"; exit 0
  fi

  echo -e "${BOLD}Ausgewählte Schritte:${NC}"
  echo -e "${DIM}──────────────────────────────────────────${NC}"
  while IFS= read -r line; do echo -e "  ${GREEN}✓${NC} ${line}"; done <<< "$SELECTED"
  echo -e "${DIM}──────────────────────────────────────────${NC}"; echo

  read -r -n 1 -p "Starten? (y/n): " confirm; echo
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo -e "${YELLOW}Zurück zum Menü…${NC}"; sleep 1; continue
  fi

  reset_results
  if grep -qF "[★ Alle]      Alle Updates ausführen" <<< "$SELECTED"; then
    run_all
  else
    for i in "${!STEP_KEYS[@]}"; do
      while IFS= read -r line; do
        [[ "${STEP_LABELS[$i]}" == "$line" ]] && run_step "${STEP_KEYS[$i]}" "${STEP_LABELS[$i]}"
      done <<< "$SELECTED"
    done
  fi

  check_reboot
  print_run_summary
  echo; echo -e "${BOLD}${GREEN}✓ Durchlauf abgeschlossen.${NC}"; echo
  read -r -n 1 -p "Zurück zum Menü? (y/n): " weiter; echo
  if [[ "$weiter" != "y" && "$weiter" != "Y" ]]; then
    echo -e "${DIM}Skript beendet.${NC}\n"; exit 0
  fi
done
