#!/usr/bin/env bats
# ══════════════════════════════════════════════════════════════════
#  hauptscript_md5.bats — Tests für Daemon+Plist-MD5-Drift-Detection
#                        im Hauptscript (v0.6.1+)
#
#  Coverage:
#    T-PL-1  Plist-MD5-Vergleich existiert (Source vs. Dst)
#    T-PL-2  Daemon-MD5-Vergleich existiert (Regression)
#    T-PL-3  Variable Uniqueness: pro Datei eigene Variablen
#            (DAEMON_SRC_SUM, DAEMON_DST_SUM, PLIST_SRC_SUM, PLIST_DST_SUM)
#    T-PL-4  Generische SRC_SUM/DST_SUM nicht mehr verwendet
#
#  Versions-agnostisch via Glob-basiertem Hauptscript-Lookup.
# ══════════════════════════════════════════════════════════════════

setup() {
  ROOT="${BATS_TEST_DIRNAME}/.."
  HAUPTSCRIPT=$(ls "$ROOT"/macOSUpdater_v*.sh 2>/dev/null | head -1)
  [[ -f "$HAUPTSCRIPT" ]]
}

@test "T-PL-1: Plist-Source-MD5 vs. Plist-Dst-MD5 wird verglichen" {
  grep -qE "PLIST_SRC_SUM=.*md5.*PLIST_SRC" "$HAUPTSCRIPT"
  grep -qE "PLIST_DST_SUM=.*md5.*PLIST_DST" "$HAUPTSCRIPT"
  grep -qE 'PLIST_SRC_SUM.*!=.*PLIST_DST_SUM' "$HAUPTSCRIPT"
}

@test "T-PL-2: Daemon-Source-MD5 vs. Daemon-Dst-MD5 wird verglichen (Regression)" {
  grep -qE "DAEMON_SRC_SUM=.*md5.*DAEMON_SRC" "$HAUPTSCRIPT"
  grep -qE "DAEMON_DST_SUM=.*md5.*DAEMON_DST" "$HAUPTSCRIPT"
  grep -qE 'DAEMON_SRC_SUM.*!=.*DAEMON_DST_SUM' "$HAUPTSCRIPT"
}

@test "T-PL-3: Variable Uniqueness — pro Datei eigene MD5-Variablen" {
  # Genau 4 distinct MD5-Variablennamen erwartet
  local md5_vars
  md5_vars=$(grep -oE '(DAEMON|PLIST)_(SRC|DST)_SUM' "$HAUPTSCRIPT" | sort -u | wc -l | tr -d ' ')
  [[ "$md5_vars" -eq 4 ]]
}

@test "T-PL-4: Generische SRC_SUM/DST_SUM nicht mehr verwendet (E-008 Variable Uniqueness)" {
  # Direkte SRC_SUM oder DST_SUM ohne Prefix → Verstoss.
  # Jede Negation als `run …; [ status -ne 0 ]` — nackte `! grep`-Zeilen entkommen
  # an nicht-finaler Position der bats-errexit (false green). Siehe Memory
  # feedback-bats-last-command-assertion.
  run grep -qE '^[[:space:]]*SRC_SUM=' "$HAUPTSCRIPT"; [ "$status" -ne 0 ]
  run grep -qE '^[[:space:]]*DST_SUM=' "$HAUPTSCRIPT"; [ "$status" -ne 0 ]
  run grep -qE '\$SRC_SUM[^_]' "$HAUPTSCRIPT"; [ "$status" -ne 0 ]
  run grep -qE '\$DST_SUM[^_]' "$HAUPTSCRIPT"; [ "$status" -ne 0 ]
}

@test "T-PL-5: Plist-Drift triggert Setup (User-Message vorhanden)" {
  grep -qE "Plist aktualisiert.*neu deployed" "$HAUPTSCRIPT"
}

@test "T-PL-6: Daemon-Drift triggert Setup (User-Message Regression)" {
  grep -qE "Daemon-Script aktualisiert.*neu deployed" "$HAUPTSCRIPT"
}
