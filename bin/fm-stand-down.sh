#!/usr/bin/env bash
# Record, show, or retire a task's STAND-DOWN: the task is still open and its work
# is not landed, but its agent is stopped by intent rather than by failure.
#
# bin/fm-stand-down-lib.sh owns what the record means, what it deliberately is
# not, and why it cannot hide a real failure. This script owns the commands.
#
# Usage:
#   fm-stand-down.sh <task-id> --reason "<why it was stopped>"
#   fm-stand-down.sh <task-id> --show
#   fm-stand-down.sh <task-id> --release
#
# --reason records the stand-down. It refuses while the task's agent reads
# positively ALIVE: a stand-down describes an agent that is already stopped, and
# recording one over a running agent would be a way to silence a live worker's
# alarm rather than a record of a decision already taken. Stop the agent first
# (bin/fm-control.sh <task-id> exit), then record why. An endpoint that is merely
# unreachable or unreadable is not positive evidence of a live agent and does not
# block the record.
# --show prints the record, or exits 1 when the task is not stood down.
# --release retires it, which is what resuming or landing the work calls for; a
# relaunch (bin/fm-spawn.sh --relaunch) retires it on its own.
#
# Recording a stand-down changes no backlog state and lands, discards, or unblocks
# nothing. The item stays in flight because the work is still open, which is
# exactly the distinction teardown could not express - AGENTS.md section 7 keeps
# teardown for landed work only. This is not a cleanup shortcut and not a way to
# quieten a task that is actually stuck: a wedged-but-running worker is refused
# here and still needs recovery. bin/fm-stand-down-lib.sh's header is the full
# list of what this does not do, and of the one part no tool can enforce.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-stand-down-lib.sh
. "$SCRIPT_DIR/fm-stand-down-lib.sh"

usage() {
  cat <<'EOF'
Record, show, or retire a task's stand-down: still open, work not landed, agent
stopped by intent rather than by failure.

Usage:
  fm-stand-down.sh <task-id> --reason "<why it was stopped>"
  fm-stand-down.sh <task-id> --show
  fm-stand-down.sh <task-id> --release

--reason refuses while the agent reads positively alive; stop it first with
bin/fm-control.sh <task-id> exit, then record why. --release retires the record,
and bin/fm-spawn.sh --relaunch retires it on its own.

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
while [ "$#" -gt 0 ]; do
  case "$1" in
    --reason)
      [ "$#" -ge 2 ] || { echo "error: --reason needs a value" >&2; exit 2; }
      VERB=record; REASON=$2; shift 2 ;;
    --show)    VERB=show; shift ;;
    --release) VERB=release; shift ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$VERB" ] || { echo "error: one of --reason, --show, or --release is required" >&2; exit 2; }

if [ -z "${STATE-}" ] || [ ! -d "${STATE-}" ] || [ -L "${STATE-}" ]; then
  echo "error: state directory is unavailable" >&2
  exit 1
fi

META="$STATE/$ID.meta"
RECORD=$(fm_stand_down_path "$STATE" "$ID")

case "$VERB" in
  show)
    if fm_stand_down_read "$STATE" "$ID"; then
      printf 'stood down since %s: %s\n' \
        "$(fm_stand_down_format_time "$FM_STAND_DOWN_RECORDED")" "$FM_STAND_DOWN_REASON"
      exit 0
    fi
    printf '%s is not stood down\n' "$ID"
    exit 1
    ;;
  release)
    if ! fm_stand_down_read "$STATE" "$ID"; then
      printf '%s is not stood down\n' "$ID"
      exit 0
    fi
    fm_stand_down_remove "$STATE" "$ID" || {
      echo "error: the stand-down record could not be retired" >&2
      exit 1
    }
    printf 'released: %s is no longer stood down\n' "$ID"
    exit 0
    ;;
esac

# --- record ----------------------------------------------------------------
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: $ID has no task record in this home" >&2
  exit 1
fi
if ! fm_stand_down_reason_valid "$REASON"; then
  echo "error: --reason must be one line of at most 200 printable characters" >&2
  exit 2
fi

# Only a POSITIVE alive verdict blocks the record. fm_backend_agent_state answers
# `alive` solely when the endpoint and its agent both responded, so an absent,
# dead, unreachable, or unreadable endpoint - every shape of "the agent is not
# demonstrably running" - records normally instead of demanding the operator
# argue with an unreachable backend.
BACKEND=$(fm_backend_of_meta "$META")
TARGET=$(fm_backend_target_of_meta "$META")
if [ -n "$TARGET" ]; then
  AGENT_STATE=$(fm_backend_agent_state "$BACKEND" "$TARGET" 2>/dev/null) || AGENT_STATE=unreadable
  if [ "$AGENT_STATE" = alive ]; then
    echo "error: $ID's agent is still running; stop it first (bin/fm-control.sh $ID exit), then record why" >&2
    exit 1
  fi
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
printf 'recorded: %s is stood down (open, no agent by intent): %s\n' "$ID" "$REASON"
