#!/usr/bin/env bash
# fm-sitrep.sh - colour-coded, at-a-glance situation report for one firstmate home.
#
# A read-only terminal renderer. It does not parse fleet state files itself: it
# renders bin/fm-fleet-snapshot.sh --json (the canonical fleet state, including
# each task's current state from bin/fm-crew-state.sh, its stand-down record,
# recorded PR, and the backlog's captain holds), and adds only what that
# snapshot does not carry: the resident memory and CPU of every live worker's
# process tree and the machine's free memory and load. It takes no lock, drains
# nothing, writes nothing under the home, and makes no network call of its own;
# the snapshot it renders is bounded and its only side effect is the snapshot's
# own observational remote-summary cache refresh.
#
# Sections, in order:
#   1. one-line verdict for the whole fleet;
#   2. projects at a glance - one row per registered project (data/projects.md,
#      line format owned by bin/fm-project-mode.sh) plus any project with open
#      work, with a status word, running / parked / held counts, and the single
#      most important next thing;
#   3. decisions needed - every open item held for the captain, oldest first,
#      with its question and any PR URL in full;
#   4. workers running - every live worker with what it is doing, how long it
#      has run, its recorded model, and the summed resident memory (RSS) and CPU
#      of its whole process tree, then a total and the machine's memory and load;
#   5. parked work (stopped on purpose) and recently finished work.
#
# Status words and colours (the words carry the meaning without colour):
#   BLOCKED  red     failed, stuck, or a worker that stopped responding
#   WAITING  yellow  waiting on a decision, a review, or a merge
#   MOVING   green   work under way with nothing needed
#   PAUSED   grey    open work that is parked on purpose, deferred, or queued
#   IDLE     grey    nothing open
# A project takes the most urgent status among its items.
#
# Worker memory: the root pid of each live worker's recorded endpoint comes
# from fm_backend_endpoint_pid in bin/fm-backend.sh (tmux pane_pid, Herdr pane
# process-info). One `ps -axo pid=,ppid=,rss=,pcpu=` read supplies the process
# table, and RSS and CPU are summed over the root and all of its descendants.
# Backends without a verified pid source, remote workers, and endpoints that
# cannot be read show memory as not measured rather than a guess.
#
# Machine thresholds: available memory below 20% of total or below 2 GiB is
# yellow, below 10% or below 1 GiB is red. A one-minute load average above
# 75% of the online core count is yellow, above the core count red.
#
# Colour: ANSI colour only when stdout is a terminal, NO_COLOR is unset or
# empty, and --no-color was not given. --color forces colour on.
#
# Flags:
#   (default)    the human report
#   --json       the same model as JSON (schema fm-sitrep.v1), no colour
#   --no-color   never colour
#   --color      always colour
#   -h, --help   usage
#
# Environment (tests and unusual hosts):
#   FM_HOME                the home to report on (as every bin script)
#   FM_SITREP_PS_BIN       ps-compatible binary for the process table (default ps)
#   FM_SITREP_MEMINFO      meminfo-format file (default /proc/meminfo)
#   FM_SITREP_LOADAVG      loadavg-format file (default /proc/loadavg)
#   FM_SITREP_CORES        online core count override
#   FM_SITREP_NOW_EPOCH    clock override for ages and run times
#   FM_SITREP_WIDTH        line width override (default: terminal width, else 100)
#   FM_SITREP_FINISHED     how many recently finished items to show (default 5)
#   FM_SITREP_OVERDUE_DAYS days a held item may wait before it shows as overdue
#                          (default 3)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
export FM_HOME
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() {
  cat <<'EOF'
usage: fm-sitrep.sh [--json] [--no-color | --color]

Colour-coded situation report for the active firstmate home: an overall
verdict, every project at a glance, decisions waiting on you, running workers
with their memory and CPU use, and parked and recently finished work.

  --json       print the report model as JSON (schema fm-sitrep.v1)
  --no-color   never use colour (NO_COLOR is honoured too)
  --color      always use colour
  -h, --help   this help

Status words: BLOCKED (red) failed, stuck or not responding; WAITING (yellow)
needs a decision, review or merge; MOVING (green) under way, nothing needed;
PAUSED (grey) parked on purpose, deferred or queued; IDLE (grey) nothing open.
Read-only: no locks, no writes, no network calls of its own.
EOF
}

JSON=0
COLOR=auto
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) JSON=1 ;;
    --no-color|--no-colour) COLOR=never ;;
    --color|--colour) COLOR=always ;;
    -h|--help) usage; exit 0 ;;
    *) echo "fm-sitrep: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || { echo "fm-sitrep: jq not found" >&2; exit 1; }

if [ "$COLOR" = auto ]; then
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then COLOR=always; else COLOR=never; fi
fi
[ "$JSON" -eq 0 ] || COLOR=never

NOW_EPOCH=${FM_SITREP_NOW_EPOCH:-$(date +%s)}
case "$NOW_EPOCH" in ''|*[!0-9]*) NOW_EPOCH=$(date +%s) ;; esac
FINISHED_N=${FM_SITREP_FINISHED:-5}
OVERDUE_DAYS=${FM_SITREP_OVERDUE_DAYS:-3}
case "$OVERDUE_DAYS" in ''|*[!0-9]*) OVERDUE_DAYS=3 ;; esac
case "$FINISHED_N" in ''|*[!0-9]*) FINISHED_N=5 ;; esac
WIDTH=${FM_SITREP_WIDTH:-}
if [ -z "$WIDTH" ] && [ -t 1 ]; then
  WIDTH=$(tput cols 2>/dev/null || true)
fi
case "$WIDTH" in ''|*[!0-9]*) WIDTH=100 ;; esac
[ "$WIDTH" -ge 60 ] || WIDTH=60

SNAPSHOT=$("$SCRIPT_DIR/fm-fleet-snapshot.sh" --json) || {
  echo "fm-sitrep: the fleet snapshot could not be read" >&2
  exit 1
}

# Registered project names, in registry order.
registered_projects_json() {
  local reg="$DATA/projects.md"
  [ -f "$reg" ] || { printf '[]'; return 0; }
  awk '$1 == "-" && $2 != "" { print $2 }' "$reg" | jq -R -s '[splits("\n") | select(length > 0)]'
}
REGISTERED=$(registered_projects_json)

# --- worker process trees ----------------------------------------------------
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

ROOTS_TSV=""
while IFS=$'\t' read -r id backend target; do
  [ -n "$id" ] || continue
  pid=$(fm_backend_endpoint_pid "$backend" "$target" 2>/dev/null | head -n 1) || pid=""
  case "$pid" in ''|*[!0-9]*) pid="" ;; esac
  ROOTS_TSV="$ROOTS_TSV$id	$pid
"
done < <(printf '%s' "$SNAPSHOT" | jq -r '
  .tasks[]
  | select(.remote == null and .endpoint.exists == true and .current_state.source != "stood-down"
           and (.endpoint.target // "") != "")
  | [.id, .backend, .endpoint.target] | @tsv')

PS_BIN=${FM_SITREP_PS_BIN:-ps}
PS_TABLE=$(LC_ALL=C "$PS_BIN" -axo pid=,ppid=,rss=,pcpu= 2>/dev/null) || PS_TABLE=""

# One line per worker: id, root pid, process count, rss kB, cpu percent.
# A root pid absent from the table yields a zero process count.
TREES_JSON=$(
  {
    printf '%s' "$ROOTS_TSV" | sed 's/^/R\t/'
    printf '%s\n' "$PS_TABLE" | sed 's/^/P\t/'
  } | awk -F'\t' '
    $1 == "R" { ids[++n] = $2; root[$2] = $3; next }
    $1 == "P" {
      split($2, f, " ")
      if (f[1] !~ /^[0-9]+$/) next
      pid = f[1]; ppid[pid] = f[2]; rss[pid] = f[3] + 0; cpu[pid] = f[4] + 0
      kids[f[2]] = kids[f[2]] " " pid
      next
    }
    END {
      for (i = 1; i <= n; i++) {
        id = ids[i]; r = root[id]
        procs = 0; tr = 0; tc = 0
        if (r != "" && (r in rss)) {
          top = 1; stack[1] = r; delete seen
          while (top > 0) {
            p = stack[top--]
            if (p in seen) continue
            seen[p] = 1; procs++; tr += rss[p]; tc += cpu[p]
            m = split(kids[p], c, " ")
            for (j = 1; j <= m; j++) if (c[j] != "") stack[++top] = c[j]
          }
        }
        printf "%s\t%s\t%d\t%d\t%.1f\n", id, r, procs, tr, tc
      }
    }' | jq -R -s '
      [splits("\n") | select(length > 0) | split("\t")
       | {key: .[0],
          value: {root_pid: (if .[1] == "" then null else (.[1] | tonumber) end),
                  processes: (.[2] | tonumber),
                  rss_kb: (.[3] | tonumber),
                  cpu_percent: (.[4] | tonumber)}}]
      | from_entries'
)

# --- machine -----------------------------------------------------------------
MEMINFO=${FM_SITREP_MEMINFO:-/proc/meminfo}
LOADAVG=${FM_SITREP_LOADAVG:-/proc/loadavg}
MEM_TOTAL_KB=""
MEM_AVAIL_KB=""
if [ -r "$MEMINFO" ]; then
  MEM_TOTAL_KB=$(awk '$1 == "MemTotal:" { print $2; exit }' "$MEMINFO")
  MEM_AVAIL_KB=$(awk '$1 == "MemAvailable:" { print $2; exit }' "$MEMINFO")
elif command -v sysctl >/dev/null 2>&1 && command -v vm_stat >/dev/null 2>&1; then
  bytes=$(sysctl -n hw.memsize 2>/dev/null || true)
  case "$bytes" in ''|*[!0-9]*) ;; *) MEM_TOTAL_KB=$((bytes / 1024)) ;; esac
  MEM_AVAIL_KB=$(vm_stat 2>/dev/null | awk '
    /page size of/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) ps = $i }
    /^Pages (free|inactive|speculative|purgeable):/ { gsub(/\./, "", $NF); pages += $NF }
    END { if (ps > 0) printf "%d", pages * ps / 1024 }')
fi
case "$MEM_TOTAL_KB" in ''|*[!0-9]*) MEM_TOTAL_KB="" ;; esac
case "$MEM_AVAIL_KB" in ''|*[!0-9]*) MEM_AVAIL_KB="" ;; esac
LOAD1=""
if [ -r "$LOADAVG" ]; then
  LOAD1=$(awk '{ print $1; exit }' "$LOADAVG")
elif command -v sysctl >/dev/null 2>&1; then
  LOAD1=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{ print $1 }')
fi
case "$LOAD1" in ''|*[!0-9.]*) LOAD1="" ;; esac
CORES=${FM_SITREP_CORES:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)}
case "$CORES" in ''|*[!0-9]*|0) CORES="" ;; esac

# --- model -------------------------------------------------------------------
MODEL=$(printf '%s' "$SNAPSHOT" | jq \
  --argjson registered "$REGISTERED" \
  --argjson trees "$TREES_JSON" \
  --argjson now "$NOW_EPOCH" \
  --argjson finished_n "$FINISHED_N" \
  --argjson overdue_days "$OVERDUE_DAYS" \
  --arg mem_total "$MEM_TOTAL_KB" \
  --arg mem_avail "$MEM_AVAIL_KB" \
  --arg load1 "$LOAD1" \
  --arg cores "$CORES" '
  def num($s): if $s == "" then null else ($s | tonumber) end;
  def lc: ascii_downcase;
  def rank: {red: 0, yellow: 1, green: 2, dim: 3}[.] // 3;
  def epoch_of($ts):
    if $ts == null or $ts == "" then null
    else ($ts | tostring
          | if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") then . + "T00:00:00Z" else . end
          | try fromdateiso8601 catch null) end;
  def spawn_epoch($gen):
    if ($gen // "") | test("^s[0-9]+\\.") then ($gen | capture("^s(?<e>[0-9]+)\\.").e | tonumber) else null end;
  def project_of($t; $r):
    (($r.repo // null) // (if ($t.project // "") != "" then ($t.project | split("/") | last) else null end)
     // "(no project)");
  def strip_prefix($p):
    (. // "") as $s
    | ($p | lc) as $lp
    | if ($s | lc | startswith($lp + ": ")) then $s[($lp | length) + 2:] else $s end;
  def crew_phrase($t):
    ($t.current_state.state // "unknown") as $st
    | ($t.current_state.source // "none") as $src
    | ($t.current_state.detail // "") as $d
    | if $st == "working" and $src == "run-step" then
        "checking the change (review, tests, CI)"
        + (if ($d | test("waiting on [0-9]+ of [0-9]+ checks")) then
             " - " + ($d | capture("(?<w>waiting on [0-9]+ of [0-9]+ checks)").w) else "" end)
      elif $st == "working" then "working on it"
      elif $st == "parked" then "paused at a review question"
      elif $st == "done" then (if $t.pr.url != null then "finished, pull request open" else "finished" end)
      elif $st == "blocked" then "stuck and asking for help"
      elif $st == "failed" then "failed"
      elif $st == "paused" then "waiting on an outside delay"
      else "state could not be read" end;
  def stood_down_reason($t):
    ($t.current_state.detail // "")
    | (capture("^stopped by intent since (?<since>[0-9]{4}-[0-9]{2}-[0-9]{2}( [0-9:]+Z)?): (?<reason>.*)$") // {since: null, reason: .});

  (.tasks // []) as $tasks
  | ([.backlog.records[]? | select(.structured and (.state == "in_flight" or .state == "queued"))]) as $open
  | (.main_inventory.orphan_in_flight // [] | map(if type == "object" then .id else . end)) as $orphans
  | ([ $open[] as $r
       | ([$tasks[] | select(.id == $r.id)] | first) as $t
       | {r: $r, t: $t} ]
     + [ $tasks[] | . as $t
         | select(([$open[] | select(.id == $t.id)] | length) == 0)
         | select(.kind != "secondmate")
         | select(.current_state.state != "done" or .pr.url != null)
         | {r: (.backlog // null), t: $t} ]) as $pairs
  | ([ $pairs[] | .r as $r | .t as $t
       | ($t != null and $t.current_state.source == "stood-down") as $stood
       | ($t != null and $t.remote == null and $t.endpoint.exists == true and ($stood | not)) as $live
       | (($r.hold_kind // null) == "captain") as $held
       | ($r.hold_bucket // null) as $bucket
       | ($t.current_state.state // null) as $st
       | (if $t == null then null else $t.pr.url end) as $pr
       | project_of($t; $r) as $proj
       | (if $t == null and ($r.state // "") == "in_flight" and ($orphans | index($r.id)) != null then
            {tone: "red", phrase: "recorded as under way, but no worker is attached"}
          elif $t != null and $st == "failed" then {tone: "red", phrase: "failed"}
          elif $t != null and ($st == "blocked" or $t.hints.blocked_event == true) then
            {tone: "red", phrase: "stuck and asking for help"}
          elif $t != null and ($stood | not) and $t.remote == null and $t.endpoint.exists == false and $st != "done" then
            {tone: "red", phrase: "worker stopped responding"}
          elif $t != null and ($stood | not) and $st == "unknown" and $t.remote == null then
            {tone: "red", phrase: "worker state could not be read"}
          elif $held and ($bucket == "live" or $bucket == "aged") then
            {tone: "yellow", phrase: "your decision"}
          elif $held and $bucket == "dated" then
            {tone: "dim", phrase: ("deferred until " + ($r.hold_until // "a later date"))}
          elif $held and $bucket == "blocked" then
            {tone: "dim", phrase: "held until other work finishes"}
          elif $t != null and $st == "done" and $pr != null then
            {tone: "yellow", phrase: "ready for your review"}
          elif $t != null and ($st == "parked" or $t.hints.pending_decision == true) then
            {tone: "yellow", phrase: "paused at a review question"}
          elif $stood then {tone: "dim", phrase: "parked on purpose"}
          elif $t != null then {tone: "green", phrase: crew_phrase($t)}
          elif ($r.unresolved_blocker_ids // []) | length > 0 then
            {tone: "dim", phrase: "queued behind other work"}
          else {tone: "dim", phrase: "queued"} end) as $c
       | {id: ($r.id // $t.id), project: $proj,
          title: ((($r.title // null) // $t.id) | strip_prefix($proj)),
          tone: $c.tone, phrase: $c.phrase,
          running: $live, parked: $stood, held: $held,
          hold_bucket: $bucket, hold_reason: ($r.hold_reason // null),
          hold_until: ($r.hold_until // null),
          hold_epoch: (epoch_of($r.hold_set // null) // epoch_of($r.since // null)),
          pr_url: (($r.pr_url // null) // $pr),
          state: ($r.state // "in_flight"),
          worker_state: $st} ]) as $items_main
  | ([ (.secondmate_current.records // [])[] as $m
       | ([$m.active_children[]? | {id: ($m.id + "/" + .id), project: (.repo // $m.id),
             title: (.id), tone: "green", phrase: "working on it (via second mate " + $m.id + ")",
             running: true, parked: false, held: false, hold_bucket: null, hold_reason: null,
             hold_until: null, hold_epoch: null, pr_url: null, state: "in_flight", worker_state: "working"}]
          + [$m.decisions_open[]? | select(.verb == "captain-hold")
             | {id: ($m.id + "/" + .id), project: $m.id, title: (.summary // .id),
                tone: "yellow", phrase: "waiting on your decision (via second mate " + $m.id + ")",
                running: false, parked: false, held: true, hold_bucket: (.hold_bucket // "live"),
                hold_reason: (.reason // null), hold_until: (.hold_until // null),
                hold_epoch: (if .hold_age_days != null then ($now - (.hold_age_days * 86400)) else null end),
                pr_url: null, state: "queued", worker_state: null}])[] ]) as $items_mates
  | ($items_main + $items_mates
     | map((.held and (.hold_bucket == "dated" or .hold_bucket == "blocked")) as $deferred
           | (if .held and .hold_epoch != null then ($now - .hold_epoch) else null end) as $age
           | . + {waiting_seconds: $age,
                  waiting_days: (if $age == null then null else (($age / 86400) | floor) end),
                  deferred: $deferred,
                  overdue: (.held and ($deferred | not) and $age != null and $age > ($overdue_days * 86400))})) as $items
  | (($registered + [$items[].project])
     | reduce .[] as $p ([]; if any(.[]; lc == ($p | lc)) then . else . + [$p] end)) as $project_names
  | ([ $project_names[] as $p
       | [$items[] | select((.project | lc) == ($p | lc))] as $its
       | ($its | sort_by(.tone | rank) | first) as $top
       | (if ($its | length) == 0 then {word: "IDLE", tone: "dim"}
          else {red: "BLOCKED", yellow: "WAITING", green: "MOVING", dim: "PAUSED"}[$top.tone] as $w
               | {word: $w, tone: $top.tone} end) as $s
       | ([$its[] | select(.tone == $top.tone)] | sort_by(.hold_epoch // 9e18)) as $peers
       | {name: $p, status: $s.word, tone: $s.tone,
          registered: any($registered[]; lc == ($p | lc)),
          running: ([$its[] | select(.running)] | length),
          parked: ([$its[] | select(.parked)] | length),
          held: ([$its[] | select(.held)] | length),
          overdue: ([$its[] | select(.overdue)] | length),
          queued: ([$its[] | select(.state == "queued" and (.held | not))] | length),
          next: (if ($its | length) == 0 then "nothing open"
                 else ((if $peers[0].overdue then "OVERDUE " + ($peers[0].waiting_days | tostring) + "d: " else "" end)
                       + $peers[0].phrase + ": " + $peers[0].title
                       + (if ($peers | length) > 1 then " (+" + (($peers | length) - 1 | tostring) + " more)" else "" end))
                 end)} ]
     | sort_by((.tone | rank), (.name | lc))) as $projects
  | ([ $items[] | select(.held) ] | sort_by(.hold_epoch // 9e18)) as $decisions
  | ([ $tasks[] | select(.remote == null and .endpoint.exists == true and .current_state.source != "stood-down") | . as $t
       | ($trees[$t.id] // null) as $tree
       | ([$pairs[] | select(.t != null and .t.id == $t.id) | .r] | first) as $r
       | {id: $t.id,
          project: (if $t.kind == "secondmate" then "second mate" else project_of($t; $r) end),
          title: (($r.title // $t.id) | strip_prefix(project_of($t; $r))),
          doing: crew_phrase($t),
          tone: (if ($t.current_state.state // "") | IN("failed", "blocked", "unknown") then "red"
                 elif ($t.current_state.state // "") == "parked" then "yellow"
                 elif ($t.current_state.state // "") == "done" then "yellow"
                 else "green" end),
          model: ($t.model // null), effort: ($t.effort // null), harness: ($t.harness // null),
          running_seconds: (spawn_epoch($t.spawn_gen) | if . == null then null else ($now - .) end),
          measured: ($tree != null and $tree.processes > 0),
          processes: ($tree.processes // 0),
          rss_kb: (if $tree != null and $tree.processes > 0 then $tree.rss_kb else null end),
          cpu_percent: (if $tree != null and $tree.processes > 0 then $tree.cpu_percent else null end)} ]
     | sort_by(.project | lc)) as $workers
  | (num($mem_total)) as $mt | (num($mem_avail)) as $ma | (num($load1)) as $l1 | (num($cores)) as $nc
  | (if $mt == null or $ma == null then "dim"
     elif ($ma < $mt * 0.10) or ($ma < 1048576) then "red"
     elif ($ma < $mt * 0.20) or ($ma < 2097152) then "yellow"
     else "green" end) as $mem_tone
  | (if $l1 == null or $nc == null then "dim"
     elif $l1 > $nc then "red"
     elif $l1 > ($nc * 0.75) then "yellow"
     else "green" end) as $load_tone
  | ([ $items[] | select(.parked) ] as $pk
     | [ $pk[] | . as $i | ([$tasks[] | select(.id == $i.id)] | first) as $t
         | stood_down_reason($t) as $why
         | {id, project, title, reason: ($why.reason | sub("^stopped on purpose(: |$)"; "")),
            since: $why.since, held, pr_url} ]) as $parked
  | ([ .backlog.records[]? | select(.structured and .state == "done") ]
     | to_entries
     | sort_by([-((epoch_of(.value.completion.date) // 0)), .key])
     | map(.value)[:$finished_n]
     | map(. as $d | {id, project: (.repo // "(no project)"), title: (($d.title // $d.id) | strip_prefix($d.repo // "")),
            verb: (.completion.verb // "done"), date: (.completion.date // null),
            pr_url: (.pr_url // null), report: (.report_path != null)})) as $finished
  | ([$projects[] | select(.tone == "red")] | length) as $n_red
  | ([$decisions[] | select(.deferred | not)] | length) as $n_dec
  | ([$decisions[] | select(.overdue)] | length) as $n_overdue
  | ([$items[] | select(.tone == "yellow" and (.held | not))] | length) as $n_review
  | ([$items[] | select(.tone == "green")] | length) as $n_green
  | {schema: "fm-sitrep.v1",
     generated: (.generated // null),
     verdict: {
       tone: (if $n_red > 0 or $mem_tone == "red" then "red"
              elif $n_dec > 0 or $n_review > 0 or $mem_tone == "yellow" or $load_tone != "green" and $load_tone != "dim" then "yellow"
              elif $n_green > 0 then "green" else "dim" end),
       word: (if $n_red > 0 then "NEEDS ATTENTION"
              elif $n_dec > 0 or $n_review > 0 then "WAITING ON YOU"
              elif $n_green > 0 then "ALL MOVING" else "QUIET" end),
       blocked_projects: $n_red, decisions: $n_dec, overdue_decisions: $n_overdue,
       overdue_after_days: $overdue_days, reviews: $n_review,
       workers: ($workers | length), moving_items: $n_green,
       machine_pressure: (if $mem_tone == "red" or $load_tone == "red" then "high"
                          elif $mem_tone == "yellow" or $load_tone == "yellow" then "elevated" else "normal" end)},
     projects: $projects,
     decisions: $decisions,
     workers: $workers,
     totals: {workers: ($workers | length),
              measured: ([$workers[] | select(.measured)] | length),
              rss_kb: ([$workers[] | .rss_kb // 0] | add // 0),
              cpu_percent: ([$workers[] | .cpu_percent // 0] | add // 0)},
     machine: {mem_total_kb: $mt, mem_available_kb: $ma, mem_tone: $mem_tone,
               load1: $l1, cores: $nc, load_tone: $load_tone},
     parked: $parked,
     finished: $finished}
') || { echo "fm-sitrep: could not build the report" >&2; exit 1; }

if [ "$JSON" -eq 1 ]; then
  printf '%s\n' "$MODEL"
  exit 0
fi

# --- render ------------------------------------------------------------------
if [ "$COLOR" = always ]; then
  ESC=$'\033'
  CODES=$(jq -n --arg e "$ESC" '{red: ($e + "[31m"), yellow: ($e + "[33m"), green: ($e + "[32m"),
    dim: ($e + "[2m"), bold: ($e + "[1m"), reset: ($e + "[0m")}')
else
  CODES='{"red":"","yellow":"","green":"","dim":"","bold":"","reset":""}'
fi

printf '%s' "$MODEL" | jq -r --argjson c "$CODES" --argjson width "$WIDTH" '
  def paint($tone; $s): ($c[$tone] // "") + $s + (if ($c[$tone] // "") == "" then "" else $c.reset end);
  def bold($s): paint("bold"; $s);
  def cut($n): if length > $n then .[:($n - 3)] + "..." else . end;
  def pad($n): if length >= $n then . else . + (" " * ($n - length)) end;
  def lpad($n): if length >= $n then . else (" " * ($n - length)) + . end;
  def plural($n; $one; $many): ($n | tostring) + " " + (if $n == 1 then $one else $many end);
  def gib($kb): if $kb == null then "-" else (($kb / 1048576 * 10 | round) / 10 | tostring) + " GiB" end;
  def mem($kb): if $kb == null then "-"
                elif $kb >= 1048576 then gib($kb)
                else ((($kb / 1024) | round) | tostring) + " MiB" end;
  def dur($s): if $s == null or $s < 0 then "-"
               elif $s < 3600 then ((($s / 60) | floor) | tostring) + "m"
               elif $s < 86400 then ((($s / 3600) | floor) | tostring) + "h" + (((($s % 3600) / 60) | floor) | tostring | if length < 2 then "0" + . else . end) + "m"
               else ((($s / 86400) | floor) | tostring) + "d" + (((($s % 86400) / 3600) | floor) | tostring) + "h" end;
  def wrap($n; $indent):
    (split(" ") | map(select(length > 0))) as $w
    | reduce $w[] as $x ({lines: [], cur: ""};
        if .cur == "" then .cur = $x
        elif (.cur | length) + 1 + ($x | length) <= $n then .cur += " " + $x
        else .lines += [.cur] | .cur = $x end)
    | (.lines + (if .cur == "" then [] else [.cur] end))
    | map($indent + .) | join("\n");
  def section($t): "\n" + bold($t);
  def age($s): if $s < 3600 then "under an hour"
               elif $s < 86400 then plural((($s / 3600) | floor); "hour"; "hours")
               else plural((($s / 86400) | floor); "day"; "days") end;

  . as $m
  | ($m.verdict) as $v
  | [
      # 1. verdict
      (paint($v.tone; bold("SITREP  " + $v.word))
       + "  -  "
       + ([ (if $v.blocked_projects > 0 then plural($v.blocked_projects; "project blocked"; "projects blocked") else empty end),
            (if $v.decisions > 0 then plural($v.decisions; "decision waits on you"; "decisions wait on you")
               + (if $v.overdue_decisions > 0 then " (" + ($v.overdue_decisions | tostring) + " overdue)" else "" end)
             else empty end),
            (if $v.reviews > 0 then plural($v.reviews; "item ready for review"; "items ready for review") else empty end),
            plural($v.workers; "worker running"; "workers running"),
            (if $v.machine_pressure != "normal" then "machine load " + $v.machine_pressure else empty end)
          ] | join(", "))),
      ($c.dim + "Legend: " + $c.reset
       + paint("red"; "BLOCKED") + " failed, stuck or not responding | "
       + paint("yellow"; "WAITING") + " needs a decision, review or merge | "
       + paint("green"; "MOVING") + " under way, nothing needed | "
       + paint("dim"; "PAUSED / IDLE") + " parked, queued or nothing open | "
       + paint("red"; "OVERDUE") + " a decision waiting over " + plural($v.overdue_after_days; "day"; "days")),

      # 2. projects
      section("PROJECTS"),
      (if ($m.projects | length) == 0 then "  No projects are registered and nothing is open."
       else
         ([$m.projects[].name | length] | max | if . < 7 then 7 else . end | if . > 24 then 24 else . end) as $nw
         | ("  " + ("PROJECT" | pad($nw)) + "  " + ("STATUS" | pad(7)) + "  RUN PARK HELD  NEXT"),
           ($m.projects[]
            | ($width - $nw - 33) as $rest
            | "  " + paint(.tone; (.name | cut($nw) | pad($nw)) + "  " + (.status | pad(7)))
              + "  " + (.running | tostring | lpad(3)) + " " + (.parked | tostring | lpad(4)) + " " + (.held | tostring | lpad(4))
              + "  " + (.next | cut(if $rest < 20 then 20 else $rest end)
                        | if startswith("OVERDUE") then paint("red"; .) else . end))
       end),

      # 3. decisions
      section("DECISIONS NEEDED") + (if ($m.decisions | length) > 0 then " (oldest first)" else "" end),
      (if ($m.decisions | length) == 0 then "  " + paint("green"; "Nothing is waiting on your decision.")
       else
         ($m.decisions | to_entries[]
          | .key as $k | .value as $d
          | ("  " + paint(if $d.overdue then "red" elif $d.deferred then "dim" else "yellow" end;
                  (($k + 1) | tostring) + ". [" + $d.project + "] " + ($d.title | cut($width - 34)))
             + paint(if $d.overdue then "red" else "dim" end; " ("
                 + (if $d.waiting_seconds == null then "age unknown" else "waiting " + age($d.waiting_seconds) end)
                 + (if $d.overdue then ", OVERDUE" else "" end)
                 + (if $d.hold_bucket == "dated" then ", deferred until " + ($d.hold_until // "later")
                    elif $d.hold_bucket == "blocked" then ", until other work finishes"
                    else "" end) + ")")),
            (if ($d.hold_reason // "") != "" then ($d.hold_reason | wrap($width - 7; "     ")) else empty end),
            (if $d.pr_url != null and (($d.hold_reason // "") | contains($d.pr_url) | not) then "     PR: " + $d.pr_url else empty end))
       end),

      # 4. workers
      section("WORKERS RUNNING"),
      (if ($m.workers | length) == 0 then "  No workers are running."
       else
         ("  " + ("PROJECT" | pad(16)) + "  " + ("DOING" | pad(40)) + "  " + ("TIME" | lpad(6)) + "  " + ("MEMORY" | lpad(9)) + "  " + ("CPU" | lpad(5)) + "  MODEL"),
         ($m.workers[]
          | ("  " + paint(.tone; (.project | cut(16) | pad(16)) + "  " + (.doing | cut(40) | pad(40)))
             + "  " + (dur(.running_seconds) | lpad(6))
             + "  " + (if .measured then mem(.rss_kb) else "unknown" end | lpad(9))
             + "  " + (if .measured then ((.cpu_percent | round | tostring) + "%") else "-" end | lpad(5))
             + "  " + ((.model // .harness // "-") + (if .effort != null then " (" + .effort + ")" else "" end))),
            paint("dim"; "    " + ((.title + "  (" + .id + ")") | cut($width - 4))))
       end),
      ("  " + bold("Total") + ": " + plural($m.totals.workers; "worker"; "workers")
       + (if $m.totals.workers > 0 then
            ", " + mem($m.totals.rss_kb) + " memory, " + (($m.totals.cpu_percent | round | tostring) + "% CPU")
            + (if $m.totals.measured < $m.totals.workers then
                 " (" + (($m.totals.workers - $m.totals.measured) | tostring) + " not measured)" else "" end)
          else "" end)),
      ("  Machine: "
       + paint($m.machine.mem_tone;
           if $m.machine.mem_available_kb == null then "memory unknown"
           else gib($m.machine.mem_available_kb) + " of " + gib($m.machine.mem_total_kb) + " memory available"
                + (if $m.machine.mem_tone == "red" then " (LOW)" elif $m.machine.mem_tone == "yellow" then " (getting low)" else "" end) end)
       + ", "
       + paint($m.machine.load_tone;
           if $m.machine.load1 == null then "load unknown"
           else "load " + ($m.machine.load1 | tostring) + " on " + (($m.machine.cores // "?") | tostring) + " cores"
                + (if $m.machine.load_tone == "red" then " (OVERLOADED)" elif $m.machine.load_tone == "yellow" then " (busy)" else "" end) end)),

      # 5. parked and finished
      section("PARKED (stopped on purpose)"),
      (if ($m.parked | length) == 0 then "  Nothing is parked."
       else ($m.parked[]
             | ("  " + paint("dim"; "[" + .project + "] " + (.title | cut($width - 34)))
                + (if .since != null then paint("dim"; " (since " + (.since | split(" ")[0]) + ")") else "" end)),
               (if (.reason // "") != "" then "    " + (.reason | cut($width - 4)) else empty end))
       end),
      section("RECENTLY FINISHED"),
      (if ($m.finished | length) == 0 then "  Nothing has finished recently."
       else ($m.finished[]
             | "  " + paint("green"; "[" + .project + "] " + (.title | cut($width - 50)))
               + " - " + .verb + (if .date != null then " " + .date else "" end)
               + (if .pr_url != null then " - " + .pr_url elif .report then " - report written" else "" end))
       end)
    ]
  | .[]
'
