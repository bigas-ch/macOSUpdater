# tests/setup_test_helper.bash — hermetische Harness für Setup-Tests (bash/bats).
# Globale Vars werden von make_sandbox gesetzt; setup_env exportiert die MACUP_*-Seams.

make_sandbox() {
  SBOX=$(mktemp -d /tmp/.macup_setup.XXXXXX)
  SETUP_SANDBOXES+=("$SBOX")
  T_DAEMON_DIR="$SBOX/Library/Application Support/ch.bigas.macOSUpdater"
  T_PLIST="$SBOX/Library/LaunchDaemons/ch.bigas.macOSUpdater.plist"
  T_LOG="$SBOX/var/log/macOSUpdater.log"
  T_HOME="$SBOX/home"
  STUB_BIN="$SBOX/stubs"
  SUDO_LOG="$SBOX/sudo.log"
  LCTL_LOG="$SBOX/launchctl.log"
  LCTL_LOADED="$SBOX/loaded_labels"
  mkdir -p "$T_HOME" "$STUB_BIN" "$(dirname "$T_PLIST")" "$SBOX/var/log" "$SBOX/usr/local/bin" \
           "$(dirname "$T_DAEMON_DIR")"
  : > "$SUDO_LOG"; : > "$LCTL_LOG"; : > "$LCTL_LOADED"

  # sudo-Recorder: loggt alles; no-op nur für chown (als non-root unmöglich);
  # no-op auch für sudo-eigene Flags (-v/-k Auth-Gate, kein Kommando) — sonst
  # bricht 'exec -v' mit 'invalid option' (rc 2) und deploy_daemon nimmt immer
  # den Auth-Fail-Zweig. Rest real ausführen (mkdir/cp/touch/sed/mv/rm — alle
  # in der temp-Sandbox).
  cat > "$STUB_BIN/sudo" <<EOF
#!/bin/bash
echo "\$*" >> "$SUDO_LOG"
[[ "\$1" == -* ]] && exit 0
[[ "\$1" == */chown ]] && exit 0
exec "\$@"
EOF
  chmod +x "$STUB_BIN/sudo"

  # launchctl-Stub: loggt + verwaltet das geladene Label-Set.
  cat > "$STUB_BIN/launchctl" <<EOF
#!/bin/bash
echo "\$*" >> "$LCTL_LOG"
case "\$1" in
  print)   label="\${2#system/}"; grep -qxF "\$label" "$LCTL_LOADED" && exit 0 || exit 1 ;;
  bootout) label="\${2#system/}"; grep -vxF "\$label" "$LCTL_LOADED" > "$LCTL_LOADED.tmp" 2>/dev/null || :; mv "$LCTL_LOADED.tmp" "$LCTL_LOADED" 2>/dev/null || :; exit 0 ;;
  load)    echo "ch.bigas.macOSUpdater" >> "$LCTL_LOADED"; exit 0 ;;
  unload)  exit 0 ;;
  *)       exit 0 ;;
esac
EOF
  chmod +x "$STUB_BIN/launchctl"
}

mark_loaded() { echo "$1" >> "$LCTL_LOADED"; }   # Label als "geladen" markieren

setup_env() {
  export MACUP_SETUP_LIB=1
  export HOME="$T_HOME"
  export PATH="$STUB_BIN:$PATH"
  export MACUP_SUDO_OVERRIDE="$STUB_BIN/sudo"
  export MACUP_LAUNCHCTL_OVERRIDE="$STUB_BIN/launchctl"
  export MACUP_DAEMON_DIR_OVERRIDE="$T_DAEMON_DIR"
  export MACUP_PLIST_DST_OVERRIDE="$T_PLIST"
  export MACUP_LOG_OVERRIDE="$T_LOG"
  export MACUP_INSTALL_DIR_UID_OVERRIDE=0
  export MACUP_INSTALL_USER_OVERRIDE="$(id -un)"
}

clean_sandboxes() { for s in "${SETUP_SANDBOXES[@]}"; do rm -rf "$s" 2>/dev/null || true; done; }
