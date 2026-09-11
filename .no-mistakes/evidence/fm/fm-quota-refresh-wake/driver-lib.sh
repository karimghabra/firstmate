# Shared helpers for the quota refresh e2e drive.
WT=/home/mars/.no-mistakes/worktrees/a8c0c72d0935/01M278DMHRZ56PHZN98T8TQ83P
BIN=$WT/bin
LAB=${LAB:?}
FAKEBIN=$LAB/fakebin
export FM_HOME=$LAB/home
export FM_PROCEVENT_CLAIM_ROOT=$LAB/claims
export QA_CURRENT=$LAB/current.json
export QA_CALLS=$LAB/calls
mkdir -p "$FAKEBIN" "$FM_HOME/state" "$FM_PROCEVENT_CLAIM_ROOT"; chmod 700 "$LAB" "$FM_HOME" "$FM_HOME/state" "$FM_PROCEVENT_CLAIM_ROOT"
cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
# Scripted quota-axi: reports whatever snapshot the driver last wrote.
if [ "${1:-}" = --version ]; then echo "quota-axi 0.1.41"; exit 0; fi
echo "$(date +%T.%N) $*" >> "$QA_CALLS"
cat "$QA_CURRENT"
SH
chmod +x "$FAKEBIN/quota-axi"
export PATH=$FAKEBIN:$PATH

# snap <generatedAt> <five_hour-resetsAt|-> <five_hour-%> <seven_day-resetsAt|-> <seven_day-%>
snap() {
  jq -nc --arg gen "$1" --arg r5 "$2" --argjson p5 "$3" --arg r7 "$4" --argjson p7 "$5" '
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
                     else {status: "through_reset"} end)}]}}]}' > "$QA_CURRENT.tmp"
  mv "$QA_CURRENT.tmp" "$QA_CURRENT"
}
wakes() { cat "$FM_HOME/state/.wake-queue" 2>/dev/null; }
wait_wake() { local n=0; while [ ! -s "$FM_HOME/state/.wake-queue" ] && [ $n -lt ${1:-100} ]; do sleep 0.1; n=$((n+1)); done; [ -s "$FM_HOME/state/.wake-queue" ]; }
