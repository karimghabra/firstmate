#!/usr/bin/env bash
# Live driver: /afk entry on a real Claude Code primary, then the real Claude
# Stop asyncRewake hook (bin/fm-claude-stop-autoarm.sh) with the real watcher.
#
# Runs inside a genuine Claude Code process tree (CLAUDECODE=1, harness ancestor
# = the running `claude` process), so bin/fm-harness.sh detects claude for real
# and the hook's session-lock identity check resolves the real harness pid.
# Every firstmate home is a throwaway checkout under /tmp; tmux runs on a
# private TMUX_TMPDIR server. Nothing in the worktree or a live home is touched.
#
# Usage: drive-claude-afk-live.sh <phase>
#   target-entry   /afk entry at the target commit, then Stop hook rewake
#   base-entry     same flow at the base commit (reproduces the regression)
#   leftover-flag  an older (base) launch leaves state/.afk; target start-native releases it
#   live-daemon    real daemon on a daemon-running harness (grok marker) keeps
#                  launching; a Claude refusal leaves the live daemon's flag alone
set -u
WT=/home/mars/.no-mistakes/worktrees/a8c0c72d0935/01M28M4Y7T9B6B7WTW87WNWYMR
BASE=c08b78282148fd8d8bc790b97a11fc9c958e385a
TARGET=73eeb4c19d1342c310215a5041ea8546358a74c7
LABROOT=${LABROOT:-/tmp/fm-afk-claude-live}
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION FM_STATE_OVERRIDE FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND
export TMUX_TMPDIR="$LABROOT/tmux"
mkdir -p "$TMUX_TMPDIR"

say() { printf '\n$ %s\n' "$*"; }
run() { say "$*"; "$@"; local rc=$?; printf '[exit %s]\n' "$rc"; return 0; }
show_state() {
  local h=$1 f
  printf -- '--- state of %s ---\n' "$h"
  for f in .afk .afk-contract .afk-daemon-terminal .supervise-daemon.lock; do
    if [ -e "$h/state/$f" ]; then printf '  state/%-24s PRESENT\n' "$f"; else printf '  state/%-24s absent\n' "$f"; fi
  done
  printf '  supervise-daemon processes for this home: %s\n' \
    "$(pgrep -f "$h/bin/fm-supervise-daemon.sh" | tr '\n' ' ' || true)"
}

make_home() {  # <rev> <dir>
  local rev=$1 dir=$2
  rm -rf "$dir"; mkdir -p "$dir"
  git -C "$WT" archive "$rev" | tar -x -C "$dir"
  git -C "$dir" init -q
  git -C "$dir" -c user.name=lab -c user.email=lab@example.invalid add -A
  git -C "$dir" -c user.name=lab -c user.email=lab@example.invalid commit -q -m "lab $rev"
  mkdir -p "$dir/state" "$dir/config" "$dir/data"
}

afk_entry() {  # <home>
  local h=$1
  export FM_HOME="$h"
  say "bin/fm-harness.sh   # harness this session is detected as"
  "$h/bin/fm-harness.sh"
  run "$h/bin/fm-afk-launch.sh" propose
  run "$h/bin/fm-afk-launch.sh" confirm
  # SKILL.md phase 4 at the base commit sends Claude to start-native; the
  # target's SKILL.md says stop after confirm. Drive both daemon verbs anyway,
  # as an agent following the old skill (or trying `start`) would.
  run "$h/bin/fm-afk-launch.sh" start-native
  run "$h/bin/fm-afk-launch.sh" start
  show_state "$h"
}

# The Stop hook, fired the way Claude's asyncRewake fires it, from inside this
# real Claude process tree, holding the home's session lock with the real
# harness pid. In-flight work exists (a task meta), the real watcher is armed by
# the hook, and a crewmate then posts a needs-decision status.
stop_hook_cycle() {  # <home>
  local h=$1 hook_out hook_pid rc i
  export FM_HOME="$h"
  printf '%s\n' "$CLAUDE_PID" > "$h/state/.lock"
  printf 'project=lab\nwindow=lab-crew\nbackend=tmux\n' > "$h/state/lab-crew.meta"
  hook_out="$h/../stop-hook.$(basename "$h").out"
  say "printf '{\"session_id\":\"lab\",\"stop_hook_active\":false}' | bin/fm-claude-stop-autoarm.sh   # Claude Stop asyncRewake"
  printf '{"session_id":"lab","stop_hook_active":false}\n' \
    | FM_POLL=2 timeout 150 "$h/bin/fm-claude-stop-autoarm.sh" >"$hook_out" 2>&1 &
  hook_pid=$!
  for i in $(seq 1 40); do
    kill -0 "$hook_pid" 2>/dev/null || break
    [ -e "$h/state/.last-watcher-beat" ] && break
    sleep 0.5
  done
  if kill -0 "$hook_pid" 2>/dev/null; then
    printf '  hook still running after arm; watcher beacon: %s\n' \
      "$([ -e "$h/state/.last-watcher-beat" ] && echo fresh || echo none)"
    sleep 3
    say "crewmate lab-crew posts: needs-decision: pick schema v1 or v2 for the export"
    printf 'needs-decision: pick schema v1 or v2 for the export\n' >> "$h/state/lab-crew.status"
  else
    printf '  hook already exited before any watcher armed\n'
  fi
  wait "$hook_pid"; rc=$?
  printf '[Stop hook exit %s]  (2 = rewake delivered to Claude as "Stop hook feedback"; 0 = silent, no rewake)\n' "$rc"
  printf -- '--- Stop hook stderr (what Claude would be woken with) ---\n'
  sed 's/^/  | /' "$hook_out"
  printf -- '--- wake queue ---\n'
  sed 's/^/  | /' "$h/state/.wake-queue" 2>/dev/null || echo '  | (empty)'
  printf -- '--- epoch ledger ---\n'
  sed 's/^/  | /' "$h/state/.claude-autoarm-epoch" 2>/dev/null || echo '  | (none)'
  pkill -f "$h/bin/fm-watch.sh" 2>/dev/null || true
}

case "${1:-}" in
  target-entry)
    H="$LABROOT/target-home"; make_home "$TARGET" "$H"
    echo "=== /afk on a Claude Code primary at TARGET $TARGET ==="
    afk_entry "$H"
    echo; echo "=== Stop-hook rewake under the away-posture record (TARGET) ==="
    stop_hook_cycle "$H"
    ;;
  base-entry)
    H="$LABROOT/base-home"; make_home "$BASE" "$H"
    echo "=== /afk on a Claude Code primary at BASE $BASE (before the fix) ==="
    afk_entry "$H"
    echo; echo "=== Stop-hook rewake under the away-posture record (BASE) ==="
    stop_hook_cycle "$H"
    ;;
  leftover-flag)
    H="$LABROOT/leftover-home"; make_home "$TARGET" "$H"
    B="$LABROOT/base-launcher"; make_home "$BASE" "$B"
    export FM_HOME="$H"
    echo "=== A state/.afk left by an older (pre-fix) Claude launch, no daemon running ==="
    run "$H/bin/fm-afk-launch.sh" propose
    run "$H/bin/fm-afk-launch.sh" confirm
    say "(pre-fix launcher) FM_HOME=<home> base/bin/fm-afk-launch.sh start-native"
    "$B/bin/fm-afk-launch.sh" start-native; printf '[exit %s]\n' "$?"
    show_state "$H"
    echo; echo "--- Stop hook with the leftover flag (before release) ---"
    stop_hook_cycle "$H"
    rm -f "$H/state/lab-crew.status" "$H/state/.wake-queue" "$H/state/.claude-autoarm-epoch" "$H"/state/.seen-*
    echo; echo "=== Target launcher, as SKILL.md phase 4 instructs: start-native once ==="
    run "$H/bin/fm-afk-launch.sh" start-native
    show_state "$H"
    echo; echo "--- Stop hook after the release ---"
    stop_hook_cycle "$H"
    ;;
  live-daemon)
    H="$LABROOT/daemon-home"; make_home "${LIVE_REV:-$TARGET}" "$H"
    export FM_HOME="$H"
    tmux new-session -d -s captain -x 200 -y 50
    CAP=$(tmux display-message -p -t captain '#{pane_id}')
    echo "=== Daemon-running harness (grok marker) still launches the real daemon: TARGET ==="
    say "GROK_AGENT=1 bin/fm-harness.sh"; env -u CLAUDECODE GROK_AGENT=1 "$H/bin/fm-harness.sh"
    env -u CLAUDECODE GROK_AGENT=1 "$H/bin/fm-afk-launch.sh" propose >/dev/null 2>&1
    run env -u CLAUDECODE GROK_AGENT=1 "$H/bin/fm-afk-launch.sh" confirm
    run env -u CLAUDECODE GROK_AGENT=1 FM_SUPERVISOR_TARGET="$CAP" FM_SUPERVISOR_BACKEND=tmux "$H/bin/fm-afk-launch.sh" start
    sleep 4
    show_state "$H"
    printf '  daemon terminal record: %s\n' "$(cat "$H/state/.afk-daemon-terminal" 2>/dev/null)"
    printf '  tmux sessions on private server: %s\n' "$(tmux ls -F '#S' | tr '\n' ' ')"
    printf -- '--- daemon log head ---\n'; sed -n '1,6p' "$H/state/.supervise-daemon.log" 2>/dev/null | sed 's/^/  | /'
    echo; echo "=== Adversarial: a Claude refusal while a LIVE daemon owns state/.afk ==="
    run "$H/bin/fm-afk-launch.sh" start-native
    show_state "$H"
    sleep "${STOP_SETTLE:-0}"
    echo; echo "=== Return: stop shuts the daemon down in order (daemon settled ${STOP_SETTLE:-0}s) ==="
    run env -u CLAUDECODE GROK_AGENT=1 FM_SUPERVISOR_TARGET="$CAP" FM_SUPERVISOR_BACKEND=tmux "$H/bin/fm-afk-launch.sh" stop
    show_state "$H"
    printf '  tmux sessions on private server: %s\n' "$(tmux ls -F '#S' 2>/dev/null | tr '\n' ' ')"
    tmux kill-server 2>/dev/null || true
    ;;
  *) echo "usage: $0 target-entry|base-entry|leftover-flag|live-daemon" >&2; exit 2 ;;
esac
