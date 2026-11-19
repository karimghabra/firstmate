#!/usr/bin/env bash
# fm-fallback-lib.sh - ordered per-harness/model fallback chain
# (config/model-fallback.json) and the durable record of an active usage-limit
# switch, read by fm-watch.sh when it falls a wedged worker back and by
# fm-spawn.sh when it resolves the model for a NEW spawn on the same
# harness/model while that switch is still active.
#
# Schema: docs/configuration.md "Model fallback on a usage limit" is the
# single owner of config/model-fallback.json's shape; this file is the single
# owner of how it is read and how the durable record format works.
#
# Record file: state/.usage-limit-<harness>-<sanitized-model> - one line,
#   fallback=<model> reset=<epoch-or-> switched=<epoch>
# written once per harness/model by fm_fallback_record_write when
# fm-watch.sh relaunches a worker onto its fallback model, and consulted (never
# written) by fm-spawn.sh's model resolution for every later spawn that would
# otherwise request the SAME original model on the SAME harness. An absent
# `reset` (recorded as "-") means the harness's screen named no reset time;
# such a record never expires on its own and is cleared only by a captain or
# firstmate action that stops naming the original model. A running fallback
# worker is never touched by this file: expiry governs only what a later NEW
# spawn resolves to, per AGENTS.md section 7.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# Print the next model in the configured fallback chain for <harness>/<model>,
# or nothing (exit 1) when the file is absent, jq is unavailable, the chain is
# unconfigured for that pair, or the configured chain is already exhausted
# (caller passes its own current model, so stepping past a chain's end is
# simply "no further fallback", never a loop back to the start).
fm_fallback_config_next() {  # <harness> <model>
  local harness=$1 model=$2 file="$CONFIG/model-fallback.json" next
  [ -f "$file" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  next=$(jq -r --arg h "$harness" --arg m "$model" '
    (.[$h][$m] // [])[0] // ""
  ' "$file" 2>/dev/null) || return 1
  [ -n "$next" ] || return 1
  printf '%s\n' "$next"
}

# Sanitize a model name into a filename-safe token for the record path.
fm_fallback_sanitize() {  # <token>
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

fm_fallback_record_path() {  # <state-dir> <harness> <model>
  local state=$1 harness=$2 model=$3
  printf '%s/.usage-limit-%s-%s\n' "$state" "$(fm_fallback_sanitize "$harness")" "$(fm_fallback_sanitize "$model")"
}

# Record that <harness>/<model> fell back to <fallback> at <reset-epoch>
# (empty string when the harness named no reset time).
fm_fallback_record_write() {  # <state-dir> <harness> <model> <fallback> [reset-epoch]
  local state=$1 harness=$2 model=$3 fallback=$4 reset=${5:-} path now
  path=$(fm_fallback_record_path "$state" "$harness" "$model")
  now=$(date +%s)
  printf 'fallback=%s reset=%s switched=%s\n' "$fallback" "${reset:--}" "$now" > "$path"
}

# Print the active fallback model for <harness>/<model>, or nothing (exit 1)
# when no record exists or its recorded reset time has passed. A passed-reset
# record is removed as a side effect, so the next spawn resolution and the
# next read both see a clean slate without a separate sweep.
fm_fallback_record_active() {  # <state-dir> <harness> <model>
  local state=$1 harness=$2 model=$3 path line fallback reset now
  path=$(fm_fallback_record_path "$state" "$harness" "$model")
  [ -f "$path" ] || return 1
  line=$(cat "$path" 2>/dev/null) || return 1
  fallback=${line#*fallback=}; fallback=${fallback%% *}
  reset=${line#*reset=}; reset=${reset%% *}
  [ -n "$fallback" ] || return 1
  if [ "$reset" != "-" ] && [ -n "$reset" ]; then
    case "$reset" in
      *[!0-9]*) ;;  # malformed reset: treat as never-expiring rather than guessing
      *)
        now=$(date +%s)
        if [ "$now" -ge "$reset" ]; then
          rm -f "$path"
          return 1
        fi
        ;;
    esac
  fi
  printf '%s\n' "$fallback"
}

# Resolve the model a NEW spawn should actually request: <model> unchanged
# unless an unexpired fallback record for <harness>/<model> says otherwise.
# fm-spawn.sh calls this for every explicitly resolved --model, so a task
# dispatched while an account-level usage limit is still active lands on the
# same fallback a wedged sibling already switched to, and a plain respawn of
# the original model resumes automatically once the record's reset time (if
# any) has passed.
fm_fallback_resolve_spawn_model() {  # <state-dir> <harness> <model>
  local state=$1 harness=$2 model=$3 active
  [ -n "$model" ] && [ "$model" != "-" ] || { printf '%s\n' "$model"; return 0; }
  if active=$(fm_fallback_record_active "$state" "$harness" "$model"); then
    printf '%s\n' "$active"
  else
    printf '%s\n' "$model"
  fi
}
