#!/usr/bin/env bash
# Behavior tests for bin/fm-sitrep.sh, the colour-coded situation report.
# Every case drives the public command against a synthetic home with a fake
# tmux endpoint inventory and a fake process table.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SITREP="$ROOT/bin/fm-sitrep.sh"
TMP_ROOT=$(fm_test_tmproot fm-sitrep)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# 2026-07-25T00:00:00Z, the fixture's "now".
NOW_EPOCH=1784937600
NOW_ISO=2026-07-25T00:00:00Z

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  : > "$home/live-windows"
  printf '%s\n' "$home"
}

# A fake tmux whose live inventory is the home's live-windows file
# ("<window-name> <pane-pid>" per line). Absent windows fail like real tmux.
make_fakebin() {  # <home>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
live="${FM_HOME:?}/live-windows"
target=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-t" ]; then target=$arg; fi
  prev=$arg
done
window=${target#*:}
pid=$(awk -v w="$window" '$1 == w { print $2; exit }' "$live")
case "${1:-}" in
  list-windows)
    awk '{ print $1 }' "$live"
    ;;
  list-panes)
    [ -n "$pid" ] || { echo "can't find window: $window" >&2; exit 1; }
    printf '%s\n' "$pid"
    ;;
  display-message)
    [ -n "$pid" ] || { echo "can't find window: $window" >&2; exit 1; }
    case "$*" in
      *pane_current_command*) printf 'claude\n' ;;
      *pane_tty*) printf '/dev/fm-sitrep-none\n' ;;
      *) printf '%%1\n' ;;
    esac
    ;;
  capture-pane)
    [ -n "$pid" ] || exit 1
    printf 'all quiet\n> \n'
    ;;
esac
exit 0
SH
  # A fake Herdr that knows one pane, w1:p5, whose shell is pid 400.
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "status --json")
    echo '{"server":{"running":true}}'
    ;;
  "agent get")
    echo '{"result":{"agent":{"agent_status":"working"}}}'
    ;;
  "pane get")
    [ "${3:-}" = "w1:p5" ] || { echo '{"error":{"code":"pane_not_found"}}'; exit 1; }
    echo '{"result":{"type":"pane","pane":{"pane_id":"w1:p5"}}}'
    ;;
  "pane process-info")
    [ "${4:-}" = "w1:p5" ] || exit 1
    echo '{"id":"cli:pane:process_info","result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p5","shell_pid":400,"foreground_process_group_id":401,"foreground_processes":[]}}}'
    ;;
  *) echo '{"error":{"code":"unsupported"}}'; exit 1 ;;
esac
SH
  # Fake process table: the running worker's tree is 100 -> 101 -> 102 with an
  # unrelated heavy process 200 that must not be counted.
  cat > "$fb/fake-ps" <<'SH'
#!/usr/bin/env bash
cat <<'EOF'
    1     0   900  0.0
  100     1  1000  1.0
  101   100  2000  2.5
  102   101  3000  0.5
  200     1 50000  9.0
  400     1   500  0.0
  401   400  7500 12.0
EOF
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux" "$fb/herdr" "$fb/fake-ps"
  printf '%s\n' "$fb"
}

machine_files() {  # <home> <mem-total-kb> <mem-avail-kb> <load1>
  printf 'MemTotal:       %s kB\nMemFree:          1000 kB\nMemAvailable:   %s kB\n' "$2" "$3" > "$1/meminfo"
  printf '%s 0.50 0.40 1/100 4242\n' "$4" > "$1/loadavg"
}

record_busy() {  # <state-dir> <id>
  local gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$1" "$2")
  "$ROOT/bin/fm-busy-event.sh" apply "$1" "$2" busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
}

record_idle() {  # <state-dir> <id>
  local gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$1" "$2")
  "$ROOT/bin/fm-busy-event.sh" apply "$1" "$2" idle --gen "$gen" \
    --source claude-hook --event stop
}

write_fixture() {  # <home>
  local home=$1
  mkdir -p "$home/projects/run-wt" "$home/projects/stuck-wt" "$home/projects/parked-wt" "$home/projects/gone-wt"
  cat > "$home/data/projects.md" <<'EOF'
# Projects

- alpha [no-mistakes] - the first sample project (added 2026-07-01)
- beta [local-only] - a registered project with nothing open (added 2026-07-01)
- gamma [direct-PR] - a project with a stuck worker (added 2026-07-01)
EOF
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] run-task - alpha: build the widget (repo: alpha) (kind: ship) (since 2026-07-20)
- [ ] stuck-task - fix the flaky parser (repo: gamma) (kind: ship) (since 2026-07-20)
- [ ] gone-task - tidy the gamma docs (repo: gamma) (kind: ship) (since 2026-07-20)
- [ ] parked-task - alpha: tune the cache (repo: alpha) (kind: ship) (since 2026-07-19)
- [ ] herdr-task - render the epsilon charts (repo: epsilon) (kind: ship) (since 2026-07-24)

## Queued
- [ ] old-call - pick the delta storage format (repo: delta) (kind: captain) (since 2026-07-19) (hold: Choose JSON or SQLite for delta storage. PR https://github.com/example/delta/pull/4 compares both formats.) (hold-kind: captain)
  Captain hold set: 2026-07-19T00:00:00Z
- [ ] new-call - name the alpha release (repo: alpha) (kind: captain) (since 2026-07-24) (hold: Pick a release name for alpha.) (hold-kind: captain)
  Captain hold set: 2026-07-24T12:00:00Z
- [ ] later-call - revisit alpha pricing (repo: alpha) (kind: captain) (since 2026-07-01) (hold: Revisit pricing after launch.) (hold-kind: captain) (hold-until: 2026-12-01)
  Captain hold set: 2026-07-01T00:00:00Z

## Done
- [x] shipped-task - alpha: first release https://github.com/example/alpha/pull/7 (repo: alpha) (kind: ship) (merged 2026-07-22)
EOF
  # Running worker on a live endpoint whose process tree is 100 -> 101 -> 102.
  fm_write_meta "$home/state/run-task.meta" \
    "window=firstmate:fm-run-task" \
    "worktree=$home/projects/run-wt" \
    "project=$home/projects/alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "model=sample-model-1" \
    "effort=high" \
    "spawn_gen=s$((NOW_EPOCH - 5400)).1.1"
  record_busy "$home/state" run-task
  printf 'fm-run-task 100\n' >> "$home/live-windows"
  # Live endpoint, idle, last status says it is stuck.
  fm_write_meta "$home/state/stuck-task.meta" \
    "window=firstmate:fm-stuck-task" \
    "worktree=$home/projects/stuck-wt" \
    "project=$home/projects/gamma" \
    "harness=claude" \
    "kind=ship" \
    "mode=direct-PR" \
    "yolo=off"
  record_idle "$home/state" stuck-task
  printf 'blocked: the test database credential is missing\n' > "$home/state/stuck-task.status"
  printf 'fm-stuck-task 300\n' >> "$home/live-windows"
  # Endpoint gone with no stand-down: a worker that stopped responding.
  fm_write_meta "$home/state/gone-task.meta" \
    "window=firstmate:fm-gone-task" \
    "worktree=$home/projects/gone-wt" \
    "project=$home/projects/gamma" \
    "harness=claude" \
    "kind=ship" \
    "mode=direct-PR" \
    "yolo=off"
  # A worker in a Herdr pane, whose process tree is 400 -> 401.
  fm_write_meta "$home/state/herdr-task.meta" \
    "window=default:w1:p5" \
    "backend=herdr" \
    "herdr_session=default" \
    "herdr_pane_id=w1:p5" \
    "worktree=$home/projects/run-wt" \
    "project=$home/projects/epsilon" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
  # Stopped on purpose: endpoint gone and a stand-down record.
  fm_write_meta "$home/state/parked-task.meta" \
    "window=firstmate:fm-parked-task" \
    "worktree=$home/projects/parked-wt" \
    "project=$home/projects/alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
  printf 'recorded=%s\nreason=waiting for the upstream release\n' "$((NOW_EPOCH - 86400))" > "$home/state/parked-task.stood-down"
  printf 'stood-down: waiting for the upstream release\n' > "$home/state/parked-task.status"
}

run_sitrep() {  # <home> <fakebin> [args...]
  local home=$1 fb=$2
  shift 2
  PATH="$fb:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW="$NOW_ISO" FM_SNAPSHOT_NOW_EPOCH="$NOW_EPOCH" \
    FM_SITREP_NOW_EPOCH="$NOW_EPOCH" FM_SITREP_PS_BIN="$fb/fake-ps" \
    FM_SITREP_MEMINFO="$home/meminfo" FM_SITREP_LOADAVG="$home/loadavg" FM_SITREP_CORES=12 \
    FM_SITREP_WIDTH=120 "$SITREP" "$@"
}

FIX_HOME=""
FIX_BIN=""
fixture() {
  if [ -z "$FIX_HOME" ]; then
    FIX_HOME=$(make_home fixture)
    write_fixture "$FIX_HOME"
    FIX_BIN=$(make_fakebin "$FIX_HOME")
  fi
  machine_files "$FIX_HOME" 16000000 12000000 1.50
}

test_project_classification() {
  local out
  fixture
  out=$(run_sitrep "$FIX_HOME" "$FIX_BIN" --json) || fail "sitrep --json must succeed"
  printf '%s' "$out" | jq -e '.schema == "fm-sitrep.v1"' >/dev/null || fail "schema id missing: $out"
  printf '%s' "$out" | jq -e '
    (.projects | map({key: .name, value: .status}) | from_entries) as $s
    | $s.gamma == "BLOCKED" and $s.alpha == "WAITING" and $s.delta == "WAITING" and $s.beta == "IDLE"
  ' >/dev/null || fail "project statuses wrong: $(printf '%s' "$out" | jq -c '[.projects[] | {name, status}]')"
  printf '%s' "$out" | jq -e '
    [.projects[].name] as $n
    | ($n | index("gamma")) < ($n | index("alpha")) and ($n | index("alpha")) < ($n | index("beta"))
  ' >/dev/null || fail "projects must be ordered most urgent first"
  printf '%s' "$out" | jq -e '
    (.projects[] | select(.name == "alpha")) as $a
    | $a.running == 1 and $a.parked == 1 and $a.held == 2
  ' >/dev/null || fail "alpha running/parked/held counts wrong: $(printf '%s' "$out" | jq -c '.projects[] | select(.name == "alpha")')"
  printf '%s' "$out" | jq -e '
    (.projects[] | select(.name == "gamma") | .next) | test("stuck|stopped responding")
  ' >/dev/null || fail "gamma next thing must name the stuck or unresponsive worker"
  printf '%s' "$out" | jq -e '
    (.projects[] | select(.name == "delta")) as $d | $d.registered == false and $d.held == 1
  ' >/dev/null || fail "an unregistered project with only a held item must still appear"
  pass "projects are classified blocked, waiting, moving or idle and include unregistered held work"
}

test_decisions_listing() {
  local out
  fixture
  out=$(run_sitrep "$FIX_HOME" "$FIX_BIN" --json)
  printf '%s' "$out" | jq -e '
    [.decisions[].id] == ["later-call", "old-call", "new-call"]
  ' >/dev/null || fail "decisions must list every held item oldest first: $(printf '%s' "$out" | jq -c '[.decisions[].id]')"
  printf '%s' "$out" | jq -e '
    (.decisions[] | select(.id == "old-call")) as $o
    | $o.waiting_days == 6 and $o.overdue == true
      and ($o.hold_reason | contains("https://github.com/example/delta/pull/4"))
  ' >/dev/null || fail "old held item must show its six-day age, be overdue, and keep its PR URL"
  printf '%s' "$out" | jq -e '
    (.decisions[] | select(.id == "new-call")) as $n | $n.overdue == false and $n.waiting_days == 0
  ' >/dev/null || fail "a held item set yesterday must not be overdue"
  printf '%s' "$out" | jq -e '
    (.decisions[] | select(.id == "later-call")) as $l | $l.deferred == true and $l.overdue == false
  ' >/dev/null || fail "a deferred held item must not count as overdue"
  printf '%s' "$out" | jq -e '.verdict.decisions == 2 and .verdict.overdue_decisions == 1' >/dev/null \
    || fail "verdict must count live and overdue decisions: $(printf '%s' "$out" | jq -c .verdict)"
  pass "decisions list every held item oldest first with age, overdue flag and PR URL"
}

test_human_report() {
  local out
  fixture
  out=$(run_sitrep "$FIX_HOME" "$FIX_BIN")
  assert_contains "$out" "SITREP  NEEDS ATTENTION" "a blocked project must make the verdict need attention"
  assert_contains "$out" "2 decisions wait on you (1 overdue)" "verdict line must count overdue decisions"
  assert_contains "$out" "waiting 6 days, OVERDUE" "an overdue decision must be called out with its age"
  assert_contains "$out" "waiting 12 hours" "a recent decision must show its age"
  assert_contains "$out" "deferred until 2026-12-01" "a deferred decision must say until when"
  assert_contains "$out" "OVERDUE 6d:" "the project row must flag its overdue decision"
  assert_contains "$out" "Legend:" "a legend line must explain the status words"
  assert_contains "$out" "waiting for the upstream release" "parked work must show why it was stopped"
  assert_contains "$out" "https://github.com/example/alpha/pull/7" "recently finished work must keep its PR URL"
  assert_contains "$out" "sample-model-1 (high)" "workers must show their recorded model"
  assert_not_contains "$out" "stood-down" "the report must not use internal state labels"
  pass "human report carries verdict, overdue ages, legend, parked reasons and finished links"
}

test_decision_text_length() {
  local out
  fixture
  out=$(run_sitrep "$FIX_HOME" "$FIX_BIN")
  assert_contains "$out" "Choose JSON or SQLite for delta storage." "the first sentence of a decision must show"
  assert_not_contains "$out" "compares both formats" "later sentences must be left out by default"
  assert_contains "$out" "PR: https://github.com/example/delta/pull/4" "a PR URL from a shortened reason must still show in full"
  assert_contains "$out" "--full" "a shortened list must say how to see the whole reasons"
  out=$(run_sitrep "$FIX_HOME" "$FIX_BIN" --full)
  assert_contains "$out" "compares both formats" "--full must show the whole reason"
  assert_not_contains "$out" "Shortened to the first sentence" "--full must not claim the reasons were shortened"
  pass "decision reasons show their first sentence, and --full shows them whole"
}

test_memory_over_process_tree() {
  local out
  fixture
  out=$(run_sitrep "$FIX_HOME" "$FIX_BIN" --json)
  printf '%s' "$out" | jq -e '
    (.workers[] | select(.id == "run-task")) as $w
    | $w.measured == true and $w.processes == 3 and $w.rss_kb == 6000 and $w.cpu_percent == 4
      and $w.running_seconds == 5400 and $w.model == "sample-model-1"
  ' >/dev/null || fail "run-task memory must sum RSS over its three-process tree only: $(printf '%s' "$out" | jq -c '.workers')"
  printf '%s' "$out" | jq -e '
    (.workers[] | select(.id == "stuck-task")) as $w | $w.measured == false and $w.rss_kb == null
  ' >/dev/null || fail "a worker whose root process is absent must be reported as not measured"
  printf '%s' "$out" | jq -e '
    (.workers[] | select(.id == "herdr-task")) as $w
    | $w.measured == true and $w.processes == 2 and $w.rss_kb == 8000 and $w.cpu_percent == 12
  ' >/dev/null || fail "a Herdr worker must be measured from its pane shell's process tree: $(printf '%s' "$out" | jq -c '.workers')"
  printf '%s' "$out" | jq -e '[.workers[].id] | index("parked-task") == null and index("gone-task") == null' >/dev/null \
    || fail "parked and gone workers must not be listed as running"
  printf '%s' "$out" | jq -e '.totals.rss_kb == 14000 and .totals.measured == 2 and .totals.workers == 3' >/dev/null \
    || fail "totals wrong: $(printf '%s' "$out" | jq -c .totals)"
  printf '%s' "$out" | jq -e '.machine.mem_tone == "green" and .machine.load_tone == "green"' >/dev/null \
    || fail "healthy machine must read green"
  out=$(run_sitrep "$FIX_HOME" "$FIX_BIN")
  assert_contains "$out" "6 MiB" "the human report must show the summed memory"
  assert_contains "$out" "(1 not measured)" "the total must disclose unmeasured workers"
  pass "worker memory sums RSS and CPU over each worker's own process tree"
}

test_machine_pressure() {
  local out
  fixture
  machine_files "$FIX_HOME" 16000000 2500000 10.0
  out=$(run_sitrep "$FIX_HOME" "$FIX_BIN" --json)
  printf '%s' "$out" | jq -e '.machine.mem_tone == "yellow" and .machine.load_tone == "yellow"' >/dev/null \
    || fail "low-ish memory and busy load must read yellow: $(printf '%s' "$out" | jq -c .machine)"
  machine_files "$FIX_HOME" 16000000 800000 13.0
  out=$(run_sitrep "$FIX_HOME" "$FIX_BIN" --json)
  printf '%s' "$out" | jq -e '.machine.mem_tone == "red" and .machine.load_tone == "red" and .verdict.machine_pressure == "high"' >/dev/null \
    || fail "very low memory and load above the core count must read red: $(printf '%s' "$out" | jq -c .machine)"
  out=$(run_sitrep "$FIX_HOME" "$FIX_BIN")
  assert_contains "$out" "(LOW)" "low memory must be flagged in words"
  assert_contains "$out" "(OVERLOADED)" "load above the core count must be flagged in words"
  pass "machine memory and load are flagged yellow and red at their thresholds"
}

# Runs a command under a pseudo-terminal when script(1) is available.
run_in_tty() {  # <command-string>
  if script -qec true /dev/null >/dev/null 2>&1; then
    script -qec "$1" /dev/null
  elif script -q /dev/null true >/dev/null 2>&1; then
    script -q /dev/null bash -c "$1"
  else
    return 77
  fi
}

test_colour_controls() {
  local out esc cmd rc
  esc=$'\033['
  fixture
  out=$(run_sitrep "$FIX_HOME" "$FIX_BIN")
  assert_not_contains "$out" "$esc" "output to a pipe must carry no colour"
  out=$(run_sitrep "$FIX_HOME" "$FIX_BIN" --color)
  assert_contains "$out" "${esc}31m" "--color must colour the blocked project red"
  assert_contains "$out" "${esc}33m" "--color must colour waiting items yellow"
  out=$(run_sitrep "$FIX_HOME" "$FIX_BIN" --color --no-color)
  assert_not_contains "$out" "$esc" "--no-color must win over an earlier --color"
  out=$(run_sitrep "$FIX_HOME" "$FIX_BIN" --color --json)
  assert_not_contains "$out" "$esc" "--json must never carry colour"
  printf '%s' "$out" | jq -e . >/dev/null || fail "--json must stay valid JSON"
  cmd="PATH='$FIX_BIN':\"\$PATH\" FM_HOME='$FIX_HOME' FM_SITREP_PS_BIN='$FIX_BIN/fake-ps' FM_SITREP_WIDTH=120 '$SITREP'"
  rc=0
  out=$(run_in_tty "$cmd") || rc=$?
  if [ "$rc" -eq 77 ]; then
    pass "colour controls (terminal checks skipped: script(1) unavailable)"
    return 0
  fi
  assert_contains "$out" "$esc" "a terminal must get colour by default"
  out=$(run_in_tty "NO_COLOR=1 $cmd")
  assert_not_contains "$out" "$esc" "NO_COLOR must turn colour off on a terminal"
  out=$(run_in_tty "$cmd --no-color")
  assert_not_contains "$out" "$esc" "--no-color must turn colour off on a terminal"
  pass "colour follows the terminal, NO_COLOR, --no-color, --color and --json"
}

test_empty_home() {
  local home fb out
  home=$(make_home empty)
  fb=$(make_fakebin "$home")
  machine_files "$home" 16000000 12000000 0.20
  out=$(run_sitrep "$home" "$fb" --json) || fail "sitrep must succeed on an empty home"
  printf '%s' "$out" | jq -e '
    .verdict.word == "QUIET" and (.projects | length) == 0 and (.decisions | length) == 0
      and (.workers | length) == 0 and (.parked | length) == 0 and (.finished | length) == 0
  ' >/dev/null || fail "empty home model wrong: $out"
  out=$(run_sitrep "$home" "$fb")
  assert_contains "$out" "SITREP  QUIET" "an empty home must read quiet"
  assert_contains "$out" "Nothing is waiting on your decision." "empty decisions must say so"
  assert_contains "$out" "No workers are running." "empty workers must say so"
  assert_contains "$out" "Total: 0 workers" "the total line must still print"
  assert_contains "$out" "Nothing has finished recently." "empty finished list must say so"
  pass "a home with no work renders explicit empty states"
}

test_usage() {
  local rc=0
  "$SITREP" --help | grep -q 'usage: fm-sitrep.sh' || fail "--help must print usage"
  "$SITREP" --bogus >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "an unknown flag"
  pass "usage and unknown flags behave"
}

test_project_classification
test_decisions_listing
test_human_report
test_decision_text_length
test_memory_over_process_tree
test_machine_pressure
test_colour_controls
test_empty_home
test_usage
