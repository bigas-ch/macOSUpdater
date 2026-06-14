#!/usr/bin/env bats
# ══════════════════════════════════════════════════════════════════
#  uninstall_exec.bats — hermetische Execution-Tests des Uninstallers
#
#  Modell (analog setup_deploy.bats): MACUP_UNINSTALL_LIB=1 sourct nur
#  Helfer + Pfade; sudo/launchctl via Override-Stubs (Recorder), Pfade
#  in eine Sandbox umgelenkt. Echtes Laufzeitverhalten der Removal-Logik,
#  ohne realen sudo/launchctl/rm auf Systempfade (M-5-Leitplanke).
# ══════════════════════════════════════════════════════════════════

load setup_test_helper

setup() {
  UNINSTALL="${BATS_TEST_DIRNAME}/../uninstall_macOSUpdater.sh"
  SETUP_SANDBOXES=()
  [[ -f "$UNINSTALL" ]]
}

teardown() { clean_sandboxes; }

# Quelle den Uninstaller im Lib-Mode (Helfer + Pfade, kein interaktiver Flow).
lib_env() { make_sandbox; setup_env; export MACUP_UNINSTALL_LIB=1; }

@test "U-LIB-1: MACUP_UNINSTALL_LIB=1 sourct nur Helfer, ruft uninstall_main NICHT auf" {
  lib_env
  run zsh -c "source '$UNINSTALL'; typeset -f do_rm do_unload do_rmdir uninstall_main >/dev/null && echo ALL_DEFINED"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | grep -cF 'ALL_DEFINED')" -ge 1 ]
  # main lief nicht → kein UNINSTALL-Banner
  [ "$(printf '%s' "$output" | grep -cF 'UNINSTALL')" -eq 0 ]
}

@test "U-RM-USER: do_rm entfernt user-owned File ohne sudo" {
  lib_env
  local f="$SBOX/victim_user"; echo x > "$f"
  run zsh -c "source '$UNINSTALL'; do_rm '$f' 0"
  [ "$status" -eq 0 ]
  [ ! -e "$f" ]
  [ "$(printf '%s' "$output" | grep -cF 'Entfernt')" -ge 1 ]
}

@test "U-RM-SUDO: do_rm mit use_sudo=1 ruft \$SUDO (Recorder) + entfernt" {
  lib_env
  local f="$SBOX/victim_sudo"; echo x > "$f"
  run zsh -c "source '$UNINSTALL'; do_rm '$f' 1"
  [ "$status" -eq 0 ]
  [ ! -e "$f" ]
  [ "$(grep -cF 'rm -f' "$SUDO_LOG")" -ge 1 ]
}

@test "U-UNLOAD: do_unload ruft \$SUDO \$LAUNCHCTL unload" {
  lib_env
  local p="$T_PLIST"; mkdir -p "$(dirname "$p")"; echo x > "$p"
  run zsh -c "source '$UNINSTALL'; do_unload '$p'"
  [ "$status" -eq 0 ]
  [ "$(grep -cF 'unload' "$LCTL_LOG")" -ge 1 ]
}

@test "U-RMDIR: do_rmdir entfernt leeres Verzeichnis" {
  lib_env
  local d="$SBOX/victim_dir"; mkdir -p "$d"
  run zsh -c "source '$UNINSTALL'; do_rmdir '$d'"
  [ "$status" -eq 0 ]
  [ ! -d "$d" ]
}

@test "U-DRYRUN: DRY_RUN=1 → do_rm loggt [dry-run] und löscht NICHT" {
  lib_env
  local f="$SBOX/victim_dry"; echo x > "$f"
  run zsh -c "source '$UNINSTALL'; DRY_RUN=1; do_rm '$f' 1"
  [ "$status" -eq 0 ]
  [ -e "$f" ]
  [ "$(printf '%s' "$output" | grep -cF 'dry-run')" -ge 1 ]
}

# ── F1: assert_safe_target — Schutz vor vergifteten Removal-Zielen ──────────────

@test "U-GUARD-EMPTY: assert_safe_target lehnt leeres Ziel ab" {
  lib_env
  run zsh -c "source '$UNINSTALL'; assert_safe_target ''"
  [ "$status" -ne 0 ]
  [ "$(printf '%s' "$output" | grep -cF 'F1-Guard')" -ge 1 ]
}

@test "U-GUARD-ROOT: assert_safe_target lehnt / ab" {
  lib_env
  run zsh -c "source '$UNINSTALL'; assert_safe_target /"
  [ "$status" -ne 0 ]
  [ "$(printf '%s' "$output" | grep -cF 'F1-Guard')" -ge 1 ]
}

@test "U-GUARD-SYSTEM: assert_safe_target lehnt /System (+ Subtree) ab" {
  lib_env
  run zsh -c "source '$UNINSTALL'; assert_safe_target /System"
  [ "$status" -ne 0 ]
  run zsh -c "source '$UNINSTALL'; assert_safe_target '/System/Library/Frameworks'"
  [ "$status" -ne 0 ]
}

@test "U-GUARD-TRAVERSAL: assert_safe_target lehnt Path-Traversal ab" {
  lib_env
  run zsh -c "source '$UNINSTALL'; assert_safe_target '/Library/../etc'"
  [ "$status" -ne 0 ]
  [ "$(printf '%s' "$output" | grep -cF 'F1-Guard')" -ge 1 ]
}

@test "U-GUARD-OK: assert_safe_target lässt legitimes Sandbox-Ziel durch" {
  lib_env
  run zsh -c "source '$UNINSTALL'; assert_safe_target '$SBOX/Library/Application Support/ch.bigas.macOSUpdater'; echo PASSED"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | grep -cF 'PASSED')" -ge 1 ]
}

@test "U-RM-POISON-BLOCKED: do_rm auf geschütztes Ziel ruft KEIN sudo rm" {
  lib_env
  # vergiftetes Ziel (z.B. aus manipuliertem _constants) → Guard greift vor $SUDO rm
  run zsh -c "source '$UNINSTALL'; do_rm '/System' 1"
  [ "$status" -ne 0 ]
  [ "$(printf '%s' "$output" | grep -cF 'F1-Guard')" -ge 1 ]
  # sudo-Recorder wurde nie für /System aufgerufen
  local n=0
  if [[ -f "$SUDO_LOG" ]]; then n=$(grep -cF '/System' "$SUDO_LOG" || true); fi
  [ "$n" -eq 0 ]
}

@test "U-APP-PATH: APP_DST ist gesetzt und zeigt auf macOSUpdater.app" {
  lib_env
  run zsh -c "source '$UNINSTALL'; echo \"\$APP_DST\""
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | grep -cF 'macOSUpdater.app')" -ge 1 ]
}

@test "U-APP-REMOVE: do_rmdir entfernt macOSUpdater.app (Launcher)" {
  lib_env
  local app="$SBOX/Applications/macOSUpdater.app"; mkdir -p "$app/Contents"
  run zsh -c "source '$UNINSTALL'; do_rmdir '$app'"
  [ "$status" -eq 0 ]
  [ ! -d "$app" ]
}
