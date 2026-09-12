#!/usr/bin/env bash
# fm-stand-down-lib.sh - the single owner of the stand-down record's format and
# read contract. bin/fm-stand-down.sh owns writing and retiring one; this library
# is what every reader uses so the record is parsed in exactly one place.
#
# WHERE THE STATE LIVES, in two halves that answer two different questions:
#
#   - The status LOG declares it. bin/fm-stand-down.sh appends exactly one
#     `stood-down:` line (bin/fm-classify-lib.sh owns the verb), and --release
#     appends the `note:` line that stops declaring it. That is where every
#     supervisor reconciles its pause bookkeeping: the watcher and the away-mode
#     daemon both drop a pane's pause marker on any poll where the log does not
#     declare a wait, so a state that absorbs a pane without declaring itself
#     there loses its marker every poll and re-alarms as a first sighting - which
#     is noisier than the alarm this record exists to retire.
#   - The RECORD carries the decision. The reason in someone's own words, the
#     epoch it was recorded at (which anchors the re-surface cadence and the
#     digest's wording), and the gate every reader applies before honoring any of
#     it: proven death of the agent. The log says a wait is declared; the record
#     says which wait, since when, why, and whether it may be believed.
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
# WHAT IT IS NOT. This is new surface on a safety path, so read this list before
# reaching for it, and do not let its convenience widen past it:
#
#   - It DOES NOT record a completion. It writes no backlog transition at all:
#     the item stays in flight, because the work is still open. Recording a Done
#     the work never reached, to quieten an alarm, is exactly the trade this
#     record exists so that nobody has to make.
#   - It DOES NOT discard, land, or unblock any work. Unlanded work stays
#     unlanded, the branch is untouched, and teardown's landed-work proofs are
#     unchanged - a stood-down task still has to be finished or landed like any
#     other open item.
#   - It DOES NOT speak for the worker about the WORK. Firstmate appends exactly
#     one declaration line, attributed to firstmate, exactly as a verified
#     captain hold does - and on release exactly one line retiring it. Neither
#     claims progress, completion, or any other thing only the worker can say,
#     and everything the worker itself wrote stays untouched beneath them.
#   - It IS NOT a cleanup shortcut, and it is not teardown's little brother. If
#     the work is landed, tear the task down. If it is not, this record changes
#     only how the missing agent is REPORTED.
#   - It IS NOT a declared pause. A `paused:` wait clears on its own; a
#     stand-down clears only when someone resumes or lands the work.
#
# AND IT MUST NOT QUIETEN A TASK THAT IS ACTUALLY STUCK. Two things enforce that,
# and one is on the operator:
#
#   - Enforced where liveness can be PROVEN: a stand-down is refused while the
#     agent reads positively alive, so a wedged-but-running worker cannot be
#     silenced with it - that worker is still alarming and still needs recovery.
#     Only a backend with a recovery-grade agent-state classifier can answer
#     that question (bin/fm-control-lib.sh owns the table; tmux and herdr have
#     one), so on every other backend recording is refused OUTRIGHT rather than
#     written with no check behind it: a record whose guard silently never ran
#     would claim a safety that was never checked. Retiring and reading a record
#     stay available on every backend. Readers additionally gate the record on
#     proven death of the AGENT - fm_backend_agent_state answering `dead` or
#     `missing` - and never on an absent endpoint. That is not a distinction
#     without a difference: a tmux task window is created with no command, so its
#     shell outlives the agent, and the stop the recovery playbook prescribes
#     (bin/fm-control.sh <id> exit) returns on exactly that `dead` verdict. Gated
#     on the endpoint, every reader sailed straight past the record for the one
#     stop we tell operators to make. So a record beside a live agent is ignored
#     rather than honored, a resumed task's leftover record cannot silence its
#     next genuine death, an unreachable or unverifiable answer is not proof of
#     death and keeps its existing verdict, an active run step still outranks it,
#     and bin/fm-spawn.sh's relaunch path retires it outright.
#   - NOT PROTECTED IN AWAY MODE. While state/.afk is active the away-mode
#     daemon (bin/fm-supervise-daemon.sh) owns triage, and its stale classifier
#     is deliberately probe-free: it never asks the backend whether an agent is
#     alive. It therefore trusts a `stood-down:` declaration from the status LOG
#     alone for liveness. A live worker - including a wedged one - under a
#     stand-down record IS NOT ESCALATED there; it takes the four-hour recheck
#     cadence instead of the wedge ladder, for as long as away mode lasts. The
#     RECORD half is gated there (a record that does not parse falls through and
#     keeps alarming, so the paragraph above holds in both supervisors); the
#     LIVENESS half is not. The always-on watcher gates both. This is a known
#     gap, written down rather than closed, because closing it means putting a
#     backend probe inside a classifier whose cost contract forbids one - a
#     design decision filed as separate work.
#   - Not enforceable here: no tool can read INTENT. An agent that crashed and
#     one the captain stopped both leave the same dead agent, so the record asserts
#     something only the person writing it knows. That is why the reason is
#     required and stored: it is the claim, in someone's own words, that this
#     stop was deliberate. Recording one for a worker that actually died is
#     mislabeling a failure, not using this feature.
#
# Sourced by bin/fm-stand-down.sh, bin/fm-crew-state.sh, bin/fm-session-start.sh,
# bin/fm-teardown.sh, bin/fm-spawn.sh, and bin/fm-supervise-daemon.sh.

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
# stood down". That is the safe direction for a record whose whole job is to
# quieten an alarm: a record nobody can parse must never be trusted to silence
# one. The symlink rejection is what keeps the answer bound to this home's own
# state directory, and the field validation below is what keeps a truncated or
# half-written file from reading as a decision somebody made.
#
# This answer restores the ordinary ALARM, not merely the reader's verdict, and
# the difference is load-bearing because the two halves of the state can disagree:
# the log's `stood-down:` declaration would otherwise keep absorbing the pane on
# its own while the record backing it was unreadable. BOTH supervisors close that,
# so the sentence above is true wherever triage happens to be running -
# bin/fm-watch.sh's pause_state_class and bin/fm-supervise-daemon.sh's
# classify_stale each refuse to admit a stood-down declaration whose record does
# not read here, so the pane goes back on the wedge schedule rather than sitting
# absorbed behind a record nobody can parse.
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
# afterwards, whether or not one was there to begin with. The status log's
# declaration is the other half of the state, so callers retiring a stand-down
# use fm_stand_down_release below rather than this directly; this stays the raw
# removal for teardown, whose whole task record is going away anyway.
fm_stand_down_remove() {  # <state-dir> <task-id>
  rm -f -- "$(fm_stand_down_path "$1" "$2")"
}

# The one line that stops a status log declaring a stand-down. It uses the
# informational verb bin/fm-classify-lib.sh owns as FM_CLASSIFY_NOTE_VERB, which
# declares no wait, closes no keyed decision, and claims nothing about the work -
# exactly the whole of what firstmate may say here. No other verb in that
# vocabulary fits: `working:` would claim progress on the worker's behalf, a
# terminal verb would be the false completion this record exists so that nobody
# has to write, `resolved:` would close a keyed decision that was never opened,
# and the remaining verbs each declare a wait, which is the one thing this line
# must undo.
FM_STAND_DOWN_RELEASE_LINE="${FM_CLASSIFY_NOTE_VERB:-${FM_CLASSIFY_NOTE_VERB_DEFAULT:-note}}: stand-down released by firstmate; this task declares no wait"

# The declared-wait line firstmate appends when it records a stand-down for
# <reason>. bin/fm-classify-lib.sh owns the verb; the reason is already validated
# as one bounded line of printable text where it entered the record.
fm_stand_down_declaration_line() {  # <reason>
  printf '%s: %s' "${FM_CLASSIFY_STOOD_DOWN_VERB:-$FM_CLASSIFY_STOOD_DOWN_VERB_DEFAULT}" "$1"
}

# Append <line> to <task-id>'s status log as firstmate's own bookkeeping, through
# the provenance-guarded self-announced append (bin/fm-wake-lib.sh) so the turn
# that writes it does not wake itself, exactly as a verified captain hold's
# transfer line is written. 0 when the line is on the log (announced or left for
# the watcher, both fine), 1 when the append itself failed.
# Requires bin/fm-classify-lib.sh and bin/fm-wake-lib.sh in the caller.
fm_stand_down_declare() {  # <state-dir> <task-id> <line>
  local rc=0
  fm_wake_status_append_self_announced "$1" "$1/$2.status" "$3" || rc=$?
  [ "$rc" -ne 2 ]
}

# Retire a stand-down: drop the record AND stop the log declaring the wait.
# Both halves, always, because either one left behind is a state nobody can act
# on - a record with no declaration loses its pane marker every poll, and a
# declaration with no record absorbs the pane forever after the stand-down is
# over. Keyed on the LOG rather than the record so a hand-deleted record still
# gets its declaration retired. 0 when neither half remains.
# Requires bin/fm-classify-lib.sh and bin/fm-wake-lib.sh in the caller.
fm_stand_down_release() {  # <state-dir> <task-id>
  local state=$1 id=$2
  fm_stand_down_remove "$state" "$id" || return 1
  status_is_stood_down "$(last_status_line "$state/$id.status")" || return 0
  fm_stand_down_declare "$state" "$id" "$FM_STAND_DOWN_RELEASE_LINE"
}
