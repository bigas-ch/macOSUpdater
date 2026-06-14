#!/bin/zsh
# ══════════════════════════════════════════════════════════════════
#  setup_macOSUpdater_v1.0.0.sh — Einmalige Installation des LaunchDaemon
#  Vollständige Voraussetzungs-Prüfung für neue Maschinen.
#  Authentifizierung via Touch ID (selbst-heilend).
# ══════════════════════════════════════════════════════════════════
#  Prüft + installiert automatisch:
#    • Xcode Command Line Tools
#    • Homebrew
#    • fzf
#    • mas (Mac App Store CLI)
#    • Touch ID für sudo
#    • LaunchDaemon (ch.bigas.macOSUpdater)
#  Migration:
#    • v0.5: com.micha.updater entfernt
#    • v0.6.x: alter /tmp-Trigger geräumt (Pfad-Wechsel zu $HOME)
# ══════════════════════════════════════════════════════════════════

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${(%):-%x}")" && pwd)"
source "$SCRIPT_DIR/_constants.sh"

# ── Override-Seams (NUR Tests; in Production NICHT setzen) ───────────
SUDO="${MACUP_SUDO_OVERRIDE-sudo}"   # '-' (nicht ':-') bewusst: erlaubt einen explizit leeren "kein-sudo"-Seam für Tests
LAUNCHCTL="${MACUP_LAUNCHCTL_OVERRIDE:-launchctl}"
DAEMON_DIR="${MACUP_DAEMON_DIR_OVERRIDE:-$MACUP_DAEMON_DIR}"
DAEMON_SCRIPT="$DAEMON_DIR/${MACUP_DAEMON_SCRIPT##*/}"
PLIST_SRC="$SCRIPT_DIR/ch.bigas.macOSUpdater.plist"
PLIST_DST="${MACUP_PLIST_DST_OVERRIDE:-$MACUP_PLIST_DST}"
LOG="${MACUP_LOG_OVERRIDE:-$MACUP_LOG}"

# Legacy-Pfade (Migration v0.5 → v0.6)
LEGACY_DAEMON="/usr/local/bin/micha_updater_daemon.sh"
LEGACY_PLIST="/Library/LaunchDaemons/com.micha.updater.plist"
LEGACY_LABEL="com.micha.updater"

ok()   { echo -e "  ${GREEN}✓${NC}  $*"; }
warn() { echo -e "  ${YELLOW}⚠️${NC}   $*"; }
fail() { echo -e "  ${RED}✗${NC}  $*" >&2; }
step() { echo -e "\n${BOLD}── $*${NC}"; }

check_prereqs() {
  # ════════════════════════════════════════════════════════════════
  #  1. Xcode Command Line Tools
  # ════════════════════════════════════════════════════════════════
  step "1/8  Xcode Command Line Tools"
  if xcode-select -p &>/dev/null; then
    ok "Xcode CLT bereits installiert ($(xcode-select -p))"
  else
    warn "Xcode CLT fehlt — wird installiert..."
    xcode-select --install 2>/dev/null || true
    echo -e "  ${DIM}Bitte den Installations-Dialog bestätigen und danach erneut starten.${NC}"
    exit 0
  fi

  # ════════════════════════════════════════════════════════════════
  #  2. Homebrew
  # ════════════════════════════════════════════════════════════════
  step "2/8  Homebrew"
  if command -v brew &>/dev/null; then
    ok "Homebrew bereits installiert ($(brew --version | head -1))"
  else
    warn "Homebrew fehlt — wird installiert..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [[ -f /opt/homebrew/bin/brew ]]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
      echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
    fi
    ok "Homebrew installiert"
  fi

  # ════════════════════════════════════════════════════════════════
  #  3. fzf
  # ════════════════════════════════════════════════════════════════
  step "3/8  fzf"
  if command -v fzf &>/dev/null; then
    ok "fzf bereits installiert ($(fzf --version))"
  else
    warn "fzf fehlt — wird via Homebrew installiert..."
    brew install fzf
    ok "fzf installiert"
  fi

  # ════════════════════════════════════════════════════════════════
  #  4. mas (Mac App Store CLI)
  # ════════════════════════════════════════════════════════════════
  step "4/8  mas"
  if command -v mas &>/dev/null; then
    ok "mas bereits installiert ($(mas version))"
  else
    warn "mas fehlt — wird via Homebrew installiert..."
    brew install mas
    ok "mas installiert"
  fi
}

setup_touchid() {
  # ════════════════════════════════════════════════════════════════
  #  5. Touch ID für sudo
  # ════════════════════════════════════════════════════════════════
  step "5/8  Touch ID für sudo"
  # F3: Pfad-Seam (nur Tests). Append statt Überschreiben — fremde PAM-Direktiven
  # in sudo_local bleiben erhalten. Idempotent über die pam_tid.so-Vorabprüfung.
  local sudo_local="${MACUP_SUDO_LOCAL_OVERRIDE:-/etc/pam.d/sudo_local}"
  if grep -q "pam_tid.so" "$sudo_local" 2>/dev/null; then
    ok "Touch ID für sudo bereits aktiv"
  else
    warn "Touch ID für sudo wird eingerichtet (einmalig Passwort nötig)..."
    # führendes \n trennt sicher von evtl. fehlendem trailing-Newline der Bestandsdatei
    printf '\n%s\n' "auth       sufficient     pam_tid.so" | $SUDO tee -a "$sudo_local" > /dev/null
    if grep -q "pam_tid.so" "$sudo_local" 2>/dev/null; then
      ok "Touch ID für sudo aktiviert"
      $SUDO -k
    else
      warn "Touch ID Setup fehlgeschlagen — sudo läuft weiter mit Passwort"
    fi
  fi
}

migrate_legacy() {
  # ════════════════════════════════════════════════════════════════
  #  6. Migration: Alte v0.5-Installation entfernen
  # ════════════════════════════════════════════════════════════════
  step "6/8  Migration aus älteren Versionen"
  # Migration v0.5 → v0.6+: com.micha.updater entfernen
  if [[ -f "$LEGACY_PLIST" ]] || [[ -f "$LEGACY_DAEMON" ]]; then
    warn "v0.5-Installation gefunden ($LEGACY_LABEL) — wird entfernt..."
    echo -e "  ${YELLOW}🔐 Bitte mit Touch ID oder Passwort bestätigen:${NC}"
    if ! $SUDO -v; then
      fail "Authentifizierung fehlgeschlagen."; exit 1
    fi
    if [[ -f "$LEGACY_PLIST" ]]; then
      $SUDO $LAUNCHCTL unload "$LEGACY_PLIST" 2>/dev/null || true
      $SUDO rm -f "$LEGACY_PLIST"
      ok "Entfernt: $LEGACY_PLIST"
    fi
    if [[ -f "$LEGACY_DAEMON" ]]; then
      $SUDO rm -f "$LEGACY_DAEMON"
      ok "Entfernt: $LEGACY_DAEMON"
    fi
    if [[ -f /var/log/micha_updater.log ]]; then
      $SUDO mv /var/log/micha_updater.log /var/log/micha_updater.log.legacy_v0.5 2>/dev/null || true
      ok "Altes Log archiviert: /var/log/micha_updater.log.legacy_v0.5"
    fi
    rm -f /tmp/.micha_update_trigger "$HOME/.micha_update_done" 2>/dev/null || true
  fi
  # Migration v0.6.x → v0.7: alter /tmp-Trigger räumen (Pfad-Wechsel nach $HOME)
  if [[ -f /tmp/.macOSUpdater_trigger ]]; then
    warn "v0.6.x-Trigger in /tmp gefunden — wird geräumt (Pfad jetzt \$HOME)..."
    rm -f /tmp/.macOSUpdater_trigger
    ok "Entfernt: /tmp/.macOSUpdater_trigger"
  fi
  # Migration v0.x → v1.0: Alt-Daemon ch.bigas.OSXforgedUpdater label-keyed ausbooten
  teardown_legacy_daemons
  ok "Migration abgeschlossen — bereit für v1.0.0-Install"
}

deploy_daemon() {
  # ════════════════════════════════════════════════════════════════
  #  7. LaunchDaemon installieren (v1.0.0)
  # ════════════════════════════════════════════════════════════════
  step "7/8  LaunchDaemon ch.bigas.macOSUpdater"
  # Prio-0 Pre-chown-Guard (M-2): beide root-Deploy-Ziele absichern, BEVOR
  # authentifiziert/geschrieben wird (braucht kein sudo). Bei manipuliertem Ziel
  # Abbruch vor dem Touch-ID-Prompt.
  assert_safe_deploy_target "$DAEMON_DIR" dir
  assert_safe_deploy_target "$PLIST_DST"  file
  echo -e "  ${YELLOW}🔐 Bitte mit Touch ID oder Passwort bestätigen:${NC}"
  if ! $SUDO -v; then fail "Authentifizierung fehlgeschlagen."; exit 1; fi

  # Owner-Auflösung: Status der Command-Substitution prüfen — der exit 1
  # im Root-Guard von resolve_install_owner beendet sonst nur die
  # Substitutions-Subshell, nicht deploy_daemon.
  local install_owner
  install_owner=$(resolve_install_owner) || exit 1
  # Defense-in-Depth: nie mit leerem Owner deployen (sonst leerer
  # EXPECTED_OWNER + Müll-WatchPath).
  if [[ -z "$install_owner" ]]; then
    fail "Installierenden User nicht ableitbar (leer) — Installation verweigert."
    exit 1
  fi

  # 1. Daemon-Dir root-owned anlegen (Prio-0: root-owned Chain)
  $SUDO /bin/mkdir -p "$DAEMON_DIR"
  $SUDO /usr/sbin/chown root:wheel "$DAEMON_DIR"
  $SUDO /bin/chmod 755 "$DAEMON_DIR"

  # 2. Prio-0-Hard-Fail (Task 3 befüllt assert_root_owned)
  assert_root_owned "$DAEMON_DIR"

  # 3. _constants.sh co-deployen (Variante B — Daemon sourct sie zur Laufzeit)
  $SUDO /bin/cp "$SCRIPT_DIR/_constants.sh" "$DAEMON_DIR/_constants.sh"
  $SUDO /usr/sbin/chown root:wheel "$DAEMON_DIR/_constants.sh"
  $SUDO /bin/chmod 644 "$DAEMON_DIR/_constants.sh"
  ok "$DAEMON_DIR/_constants.sh"

  # 4. Daemon-Script deployen (+ Owner-Injektion = Task 4)
  $SUDO /bin/cp "$SCRIPT_DIR/macOSUpdater_daemon.sh" "$DAEMON_SCRIPT"
  $SUDO /usr/bin/sed -i '' "s/__INSTALL_OWNER__/${install_owner}/g" "$DAEMON_SCRIPT"
  $SUDO /bin/chmod 755 "$DAEMON_SCRIPT"
  $SUDO /usr/sbin/chown root:wheel "$DAEMON_SCRIPT"
  ok "$DAEMON_SCRIPT"

  # 4b. CLI self-contained co-deployen (Client-Modus: kein setup daneben → kein Drift-Check)
  $SUDO /bin/cp "$SCRIPT_DIR/macOSUpdater_v1.0.0.sh" "$DAEMON_DIR/macOSUpdater_v1.0.0.sh"
  $SUDO /bin/chmod 755 "$DAEMON_DIR/macOSUpdater_v1.0.0.sh"
  $SUDO /usr/sbin/chown root:wheel "$DAEMON_DIR/macOSUpdater_v1.0.0.sh"
  ok "$DAEMON_DIR/macOSUpdater_v1.0.0.sh"

  # 5. Plist deployen + echten WatchPath injizieren
  if [[ -f "$PLIST_DST" ]]; then $SUDO $LAUNCHCTL unload "$PLIST_DST" 2>/dev/null || true; fi
  inject_watch_path "$PLIST_SRC" "$PLIST_DST" "$install_owner"
  $SUDO /bin/chmod 644 "$PLIST_DST"
  $SUDO /usr/sbin/chown root:wheel "$PLIST_DST"
  ok "$PLIST_DST"

  # 6. Laden (load/unload bleibt 2a-Stil; bootstrap-Modernisierung = 2c)
  $SUDO $LAUNCHCTL load "$PLIST_DST"
  ok "Daemon geladen"

  # 7. Log
  $SUDO /usr/bin/touch "$LOG"
  $SUDO /bin/chmod 644 "$LOG"
  ok "$LOG"

  if [[ -f /etc/sudoers.d/mas_update ]]; then
    $SUDO /bin/rm /etc/sudoers.d/mas_update
    ok "Alte sudoers-Regel für mas entfernt"
  fi
}

print_summary() {
  # ── Abschluss ──────────────────────────────────────────────────
  echo ""
  echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${GREEN}  ✅ Installation abgeschlossen!${NC}"
  echo ""
  echo "  Alle Voraussetzungen erfüllt:"
  echo -e "  ${GREEN}✓${NC}  Xcode CLT"
  echo -e "  ${GREEN}✓${NC}  Homebrew"
  echo -e "  ${GREEN}✓${NC}  fzf"
  echo -e "  ${GREEN}✓${NC}  mas"
  echo -e "  ${GREEN}✓${NC}  Touch ID für sudo"
  echo -e "  ${GREEN}✓${NC}  LaunchDaemon ch.bigas.macOSUpdater"
  echo ""
  echo -e "  Jetzt starten: ${CYAN}./macOSUpdater_v1.0.0.sh${NC}"
  echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
  echo ""
}

# Platzhalter-Funktionen (in späteren Tasks befüllt) — leer definiert,
# damit S-LIB-2 grün ist und setup_main sie aufrufen kann:
install_dir_owner_uid() {
  local dir="$1" mapped
  # MACUP_UID_MAP_OVERRIDE: NUR Tests — Datei mit "uid<TAB>pfad"-Zeilen, erlaubt
  # Per-Pfad-UIDs (z.B. Parent=root, Leaf≠root). awk druckt die uid + exit 0 bei
  # Treffer, sonst exit 1 → '&&' greift nicht → Durchfall auf den globalen Override
  # (Map-Miss = KEIN Mapping, NICHT uid 0). In Production NIE setzen.
  if [[ -n "${MACUP_UID_MAP_OVERRIDE:-}" && -f "${MACUP_UID_MAP_OVERRIDE}" ]]; then
    mapped=$(/usr/bin/awk -v p="$dir" -F '\t' '$2==p{print $1; f=1} END{exit !f}' "$MACUP_UID_MAP_OVERRIDE") \
      && { echo "$mapped"; return; }
  fi
  # MACUP_INSTALL_DIR_UID_OVERRIDE: NUR Tests — globaler stat-Override. In Production NIE setzen.
  if [[ -n "${MACUP_INSTALL_DIR_UID_OVERRIDE:-}" ]]; then
    echo "$MACUP_INSTALL_DIR_UID_OVERRIDE"
  else
    /usr/bin/stat -f %u "$dir" 2>/dev/null || echo -1
  fi
}

assert_root_owned() {
  local dir="$1" uid
  uid=$(install_dir_owner_uid "$dir")
  if [[ "$uid" != "0" ]]; then
    fail "Install-Verzeichnis $dir nicht root-owned (uid=$uid) — Installation verweigert (Prio-0-Guard)."
    exit 1
  fi
}

# assert_safe_deploy_target <pfad> <kind>   (kind = dir | file)
# Prio-0-Guard (M-2): verhindert Symlink-Hijack/TOCTOU bei root-Deploy-Zielen,
# BEVOR ein privilegierter Schritt (mkdir/chown/cp/sed/touch) läuft. Braucht selbst
# KEIN sudo (nur stat/[[ -L ]]). Parent muss reales root-owned Verzeichnis sein;
# ein root-owned Parent schliesst das TOCTOU-Fenster (Unprivilegierte können dort
# nichts einfügen/austauschen) und macht Dateien im verifizierten Dir automatisch sicher.
assert_safe_deploy_target() {
  # ACHTUNG: 'path' NICHT als local verwenden — überschreibt zsh $path-Array ($PATH-Footgun).
  local tgt="$1" kind="$2" tgt_parent="${1:h}"
  [[ -L "$tgt_parent" ]] && { fail "Parent $tgt_parent ist ein Symlink — Installation verweigert (Prio-0-Guard)."; exit 1; }
  [[ -d "$tgt_parent" ]] || { fail "Parent $tgt_parent fehlt oder ist kein Verzeichnis — Installation verweigert (Prio-0-Guard)."; exit 1; }
  assert_root_owned "$tgt_parent"
  [[ -L "$tgt" ]] && { fail "Ziel $tgt ist ein Symlink — Installation verweigert (Prio-0-Guard)."; exit 1; }
  if [[ -e "$tgt" ]]; then
    if [[ "$kind" == dir ]]; then
      [[ -d "$tgt" ]] || { fail "$tgt existiert, ist aber kein Verzeichnis — Installation verweigert (Prio-0-Guard)."; exit 1; }
    else
      [[ -f "$tgt" ]] || { fail "$tgt existiert, ist aber keine reguläre Datei — Installation verweigert (Prio-0-Guard)."; exit 1; }
    fi
    assert_root_owned "$tgt"
  fi
}

resolve_install_owner() {
  # MACUP_INSTALL_USER_OVERRIDE: NUR Tests (Default = echter installierender User).
  local owner="${MACUP_INSTALL_USER_OVERRIDE:-$(/usr/bin/id -un)}"
  if [[ "$owner" == "root" ]]; then
    fail "Setup als root gestartet — installierenden User nicht ableitbar. Bitte als normaler User starten (setup nutzt sudo selektiv)."
    exit 1
  fi
  # Defense-in-Depth: der Owner wird per sed in den Root-Daemon UND die plist
  # injiziert. Ungültige Zeichen (/, &, #) würden sed brechen oder Müll in den
  # Root-Daemon schreiben. macOS-Usernamen sind [A-Za-z0-9_.-].
  if [[ ! "$owner" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    fail "Ungültiger Owner-Name '$owner' (nur [A-Za-z0-9_.-] erlaubt) — Installation verweigert."
    exit 1
  fi
  echo "$owner"
}
teardown_legacy_daemons() {
  # Label-keyed Teardown des Alt-Daemons ch.bigas.OSXforgedUpdater. unload-by-plist
  # evict den System-Domain-Eintrag nicht zuverlässig → bootout system/<label>
  # (verhindert verwaisten In-Memory-root-Daemon). Idempotent + re-runbar =
  # zugleich der Recovery-Pfad. OVERRIDE-Seams nur für hermetische Tests.
  local legacy_label="ch.bigas.OSXforgedUpdater"
  local legacy_plist="${MACUP_LEGACY_FU_PLIST_OVERRIDE:-/Library/LaunchDaemons/${legacy_label}.plist}"
  local legacy_daemon="${MACUP_LEGACY_FU_DAEMON_OVERRIDE:-/usr/local/bin/OSXforgedUpdater_daemon.sh}"
  local legacy_log="${MACUP_LEGACY_FU_LOG_OVERRIDE:-/var/log/OSXforgedUpdater.log}"

  if $SUDO $LAUNCHCTL print "system/${legacy_label}" &>/dev/null; then
    warn "Alt-Daemon $legacy_label geladen — wird ausgebootet..."
    $SUDO $LAUNCHCTL bootout "system/${legacy_label}" 2>/dev/null || true
    ok "Ausgebootet: $legacy_label"
  fi
  if [[ -f "$legacy_plist" ]]; then
    $SUDO /bin/rm -f "$legacy_plist"
    ok "Entfernt: $legacy_plist"
  fi
  if [[ -f "$legacy_daemon" ]]; then
    $SUDO /bin/rm -f "$legacy_daemon"
    ok "Entfernt: $legacy_daemon"
  fi
  # Alt-Log archivieren statt löschen (Nichts-wegwerfen-Linie)
  if [[ -f "$legacy_log" ]]; then
    $SUDO /bin/mv "$legacy_log" "${legacy_log}.legacy" 2>/dev/null || true
    ok "Alt-Log archiviert: ${legacy_log}.legacy"
  fi
  rm -f "$HOME/.OSXforgedUpdater_trigger" "$HOME/.OSXforgedUpdater_done" \
        /tmp/.OSXforgedUpdater_trigger 2>/dev/null || true
}

inject_watch_path() {
  local src="$1" dst="$2" owner="$3" home watch
  home=$(/usr/bin/dscl . -read "/Users/$owner" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')
  [[ -z "$home" ]] && home="/Users/$owner"
  watch="${home}/${MACUP_TRIGGER_BASENAME}"
  $SUDO /bin/cp "$src" "$dst"
  # '#' als sed-Delimiter, da der Pfad '/' enthält
  $SUDO /usr/bin/sed -i '' "s#__WATCH_PATH__#${watch}#g" "$dst"
}

setup_applauncher() {
  step "8/8  App-Launcher (Applications)"
  local app_name="macOSUpdater.app"
  local app_base="${MACUP_APP_DIR_OVERRIDE:-/Applications}"
  if [[ ! -d "$app_base" || ! -w "$app_base" ]]; then
    app_base="$HOME/Applications"; /bin/mkdir -p "$app_base" 2>/dev/null
  fi
  local app_dir="$app_base/$app_name"
  local osacompile="${MACUP_OSACOMPILE_OVERRIDE:-/usr/bin/osacompile}"
  if [[ ! -x "$osacompile" ]]; then
    warn "osacompile nicht gefunden — App-Launcher übersprungen (CLI: $DAEMON_DIR/macOSUpdater_v1.0.0.sh)"
    return 0
  fi
  # do script (nicht exec): Quit (q) kehrt zu nutzbarem Prompt zurück (R-1 §5).
  local cli="$DAEMON_DIR/macOSUpdater_v1.0.0.sh"
  local script="tell application \"Terminal\"
    activate
    do script \"clear; '${cli}'\"
end tell"
  /bin/rm -rf "$app_dir" 2>/dev/null
  if ! print -r -- "$script" | "$osacompile" -o "$app_dir" 2>/dev/null; then
    warn "App-Launcher konnte nicht erstellt werden (non-fatal; CLI: $cli)"
    return 0
  fi
  # Icon-Override-Kaskade: Assets.car schlägt applet.icns → entfernen, CFBundleIconName
  # löschen, re-signen, LaunchServices-Cache busten. Alle Schritte non-fatal.
  local icon="${MACUP_APP_ICON_OVERRIDE:-$SCRIPT_DIR/assets/macosupdater.icns}"
  if [[ -f "$icon" ]]; then
    /bin/cp -f "$icon" "$app_dir/Contents/Resources/applet.icns" 2>/dev/null
    /bin/rm -f "$app_dir/Contents/Resources/Assets.car" 2>/dev/null
    /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$app_dir/Contents/Info.plist" 2>/dev/null || true
    /usr/bin/codesign --force --sign - "$app_dir" 2>/dev/null || true
    /usr/bin/touch "$app_dir" 2>/dev/null
    local lsreg="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    [[ -x "$lsreg" ]] && "$lsreg" -f "$app_dir" 2>/dev/null || true
    ok "App-Launcher: $app_dir (eigenes Icon)"
  else
    ok "App-Launcher: $app_dir"
  fi
  return 0
}

setup_main() {
  echo ""
  echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${CYAN}  ⚙️  macOSUpdater v1.0.0 — Einrichtung${NC}"
  echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
  echo ""
  check_prereqs
  setup_touchid
  migrate_legacy
  deploy_daemon
  setup_applauncher
  print_summary
}

# ── Ausführen nur bei direktem Start (nicht beim Sourcen in Tests) ──
if [[ "${MACUP_SETUP_LIB:-0}" != "1" ]]; then
  set -uo pipefail
  setup_main "$@"
fi
