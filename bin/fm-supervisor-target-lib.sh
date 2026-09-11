#!/usr/bin/env bash
# fm-supervisor-target-lib.sh - the single owner of supervisor-pane discovery
# and of the delivery proof the away daemon must pass before it may own
# supervision.
#
# The away-mode daemon (bin/fm-supervise-daemon.sh) must know which pane runs
# firstmate itself, both to inject escalations into it and, for the daemon, to
# validate that target at startup. The script-owned away launcher
# (bin/fm-afk-launch.sh) must resolve the SAME captain pane BEFORE it creates a
# separate, non-visible terminal for the daemon, so it can pass that pane in as
# FM_SUPERVISOR_TARGET (otherwise the daemon, running in its own terminal, would
# auto-discover its OWN pane and inject there instead of into the captain's).
#
# Because both callers need the identical resolution, it lives here once. The
# function names and precedence are unchanged from when this logic lived inline
# in bin/fm-supervise-daemon.sh, so its unit tests (tests/fm-daemon.test.sh)
# keep exercising the same names after the daemon sources this file.
#
# fm_supervisor_delivery_proof below calls the backend dispatcher
# (bin/fm-backend.sh), which both callers source before using it.

# Default supervisor pane target/backend when nothing is configured or detected.
# "firstmate:0" is a tmux session:window name, so the bare fallback (nothing
# configured, nothing detected) assumes tmux - matching the daemon's pre-herdr
# behavior byte-for-byte when run outside both tmux and herdr.
FM_SUPERVISOR_TARGET_DEFAULT="firstmate:0"
FM_SUPERVISOR_BACKEND_DEFAULT="tmux"

# Supervisor backends the daemon can inject into. Zellij, Orca, and cmux have no
# verified busy, composer, and submit wiring for the daemon yet, so the launcher
# and the daemon both refuse them rather than misapplying another transport.
FM_SUPERVISOR_SUPPORTED_BACKENDS="tmux herdr"

# discover_supervisor_target: resolve the pane running firstmate. Priority:
#   1. FM_SUPERVISOR_TARGET env (explicit override) - may be a tmux target or a
#      herdr "<session>:<pane-id>" target (paired with discover_supervisor_backend
#      to know which).
#   2. $TMUX_PANE - tmux sets this in every pane's environment; inherited by a
#      process launched from firstmate's own pane.
#   3. $HERDR_ENV=1 + $HERDR_PANE_ID - herdr injects both into every process it
#      manages a pane for; compose the "<session>:<pane-id>" target from
#      $HERDR_SESSION (defaulting to "default", mirroring bin/backends/herdr.sh's
#      fm_backend_herdr_session) and $HERDR_PANE_ID. Checked after $TMUX_PANE so a
#      tmux pane nested inside herdr still resolves to tmux, matching
#      fm_backend_detect's innermost-first rule.
#   4. FM_SUPERVISOR_TARGET_DEFAULT - legacy tmux fallback (may not resolve if the
#      session is named differently). Returns 1 so the caller can warn.
discover_supervisor_target() {
  if [ -n "${FM_SUPERVISOR_TARGET:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_TARGET"
    return 0
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    printf '%s' "$TMUX_PANE"
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf '%s:%s' "${HERDR_SESSION:-default}" "$HERDR_PANE_ID"
    return 0
  fi
  printf '%s' "$FM_SUPERVISOR_TARGET_DEFAULT"
  return 1
}

# discover_supervisor_backend: resolve the supervisor pane's BACKEND, independent
# of the target string so an explicit FM_SUPERVISOR_TARGET override still knows
# which primitives (tmux vs herdr) to dispatch through. Priority mirrors
# discover_supervisor_target and bin/fm-backend.sh's fm_backend_detect:
#   1. FM_SUPERVISOR_BACKEND env (explicit override).
#   2. $TMUX_PANE set - tmux.
#   3. $HERDR_ENV=1 (with $HERDR_PANE_ID present) - herdr.
#   4. FM_SUPERVISOR_BACKEND_DEFAULT (tmux) - matches the target fallback. Returns 1.
discover_supervisor_backend() {
  if [ -n "${FM_SUPERVISOR_BACKEND:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_BACKEND"
    return 0
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    printf 'tmux'
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf 'herdr'
    return 0
  fi
  printf '%s' "$FM_SUPERVISOR_BACKEND_DEFAULT"
  return 1
}

# fm_supervisor_delivery_proof: prove that the away daemon could ever deliver an
# escalation to the supervisor pane, BEFORE it takes over supervision.
#
# The daemon's only transport is typing into that pane, and inject_msg types
# only into a composer the shared classifier (fm_backend_composer_state ->
# bin/fm-composer-lib.sh) reads as exactly `empty`. Meanwhile the daemon's
# state/.afk flag switches off the ordinary supervision cycle that would
# otherwise wake this session (the watcher goes one-shot and every harness
# turn-end rewake stands down). A pane whose composer the classifier cannot
# confirm - a rendering the classifier does not know, such as a Claude session
# name drawn into the composer's top rule under a cursorless capture, or a
# harness release whose idle composer never reads empty - therefore receives no
# escalation at all while supervision has silently stopped. The daemon's
# max-defer wedge alarm can only report that after the fact, from a process no
# one is watching; this proof refuses it up front, while someone is.
#
# It never loosens the injection guard: it requires the same exact `empty`
# verdict inject_msg requires, and decides only whether the daemon may own
# supervision at all. Pending text is not proof, because a composer whose idle
# placeholder the classifier misreads as typed text reads pending forever.
#
# Prints one verdict word and returns 0 only on `empty`. Returns 1 with:
#   unsupported   the daemon has no transport for <backend>
#   missing       <target> is not a live pane on <backend>
#   <verdict>     the last composer verdict (unknown, pending, pending-unproven,
#                 or any future verdict) after five composer reads one second
#                 apart, so a capture taken mid-redraw does not refuse on its own
fm_supervisor_delivery_proof() {  # <backend> <target>
  local backend=$1 target=$2 attempts=5 attempt=0 verdict=''
  if ! fm_backend_list_contains "$FM_SUPERVISOR_SUPPORTED_BACKENDS" "$backend"; then
    printf 'unsupported'
    return 1
  fi
  if ! fm_backend_target_exists "$backend" "$target"; then
    printf 'missing'
    return 1
  fi
  while :; do
    attempt=$((attempt + 1))
    verdict=$(fm_backend_composer_state "$backend" "$target" 2>/dev/null)
    if [ "$verdict" = empty ]; then
      printf 'empty'
      return 0
    fi
    [ "$attempt" -lt "$attempts" ] || break
    sleep 1
  done
  printf '%s' "${verdict:-unknown}"
  return 1
}
