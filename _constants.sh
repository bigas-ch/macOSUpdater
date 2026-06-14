# shellcheck shell=bash
# shellcheck disable=SC2034  # Konstanten werden von sourcenden Skripten genutzt, nicht hier
# ══════════════════════════════════════════════════════════════════
#  _constants.sh — Single Source of Truth für macOSUpdater-Naming.
#
#  POSIX-sourcebar von bash 3.2 UND zsh (nur einfache Var-Zuweisungen,
#  keine Arrays, keine bash-4-/zsh-only-Syntax, keine Kommandos).
#  Wird von CLI, Daemon, setup und uninstall zur Laufzeit gesourct
#  (Variante B — Volles Threading). Im Deploy liegt eine Kopie root-owned
#  neben dem Daemon (/Library/Application Support/ch.bigas.macOSUpdater/).
#
#  Künftige Renames: NUR diese Datei ändern. Die nicht-sourcenden
#  Flächen (plist) werden durch tests/constants_drift.bats erzwungen
#  synchron gehalten.
# ══════════════════════════════════════════════════════════════════

MACUP_NAME="macOSUpdater"
MACUP_LABEL="ch.bigas.macOSUpdater"
MACUP_DAEMON_DIR="/Library/Application Support/ch.bigas.macOSUpdater"
MACUP_DAEMON_SCRIPT="${MACUP_DAEMON_DIR}/macOSUpdater_daemon.sh"
MACUP_PLIST_DST="/Library/LaunchDaemons/ch.bigas.macOSUpdater.plist"
MACUP_LOG="/var/log/macOSUpdater.log"
MACUP_TRIGGER_BASENAME=".macOSUpdater_trigger"
MACUP_DONE_BASENAME=".macOSUpdater_done"
