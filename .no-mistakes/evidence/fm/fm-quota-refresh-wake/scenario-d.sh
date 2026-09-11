#!/usr/bin/env bash
# Scenario D (live quota-axi, no scripting): arm the refresh watch against the real
# account, confirm it pins the live binding window, let the real runner poll the
# real quota-axi through its resetsAt jitter, and confirm no false wake; retire.
set -u
WT=/home/mars/.no-mistakes/worktrees/a8c0c72d0935/01M278DMHRZ56PHZN98T8TQ83P; BIN=$WT/bin
LAB=/tmp/qr-e2e/lab-d; rm -rf "$LAB"; mkdir -p "$LAB/home/state" "$LAB/claims"; chmod 700 "$LAB" "$LAB/home" "$LAB/home/state" "$LAB/claims"
export FM_HOME=$LAB/home FM_PROCEVENT_CLAIM_ROOT=$LAB/claims
say() { printf '\n### %s\n' "$*"; }
say "quota-axi: $(command -v quota-axi) $(quota-axi --version)"
say "live binding scope and claude windows right now:"
quota-axi --json | jq -c '.generatedAt as $g | .providers[] | select(.provider=="claude") | {generatedAt: $g, all_models: (.quotaSemantics.effectiveAvailability[] | select(.scope=="all_models") | {effectivePercentRemaining, limitingWindowIds, runway: .runway.status}), windows: [.windows[] | {id, resetsAt, percentRemaining}]}'
say "arm --refresh --provider claude --interval 5 (real quota-axi)"
$BIN/fm-procevent-quota.sh arm --refresh --provider claude --interval 5
say "baseline:"; cat "$FM_HOME/state/quota-refresh/quota-refresh-claude.baseline"
$BIN/fm-procevent.sh reconcile
say "runner polling the live quota-axi for 45s..."
for i in 1 2 3; do sleep 15; printf '%s  five_hour=%s\n' "$(date -u +%T)" "$(quota-axi --json | jq -r '.providers[]|select(.provider=="claude")|.windows[]|select(.id=="five_hour")|.resetsAt')"; done
say "fm-procevent.sh list:"; $BIN/fm-procevent.sh list
say "wake queue (expect empty - no false refresh):"; cat "$FM_HOME/state/.wake-queue" 2>/dev/null || echo "(empty)"
say "captured results (expect none):"; ls "$FM_HOME/state/procevent-inbox/" 2>/dev/null | grep . || echo "(none)"
say "retire --refresh --provider claude"
$BIN/fm-procevent-quota.sh retire --refresh --provider claude
$BIN/fm-procevent-quota.sh retire --refresh --provider claude
say "after retire:"; $BIN/fm-procevent.sh list; ls -A "$FM_HOME/state/quota-refresh/"; echo "(baseline dir listing above; expect empty)"
sleep 2; pgrep -af "lab-d|fm-procevent-quota.sh poll --refresh --interval 5" | grep -v pgrep || echo "no runner/poll process left"
