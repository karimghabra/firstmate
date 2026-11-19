#!/usr/bin/env bash
# fm-sitrep.sh - colour-coded, at-a-glance situation report for one firstmate home.
#
# A read-only terminal renderer. It does not parse fleet state files itself: it
# renders bin/fm-fleet-snapshot.sh --json (the canonical fleet state, including
# each task's current state from bin/fm-crew-state.sh, its stand-down record,
# recorded PR, and the backlog's captain holds), and adds only what that
# snapshot does not carry: the resident memory and CPU of every live worker's
# process tree and the machine's free memory and load. It takes no lock, drains
# nothing, writes nothing under the home (only --html writes, to a temp
# directory), and makes no network call of its own;
# the snapshot it renders is bounded and its only side effect is the snapshot's
# own observational remote-summary cache refresh.
#
# Second mates: every valid local second-mate home is reported by running this
# script against that home, and its items, decisions, workers (with memory) and
# parked work are merged in, labelled with the mate. A remote second mate, or a
# local one that cannot be read, gets one row in a SECOND MATES section with its
# published state and counts, and the captain holds its summary lists appear
# under decisions with ages in whole days; its other detail lives in that home.
# A local second mate whose own session is gone or holds only a bare shell is
# not listed as a running worker: its row turns red and raises the verdict,
# whether or not its home was merged.
#
# Sections, in order:
#   1. one-line verdict for the whole fleet;
#   2. projects at a glance - one row per registered project (data/projects.md,
#      line format owned by bin/fm-project-mode.sh) plus any project with open
#      work, with a status word, running / parked / held counts, and the single
#      most important next thing;
#   3. decisions needed - every open item held for the captain, oldest first,
#      with how long it has waited, its question, and any PR URL in full;
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
# Overdue decisions: a captain hold's age runs from its recorded hold date, or
# from the item's `since` date when none is recorded. A hold waiting more than 3
# days is marked OVERDUE in red, is flagged on its project's row when it is that
# project's most urgent item, and is counted in the verdict line. Holds
# deferred to a date or until other work finishes are never overdue. A hold
# known only from a second mate's summary has a whole-day age and is overdue
# from 3 days.
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
# HTML: --html writes the same report as one small self-contained page, for
# chat surfaces that render an HTML file but not terminal colour. It is built
# from the --json model with the same wording helpers as the terminal report,
# carries the same status words, follows the reader's light or dark preference,
# loads nothing external, and fits a phone-width screen without sideways
# scrolling. It goes to sitrep.html in a new private (0700) directory under
# TMPDIR (default /tmp). The written path is the only output.
#
# Flags:
#   (default)    the human report
#   --json       the same model as JSON (schema fm-sitrep.v1), no colour
#   --html       write the report as a self-contained HTML page; print its path
#   --full       show each decision's whole reason instead of its first sentence
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
#   FM_SITREP_NESTED       set by this script when it reports on a second-mate
#                          home, so that run does not descend into further homes
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
export FM_HOME
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() {
  cat <<'EOF'
usage: fm-sitrep.sh [--json | --html] [--full] [--no-color | --color]

Colour-coded situation report for the active firstmate home: an overall
verdict, every project at a glance, decisions waiting on you, running workers
with their memory and CPU use, and parked and recently finished work.

  --json       print the report model as JSON (schema fm-sitrep.v1)
  --html       write the report as a self-contained HTML page (light and
               dark, phone width) to a new private temp file, and print
               the file's path
  --full       show each decision's whole reason, not just its first sentence
  --no-color   never use colour (NO_COLOR is honoured too)
  --color      always use colour
  -h, --help   this help

Status words: BLOCKED (red) failed, stuck or not responding; WAITING (yellow)
needs a decision, review or merge; MOVING (green) under way, nothing needed;
PAUSED (grey) parked on purpose, deferred or queued; IDLE (grey) nothing open.
Read-only: no locks, no network calls of its own, and no writes except the
--html page.
EOF
}

JSON=0
HTML=0
FULL=0
COLOR=auto
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) JSON=1 ;;
    --html) HTML=1 ;;
    --full) FULL=1 ;;
    --no-color) COLOR=never ;;
    --color) COLOR=always ;;
    -h|--help) usage; exit 0 ;;
    *) echo "fm-sitrep: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [ "$JSON" -eq 1 ] && [ "$HTML" -eq 1 ]; then
  echo "fm-sitrep: --json and --html cannot be combined" >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "fm-sitrep: jq not found" >&2; exit 1; }

if [ "$COLOR" = auto ]; then
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then COLOR=always; else COLOR=never; fi
fi
[ "$JSON" -eq 0 ] || COLOR=never

NOW_EPOCH=${FM_SITREP_NOW_EPOCH:-$(date +%s)}
case "$NOW_EPOCH" in ''|*[!0-9]*) NOW_EPOCH=$(date +%s) ;; esac
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

# Each valid local second-mate home is reported by running this same script
# against it; its items, workers and parked work are merged into this report.
# A nested run does not descend again: it lists its own second mates as rows.
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
MATE_MODELS='[]'
if [ -z "${FM_SITREP_NESTED:-}" ]; then
  while IFS=$'\t' read -r mate_id mate_home; do
    [ -n "$mate_id" ] || continue
    validate_secondmate_home "$mate_id" "$mate_home" 2>/dev/null || continue
    mate_model=$(env -u FM_DATA_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
      FM_HOME="$VALIDATED_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_SITREP_NESTED=1 \
      "$SCRIPT_DIR/fm-sitrep.sh" --json 2>/dev/null) || continue
    MATE_MODELS=$(jq -n --argjson all "$MATE_MODELS" --arg id "$mate_id" --argjson model "$mate_model" \
      '$all + [{id: $id, model: $model}]') || { echo "fm-sitrep: could not read second mate $mate_id" >&2; exit 1; }
  done < <(printf '%s' "$SNAPSHOT" | jq -r '
    .secondmate_current.records[]?
    | select(.remote != true and (.home // "") != "")
    | [.id, .home] | @tsv')
fi

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
  | select(.remote == null and .endpoint.exists == true and .endpoint.agent_alive != "dead"
           and .current_state.source != "stood-down"
           and (.endpoint.target // "") != "")
  | [.id, .backend, .endpoint.target] | @tsv')

PS_BIN=${FM_SITREP_PS_BIN:-ps}
PS_TABLE=$(LC_ALL=C "$PS_BIN" -axo pid=,ppid=,rss=,pcpu= 2>/dev/null) || PS_TABLE=""

# One line per worker: id, root pid, process count, rss kB, cpu percent.
# A root pid absent from the table yields a zero process count.
TREES_JSON=$(
  {
    printf '%s' "$ROOTS_TSV" | awk '{ print "R\t" $0 }'
    printf '%s\n' "$PS_TABLE" | awk '{ print "P\t" $0 }'
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
  --argjson mates "$MATE_MODELS" \
  --argjson now "$NOW_EPOCH" \
  --argjson finished_n 5 \
  --argjson overdue_days 3 \
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
  def item($r; $t; $orphan):
    ($t != null and $t.current_state.source == "stood-down") as $stood
    | ($t != null and $t.remote == null and $t.endpoint.exists == true and ($stood | not)) as $live
    | (($r.hold_kind // null) == "captain") as $held
    | ($r.hold_bucket // null) as $bucket
    | ($t.current_state.state // null) as $st
    | (if $t == null then null else $t.pr.url end) as $pr
    | project_of($t; $r) as $proj
    | (if $orphan and ($r.state // "") == "in_flight" then
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
       worker_state: $st};

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
       | item($r; $t; ($t == null and ($orphans | index($r.id)) != null)) ]) as $items_main
  | ([ $mates[] | .id as $mid | .model.items[]
       | . + {id: ($mid + "/" + .id), mate: $mid, phrase: (.phrase + " (via second mate " + $mid + ")")} ]) as $items_mates
  | ([ (.secondmate_current.records // [])[] as $m
       | select(any($mates[]; .id == $m.id) | not)
       | ([$m.queued[]? | select(.hold_kind == "captain" and .hold_bucket != null)]
          + [$m.decisions_open[]? | select(.verb == "captain-hold")
             | {id, title: .summary, hold_kind: "captain", hold_bucket: (.hold_bucket // "live"),
                hold_reason: .reason, hold_until, hold_age_days}]
          | unique_by(.id))[]
       | . as $q
       | item($q + {repo: ($q.repo // $m.id), state: "queued"}; null; false)
       | . + {id: ($m.id + "/" + .id), mate: $m.id, phrase: (.phrase + " (via second mate " + $m.id + ")"),
              age_in_days: true,
              hold_epoch: (if $q.hold_age_days != null
                           then ($now - (($m.freshness.age_seconds // 0) + $q.hold_age_days * 86400)) else null end)} ]) as $items_summaries
  | (($items_main | map(. + {mate: null, age_in_days: false})) + $items_summaries
     | map((.held and (.hold_bucket == "dated" or .hold_bucket == "blocked")) as $deferred
           | (if .held and .hold_epoch != null then ($now - .hold_epoch) else null end) as $age
           | (if $age == null then null else (($age / 86400) | floor) end) as $days
           | . + {waiting_seconds: $age,
                  waiting_days: $days,
                  deferred: $deferred,
                  overdue: (.held and ($deferred | not) and $age != null
                            and (if .age_in_days then $days >= $overdue_days
                                 else $age > ($overdue_days * 86400) end))})
     | . + $items_mates) as $items
  | ($registered + [$mates[].model.projects[] | select(.registered) | .name]) as $registered
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
  | ([ $tasks[] | select(.remote == null and .endpoint.exists == true and .endpoint.agent_alive != "dead"
                         and .current_state.source != "stood-down") | . as $t
       | ($trees[$t.id] // null) as $tree
       | ([$pairs[] | select(.t != null and .t.id == $t.id) | .r] | first) as $r
       | {id: $t.id, mate: null,
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
     + [ $mates[] | .id as $mid | .model.workers[] | . + {id: ($mid + "/" + .id), mate: $mid} ]
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
  | ([ $items[] | select(.parked and .mate == null) | . as $i
       | ([$tasks[] | select(.id == $i.id)] | first) as $t
       | stood_down_reason($t) as $why
       | {id, mate, project, title, reason: ($why.reason | sub("^stopped on purpose(: |$)"; "")),
          since: $why.since, held, pr_url} ]
     + [ $mates[] | .id as $mid | .model.parked[] | . + {id: ($mid + "/" + .id), mate: $mid} ]) as $parked
  | ([ (.secondmate_current.records // [])[] as $r
       | any($mates[]; .id == $r.id) as $merged
       | ($r.current.state // "unknown") as $st
       | any($tasks[]; .id == $r.id and .kind == "secondmate" and .remote == null
                       and (.endpoint.exists == false or .endpoint.agent_alive == "dead")
                       and .current_state.source != "stood-down") as $stopped
       | {id: $r.id, remote: ($r.remote == true), host: ($r.host // null), home: ($r.home // null),
          merged: $merged, state: $st,
          tone: (if $stopped then "red" elif $merged then "dim" elif $st == "unknown" then "red" elif $st == "captain_decision" then "yellow"
                 elif $st == "active_child_work" then "green" else "dim" end),
          phrase: ((if $stopped then "its own session stopped responding; " else "" end)
                   + if $merged then "included in this report"
                   elif $st == "unknown" then "state could not be read" + (if $r.current.reason != null then ": " + $r.current.reason else "" end)
                   elif $st == "captain_decision" then "waiting on your decision"
                   elif $st == "active_child_work" then "working"
                   elif $st == "externally_held" then "held on outside work"
                   else "nothing open" end),
          counts: {working: ($r.counts.active_children // 0), decisions: ($r.counts.decisions_open // 0),
                   queued: ($r.counts.queued // 0)},
          omitted: ([$r.omitted[]? | select(.surface | IN("active_children", "decisions_open", "queued")) | .count]
                    | add // 0),
          omitted_holds: (if $merged then 0
                          else ([$r.omitted[]? | select(.surface == "queued" or .surface == "decisions_open") | .count] | max // 0) end)} ]
     + [ $mates[] | .id as $mid | .model.mates[] | . + {id: ($mid + "/" + .id)} ]) as $mate_rows
  | ([$mate_rows[] | select(.tone == "red")] | length) as $n_mate_red
  | ([$mate_rows[] | select(.tone == "yellow")] | length) as $n_mate_yellow
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
       tone: (if $n_red > 0 or $n_mate_red > 0 or $mem_tone == "red" then "red"
              elif $n_dec > 0 or $n_review > 0 or $n_mate_yellow > 0 or $mem_tone == "yellow" or $load_tone != "green" and $load_tone != "dim" then "yellow"
              elif $n_green > 0 then "green" else "dim" end),
       word: (if $n_red > 0 or $n_mate_red > 0 then "NEEDS ATTENTION"
              elif $n_dec > 0 or $n_review > 0 or $n_mate_yellow > 0 then "WAITING ON YOU"
              elif $n_green > 0 then "ALL MOVING" else "QUIET" end),
       blocked_projects: $n_red, decisions: $n_dec, overdue_decisions: $n_overdue,
       overdue_after_days: $overdue_days, reviews: $n_review,
       mates_attention: ($n_mate_red + $n_mate_yellow),
       workers: ($workers | length), moving_items: $n_green,
       machine_pressure: (if $mem_tone == "red" or $load_tone == "red" then "high"
                          elif $mem_tone == "yellow" or $load_tone == "yellow" then "elevated" else "normal" end)},
     projects: $projects,
     mates: $mate_rows,
     items: $items,
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
# Wording shared by the terminal and HTML renderers, so both say the same thing.
# shellcheck disable=SC2016 # a jq program, not shell expansion
JQ_COMMON='
  def plural($n; $one; $many): ($n | tostring) + " " + (if $n == 1 then $one else $many end);
  def gib($kb): if $kb == null then "-" else (($kb / 1048576 * 10 | round) / 10 | tostring) + " GiB" end;
  def mem($kb): if $kb == null then "-"
                elif $kb >= 1048576 then gib($kb)
                else ((($kb / 1024) | round) | tostring) + " MiB" end;
  def dur($s): if $s == null or $s < 0 then "-"
               elif $s < 3600 then ((($s / 60) | floor) | tostring) + "m"
               elif $s < 86400 then ((($s / 3600) | floor) | tostring) + "h" + (((($s % 3600) / 60) | floor) | tostring | if length < 2 then "0" + . else . end) + "m"
               else ((($s / 86400) | floor) | tostring) + "d" + (((($s % 86400) / 3600) | floor) | tostring) + "h" end;
  def tag($i): $i.project + (if $i.mate != null then " via " + $i.mate else "" end);
  # The text up to and including the first sentence end (., ? or ! followed by
  # a space or the end); the whole text when no sentence end is found.
  def first_sentence($s):
    ($s | sub("\\s+$"; "")) as $t
    | ($t | capture("^(?<f>.*?(?<!\\.[A-Za-z])[.?!])(\\s|$)") // {f: $t}).f;
  def age($s): if $s < 3600 then "under an hour"
               elif $s < 86400 then plural((($s / 3600) | floor); "hour"; "hours")
               else plural((($s / 86400) | floor); "day"; "days") end;
  def verdict_parts($v):
    [ (if $v.blocked_projects > 0 then plural($v.blocked_projects; "project blocked"; "projects blocked") else empty end),
      (if $v.decisions > 0 then plural($v.decisions; "decision waits on you"; "decisions wait on you")
         + (if $v.overdue_decisions > 0 then " (" + ($v.overdue_decisions | tostring) + " overdue)" else "" end)
       else empty end),
      (if $v.reviews > 0 then plural($v.reviews; "item ready for review"; "items ready for review") else empty end),
      (if $v.mates_attention > 0 then plural($v.mates_attention; "second mate needs a look"; "second mates need a look") else empty end),
      plural($v.workers; "worker running"; "workers running"),
      (if $v.machine_pressure != "normal" then "machine load " + $v.machine_pressure else empty end) ];
  def mate_head($r): $r.id + " (" + (if $r.remote then "remote, " + ($r.host // "host unknown") else "local" end) + "): " + $r.phrase;
  def mate_tail($r):
    if $r.merged then ""
    else " - " + plural($r.counts.working; "worker"; "workers") + ", "
         + plural($r.counts.decisions; "open decision"; "open decisions") + ", "
         + ($r.counts.queued | tostring) + " queued"
         + (if $r.omitted > 0 then " (" + ($r.omitted | tostring) + " not shown)" else "" end)
         + "; detail lives in that home" + (if $r.home != null then ": " + $r.home else "" end) end;
  def decision_tone($d): if $d.overdue then "red" elif $d.deferred then "dim" else "yellow" end;
  def waited($d):
    (if $d.waiting_seconds == null then "age unknown"
     elif $d.age_in_days and $d.waiting_days == 0 then "waiting under a day"
     else "waiting " + age($d.waiting_seconds) end)
    + (if $d.overdue then ", OVERDUE" else "" end)
    + (if $d.hold_bucket == "dated" then ", deferred until " + ($d.hold_until // "later")
       elif $d.hold_bucket == "blocked" then ", until other work finishes"
       else "" end);
  def shown_reason($d; $full): ($d.hold_reason // "") as $why | if $full == 1 then $why else first_sentence($why) end;
  def extra_prs($d; $shown):
    [($d.pr_url // empty), (($d.hold_reason // "") | scan("https?://[^ )]+/pull/[0-9]+"))]
    | unique | map(. as $u | select(($shown | contains($u)) | not));
  def omitted_holds_text($r):
    "Up to " + ($r.omitted_holds | tostring) + " more held or queued items wait in the home of second mate " + $r.id + " and are not listed here.";
  def any_shortened($m): any($m.decisions[]; (.hold_reason // "") as $w | first_sentence($w) != ($w | sub("\\s+$"; "")));
  def worker_mem($w): if $w.measured then mem($w.rss_kb) else "unknown" end;
  def worker_cpu($w): if $w.measured then (($w.cpu_percent | round | tostring) + "%") else "-" end;
  def worker_model($w): ($w.model // $w.harness // "-") + (if $w.effort != null then " (" + $w.effort + ")" else "" end);
  def totals_text($t):
    plural($t.workers; "worker"; "workers")
    + (if $t.workers > 0 then
         ", " + mem($t.rss_kb) + " memory, " + (($t.cpu_percent | round | tostring) + "% CPU")
         + (if $t.measured < $t.workers then " (" + (($t.workers - $t.measured) | tostring) + " not measured)" else "" end)
       else "" end);
  def machine_mem($x):
    if $x.mem_available_kb == null then "memory unknown"
    else gib($x.mem_available_kb) + " of " + gib($x.mem_total_kb) + " memory available"
         + (if $x.mem_tone == "red" then " (LOW)" elif $x.mem_tone == "yellow" then " (getting low)" else "" end) end;
  def machine_load($x):
    if $x.load1 == null then "load unknown"
    else "load " + ($x.load1 | tostring) + " on " + (($x.cores // "?") | tostring) + " cores"
         + (if $x.load_tone == "red" then " (OVERLOADED)" elif $x.load_tone == "yellow" then " (busy)" else "" end) end;
  def finished_tail($f):
    " - " + $f.verb + (if $f.date != null then " " + $f.date else "" end);
  def legend_parts($v):
    [["red", "BLOCKED", " failed, stuck or not responding"],
     ["yellow", "WAITING", " needs a decision, review or merge"],
     ["green", "MOVING", " under way, nothing needed"],
     ["dim", "PAUSED / IDLE", " parked, queued or nothing open"],
     ["red", "OVERDUE", " a decision waiting over " + plural($v.overdue_after_days; "day"; "days")]];
'

if [ "$HTML" -eq 1 ]; then
  HTML_DIR=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/fm-sitrep.XXXXXX") || {
    echo "fm-sitrep: could not create a private directory for the page" >&2
    exit 1
  }
  HTML_PATH=$HTML_DIR/sitrep.html
  printf '%s' "$MODEL" | jq -r --argjson full "$FULL" "$JQ_COMMON"'
  def tone_text($tone; $s): @html "<span class=\"\($tone)\">\($s)</span>";
  def word($tone; $s): @html "<span class=\"w \($tone)\">\($s)</span>";
  def link($u): @html "<a href=\"\($u)\">\($u)</a>";
  def section($t): @html "<h2>\($t)</h2>";
  def empty_line($s): @html "<p class=\"sub\">\($s)</p>";
  def sub($s): @html "<div class=\"sub\">\($s)</div>";

  . as $m
  | ($m.verdict) as $v
  | [
      "<!doctype html>",
      "<html lang=\"en\"><head><meta charset=\"utf-8\">",
      "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
      "<title>Sitrep</title><style>",
      ":root{color-scheme:light dark;--bg:#fff;--fg:#1c1c1c;--muted:#5f5f5f;--line:#e2e2e2;--red:#b3261e;--yellow:#8a5300;--green:#1d7a35;--dim:#6b6b6b}",
      "@media (prefers-color-scheme:dark){:root{--bg:#161616;--fg:#e9e9e9;--muted:#a3a3a3;--line:#323232;--red:#ff6f66;--yellow:#e6b23c;--green:#62d07d;--dim:#9c9c9c}}",
      "*{box-sizing:border-box}html{-webkit-text-size-adjust:100%}",
      "body{margin:0;padding:16px;background:var(--bg);color:var(--fg);font:15px/1.45 system-ui,-apple-system,\"Segoe UI\",Roboto,sans-serif;overflow-wrap:anywhere}",
      "main{max-width:52rem;margin:0 auto}h1{font-size:1.3rem;margin:0 0 .2rem}p{margin:.2rem 0}",
      "h2{font-size:.8rem;letter-spacing:.06em;color:var(--muted);margin:1.3rem 0 .3rem;padding-bottom:.2rem;border-bottom:1px solid var(--line)}",
      "ul,ol{margin:0;padding:0;list-style:none}li{padding:.45rem 0;border-bottom:1px solid var(--line)}",
      ".red{color:var(--red)}.yellow{color:var(--yellow)}.green{color:var(--green)}.dim{color:var(--dim)}",
      ".w{display:inline-block;font:700 .75rem/1.5 ui-monospace,Menlo,Consolas,monospace;border:1px solid currentColor;border-radius:4px;padding:0 .3rem;margin:0 .35rem .1rem 0;white-space:nowrap}",
      ".sub{color:var(--muted);font-size:.87rem}.legend{font-size:.8rem;color:var(--muted);margin-top:.4rem}.legend span.w{font-size:.68rem}a{color:inherit}",
      "</style></head><body><main>",

      # 1. verdict
      (@html "<h1 class=\"\($v.tone)\">SITREP \($v.word)</h1>"),
      (@html "<p>\(verdict_parts($v) | join(", "))</p>"),
      ("<p class=\"legend\">" + (legend_parts($v) | map(word(.[0]; .[1]) + (.[2] | @html)) | join(" | ")) + "</p>"),

      # 2. projects
      section("PROJECTS"),
      (if ($m.projects | length) == 0 then empty_line("No projects are registered and nothing is open.")
       else
         "<ul>",
         ($m.projects[]
          | "<li>" + word(.tone; .status) + (@html "<b class=\"\(.tone)\">\(.name)</b>")
            + sub("running " + (.running | tostring) + ", parked " + (.parked | tostring) + ", held " + (.held | tostring))
            + (if (.next | startswith("OVERDUE")) then (@html "<div class=\"red\">\(.next)</div>") else (@html "<div>\(.next)</div>") end)
            + "</li>"),
         "</ul>"
       end),

      (if ($m.mates | length) == 0 then empty
       else
         section("SECOND MATES"), "<ul>",
         ($m.mates[] | "<li>" + tone_text(.tone; mate_head(.)) + (mate_tail(.) | @html) + "</li>"),
         "</ul>"
       end),

      # 3. decisions
      section("DECISIONS NEEDED" + (if ($m.decisions | length) > 0 then " (oldest first)" else "" end)),
      (if ($m.decisions | length) == 0 then (@html "<p class=\"green\">Nothing is waiting on your decision.</p>")
       else
         "<ol>",
         ($m.decisions | to_entries[]
          | .key as $k | .value as $d
          | shown_reason($d; $full) as $shown
          | "<li>" + tone_text(decision_tone($d); (($k + 1) | tostring) + ". [" + tag($d) + "] " + $d.title)
            + " " + tone_text(if $d.overdue then "red" else "dim" end; "(" + waited($d) + ")")
            + (if $shown != "" then (@html "<div>\($shown)</div>") else "" end)
            + (extra_prs($d; $shown) | map("<div class=\"sub\">PR: " + link(.) + "</div>") | join(""))
            + "</li>"),
         "</ol>"
       end),
      ($m.mates[] | select(.omitted_holds > 0) | (@html "<p class=\"yellow\">\(omitted_holds_text(.))</p>")),
      (if $full == 0 and any_shortened($m)
       then empty_line("Shortened to the first sentence; run with --full for the whole reasons.") else empty end),

      # 4. workers
      section("WORKERS RUNNING"),
      (if ($m.workers | length) == 0 then empty_line("No workers are running.")
       else
         "<ul>",
         ($m.workers[]
          | "<li>" + (@html "<b class=\"\(.tone)\">\(.project)</b> ") + tone_text(.tone; .doing)
            + sub(.title + "  (" + .id + ")")
            + sub("time " + dur(.running_seconds) + ", memory " + worker_mem(.) + ", CPU " + worker_cpu(.) + ", " + worker_model(.))
            + "</li>"),
         "</ul>"
       end),
      (@html "<p><b>Total</b>: \(totals_text($m.totals))</p>"),
      ("<p>Machine: " + tone_text($m.machine.mem_tone; machine_mem($m.machine)) + ", "
       + tone_text($m.machine.load_tone; machine_load($m.machine)) + "</p>"),

      # 5. parked and finished
      section("PARKED (stopped on purpose)"),
      (if ($m.parked | length) == 0 then empty_line("Nothing is parked.")
       else
         "<ul>",
         ($m.parked[]
          | "<li>" + tone_text("dim"; "[" + tag(.) + "] " + .title
                               + (if .since != null then " (since " + (.since | split(" ")[0]) + ")" else "" end))
            + (if (.reason // "") != "" then (@html "<div>\(.reason)</div>") else "" end) + "</li>"),
         "</ul>"
       end),
      section("RECENTLY FINISHED"),
      (if ($m.finished | length) == 0 then empty_line("Nothing has finished recently.")
       else
         "<ul>",
         ($m.finished[]
          | "<li>" + tone_text("green"; "[" + .project + "] " + .title) + (finished_tail(.) | @html)
            + (if .pr_url != null then " - " + link(.pr_url) elif .report then " - report written" else "" end) + "</li>"),
         "</ul>"
       end),
      "</main></body></html>"
    ]
  | .[]
' > "$HTML_PATH" || { echo "fm-sitrep: could not write the page to $HTML_PATH" >&2; exit 1; }
  printf '%s\n' "$HTML_PATH"
  exit 0
fi

if [ "$COLOR" = always ]; then
  ESC=$'\033'
  CODES=$(jq -n --arg e "$ESC" '{red: ($e + "[31m"), yellow: ($e + "[33m"), green: ($e + "[32m"),
    dim: ($e + "[2m"), bold: ($e + "[1m"), reset: ($e + "[0m")}')
else
  CODES='{"red":"","yellow":"","green":"","dim":"","bold":"","reset":""}'
fi

printf '%s' "$MODEL" | jq -r --argjson c "$CODES" --argjson width "$WIDTH" --argjson full "$FULL" "$JQ_COMMON"'
  def paint($tone; $s): ($c[$tone] // "") + $s + (if ($c[$tone] // "") == "" then "" else $c.reset end);
  def bold($s): paint("bold"; $s);
  def cut($n): if length > $n then .[:($n - 3)] + "..." else . end;
  def pad($n): if length >= $n then . else . + (" " * ($n - length)) end;
  def lpad($n): if length >= $n then . else (" " * ($n - length)) + . end;
  def wrap($n; $indent):
    (split(" ") | map(select(length > 0))) as $w
    | reduce $w[] as $x ({lines: [], cur: ""};
        if .cur == "" then .cur = $x
        elif (.cur | length) + 1 + ($x | length) <= $n then .cur += " " + $x
        else .lines += [.cur] | .cur = $x end)
    | (.lines + (if .cur == "" then [] else [.cur] end))
    | map($indent + .) | join("\n");
  def section($t): "\n" + bold($t);

  . as $m
  | ($m.verdict) as $v
  | [
      # 1. verdict
      (paint($v.tone; bold("SITREP  " + $v.word)) + "  -  " + (verdict_parts($v) | join(", "))),
      ($c.dim + "Legend: " + $c.reset
       + (legend_parts($v) | map(paint(.[0]; .[1]) + .[2]) | join(" | "))),

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

      (if ($m.mates | length) == 0 then empty
       else
         section("SECOND MATES"),
         ($m.mates[] | "  " + paint(.tone; mate_head(.)) + mate_tail(.))
       end),

      # 3. decisions
      section("DECISIONS NEEDED") + (if ($m.decisions | length) > 0 then " (oldest first)" else "" end),
      (if ($m.decisions | length) == 0 then "  " + paint("green"; "Nothing is waiting on your decision.")
       else
         ($m.decisions | to_entries[]
          | .key as $k | .value as $d
          | ("  " + paint(decision_tone($d); (($k + 1) | tostring) + ". [" + tag($d) + "] " + ($d.title | cut($width - 34)))
             + paint(if $d.overdue then "red" else "dim" end; " (" + waited($d) + ")")),
            (shown_reason($d; $full) as $shown
             | (if $shown != "" then ($shown | wrap($width - 7; "     ")) else empty end),
               (extra_prs($d; $shown)[] | "     PR: " + .)))
       end),
      ($m.mates[] | select(.omitted_holds > 0) | paint("yellow"; "  " + omitted_holds_text(.))),
      (if $full == 0 and any_shortened($m)
       then paint("dim"; "  Shortened to the first sentence; run with --full for the whole reasons.") else empty end),

      # 4. workers
      section("WORKERS RUNNING"),
      (if ($m.workers | length) == 0 then "  No workers are running."
       else
         ("  " + ("PROJECT" | pad(16)) + "  " + ("DOING" | pad(40)) + "  " + ("TIME" | lpad(6)) + "  " + ("MEMORY" | lpad(9)) + "  " + ("CPU" | lpad(5)) + "  MODEL"),
         ($m.workers[]
          | ("  " + paint(.tone; (.project | cut(16) | pad(16)) + "  " + (.doing | cut(40) | pad(40)))
             + "  " + (dur(.running_seconds) | lpad(6))
             + "  " + (worker_mem(.) | lpad(9))
             + "  " + (worker_cpu(.) | lpad(5))
             + "  " + worker_model(.)),
            paint("dim"; "    " + ((.title + "  (" + .id + ")") | cut($width - 4))))
       end),
      ("  " + bold("Total") + ": " + totals_text($m.totals)),
      ("  Machine: " + paint($m.machine.mem_tone; machine_mem($m.machine)) + ", "
       + paint($m.machine.load_tone; machine_load($m.machine))),

      # 5. parked and finished
      section("PARKED (stopped on purpose)"),
      (if ($m.parked | length) == 0 then "  Nothing is parked."
       else ($m.parked[]
             | ("  " + paint("dim"; "[" + tag(.) + "] " + (.title | cut($width - 34)))
                + (if .since != null then paint("dim"; " (since " + (.since | split(" ")[0]) + ")") else "" end)),
               (if (.reason // "") != "" then "    " + (.reason | cut($width - 4)) else empty end))
       end),
      section("RECENTLY FINISHED"),
      (if ($m.finished | length) == 0 then "  Nothing has finished recently."
       else ($m.finished[]
             | "  " + paint("green"; "[" + .project + "] " + (.title | cut($width - 50))) + finished_tail(.)
               + (if .pr_url != null then " - " + .pr_url elif .report then " - report written" else "" end))
       end)
    ]
  | .[]
'
