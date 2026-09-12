#!/usr/bin/env bash
# Record or retire a task's STAND-DOWN: the task is still open and its work is
# not landed, but its agent is stopped by intent rather than by failure.
#
# bin/fm-stand-down-lib.sh owns what the record means, what it deliberately is
# not, and why it cannot hide a real failure. This script owns the commands.
#
# Usage:
#   fm-stand-down.sh <task-id> --reason "<why it was stopped>"
#   fm-stand-down.sh <task-id> --release
#
# --reason records the stand-down, and records one only where the backend can
# PROVE whether an agent is still alive. On a backend with no recovery-grade
# agent-state classifier (bin/fm-control-lib.sh owns that table; only tmux and
# herdr have one), and on a task whose metadata records no endpoint to ask at all,
# recording is refused outright rather than written with no check behind it. Where
# the check can run it refuses while the task's agent reads positively ALIVE: a
# stand-down describes an agent that is already stopped, and recording one over a
# running agent would be a way to silence a live worker's alarm rather than a
# record of a decision already taken. Stop the agent first (bin/fm-control.sh
# <task-id> exit), then record why. An endpoint that is merely unreachable or
# unreadable is not positive evidence of a live agent and does not block the
# record.
# Recording writes BOTH halves of the state: the durable record, and the one
# `stood-down:` line this appends to the task's status log so every supervisor's
# pause bookkeeping reconciles against a declared wait rather than stripping its
# own marker every poll. --release retires both, which is what resuming or landing
# the work calls for; a relaunch (bin/fm-spawn.sh --relaunch) retires them on its
# own. Retiring works on every backend: only recording a new one needs the proof.
#
# Recording a stand-down changes no backlog state and lands, discards, or unblocks
# nothing. The item stays in flight because the work is still open, which is
# exactly the distinction teardown could not express - AGENTS.md section 7 keeps
# teardown for landed work only. This is not a cleanup shortcut and not a way to
# quieten a task that is actually stuck: a wedged-but-running worker is refused
# here, and so is any task whose backend cannot prove whether a worker is still
# running at all. bin/fm-stand-down-lib.sh's header is the full list of what this
# does not do, and of the one part no tool can enforce.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-stand-down-lib.sh
. "$SCRIPT_DIR/fm-stand-down-lib.sh"

usage() {
  cat <<'EOF'
Record or retire a task's stand-down: still open, work not landed, agent
stopped by intent rather than by failure.

Usage:
  fm-stand-down.sh <task-id> --reason "<why it was stopped>"
  fm-stand-down.sh <task-id> --release

Exactly one of --reason or --release; they are opposite requests.

--reason records only on a backend that can prove whether an agent is alive -
tmux and herdr - and only on a task with a recorded endpoint to ask; it is
refused outright otherwise rather than recorded with no check behind it. Where
the check runs it refuses while the agent reads positively alive; stop it first
with bin/fm-control.sh <task-id> exit, then record why. Recording also appends
one stood-down: line to the task's status log, so supervisors read a declared
wait rather than an undeclared silence. --release retires both halves on any
backend, and bin/fm-spawn.sh --relaunch retires them on its own.

It records no completion, discards no work, and is not a cleanup shortcut: the
item stays in flight because the work is still open, and unlanded work stays
unlanded. A wedged-but-running worker cannot be quietened with it - recording is
refused while the agent reads alive, and that worker still needs recovery.
EOF
}

if [ "$#" -lt 1 ] || [ "$1" = --help ] || [ "$1" = -h ]; then
  usage
  [ "$#" -lt 1 ] && exit 2
  exit 0
fi

ID=$1
shift
if ! fm_pr_task_id_valid "$ID"; then
  echo "error: invalid task id" >&2
  exit 2
fi

VERB=
REASON=
# Recording and releasing are opposite operations, so a request naming both
# states no intent this command can carry out. Last-wins would silently perform
# the inverse of half the request and report success for it.
set_verb() {  # <record|release>
  [ -z "$VERB" ] || [ "$VERB" = "$1" ] || {
    echo "error: --reason and --release are opposite requests; pass exactly one" >&2
    exit 2
  }
  VERB=$1
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --reason)
      [ "$#" -ge 2 ] || { echo "error: --reason needs a value" >&2; exit 2; }
      set_verb record; REASON=$2; shift 2 ;;
    --release) set_verb release; shift ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$VERB" ] || { echo "error: one of --reason or --release is required" >&2; exit 2; }

if [ -z "${STATE-}" ] || [ ! -d "${STATE-}" ] || [ -L "${STATE-}" ]; then
  echo "error: state directory is unavailable" >&2
  exit 1
fi

META="$STATE/$ID.meta"
RECORD=$(fm_stand_down_path "$STATE" "$ID")

if [ "$VERB" = release ]; then
  if ! fm_stand_down_read "$STATE" "$ID" \
    && ! status_is_stood_down "$(last_status_line "$STATE/$ID.status")"; then
    printf '%s is not stood down\n' "$ID"
    exit 0
  fi
  fm_stand_down_release "$STATE" "$ID" || {
    echo "error: the stand-down could not be retired" >&2
    exit 1
  }
  printf 'released: %s is no longer stood down\n' "$ID"
  exit 0
fi

# --- record ----------------------------------------------------------------
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: $ID has no task record in this home" >&2
  exit 1
fi
if ! fm_stand_down_reason_valid "$REASON"; then
  echo "error: --reason must be one line of at most 200 printable characters" >&2
  exit 2
fi

# A record is only as good as the check behind it, so a backend that cannot answer
# "is an agent still running here" cannot carry one: without that proof the
# live-agent refusal below would pass silently on a genuinely wedged worker and
# report a check that never ran. bin/fm-control-lib.sh owns which backends have a
# recovery-grade classifier, and bin/fm-spawn.sh's relaunch refuses on the same
# predicate for the same reason. Retiring and reading a record stay available
# everywhere; only recording a new one needs the proof.
BACKEND=$(fm_backend_of_meta "$META")
fm_control_backend_state_verified "$BACKEND" || {
  echo "error: task $ID runs on the $BACKEND backend, which has no recovery-grade agent-state classifier, so it cannot prove whether an agent is still alive; refusing rather than recording a stand-down that could be quietening a live wedge (only tmux and herdr can prove it)" >&2
  exit 1
}

# A meta with no recorded endpoint has nothing for the check above to ask, and a
# record written past it would be doubly useless: the live-agent refusal would be
# skipped on a task that might still be running, and no reader could honor the
# result anyway, since each one resolves the task's endpoint before it reaches the
# stand-down gate. So the same fail-closed posture applies - refuse, and say what
# the operator should do instead, because a windowless open task is exactly what
# somebody is looking at when they reach for this command.
TARGET=$(fm_backend_target_of_meta "$META")
[ -n "$TARGET" ] || {
  echo "error: task $ID's metadata records no endpoint, so nothing here can prove whether an agent is still running and no reader could honor the record; reconcile the task's ownership first with the stuck-crewmate-recovery playbook (AGENTS.md section 5), which owns a missing window" >&2
  exit 1
}

# Only a POSITIVE alive verdict blocks the record. fm_backend_agent_state answers
# `alive` solely when the endpoint and its agent both responded, so a dead,
# unreachable, or unreadable endpoint - every shape of "the agent is not
# demonstrably running" - records normally instead of demanding the operator
# argue with an unreachable backend.
AGENT_STATE=$(fm_backend_agent_state "$BACKEND" "$TARGET" 2>/dev/null) || AGENT_STATE=unreadable
if [ "$AGENT_STATE" = alive ]; then
  echo "error: $ID's agent is still running; stop it first (bin/fm-control.sh $ID exit), then record why" >&2
  exit 1
fi

TMP=$(umask 077; mktemp "$STATE/.fm-stand-down.XXXXXX") || {
  echo "error: the stand-down record could not be written" >&2
  exit 1
}
trap 'rm -f -- "$TMP"' EXIT
{
  printf 'recorded=%s\n' "$(date +%s)"
  printf 'reason=%s\n' "$REASON"
} > "$TMP" || {
  echo "error: the stand-down record could not be written" >&2
  exit 1
}
mv -f -- "$TMP" "$RECORD" || {
  echo "error: the stand-down record could not be written" >&2
  exit 1
}
trap - EXIT

# The record is half the state; the status log's declaration is the other half,
# and it is written only after the record has been read back, exactly as
# fm-captain-hold.sh appends its transfer line only after verifying the backlog
# item. Without the declaration the absorbed pane loses its pause marker on the
# next poll and re-alarms as a first sighting, so a half-recorded stand-down is
# noisier than no stand-down at all - hence the record comes back off if the
# declaration cannot be appended, rather than being left to quietly misbehave.
fm_stand_down_read "$STATE" "$ID" || {
  fm_stand_down_remove "$STATE" "$ID"
  echo "error: the stand-down record could not be read back after writing" >&2
  exit 1
}
fm_stand_down_declare "$STATE" "$ID" "$(fm_stand_down_declaration_line "$REASON")" || {
  fm_stand_down_remove "$STATE" "$ID"
  echo "error: $ID's status log could not be made to declare the stand-down; nothing was recorded" >&2
  exit 1
}
printf 'recorded: %s is stood down (open, no agent by intent): %s\n' "$ID" "$REASON"
