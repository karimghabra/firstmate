#!/usr/bin/env bash
# Behavioral tests for bin/fm-procevent-quota.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
BIN="$FM_ROOT/bin"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-procevent-quota.XXXXXX")
FAKEBIN="$LAB/fakebin"
COUNT="$LAB/count"

cleanup() { rm -rf "$LAB"; }
trap cleanup EXIT
mkdir -p "$FAKEBIN"

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf 'quota-axi 0.1.29\n'
  exit 0
fi
case "${QUOTA_AXI_MALFORMED:-}" in
  schema)
    printf '{"schemaVersion":4,"providers":[]}\n'
    exit 0
    ;;
  duplicate)
    printf '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"unknown","effectiveAvailability":[]}},{"provider":"codex","quotaSemantics":{"status":"unknown","effectiveAvailability":[]}}]}\n'
    exit 0
    ;;
  types)
    printf '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":"0","runway":{"status":"through_reset"}}]}}]}\n'
    exit 0
    ;;
  range)
    printf '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":150,"runway":{"status":"through_reset"}}]}}]}\n'
    exit 0
    ;;
  runway)
    printf '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":50,"runway":{"status":"invalid"}}]}}]}\n'
    exit 0
    ;;
  availability)
    printf '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"typo","effectivePercentRemaining":0,"runway":{"status":"exhausted_now"}},{"scope":"model:codex_bengalfox","status":"known","effectivePercentRemaining":50,"runway":{"status":"through_reset"}}]}}]}\n'
    exit 0
    ;;
  known-empty)
    printf '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"known","effectiveAvailability":[]}}]}\n'
    exit 0
    ;;
  semantics-mismatch)
    printf '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"unknown","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":50,"runway":{"status":"through_reset"}}]}}]}\n'
    exit 0
    ;;
  identity)
    printf '{"schemaVersion":5,"providers":[{"provider":" codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now"}}]}}]}\n'
    exit 0
    ;;
esac
if [ "${QUOTA_AXI_EXHAUSTED_DETAIL:-0}" = 1 ]; then
  printf '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":10,"runway":{"status":"exhausted_now"}},{"scope":"model:foo","status":"known","effectivePercentRemaining":5,"runway":{"status":"through_reset"}}]}}]}\n'
  exit 0
fi
if [ "${QUOTA_AXI_UNKNOWN_EXHAUSTED:-0}" = 1 ]; then
  printf '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"unknown","runway":{"status":"exhausted_now"}}]}}]}\n'
  exit 0
fi
count=0
[ ! -f "$QUOTA_AXI_COUNT" ] || read -r count < "$QUOTA_AXI_COUNT"
count=$((count + 1))
printf '%s\n' "$count" > "$QUOTA_AXI_COUNT"
if [ -n "${QUOTA_AXI_SCRIPT:-}" ]; then
  line=$(sed -n "${count}p" "$QUOTA_AXI_SCRIPT")
  [ -n "$line" ] || line=$(tail -n 1 "$QUOTA_AXI_SCRIPT")
  printf '%s\n' "$line"
  exit 0
fi
if [ "${QUOTA_AXI_UNKNOWN_FIRST:-0}" = 1 ] && [ "$count" -eq 1 ]; then
  printf '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"unknown","effectiveAvailability":[]}}]}\n'
  exit 0
fi
if [ "${QUOTA_AXI_KNOWN_UNKNOWN_FIRST:-0}" = 1 ] && [ "$count" -eq 1 ]; then
  printf '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"unknown","runway":{"status":"unknown"}}]}}]}\n'
  exit 0
fi
if [ "${QUOTA_AXI_EMPTY_FIRST:-0}" = 1 ] && [ "$count" -eq 1 ]; then
  printf '{"schemaVersion":5,"providers":[]}\n'
  exit 0
fi
if [ "${QUOTA_AXI_AT_THRESHOLD:-0}" = 1 ]; then
  if [ "$count" -eq 1 ]; then
    remaining=10
  else
    remaining=9
  fi
  printf '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":%s,"runway":{"status":"through_reset"}}]}}]}\n' "$remaining"
  exit 0
fi
if [ "$count" -eq 1 ]; then
  model_remaining=20
  runway=through_reset
else
  model_remaining=0
  runway=exhausted_now
fi
printf '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":20,"runway":{"status":"through_reset"}},{"scope":"model:codex_bengalfox","status":"known","effectivePercentRemaining":%s,"runway":{"status":"%s"}}]}},{"provider":"claude","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":50,"runway":{"status":"through_reset"}}]}}]}\n' "$model_remaining" "$runway"
SH
chmod +x "$FAKEBIN/quota-axi"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
ok() { printf 'ok - %s\n' "$1"; }

if help=$("$BIN/fm-procevent-quota.sh" --help 2>&1); then
  fail "help unexpectedly exited zero"
fi
printf '%s\n' "$help" | grep -Fq 'fm-procevent-quota.sh retire [--refresh] [--provider <provider>]' \
  || fail "help omitted the retire usage"
if printf '%s\n' "$help" | grep -Fq 'set -u'; then
  fail "help leaked executable source"
fi
ok "help renders only the complete header"

out=$(QUOTA_AXI_EXHAUSTED_DETAIL=1 QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" \
  "$BIN/fm-procevent-quota.sh" poll)
printf '%s\n' "$out" | grep -qx 'status: exhausted' \
  || fail "default aggregate poll did not report exhaustion"
printf '%s\n' "$out" | grep -qx 'quota: quota' \
  || fail "default aggregate poll did not use the aggregate source"
ok "poll accepts its documented defaults"

out=$(QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-quota.sh" poll --interval 0.01 --threshold 10 --provider codex --timeout 1)
printf '%s\n' "$out" | grep -qx 'status: exhausted' || fail "provider watch did not report exhaustion"
printf '%s\n' "$out" | grep -qx 'condition_polls: 2' || fail "provider watch did not wait through the healthy poll"
ok "provider watch blocks until a model scope is exhausted"

out=$(QUOTA_AXI_EXHAUSTED_DETAIL=1 QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" \
  "$BIN/fm-procevent-quota.sh" poll --interval 1 --threshold 10 --provider codex --timeout 1)
detail=$(printf '%s\n' "$out" | sed -n 's/^detail: //p')
printf '%s\n' "$detail" | jq -e '
  .best.scope == "all_models" and
  .best.runway.status == "exhausted_now"
' >/dev/null || fail "exhausted poll recorded non-triggering detail: $detail"
ok "exhausted poll records the triggering scope"

out=$(QUOTA_AXI_UNKNOWN_EXHAUSTED=1 QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" \
  "$BIN/fm-procevent-quota.sh" poll --interval 1 --threshold 10 --provider codex --timeout 1)
printf '%s\n' "$out" | grep -qx 'status: exhausted' \
  || fail "unknown headroom with exhausted runway did not wake as exhausted"
ok "poll detects exhausted runway under unknown headroom"

rm -f "$COUNT"
out=$(QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-quota.sh" poll --interval 0.01 --threshold 10 --provider '' --timeout 1)
printf '%s\n' "$out" | grep -qx 'status: exhausted' || fail "aggregate watch did not report exhaustion"
printf '%s\n' "$out" | grep -qx 'condition_polls: 2' || fail "aggregate watch did not evaluate all providers"
ok "aggregate watch blocks until any scope is exhausted"

rm -f "$COUNT"
out=$(QUOTA_AXI_EMPTY_FIRST=1 QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-quota.sh" poll --interval 0.01 --threshold 10 --provider '' --timeout 1)
printf '%s\n' "$out" | grep -qx 'status: exhausted' || fail "empty aggregate quota did not continue polling"
printf '%s\n' "$out" | grep -qx 'condition_polls: 2' || fail "empty aggregate quota stopped early"
ok "aggregate watch preserves empty quota uncertainty"

if err=$(QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-quota.sh" arm --provider 2>&1); then
  fail "missing provider value unexpectedly armed a watch"
fi
[ "$err" = "error: --provider needs a value" ] || fail "missing provider value returned: $err"
ok "arm rejects a missing provider value"

for provider in -- codex-; do
  if err=$(QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-quota.sh" arm --provider "$provider" 2>&1); then
    fail "noncanonical provider unexpectedly armed a watch: $provider"
  fi
  [ "$err" = "error: invalid provider: $provider" ] || fail "noncanonical provider returned: $err"
done
ok "arm rejects noncanonical provider identities"

out=$(FM_HOME="$LAB/retire-home" FM_STATE_OVERRIDE="$LAB/retire-state" \
  "$BIN/fm-procevent-quota.sh" retire --provider codex)
[ "$out" = "retired: quota-codex" ] || fail "provider retire targeted the wrong source: $out"
ok "provider retire resolves the armed source id"

if err=$(QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-quota.sh" poll --interval 1 --threshold 100.5 --provider codex --timeout 1 2>&1); then
  fail "threshold above 100 unexpectedly started polling"
fi
[ "$err" = "error: --threshold needs a percent 0-100" ] || fail "invalid threshold returned: $err"
ok "poll rejects a decimal threshold above 100"

rm -f "$COUNT"
out=$(QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-quota.sh" poll --interval 0.01 --threshold 010 --provider codex --timeout 1)
printf '%s\n' "$out" | grep -qx 'status: exhausted' || fail "leading-zero threshold did not evaluate quota"
printf '%s\n' "$out" | grep -qx 'condition_polls: 2' || fail "leading-zero threshold stopped before exhaustion"
ok "poll accepts a leading-zero threshold"

rm -f "$COUNT"
out=$(QUOTA_AXI_AT_THRESHOLD=1 QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-quota.sh" poll --interval 0.01 --threshold 10 --provider codex --timeout 1)
printf '%s\n' "$out" | grep -qx 'status: low' || fail "quota below the threshold did not report low"
printf '%s\n' "$out" | grep -qx 'condition_polls: 2' || fail "quota at the threshold fired before dropping below it"
ok "poll fires only after quota drops below the threshold"

if err=$(QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-quota.sh" poll --provider 2>&1); then
  fail "missing poll provider value unexpectedly succeeded"
fi
[ "$err" = "error: --provider needs a value" ] || fail "missing poll provider returned: $err"
ok "poll rejects a missing option value"

rm -f "$COUNT"
out=$(FM_TIMEOUT_MECHANISM_OVERRIDE=bash QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-quota.sh" poll --interval 0.01 --threshold 10 --provider codex --timeout 1)
printf '%s\n' "$out" | grep -qx 'status: exhausted' || fail "bash timeout fallback did not poll quota"
printf '%s\n' "$out" | grep -qx 'condition_polls: 2' || fail "bash timeout fallback stopped before exhaustion"
ok "quota polling uses the shared bash timeout fallback"

for malformed in schema duplicate types range runway availability known-empty semantics-mismatch identity; do
  out=$(QUOTA_AXI_MALFORMED="$malformed" QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-quota.sh" poll --interval 1 --threshold 10 --provider codex --timeout 1)
  printf '%s\n' "$out" | grep -qx 'status: error' || fail "$malformed snapshot did not report an error"
  printf '%s\n' "$out" | grep -qx 'condition_polls: 1' || fail "$malformed snapshot did not stop immediately"
done
ok "poll rejects malformed schema-five snapshots"

rm -f "$COUNT"
out=$(QUOTA_AXI_UNKNOWN_FIRST=1 QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-quota.sh" poll --interval 0.01 --threshold 10 --provider codex --timeout 1)
printf '%s\n' "$out" | grep -qx 'status: exhausted' || fail "unknown quota did not continue to exhaustion"
printf '%s\n' "$out" | grep -qx 'condition_polls: 2' || fail "unknown quota stopped polling"
ok "poll preserves provider-level unknown quota"

rm -f "$COUNT"
out=$(QUOTA_AXI_KNOWN_UNKNOWN_FIRST=1 QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-quota.sh" poll --interval 0.01 --threshold 10 --provider codex --timeout 1)
printf '%s\n' "$out" | grep -qx 'status: exhausted' || fail "known semantics with unknown headroom did not continue polling"
printf '%s\n' "$out" | grep -qx 'condition_polls: 2' || fail "known semantics with unknown headroom stopped early"
ok "poll preserves unknown headroom under known semantics"


# --- refresh edge ------------------------------------------------------------
#
# Every refresh assertion below is written so the forbidden behavior is
# reachable: each "did not fire" case is followed by a real turnover in the same
# script, and the asserted condition_polls count is exactly the poll the real
# turnover lands on. A watch that fired on any earlier snapshot would report a
# smaller count and fail.

REFRESH_LAB="$LAB/refresh"
mkdir -p "$REFRESH_LAB"
# The refresh watch's durable baseline is persisted state this adapter owns.
BASELINE="$REFRESH_LAB/state/quota-refresh/quota-refresh-claude.baseline"

# claude_snap <generatedAt> <five_hour-resetsAt> <five_hour-%> [<seven_day-resetsAt> <seven_day-%>]
# One schema-five claude snapshot carrying quota-axi's own snapshot instant,
# which is what the elapsed-boundary test reads in preference to this host's
# clock. A resetsAt of `-` omits the field, which is how quota-axi reports a
# window that reset and has not been used since. effectiveAvailability is
# derived the way quota-axi derives it: the lowest windows are limiting, and a
# window at zero makes the runway exhausted_now.
claude_snap() {
  jq -nc --arg gen "$1" --arg r5 "$2" --argjson p5 "$3" \
    --arg r7 "${4:-2030-06-17T19:00:00Z}" --argjson p7 "${5:-90}" '
    def win($id; $r; $p):
      {id: $id, percentRemaining: $p} + (if $r == "-" then {} else {resetsAt: $r} end);
    [win("five_hour"; $r5; $p5), win("seven_day"; $r7; $p7)] as $w
    | ([$w[].percentRemaining] | min) as $min
    | {schemaVersion: 5, generatedAt: $gen,
       providers: [{provider: "claude", windows: $w,
         quotaSemantics: {status: "known", effectiveAvailability: [
           {scope: "all_models", status: "known", effectivePercentRemaining: $min,
            limitingWindowIds: [$w[] | select(.percentRemaining == $min) | .id],
            runway: (if $min == 0
                     then {status: "exhausted_now",
                           limitingWindowId: ([$w[] | select(.percentRemaining == 0) | .id] | first)}
                     else {status: "through_reset"} end)}]}}]}'
}

# claude_windows_snapshot <windows-json>
# A claude snapshot with a caller-supplied windows array and no generatedAt, for
# readings the adapter must treat as unknown rather than as a turnover.
claude_windows_snapshot() {
  printf '{"schemaVersion":5,"providers":[{"provider":"claude","windows":%s,"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":50,"runway":{"status":"through_reset"}}]}}]}\n' "$1"
}

# A refresh poll blocks until its condition fires, so every call here is
# bounded: a regression that stops firing must fail the test, never hang it.
if command -v timeout >/dev/null 2>&1; then
  bound() { timeout 60 "$@"; }
else
  bound() { "$@"; }
fi

refresh_poll() { # <script-file> [extra poll args...]
  local script=$1; shift
  rm -f "$COUNT"
  bound env FM_HOME="$REFRESH_LAB/home" FM_STATE_OVERRIDE="$REFRESH_LAB/state" \
    QUOTA_AXI_COUNT="$COUNT" QUOTA_AXI_SCRIPT="$script" PATH="$FAKEBIN:$PATH" \
    "$BIN/fm-procevent-quota.sh" poll --refresh --interval 0.01 --provider claude \
    --window '' --timeout 1 "$@"
}

refresh_arm() { # <script-file> [extra arm args...]
  local script=$1; shift
  rm -f "$COUNT"
  env FM_HOME="$REFRESH_LAB/home" FM_STATE_OVERRIDE="$REFRESH_LAB/state" \
    QUOTA_AXI_COUNT="$COUNT" QUOTA_AXI_SCRIPT="$script" PATH="$FAKEBIN:$PATH" \
    "$BIN/fm-procevent-quota.sh" arm --refresh --provider claude --interval 30 "$@"
}

refresh_state() { # <subcommand> [args...]
  env FM_HOME="$REFRESH_LAB/home" FM_STATE_OVERRIDE="$REFRESH_LAB/state" \
    "$BIN/fm-procevent-quota.sh" "$@"
}

reset_refresh_home() { rm -rf "${REFRESH_LAB:?}/home" "${REFRESH_LAB:?}/state"; }

detail_of() { printf '%s\n' "$1" | sed -n 's/^detail: //p'; }

printf '%s\n' "$help" | grep -Fq 'fm-procevent-quota.sh arm --refresh [--interval <secs>] [--provider <provider>] [--window <window-id>]' \
  || fail "help omitted the refresh arm usage"
ok "help documents the refresh watch"

claude_snap 2025-01-10T21:00:00Z 2025-01-10T21:50:00Z 4 > "$REFRESH_LAB/before"
claude_snap 2025-01-11T01:00:00Z 2025-01-11T02:50:00Z 80 > "$REFRESH_LAB/after"

# A boundary that actually turns over fires, on the binding window.
reset_refresh_home
{ claude_snap 2025-01-10T21:00:00Z 2025-01-10T21:50:00Z 4
  claude_snap 2025-01-10T21:51:00Z 2025-01-11T02:50:00Z 100
} > "$REFRESH_LAB/turnover"
out=$(refresh_poll "$REFRESH_LAB/turnover")
printf '%s\n' "$out" | grep -qx 'status: refreshed' || fail "a window turnover did not wake as refreshed"
printf '%s\n' "$out" | grep -qx 'quota: quota-refresh-claude' || fail "refresh watch used the wrong source id"
printf '%s\n' "$out" | grep -qx 'condition_polls: 2' || fail "refresh fired on the wrong poll"
detail=$(detail_of "$out")
printf '%s\n' "$detail" | jq -e '
  .provider == "claude" and
  .window == "five_hour" and
  .previous.resetsAt == "2025-01-10T21:50:00Z" and
  .previous.percentRemaining == 4 and
  .current.resetsAt == "2025-01-11T02:50:00Z" and
  .current.percentRemaining == 100
' >/dev/null || fail "refresh detail did not describe the turnover: $detail"
ok "refresh fires on a crossed reset boundary of the binding window"

# An idle fleet: the exhausted window resets and nothing uses it, so quota-axi
# reports it with no resetsAt at all. That is the turnover the watch exists for.
# Poll 2 carries the same resetless shape before the recorded boundary, so a
# watch that skipped the elapsed test would fire there instead.
reset_refresh_home
{ claude_snap 2025-01-10T21:00:00Z 2025-01-10T21:50:00Z 0
  claude_snap 2025-01-10T21:49:00Z - 100
  claude_snap 2025-01-10T21:51:00Z - 100
} > "$REFRESH_LAB/resetless"
out=$(refresh_poll "$REFRESH_LAB/resetless")
printf '%s\n' "$out" | grep -qx 'status: refreshed' || fail "a reset window with no new boundary did not wake"
printf '%s\n' "$out" | grep -qx 'condition_polls: 3' \
  || fail "a resetless reading fired before the recorded boundary elapsed"
detail=$(detail_of "$out")
printf '%s\n' "$detail" | jq -e '
  .window == "five_hour" and .current.resetsAt == null and .current.percentRemaining == 100
' >/dev/null || fail "resetless refresh detail was wrong: $detail"
claude_snap 2025-01-10T21:52:00Z - 100 > "$REFRESH_LAB/resetless-relaunch"
out=$(refresh_poll "$REFRESH_LAB/resetless-relaunch")
printf '%s\n' "$out" | grep -qx 'condition_polls: 1' \
  || fail "a relaunched poll swallowed a resetless refresh whose capture was lost"
ok "refresh fires when the binding window resets with no new boundary yet"

# The binding window is the one whose exhaustion stops dispatch, not the one
# that resets soonest. five_hour turns over at poll 2 with full headroom, but
# seven_day is exhausted, so nothing can resume until seven_day turns over.
reset_refresh_home
{ claude_snap 2025-01-10T21:00:00Z 2025-01-10T21:50:00Z 70 2025-01-13T19:00:00Z 0
  claude_snap 2025-01-10T21:51:00Z 2025-01-11T02:50:00Z 100 2025-01-13T19:00:00Z 0
  claude_snap 2025-01-13T19:01:00Z 2025-01-14T00:00:00Z 100 2025-01-20T19:00:00Z 100
} > "$REFRESH_LAB/binding"
out=$(refresh_poll "$REFRESH_LAB/binding")
printf '%s\n' "$out" | grep -qx 'status: refreshed' || fail "binding script never reached its turnover"
printf '%s\n' "$out" | grep -qx 'condition_polls: 3' \
  || fail "a sooner non-binding window turnover fired the refresh watch"
detail=$(detail_of "$out")
printf '%s\n' "$detail" | jq -e '.window == "seven_day"' >/dev/null \
  || fail "the refresh watch did not report the binding window: $detail"
# When several windows are exhausted together, headroom returns only once the
# last of them turns over, so that is the one pinned.
reset_refresh_home
claude_snap 2025-01-10T21:00:00Z 2025-01-10T21:50:00Z 0 2025-01-13T19:00:00Z 0 > "$REFRESH_LAB/both"
refresh_arm "$REFRESH_LAB/both" >/dev/null || fail "arming with two exhausted windows failed"
grep -qx 'window: seven_day' "$BASELINE" \
  || fail "tied binding windows did not pin the one resetting last"
ok "refresh tracks the binding window rather than the soonest reset"

# Headroom rising steeply inside the SAME window is not a refresh. Poll 2 alone
# would fire a watch that only compared percentages.
reset_refresh_home
{ claude_snap 2025-01-10T21:00:00Z 2025-01-10T21:50:00Z 4
  claude_snap 2025-01-10T21:10:00Z 2025-01-10T21:50:00Z 95
  claude_snap 2025-01-10T21:20:00Z 2025-01-10T21:50:00Z 99
  claude_snap 2025-01-10T21:51:00Z 2025-01-11T02:50:00Z 100
} > "$REFRESH_LAB/fluctuation"
out=$(refresh_poll "$REFRESH_LAB/fluctuation")
printf '%s\n' "$out" | grep -qx 'status: refreshed' || fail "fluctuation script never reached its turnover"
printf '%s\n' "$out" | grep -qx 'condition_polls: 4' \
  || fail "a fluctuation inside the recorded window fired the refresh watch"
ok "refresh ignores headroom fluctuation inside the recorded window"

# A boundary crossed while nothing was polling is still detected, because the
# recorded baseline is durable rather than re-established per poll.
reset_refresh_home
refresh_arm "$REFRESH_LAB/before" >/dev/null || fail "arming the refresh watch failed"
grep -qx 'window: five_hour' "$BASELINE" || fail "arm did not record the window baseline"
out=$(refresh_poll "$REFRESH_LAB/after")
printf '%s\n' "$out" | grep -qx 'status: refreshed' \
  || fail "a boundary crossed while nothing polled was not detected"
printf '%s\n' "$out" | grep -qx 'condition_polls: 1' \
  || fail "the missed turnover was not detected on the very first poll"
ok "refresh detects a boundary crossed while nothing was polling"

# Unknown and unreadable readings never fire. Polls 2 and 3 both carry full
# headroom after the recorded boundary, so a watch that skipped either
# validation would fire before poll 4.
reset_refresh_home
refresh_arm "$REFRESH_LAB/before" >/dev/null || fail "arming for the unknown-reading case failed"
{ claude_windows_snapshot '[]'
  claude_windows_snapshot '[{"id":"five_hour","resetsAt":"whenever","percentRemaining":100}]'
  claude_windows_snapshot '[{"id":"five_hour","resetsAt":"2025-01-11T02:50:00Z","percentRemaining":"100"}]'
  claude_snap 2025-01-10T21:51:00Z 2025-01-11T02:50:00Z 100
} > "$REFRESH_LAB/unknown"
out=$(refresh_poll "$REFRESH_LAB/unknown")
printf '%s\n' "$out" | grep -qx 'status: refreshed' || fail "unknown-reading script never reached its turnover"
printf '%s\n' "$out" | grep -qx 'condition_polls: 4' \
  || fail "an unknown or unreadable window reading fired a false refresh"
ok "refresh never fires on an unknown or unreadable window reading"

# Prove each unknown reading above is genuinely rejected on its own, not just
# outrun by the poll order.
reset_refresh_home
for unreadable in \
  '[]' \
  '[{"id":"five_hour","resetsAt":"whenever","percentRemaining":100}]' \
  '[{"id":"five_hour","resetsAt":"2025-01-11T02:50:00Z","percentRemaining":"100"}]' \
  '[{"id":"five_hour","resetsAt":"2025-01-11T02:50:00Z"}]' \
  '[{"id":"five_hour","percentRemaining":null}]' \
  '[{"id":"seven_day","resetsAt":"2025-01-11T02:50:00Z","percentRemaining":100}]'
do
  refresh_arm "$REFRESH_LAB/before" >/dev/null || fail "re-arming for $unreadable failed"
  { claude_windows_snapshot "$unreadable"
    claude_snap 2025-01-10T21:51:00Z 2025-01-11T02:50:00Z 100
  } > "$REFRESH_LAB/single-unknown"
  out=$(refresh_poll "$REFRESH_LAB/single-unknown")
  printf '%s\n' "$out" | grep -qx 'condition_polls: 2' \
    || fail "this reading fired a false refresh: $unreadable"
done
ok "each unreadable window shape is rejected individually"

# A boundary that advanced without materially restoring headroom keeps waiting,
# and the recorded boundary stays put so the restored reading still fires.
reset_refresh_home
{ claude_snap 2025-01-10T21:00:00Z 2025-01-10T21:50:00Z 4
  claude_snap 2025-01-10T21:51:00Z 2025-01-11T02:50:00Z 5
  claude_snap 2025-01-10T21:52:00Z 2025-01-11T02:50:00Z 60
} > "$REFRESH_LAB/starved"
out=$(refresh_poll "$REFRESH_LAB/starved")
printf '%s\n' "$out" | grep -qx 'status: refreshed' || fail "starved script never reached restored headroom"
printf '%s\n' "$out" | grep -qx 'condition_polls: 3' \
  || fail "refresh fired before headroom was materially restored"
ok "refresh waits for materially restored headroom, then still fires"

# quota-axi recomputes resetsAt on every call, and the observed jitter crosses
# whole seconds. Here the recorded boundary was a jittered-early reading, so
# poll 2 is past it by the snapshot clock while the window it reports still
# lies one second ahead. Only the advance floor tells that apart from a real
# turnover; a bare strictly-later comparison fires on poll 2.
reset_refresh_home
{ claude_snap 2025-01-10T21:00:00Z 2025-01-10T21:49:59Z 37
  claude_snap 2025-01-10T21:49:59.500Z 2025-01-10T21:50:00Z 36
  claude_snap 2025-01-10T21:51:00Z - 100
} > "$REFRESH_LAB/jitter"
out=$(refresh_poll "$REFRESH_LAB/jitter")
printf '%s\n' "$out" | grep -qx 'status: refreshed' || fail "jitter script never reached its turnover"
printf '%s\n' "$out" | grep -qx 'condition_polls: 3' \
  || fail "sub-second resetsAt jitter fired the refresh watch"
ok "refresh ignores quota-axi's own resetsAt recomputation jitter"

# A boundary that has not elapsed yet is not a turnover, however far ahead the
# newly reported one sits.
reset_refresh_home
{ claude_snap 2025-01-10T18:00:00Z 2025-01-10T21:50:00Z 4
  claude_snap 2025-01-10T19:00:00Z 2025-01-11T02:50:00Z 100
  claude_snap 2025-01-10T21:51:00Z 2025-01-11T02:50:00Z 100
} > "$REFRESH_LAB/notyet"
out=$(refresh_poll "$REFRESH_LAB/notyet")
printf '%s\n' "$out" | grep -qx 'status: refreshed' || fail "not-yet script never reached its turnover"
printf '%s\n' "$out" | grep -qx 'condition_polls: 3' \
  || fail "refresh fired before the recorded boundary had elapsed"
ok "refresh waits for the recorded boundary to actually elapse"

# The runner captures a fired outcome only after the poll exits, so firing must
# leave the recorded boundary in place: a poll relaunched after a lost capture
# reports the same turnover again on its first poll instead of waiting for the
# next one.
reset_refresh_home
out=$(refresh_poll "$REFRESH_LAB/turnover")
printf '%s\n' "$out" | grep -qx 'condition_polls: 2' || fail "relaunch setup did not fire as expected"
{ claude_snap 2025-01-10T22:00:00Z 2025-01-11T02:50:00Z 100
  claude_snap 2025-01-11T02:51:00Z 2025-01-11T07:50:00Z 100
} > "$REFRESH_LAB/relaunch"
out=$(refresh_poll "$REFRESH_LAB/relaunch")
printf '%s\n' "$out" | grep -qx 'status: refreshed' || fail "relaunch script never fired"
printf '%s\n' "$out" | grep -qx 'condition_polls: 1' \
  || fail "a relaunched poll swallowed a refresh whose capture was lost"
detail=$(detail_of "$out")
printf '%s\n' "$detail" | jq -e '
  .previous.resetsAt == "2025-01-10T21:50:00Z" and
  .current.resetsAt == "2025-01-11T02:50:00Z"
' >/dev/null || fail "the relaunched wake reported the wrong turnover: $detail"
ok "a relaunched refresh poll repeats an uncaptured wake rather than losing it"

# A baseline left behind by an earlier watch never stands in for the window this
# watch asked for. The five_hour baseline from the turnover above would fire on
# poll 1; the requested seven_day window only turns over on poll 3.
{ claude_snap 2025-01-11T03:00:00Z 2025-01-11T07:50:00Z 100 2025-01-13T19:00:00Z 40
  claude_snap 2025-01-11T07:51:00Z 2025-01-11T12:50:00Z 100 2025-01-13T19:00:00Z 40
  claude_snap 2025-01-13T19:01:00Z 2025-01-14T00:00:00Z 100 2025-01-20T19:00:00Z 100
} > "$REFRESH_LAB/stale"
out=$(refresh_poll "$REFRESH_LAB/stale" --window seven_day)
printf '%s\n' "$out" | grep -qx 'condition_polls: 3' \
  || fail "a stale baseline for another window drove the refresh watch"
detail=$(detail_of "$out")
printf '%s\n' "$detail" | jq -e '.window == "seven_day"' >/dev/null \
  || fail "the refresh watch did not watch the requested window: $detail"
# Arming starts a fresh baseline even when quota-axi cannot be read at arm time,
# so the first poll pins the window this watch asks for instead of reusing one.
[ -f "$BASELINE" ] || fail "stale-baseline setup left no baseline to discard"
printf 'not json\n' > "$REFRESH_LAB/garbage"
out=$(refresh_arm "$REFRESH_LAB/garbage") || fail "arming with an unreadable snapshot failed"
printf '%s\n' "$out" | grep -qx 'baseline: deferred to the first poll' \
  || fail "arm did not report the deferred baseline: $out"
[ ! -e "$BASELINE" ] || fail "a deferred arm kept an earlier watch's baseline"
ok "a baseline from another watch is never reused"

# A snapshot this adapter cannot read is an error outcome, not a refresh.
reset_refresh_home
rm -f "$COUNT"
out=$(env FM_HOME="$REFRESH_LAB/home" FM_STATE_OVERRIDE="$REFRESH_LAB/state" \
  QUOTA_AXI_MALFORMED=schema QUOTA_AXI_COUNT="$COUNT" PATH="$FAKEBIN:$PATH" \
  "$BIN/fm-procevent-quota.sh" poll --refresh --interval 1 --provider claude --window '' --timeout 1)
printf '%s\n' "$out" | grep -qx 'status: error' || fail "a malformed snapshot did not report an error"
printf '%s\n' "$out" | grep -qx 'condition_polls: 1' || fail "a malformed snapshot did not stop immediately"
ok "refresh reports an unreadable snapshot as an error rather than a refresh"

# Arm and retire are both idempotent, and retire discards the baseline so the
# next arm measures from a fresh window rather than replaying the old one.
reset_refresh_home
refresh_arm "$REFRESH_LAB/before" >/dev/null || fail "first refresh arm failed"
refresh_arm "$REFRESH_LAB/before" >/dev/null || fail "second refresh arm failed"
[ -f "$BASELINE" ] || fail "re-arming lost the baseline"
out=$(refresh_state retire --refresh --provider claude)
[ "$out" = "retired: quota-refresh-claude" ] || fail "first refresh retire reported: $out"
out=$(refresh_state retire --refresh --provider claude)
[ "$out" = "retired: quota-refresh-claude" ] || fail "second refresh retire reported: $out"
[ ! -e "$BASELINE" ] || fail "retire left the baseline behind"
refresh_arm "$REFRESH_LAB/after" >/dev/null || fail "re-arming after retire failed"
grep -qx 'resets_at: 2025-01-11T02:50:00Z' "$BASELINE" \
  || fail "re-arming after retire did not re-establish the baseline"
ok "refresh arm and retire are idempotent"

# The two edges are separate sources, so both can watch one provider at once.
[ "$("$BIN/fm-procevent-quota.sh" source-id --refresh --provider claude)" = quota-refresh-claude ] \
  || fail "refresh source id is not provider-scoped"
[ "$("$BIN/fm-procevent-quota.sh" source-id --refresh)" = quota-refresh ] \
  || fail "aggregate refresh source id is wrong"
[ "$("$BIN/fm-procevent-quota.sh" source-id --provider claude)" = quota-claude ] \
  || fail "falling-edge source id changed"
ok "each quota edge owns its own canonical source id"

# Flags belong to exactly one edge, and an explicit window the data does not
# describe is refused instead of silently watching another one.
if err=$(refresh_arm "$REFRESH_LAB/before" --threshold 10 2>&1); then
  fail "--threshold was accepted alongside --refresh"
fi
printf '%s\n' "$err" | grep -Fq 'error: --threshold belongs to the falling-edge watch' \
  || fail "--threshold with --refresh returned: $err"
rm -f "$COUNT"
if err=$(env FM_HOME="$REFRESH_LAB/home" FM_STATE_OVERRIDE="$REFRESH_LAB/state" \
  QUOTA_AXI_COUNT="$COUNT" QUOTA_AXI_SCRIPT="$REFRESH_LAB/before" PATH="$FAKEBIN:$PATH" \
  "$BIN/fm-procevent-quota.sh" arm --provider claude --window five_hour 2>&1); then
  fail "--window was accepted without --refresh"
fi
[ "$err" = "error: --window needs --refresh" ] || fail "--window without --refresh returned: $err"
if err=$(refresh_arm "$REFRESH_LAB/before" --window ninety_day 2>&1); then
  fail "an unknown explicit window unexpectedly armed a watch"
fi
printf '%s\n' "$err" | grep -Fq 'no usable window ninety_day' \
  || fail "unknown explicit window returned: $err"
ok "refresh flags are edge-scoped and an unknown window is refused"

# A refreshed outcome classifies and ends the source like every other one.
printf 'quota: quota-refresh-claude\nstatus: refreshed\ndetail: {}\ncondition_polls: 2\n' > "$REFRESH_LAB/result"
[ "$("$BIN/fm-procevent-quota.sh" classify "$REFRESH_LAB/result")" = refreshed ] \
  || fail "classify did not report a refreshed outcome"
"$BIN/fm-procevent-quota.sh" terminal "$REFRESH_LAB/result" \
  || fail "a refreshed outcome was not terminal"
printf 'quota: quota-refresh-claude\nstatus: dozing\n' > "$REFRESH_LAB/bogus"
[ "$("$BIN/fm-procevent-quota.sh" classify "$REFRESH_LAB/bogus")" = unknown ] \
  || fail "classify accepted an unrecognized status"
ok "classify and terminal cover the refreshed outcome"

printf '# all fm-procevent-quota tests passed\n'
