#!/usr/bin/env bash
# Away mode (/afk): the real bin/fm-supervise-daemon.sh, supervising a real tmux
# task window. A/B on one task: the same idle, agent-free pane with and without a
# recorded stand-down.
set -u
umask 022
ROOT=/home/mars/.no-mistakes/worktrees/a8c0c72d0935/01M29PX1Q4JF548VNWPBRRYDVX
LIVE=/tmp/fmlive/home3
export TMUX_TMPDIR=/tmp/fmlive/tmux3
export FM_GATE_REFUSE_BYPASS=1
export FM_HOME="$LIVE" FM_STATE_OVERRIDE="$LIVE/state" FM_ROOT_OVERRIDE=/tmp/fmlive/root3
rm -rf "$LIVE" "$TMUX_TMPDIR" /tmp/fmlive/root3
mkdir -p "$LIVE/state" "$LIVE/bin" "$LIVE/data" "$LIVE/config" "$TMUX_TMPDIR" "$LIVE/wt/harbor"
cp /usr/bin/sleep "$LIVE/bin/claude"
git init -q -b main /tmp/fmlive/root3 && git -C /tmp/fmlive/root3 config user.email a@b.c \
  && git -C /tmp/fmlive/root3 config user.name t && git -C /tmp/fmlive/root3 commit -q --allow-empty -m init
( cd "$LIVE/wt/harbor" && git init -q . && git config user.email a@b.c && git config user.name t && echo w > f && git add -A && git commit -qm w )
tmux new-session -d -s fmlive -n supervisor
tmux send-keys -t fmlive:supervisor "clear; cat" C-m
tmux new-window -t fmlive -n fm-harbor
sleep 1
printf 'window=fmlive:fm-harbor\nkind=ship\nharness=claude\nworktree=%s\nproject=harbor\n' "$LIVE/wt/harbor" > "$LIVE/state/harbor.meta"
printf 'working: still implementing the harbor migration\n' > "$LIVE/state/harbor.status"
touch "$LIVE/state/.afk"

reset() { rm -f "$LIVE/state"/.stale-* "$LIVE/state"/.paused-* "$LIVE/state"/.wedge-* "$LIVE/state"/.hash-* \
  "$LIVE/state"/.count-* "$LIVE/state/.subsuper-escalations" "$LIVE/state"/.subsuper-paused-* \
  "$LIVE/state/.subsuper-last-housekeep" "$LIVE/state"/.subsuper-seen-* "$LIVE/state/.wake-queue" "$LIVE/state/.wake-queue.seq"; }
run_daemon() {  # <seconds> <pause-resurface>
  env FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_STALE_ESCALATE_SECS=3 FM_PAUSE_RESURFACE_SECS="$2" FM_HOUSEKEEPING_TICK=2 FM_ESCALATE_BATCH_SECS=999999 \
    FM_SUPERVISOR_TARGET=fmlive:supervisor FM_SUPERVISOR_BACKEND=tmux \
    "$ROOT/bin/fm-supervise-daemon.sh" > /tmp/fmlive/daemon-live.out 2>&1 &
  local p=$!; sleep "$1"; kill "$p" 2>/dev/null; sleep 1; kill -9 "$p" 2>/dev/null; pkill -f "$ROOT/bin/fm-watch.sh" 2>/dev/null; wait "$p" 2>/dev/null; true; }

echo "AWAY-MODE (/afk) LIVE DRIVE - bin/fm-supervise-daemon.sh over a real tmux window"
echo "repo head: $(git -C "$ROOT" rev-parse --short HEAD)   tmux: $(tmux -V)"
echo "task fmlive:fm-harbor: real window, agent-free idle shell, status log last line 'working: ...'"
echo "away flag state/.afk present; FM_STALE_ESCALATE_SECS=3"

printf '\n\n===== A: NO stand-down recorded - the alarm this task is about =====\n'
reset; run_daemon 55 3600
printf '$ cat state/.subsuper-escalations   (what the away daemon queues for the captain)\n'
cat "$LIVE/state/.subsuper-escalations" 2>/dev/null; echo "[end]"

printf '\n\n===== B: the SAME pane, stand-down recorded =====\n'
printf '$ fm-stand-down.sh harbor --reason "captain stopped this crewmate on purpose; awaiting a decision"\n'
"$ROOT/bin/fm-stand-down.sh" harbor --reason 'captain stopped this crewmate on purpose; awaiting a decision'
reset; run_daemon 55 3600
printf '$ cat state/.subsuper-escalations\n'; cat "$LIVE/state/.subsuper-escalations" 2>/dev/null; echo "[end]"
printf '$ ls state/.subsuper-paused-*   (the pane is on the pause marker, not the wedge marker)\n'
ls "$LIVE/state"/.subsuper-paused-* 2>&1 | sed "s#$LIVE/##"
ls "$LIVE/state"/.subsuper-stale-* 2>/dev/null | sed "s#$LIVE/##" || echo "(no wedge stale marker)"

printf '\n\n===== C: and the absorb is BOUNDED - one recheck per cadence, never a wedge =====\n'
reset; run_daemon 70 15
printf '$ cat state/.subsuper-escalations   (FM_PAUSE_RESURFACE_SECS=15, 70s of supervision)\n'
cat "$LIVE/state/.subsuper-escalations" 2>/dev/null; echo "[end]"
echo; echo "=== END OF AWAY-MODE DRIVE ==="
tmux kill-server 2>/dev/null
