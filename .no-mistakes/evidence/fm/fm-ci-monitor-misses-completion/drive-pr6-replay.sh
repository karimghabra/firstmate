#!/usr/bin/env bash
# Live replay driver for the CI-monitor-behind change.
#
# Runs the REAL bin/fm-crew-state.sh and bin/fm-inactive-reconcile.sh against
# the REAL GitHub forge (the real `gh`, reading karimghabra/firstmate PR 6's
# real 14-check rollup). Only the no-mistakes run record is a stub, because a
# stalled pipeline ci monitor cannot be induced on demand: it replays the
# 2026-09-11 reading verbatim (`ci,running,25m3s`, "quiet 24m25s ago: log: CI
# checks running, waiting for results...") with the PR's real head SHA.
# A logging shim in front of the real gh records every forge call.
#
# usage: drive-pr6-replay.sh <scenario> ; prints a transcript on stdout.
set -u
WT_SRC=${WT_SRC:?}            # the worktree under test
SCEN=${1:?scenario}
ROOT=$(mktemp -d /tmp/fm-live-pr6.XXXXXX)
trap 'rm -rf "$ROOT"' EXIT
PR_URL=${PR_URL:-https://github.com/karimghabra/firstmate/pull/6}
PR_HEAD=${PR_HEAD:-ed077e1e6c9b91fac657289d8d457e6af2a46286}
REAL_GH=$(command -v gh)

mkdir -p "$ROOT/state" "$ROOT/fakebin"
# A task worktree checked out at the PR's real head, fetched from GitHub.
git init -q "$ROOT/wt"
git -C "$ROOT/wt" fetch -q --depth 1 "${REPO_URL:-https://github.com/karimghabra/firstmate.git}" "$PR_HEAD"
git -C "$ROOT/wt" checkout -q -b fm/pr-replay FETCH_HEAD
printf 'window=fm:fm-crew\nworktree=%s\nkind=ship\n' "$ROOT/wt" > "$ROOT/state/crew.meta"

CI_LOG_WAITING='monitoring CI for PR #6 (timeout: 168h0m0s)...
no CI checks reported yet, waiting for checks to register...
CI checks running, waiting for results...'
case "$SCEN" in
  rerun-wait) CI_LOG="$CI_LOG_WAITING
issues detected: 1 failing check
fix already attempted for these issues, waiting for CI re-run..." ;;
  monitor-green) CI_LOG="$CI_LOG_WAITING
all CI checks passed - still monitoring until merged or closed" ;;
  *) CI_LOG=$CI_LOG_WAITING ;;
esac
RUN_HEAD=$PR_HEAD

cat > "$ROOT/run.toon" <<EOF
run:
  id: "01RUN"
  branch: fm/pr-replay
  status: running
  head: "${RUN_HEAD:0:8}"
  head_sha: "${RUN_HEAD}"
  pr: "${PR_URL}"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0
  active_steps[1]{step,status,active_for,round_active_for,last_activity,agent_pid,round}:
    ci,running,25m3s,"","quiet 24m25s ago: log: CI checks running, waiting for results...","",""
EOF
printf '%s\n' "$CI_LOG" > "$ROOT/ci.log"
cat > "$ROOT/fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "axi status") cat "$ROOT/run.toon" ;;
  "axi logs") cat "$ROOT/ci.log" ;;
  "daemon status") echo 'daemon running (pid 4242)' ;;
esac
exit 0
SH
cat > "$ROOT/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in display-message) printf '%%1\n' ;; capture-pane) printf 'all quiet\n> \n' ;; esac
exit 0
SH
# Logging shim in front of the REAL gh. For head-moved, the forge answer is
# the real one with only its headRefOid rewritten, so the check data is real.
cat > "$ROOT/fakebin/gh" <<SH
#!/usr/bin/env bash
printf 'gh %s %s %s\n' "\$1" "\$2" "\$3" >> "$ROOT/gh.calls"
if [ "$SCEN" = unreadable ]; then exit 1; fi
if [ "$SCEN" = head-moved ]; then
  jqp=; args=()
  while [ \$# -gt 0 ]; do case "\$1" in --jq) jqp=\$2; shift 2 ;; *) args+=("\$1"); shift ;; esac; done
  "$REAL_GH" "\${args[@]}" | jq '.headRefOid = "0123456789abcdef0123456789abcdef01234567"' | jq -r "\$jqp"
  exit
fi
exec "$REAL_GH" "\$@"
SH
chmod +x "$ROOT/fakebin/"*
: > "$ROOT/gh.calls"

crew_state() {
  PATH="$ROOT/fakebin:$PATH" FM_STATE_OVERRIDE="$ROOT/state" "$WT_SRC/bin/fm-crew-state.sh" crew
}
scan() {
  PATH="$ROOT/fakebin:$PATH" FM_HOME="$ROOT" FM_STATE_OVERRIDE="$ROOT/state" \
    FM_INACTIVE_RECONCILE_SECS=60 FM_INACTIVE_RECONCILE_NOW=$(( $(date +%s) + 3600 )) \
    "$WT_SRC/bin/fm-inactive-reconcile.sh" scan --startup
}
queue_behind() { local n; n=$(grep -c $'\tcheck\tci-monitor-behind:' "$ROOT/state/.wake-queue" 2>/dev/null); echo "${n:-0}"; }
outcomes() { find "$ROOT/state/terminal-outcomes" -type f 2>/dev/null | wc -l | tr -d ' '; }

echo "== scenario: $SCEN   (wall clock $(date -u +%FT%TZ))"
echo "== real forge: $("$REAL_GH" pr view "$PR_URL" --json headRefOid,statusCheckRollup --jq '"head=\(.headRefOid[:8]) checks=\(.statusCheckRollup|length) pending=\([.statusCheckRollup[]|select(.status!="COMPLETED")]|length) last_completed=\([.statusCheckRollup[]|.completedAt]|max)"')"
echo "== stubbed run record (what the pipeline reported):"
sed 's/^/   /' "$ROOT/run.toon" | tail -2
case "$SCEN" in
  running)
    echo '$ fm-crew-state.sh crew'; crew_state
    echo '$ fm-inactive-reconcile.sh scan --startup'; scan
    echo "   queued ci-monitor-behind wakes: $(queue_behind)   terminal outcomes: $(outcomes)"
    echo "(forge calls: $(wc -l < "$ROOT/gh.calls"))" ;;
  new-occurrence)
    # Same task (same meta/incarnation). First the run watches PR 5's head,
    # whose checks really settled at 15:36:48Z; then the task advances to a new
    # head (PR 6's) whose checks really settled later, at 17:30:54Z.
    P5_HEAD=b432757bf6f1107b6344064eded326aa9440feef
    git -C "$ROOT/wt" fetch -q --depth 1 https://github.com/karimghabra/firstmate.git "$P5_HEAD"
    git -C "$ROOT/wt" checkout -q -B fm/pr-replay "$P5_HEAD"
    sed -i "s|$PR_HEAD|$P5_HEAD|; s|\"${PR_HEAD:0:8}\"|\"${P5_HEAD:0:8}\"|; s|/pull/6|/pull/5|" "$ROOT/run.toon"
    echo "# occurrence A: run head ${P5_HEAD:0:8}, PR 5"
    echo '$ fm-inactive-reconcile.sh scan --startup'; scan
    echo "   queued ci-monitor-behind wakes: $(queue_behind)"
    echo '$ fm-inactive-reconcile.sh scan --startup   # same occurrence again'; scan
    echo "   queued ci-monitor-behind wakes: $(queue_behind)"
    git -C "$ROOT/wt" checkout -q -B fm/pr-replay "$PR_HEAD"
    sed -i "s|$P5_HEAD|$PR_HEAD|; s|\"${P5_HEAD:0:8}\"|\"${PR_HEAD:0:8}\"|; s|/pull/5|/pull/6|" "$ROOT/run.toon"
    echo "# occurrence B: task advanced to run head ${PR_HEAD:0:8}, PR 6 (checks settled later)"
    echo '$ fm-inactive-reconcile.sh scan --startup'; scan
    echo "   queued ci-monitor-behind wakes: $(queue_behind)   terminal outcomes: $(outcomes)   markers: $(ls "$ROOT/state/ci-monitor-behind" | wc -l)"
    echo '$ fm-crew-state.sh crew'; crew_state
    echo "(forge calls: $(wc -l < "$ROOT/gh.calls"))" ;;
  watch)
    # The real watcher poll, unmodified cadence inputs except fast poll: the
    # crew's files are two hours old (long-inactive), no clock override.
    touch -d '-2 hours' "$ROOT/state/crew.meta"
    echo '$ fm-watch.sh     # real watcher, FM_POLL=1; runs the inactive scan on its poll'
    PATH="$ROOT/fakebin:$PATH" FM_HOME="$ROOT" FM_STATE_OVERRIDE="$ROOT/state" FM_INACTIVE_RECONCILE_SECS=60 \
      FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      timeout 60 "$WT_SRC/bin/fm-watch.sh" > "$ROOT/watch.out" 2>&1
    echo "   watcher exit: $?"
    sed 's/^/   | /' "$ROOT/watch.out"
    echo "   queued ci-monitor-behind wakes: $(queue_behind)   terminal outcomes: $(outcomes)"
    grep $'\tci-monitor-behind:' "$ROOT/state/.wake-queue" | sed 's/^/   queue row: /'
    echo '$ fm-crew-state.sh crew'; crew_state
    echo "(forge calls: $(wc -l < "$ROOT/gh.calls"))" ;;
  blocked-claim)
    # A crewmate logged a timed-out drive call during the quiet ci wait. The
    # removed recency extension must not reinterpret it as a live run.
    printf 'blocked: no-mistakes axi run timed out after 10s, pipeline unreachable\n' > "$ROOT/state/crew.status"
    echo "$ cat state/crew.status"; sed 's/^/   /' "$ROOT/state/crew.status"
    echo '$ fm-crew-state.sh crew'; crew_state; echo "(forge calls: $(wc -l < "$ROOT/gh.calls"))" ;;
  behind|rerun-wait|head-moved|unreadable|monitor-green)
    echo '$ fm-crew-state.sh crew'; crew_state; echo "(forge calls: $(wc -l < "$ROOT/gh.calls"))" ;;
  poll-window)
    echo '# clock pinned to firstmate reading PR 6: 2026-09-11T17:32:03Z (69s after last settle)'
    echo '$ FM_CREW_STATE_NOW=<17:32:03Z> fm-crew-state.sh crew'
    FM_CREW_STATE_NOW=$(date -u -d 2026-09-11T17:32:03Z +%s) crew_state
    s=$(date -u -d 2026-09-11T17:30:54Z +%s)
    echo '$ FM_CREW_STATE_NOW=<settle+240s> fm-crew-state.sh crew'
    FM_CREW_STATE_NOW=$((s + 240)) crew_state
    echo '$ FM_CREW_STATE_NOW=<settle+241s> fm-crew-state.sh crew'
    FM_CREW_STATE_NOW=$((s + 241)) crew_state
    echo "(forge calls: $(wc -l < "$ROOT/gh.calls"))" ;;
  wake)
    echo '$ fm-inactive-reconcile.sh scan --startup      # 1st scan, monitor behind'
    scan; echo "   queued ci-monitor-behind wakes: $(queue_behind)   terminal outcomes: $(outcomes)"
    echo '$ fm-crew-state.sh crew'; crew_state
    echo '$ fm-inactive-reconcile.sh scan --startup      # 2nd scan, same occurrence (age moved on)'
    sleep 61
    scan; echo "   queued ci-monitor-behind wakes: $(queue_behind)   terminal outcomes: $(outcomes)"
    echo '$ fm-wake-drain.sh                            # the supervisor reads its wake'
    FM_HOME="$ROOT" FM_STATE_OVERRIDE="$ROOT/state" "$WT_SRC/bin/fm-wake-drain.sh" 2>"$ROOT/drain.err" | grep -i 'ci monitor behind' || true
    seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$ROOT/drain.err")
    gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$ROOT/drain.err")
    echo "\$ fm-wake-drain.sh --ack-through $seq ...     # supervisor acknowledges"
    FM_HOME="$ROOT" FM_STATE_OVERRIDE="$ROOT/state" "$WT_SRC/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
    echo "   queued ci-monitor-behind wakes: $(queue_behind)"
    echo '$ fm-inactive-reconcile.sh scan --startup      # 3rd scan after the wake was handled'
    scan; echo "   queued ci-monitor-behind wakes: $(queue_behind)   terminal outcomes: $(outcomes)   markers: $(ls "$ROOT/state/ci-monitor-behind" | wc -l)"
    echo '$ fm-crew-state.sh crew'; crew_state
    echo "(forge calls: $(wc -l < "$ROOT/gh.calls"))" ;;
  wake-negative)
    echo '# monitor waiting for a CI re-run (not claiming to wait for results)'
    printf '%s\n' "$CI_LOG_WAITING" 'issues detected: 1 failing check' 'fix already attempted for these issues, waiting for CI re-run...' > "$ROOT/ci.log"
    echo '$ fm-inactive-reconcile.sh scan --startup'; scan
    echo "   queued ci-monitor-behind wakes: $(queue_behind)   terminal outcomes: $(outcomes)"
    echo '$ fm-crew-state.sh crew'; crew_state
    echo '# checks inside the poll window (behind bound raised past the real settle age)'
    printf '%s\n' "$CI_LOG_WAITING" > "$ROOT/ci.log"
    echo '$ FM_CREW_STATE_CI_BEHIND_SECS=100000000 fm-inactive-reconcile.sh scan --startup'
    FM_CREW_STATE_CI_BEHIND_SECS=100000000 scan
    echo "   queued ci-monitor-behind wakes: $(queue_behind)   terminal outcomes: $(outcomes)"
    ;;
esac
