#!/usr/bin/env bash
# Scenario C: idle fleet. five_hour exhausted, refresh watch armed, but no runner
# is polling while the boundary passes. The window resets and, unused since,
# reports no resetsAt. The next watcher reconcile must wake on its first poll.
set -u
export LAB=/tmp/qr-e2e/lab-c; rm -rf "$LAB"; . /tmp/qr-e2e/lib.sh
say() { printf '\n### %s\n' "$*"; }
say "t0 2026-09-10T14:00Z: five_hour exhausted (0%, resets 15:10Z)"
snap 2026-09-10T14:00:00Z 2026-09-10T15:10:00.412Z 0 2026-09-17T19:00:00Z 40
$BIN/fm-procevent-quota.sh arm --refresh --provider claude --interval 1
say "registered source record (nothing polling yet):"
cat "$FM_HOME/state/procevent/quota-refresh-claude.source"
say "hours pass with no runner; at 18:42Z the unused five_hour reports no resetsAt, 100%"
snap 2026-09-10T18:42:00Z - 100 2026-09-17T19:00:00Z 40
jq -c '.providers[0].windows' "$QA_CURRENT"
say "watcher cycle resumes: reconcile"
$BIN/fm-procevent.sh reconcile
n=0; until grep -q quota-refresh "$FM_HOME/state/.wake-queue" 2>/dev/null || [ $n -ge 100 ]; do sleep 0.1; n=$((n+1)); done
say "wake queue:"; wakes
R=$(ls "$FM_HOME"/state/procevent-inbox/quota-refresh-claude.*.result)
say "captured result:"; cat "$R"
say "classify: $($BIN/fm-procevent-quota.sh classify "$R")"

say "--- relaunch after a lost capture: re-run the exact registered poll argv twice ---"
export LAB=/tmp/qr-e2e/lab-c2; rm -rf "$LAB"; . /tmp/qr-e2e/lib.sh
snap 2026-09-10T14:00:00Z 2026-09-10T15:10:00.412Z 0 2026-09-17T19:00:00Z 40
$BIN/fm-procevent-quota.sh arm --refresh --provider claude --interval 1 >/dev/null
mapfile -t ARGV < <(sed -n '/^argv:/,$p' "$FM_HOME/state/procevent/quota-refresh-claude.source" | tail -n +2 | sed 's/^  //')
printf 'registered argv:'; printf ' %q' "${ARGV[@]}"; echo
snap 2026-09-10T18:42:00Z - 100 2026-09-17T19:00:00Z 40
say "first poll run (runner dies before capturing its stdout):"
timeout 20 "${ARGV[@]}"
say "baseline after firing (must be unchanged):"; cat "$FM_HOME/state/quota-refresh/quota-refresh-claude.baseline"
say "relaunched poll run:"
timeout 20 "${ARGV[@]}"; echo "exit=$?"
$BIN/fm-procevent-quota.sh retire --refresh --provider claude
