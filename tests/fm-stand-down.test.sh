#!/usr/bin/env bash
# tests/fm-stand-down.test.sh - bin/fm-stand-down.sh and its record contract
# (bin/fm-stand-down-lib.sh).
#
# A stand-down says one thing the fleet previously had no way to say: this task
# is still open, its work is not landed, and its agent is stopped BY INTENT. The
# absence of that state is what made a deliberately stopped crewmate alarm on
# every session start, because a stopped agent on an open task is otherwise
# shaped exactly like a failure - and the only silence available was teardown,
# which records a completion that did not happen.
#
# These cases pin the command surface and, more importantly, the boundaries that
# keep a quietening record from being able to quieten the wrong thing: it refuses
# to be recorded over a live agent, a malformed record is never honored, and
# releasing or relaunching retires it. How each READER gates on proven death is
# pinned where that reader lives (tests/fm-crew-state.test.sh case (m)).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-stand-down-lib.sh"

STAND_DOWN="$ROOT/bin/fm-stand-down.sh"
TMP_ROOT=$(fm_test_tmproot fm-stand-down)

# A case with a task record and a fake tmux whose liveness answer the test drives
# through FM_FAKE_TMUX_ALIVE. The default is a window tmux cannot find, which is
# the shape every recording case needs: an agent that is already stopped.
new_case() {  # <name> -> echoes case dir
  local name=$1 d
  d="$TMP_ROOT/$name"
  mkdir -p "$d/state" "$d/fakebin"
  cat > "$d/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows)
    [ "${FM_FAKE_TMUX_ALIVE:-0}" = 1 ] && printf 'fm-stood\n'
    exit 0 ;;
  list-panes)
    [ "${FM_FAKE_TMUX_ALIVE:-0}" = 1 ] || exit 1
    printf '%s\n' "${FM_FAKE_TMUX_PANE_PID:-4242}"
    exit 0 ;;
  display-message)
    [ "${FM_FAKE_TMUX_ALIVE:-0}" = 1 ] || exit 1
    printf 'claude\n'; exit 0 ;;
  capture-pane)
    [ "${FM_FAKE_TMUX_ALIVE:-0}" = 1 ] || exit 1
    printf 'working\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$d/fakebin/tmux"
  fm_write_meta "$d/state/stood.meta" "window=fm:fm-stood" "kind=ship" "backend=tmux" \
    "worktree=$d/wt"
  printf '%s\n' "$d"
}

run_stand_down() {  # <case-dir> <args...>
  local d=$1; shift
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" "$STAND_DOWN" "$@"
}

# Sorted basenames of everything directly inside <dir>, dotfiles included. A bash
# glob rather than a GNU-only find format, which would fail this suite on macOS,
# and rather than ls, whose output is not safe to parse.
list_dir_entries() {  # <dir>
  local f names=''
  shopt -s nullglob dotglob
  for f in "$1"/*; do names="$names${f##*/}"$'\n'; done
  shopt -u nullglob dotglob
  printf '%s' "$names" | sort
}

# --- the round trip ---------------------------------------------------------

test_record_show_release_round_trip() {
  local d out rc
  d=$(new_case round-trip)

  out=$(run_stand_down "$d" stood --show) && rc=0 || rc=$?
  expect_code 1 "$rc" "--show on a task that is not stood down"
  assert_contains "$out" "not stood down" "--show says so plainly"

  out=$(run_stand_down "$d" stood --reason "captain stopped it; work pushed, not landed") \
    || fail "recording a stand-down over a stopped agent was refused"
  assert_contains "$out" "stood down" "recording reports what it recorded"
  assert_contains "$out" "work pushed, not landed" "recording echoes the reason"

  out=$(run_stand_down "$d" stood --show) || fail "--show failed after recording"
  assert_contains "$out" "work pushed, not landed" "--show reports the recorded reason"

  fm_stand_down_read "$d/state" stood || fail "the recorded file did not read back"
  assert_equals "captain stopped it; work pushed, not landed" "$FM_STAND_DOWN_REASON" \
    "the reason round-trips through the record"

  out=$(run_stand_down "$d" stood --release) || fail "--release failed"
  assert_contains "$out" "no longer stood down" "--release reports the retirement"
  assert_absent "$(fm_stand_down_path "$d/state" stood)" "--release removed the record"

  out=$(run_stand_down "$d" stood --release) || fail "--release on an absent record must be a no-op, not an error"
  assert_contains "$out" "not stood down" "a second --release is a quiet no-op"
  pass "record, show, and release round-trip through the stored record"
}

# Recording changes the ENDPOINT's story and NOTHING else. The work stays open and
# unlanded, which is the whole distinction teardown could not express, so a
# stand-down must never invent a completion, move the work, or speak for the
# worker. This pins that as a whole-directory claim rather than a per-file one:
# the only thing that may appear is the record itself.
test_recording_touches_no_other_record() {
  local d before_meta before_files after_files
  d=$(new_case leaves-records-alone)
  printf 'working: both branches pushed, waiting to land\n' > "$d/state/stood.status"
  before_meta=$(cat "$d/state/stood.meta")
  before_files=$(list_dir_entries "$d/state")
  run_stand_down "$d" stood --reason "stopped on purpose" >/dev/null \
    || fail "recording was refused over a stopped agent"

  assert_equals "$before_meta" "$(cat "$d/state/stood.meta")" \
    "the task record is untouched by a stand-down"
  assert_grep "both branches pushed, waiting to land" "$d/state/stood.status" \
    "the worker's own status log is left exactly as the worker wrote it"
  assert_equals "1" "$(wc -l < "$d/state/stood.status")" \
    "no line is appended to the worker's log on its behalf"
  # Nothing else is created, so no completion, transition, or lifecycle record
  # can be hiding behind the one file this is allowed to write.
  after_files=$(list_dir_entries "$d/state")
  assert_equals "$(printf '%s\nstood.stood-down' "$before_files" | sort)" "$after_files" \
    "recording a stand-down wrote something other than its own record"
  pass "recording a stand-down writes only its own record: no completion, no transition, no word put in the worker's mouth"
}

# --- the boundaries ---------------------------------------------------------

# The one refusal that matters, and the reason it matters: a genuinely STUCK
# crewmate is alive - looping, hung, waiting on nothing - and it is alarming
# because it needs recovery. If a stand-down could be recorded over a running
# agent it would become a way to silence exactly that alarm, which is the
# opposite of what this record is for. A stand-down describes an agent that is
# ALREADY stopped, so the live case is refused and stays alarming.
test_refuses_to_record_over_a_live_agent() {
  local d out rc
  d=$(new_case live-agent)
  out=$(FM_FAKE_TMUX_ALIVE=1 run_stand_down "$d" stood --reason "trying to silence a wedged worker" 2>&1) \
    && rc=0 || rc=$?
  expect_code 1 "$rc" "recording over a live agent"
  assert_contains "$out" "still running" "the refusal names the reason"
  assert_contains "$out" "exit" "the refusal names how to stop the agent first"
  assert_absent "$(fm_stand_down_path "$d/state" stood)" "a refused recording writes nothing"
  pass "a live - and so possibly wedged - worker cannot be quietened with a stand-down"
}

# An unreachable backend is not evidence the agent is alive, so it must not block
# a record; otherwise a stopped agent behind an unanswerable backend could never
# be recorded, which is exactly when the record is most useful.
test_records_when_the_backend_cannot_answer() {
  local d
  d=$(new_case unreachable-backend)
  rm -f "$d/fakebin/tmux"
  cat > "$d/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf 'no current client\n' >&2
exit 1
SH
  chmod +x "$d/fakebin/tmux"
  run_stand_down "$d" stood --reason "stopped on purpose" >/dev/null \
    || fail "an unreachable backend must not block recording an already-stopped agent"
  assert_present "$(fm_stand_down_path "$d/state" stood)" "the record was written"
  pass "an unreachable backend does not block recording a stand-down"
}

test_refuses_an_unknown_task() {
  local d out rc
  d=$(new_case unknown-task)
  out=$(run_stand_down "$d" nosuchtask --reason "stopped on purpose" 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "recording for a task this home does not carry"
  assert_contains "$out" "no task record" "the refusal names the missing record"
  pass "a task with no record in this home cannot be stood down"
}

test_refuses_an_unsafe_reason() {
  local d out rc long
  d=$(new_case unsafe-reason)
  out=$(run_stand_down "$d" stood --reason "$(printf 'first line\nsecond line')" 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "a multi-line reason"
  out=$(run_stand_down "$d" stood --reason "" 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "an empty reason"
  long=$(printf 'x%.0s' $(seq 1 201))
  out=$(run_stand_down "$d" stood --reason "$long" 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "an over-long reason"
  assert_absent "$(fm_stand_down_path "$d/state" stood)" "no refused reason was stored"
  pass "a reason that could not be printed back safely is refused"
}

test_refuses_a_missing_or_conflicting_verb() {
  local d rc
  d=$(new_case bad-verb)
  run_stand_down "$d" stood >/dev/null 2>&1 && rc=0 || rc=$?
  expect_code 2 "$rc" "no verb at all"
  run_stand_down "$d" stood --nonsense >/dev/null 2>&1 && rc=0 || rc=$?
  expect_code 2 "$rc" "an unknown argument"
  run_stand_down "$d" 'bad id/../..' --show >/dev/null 2>&1 && rc=0 || rc=$?
  expect_code 2 "$rc" "an invalid task id"
  pass "a missing verb, an unknown argument, and an invalid id are all refused"
}

# The safe direction for a record whose whole job is to quieten an alarm: if it
# cannot be parsed with confidence it is not honored, so the ordinary alarm
# returns rather than a corrupt file silencing one forever.
test_a_malformed_record_is_never_honored() {
  local d record
  d=$(new_case malformed)
  record=$(fm_stand_down_path "$d/state" stood)

  printf 'reason=no timestamp at all\n' > "$record"
  ! fm_stand_down_read "$d/state" stood || fail "a record with no timestamp was honored"

  printf 'recorded=notanumber\nreason=bad clock\n' > "$record"
  ! fm_stand_down_read "$d/state" stood || fail "a non-numeric timestamp was honored"

  printf 'recorded=%s\n' "$(date +%s)" > "$record"
  ! fm_stand_down_read "$d/state" stood || fail "a record with no reason was honored"

  : > "$record"
  ! fm_stand_down_read "$d/state" stood || fail "an empty record was honored"

  rm -f "$record"
  ln -s /dev/null "$record"
  ! fm_stand_down_read "$d/state" stood || fail "a symlinked record was honored"
  rm -f "$record"

  printf 'recorded=%s\nreason=well formed\n' "$(date +%s)" > "$record"
  fm_stand_down_read "$d/state" stood || fail "a well-formed record was rejected"
  assert_equals "well formed" "$FM_STAND_DOWN_REASON" "the well-formed control case reads back"
  pass "a malformed, empty, or symlinked record is never honored"
}

test_record_show_release_round_trip
test_recording_touches_no_other_record
test_refuses_to_record_over_a_live_agent
test_records_when_the_backend_cannot_answer
test_refuses_an_unknown_task
test_refuses_an_unsafe_reason
test_refuses_a_missing_or_conflicting_verb
test_a_malformed_record_is_never_honored

echo "all fm-stand-down tests passed"
