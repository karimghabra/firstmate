#!/usr/bin/env bash
# fm-stand-down-lib.sh - the single owner of the stand-down record's format and
# read contract. bin/fm-stand-down.sh owns writing and retiring one; this library
# is what every reader uses so the record is parsed in exactly one place.
#
# WHAT THE RECORD MEANS. A task is stood down when it is still open, its work is
# not landed, and its agent is stopped BY INTENT - the captain stopped it, or
# firstmate stopped it on the captain's word. It is the third possibility beside
# "working" and "finished", and before it existed the fleet could not express it:
# a stopped agent on an open task read as a dead endpoint on every session start,
# which is a recovery trigger (AGENTS.md section 5), so the same deliberate stop
# was re-investigated for as long as the task stayed open. The only way to silence
# that was teardown, which records a completion that did not happen. Recording the
# intent is what makes "stopped on purpose, still open" a state a supervisor can
# read instead of a contradiction it has to re-derive every session.
#
# WHAT IT IS NOT. It is not a claim about the worker: the status log stays exactly
# what the worker last wrote, untouched. It is not a backlog transition: the item
# stays in flight, because the work is still open. It is not a pause: a `paused:`
# wait clears on its own, and a stand-down clears only when someone resumes or
# lands the work. And it is not authority to skip anything - unlanded work is
# still unlanded, and teardown's landed-work test is untouched.
#
# WHY IT CANNOT HIDE A REAL FAILURE. Every reader gates the record on positive
# evidence that the endpoint is not alive. A stand-down record beside a live agent
# is ignored, never honored, so a record left behind by a resumed task cannot
# silence that task's next genuine death; bin/fm-spawn.sh's relaunch path retires
# it outright for the same reason. An unreachable or unreadable endpoint is not
# positive evidence of anything and keeps its existing unknown verdict.
#
# Sourced by bin/fm-stand-down.sh, bin/fm-crew-state.sh, bin/fm-session-start.sh,
# bin/fm-teardown.sh, and bin/fm-spawn.sh.

# The record's path for <state-dir> <task-id>. Callers that already validated the
# task id use this; it performs no validation of its own.
fm_stand_down_path() {  # <state-dir> <task-id>
  printf '%s/%s.stood-down' "$1" "$2"
}

# Read the stand-down record for <state-dir> <task-id>.
# 0 and sets FM_STAND_DOWN_RECORDED (epoch seconds) and FM_STAND_DOWN_REASON when
# a well-formed record exists; 1 and clears both otherwise.
#
# A malformed, unreadable, or symlinked record answers 1, which reads as "not
# stood down" and so restores the ordinary alarm rather than suppressing it. That
# is the safe direction for a record whose whole job is to quieten an alarm: a
# record nobody can parse must never be trusted to silence one. The symlink
# rejection is what keeps the answer bound to this home's own state directory,
# and the field validation below is what keeps a truncated or half-written file
# from reading as a decision somebody made.
fm_stand_down_read() {  # <state-dir> <task-id>
  local path line
  FM_STAND_DOWN_RECORDED=
  FM_STAND_DOWN_REASON=
  path=$(fm_stand_down_path "$1" "$2")
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      recorded=*) FM_STAND_DOWN_RECORDED=${line#recorded=} ;;
      reason=*)   FM_STAND_DOWN_REASON=${line#reason=} ;;
    esac
  done < "$path" 2>/dev/null || true
  case "$FM_STAND_DOWN_RECORDED" in
    ''|*[!0-9]*) FM_STAND_DOWN_RECORDED=; FM_STAND_DOWN_REASON=; return 1 ;;
  esac
  [ -n "$FM_STAND_DOWN_REASON" ] || { FM_STAND_DOWN_RECORDED=; return 1; }
  return 0
}

# 0 when <reason> is safe to store and to print back into a digest: one line, no
# control characters, bounded length. The reason is the only free text in the
# record and it is rendered into the session-start digest, so it is validated
# where it enters rather than where it is read.
fm_stand_down_reason_valid() {  # <reason>
  local reason=$1
  [ -n "$reason" ] || return 1
  [ "${#reason}" -le 200 ] || return 1
  case $reason in
    *[[:cntrl:]]*) return 1 ;;
  esac
  return 0
}

# Render <epoch> the way both the operator command and the session-start digest
# print it, so one record never reads as two different times. Falls back to the
# raw epoch where date(1) cannot format it.
fm_stand_down_format_time() {  # <epoch>
  date -u -d "@$1" '+%Y-%m-%d %H:%MZ' 2>/dev/null \
    || date -u -r "$1" '+%Y-%m-%d %H:%MZ' 2>/dev/null \
    || printf '%s' "$1"
}

# Remove the record for <state-dir> <task-id>. 0 when no record remains
# afterwards, whether or not one was there to begin with.
fm_stand_down_remove() {  # <state-dir> <task-id>
  rm -f -- "$(fm_stand_down_path "$1" "$2")"
}
