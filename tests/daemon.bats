#!/usr/bin/env bats
# ══════════════════════════════════════════════════════════════════
#  daemon.bats — Tests für macOSUpdater_daemon.sh (v1.0+)
#
#  Coverage:
#    T-001 Positive Pfade (alle 4 Actions, NDJSON-Output)
#    T-002 Negative Pfade (Owner-Mismatch, unknown Action, leerer Trigger)
#    T-003 Edge Cases (kein Trigger, unbekannter Owner)
#    T-004 Regression (DONE_MARKER, Trigger-Cleanup)
#    T-NJ  NDJSON-Format-Validität
#    T-LR  Log-Rotation-Schwelle
# ══════════════════════════════════════════════════════════════════

setup() {
  DAEMON_SCRIPT="${BATS_TEST_DIRNAME}/../macOSUpdater_daemon.sh"
  TEST_TRIGGERS=()
  TEST_LOGS=()
  TEST_DONES=()
  [[ -x "$DAEMON_SCRIPT" ]]
}

teardown() {
  for trigger in "${TEST_TRIGGERS[@]}"; do
    rm -f "$trigger" 2>/dev/null || true
  done
  for log in "${TEST_LOGS[@]}"; do
    rm -f "$log" "$log".{1,2,3,4,5} 2>/dev/null || true
  done
  for done in "${TEST_DONES[@]}"; do
    rm -f "$done" 2>/dev/null || true
  done
}

make_trigger() {
  local action="$1"
  local trigger
  trigger=$(mktemp /tmp/.osxfu_test.XXXXXX)
  if [[ -n "$action" ]]; then
    echo "$action" > "$trigger"
  else
    : > "$trigger"
  fi
  TEST_TRIGGERS+=("$trigger")
  echo "$trigger"
}

make_log() {
  local log
  log=$(mktemp /tmp/.osxfu_testlog.XXXXXX)
  TEST_LOGS+=("$log")
  echo "$log"
}

# Done-Marker-Pfad fürs Test (via MACUP_DONE_OVERRIDE). Startet absent —
# der Daemon soll ihn selbst anlegen und mit dem Action-rc befüllen.
make_done() {
  local done
  done=$(mktemp /tmp/.osxfu_testdone.XXXXXX)
  rm -f "$done"
  TEST_DONES+=("$done")
  echo "$done"
}

run_daemon() {
  local trigger="$1" log="${2:-}"
  # Done-Marker auf Temp umlenken — sonst schreibt der Daemon real nach
  # $HOME/.macOSUpdater_done (USER_HOME = echtes Home im Test).
  local done; done=$(make_done)
  if [[ -n "$log" ]]; then
    MACUP_TEST_MODE=1 \
    MACUP_EXPECTED_OWNER_OVERRIDE="$(id -un)" \
    MACUP_TRIGGER_OVERRIDE="$trigger" \
    MACUP_LOG_OVERRIDE="$log" \
    MACUP_DONE_OVERRIDE="$done" \
    MACUP_SOFTWAREUPDATE_OVERRIDE=/usr/bin/true \
    run "$DAEMON_SCRIPT"
  else
    MACUP_TEST_MODE=1 \
    MACUP_EXPECTED_OWNER_OVERRIDE="$(id -un)" \
    MACUP_TRIGGER_OVERRIDE="$trigger" \
    MACUP_DONE_OVERRIDE="$done" \
    MACUP_SOFTWAREUPDATE_OVERRIDE=/usr/bin/true \
    run "$DAEMON_SCRIPT"
  fi
}

# ══════════════════════════════════════════════════════════════════
#  T-001 Positive Pfade — NDJSON Events
# ══════════════════════════════════════════════════════════════════

@test "T-001a: Action 'macos_sw' produziert step_completed event" {
  trigger=$(make_trigger "macos_sw")
  run_daemon "$trigger"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | grep -cF '"event":"step_completed"')" -ge 1 ]
  [ "$(printf '%s' "$output" | grep -cF '"event":"daemon_completed"')" -ge 1 ]
  [ ! -f "$trigger" ]
}

@test "T-001b: Action 'macos_sec' wird abgelehnt (entfernt in v0.7.2)" {
  # macos_sec / --background-critical wurde entfernt (macOS 26 deprecated).
  # Action darf nicht mehr in der Whitelist sein → unknown_action + exit 1.
  trigger=$(make_trigger "macos_sec")
  run_daemon "$trigger"
  [ "$status" -ne 0 ]
  [ "$(printf '%s' "$output" | grep -cF '"event":"unknown_action"')" -ge 1 ]
  [ "$(printf '%s' "$output" | grep -cF 'background-critical')" -eq 0 ]
}

@test "T-001c: Action 'all' triggert genau einen Step (nur macos_sw)" {
  trigger=$(make_trigger "all")
  run_daemon "$trigger"
  [ "$status" -eq 0 ]
  local count
  count=$(echo "$output" | grep -c '"event":"step_completed"')
  [ "$count" -eq 1 ]
}

@test "T-001d: Action 'macos_sw_restart' wird akzeptiert" {
  trigger=$(make_trigger "macos_sw_restart")
  run_daemon "$trigger"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | grep -cF '"event":"step_completed"')" -ge 1 ]
  [ "$(printf '%s' "$output" | grep -cF -- '-R')" -ge 1 ]
}

# ══════════════════════════════════════════════════════════════════
#  T-002 Negative Pfade — Sicherheits-Validation
# ══════════════════════════════════════════════════════════════════

@test "T-002a: Owner-Mismatch → owner_mismatch event + exit 1" {
  trigger=$(make_trigger "macos_sw")
  MACUP_TEST_MODE=1 \
  MACUP_TRIGGER_OVERRIDE="$trigger" \
  MACUP_EXPECTED_OWNER_OVERRIDE=root \
  MACUP_SOFTWAREUPDATE_OVERRIDE=/usr/bin/true \
  run "$DAEMON_SCRIPT"
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | grep -cF '"event":"owner_mismatch"')" -ge 1 ]
  [ "$(printf '%s' "$output" | grep -cF '"level":"error"')" -ge 1 ]
  [ ! -f "$trigger" ]
}

@test "T-002b: Unbekannte Action → unknown_action event + exit 1" {
  trigger=$(make_trigger "evil_command")
  run_daemon "$trigger"
  [ "$status" -eq 1 ]
  [[ "$output" == *'"event":"unknown_action"'* ]]
}

@test "T-002c: Leerer Trigger → unknown_action event" {
  trigger=$(make_trigger "")
  run_daemon "$trigger"
  [ "$status" -eq 1 ]
  [[ "$output" == *'"event":"unknown_action"'* ]]
}

@test "T-002d: Shell-injection ('all;rm-rf/') wird abgelehnt" {
  trigger=$(make_trigger "all;rm-rf/")
  run_daemon "$trigger"
  [ "$status" -eq 1 ]
  [[ "$output" == *'"event":"unknown_action"'* ]]
}

# ══════════════════════════════════════════════════════════════════
#  T-003 Edge Cases
# ══════════════════════════════════════════════════════════════════

@test "T-003a: Nicht existenter Trigger → trigger_missing event" {
  fake_trigger="/tmp/.nonexistent_osxfu_$$"
  rm -f "$fake_trigger"
  MACUP_TEST_MODE=1 \
  MACUP_TRIGGER_OVERRIDE="$fake_trigger" \
  MACUP_SOFTWAREUPDATE_OVERRIDE=/usr/bin/true \
  run "$DAEMON_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *'"event":"trigger_missing"'* ]]
}

@test "T-003b: Unbekannter EXPECTED_OWNER → expected_owner_unresolvable event" {
  trigger=$(make_trigger "macos_sw")
  MACUP_TEST_MODE=1 \
  MACUP_TRIGGER_OVERRIDE="$trigger" \
  MACUP_EXPECTED_OWNER_OVERRIDE="nonexistent_user_xyz_$$" \
  MACUP_SOFTWAREUPDATE_OVERRIDE=/usr/bin/true \
  run "$DAEMON_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *'"event":"expected_owner_unresolvable"'* ]]
}

@test "T-003c: Trigger mit Whitespace wird normalisiert" {
  trigger=$(make_trigger "")
  printf "  macos_sw  \n" > "$trigger"
  run_daemon "$trigger"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"event":"step_completed"'* ]]
}

# ══════════════════════════════════════════════════════════════════
#  T-004 Regression — Cleanup, Owner-First
# ══════════════════════════════════════════════════════════════════

@test "T-004a: Owner-Validation läuft VOR Action-Read" {
  trigger=$(make_trigger "evil_command")
  MACUP_TEST_MODE=1 \
  MACUP_TRIGGER_OVERRIDE="$trigger" \
  MACUP_EXPECTED_OWNER_OVERRIDE=root \
  MACUP_SOFTWAREUPDATE_OVERRIDE=/usr/bin/true \
  run "$DAEMON_SCRIPT"
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | grep -cF '"event":"owner_mismatch"')" -ge 1 ]
  [ "$(printf '%s' "$output" | grep -cF '"event":"unknown_action"')" -eq 0 ]
}

@test "T-004b: Erfolgreicher Run räumt Trigger auf" {
  trigger=$(make_trigger "macos_sw")
  run_daemon "$trigger"
  [ "$status" -eq 0 ]
  [ ! -f "$trigger" ]
}

@test "T-004c: Owner-Mismatch räumt Trigger auf" {
  trigger=$(make_trigger "macos_sw")
  MACUP_TEST_MODE=1 \
  MACUP_TRIGGER_OVERRIDE="$trigger" \
  MACUP_EXPECTED_OWNER_OVERRIDE=root \
  MACUP_SOFTWAREUPDATE_OVERRIDE=/usr/bin/true \
  run "$DAEMON_SCRIPT"
  [ ! -f "$trigger" ]
}

@test "T-004d: softwareupdate-Mock-Failure produziert step_failed event" {
  trigger=$(make_trigger "macos_sw")
  done=$(make_done)
  MACUP_TEST_MODE=1 \
  MACUP_EXPECTED_OWNER_OVERRIDE="$(id -un)" \
  MACUP_TRIGGER_OVERRIDE="$trigger" \
  MACUP_DONE_OVERRIDE="$done" \
  MACUP_SOFTWAREUPDATE_OVERRIDE=/usr/bin/false \
  run "$DAEMON_SCRIPT"
  [ "$(printf '%s' "$output" | grep -cF '"event":"step_failed"')" -ge 1 ]
  [ "$(printf '%s' "$output" | grep -cF '"event":"daemon_completed"')" -ge 1 ]
}

@test "T-004e: DONE_MARKER trägt rc=0 bei Update-Erfolg (Mock /usr/bin/true)" {
  trigger=$(make_trigger "macos_sw")
  done=$(make_done)
  MACUP_TEST_MODE=1 \
  MACUP_EXPECTED_OWNER_OVERRIDE="$(id -un)" \
  MACUP_TRIGGER_OVERRIDE="$trigger" \
  MACUP_DONE_OVERRIDE="$done" \
  MACUP_SOFTWAREUPDATE_OVERRIDE=/usr/bin/true \
  run "$DAEMON_SCRIPT"
  [ -f "$done" ]
  [ "$(cat "$done")" = "0" ]
}

@test "T-004f: DONE_MARKER trägt rc≠0 bei Update-Failure (Mock /usr/bin/false)" {
  # Kern der Silent-Failure-Härtung: ein fehlgeschlagenes-aber-beendetes Update
  # muss sich im Marker-Inhalt niederschlagen, damit die CLI es als Fehler liest.
  trigger=$(make_trigger "macos_sw")
  done=$(make_done)
  MACUP_TEST_MODE=1 \
  MACUP_EXPECTED_OWNER_OVERRIDE="$(id -un)" \
  MACUP_TRIGGER_OVERRIDE="$trigger" \
  MACUP_DONE_OVERRIDE="$done" \
  MACUP_SOFTWAREUPDATE_OVERRIDE=/usr/bin/false \
  run "$DAEMON_SCRIPT"
  [ -f "$done" ]
  [ "$(cat "$done")" = "1" ]
}

@test "T-004g: macos_sw_restart schreibt 'reboot'-Sentinel VOR softwareupdate -R" {
  # Der echte Reboot (-R) killt den Daemon, bevor er den rc-Marker schreibt.
  # Daher muss VOR dem softwareupdate-Aufruf ein Erfolgs-Sentinel im Marker
  # stehen. Der Probe-Mock gibt den Marker-Inhalt ZUR AUFRUFZEIT aus → "reboot".
  trigger=$(make_trigger "macos_sw_restart")
  done=$(make_done)
  probe=$(mktemp /tmp/.osxfu_probe.XXXXXX)
  TEST_DONES+=("$probe")
  cat > "$probe" <<'PROBE'
#!/bin/sh
cat "$MACUP_DONE_OVERRIDE" 2>/dev/null
PROBE
  chmod +x "$probe"
  MACUP_TEST_MODE=1 \
  MACUP_EXPECTED_OWNER_OVERRIDE="$(id -un)" \
  MACUP_TRIGGER_OVERRIDE="$trigger" \
  MACUP_DONE_OVERRIDE="$done" \
  MACUP_SOFTWAREUPDATE_OVERRIDE="$probe" \
  run "$DAEMON_SCRIPT"
  [[ "$output" == *"reboot"* ]]
}

# ══════════════════════════════════════════════════════════════════
#  T-TOC — TOCTOU-Closure: atomarer O_NOFOLLOW-fd-Read (#3, Prompt Z.120)
# ══════════════════════════════════════════════════════════════════

@test "T-TOC-1: Trigger-Read ist eine atomare O_NOFOLLOW-fd-Closure (kein stat/cat-Pfad-Reresolve)" {
  # Check und Use teilen einen Deskriptor (sysopen O_NOFOLLOW → fstat → read)
  # statt den Pfad 3× separat aufzulösen ([[ -L ]], stat -f %u, cat) → kein
  # TOCTOU-Fenster. Strukturell prüfbar: die Closure ist da, die alten
  # pfadbasierten Trigger-Ops sind weg.
  grep -qF "O_NOFOLLOW" "$DAEMON_SCRIPT"
  grep -qF "sysopen" "$DAEMON_SCRIPT"
  # Negationen als run/[status] — nackte `! grep` an Nicht-End-Position
  # entkommt der bats-errexit (s. Memory feedback-bats-last-command-assertion).
  run grep -qE '/usr/bin/stat[[:space:]]+-f[[:space:]]+"%u"[[:space:]]+"\$TRIGGER"' "$DAEMON_SCRIPT"; [ "$status" -ne 0 ]
  run grep -qF '/bin/cat "$TRIGGER"' "$DAEMON_SCRIPT"; [ "$status" -ne 0 ]
}

@test "T-TOC-2: Symlink-Trigger wird abgelehnt, Content nie verarbeitet" {
  # Angreifer ersetzt den user-eigenen Trigger durch einen Symlink auf eine
  # valide Action-Datei. O_NOFOLLOW lehnt beim Öffnen ab (ELOOP), bevor gelesen
  # wird → trigger_symlink_rejected, kein step_completed.
  local target; target=$(make_trigger "macos_sw")
  local link; link=$(mktemp -u /tmp/.osxfu_link.XXXXXX)
  ln -s "$target" "$link"
  TEST_TRIGGERS+=("$link")
  run_daemon "$link"
  local out="$output"
  # grep -c + [ ] statt [[ ]] — [[ ]] entkommt an Nicht-End-Position der
  # bats-errexit (false green). Siehe Memory feedback-bats-last-command-assertion.
  [ "$status" -ne 0 ]
  [ "$(printf '%s' "$out" | grep -cF '"event":"trigger_symlink_rejected"')" -ge 1 ]
  [ "$(printf '%s' "$out" | grep -cF '"event":"step_completed"')" -eq 0 ]
}

@test "T-TOC-3: Echter fremd-owned Trigger (root-owned, SIP) → owner_mismatch vor Read" {
  # Genuine Angreifer-Seite (NICHT der geforcte EXPECTED_OWNER-Override): ein
  # real fremd-owned File als Trigger. fstat auf dem geöffneten fd lehnt den
  # Owner ab, BEVOR Content gelesen wird → owner_mismatch, nie unknown_action.
  # Vehikel SIP-geschützt → der Daemon-rm-Pfad ist auch als root inert.
  local foreign="/System/Library/CoreServices/SystemVersion.plist"
  [ -f "$foreign" ] || skip "Foreign-UID-Vehikel fehlt: $foreign"
  MACUP_TEST_MODE=1 \
  MACUP_EXPECTED_OWNER_OVERRIDE="$(id -un)" \
  MACUP_TRIGGER_OVERRIDE="$foreign" \
  MACUP_DONE_OVERRIDE="$(make_done)" \
  MACUP_SOFTWAREUPDATE_OVERRIDE=/usr/bin/true \
  run "$DAEMON_SCRIPT"
  local out="$output"
  # grep -c + [ ] statt [[ ]] (s. T-TOC-2): owner_mismatch muss feuern, der
  # fremd-Content darf NIE als Action gelesen werden (kein unknown_action aus
  # dem Plist-Inhalt, kein step_completed).
  [ "$status" -ne 0 ]
  [ "$(printf '%s' "$out" | grep -cF '"event":"owner_mismatch"')" -ge 1 ]
  [ "$(printf '%s' "$out" | grep -cF '"event":"unknown_action"')" -eq 0 ]
  [ "$(printf '%s' "$out" | grep -cF '"event":"step_completed"')" -eq 0 ]
}

# ══════════════════════════════════════════════════════════════════
#  T-NJ — NDJSON-Format-Validität
# ══════════════════════════════════════════════════════════════════

@test "T-NJ-1: Jede JSON-Zeile ist valides JSON (jq-parsbar)" {
  trigger=$(make_trigger "macos_sw")
  run_daemon "$trigger"
  [ "$status" -eq 0 ]
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" != \{* ]] && continue
    echo "$line" | jq -e . >/dev/null
  done <<< "$output"
}

@test "T-NJ-2: NDJSON enthält Pflicht-Felder ts + level + event" {
  trigger=$(make_trigger "macos_sw")
  run_daemon "$trigger"
  while IFS= read -r line; do
    [[ "$line" != \{* ]] && continue
    echo "$line" | jq -e '.ts and .level and .event' >/dev/null
  done <<< "$output"
}

@test "T-NJ-3: ts-Format ist ISO8601 UTC" {
  trigger=$(make_trigger "macos_sw")
  run_daemon "$trigger"
  local first_ts
  first_ts=$(echo "$output" | grep '^{' | head -1 | jq -r '.ts')
  [[ "$first_ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "T-NJ-4: step_completed-Events haben duration_ms-Feld" {
  trigger=$(make_trigger "macos_sw")
  run_daemon "$trigger"
  echo "$output" | grep '"event":"step_completed"' | jq -e '.duration_ms' >/dev/null
}

@test "T-NJ-5: step_started/completed-Events haben step-Feld (v0.7.1)" {
  # Schema-Erweiterung: separates 'step'-Feld erlaubt jq-Filter wie
  # 'select(.step=="macos_sw")'. Vorher war step nur im msg-String.
  trigger=$(make_trigger "macos_sw")
  run_daemon "$trigger"
  # step_started + step_completed müssen step:"macos_sw" enthalten
  echo "$output" | grep '"event":"step_started"' | jq -e '.step == "macos_sw"' >/dev/null
  echo "$output" | grep '"event":"step_completed"' | jq -e '.step == "macos_sw"' >/dev/null
}

@test "T-NJ-6: action='all' triggert step-Feld nur macos_sw (kein macos_sec)" {
  # Seit v0.7.2: action=all = nur run_sw. macos_sec entfernt — darf im
  # step-Feld nicht mehr auftauchen.
  trigger=$(make_trigger "all")
  run_daemon "$trigger"
  local sw_count sec_count
  sw_count=$(echo "$output" | grep '"event":"step_completed"' | jq -e '.step == "macos_sw"' 2>/dev/null | grep -c "true")
  # grep -c liefert Exit 1 bei 0 Treffern → || true, sonst failt die Assignment-Zeile
  sec_count=$(echo "$output" | grep '"event":"step_completed"' | jq -e '.step == "macos_sec"' 2>/dev/null | grep -c "true" || true)
  [ "$sw_count" -eq 1 ]
  [ "$sec_count" -eq 0 ]
}

# ══════════════════════════════════════════════════════════════════
#  T-LR — Log-Rotation
# ══════════════════════════════════════════════════════════════════

@test "T-LR-1: Bestehender Log unter 1MB wird NICHT rotiert" {
  trigger=$(make_trigger "macos_sw")
  log=$(make_log)
  echo "small initial content" > "$log"
  MACUP_TRIGGER_OVERRIDE="$trigger" \
  MACUP_LOG_OVERRIDE="$log" \
  MACUP_SOFTWAREUPDATE_OVERRIDE=/usr/bin/true \
  run "$DAEMON_SCRIPT"
  [ ! -f "$log.1" ]
}

@test "T-LR-2: Log über 1MB wird rotiert nach .1" {
  trigger=$(make_trigger "macos_sw")
  log=$(make_log)
  dd if=/dev/zero of="$log" bs=1024 count=1100 2>/dev/null
  MACUP_TRIGGER_OVERRIDE="$trigger" \
  MACUP_LOG_OVERRIDE="$log" \
  MACUP_SOFTWAREUPDATE_OVERRIDE=/usr/bin/true \
  run "$DAEMON_SCRIPT"
  [ -f "$log.1" ]
}
