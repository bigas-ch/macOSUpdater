#!/bin/zsh
# ══════════════════════════════════════════════════════════════════
#  macOSUpdater_daemon.sh — v1.0.0 (2026-06-13)
#  Läuft als root via LaunchDaemon — KEIN Passwort nötig.
#  Triggered durch $USER_HOME/.macOSUpdater_trigger
#  Schreibt NDJSON-Output nach /var/log/macOSUpdater.log
# ══════════════════════════════════════════════════════════════════
#
#  v0.7.2 Release-Notes (2026-06-05, macOS 26.5.1):
#    - macos_sec / run_sw_sec ENTFERNT. `softwareupdate
#      --background-critical` ist auf macOS 26 deprecated (nicht mehr
#      in --help) und triggerte nur einen Async-Scan ohne echtes
#      Install (0ms-„Erfolg"). Security-/Config-Data-Updates laufen
#      über `softwareupdate -i -a` (= macos_sw) mit. Action `all`
#      ruft daher nur noch run_sw. `--include-config-data` existiert
#      auf macOS 26 ebenfalls nicht mehr → kein Ersatz-Flag nötig.
#
#  v0.7 Release-Notes:
#    + Log-Rotation: 1 MB Schwelle, 5 Generationen (.1 bis .5)
#    + NDJSON-strukturiertes Logging (jq-pipeable)
#    + Trigger-Pfad nach $USER_HOME/.macOSUpdater_trigger
#      (Defense-in-Depth: FS-Permission als 2. Sicherheitsschicht)
#    + Destruktiver Truncate (`: > $LOG`) entfernt
#    + Variable Uniqueness durchgehend (DAEMON_LOG, USER_HOME, ...)
#
# ══════════════════════════════════════════════════════════════════
#  ENV-Overrides (NUR für Tests; in Production NICHT setzen):
#    MACUP_TRIGGER_OVERRIDE        — abweichender Trigger-Pfad
#    MACUP_LOG_OVERRIDE            — abweichender Log-Pfad
#    MACUP_SOFTWAREUPDATE_OVERRIDE — abweichendes softwareupdate-Binary
#    MACUP_EXPECTED_OWNER_OVERRIDE — abweichender erwarteter Owner-Name
#    MACUP_TEST_MODE=1             — skippt Log-Rotation für vorhersehbare Tests
#    MACUP_CONSTANTS_OVERRIDE      — abweichender Pfad zu _constants.sh (NUR Tests)
#    MACUP_DONE_OVERRIDE          — abweichender Done-Marker-Pfad (NUR Tests)
# ══════════════════════════════════════════════════════════════════

set -u

# ── Prio-0 LPE-Haertung (C-2): Root-PATH festnageln ──────────────────
# Schliesst die PATH-Injection ueber user-writable /opt/homebrew/bin und
# /usr/local/bin (live verifiziert: plist setzt diese als erste PATH-
# Eintraege). Unabhaengig von der plist — der Daemon erzwingt nur root-
# owned System-Verzeichnisse. ALLE externen Kommandos liegen darin.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

# ── Constants laden (Single Source of Truth, Variante B) ─────────────
# Defense-in-Depth (F2): der Root-Daemon sourct eine externe Datei → er MUSS sie
# als self-owned verifizieren (in Produktion läuft er als root → EUID 0 → Constants
# müssen root-owned sein). Schreibbarkeit durch Nicht-root = RCE-as-root. TOCTOU-frei
# analog zur Trigger-Closure: `sysopen O_NOFOLLOW` (Symlink-Reject) → `fstat` auf dem
# fd (Owner der geöffneten Inode == erwartete UID) → der verifizierte Inhalt wird vom
# SELBEN fd gelesen und gesourct (kein Pfad-Re-Resolve zwischen Check und Use → der
# Daemon verteidigt sich selbst, unabhängig vom Deploy-Ort = ehemaliges 2c-Verify-Gate).
# _CONST_EXPECTED_UID default = EUID des Daemons (root in Produktion).
# MACUP_CONSTANTS_*-Overrides NUR für hermetische Tests.
_CONST_FILE="${MACUP_CONSTANTS_OVERRIDE:-$(/usr/bin/dirname "$0")/_constants.sh}"
_CONST_EXPECTED_UID="${MACUP_CONSTANTS_EXPECTED_UID:-$(/usr/bin/id -u)}"
# Exit-Vertrag: 0=ok (stdout=Inhalt) · 2=Symlink (ELOOP) · 3=fehlt/unlesbar
# · 4=fstat scheitert · 5=Owner-Mismatch (stdout=gefundene uid, fürs Logging).
_CONST_OUT="$(/usr/bin/perl -e '
  use Fcntl qw(O_RDONLY O_NOFOLLOW);
  use Errno qw(ELOOP);
  sysopen(my $fh, $ARGV[0], O_RDONLY | O_NOFOLLOW) or do { exit 2 if $!{ELOOP}; exit 3; };
  my @st = stat($fh) or exit 4;
  if ($st[4] != $ARGV[1]) { print $st[4]; exit 5; }
  local $/;
  print scalar <$fh>;
  exit 0;
' "$_CONST_FILE" "$_CONST_EXPECTED_UID" 2>/dev/null)"
_const_rc=$?
case "$_const_rc" in
  2) echo "{\"level\":\"error\",\"event\":\"constants_symlink_rejected\",\"msg\":\"$_CONST_FILE\"}" >&2; exit 1 ;;
  3|4) echo "{\"level\":\"error\",\"event\":\"constants_missing\",\"msg\":\"$_CONST_FILE\"}" >&2; exit 1 ;;
  5) echo "{\"level\":\"error\",\"event\":\"constants_owner_mismatch\",\"msg\":\"owner=$_CONST_OUT expected=$_CONST_EXPECTED_UID file=$_CONST_FILE\"}" >&2; exit 1 ;;
esac
# Inhalt vom verifizierten fd sourcen (nicht den Pfad erneut öffnen → keine TOCTOU-Lücke)
source <(printf '%s' "$_CONST_OUT")
unset _CONST_FILE _CONST_EXPECTED_UID _CONST_OUT _const_rc

EXPECTED_OWNER_NAME="${MACUP_EXPECTED_OWNER_OVERRIDE:-__INSTALL_OWNER__}"
USER_HOME=$(/usr/bin/dscl . -read "/Users/$EXPECTED_OWNER_NAME" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')
TRIGGER="${MACUP_TRIGGER_OVERRIDE:-${USER_HOME}/${MACUP_TRIGGER_BASENAME}}"
DAEMON_LOG="${MACUP_LOG_OVERRIDE:-$MACUP_LOG}"
SOFTWAREUPDATE="${MACUP_SOFTWAREUPDATE_OVERRIDE:-/usr/sbin/softwareupdate}"
TEST_MODE="${MACUP_TEST_MODE:-0}"

LOG_MAX_SIZE=1048576   # 1 MB
LOG_GENERATIONS=5      # .1 bis .5

# Run-State (kontextuelle Felder für NDJSON)
ACTION=""
TRIGGER_UID=""
RUN_START_EPOCH=$(/bin/date +%s)

# ── Log-Rotation ─────────────────────────────────────────────────────
rotate_log_if_needed() {
  local log="$1"
  [[ -f "$log" ]] || return 0
  local size
  size=$(/usr/bin/stat -f "%z" "$log" 2>/dev/null || echo 0)
  (( size > LOG_MAX_SIZE )) || return 0
  # Rotate: .4 → .5, .3 → .4, ..., current → .1 (älteste .5 wird überschrieben/gelöscht)
  local i
  for i in $(/usr/bin/seq $((LOG_GENERATIONS - 1)) -1 1); do
    [[ -f "$log.$i" ]] && /bin/mv -f "$log.$i" "$log.$((i+1))" 2>/dev/null || true
  done
  /bin/mv -f "$log" "$log.1" 2>/dev/null || true
}

[[ "$TEST_MODE" != "1" ]] && rotate_log_if_needed "$DAEMON_LOG"

# Sicherstellen dass Log existiert + lesbar (best-effort, root in Production)
/usr/bin/touch "$DAEMON_LOG" 2>/dev/null || true
/bin/chmod 644 "$DAEMON_LOG" 2>/dev/null || true

# ── NDJSON-Logging ───────────────────────────────────────────────────
# Schema (v0.7.1): {"ts":"<ISO8601 UTC>","level":"info|warn|error",
#                   "event":"<name>","action":"<trigger-action>",
#                   "step":"<concrete-step>","uid":<int>,
#                   "duration_ms":<int>,"msg":"<text>"}
# Neu in v0.7.1: separate `step`-Feld erlaubt jq-Filter wie
#                `jq 'select(.step=="macos_sw")'`. Vorher war nur
#                action="all" verfügbar — mehrdeutig bei sub-steps.
json_escape() {
  printf '%s' "$1" | /usr/bin/sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
    | /usr/bin/tr -d '\r' | /usr/bin/tr '\n\t' ' '
}

# Aktueller Step (wird von run_step_timed gesetzt). Leer = kein Step-Kontext.
CURRENT_STEP=""

log_event() {
  local level="$1" event="$2" msg="${3:-}" duration_ms="${4:-}"
  local ts
  ts=$(/bin/date -u +"%Y-%m-%dT%H:%M:%SZ")
  local out="{\"ts\":\"$ts\",\"level\":\"$level\",\"event\":\"$event\""
  [[ -n "$ACTION" ]]        && out+=",\"action\":\"$ACTION\""
  [[ -n "$CURRENT_STEP" ]]  && out+=",\"step\":\"$CURRENT_STEP\""
  [[ -n "$TRIGGER_UID" ]]   && out+=",\"uid\":$TRIGGER_UID"
  [[ -n "$duration_ms" ]]   && out+=",\"duration_ms\":$duration_ms"
  [[ -n "$msg" ]]           && out+=",\"msg\":\"$(json_escape "$msg")\""
  out+="}"
  echo "$out"
}

log_event "info" "daemon_started" "v1.0.0 daemon awakened by trigger"

# ── TOCTOU-Closure: Owner-Check + Read auf EINEM Deskriptor ──────────
# Der Trigger liegt im user-eigenen $HOME → der User kann ihn zwischen Check
# und Use durch einen Symlink/andere Inode ersetzen. Drei separate
# pfadbasierte Ops ([[ -L ]], stat, cat) re-resolven den Pfad je neu → TOCTOU.
# Stattdessen EINMAL `sysopen O_NOFOLLOW` (lehnt Symlink atomar ab) → `fstat`
# auf dem fd (Owner der geöffneten Inode) → read vom selben fd. Check und Use
# treffen dieselbe Inode → kein Fenster. (zsh hat kein O_NOFOLLOW; daher die
# perl-Closure mit Absolut-Pfad, konsistent zur C-2-PATH-Härtung.)
EXPECTED_UID="$(/usr/bin/id -u "$EXPECTED_OWNER_NAME" 2>/dev/null)"

# Exit-Vertrag: 0=ok (stdout=Content) · 2=Symlink (ELOOP) · 3=fehlt/unlesbar
# · 4=fstat scheitert · 6=EXPECTED_UID unauflösbar · 5=UID-Mismatch (stdout=
# gefundene uid, fürs Logging). Präzedenz wie im Original: Symlink → fehlt →
# (Trigger existiert →) Owner-unauflösbar → Mismatch. Die unresolvable-Prüfung
# liegt daher IN der Closure (nach fstat), nicht davor.
CLOSURE_OUT="$(/usr/bin/perl -e '
  use Fcntl qw(O_RDONLY O_NOFOLLOW);
  use Errno qw(ELOOP);
  sysopen(my $fh, $ARGV[0], O_RDONLY | O_NOFOLLOW) or do { exit 2 if $!{ELOOP}; exit 3; };
  my @st = stat($fh) or exit 4;
  exit 6 if $ARGV[1] eq "";
  if ($st[4] != $ARGV[1]) { print $st[4]; exit 5; }
  local $/;
  print scalar <$fh>;
  exit 0;
' "$TRIGGER" "$EXPECTED_UID" 2>/dev/null)"
closure_rc=$?

case "$closure_rc" in
  2)
    log_event "error" "trigger_symlink_rejected" "Trigger ist ein Symlink — abgelehnt: $TRIGGER"
    /bin/rm -f "$TRIGGER" 2>/dev/null || true
    exit 1 ;;
  3|4)
    log_event "error" "trigger_missing" "Trigger nicht lesbar oder existiert nicht: $TRIGGER"
    exit 1 ;;
  6)
    log_event "error" "expected_owner_unresolvable" "id -u failed for '$EXPECTED_OWNER_NAME'"
    /bin/rm -f "$TRIGGER" 2>/dev/null || true
    exit 1 ;;
  5)
    TRIGGER_UID="$CLOSURE_OUT"
    log_event "error" "owner_mismatch" "trigger_uid=$TRIGGER_UID expected_uid=$EXPECTED_UID ($EXPECTED_OWNER_NAME)"
    /bin/rm -f "$TRIGGER" 2>/dev/null || true
    exit 1 ;;
esac

# Owner auf der geöffneten Inode validiert == EXPECTED_UID → fürs uid-Log-Feld.
TRIGGER_UID="$EXPECTED_UID"

# ── DONE_MARKER + Action (Content stammt aus der Closure) ────────────
DONE_MARKER="${MACUP_DONE_OVERRIDE:-${USER_HOME}/${MACUP_DONE_BASENAME}}"
/bin/rm -f "$DONE_MARKER" 2>/dev/null || true

ACTION="$(printf '%s' "$CLOSURE_OUT" | /usr/bin/tr -d '[:space:]')"
/bin/rm -f "$TRIGGER" 2>/dev/null || true

log_event "info" "owner_validated" "trigger accepted, processing action"

# ── Update-Funktionen mit Duration-Tracking + step-Tag (v0.7.1) ─────
# step_id ist der jq-filterbare Bezeichner (z.B. "macos_sw").
# step_cmd ist das menschenlesbare Kommando für msg-Feld.
run_step_timed() {
  local step_id="$1" step_cmd="$2"
  shift 2
  local step_start step_end step_duration step_rc
  CURRENT_STEP="$step_id"
  log_event "info" "step_started" "$step_cmd"
  step_start=$(/bin/date +%s)
  "$@" 2>&1
  step_rc=$?
  step_end=$(/bin/date +%s)
  step_duration=$(( (step_end - step_start) * 1000 ))
  if (( step_rc == 0 )); then
    log_event "info" "step_completed" "$step_cmd" "$step_duration"
  else
    log_event "error" "step_failed" "$step_cmd (rc=$step_rc)" "$step_duration"
  fi
  CURRENT_STEP=""
  return $step_rc
}

# Done-Marker (User-eigen) mit Inhalt schreiben — printf statt touch, damit der
# Marker den Status trägt. Zwei Aufrufstellen: regulär nach dem case (action_rc)
# UND vor dem Reboot (Sentinel, s. run_sw_restart). $DONE_MARKER/$EXPECTED_OWNER_NAME
# sind beim Aufruf (nach der case-Dispatch) gesetzt.
write_done_marker() {
  /usr/bin/printf '%s' "$1" > "$DONE_MARKER" 2>/dev/null || true
  /bin/chmod 644 "$DONE_MARKER" 2>/dev/null || true
  /usr/sbin/chown "$EXPECTED_OWNER_NAME" "$DONE_MARKER" 2>/dev/null || true
}

run_sw() { run_step_timed "macos_sw" "softwareupdate -i -a" "$SOFTWAREUPDATE" -i -a; }
run_sw_restart() {
  # Der Reboot (-R) killt den Daemon, bevor er unten action_rc schreiben kann.
  # Daher VORHER einen 'reboot'-Erfolgs-Sentinel setzen — er überlebt den Reboot.
  # Bleibt der Reboot aus (Install-Fehler vor -R), überschreibt der reguläre
  # action_rc-Write den Marker danach mit dem echten rc.
  write_done_marker "reboot"
  run_step_timed "macos_sw_restart" "softwareupdate -i -a -R" "$SOFTWAREUPDATE" -i -a -R
}

# ── Action-Whitelist (explizit, kein Default-Pass) ───────────────────
case "$ACTION" in
  macos_sw)         run_sw ;;
  macos_sw_restart) run_sw_restart ;;
  all)              run_sw ;;
  *)
    log_event "error" "unknown_action" "Action '$ACTION' nicht in Whitelist"
    exit 1
    ;;
esac
action_rc=$?

# ── Done-Marker schreiben (User-eigen) ───────────────────────────────
# Der Marker trägt den Action-Exit-Code statt nur zu existieren: 0=Erfolg,
# ≠0=fehlgeschlagenes-aber-beendetes Update. Die CLI (trigger_daemon) liest den
# Inhalt — fehlend/leer = Timeout/Crash bzw. Legacy-touch, numerisch ≠0 =
# Update-Fehler. Schliesst die Silent-Failure (vorher: unbedingter touch → die
# CLI meldete jeden beendeten Lauf als Erfolg, auch bei rc≠0). Reboot-Pfad:
# der 'reboot'-Sentinel aus run_sw_restart steht hier nur dann noch, wenn der
# Reboot ausblieb — dann ist action_rc der echte rc und überschreibt ihn.
write_done_marker "$action_rc"

local_total_duration=$(( ($(/bin/date +%s) - RUN_START_EPOCH) * 1000 ))
log_event "info" "daemon_completed" "all tasks finished" "$local_total_duration"
