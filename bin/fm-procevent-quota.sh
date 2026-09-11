#!/usr/bin/env bash
# Quota process-event adapter: the falling edge (quota running out) and the
# rising edge (a quota window refreshing).
#
# Usage:
#   fm-procevent-quota.sh arm [--interval <secs>] [--threshold <percent>] [--provider <provider>]
#   fm-procevent-quota.sh arm --refresh [--interval <secs>] [--provider <provider>] [--window <window-id>]
#   fm-procevent-quota.sh poll [--interval <secs>] [--threshold <percent>] [--provider <provider>] [--timeout <secs>]
#   fm-procevent-quota.sh poll --refresh [--interval <secs>] [--provider <provider>] [--window <window-id>] [--timeout <secs>]
#   fm-procevent-quota.sh classify <result-file>
#   fm-procevent-quota.sh terminal <result-file>
#   fm-procevent-quota.sh source-id [--refresh] [--provider <provider>]
#   fm-procevent-quota.sh retire [--refresh] [--provider <provider>]
#
# arm        Register a recurring quota-axi --json poll that wakes firstmate.
#            Without --refresh it watches the falling edge and fires when the
#            tracked provider's effectivePercentRemaining drops below
#            <threshold> (default 10%) or when its runway.status becomes
#            exhausted_now. With --refresh it watches the rising edge and fires
#            when the binding quota window turns over and its headroom is back
#            at or above 25%; the exact rule is below. Both conditions are
#            deterministic, the action is only the durable
#            `check: procevent:quota:<seq>` wake, and the watch is registered
#            through `bin/fm-procevent.sh register`. Deciding what to dispatch
#            on a refreshed window is firstmate's judgment about queued work and
#            is never bound into the watch.
# poll       The blocking child the generic runner executes; never run this
#            directly in a conversational turn.
# classify   Print the captured outcome class: low, exhausted, refreshed,
#            error, or unknown.
# terminal   Every quota poll is terminal because the source fires at most once.
# source-id  Print the canonical source id.
# retire     Stop the matching watch, retire the registration, and for a refresh
#            watch discard its recorded window baseline. Idempotent.
#
# The canonical source id is `quota` for the aggregate falling-edge watch and
# `quota-refresh` for the aggregate refresh watch. A provider named with
# --provider sets the tracked provider and appends `-<provider>` to that id, so
# both edges can be armed for the same provider at the same time.
#
# Refresh-edge mechanics, because this is the part that is easy to get wrong:
#
#   * The watch pins one window - provider plus window id - and records that
#     window's `resetsAt` boundary and `percentRemaining` in a durable baseline
#     under `state/quota-refresh/`. Every arm starts a fresh baseline, and a
#     baseline recorded for another provider or another explicit --window is
#     treated as absent and re-established.
#   * Without --window the pinned window is the binding one - the window whose
#     exhaustion stops dispatch - read from quotaSemantics.effectiveAvailability:
#     the tightest scope is an exhausted_now one if any, otherwise the one with
#     the lowest effectivePercentRemaining, and its limiting window is pinned.
#     When several windows tie as limiting, the one resetting last is pinned,
#     because headroom only returns once every one of them has turned over. A
#     window that refreshes sooner without being binding never fires the watch.
#     --window pins an explicit window id instead. No window length is
#     hardcoded: every id, boundary, and percentage comes from quota-axi.
#   * The watch fires only when all three of these hold for the pinned window:
#       1. the recorded boundary has elapsed by the snapshot's own `generatedAt`;
#       2. the window has turned over: it reports no `resetsAt` (a window that
#          reset and has not been used since), a `resetsAt` at or before
#          `generatedAt`, or a `resetsAt` at least 300 seconds later than the
#          recorded boundary;
#       3. its `percentRemaining` is at or above 25%.
#     Headroom rising inside the recorded window therefore never fires it.
#   * The 300-second floor in (2) exists because quota-axi recomputes `resetsAt`
#     on every call and its jitter of roughly a second crosses whole-second
#     boundaries, so a bare strictly-later comparison reports a turnover that
#     never happened. A real turnover advances by the window's whole length.
#   * The baseline is durable rather than in-memory, so a boundary crossed while
#     nothing was polling is still detected on the next poll.
#   * An unknown or unreadable reading never fires: a window absent from the
#     snapshot, a `resetsAt` that is present but does not parse, or a missing or
#     out-of-range `percentRemaining` leaves the baseline untouched and keeps
#     polling. A quota-axi failure or a malformed snapshot is reported as an
#     error outcome exactly as the falling-edge watch reports it.
#   * Firing leaves the baseline untouched; only arm and retire replace or
#     discard it. The runner captures the outcome only after the poll exits, so
#     a poll relaunched after a lost capture reports the same turnover again
#     rather than swallowing it.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

DEFAULT_INTERVAL=60
DEFAULT_THRESHOLD=10
REFRESH_RESTORE=25
REFRESH_MIN_ADVANCE=300

SOURCE_ID_BASE=quota
REFRESH_SOURCE_ID_BASE=quota-refresh
BASELINE_DIR="$STATE/quota-refresh"

CANONICAL_SOURCE_ID=
PROVIDER=
MODE=low

# Shared ISO-8601 to epoch-seconds normalizer. quota-axi emits both
# `...Z` and `...+00:00`, with and without fractional seconds, so the boundary
# comparison must not depend on the platform's `date` accepting either. jq's
# own mktime treats its argument as UTC on every platform, and the numeric
# offset is subtracted here, so an unparseable timestamp becomes null rather
# than a wrong instant.
# shellcheck disable=SC2016  # single quotes are deliberate: this is a literal jq program.
ISO_EPOCH_JQ='
def iso_epoch:
  if type != "string" then null
  else
    (capture("^(?<y>[0-9]{4})-(?<mo>[0-9]{2})-(?<d>[0-9]{2})[Tt ](?<h>[0-9]{2}):(?<mi>[0-9]{2}):(?<s>[0-9]{2})(\\.[0-9]+)?(?<off>[Zz]|[+-][0-9]{2}:?[0-9]{2})$") // null) as $c
    | if $c == null then null
      else
        ([($c.y | tonumber), (($c.mo | tonumber) - 1), ($c.d | tonumber),
          ($c.h | tonumber), ($c.mi | tonumber), ($c.s | tonumber), 0, 0] | mktime) as $utc
        | (if ($c.off | test("^[Zz]$")) then 0
           else
             ($c.off | capture("^(?<sg>[+-])(?<oh>[0-9]{2}):?(?<om>[0-9]{2})$")) as $o
             | ((($o.oh | tonumber) * 3600) + (($o.om | tonumber) * 60))
               * (if $o.sg == "-" then -1 else 1 end)
           end) as $offset
        | $utc - $offset
      end
  end;
def window_reading($p):
  select(type == "object")
  | select((.id | type) == "string" and (.id | length) > 0)
  | {provider: $p, id: .id, resetsAt: .resetsAt, epoch: (.resetsAt | iso_epoch),
     percentRemaining: .percentRemaining}
  | select(.resetsAt == null or .epoch != null)
  | select((.percentRemaining | type) == "number"
           and .percentRemaining >= 0 and .percentRemaining <= 100);
def reading_row:
  .provider, .id, (.resetsAt // ""), ((.epoch // "") | tostring), (.percentRemaining | tostring);
'

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

resolve_provider() {
  local LC_ALL=C base
  if [ "$MODE" = refresh ]; then base=$REFRESH_SOURCE_ID_BASE; else base=$SOURCE_ID_BASE; fi
  PROVIDER=${1:-}
  if [ -n "$PROVIDER" ]; then
    [[ "$PROVIDER" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "invalid provider: $PROVIDER"
    CANONICAL_SOURCE_ID="$base-$PROVIDER"
  else
    CANONICAL_SOURCE_ID=$base
    PROVIDER=
  fi
  fm_procevent_source_id_valid "$CANONICAL_SOURCE_ID" || die "source id is not path-safe: $CANONICAL_SOURCE_ID"
}

positive_number() {
  local n=${1-}
  local LC_ALL=C
  [[ "$n" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  [ "$n" != 0 ] && [[ ! "$n" =~ ^0+(\.0+)?$ ]]
}

positive_int() { case "${1-}" in ''|*[!0-9]*) return 1 ;; 0) return 1 ;; *) return 0 ;; esac }

valid_percent() {
  local n=${1-}
  local LC_ALL=C
  [[ "$n" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  jq -en --arg n "$n" '($n | tonumber) <= 100' >/dev/null 2>&1
}

valid_window_id() {
  local w=${1-}
  local LC_ALL=C
  [[ "$w" =~ ^[A-Za-z0-9][A-Za-z0-9_:.-]*$ ]] || return 1
  [ "${#w}" -le 64 ]
}

valid_epoch() {
  local LC_ALL=C
  [[ "${1-}" =~ ^-?[0-9]+$ ]]
}

num_ge() { jq -en --arg a "${1-}" --arg b "${2-}" '($a | tonumber) >= ($b | tonumber)' >/dev/null 2>&1; }

# quota_json [timeout]
# Run `quota-axi --json` bounded by the given timeout. A missing or incompatible
# quota-axi is an error condition, not a signal to fire.
quota_json() {
  local timeout=${1:-} output
  if [ -n "$timeout" ]; then
    fm_quota_axi_compatible "$timeout" >/dev/null 2>&1 || return 2
    output=$(fm_run_timed "$timeout" quota-axi --json 2>/dev/null </dev/null) || return 2
  else
    fm_quota_axi_compatible >/dev/null 2>&1 || return 2
    output=$(quota-axi --json 2>/dev/null </dev/null) || return 2
  fi
  printf '%s\n' "$output"
}

# condition_status <json> [provider] [threshold]
# Print healthy, low, exhausted, or error for the tightest known applicable
# quota scope.
condition_status() {
  local json=$1 provider=${2:-} threshold=${3:-$DEFAULT_THRESHOLD}
  printf '%s\n' "$json" | fm_quota_json_valid || { printf 'error\n'; return; }
  printf '%s\n' "$json" | jq -r --arg provider "$provider" --arg threshold "$threshold" '
    def classify($availability):
      ($availability | map(select(.status == "known"))) as $known |
      if ($availability | length) == 0 then "error"
      elif any($availability[]; (.runway.status // "") == "exhausted_now") then "exhausted"
      elif ($known | length) == 0 then "healthy"
      elif any($known[]; .effectivePercentRemaining < ($threshold | tonumber)) then "low"
      else "healthy"
      end;
    if (.providers | type) != "array" then "error"
    elif $provider == "" then
      if (.providers | length) == 0 then "healthy"
      elif ([.providers[]?.quotaSemantics.effectiveAvailability[]?] | length) == 0 then "healthy"
      else classify([.providers[]?.quotaSemantics.effectiveAvailability[]?])
      end
    else
      ([.providers[]? | select(.provider == $provider)] | first) as $p |
      if ($p // null) == null then "error"
      elif ($p.quotaSemantics.effectiveAvailability | length) == 0 and
           ($p.quotaSemantics.status == "unknown" or $p.quotaSemantics.status == "partial") then "healthy"
      else classify($p.quotaSemantics.effectiveAvailability // [])
      end
    end
  ' 2>/dev/null || printf 'error\n'
}

# details <json> [provider]
# Print a one-line summary of the quota state for the result document.
details() {
  local json=$1 provider=${2:-}
  printf '%s\n' "$json" | jq -c --arg provider "$provider" '
    def best_detail($availability):
      ($availability | map(select(.status == "known"))) as $known |
      ($availability | map(select((.runway.status // "") == "exhausted_now"))) as $exhausted |
      if ($exhausted | length) > 0 then ($exhausted | min_by(.effectivePercentRemaining // 101))
      elif ($known | length) > 0 then ($known | min_by(.effectivePercentRemaining))
      else null
      end;
    if $provider == "" then
      {
        provider: "aggregate",
        summary: [
          (.providers[]? |
            { provider: .provider,
              best: best_detail(.quotaSemantics.effectiveAvailability // [])
            }
          )
        ]
      }
    else
      (.providers[]? | select(.provider == $provider)) as $p |
      {
        provider: $provider,
        best: best_detail($p.quotaSemantics.effectiveAvailability // [])
      }
    end
  ' 2>/dev/null
}

# select_window <json> <provider> <window-id>
# Print the window to pin as five lines - provider, id, resetsAt, epoch,
# percentRemaining - or nothing when the snapshot names no pinnable window. An
# explicit window id is taken as given; otherwise the binding window is read
# from the tightest effectiveAvailability scope, and among tied limiting windows
# the one resetting last wins. Only a window with a reset boundary can be pinned.
select_window() {
  local json=$1 provider=$2 window=$3
  printf '%s\n' "$json" | jq -r \
    --arg provider "$provider" --arg window "$window" \
    "$ISO_EPOCH_JQ"'
    [ .providers[]? | select($provider == "" or .provider == $provider) ] as $ps
    | (if $window != "" then
         [ $ps[] | . as $p | (.windows // [])[]? | window_reading($p.provider)
           | select(.id == $window) ]
       else
         ([ $ps[] | . as $p | (.quotaSemantics.effectiveAvailability // [])[]?
            | select(type == "object")
            | { provider: $p.provider,
                exhausted: ((.runway.status? // "") == "exhausted_now"),
                eff: (if (.effectivePercentRemaining | type) == "number"
                      then .effectivePercentRemaining else null end),
                ids: ([(.limitingWindowIds? // [])[]?, (.runway.limitingWindowId? // empty)]
                      | map(select(type == "string"))) }
            | select(.exhausted or .eff != null) ]
          | sort_by((if .exhausted then 0 else 1 end), (.eff // 101))
          | first) as $b
         | if $b == null then []
           else
             [ $ps[] | select(.provider == $b.provider) | . as $p
               | (.windows // [])[]? | window_reading($p.provider)
               | select(.id as $id | any($b.ids[]; . == $id)) ]
           end
       end)
    | map(select(.epoch != null))
    | sort_by(.epoch, .id, .provider)
    | last
    | if . == null then empty else reading_row end
  ' 2>/dev/null
}

# read_window <json> <provider> <window-id>
# Print the pinned window's current reading in the same five-line shape, with
# empty resetsAt and epoch lines when the window reports no boundary, or
# nothing when it is absent or unreadable.
read_window() {
  local json=$1 provider=$2 window=$3
  printf '%s\n' "$json" | jq -r \
    --arg provider "$provider" --arg window "$window" \
    "$ISO_EPOCH_JQ"'
    [ .providers[]?
      | select(.provider == $provider)
      | . as $p
      | (.windows // [])[]?
      | window_reading($p.provider)
      | select(.id == $window)
    ]
    | first
    | if . == null then empty else reading_row end
  ' 2>/dev/null
}

W_PROVIDER='' W_ID='' W_RESETS='' W_EPOCH='' W_PERCENT=''

# parse_window_row <row>
# Load a complete five-line window record into the W_* variables. A short,
# empty, or otherwise incomplete record is refused, so a reading the adapter
# cannot fully trust never reaches the boundary comparison; resetsAt and its
# epoch are either both present or both empty. The record is newline-delimited
# rather than tab-delimited because tab is IFS whitespace: `read` would collapse
# adjacent empty fields and silently shift the rest.
parse_window_row() {
  local row=${1-} fields=()
  [ -n "$row" ] || return 1
  mapfile -t fields <<< "$row"
  [ "${#fields[@]}" -eq 5 ] || return 1
  W_PROVIDER=${fields[0]} W_ID=${fields[1]} W_RESETS=${fields[2]}
  W_EPOCH=${fields[3]} W_PERCENT=${fields[4]}
  [ -n "$W_PROVIDER" ] && [ -n "$W_ID" ] || return 1
  if [ -n "$W_RESETS" ]; then
    valid_epoch "$W_EPOCH" || return 1
  else
    [ -z "$W_EPOCH" ] || return 1
  fi
  valid_percent "$W_PERCENT"
}

# snapshot_now <json>
# The instant the snapshot describes, taken from quota-axi's own `generatedAt`
# so the elapsed-boundary test does not depend on this host's clock agreeing
# with the provider's. Falls back to local time when that field is absent or
# unparseable.
snapshot_now() {
  local json=$1 now
  now=$(printf '%s\n' "$json" | jq -r "$ISO_EPOCH_JQ"'
    (.generatedAt | iso_epoch) | if . == null then "" else tostring end
  ' 2>/dev/null)
  valid_epoch "$now" || now=$(date +%s)
  printf '%s\n' "$now"
}

baseline_file() { printf '%s/%s.baseline\n' "$BASELINE_DIR" "$1"; }

# baseline_write <source-id> <provider> <window> <resetsAt> <epoch> <percent>
baseline_write() {
  local id=$1 provider=$2 window=$3 resets=$4 epoch=$5 percent=$6 tmp file
  file=$(baseline_file "$id")
  (umask 077; mkdir -p "$BASELINE_DIR") || return 1
  [ -d "$BASELINE_DIR" ] && [ ! -L "$BASELINE_DIR" ] || return 1
  tmp=$(umask 077; mktemp "$BASELINE_DIR/.baseline.XXXXXX") || return 1
  {
    printf 'source: %s\n' "$id"
    printf 'provider: %s\n' "$provider"
    printf 'window: %s\n' "$window"
    printf 'resets_at: %s\n' "$resets"
    printf 'resets_at_epoch: %s\n' "$epoch"
    printf 'percent_remaining: %s\n' "$percent"
    printf 'recorded_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
}

BL_PROVIDER='' BL_WINDOW='' BL_RESETS='' BL_EPOCH='' BL_PERCENT=''

# baseline_read <source-id>
# Load a complete, well-formed baseline into the BL_* variables. An incomplete
# or corrupt record reads as absent, so the watch re-establishes it rather than
# comparing against a value it cannot trust.
baseline_read() {
  local file key value
  file=$(baseline_file "$1")
  [ -f "$file" ] || return 1
  BL_PROVIDER='' BL_WINDOW='' BL_RESETS='' BL_EPOCH='' BL_PERCENT=''
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%: *}
    value=${line#*: }
    [ "$key" != "$line" ] || continue
    case "$key" in
      provider)          BL_PROVIDER=$value ;;
      window)            BL_WINDOW=$value ;;
      resets_at)         BL_RESETS=$value ;;
      resets_at_epoch)   BL_EPOCH=$value ;;
      percent_remaining) BL_PERCENT=$value ;;
    esac
  done < "$file"
  [ -n "$BL_PROVIDER" ] && [ -n "$BL_WINDOW" ] && [ -n "$BL_RESETS" ] || return 1
  valid_epoch "$BL_EPOCH" || return 1
  valid_percent "$BL_PERCENT" || return 1
  valid_window_id "$BL_WINDOW" || return 1
}

cmd_source_id() {
  local provider=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --refresh)  MODE=refresh; shift ;;
      --provider) [ -n "${2-}" ] || die "--provider needs a value"; provider=$2; shift 2 ;;
      -*) usage ;;
      *) [ -z "$provider" ] || usage; provider=$1; shift ;;
    esac
  done
  resolve_provider "$provider"
  printf '%s\n' "$CANONICAL_SOURCE_ID"
}

# establish_baseline <json> <provider> <window> -- prints the pinned row on success.
establish_baseline() {
  local json=$1 provider=$2 window=$3 row
  row=$(select_window "$json" "$provider" "$window") || return 1
  parse_window_row "$row" || return 1
  baseline_write "$CANONICAL_SOURCE_ID" "$W_PROVIDER" "$W_ID" "$W_RESETS" "$W_EPOCH" "$W_PERCENT" || return 1
  printf '%s\n' "$row"
}

cmd_arm() {
  local interval=$DEFAULT_INTERVAL threshold='' window='' provider='' row
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --refresh)   MODE=refresh; shift ;;
      --interval)  positive_number "${2-}" || die "--interval needs a positive number"; interval=$2; shift 2 ;;
      --threshold) valid_percent "${2-}" || die "--threshold needs a percent 0-100"; threshold=$2; shift 2 ;;
      --window)    [ "$#" -ge 2 ] || die "--window needs a value"; window=$2; shift 2 ;;
      --provider)  [ -n "${2-}" ] || die "--provider needs a value"; provider=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  if [ "$MODE" = refresh ]; then
    [ -z "$threshold" ] || die "--threshold belongs to the falling-edge watch, not --refresh"
    [ -z "$window" ] || valid_window_id "$window" || die "invalid window id: $window"
  else
    [ -z "$window" ] || die "--window needs --refresh"
    threshold=${threshold:-$DEFAULT_THRESHOLD}
  fi
  resolve_provider "$provider"
  fm_quota_axi_compatible 5 >/dev/null 2>&1 || die "quota-axi is missing or below the compatibility floor"
  local timeout
  timeout=$(perl -e 'print int($ARGV[0] * 0.8 + 0.5)' "$interval") || timeout=30
  [ "$timeout" -ge 5 ] || timeout=5

  if [ "$MODE" = refresh ]; then
    local json='' baseline_note='deferred to the first poll'
    rm -f -- "$(baseline_file "$CANONICAL_SOURCE_ID")"
    if json=$(quota_json 10) && printf '%s\n' "$json" | fm_quota_json_valid; then
      # establish_baseline runs in a subshell here, so re-parse its printed
      # record rather than reading the W_* variables it set in that child.
      if row=$(establish_baseline "$json" "$PROVIDER" "$window") && parse_window_row "$row"; then
        baseline_note=$(printf '%s %s resets %s at %s%%' \
          "$W_PROVIDER" "$W_ID" "$W_RESETS" "$W_PERCENT")
      elif [ -n "$window" ]; then
        die "quota-axi reports no usable window $window for ${PROVIDER:-any provider}"
      fi
    fi
    "$SCRIPT_DIR/fm-procevent.sh" register quota "$CANONICAL_SOURCE_ID" \
      -- "$SCRIPT_DIR/fm-procevent-quota.sh" poll --refresh --interval "$interval" \
      --window "$window" --provider "$PROVIDER" --timeout "$timeout" || exit 1
    printf 'armed: %s\n' "$CANONICAL_SOURCE_ID"
    printf 'provider: %s\n' "${PROVIDER:-(any)}"
    printf 'window: %s\n' "${window:-(binding)}"
    printf 'interval: %ss\n' "$interval"
    printf 'baseline: %s\n' "$baseline_note"
    return 0
  fi

  "$SCRIPT_DIR/fm-procevent.sh" register quota "$CANONICAL_SOURCE_ID" \
    -- "$SCRIPT_DIR/fm-procevent-quota.sh" poll --interval "$interval" --threshold "$threshold" --provider "$PROVIDER" --timeout "$timeout" || exit 1
  printf 'armed: %s\n' "$CANONICAL_SOURCE_ID"
  printf 'provider: %s\n' "${PROVIDER:-(aggregate)}"
  printf 'threshold: %s%%\n' "$threshold"
  printf 'interval: %ss\n' "$interval"
}

emit_error() {
  local polls=$1 detail=$2
  printf 'quota: %s\n' "$CANONICAL_SOURCE_ID"
  printf 'status: error\n'
  printf 'detail: %s\n' "$detail"
  printf 'condition_polls: %s\n' "$polls"
  exit 0
}

# For use inside the runner: parse the spec argv and run one condition evaluation.
# This is intentionally not the public `arm` path; the runner calls this command
# directly, so the argv must match the registration.
cmd_poll() {
  local interval=$DEFAULT_INTERVAL threshold=$DEFAULT_THRESHOLD timeout='' window=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --refresh)   MODE=refresh; shift ;;
      --interval)  [ "$#" -ge 2 ] || die "--interval needs a positive number"; interval=$2; shift 2 ;;
      --threshold) [ "$#" -ge 2 ] || die "--threshold needs a percent 0-100"; threshold=$2; shift 2 ;;
      --window)    [ "$#" -ge 2 ] || die "--window needs a value"; window=$2; shift 2 ;;
      --provider)  [ "$#" -ge 2 ] || die "--provider needs a value"; PROVIDER=$2; shift 2 ;;
      --timeout)   [ "$#" -ge 2 ] || die "--timeout needs a positive integer"; timeout=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  positive_number "$interval" || die "--interval needs a positive number"
  [ -z "$timeout" ] || positive_int "$timeout" || die "--timeout needs a positive integer"
  if [ "$MODE" = refresh ]; then
    [ -z "$window" ] || valid_window_id "$window" || die "invalid window id: $window"
  else
    valid_percent "$threshold" || die "--threshold needs a percent 0-100"
  fi
  resolve_provider "$PROVIDER"
  if [ "$MODE" = refresh ]; then
    poll_refresh "$interval" "$window" "$timeout"
    return
  fi
  poll_low "$interval" "$threshold" "$timeout"
}

poll_low() {
  local interval=$1 threshold=$2 timeout=$3
  local json detail status polls=0
  while :; do
    polls=$((polls + 1))
    if ! json=$(quota_json "${timeout:-}"); then
      emit_error "$polls" 'quota-axi --json failed or quota-axi is missing/incompatible'
    fi
    status=$(condition_status "$json" "$PROVIDER" "$threshold")
    case "$status" in
      healthy) sleep "$interval"; continue ;;
      low|exhausted) : ;;
      *) status=error ;;
    esac
    detail=$(details "$json" "$PROVIDER")
    printf 'quota: %s\n' "$CANONICAL_SOURCE_ID"
    printf 'status: %s\n' "$status"
    printf 'detail: %s\n' "$detail"
    printf 'condition_polls: %s\n' "$polls"
    exit 0
  done
}

poll_refresh() {
  local interval=$1 window=$2 timeout=$3
  local json row polls=0 detail now
  while :; do
    polls=$((polls + 1))
    if ! json=$(quota_json "${timeout:-}"); then
      emit_error "$polls" 'quota-axi --json failed or quota-axi is missing/incompatible'
    fi
    if ! printf '%s\n' "$json" | fm_quota_json_valid; then
      emit_error "$polls" 'quota-axi --json returned a snapshot this adapter cannot read'
    fi
    if ! baseline_read "$CANONICAL_SOURCE_ID" \
       || { [ -n "$PROVIDER" ] && [ "$BL_PROVIDER" != "$PROVIDER" ]; } \
       || { [ -n "$window" ] && [ "$BL_WINDOW" != "$window" ]; }; then
      # No trustworthy "before" for this watch yet, so there is nothing a
      # refresh could be measured against. Pin one if the snapshot offers a
      # pinnable window and keep polling either way; this can never fire.
      establish_baseline "$json" "$PROVIDER" "$window" >/dev/null || :
      sleep "$interval"; continue
    fi
    # An absent, incomplete, or unreadable window is uncertainty, not a
    # turnover: leave the recorded boundary in place so the refresh is still
    # detected later.
    row=$(read_window "$json" "$BL_PROVIDER" "$BL_WINDOW")
    parse_window_row "$row" || { sleep "$interval"; continue; }
    now=$(snapshot_now "$json")
    # Three independent facts make a turnover, and every one of them is here
    # because a weaker test misfires. The recorded boundary must actually have
    # elapsed, which is what "the window reset" means; the window must report a
    # new instance - no boundary yet, a boundary already behind it, or one that
    # moved by more than quota-axi's own recomputation jitter, which crosses
    # whole seconds between consecutive calls; and headroom must be materially
    # back, which is what makes the wake worth acting on.
    if [ "$now" -lt "$BL_EPOCH" ] || ! num_ge "$W_PERCENT" "$REFRESH_RESTORE" \
       || { [ -n "$W_EPOCH" ] && [ "$W_EPOCH" -gt "$now" ] \
            && [ $((W_EPOCH - BL_EPOCH)) -lt "$REFRESH_MIN_ADVANCE" ]; }; then
      sleep "$interval"; continue
    fi
    detail=$(jq -nc \
      --arg provider "$W_PROVIDER" --arg window "$W_ID" \
      --arg prev_resets "$BL_RESETS" --arg resets "$W_RESETS" \
      --argjson prev_percent "$BL_PERCENT" --argjson percent "$W_PERCENT" '
      { provider: $provider,
        window: $window,
        previous: {resetsAt: $prev_resets, percentRemaining: $prev_percent},
        current: {resetsAt: (if $resets == "" then null else $resets end),
                  percentRemaining: $percent} }')
    printf 'quota: %s\n' "$CANONICAL_SOURCE_ID"
    printf 'status: refreshed\n'
    printf 'detail: %s\n' "$detail"
    printf 'condition_polls: %s\n' "$polls"
    exit 0
  done
}

cmd_classify() {
  local file=${1-} status
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  status=$(awk '
    $0 == "output:" { exit }
    /^status: / { sub(/^status: /, ""); print; exit }
  ' "$file")
  case "$status" in
    low|exhausted|refreshed|error) printf '%s\n' "$status" ;;
    *) printf 'unknown\n' ;;
  esac
}

cmd_terminal() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  [ "$(cmd_classify "$file")" != unknown ]
}

cmd_retire() {
  local id provider=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --refresh)  MODE=refresh; shift ;;
      --provider) [ -n "${2-}" ] || die "--provider needs a value"; provider=$2; shift 2 ;;
      -*) usage ;;
      *) [ -z "$provider" ] || usage; provider=$1; shift ;;
    esac
  done
  resolve_provider "$provider"
  id=$CANONICAL_SOURCE_ID
  [ "$MODE" != refresh ] || rm -f -- "$(baseline_file "$id")"
  "$SCRIPT_DIR/fm-procevent.sh" retire "$id"
}

case "${1-}" in
  arm)       shift; cmd_arm "$@" ;;
  poll)      shift; cmd_poll "$@" ;;
  classify)  shift; cmd_classify "$@" ;;
  terminal)  shift; cmd_terminal "$@" ;;
  source-id) shift; cmd_source_id "$@" ;;
  retire)    shift; cmd_retire "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
