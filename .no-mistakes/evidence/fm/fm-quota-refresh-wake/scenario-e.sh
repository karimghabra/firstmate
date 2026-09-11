#!/usr/bin/env bash
# Scenario E: the public surface stays minimal and edge-scoped; an explicit --window
# still pins that window; a quota-axi failure wakes as error, never as refreshed.
set -u
export LAB=/tmp/qr-e2e/lab-e; rm -rf "$LAB"; . /tmp/qr-e2e/lib.sh
say() { printf '\n### %s\n' "$*"; }
try() { printf '$ fm-procevent-quota.sh %s\n' "$*"; $BIN/fm-procevent-quota.sh "$@" >"$LAB/o" 2>&1; rc=$?; head -3 "$LAB/o"; echo "exit=$rc"; }
snap 2026-09-11T02:00:00Z 2026-09-11T03:00:00Z 0 2026-09-17T19:00:00Z 60
say "removed tuning flags and baseline subcommand are refused"
try arm --refresh --provider claude --min-advance 1
try arm --refresh --provider claude --restore 5
try baseline --refresh --provider claude
say "edge-scoped flags"
try arm --refresh --provider claude --threshold 10
try arm --provider claude --window five_hour
try arm --refresh --provider claude --window ninety_day
say "explicit --window seven_day pins seven_day although five_hour is binding"
$BIN/fm-procevent-quota.sh arm --refresh --provider claude --window seven_day --interval 1
grep '^window:' "$FM_HOME/state/quota-refresh/quota-refresh-claude.baseline"
say "quota-axi starts failing while the refresh watch runs"
$BIN/fm-procevent.sh reconcile; sleep 2
printf '#!/usr/bin/env bash\n[ "${1:-}" = --version ] && { echo "quota-axi 0.1.41"; exit 0; }\necho boom >&2; exit 3\n' > "$FAKEBIN/quota-axi"
n=0; until grep -q quota-refresh "$FM_HOME/state/.wake-queue" 2>/dev/null || [ $n -ge 150 ]; do sleep 0.1; n=$((n+1)); done
cat "$FM_HOME/state/.wake-queue"
R=$(ls "$FM_HOME"/state/procevent-inbox/quota-refresh-claude.*.result); cat "$R"
say "classify: $($BIN/fm-procevent-quota.sh classify "$R")"
$BIN/fm-procevent-quota.sh retire --refresh --provider claude
