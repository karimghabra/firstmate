#!/usr/bin/env bash
# tests/fm-usage-limit-fallback.test.sh - the usage-limit fallback feature:
# recognizing a provider usage-limit screen as distinct from an ordinary wedge
# (bin/fm-usage-limit-lib.sh), the configured fallback chain and its durable
# active-switch record (bin/fm-fallback-lib.sh), and the one call site in
# bin/fm-watch.sh that dismisses the menu and relaunches on the fallback model
# when both fire together. Also covers that an active record's reset time
# governs a later NEW spawn's model resolution (bin/fm-spawn.sh), while a
# running fallback worker is never touched by expiry.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-usage-limit-lib.sh
. "$ROOT/bin/fm-usage-limit-lib.sh"
# shellcheck source=bin/fm-fallback-lib.sh
. "$ROOT/bin/fm-fallback-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-usage-limit-fallback-tests)

case_dir() {  # <name>
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/config" "$d/state"
  printf '%s' "$d"
}

CLAUDE_LIMIT_SCREEN=$(printf '%s\n' \
  "some earlier pane output" \
  "You've hit your Fable limit · resets Nov 19, 11am" \
  "1. Stop and wait for limit to reset" \
  "2. Wait here, then continue automatically" \
  "3. Add funds")

# A second fixture whose reset phrase is always a few hours ahead of whenever
# this suite actually runs, for the cases below that need the record to still
# be active at assertion time; CLAUDE_LIMIT_SCREEN's fixed "Nov 19" wording is
# fine for the pure parsing tests above, which only check the text parses to
# the same moment `date` itself resolves it to, never that the moment is
# still in the future.
CLAUDE_LIMIT_SCREEN_FUTURE=$(printf '%s\n' \
  "some earlier pane output" \
  "You've hit your Fable limit · resets $(date -d "+3 hours" "+%b %-d, %-I%P")" \
  "1. Stop and wait for limit to reset" \
  "2. Wait here, then continue automatically" \
  "3. Add funds")

ORDINARY_WEDGE_PANE=$(printf '%s\n' \
  "a static pane that just happens to mention a limit in passing" \
  "waiting on something that never completes")

# --- detection ---------------------------------------------------------------

test_detects_the_claude_limit_screen() {
  fm_usage_limit_detect claude "$CLAUDE_LIMIT_SCREEN" \
    || fail "Claude's limit banner plus menu was not recognized"
  pass "Claude's usage-limit screen is recognized"
}

test_an_ordinary_wedge_is_not_misread_as_a_limit() {
  if fm_usage_limit_detect claude "$ORDINARY_WEDGE_PANE"; then
    fail "a stray 'limit' mention without the menu was misread as a usage-limit screen"
  fi
  pass "an ordinary wedge pane is not misread as a usage limit"
}

test_detect_is_scoped_to_its_own_harness() {
  if fm_usage_limit_detect codex "$CLAUDE_LIMIT_SCREEN"; then
    fail "Claude's screen was recognized under an unrelated harness name"
  fi
  pass "detection never crosses harness boundaries"
}

test_reset_time_is_parsed_to_the_correct_epoch() {
  local epoch want
  epoch=$(fm_usage_limit_reset_epoch claude "$CLAUDE_LIMIT_SCREEN") \
    || fail "no reset time was parsed from the limit screen"
  want=$(date -d "Nov 19 11:00am" +%s)
  [ "$epoch" = "$want" ] || fail "reset epoch mismatch: got $epoch want $want"
  pass "the limit screen's reset time is parsed to the right epoch"
}

test_no_reset_time_on_an_undetected_screen() {
  if fm_usage_limit_reset_epoch claude "$ORDINARY_WEDGE_PANE" >/dev/null 2>&1; then
    fail "a reset epoch was produced for a pane with no limit screen"
  fi
  pass "no reset epoch is manufactured when there is nothing to parse"
}

# --- fallback chain selection ------------------------------------------------

# bin/fm-fallback-lib.sh resolves config/ once at source time from
# FM_CONFIG_OVERRIDE (the same convention bin/fm-harness.sh uses), so a case
# that varies the config directory re-sources it in a fresh subprocess rather
# than relying on this file's own already-sourced copy.
fallback_config_next_in() {  # <config-dir> <harness> <model>
  local config=$1 harness=$2 model=$3
  FM_CONFIG_OVERRIDE="$config" bash -c '
    . "$1/bin/fm-fallback-lib.sh"
    fm_fallback_config_next "$2" "$3"
  ' _ "$ROOT" "$harness" "$model"
}

test_fallback_config_selects_the_next_model() {
  local d
  d=$(case_dir config-next)
  cat > "$d/config/model-fallback.json" <<'EOF'
{
  "claude": {
    "claude-fable-5-2": ["claude-opus-5-5"]
  }
}
EOF
  [ "$(fallback_config_next_in "$d/config" claude claude-fable-5-2)" = "claude-opus-5-5" ] \
    || fail "configured fallback chain did not select claude-opus-5-5"
  pass "the configured fallback chain selects the next model"
}

test_fallback_config_absent_file_means_no_fallback() {
  local d
  d=$(case_dir config-absent)
  if fallback_config_next_in "$d/config" claude claude-fable-5-2 >/dev/null 2>&1; then
    fail "a fallback was produced with no config/model-fallback.json present"
  fi
  pass "no config/model-fallback.json means no fallback, not an error"
}

test_fallback_config_unconfigured_model_has_no_next_step() {
  local d
  d=$(case_dir config-exhausted)
  cat > "$d/config/model-fallback.json" <<'EOF'
{
  "claude": {
    "claude-fable-5-2": ["claude-opus-5-5"]
  }
}
EOF
  if fallback_config_next_in "$d/config" claude claude-opus-5-5 >/dev/null 2>&1; then
    fail "a model with no configured chain of its own produced a fallback"
  fi
  pass "a model past the end of its configured chain has no further fallback"
}

# --- durable active-switch record and expiry ---------------------------------

test_record_write_and_read_back() {
  local d reset
  d=$(case_dir record-roundtrip)
  reset=$(( $(date +%s) + 3600 ))
  fm_fallback_record_write "$d/state" claude claude-fable-5-2 claude-opus-5-5 "$reset"
  [ "$(fm_fallback_record_active "$d/state" claude claude-fable-5-2)" = "claude-opus-5-5" ] \
    || fail "an unexpired fallback record was not read back"
  pass "a freshly written fallback record is active"
}

test_expired_record_is_cleared_and_ignored() {
  local d reset path
  d=$(case_dir record-expiry)
  reset=$(( $(date +%s) - 10 ))
  fm_fallback_record_write "$d/state" claude claude-fable-5-2 claude-opus-5-5 "$reset"
  path=$(fm_fallback_record_path "$d/state" claude claude-fable-5-2)
  if fm_fallback_record_active "$d/state" claude claude-fable-5-2; then
    fail "a record past its recorded reset time was still reported active"
  fi
  [ ! -e "$path" ] || fail "an expired fallback record was not cleared"
  pass "an expired fallback record is cleared and no longer reported active"
}

test_resolve_spawn_model_uses_the_active_record() {
  local d reset
  d=$(case_dir resolve-active)
  reset=$(( $(date +%s) + 3600 ))
  fm_fallback_record_write "$d/state" claude claude-fable-5-2 claude-opus-5-5 "$reset"
  [ "$(fm_fallback_resolve_spawn_model "$d/state" claude claude-fable-5-2)" = "claude-opus-5-5" ] \
    || fail "a new spawn naming the limited model did not resolve to the active fallback"
  pass "a new spawn resolves onto the active fallback model"
}

test_resolve_spawn_model_resumes_the_original_after_expiry() {
  local d reset
  d=$(case_dir resolve-expired)
  reset=$(( $(date +%s) - 10 ))
  fm_fallback_record_write "$d/state" claude claude-fable-5-2 claude-opus-5-5 "$reset"
  [ "$(fm_fallback_resolve_spawn_model "$d/state" claude claude-fable-5-2)" = "claude-fable-5-2" ] \
    || fail "a new spawn did not resume the original model once the fallback record expired"
  pass "a new spawn resumes the original model once the recorded reset time has passed"
}

test_resolve_spawn_model_passes_through_an_unrelated_model() {
  local d reset
  d=$(case_dir resolve-unrelated)
  reset=$(( $(date +%s) + 3600 ))
  fm_fallback_record_write "$d/state" claude claude-fable-5-2 claude-opus-5-5 "$reset"
  [ "$(fm_fallback_resolve_spawn_model "$d/state" claude claude-sonnet-5)" = "claude-sonnet-5" ] \
    || fail "an unrelated model was rewritten by another model's fallback record"
  pass "a spawn for an unrelated model is never affected by someone else's fallback record"
}

# --- the watcher's one call site: detect + dismiss + relaunch together -------

# A fake fm-control.sh: records every invocation (verb, model, note) to a log
# and always succeeds, so the call site is tested as a black box through its
# own override point (FM_CONTROL_BIN mirrors fm-classify-lib.sh's
# FM_CREW_STATE_BIN pattern) rather than by asserting fm-watch.sh's source.
make_fake_control() {  # <dir>
  local bin="$1/fake-fm-control.sh"
  cat > "$bin" <<'SH'
#!/usr/bin/env bash
set -u
log="$FM_FAKE_CONTROL_LOG"
id=$1; shift
printf 'task=%s' "$id" >> "$log"
for a in "$@"; do printf ' %s' "$a" >> "$log"; done
printf '\n' >> "$log"
exit 0
SH
  chmod +x "$bin"
  printf '%s' "$bin"
}

make_fallback_window_fixture() {  # <dir> <task-id>
  local d=$1 id=$2
  cat > "$d/state/$id.meta" <<EOF
window=fm-$id
harness=claude
model=claude-fable-5-2
backend=tmux
kind=ship
EOF
  : > "$d/state/$id.status"
}

test_watch_fallback_check_dismisses_and_relaunches_on_detection() {
  local d id log control_bin rc record status_tail
  d=$(case_dir watch-fallback-hit)
  id="fallback-hit"
  cat > "$d/config/model-fallback.json" <<'EOF'
{
  "claude": {
    "claude-fable-5-2": ["claude-opus-5-5"]
  }
}
EOF
  make_fallback_window_fixture "$d" "$id"
  control_bin=$(make_fake_control "$d")
  log="$d/control.log"
  : > "$log"

  rc=0
  FM_STATE_OVERRIDE="$d/state" FM_CONFIG_OVERRIDE="$d/config" \
    FM_CONTROL_BIN="$control_bin" FM_FAKE_CONTROL_LOG="$log" \
    bash -c '
      . "$1/bin/fm-watch.sh"
      usage_limit_fallback_check "fm-$2" "$2" "$3"
    ' _ "$ROOT" "$id" "$CLAUDE_LIMIT_SCREEN_FUTURE"
  rc=$?
  [ "$rc" -eq 0 ] || fail "usage_limit_fallback_check did not report success on a real detection with a configured fallback"

  grep -qF "task=$id interrupt" "$log" \
    || fail "the limit menu was not dismissed via an interrupt call: $(cat "$log")"
  grep -qF "task=$id relaunch --model claude-opus-5-5" "$log" \
    || fail "the worker was not relaunched on the configured fallback model: $(cat "$log")"

  record=$(fm_fallback_record_active "$d/state" claude claude-fable-5-2) \
    || fail "no active fallback record was written after the automatic switch"
  [ "$record" = claude-opus-5-5 ] || fail "the fallback record named the wrong model: $record"

  status_tail=$(tail -n1 "$d/state/$id.status")
  case "$status_tail" in
    "working: automatically switched from claude-fable-5-2 to claude-opus-5-5"*) ;;
    *) fail "the status log was not told about the automatic switch: $status_tail" ;;
  esac
  pass "a real usage-limit screen with a configured fallback is dismissed, relaunched, and durably recorded"
}

test_watch_fallback_check_leaves_an_ordinary_wedge_alone() {
  local d id log control_bin rc
  d=$(case_dir watch-fallback-miss)
  id="ordinary-wedge"
  cat > "$d/config/model-fallback.json" <<'EOF'
{
  "claude": {
    "claude-fable-5-2": ["claude-opus-5-5"]
  }
}
EOF
  make_fallback_window_fixture "$d" "$id"
  control_bin=$(make_fake_control "$d")
  log="$d/control.log"
  : > "$log"

  rc=0
  FM_STATE_OVERRIDE="$d/state" FM_CONFIG_OVERRIDE="$d/config" \
    FM_CONTROL_BIN="$control_bin" FM_FAKE_CONTROL_LOG="$log" \
    bash -c '
      . "$1/bin/fm-watch.sh"
      usage_limit_fallback_check "fm-$2" "$2" "$3"
    ' _ "$ROOT" "$id" "$ORDINARY_WEDGE_PANE"
  rc=$?
  [ "$rc" -ne 0 ] || fail "an ordinary wedge pane was handled as a usage-limit fallback"
  [ ! -s "$log" ] || fail "fm-control.sh was invoked for a pane that was never a usage-limit screen: $(cat "$log")"
  pass "an ordinary wedge pane falls straight through, untouched, to the usual stale/wedge handling"
}

test_watch_fallback_check_falls_through_with_no_configured_fallback() {
  local d id log control_bin rc
  d=$(case_dir watch-fallback-unconfigured)
  id="unconfigured-model"
  make_fallback_window_fixture "$d" "$id"
  control_bin=$(make_fake_control "$d")
  log="$d/control.log"
  : > "$log"

  rc=0
  FM_STATE_OVERRIDE="$d/state" FM_CONFIG_OVERRIDE="$d/config" \
    FM_CONTROL_BIN="$control_bin" FM_FAKE_CONTROL_LOG="$log" \
    bash -c '
      . "$1/bin/fm-watch.sh"
      usage_limit_fallback_check "fm-$2" "$2" "$3"
    ' _ "$ROOT" "$id" "$CLAUDE_LIMIT_SCREEN"
  rc=$?
  [ "$rc" -ne 0 ] || fail "a detected usage limit with no config/model-fallback.json still reported success"
  [ ! -s "$log" ] || fail "fm-control.sh was invoked with no fallback configured: $(cat "$log")"
  pass "a detected usage limit with no configured fallback escalates exactly as an ordinary wedge would"
}

test_detects_the_claude_limit_screen
test_an_ordinary_wedge_is_not_misread_as_a_limit
test_detect_is_scoped_to_its_own_harness
test_reset_time_is_parsed_to_the_correct_epoch
test_no_reset_time_on_an_undetected_screen
test_fallback_config_selects_the_next_model
test_fallback_config_absent_file_means_no_fallback
test_fallback_config_unconfigured_model_has_no_next_step
test_record_write_and_read_back
test_expired_record_is_cleared_and_ignored
test_resolve_spawn_model_uses_the_active_record
test_resolve_spawn_model_resumes_the_original_after_expiry
test_resolve_spawn_model_passes_through_an_unrelated_model
test_watch_fallback_check_dismisses_and_relaunches_on_detection
test_watch_fallback_check_leaves_an_ordinary_wedge_alone
test_watch_fallback_check_falls_through_with_no_configured_fallback
