#!/usr/bin/env bats
# ══════════════════════════════════════════════════════════════════
#  setup_deploy.bats — hermetische Tests der Setup-Deploy-Logik (2b)
#  Sourcing-Guard, Daemon-Dir + _constants.sh-Co-Deploy, WatchPath-
#  Injektion, Owner-Injektion, Prio-0-Root-Owned-Hard-Fail.
# ══════════════════════════════════════════════════════════════════

load setup_test_helper

setup() {
  SETUP="${BATS_TEST_DIRNAME}/../setup_macOSUpdater_v1.0.0.sh"
  SETUP_SANDBOXES=()
  [[ -f "$SETUP" ]]
}

teardown() { clean_sandboxes; }

@test "S-LIB-1: MACUP_SETUP_LIB=1 sourct nur Funktionen, ruft setup_main NICHT auf" {
  make_sandbox; setup_env
  run zsh -c "source '$SETUP'; typeset -f deploy_daemon >/dev/null && echo HAS_DEPLOY"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | grep -cF 'HAS_DEPLOY')" -ge 1 ]
  # setup_main lief nicht → kein 'Einrichtung'-Banner im Output
  [ "$(printf '%s' "$output" | grep -cF 'Einrichtung')" -eq 0 ]
}

@test "S-LIB-2: deploy_daemon, teardown_legacy_daemons, assert_root_owned sind definiert" {
  make_sandbox; setup_env
  run zsh -c "source '$SETUP'; for f in deploy_daemon teardown_legacy_daemons assert_root_owned inject_watch_path resolve_install_owner setup_main; do typeset -f \$f >/dev/null || { echo MISSING:\$f; exit 1; }; done; echo ALL_DEFINED"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL_DEFINED"* ]]
}

@test "S-HARNESS-1: sudo-Stub behandelt sudo-Flags (-v/-k) als no-op (rc 0, kein exec)" {
  # Regression: deploy_daemon startet mit '$SUDO -v' (Auth-Gate). Die Stub darf
  # '-v'/'-k' nicht an 'exec' durchreichen ('exec -v' = invalid option, rc 2),
  # sonst nimmt deploy_daemon IMMER den Auth-Fail-Zweig (exit 1).
  make_sandbox; setup_env
  run "$STUB_BIN/sudo" -v
  [ "$status" -eq 0 ]
  run "$STUB_BIN/sudo" -k
  [ "$status" -eq 0 ]
  # chown bleibt no-op, echte Kommandos werden weiterhin ausgeführt
  run "$STUB_BIN/sudo" /usr/sbin/chown root:wheel "$T_DAEMON_DIR"
  [ "$status" -eq 0 ]
  run "$STUB_BIN/sudo" /bin/echo executed
  [ "$status" -eq 0 ]
  [[ "$output" == *"executed"* ]]
}

@test "S-DEPLOY-1: setup legt Daemon-Dir an + co-deployt _constants.sh root-owned-Chain" {
  make_sandbox; setup_env
  run zsh -c "source '$SETUP'; deploy_daemon"
  [ "$status" -eq 0 ]
  [ -d "$T_DAEMON_DIR" ]
  [ -f "$T_DAEMON_DIR/_constants.sh" ]
  [ -f "$T_DAEMON_DIR/macOSUpdater_daemon.sh" ]
  # sudo-Recorder belegt chown root:wheel auf Dir + _constants.sh
  grep -qF "/usr/sbin/chown root:wheel $T_DAEMON_DIR" "$SUDO_LOG"
  grep -qF "/usr/sbin/chown root:wheel $T_DAEMON_DIR/_constants.sh" "$SUDO_LOG"
}

@test "S-DEPLOY-2: deploytes _constants.sh ist inhaltsgleich zur Quelle (Variante B)" {
  make_sandbox; setup_env
  run zsh -c "source '$SETUP'; deploy_daemon"
  [ "$status" -eq 0 ]
  run diff "$BATS_TEST_DIRNAME/../_constants.sh" "$T_DAEMON_DIR/_constants.sh"
  [ "$status" -eq 0 ]
}

@test "S-DEPLOY-3: deployte plist trägt echten WatchPath, KEIN __WATCH_PATH__-Platzhalter" {
  make_sandbox; setup_env
  run zsh -c "source '$SETUP'; deploy_daemon"
  [ "$status" -eq 0 ]
  [ -f "$T_PLIST" ]
  run grep -qF "__WATCH_PATH__" "$T_PLIST"
  [ "$status" -ne 0 ]
  grep -qF "$(id -un)" "$T_PLIST" || grep -qF "${HOME}/.macOSUpdater_trigger" "$T_PLIST"
  grep -qF ".macOSUpdater_trigger" "$T_PLIST"
}

@test "S-GUARD-1: Hard-Fail wenn Install-Dir NICHT root-owned (uid≠0) → exit 1" {
  make_sandbox; setup_env
  export MACUP_INSTALL_DIR_UID_OVERRIDE=502   # simuliert user-Ownership
  run zsh -c "source '$SETUP'; deploy_daemon"
  [ "$status" -eq 1 ]
  [[ "$output" == *"nicht root-owned"* ]]
}

@test "S-GUARD-2: root-owned (uid=0) → deploy_daemon läuft durch" {
  make_sandbox; setup_env   # setzt MACUP_INSTALL_DIR_UID_OVERRIDE=0
  run zsh -c "source '$SETUP'; deploy_daemon"
  [ "$status" -eq 0 ]
}

@test "S-GUARD-3: Guard nutzt echtes stat -f %u wenn kein Override gesetzt" {
  make_sandbox; setup_env
  unset MACUP_INSTALL_DIR_UID_OVERRIDE   # echtes stat: temp-Dir gehört dem Testuser (≠0) → Hard-Fail
  run zsh -c "source '$SETUP'; deploy_daemon"
  [ "$status" -eq 1 ]
  [[ "$output" == *"nicht root-owned"* ]]
}

@test "S-OWNER-1: Daemon-Quelle enthält __INSTALL_OWNER__-Platzhalter, KEIN michabarth" {
  run grep -qF '__INSTALL_OWNER__' "$BATS_TEST_DIRNAME/../macOSUpdater_daemon.sh"
  [ "$status" -eq 0 ]
  run grep -qF 'michabarth' "$BATS_TEST_DIRNAME/../macOSUpdater_daemon.sh"
  [ "$status" -ne 0 ]
}

@test "S-OWNER-2: deployter Daemon hat injizierten User, KEINEN Platzhalter mehr" {
  make_sandbox; setup_env
  run zsh -c "source '$SETUP'; deploy_daemon"
  [ "$status" -eq 0 ]
  # Negierte Assertion via run+status (nicht `! grep` — das ist von bats'
  # set-e-Semantik ausgenommen und wäre eine tote Assertion).
  run grep -qF '__INSTALL_OWNER__' "$T_DAEMON_DIR/macOSUpdater_daemon.sh"
  [ "$status" -ne 0 ]
  run grep -qF "EXPECTED_OWNER_OVERRIDE:-$(id -un)}" "$T_DAEMON_DIR/macOSUpdater_daemon.sh"
  [ "$status" -eq 0 ]
}

@test "S-OWNER-3: resolve_install_owner verweigert root (Setup muss als User laufen)" {
  make_sandbox; setup_env
  export MACUP_INSTALL_USER_OVERRIDE=root
  run zsh -c "source '$SETUP'; resolve_install_owner"
  [ "$status" -eq 1 ]
  [[ "$output" == *"als root"* ]]
}

@test "S-OWNER-4: deploy_daemon bricht bei root-Owner HART ab (realer Aufrufpfad, kein leerer Owner)" {
  make_sandbox; setup_env
  export MACUP_INSTALL_USER_OVERRIDE=root
  # realer Aufrufpfad: deploy_daemon ruft resolve_install_owner per
  # Command-Substitution → der Root-Guard muss deploy_daemon abbrechen,
  # NICHT nur die Substitutions-Subshell.
  run zsh -c "source '$SETUP'; deploy_daemon"
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | grep -cF 'als root')" -ge 1 ]
  # Defense-in-Depth: kein Daemon mit leerem/Platzhalter-Owner deployt.
  if [[ -f "$T_DAEMON_DIR/macOSUpdater_daemon.sh" ]]; then
    run grep -qF 'EXPECTED_OWNER_OVERRIDE:-}' "$T_DAEMON_DIR/macOSUpdater_daemon.sh"
    [ "$status" -ne 0 ]
  fi
}

@test "S-OWNER-5: resolve_install_owner weist ungültige Owner-Zeichen ab (sed-Injection-Schutz)" {
  make_sandbox; setup_env
  export MACUP_INSTALL_USER_OVERRIDE="ev/il&x"
  run zsh -c "source '$SETUP'; resolve_install_owner"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Ungültig"* ]]
}

@test "S-UIDMAP-1: install_dir_owner_uid nutzt Per-Pfad-Map (Treffer) + Durchfall auf globalen Override (Miss)" {
  make_sandbox; setup_env   # setzt MACUP_INSTALL_DIR_UID_OVERRIDE=0
  local map="$SBOX/uidmap"
  printf '%s\t%s\n' 502 "$T_DAEMON_DIR" > "$map"
  export MACUP_UID_MAP_OVERRIDE="$map"
  # Treffer (Map): T_DAEMON_DIR → 502 ; Miss (nicht in Map): irgendein Pfad → globaler Override 0
  run zsh -c "source '$SETUP'; hit=\$(install_dir_owner_uid '$T_DAEMON_DIR'); miss=\$(install_dir_owner_uid '/nicht/in/map'); echo \"\$hit:\$miss\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"502:0"* ]]
}

# ── M-2 Pre-chown-Guard: $DAEMON_DIR (kind=dir) ──
@test "S-PRECHOWN-1: Leaf ist Symlink → exit 1, kein chown aufs Ziel" {
  make_sandbox; setup_env
  ln -s "$SBOX/elsewhere" "$T_DAEMON_DIR"
  run zsh -c "source '$SETUP'; deploy_daemon"
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | grep -cF 'Symlink')" -ge 1 ]
  run grep -F "chown root:wheel $T_DAEMON_DIR" "$SUDO_LOG"
  [ "$status" -ne 0 ]
}

@test "S-PRECHOWN-2: Parent ist Symlink → exit 1" {
  make_sandbox; setup_env
  local parent; parent="$(dirname "$T_DAEMON_DIR")"
  rmdir "$parent"
  mkdir -p "$SBOX/realparent"
  ln -s "$SBOX/realparent" "$parent"
  run zsh -c "source '$SETUP'; deploy_daemon"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Symlink"* ]]
}

@test "S-PRECHOWN-3: Parent fehlt → exit 1" {
  make_sandbox; setup_env
  rmdir "$(dirname "$T_DAEMON_DIR")"
  run zsh -c "source '$SETUP'; deploy_daemon"
  [ "$status" -eq 1 ]
  [[ "$output" == *"fehlt"* || "$output" == *"kein Verzeichnis"* ]]
}

@test "S-PRECHOWN-4: Leaf existiert als Datei → exit 1" {
  make_sandbox; setup_env
  : > "$T_DAEMON_DIR"
  run zsh -c "source '$SETUP'; deploy_daemon"
  [ "$status" -eq 1 ]
  [[ "$output" == *"kein Verzeichnis"* ]]
}

@test "S-PRECHOWN-5: Leaf-Dir nicht root-owned (Map: Parent=0, Leaf=502) → exit 1 nicht root-owned" {
  make_sandbox; setup_env
  local parent map
  parent="$(dirname "$T_DAEMON_DIR")"
  mkdir -p "$T_DAEMON_DIR"
  map="$SBOX/uidmap"
  printf '%s\t%s\n' 0 "$parent" 502 "$T_DAEMON_DIR" > "$map"
  export MACUP_UID_MAP_OVERRIDE="$map"
  run zsh -c "source '$SETUP'; deploy_daemon"
  [ "$status" -eq 1 ]
  [[ "$output" == *"nicht root-owned"* ]]
}

@test "S-PRECHOWN-6: Happy — Parent+Leaf root-owned (Leaf existiert vorab) → exit 0" {
  make_sandbox; setup_env
  mkdir -p "$T_DAEMON_DIR"
  run zsh -c "source '$SETUP'; deploy_daemon"
  [ "$status" -eq 0 ]
}

# ── M-2 Pre-chown-Guard: $PLIST_DST (kind=file) ──
@test "S-PRECHOWN-7: Plist-Leaf ist Symlink → exit 1, kein chown aufs Plist-Ziel" {
  make_sandbox; setup_env
  ln -s "$SBOX/evil" "$T_PLIST"
  run zsh -c "source '$SETUP'; deploy_daemon"
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | grep -cF 'Symlink')" -ge 1 ]
  run grep -F "chown root:wheel $T_PLIST" "$SUDO_LOG"
  [ "$status" -ne 0 ]
}

@test "S-PRECHOWN-8: Plist-Leaf existiert als Verzeichnis → exit 1 keine reguläre Datei" {
  make_sandbox; setup_env
  mkdir -p "$T_PLIST"
  run zsh -c "source '$SETUP'; deploy_daemon"
  [ "$status" -eq 1 ]
  [[ "$output" == *"keine reguläre Datei"* ]]
}

@test "S-PRECHOWN-9: Plist-Parent ist Symlink → exit 1" {
  make_sandbox; setup_env
  local parent; parent="$(dirname "$T_PLIST")"
  rmdir "$parent"
  mkdir -p "$SBOX/realLD"
  ln -s "$SBOX/realLD" "$parent"
  run zsh -c "source '$SETUP'; deploy_daemon"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Symlink"* ]]
}

# ── F3: setup_touchid hängt an statt zu überschreiben ───────────────────────────

@test "S-TOUCHID-MERGE: bestehende sudo_local-Direktiven bleiben erhalten (F3)" {
  make_sandbox; setup_env
  local sl="$SBOX/sudo_local"
  printf 'auth       sufficient     pam_other.so\n' > "$sl"
  run zsh -c "source '$SETUP'; MACUP_SUDO_LOCAL_OVERRIDE='$sl'; setup_touchid"
  [ "$status" -eq 0 ]
  # F3-Kern: fremde Direktive NICHT verloren + pam_tid.so ergänzt
  [ "$(grep -cF 'pam_other.so' "$sl")" -eq 1 ]
  [ "$(grep -cF 'pam_tid.so' "$sl")" -eq 1 ]
}

@test "S-TOUCHID-IDEMPOTENT: pam_tid.so schon vorhanden → kein doppelter Eintrag" {
  make_sandbox; setup_env
  local sl="$SBOX/sudo_local"
  printf 'auth       sufficient     pam_tid.so\n' > "$sl"
  run zsh -c "source '$SETUP'; MACUP_SUDO_LOCAL_OVERRIDE='$sl'; setup_touchid"
  [ "$status" -eq 0 ]
  [ "$(grep -cF 'pam_tid.so' "$sl")" -eq 1 ]
  [ "$(printf '%s' "$output" | grep -cF 'bereits aktiv')" -ge 1 ]
}

@test "S-CLI-DEPLOY: deploy_daemon legt den CLI root-owned + ausführbar in DAEMON_DIR ab" {
  make_sandbox; setup_env
  run zsh -c "source '$SETUP'; deploy_daemon"
  [ "$status" -eq 0 ]
  local cli="$T_DAEMON_DIR/macOSUpdater_v1.0.0.sh"
  [ -f "$cli" ]
  [ -x "$cli" ]
  [ "$(grep -cE 'chown root:wheel .*macOSUpdater_v1.0.0.sh' "$SUDO_LOG")" -ge 1 ]
}

@test "S-LAUNCHER-GUARD: ohne osacompile wird der Launcher übersprungen (non-fatal, rc 0)" {
  make_sandbox; setup_env
  run zsh -c "source '$SETUP'; MACUP_OSACOMPILE_OVERRIDE='/nonexistent/osacompile' MACUP_APP_DIR_OVERRIDE='$SBOX/Applications' setup_applauncher"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | grep -cF 'osacompile')" -ge 1 ]
  [ ! -d "$SBOX/Applications/macOSUpdater.app" ]
}

@test "S-LAUNCHER-APP: erzeugt macOSUpdater.app und referenziert den deployten CLI" {
  command -v osacompile >/dev/null || skip "osacompile nicht verfügbar"
  make_sandbox; setup_env
  mkdir -p "$SBOX/Applications"
  run zsh -c "source '$SETUP'; MACUP_APP_DIR_OVERRIDE='$SBOX/Applications' MACUP_APP_ICON_OVERRIDE='$SBOX/none.icns' setup_applauncher"
  [ "$status" -eq 0 ]
  [ -d "$SBOX/Applications/macOSUpdater.app" ]
  # CLI-Pfad via osadecompile prüfen (osacompile erzeugt binäres main.scpt; osadecompile
  # dekompiliert es zuverlässig zurück zu lesbarem AppleScript — robuster als grep -ra).
  /usr/bin/osadecompile "$SBOX/Applications/macOSUpdater.app/Contents/Resources/Scripts/main.scpt" | grep -qF "macOSUpdater_v1.0.0.sh"
}
