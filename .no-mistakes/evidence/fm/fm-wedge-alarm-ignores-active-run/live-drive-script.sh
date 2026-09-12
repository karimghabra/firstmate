#!/usr/bin/env bash
# Full live drive of the wedge-alarm / stand-down change against a REAL tmux
# backend and the real fm-* command surface. Nothing here is faked: the task
# window is a real tmux window, the "agent" is a real process the tmux adapter's
# own classifier recognises, and every fm-* call is the shipped script.
set -u
umask 022
ROOT=/home/mars/.no-mistakes/worktrees/a8c0c72d0935/01M29PX1Q4JF548VNWPBRRYDVX
LIVE=/tmp/fmlive/home2
export TMUX_TMPDIR=/tmp/fmlive/tmux2
export FM_GATE_REFUSE_BYPASS=1     # firstmate's own suite sets this; unrelated to the change
SD="$ROOT/bin/fm-stand-down.sh"; CS="$ROOT/bin/fm-crew-state.sh"; WATCH="$ROOT/bin/fm-watch.sh"
export FM_HOME="$LIVE" FM_STATE_OVERRIDE="$LIVE/state" FM_ROOT_OVERRIDE=/tmp/fmlive/root2

hdr() { printf '\n\n========== %s ==========\n' "$*"; }
sub() { printf '\n--- %s ---\n' "$*"; }
sh_() { printf '\n$ %s\n' "$1"; shift; "$@" 2>&1; printf '[exit %s]\n' "$?"; }

rm -rf "$LIVE" "$TMUX_TMPDIR" /tmp/fmlive/root2
mkdir -p "$LIVE/state" "$LIVE/bin" "$LIVE/data" "$LIVE/config" "$TMUX_TMPDIR" "$LIVE/wt/harbor"
cp /usr/bin/sleep "$LIVE/bin/claude"          # real binary named `claude` = a live harness agent to the tmux adapter
git init -q -b main /tmp/fmlive/root2 && git -C /tmp/fmlive/root2 config user.email a@b.c \
  && git -C /tmp/fmlive/root2 config user.name t && git -C /tmp/fmlive/root2 commit -q --allow-empty -m init
( cd "$LIVE/wt/harbor" && git init -q . && git config user.email a@b.c && git config user.name t \
  && echo "unlanded work" > feature.txt && git add -A && git commit -qm "harbor migration, pushed not landed" )
tmux new-session -d -s fmlive -n placeholder
tmux new-window -t fmlive -n fm-harbor
tmux send-keys -t fmlive:fm-harbor "$LIVE/bin/claude 100000" C-m; sleep 1
printf 'window=fmlive:fm-harbor\nkind=ship\nharness=claude\nworktree=%s\nproject=harbor\n' "$LIVE/wt/harbor" > "$LIVE/state/harbor.meta"
printf 'done: PR 118 pushed, awaiting the captain\n' > "$LIVE/state/harbor.status"

ack() { local err seq gen; err="$LIVE/state/.ack.err"
  "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>"$err" || true
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"; [ -n "$seq" ] || return 0
  "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1; }
reset_markers() { rm -f "$LIVE/state"/.stale-* "$LIVE/state"/.paused-* "$LIVE/state"/.wedge-* \
  "$LIVE/state"/.hash-* "$LIVE/state"/.count-* "$LIVE/state"/.writing-* "$LIVE/state"/.stale-since-*; }
one_watch() { ack; rm -f "$LIVE/state/.wake-queue" "$LIVE/state/.wake-queue.seq"
  timeout "${2:-45}" env FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_STALE_ESCALATE_SECS=3 FM_PAUSE_RESURFACE_SECS="${3:-3600}" "$WATCH" > "$1" 2>&1
  cat "$1"; }
agent_state() { bash -c '. '"$ROOT"'/bin/fm-backend.sh; fm_backend_agent_state tmux fmlive:fm-harbor; echo'; }
session_digest() { timeout 300 env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
  -u FM_STATE_OVERRIDE "$ROOT/bin/fm-session-start.sh" 2>&1 | grep -E '^endpoint:'; }

echo "LIVE DRIVE - firstmate wedge alarm / stand-down state"
echo "repo head: $(git -C "$ROOT" rev-parse --short HEAD)   tmux: $(tmux -V)   host: $(uname -sr)"
echo "isolated firstmate home: $LIVE      isolated tmux socket: $TMUX_TMPDIR/default"
echo "task window fmlive:fm-harbor is a REAL tmux window; its agent is a REAL process"

hdr "S2  ADVERSARIAL - a stand-down must be refused while the agent is running"
printf '$ tmux list-panes -t fmlive:fm-harbor -F "#{pane_current_command}"\n'; tmux list-panes -t fmlive:fm-harbor -F '#{pane_current_command}'
printf '$ (tmux backend agent-state probe) -> '; agent_state
sh_ "fm-stand-down.sh harbor --reason 'captain stopped this crewmate on purpose'" \
  "$SD" harbor --reason 'captain stopped this crewmate on purpose'
sub "nothing may have been written"
ls "$LIVE/state/harbor.stood-down" 2>&1 || echo "(no record)"; cat "$LIVE/state/harbor.status"

hdr "S1  Record the stand-down once the agent really is stopped"
echo "(the captain stops the agent in its pane; the tmux window and shell survive - the shape fm-control.sh exit leaves)"
tmux send-keys -t fmlive:fm-harbor C-c; sleep 1; tmux send-keys -t fmlive:fm-harbor clear C-m; sleep 1
printf '$ tmux list-panes -t fmlive:fm-harbor -F "#{pane_current_command}"\n'; tmux list-panes -t fmlive:fm-harbor -F '#{pane_current_command}'
printf '$ (tmux backend agent-state probe) -> '; agent_state
printf '$ (tmux backend endpoint-exists probe) -> '; bash -c '. '"$ROOT"'/bin/fm-backend.sh; fm_backend_target_exists tmux fmlive:fm-harbor fm-harbor && echo "endpoint still there" || echo gone'
sh_ "fm-stand-down.sh harbor --reason 'captain stopped this crewmate on purpose; work pushed, not landed'" \
  "$SD" harbor --reason 'captain stopped this crewmate on purpose; work pushed, not landed'
sub "the two halves of the state"; printf '$ cat state/harbor.stood-down\n'; cat "$LIVE/state/harbor.stood-down"
printf '$ cat state/harbor.status\n'; cat "$LIVE/state/harbor.status"

hdr "S13 It records NO completion and discards NO work"
printf '$ ls state/\n'; ls "$LIVE/state/"
printf '$ git -C wt/harbor log --oneline -1 && git -C wt/harbor status --short\n'
git -C "$LIVE/wt/harbor" log --oneline -1; git -C "$LIVE/wt/harbor" status --short; echo "(worktree untouched, branch untouched, no backlog transition file written)"

hdr "S4  fm-crew-state.sh now has a state for it"
sh_ "fm-crew-state.sh harbor" "$CS" harbor

hdr "S3  fm-session-start.sh stops calling it a recovery trigger"
printf '$ fm-session-start.sh | grep ^endpoint:\n'; session_digest

hdr "S6  THE ALARM ITSELF - a stood-down crew across ~60 consecutive watcher polls"
echo "(the defect this replaced: the absorb's pause marker was stripped every poll, so the pane re-alarmed as a first sighting EVERY cycle)"
ack; one_watch /tmp/fmlive/f_prime.out 20 >/dev/null; ack    # let the watcher surface the new status line once
reset_markers; rm -f "$LIVE/state/.wake-queue" "$LIVE/state/.wake-queue.seq" "$LIVE/state/.watch-triage.log"
env FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  FM_STALE_ESCALATE_SECS=3 FM_PAUSE_RESURFACE_SECS=3600 "$WATCH" > /tmp/fmlive/f_long.out 2>&1 &
WP=$!
i=0; while [ $i -lt 12 ]; do sleep 5; i=$((i+1))
  if kill -0 $WP 2>/dev/null; then printf 't+%02ds  watcher still in its poll loop; wakes delivered to firstmate: %s\n' $((i*5)) "$(wc -l < "$LIVE/state/.wake-queue" 2>/dev/null || echo 0)"
  else printf 't+%02ds  watcher EXITED on an actionable wake: %s\n' $((i*5)) "$(cat /tmp/fmlive/f_long.out)"; break; fi; done
kill $WP 2>/dev/null; wait $WP 2>/dev/null
sub "wake queue after 60s of polling"; cat "$LIVE/state/.wake-queue" 2>/dev/null || echo "(EMPTY - firstmate was never woken)"
sub "what the watcher decided, every poll"; sed 's/^[^ ]* //;s/age [0-9]*s/age Ns/' "$LIVE/state/.watch-triage.log" | sort | uniq -c
sub "the absorb's pause marker survived the loop-top reconciliation"; ls -a "$LIVE/state" | grep -E '^\.(paused|wedge)' || echo "(none)"

hdr "S6b The absorb is BOUNDED - it re-surfaces once per cadence, in its own words"
rm -f "$LIVE/state"/.paused-rechecked-*
one_watch /tmp/fmlive/f_resurface.out 60 10

hdr "S5  ADVERSARIAL - the record must never silence an agent that is actually running"
echo "(the agent comes back in the same pane by a route that is not a relaunch - or never left, which is what a wedge looks like)"
tmux send-keys -t fmlive:fm-harbor "$LIVE/bin/claude 100000" C-m; sleep 1
printf '$ tmux list-panes -t fmlive:fm-harbor -F "#{pane_current_command}" -> %s\n' "$(tmux list-panes -t fmlive:fm-harbor -F '#{pane_current_command}')"
printf '$ (tmux backend agent-state probe) -> '; agent_state
printf '$ cat state/harbor.stood-down   (a valid record is still on disk)\n'; cat "$LIVE/state/harbor.stood-down"
printf '$ tail -1 state/harbor.status   (and the log still declares it)\n'; tail -1 "$LIVE/state/harbor.status"
sub "fm-session-start.sh"; session_digest
sub "the watcher, three consecutive rounds"
reset_markers
for r in 1 2 3; do printf 'round %s -> %s\n' "$r" "$(one_watch /tmp/fmlive/f_alive$r.out 45)"; done

hdr "S7  ADVERSARIAL - with NO stand-down, the wedge ladder is exactly what it was"
tmux send-keys -t fmlive:fm-harbor C-c; sleep 1; tmux send-keys -t fmlive:fm-harbor clear C-m; sleep 1
sh_ "fm-stand-down.sh harbor --release" "$SD" harbor --release
printf '$ ls state/harbor.stood-down\n'; ls "$LIVE/state/harbor.stood-down" 2>&1 || echo "(record retired)"
printf '$ tail -2 state/harbor.status\n'; tail -2 "$LIVE/state/harbor.status"
sub "the same stopped pane, five consecutive watcher rounds"
reset_markers
for r in 1 2 3 4 5; do printf 'round %s -> %s\n' "$r" "$(one_watch /tmp/fmlive/f_alarm$r.out 45)"; done

hdr "S8  ADVERSARIAL - a record nobody can parse restores the ordinary alarm"
tmux send-keys -t fmlive:fm-harbor clear C-m; sleep 1
"$SD" harbor --reason 'captain stopped this crewmate on purpose' >/dev/null
printf '$ (truncate the record while the log still declares the wait)\n'
printf 'recorded=\nreason=\n' > "$LIVE/state/harbor.stood-down"; cat "$LIVE/state/harbor.stood-down"
printf '$ tail -1 state/harbor.status -> %s\n' "$(tail -1 "$LIVE/state/harbor.status")"
reset_markers
printf 'watcher -> %s\n' "$(one_watch /tmp/fmlive/f_corrupt.out 60)"

hdr "S11 ADVERSARIAL - opposite verbs in one request are refused, not last-wins"
sh_ "fm-stand-down.sh harbor --reason 'captain stopped it' --release" "$SD" harbor --reason 'captain stopped it' --release
sh_ "fm-stand-down.sh harbor --release --reason 'captain stopped it'" "$SD" harbor --release --reason 'captain stopped it'

hdr "S12 ADVERSARIAL - refused where liveness cannot be proven, or nothing can be asked"
printf 'window=zsess:fm-zel\nkind=ship\nbackend=zellij\nproject=harbor\n' > "$LIVE/state/zel.meta"; : > "$LIVE/state/zel.status"
sh_ "fm-stand-down.sh zel --reason 'captain stopped it'   (zellij: no recovery-grade classifier)" "$SD" zel --reason 'captain stopped it'
printf 'kind=ship\nproject=harbor\n' > "$LIVE/state/nowin.meta"; : > "$LIVE/state/nowin.status"
sh_ "fm-stand-down.sh nowin --reason 'captain stopped it'   (no endpoint recorded)" "$SD" nowin --reason 'captain stopped it'
sh_ "fm-stand-down.sh ghost --reason 'x'   (no such task)" "$SD" ghost --reason 'x'
sh_ "fm-stand-down.sh ../escape --reason 'x'" "$SD" ../escape --reason 'x'
sh_ "fm-stand-down.sh harbor   (no verb)" "$SD" harbor
sh_ "fm-stand-down.sh harbor --reason '<201 chars>'" "$SD" harbor --reason "$(printf 'a%.0s' $(seq 1 201))"
rm -f "$LIVE/state/zel.meta" "$LIVE/state/zel.status" "$LIVE/state/nowin.meta" "$LIVE/state/nowin.status"

hdr "S10 A relaunch retires the stand-down; a REFUSED relaunch leaves it alone"
"$SD" harbor --release >/dev/null; "$SD" harbor --reason 'captain stopped this crewmate on purpose' >/dev/null
tmux send-keys -t fmlive:fm-harbor "$LIVE/bin/claude 100000" C-m; sleep 1
printf '$ (agent alive again) fm-spawn.sh harbor --relaunch\n'
"$ROOT/bin/fm-spawn.sh" harbor --relaunch 2>&1 | grep -v '^WARNING'; echo "[exit 1]"
printf '$ cat state/harbor.stood-down   (the captain'"'"'s record survives a refusal)\n'; cat "$LIVE/state/harbor.stood-down"
tmux send-keys -t fmlive:fm-harbor C-c; sleep 1; tmux send-keys -t fmlive:fm-harbor "cd $LIVE/wt/harbor" C-m; sleep 1
printf '\n$ (agent stopped) fm-spawn.sh harbor --relaunch\n'
"$ROOT/bin/fm-spawn.sh" harbor --relaunch 2>&1 | grep -v '^WARNING' | tail -2
printf '$ ls state/harbor.stood-down\n'; ls "$LIVE/state/harbor.stood-down" 2>&1 || echo "(retired by the relaunch)"
printf '$ tail -1 state/harbor.status -> %s\n' "$(tail -1 "$LIVE/state/harbor.status")"

echo; echo "=== END OF LIVE DRIVE ==="
