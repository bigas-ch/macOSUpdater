#!/usr/bin/env bats
# ══════════════════════════════════════════════════════════════════
#  security.bats — Prio-0 LPE-Härtungs-Tests für macOSUpdater_daemon.sh
#
#  T-SEC-001  PATH-Injection (C-2): Daemon ignoriert user-writable PATH
#  T-SEC-002  Symlink-Trigger wird abgelehnt bevor Inhalt gelesen wird
#  T-SEC-003  Daemon lehnt symlinked _constants.sh ab (Source-Guard)
#  T-SEC-004  Daemon-Versions-String ist v1.0.0
#  T-SEC-005  Daemon lehnt _constants.sh mit fremdem Owner ab (F2)
#
#  Hermetisch: führt den echten Daemon via MACUP_*-Overrides aus, keine
#  Live-System-Berührung. Modell nach daemon.bats.
# ══════════════════════════════════════════════════════════════════

setup() {
  DAEMON_SCRIPT="${BATS_TEST_DIRNAME}/../macOSUpdater_daemon.sh"
  TEST_TRIGGERS=()
  TEST_DIRS=()
  [[ -x "$DAEMON_SCRIPT" ]]
}

teardown() {
  for t in "${TEST_TRIGGERS[@]}"; do rm -f "$t" 2>/dev/null || true; done
  for d in "${TEST_DIRS[@]}"; do rm -rf "$d" 2>/dev/null || true; done
}

make_trigger() {
  local action="$1" trigger
  trigger=$(mktemp /tmp/.macup_sec.XXXXXX)
  [[ -n "$action" ]] && echo "$action" > "$trigger" || : > "$trigger"
  TEST_TRIGGERS+=("$trigger")
  echo "$trigger"
}

@test "T-SEC-001: Daemon ignoriert user-writable PATH-Eintrag (C-2 LPE)" {
  evil_dir=$(mktemp -d /tmp/.macup_evil.XXXXXX)
  TEST_DIRS+=("$evil_dir")
  marker="$evil_dir/PWNED"
  # Boesartiges 'date' (date wird im Daemon schon vor jeder Validierung
  # aufgerufen, Z.50). Es schreibt einen Marker und delegiert ans echte date.
  cat > "$evil_dir/date" <<EOF
#!/bin/bash
touch "$marker"
exec /bin/date "\$@"
EOF
  chmod +x "$evil_dir/date"

  trigger=$(make_trigger "macos_sw")
  PATH="$evil_dir:$PATH" \
  MACUP_TEST_MODE=1 \
  MACUP_EXPECTED_OWNER_OVERRIDE="$(id -un)" \
  MACUP_TRIGGER_OVERRIDE="$trigger" \
  MACUP_SOFTWAREUPDATE_OVERRIDE=/usr/bin/true \
  run "$DAEMON_SCRIPT"

  # Marker-Existenz VOR dem teardown auswerten
  marker_present=1
  [[ -f "$marker" ]] || marker_present=0

  [ "$status" -eq 0 ]
  # Kernassertion: das untergeschobene date wurde NIE als (root-)Daemon ausgefuehrt
  [ "$marker_present" -eq 0 ]
}

@test "T-SEC-002: Symlink-Trigger wird abgelehnt bevor Inhalt gelesen wird" {
  real=$(mktemp /tmp/.macup_real.XXXXXX)
  echo "macos_sw" > "$real"
  TEST_TRIGGERS+=("$real")
  link=$(mktemp -u /tmp/.macup_link.XXXXXX)
  ln -s "$real" "$link"
  TEST_TRIGGERS+=("$link")

  # EXPECTED_OWNER = aktueller User → die Owner-Validation wuerde sonst
  # passieren (Link gehoert dem User). So isolieren wir den Symlink-Reject.
  MACUP_TEST_MODE=1 \
  MACUP_TRIGGER_OVERRIDE="$link" \
  MACUP_EXPECTED_OWNER_OVERRIDE="$(id -un)" \
  MACUP_SOFTWAREUPDATE_OVERRIDE=/usr/bin/true \
  run "$DAEMON_SCRIPT"

  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | grep -cF '"event":"trigger_symlink_rejected"')" -ge 1 ]
  # Negativ-Assertion: der Inhalt wurde NIE verarbeitet
  [ "$(printf '%s' "$output" | grep -cF '"event":"step_started"')" -eq 0 ]
}

@test "T-SEC-003: Daemon lehnt symlinked _constants.sh ab (Source-Guard)" {
  fake_const=$(mktemp -u /tmp/.macup_const.XXXXXX)
  echo 'MACUP_NAME="x"' > "${fake_const}.real"
  ln -s "${fake_const}.real" "$fake_const"
  TEST_TRIGGERS+=("$fake_const" "${fake_const}.real")
  trigger=$(make_trigger "macos_sw")

  MACUP_CONSTANTS_OVERRIDE="$fake_const" \
  MACUP_TEST_MODE=1 \
  MACUP_TRIGGER_OVERRIDE="$trigger" \
  MACUP_SOFTWAREUPDATE_OVERRIDE=/usr/bin/true \
  run "$DAEMON_SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *'"event":"constants_symlink_rejected"'* ]]
}

@test "T-SEC-005: Daemon lehnt _constants.sh mit fremdem Owner ab (Source-Owner-Guard, F2)" {
  # F2: der Root-Daemon sourct Constants → muss sie als self/root-owned verifizieren
  # (fstat-Owner == EUID auf dem geöffneten fd, analog Trigger-Closure). Die Test-
  # Constants gehören dem Test-User; via Seam einen fremden erwarteten UID erzwingen
  # → Owner-Mismatch → reject, KEIN Sourcing.
  real_const=$(mktemp /tmp/.macup_const5.XXXXXX)
  echo 'MACUP_NAME="x"' > "$real_const"
  TEST_TRIGGERS+=("$real_const")
  trigger=$(make_trigger "macos_sw")

  MACUP_CONSTANTS_OVERRIDE="$real_const" \
  MACUP_CONSTANTS_EXPECTED_UID=99 \
  MACUP_TEST_MODE=1 \
  MACUP_TRIGGER_OVERRIDE="$trigger" \
  MACUP_EXPECTED_OWNER_OVERRIDE="$(id -un)" \
  MACUP_SOFTWAREUPDATE_OVERRIDE=/usr/bin/true \
  run "$DAEMON_SCRIPT"

  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | grep -cF '"event":"constants_owner_mismatch"')" -ge 1 ]
  # Negativ-Assertion: nie gesourct/verarbeitet
  [ "$(printf '%s' "$output" | grep -cF '"event":"step_started"')" -eq 0 ]
}

@test "T-SEC-004: Daemon-Versions-String ist v1.0.0" {
  grep -qE '^#.*macOSUpdater_daemon\.sh — v1\.0\.0' "$DAEMON_SCRIPT"
  grep -qE 'daemon_started.*v1\.0\.0' "$DAEMON_SCRIPT"
}
