#!/usr/bin/env bash
# Scenario B (adversarial): seven_day is exhausted and binding; five_hour has 70%
# and resets sooner. five_hour's turnover must NOT wake; seven_day's must.
set -u
export LAB=/tmp/qr-e2e/lab-b; rm -rf "$LAB"; . /tmp/qr-e2e/lib.sh
say() { printf '\n### %s\n' "$*"; }
say "t0 2026-09-15T18:00Z: seven_day 0% exhausted_now (resets 09-17T19:00Z); five_hour 70% (resets 09-15T19:00Z)"
snap 2026-09-15T18:00:00Z 2026-09-15T19:00:00Z 70 2026-09-17T19:00:00Z 0
jq -c '.providers[0].quotaSemantics.effectiveAvailability' "$QA_CURRENT"
$BIN/fm-procevent-quota.sh arm --refresh --provider claude --interval 1
$BIN/fm-procevent.sh reconcile
sleep 2
say "t1 09-15T19:00:10Z: five_hour turned over (resets 09-16T00:00Z, 100%); seven_day still 0%"
snap 2026-09-15T19:00:10Z 2026-09-16T00:00:00Z 100 2026-09-17T19:00:00Z 0; sleep 4
say "t2 09-16T00:00:10Z: five_hour turned over again (resetless, 100%); seven_day still 0%"
snap 2026-09-16T00:00:10Z - 100 2026-09-17T19:00:00Z 0; sleep 4
say "refresh wakes before seven_day turnover (expect 0):"
grep -c quota-refresh "$FM_HOME/state/.wake-queue" 2>/dev/null || echo 0
say "t3 09-17T19:00:30Z: seven_day turned over (resets 09-24T19:00Z, 100%)"
snap 2026-09-17T19:00:30Z 2026-09-18T00:00:00Z 100 2026-09-24T19:00:00Z 100
n=0; until grep -q quota-refresh "$FM_HOME/state/.wake-queue" 2>/dev/null || [ $n -ge 100 ]; do sleep 0.1; n=$((n+1)); done
say "wake queue:"; wakes
R=$(ls "$FM_HOME"/state/procevent-inbox/quota-refresh-claude.*.result)
say "captured result:"; cat "$R"
say "classify: $($BIN/fm-procevent-quota.sh classify "$R")"
$BIN/fm-procevent-quota.sh retire --refresh --provider claude
