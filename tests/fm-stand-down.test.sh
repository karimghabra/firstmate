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
# to be recorded over a live agent, it refuses outright where the backend cannot
# prove whether an agent is alive, a malformed record is never honored, and
# releasing or relaunching retires it. How each READER gates on proven death is
# pinned where that reader lives (tests/fm-crew-state.test.sh case (m)).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"
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

test_record_release_round_trip() {
  local d out
  d=$(new_case round-trip)

  fm_stand_down_read "$d/state" stood && fail "a task with no record read as stood down"

  out=$(run_stand_down "$d" stood --reason "captain stopped it; work pushed, not landed") \
    || fail "recording a stand-down over a stopped agent was refused"
  assert_contains "$out" "stood down" "recording reports what it recorded"
  assert_contains "$out" "work pushed, not landed" "recording echoes the reason"

  fm_stand_down_read "$d/state" stood || fail "the recorded file did not read back"
  assert_equals "captain stopped it; work pushed, not landed" "$FM_STAND_DOWN_REASON" \
    "the reason round-trips through the record"

  out=$(run_stand_down "$d" stood --release) || fail "--release failed"
  assert_contains "$out" "no longer stood down" "--release reports the retirement"
  assert_absent "$(fm_stand_down_path "$d/state" stood)" "--release removed the record"

  out=$(run_stand_down "$d" stood --release) || fail "--release on an absent record must be a no-op, not an error"
  assert_contains "$out" "not stood down" "a second --release is a quiet no-op"
  pass "record and release round-trip through the stored record"
}

# Recording changes the ENDPOINT's story and NOTHING else. The work stays open and
# unlanded, which is the whole distinction teardown could not express, so a
# stand-down must never invent a completion or move the work. It DOES append one
# line to the status log - the declaration every supervisor reconciles its pause
# bookkeeping against - and this pins the bound on that: exactly one line, the
# declaration and nothing else, with everything the worker wrote left beneath it.
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
    "the worker's own status log keeps exactly what the worker wrote"
  assert_equals "2" "$(wc -l < "$d/state/stood.status")" \
    "recording appended more than its single declaration line"
  assert_equals "stood-down: stopped on purpose" "$(tail -1 "$d/state/stood.status")" \
    "the appended line is the declaration, attributed to nobody's progress but the stop itself"
  status_is_stood_down "$(tail -1 "$d/state/stood.status")" \
    || fail "the appended line does not read as a declared stand-down"
  status_is_captain_relevant "$(tail -1 "$d/state/stood.status")" \
    && fail "the declaration reads as a captain-relevant event and would re-alarm"
  # Nothing else is created, so no completion, transition, or lifecycle record
  # can be hiding behind the one file this is allowed to write.
  after_files=$(list_dir_entries "$d/state")
  assert_equals "$(printf '%s\nstood.stood-down' "$before_files" | sort)" "$after_files" \
    "recording a stand-down wrote something other than its own record"
  pass "recording a stand-down writes its own record and exactly one declaration line: no completion, no transition, no claim about the work"
}

# The half of the state the watcher's reconciliation reads. A stand-down whose log
# does not declare the wait loses its pause marker on the very next poll and
# re-alarms as a first sighting, so --release must stop declaring it or the task
# stays absorbed forever after the stand-down is over.
test_release_stops_the_log_declaring_the_wait() {
  local d last
  d=$(new_case release-undeclares)
  printf 'done: PR 42 pushed, awaiting the captain\n' > "$d/state/stood.status"
  run_stand_down "$d" stood --reason "captain stopped it" >/dev/null || fail "recording was refused"
  status_is_paused_or_captain_held "$(tail -1 "$d/state/stood.status")" \
    || fail "a recorded stand-down left the log declaring no wait"

  run_stand_down "$d" stood --release >/dev/null || fail "--release failed"
  last=$(tail -1 "$d/state/stood.status")
  status_is_paused_or_captain_held "$last" \
    && fail "the log still declares a wait after --release, so the task stays absorbed forever"
  status_is_captain_relevant "$last" \
    && fail "--release appended a captain-relevant line, re-alarming the task it just released"
  assert_grep "PR 42 pushed" "$d/state/stood.status" "the worker's own lines survive a release"
  pass "--release leaves the log declaring no wait, so an ordinary supervision schedule resumes"
}

# A stand-down recorded for a task with no endpoint in its metadata would skip the
# live-agent refusal entirely - nothing to ask - and no reader could honor the
# result anyway, since each resolves the endpoint before it reaches the stand-down
# gate. So it is refused, and the refusal names where a windowless open task is
# actually reconciled.
test_refuses_to_record_without_a_recorded_endpoint() {
  local d out rc before_files
  d=$(new_case no-endpoint)
  fm_write_meta "$d/state/stood.meta" "kind=ship" "backend=tmux" "worktree=$d/wt"
  before_files=$(list_dir_entries "$d/state")

  out=$(run_stand_down "$d" stood --reason "stopped on purpose" 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "recording for a task whose metadata records no endpoint"
  assert_contains "$out" "records no endpoint" "the refusal names what is missing"
  assert_contains "$out" "stuck-crewmate-recovery" "the refusal names the remedy, not just the refusal"
  assert_absent "$(fm_stand_down_path "$d/state" stood)" "a refused recording writes no record"
  assert_equals "$before_files" "$(list_dir_entries "$d/state")" \
    "a refused recording wrote something into the state directory"
  pass "a task with no recorded endpoint is refused, and told where a missing window is reconciled"
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

# The live-agent refusal above is only a guarantee where the backend can actually
# answer "is an agent running here". zellij, orca, and cmux have no recovery-grade
# classifier, so that guard would pass silently on a genuinely wedged worker and
# report a check that never ran. Recording is refused outright there instead -
# while retiring an existing record, which quietens nothing new, stays available
# on every backend.
test_refuses_to_record_where_liveness_cannot_be_proven() {
  local d out rc record
  d=$(new_case unverified-backend)
  fm_write_meta "$d/state/stood.meta" "window=fm:fm-stood" "kind=ship" "backend=cmux" \
    "worktree=$d/wt"

  out=$(run_stand_down "$d" stood --reason "stopped on purpose" 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "recording on a backend with no recovery-grade classifier"
  assert_contains "$out" "cmux" "the refusal names the backend that cannot answer"
  assert_contains "$out" "still alive" "the refusal says what cannot be proven"
  assert_contains "$out" "tmux and herdr" "the refusal names the backends that can"
  assert_absent "$(fm_stand_down_path "$d/state" stood)" "a refused recording writes nothing"

  # Retiring is not gated: a record made before a backend switch, or by any other
  # route, must still be removable wherever it exists.
  record=$(fm_stand_down_path "$d/state" stood)
  printf 'recorded=%s\nreason=recorded earlier\n' "$(date +%s)" > "$record"
  run_stand_down "$d" stood --release >/dev/null \
    || fail "--release must not need a backend that can prove liveness"
  assert_absent "$record" "--release retired the record on an unverifiable backend"
  pass "a backend that cannot prove an agent stopped cannot carry a new stand-down, but can still shed one"
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
  local d rc out record
  d=$(new_case bad-verb)
  run_stand_down "$d" stood >/dev/null 2>&1 && rc=0 || rc=$?
  expect_code 2 "$rc" "no verb at all"
  run_stand_down "$d" stood --nonsense >/dev/null 2>&1 && rc=0 || rc=$?
  expect_code 2 "$rc" "an unknown argument"
  run_stand_down "$d" 'bad id/../..' --release >/dev/null 2>&1 && rc=0 || rc=$?
  expect_code 2 "$rc" "an invalid task id"

  # Record and release are opposite requests, so naming both states no intent this
  # command can carry out. Last-wins silently performed the inverse of half the
  # request and reported success for it - in either order.
  out=$(run_stand_down "$d" stood --reason "captain stopped it" --release 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "--reason followed by --release"
  assert_contains "$out" "opposite requests" "the refusal says why both cannot be honored"
  out=$(run_stand_down "$d" stood --release --reason "captain stopped it" 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "--release followed by --reason"
  assert_absent "$(fm_stand_down_path "$d/state" stood)" "a refused conflicting request recorded nothing"

  # And the inverse harm: with a record present, a conflicting request must not
  # take the release path either.
  record=$(fm_stand_down_path "$d/state" stood)
  printf 'recorded=%s\nreason=recorded earlier\n' "$(date +%s)" > "$record"
  run_stand_down "$d" stood --reason "captain stopped it" --release >/dev/null 2>&1 && rc=0 || rc=$?
  expect_code 2 "$rc" "a conflicting request over an existing record"
  assert_present "$record" "a refused conflicting request retired an existing record"
  pass "a missing verb, an unknown argument, an invalid id, and two conflicting verbs in either order are all refused"
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

test_record_release_round_trip
test_recording_touches_no_other_record
test_release_stops_the_log_declaring_the_wait
test_refuses_to_record_without_a_recorded_endpoint
test_refuses_to_record_over_a_live_agent
test_refuses_to_record_where_liveness_cannot_be_proven
test_records_when_the_backend_cannot_answer
test_refuses_an_unknown_task
test_refuses_an_unsafe_reason
test_refuses_a_missing_or_conflicting_verb
test_a_malformed_record_is_never_honored

echo "all fm-stand-down tests passed"
