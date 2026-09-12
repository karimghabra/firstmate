#!/usr/bin/env bash
# The one deferral this change KEEPS (bin/fm-watch.sh wedge_defer_writing): a crew
# whose pane is quiet while its own task worktree is demonstrably still being
# written is deferred rather than escalated - and re-escalates the moment the
# writes stop. Driven against the real bin/fm-watch.sh over a real tmux window and
# a real git worktree. This is the path the branch reverted its pipeline-ownership
# experiments back to, so it is worth seeing it still behaves as base did.
set -u
umask 022
ROOT=/home/mars/.no-mistakes/worktrees/a8c0c72d0935/01M29PX1Q4JF548VNWPBRRYDVX
SB=/tmp/fmlive-wd
export TMUX_TMPDIR="$SB/tmux" FM_GATE_REFUSE_BYPASS=1
export FM_HOME="$SB/home" FM_STATE_OVERRIDE="$SB/home/state" FM_ROOT_OVERRIDE="$SB/root"
STATE="$FM_STATE_OVERRIDE"
rm -rf "$SB"; mkdir -p "$STATE" "$SB/home/data" "$SB/home/config" "$SB/tmux" "$SB/wt" "$SB/root"
git init -q -b main "$SB/root" && git -C "$SB/root" -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m init
git init -q -b main "$SB/wt" && git -C "$SB/wt" -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m init
tmux new-session -d -s fmlive -n fm-busy "bash --noprofile --norc"; sleep 1
printf 'window=fmlive:fm-busy\nkind=ship\nbackend=tmux\nworktree=%s\n' "$SB/wt" > "$STATE/busy.meta"
printf 'working: implementing the harbor migration\n' > "$STATE/busy.status"
bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_status_mark_current "$2" "$2/busy.status"' _ "$ROOT" "$STATE"
touch -d "@$(( $(date +%s) - 5000 ))" "$STATE/busy.status"
KEY=fmlive_fm-busy
ack() {
  local err="$SB/drain.err" seq gen
  "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>"$err" || true
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$gen" ] && "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
  return 0
}
run_watch() {  # <limit-ticks>
  local limit=$1 out="$SB/round.out" pid i=0
  : > "$out"
  FM_STALE_ESCALATE_SECS=3 FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" > "$out" 2>&1 &
  pid=$!
  while [ "$i" -lt "$limit" ]; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; i=$((i+1)); done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    printf '(no wake - the watcher polled for %ss and never woke firstmate)\n' "$((limit/10))"
  else wait "$pid" 2>/dev/null; cat "$out"; fi
  ack
}

echo "WORKTREE-WRITE DEFERRAL LIVE DRIVE - head $(git -C "$ROOT" rev-parse --short HEAD)"
echo "fmlive:fm-busy: a real tmux window with a quiet pane; its task worktree is $SB/wt"
echo "FM_STALE_ESCALATE_SECS=3"

printf '\n--- first sighting of the quiet pane ---\n'
ack; printf '%s' "$(run_watch 250)"; echo

printf '\n--- the crew keeps writing its own worktree while the pane stays quiet ---\n'
( for i in $(seq 1 20); do sleep 2; echo "progress $i" >> "$SB/wt/notes.txt"; done ) & writer=$!
printf '%s' "$(run_watch 300)"; echo
kill "$writer" 2>/dev/null; wait "$writer" 2>/dev/null
printf '$ ls state/.writing-since-%s -> %s\n' "$KEY" "$(ls "$STATE/.writing-since-$KEY" >/dev/null 2>&1 && echo present || echo absent)"
printf '$ what the watcher decided (triage log, timestamps and ages folded):\n'
sed 's/^\[[^]]*\] //; s/idle [0-9]*s/idle Ns/' "$STATE/.watch-triage.log" 2>/dev/null | sort | uniq -c | sed 's/^/  /'

printf '\n--- and it is a DEFERRAL, not a silencer: the writes stop, the alarm returns ---\n'
printf '%s' "$(run_watch 300)"; echo
printf '$ cat state/.wedge-escalations-%s -> %s\n' "$KEY" "$(cat "$STATE/.wedge-escalations-$KEY" 2>/dev/null || echo absent)"
echo
echo "=== END ==="
tmux kill-server 2>/dev/null
exit 0
