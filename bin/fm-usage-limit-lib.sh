#!/usr/bin/env bash
# fm-usage-limit-lib.sh - detect a worker stopped on a provider usage-limit
# screen (as opposed to an ordinary wedge) and, where the harness renders one,
# parse the reset time it names.
#
# This is a DETECTION-ONLY library: it reads a captured pane tail and reports
# what it sees. It writes nothing and launches nothing. bin/fm-watch.sh is the
# only caller that acts on a positive detection (see its header for the
# fallback-and-relaunch sequence); bin/fm-fallback-lib.sh owns the fallback
# model choice and the durable record of an active switch.
#
# Detectors are per-harness so that one harness's usage-limit screen can never
# misclassify another's ordinary busy/idle rendering. Add a new harness by
# adding fm_usage_limit_detect_<harness> (required: true/false) and, where
# that harness's screen names a reset time, fm_usage_limit_reset_text_<harness>
# (prints the raw reset phrase, or nothing). Both take the pane tail as $1.
#
# Usage:
#   fm_usage_limit_detect <harness> <tail>        -> exit 0 iff a usage-limit
#                                                     screen is recognized
#   fm_usage_limit_reset_epoch <harness> <tail>    -> prints the parsed reset
#                                                     time as an epoch second,
#                                                     or nothing (exit 1) if
#                                                     the harness names none or
#                                                     it cannot be parsed
#
# Claude Code's limit screen (verified 2026-11-18, claude-fable-5-2) renders a
# banner line naming the limit and a reset time, immediately followed by a
# menu offering exactly these choices (wording is the structural signal, not
# the surrounding punctuation, which has moved between releases):
#   You've hit your Fable limit · resets Nov 19, 11am
#   1. Stop and wait for limit to reset
#   2. Wait here, then continue automatically
#   3. Add funds
# Both the banner phrase and at least one menu option are required together,
# so a stray "limit" mention elsewhere in rendered output (a log line, a
# docstring) cannot alone trip detection.
set -u

fm_usage_limit_detect_claude() {  # <tail>
  local tail=$1
  printf '%s\n' "$tail" | grep -qiE "you.ve hit your .* limit" || return 1
  printf '%s\n' "$tail" | grep -qF "Stop and wait for limit to reset" \
    || printf '%s\n' "$tail" | grep -qF "Wait here, then continue automatically" \
    || return 1
  return 0
}

fm_usage_limit_reset_text_claude() {  # <tail>
  printf '%s\n' "$1" | grep -ioE "resets[[:space:]]+[^·|]*" | head -n1 \
    | sed -E 's/^resets[[:space:]]*//I; s/[[:space:]]+$//'
}

# Dispatch to fm_usage_limit_detect_<harness> when it exists; an unrecognized
# harness simply has no detector yet, never a false positive.
fm_usage_limit_detect() {  # <harness> <tail>
  local harness=$1 tail=$2
  local fn="fm_usage_limit_detect_${harness}"
  [ "$(type -t "$fn" 2>/dev/null || true)" = function ] || return 1
  "$fn" "$tail"
}

# Parse the harness's reset phrase (if it renders one) into an epoch second.
# GNU date resolves a bare "Mon D H:MMam/pm" against the current year; when
# the parsed moment is already more than a day in the past, the renderer meant
# next year's occurrence of that date (a limit screen never reports a reset
# time in the past), so retry with "next year" appended.
fm_usage_limit_reset_epoch() {  # <harness> <tail>
  local harness=$1 tail=$2
  local fn="fm_usage_limit_reset_text_${harness}" text epoch now
  [ "$(type -t "$fn" 2>/dev/null || true)" = function ] || return 1
  text=$("$fn" "$tail") || return 1
  [ -n "$text" ] || return 1
  text=${text//,/}
  epoch=$(date -d "$text" +%s 2>/dev/null) || return 1
  now=$(date +%s)
  if [ "$epoch" -lt "$((now - 86400))" ]; then
    epoch=$(date -d "$text next year" +%s 2>/dev/null) || return 1
  fi
  printf '%s\n' "$epoch"
}

# Small supervisor-facing hint for the no-mistakes review agent failing on the
# same usage-limit screen (AGENTS.md section 7's optional item 4). Pass the
# failed run's recorded failure text; prints one line naming the exact
# ~/.no-mistakes/config.yaml change to recommend, or nothing if the text is
# not a recognized usage-limit failure. Firstmate relays this to the captain
# rather than ever editing ~/.no-mistakes itself.
fm_usage_limit_nm_hint() {  # <failure-text> <fallback-model>
  local text=$1 fallback=${2:-} harness
  printf '%s\n' "$text" | grep -qiE "hit your .* limit" || return 1
  [ -n "$fallback" ] || return 1
  harness=claude
  printf '%s\n' "the no-mistakes review agent hit a usage limit; consider setting agent_config: $harness: model: $fallback in ~/.no-mistakes/config.yaml"
}
