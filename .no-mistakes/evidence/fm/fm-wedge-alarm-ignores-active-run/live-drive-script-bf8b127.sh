#!/usr/bin/env bash
# Live drive of the stand-down state at head bf8b127, over a REAL tmux server, a
# REAL git worktree with unlanded work, a REAL tasks-axi backlog, and the real
# bin/fm-stand-down.sh / fm-crew-state.sh / fm-session-start.sh / fm-watch.sh.
#
# Head-specific focus: bf8b127 ("never classify a pause from the stand-down
# record alone"). Section 4 runs the same fixture against the PARENT commit's
# watcher to show the defect, then against this head's watcher to show it gone.
set -u
umask 022
ROOT=/home/mars/.no-mistakes/worktrees/a8c0c72d0935/01M29PX1Q4JF548VNWPBRRYDVX
SB=/tmp/fmlive-nd
export TMUX_TMPDIR="$SB/tmux"
export FM_GATE_REFUSE_BYPASS=1
export FM_HOME="$SB/home" FM_STATE_OVERRIDE="$SB/home/state" FM_ROOT_OVERRIDE="$SB/root"
STATE="$FM_STATE_OVERRIDE"
rm -rf "$SB"
mkdir -p "$STATE" "$SB/home/data" "$SB/home/config" "$SB/bin" "$SB/tmux" "$SB/wt" "$SB/root"
cp /usr/bin/sleep "$SB/bin/claude"   # a real process whose name is what the tmux backend classifies
git init -q -b main "$SB/root" && git -C "$SB/root" -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m init
git init -q -b main "$SB/wt" && git -C "$SB/wt" -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m init
git -C "$SB/wt" checkout -q -b fm/stop
echo 'unlanded work' > "$SB/wt/work.txt"
git -C "$SB/wt" add -A && git -C "$SB/wt" -c user.email=a@b.c -c user.name=t commit -q -m 'pushed, not landed'

# The shape `bin/fm-control.sh <id> exit` leaves behind: the tmux window and its
# shell survive, only the agent is gone.
tmux new-session -d -s fmlive -n fm-stop "bash --noprofile --norc"
sleep 1
printf 'window=fmlive:fm-stop\nkind=ship\nbackend=tmux\nworktree=%s\nbranch=fm/stop\n' "$SB/wt" > "$STATE/stop.meta"
printf 'done: PR 9 pushed, waiting on the captain to land it\n' > "$STATE/stop.status"
tasks-axi add stop "stand-down live drive: PR 9 pushed, not landed" --kind ship --start \
  --file "$SB/home/data/backlog.md" >/dev/null 2>&1

KEY=fmlive_fm-stop
probe() { bash -c '. "$1/bin/fm-backend.sh"; fm_backend_agent_state tmux "$2"' _ "$ROOT" "$1"; }
prime_seen() { bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_status_mark_current "$2" "$2/$3.status"' _ "$ROOT" "$STATE" "$1"; }
backdate() { touch -d "@$(( $(date +%s) - $2 ))" "$STATE/$1.status"; }
reset_markers() { rm -f "$STATE"/.hash-* "$STATE"/.count-* "$STATE"/.stale-* "$STATE"/.stale-since-* \
  "$STATE"/.paused-* "$STATE"/.wedge-escalations-* "$STATE"/.watch-triage.log; }
ack() {
  local err="$SB/drain.err" seq gen
  "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>"$err" || true
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$gen" ] && "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
  return 0
}
# One watcher process, run exactly as the always-on supervisor runs it. It exits
# after delivering one wake; the line it prints is the line firstmate is woken with.
watch_round() {  # <bin-dir> <escalate-secs> <resurface-secs> <limit-ticks>
  local bin=$1 esc=$2 res=$3 limit=$4 out="$SB/round.out" pid i=0
  : > "$out"
  FM_STALE_ESCALATE_SECS="$esc" FM_PAUSE_RESURFACE_SECS="$res" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$bin/fm-watch.sh" > "$out" 2>"$out.err" &
  pid=$!
  while [ "$i" -lt "$limit" ]; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; i=$((i+1)); done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    printf '(no wake - the watcher polled for %ss and never woke firstmate)\n' "$((limit/10))"
  else wait "$pid" 2>/dev/null; cat "$out"; fi
  ack
}

echo "LIVE DRIVE - stand-down state at head $(git -C "$ROOT" rev-parse --short HEAD)"
echo "tmux: $(tmux -V)   host: $(uname -sr)"
echo "isolated firstmate home: $SB/home   isolated tmux socket: $TMUX_TMPDIR/default"
echo "fmlive:fm-stop is a REAL tmux window whose agent was stopped; its shell survives"

printf '\n\n========== 1  RECORD: the state the fleet could not express ==========\n'
printf '$ (tmux backend agent-state probe) -> %s\n' "$(probe fmlive:fm-stop)"
printf '$ bin/fm-crew-state.sh stop   (before)\n'; "$ROOT/bin/fm-crew-state.sh" stop
printf '\n$ bin/fm-stand-down.sh stop --reason "captain stopped it; PR 9 pushed, waiting to land"\n'
"$ROOT/bin/fm-stand-down.sh" stop --reason 'captain stopped it; PR 9 pushed, waiting to land'; printf '[exit %s]\n' "$?"
printf '\n--- the two halves of the state ---\n$ cat state/stop.stood-down\n'; cat "$STATE/stop.stood-down"
printf '$ cat state/stop.status\n'; cat "$STATE/stop.status"
printf '\n$ bin/fm-crew-state.sh stop   (after)\n'; "$ROOT/bin/fm-crew-state.sh" stop

printf '\n\n========== 2  IT RECORDS NO COMPLETION AND DISCARDS NO WORK ==========\n'
printf '$ tasks-axi list --file home/data/backlog.md\n'
tasks-axi list --file "$SB/home/data/backlog.md" | sed -n 1,3p
printf '$ git -C wt log --oneline -1 && git -C wt status --short\n'
git -C "$SB/wt" log --oneline -1; git -C "$SB/wt" status --short; echo "(clean: the branch and its unlanded commit are untouched)"

printf '\n\n========== 3  THE SESSION-START DIGEST STOPS CALLING IT A RECOVERY TRIGGER ==========\n'
printf '$ bin/fm-session-start.sh | grep ^endpoint:\n'
env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT "$ROOT/bin/fm-session-start.sh" 2>&1 | grep '^endpoint:'

printf '\n\n========== 4  THE ALARM: the same idle pane, with and without the record ==========\n'
printf 'FM_STALE_ESCALATE_SECS=1 for both halves, so the wedge ladder is as eager as it can be.\n'
printf '\n--- 4a  WITH the stand-down recorded (record aged past the re-surface cadence) ---\n'
printf 'recorded=%s\nreason=captain stopped it; PR 9 pushed, waiting to land\n' "$(( $(date +%s) - 5000 ))" > "$STATE/stop.stood-down"
reset_markers; prime_seen stop; backdate stop 5000; ack
for r in 1 2 3; do printf 'round %s -> %s' "$r" "$(watch_round "$ROOT/bin" 1 240 150)"; echo; done
printf '$ ls state/.paused-%s state/.wedge-escalations-%s\n' "$KEY" "$KEY"
ls "$STATE/.paused-$KEY" >/dev/null 2>&1 && echo "  .paused-$KEY      present (the absorb survived the loop-top reconciliation)" || echo "  .paused-$KEY      ABSENT"
ls "$STATE/.wedge-escalations-$KEY" >/dev/null 2>&1 && echo "  .wedge-escalations-$KEY = $(cat "$STATE/.wedge-escalations-$KEY")" || echo "  .wedge-escalations-$KEY  absent (the wedge ladder never advanced)"
printf '$ what the watcher decided on every other poll (triage log, timestamps and ages folded):\n'
sed 's/^\[[^]]*\] //; s/age [0-9]*s/age Ns/' "$STATE/.watch-triage.log" 2>/dev/null | sort | uniq -c | sed 's/^/  /'

printf '\n--- 4b  ADVERSARIAL: release it, and the wedge ladder is exactly what it was ---\n'
printf '$ bin/fm-stand-down.sh stop --release\n'; "$ROOT/bin/fm-stand-down.sh" stop --release
printf '$ tail -1 state/stop.status -> %s\n' "$(tail -1 "$STATE/stop.status")"
reset_markers; prime_seen stop; backdate stop 5000; ack
for r in 1 2 3 4; do printf 'round %s -> %s' "$r" "$(watch_round "$ROOT/bin" 1 240 200)"; echo; done

printf '\n\n========== 5  HEAD FIX (bf8b127): a RECORD with no DECLARATION is not a pause ==========\n'
printf 'The pane was resumed without a relaunch, so the record survived; the restarted agent\n'
printf 'wrote its own working: line and then exited. fm-crew-state.sh honors the record (the\n'
printf 'agent really is gone), so the crew verdict is paused - but the log declares no wait.\n'
printf 'recorded=%s\nreason=captain stopped it; PR 9 pushed, waiting to land\n' "$(( $(date +%s) - 5000 ))" > "$STATE/stop.stood-down"
printf 'working: reindexing the backlog\n' > "$STATE/stop.status"
printf '\n$ bin/fm-crew-state.sh stop\n'; "$ROOT/bin/fm-crew-state.sh" stop
printf '$ tail -1 state/stop.status -> %s\n' "$(tail -1 "$STATE/stop.status")"

printf '\n--- 5a  the PARENT commit (c50ec8b) watcher on this fixture: the defect ---\n'
rm -rf "$SB/binbase"; cp -r "$ROOT/bin" "$SB/binbase"
git -C "$ROOT" show c50ec8b:bin/fm-watch.sh > "$SB/binbase/fm-watch.sh"; chmod +x "$SB/binbase/fm-watch.sh"
reset_markers; prime_seen stop; backdate stop 5000; ack
for r in 1 2 3; do printf 'round %s -> %s' "$r" "$(watch_round "$SB/binbase" 1 240 150)"; echo; done
ls "$STATE/.paused-$KEY" >/dev/null 2>&1 && echo "  .paused-$KEY present - and the next poll's reconciliation strips it, which is why every round wakes again" || echo "  .paused-$KEY absent"

printf '\n--- 5b  THIS head (bf8b127) on the identical fixture ---\n'
reset_markers; prime_seen stop; backdate stop 5000; ack
for r in 1 2 3; do printf 'round %s -> %s' "$r" "$(watch_round "$ROOT/bin" 1 240 150)"; echo; done
ls "$STATE/.paused-$KEY" >/dev/null 2>&1 && echo "  .paused-$KEY present" || echo "  .paused-$KEY absent (no pause marker for a wait nobody declared)"
echo "  .wedge-escalations-$KEY = $(cat "$STATE/.wedge-escalations-$KEY" 2>/dev/null || echo absent)  (the ordinary ladder, once per threshold)"

printf '\n\n========== 6  ADVERSARIAL: a record nobody can parse restores the ordinary alarm ==========\n'
printf 'done: PR 9 pushed, waiting on the captain\nstood-down: captain stopped it\n' > "$STATE/stop.status"
printf 'reason=captain stopped it\n' > "$STATE/stop.stood-down"   # half-written: the epoch never landed
printf '$ cat state/stop.stood-down -> %s\n' "$(cat "$STATE/stop.stood-down")"
printf '$ tail -1 state/stop.status -> %s\n' "$(tail -1 "$STATE/stop.status")"
printf '$ bin/fm-crew-state.sh stop\n'; "$ROOT/bin/fm-crew-state.sh" stop
reset_markers; prime_seen stop; backdate stop 5000; ack
for r in 1 2; do printf 'round %s -> %s' "$r" "$(watch_round "$ROOT/bin" 1 240 150)"; echo; done

printf '\n\n========== 7  ADVERSARIAL: it must not quieten a crewmate that is actually running ==========\n'
rm -f "$STATE/stop.stood-down"
printf 'done: PR 9 pushed, waiting on the captain\n' > "$STATE/stop.status"
printf '$ (the agent is started again in the same pane, by a route that is not a relaunch)\n'
tmux send-keys -t fmlive:fm-stop "exec $SB/bin/claude 100000" Enter
sleep 2
printf '$ tmux list-panes -t fmlive:fm-stop -F "#{pane_current_command}" -> %s\n' "$(tmux list-panes -t fmlive:fm-stop -F '#{pane_current_command}')"
printf '$ (tmux backend agent-state probe) -> %s\n' "$(probe fmlive:fm-stop)"
printf '\n$ bin/fm-stand-down.sh stop --reason "quiet this alarm"\n'
"$ROOT/bin/fm-stand-down.sh" stop --reason 'quiet this alarm'; printf '[exit %s]\n' "$?"
printf '$ ls state/stop.stood-down\n'; ls "$STATE/stop.stood-down" 2>&1 | tail -1
printf '$ cat state/stop.status   (untouched)\n'; cat "$STATE/stop.status"

printf '\n--- 7b  and a record written while it WAS stopped never covers for it afterwards ---\n'
printf 'recorded=%s\nreason=captain stopped it; PR 9 pushed, waiting to land\n' "$(( $(date +%s) - 5000 ))" > "$STATE/stop.stood-down"
printf 'done: PR 9 pushed, waiting on the captain\nstood-down: captain stopped it; PR 9 pushed, waiting to land\n' > "$STATE/stop.status"
printf '$ bin/fm-crew-state.sh stop\n'; "$ROOT/bin/fm-crew-state.sh" stop
printf '$ bin/fm-session-start.sh | grep ^endpoint:\n'
env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT "$ROOT/bin/fm-session-start.sh" 2>&1 | grep '^endpoint:'
reset_markers; prime_seen stop; backdate stop 5000; ack
for r in 1 2 3; do printf 'round %s -> %s' "$r" "$(watch_round "$ROOT/bin" 1 240 200)"; echo; done
ls "$STATE/.paused-$KEY" >/dev/null 2>&1 && echo "  .paused-$KEY present" || echo "  .paused-$KEY absent (a live agent is never absorbed on the stand-down cadence)"

printf '\n\n========== 8  ADVERSARIAL: the argument and backend refusals ==========\n'
printf '$ bin/fm-stand-down.sh stop --reason "captain stopped it" --release\n'
"$ROOT/bin/fm-stand-down.sh" stop --reason 'captain stopped it' --release; printf '[exit %s]\n' "$?"
printf '$ bin/fm-stand-down.sh stop --release --reason "captain stopped it"\n'
"$ROOT/bin/fm-stand-down.sh" stop --release --reason 'captain stopped it'; printf '[exit %s]\n' "$?"
printf '$ bin/fm-stand-down.sh stop\n'; "$ROOT/bin/fm-stand-down.sh" stop; printf '[exit %s]\n' "$?"
printf '$ bin/fm-stand-down.sh stop --reason "<two lines>"\n'
"$ROOT/bin/fm-stand-down.sh" stop --reason "$(printf 'two\nlines')"; printf '[exit %s]\n' "$?"
printf '$ bin/fm-stand-down.sh ../escape --reason x\n'
"$ROOT/bin/fm-stand-down.sh" ../escape --reason x; printf '[exit %s]\n' "$?"
printf 'window=zj:fm-zel\nkind=ship\nbackend=zellij\n' > "$STATE/zel.meta"
printf '$ bin/fm-stand-down.sh zel --reason "captain stopped it"   (a backend that cannot prove liveness)\n'
"$ROOT/bin/fm-stand-down.sh" zel --reason 'captain stopped it'; printf '[exit %s]\n' "$?"
printf 'kind=ship\nbackend=tmux\n' > "$STATE/nowin.meta"
printf '$ bin/fm-stand-down.sh nowin --reason "captain stopped it"   (no endpoint recorded)\n'
"$ROOT/bin/fm-stand-down.sh" nowin --reason 'captain stopped it'; printf '[exit %s]\n' "$?"
printf '$ bin/fm-stand-down.sh ghost --reason x   (no such task)\n'
"$ROOT/bin/fm-stand-down.sh" ghost --reason x; printf '[exit %s]\n' "$?"

echo
echo "=== END OF LIVE DRIVE ==="
tmux kill-server 2>/dev/null
exit 0
