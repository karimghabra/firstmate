#!/usr/bin/env bash
# Scenario A: the five_hour window is exhausted, firstmate arms the refresh watch,
# the real runner polls through exhaustion, jitter, and an absent reading without
# waking, then wakes exactly once when five_hour turns over with headroom back.
set -u
export LAB=/tmp/qr-e2e/lab-a; rm -rf "$LAB"; . /tmp/qr-e2e/lib.sh
say() { printf '\n### %s\n' "$*"; }
say "t0 2026-09-11T02:00Z: five_hour exhausted (0%, resets 03:00Z), seven_day 60%"
snap 2026-09-11T02:00:00Z 2026-09-11T03:00:00.187Z 0 2026-09-17T19:00:00Z 60
say "firstmate: dispatch stopped on exhausted quota -> arm both edges"
$BIN/fm-procevent-quota.sh arm --refresh --provider claude --interval 1
$BIN/fm-procevent-quota.sh arm --provider claude --interval 1
say "persisted baseline (state/quota-refresh/quota-refresh-claude.baseline)"
cat "$FM_HOME/state/quota-refresh/quota-refresh-claude.baseline"
say "watcher cycle: fm-procevent.sh reconcile starts the runners"
$BIN/fm-procevent.sh reconcile
sleep 3
say "wake queue after 3s (falling edge should have fired; refresh must not):"
wakes
say "t1 02:30Z: still exhausted, resetsAt jitters +0.9s across a whole second"
snap 2026-09-11T02:30:00Z 2026-09-11T03:00:01.090Z 0 2026-09-17T19:00:00Z 60; sleep 3
say "t2 03:00:02Z: boundary elapsed, but five_hour missing from the snapshot (unknown reading)"
jq -c '.generatedAt="2026-09-11T03:00:02Z" | .providers[0].windows |= map(select(.id!="five_hour"))' "$QA_CURRENT" > "$QA_CURRENT.t" && mv "$QA_CURRENT.t" "$QA_CURRENT"; sleep 3
say "t3 03:00:03Z: boundary elapsed, five_hour shows new boundary but only 10% headroom"
snap 2026-09-11T03:00:03Z 2026-09-11T08:00:00Z 10 2026-09-17T19:00:00Z 60; sleep 3
say "refresh wakes so far (expect none):"
wakes | grep -c 'quota-refresh' || true
say "t4 03:00:05Z: five_hour turned over -> resets 08:00Z, 100% remaining"
snap 2026-09-11T03:00:05Z 2026-09-11T08:00:00.201Z 100 2026-09-17T19:00:00Z 60
n=0; until grep -q quota-refresh "$FM_HOME/state/.wake-queue" 2>/dev/null || [ $n -ge 100 ]; do sleep 0.1; n=$((n+1)); done
say "wake queue:"
wakes
say "fm-procevent.sh list:"
$BIN/fm-procevent.sh list
R=$(ls "$FM_HOME"/state/procevent-inbox/quota-refresh-claude.*.result)
say "captured result $R:"
cat "$R"
say "classify:"
$BIN/fm-procevent-quota.sh classify "$R"
$BIN/fm-procevent.sh classify "$R"
seq=$(basename "$R" | sed 's/^quota-refresh-claude\.\([0-9]*\)\..*/\1/')
say "firstmate acknowledges: handled quota-refresh-claude $seq"
$BIN/fm-procevent.sh handled quota-refresh-claude "$seq"
say "registrations after terminal verdict:"
$BIN/fm-procevent.sh list
sleep 3
say "refresh wake lines total (expect exactly 1):"
grep -c 'quota-refresh' "$FM_HOME/state/.wake-queue"
say "retire both (idempotent cleanup):"
$BIN/fm-procevent-quota.sh retire --refresh --provider claude
$BIN/fm-procevent-quota.sh retire --provider claude
ls "$FM_HOME/state/quota-refresh/" 2>&1
