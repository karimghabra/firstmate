#!/usr/bin/env bash
# Live driver: generate real ship briefs with bin/fm-brief.sh (target and base
# commit) in isolated FM_HOMEs, print the "# Project memory" section, then act
# as a worker: follow the target brief's command in a git repo whose only guide
# is a real CLAUDE.md and record knowledge where the helper's guide: line says.
set -u
WT=/home/mars/.no-mistakes/worktrees/a8c0c72d0935/01M27J3PJGC4TE9T9N1M2YHTKC
SCR=$(mktemp -d /tmp/fm-brief-live.XXXXXX)
mkdir -p "$SCR/base"
git -C "$WT" archive 8facd7c | tar -x -C "$SCR/base"

section() { sed -n '/^# Project memory$/,/^# /p' "$1" | sed '$d' | sed "s#$2#<FM_ROOT>#g; s/^/    | /"; }
gen() {
  local root=$1 home="$SCR/home-$2"
  mkdir -p "$home/data"
  FM_HOME="$home" "$root/bin/fm-brief.sh" brief-live-$2 some-proj --mode no-mistakes >/dev/null 2>&1 || echo "fm-brief failed for $2"
  echo "$home/data/brief-live-$2/brief.md"
}

echo "=== B1 ship brief # Project memory section: base (8facd7c) ==="
b=$(gen "$SCR/base" base); section "$b" "$SCR/base"
echo
echo "=== B1 ship brief # Project memory section: target (50c8a38) ==="
t=$(gen "$WT" target); section "$t" "$WT"

echo
echo "=== B2 worker follows the target brief in a repo whose only guide is CLAUDE.md ==="
p="$SCR/proj"; mkdir -p "$p"; git -C "$p" init -q
git -C "$p" config user.email t@example.invalid; git -C "$p" config user.name tester
printf '# Project guide\n\nRun tests with make test.\n' > "$p/CLAUDE.md"
printf 'code\n' > "$p/app.txt"
git -C "$p" add -A; git -C "$p" commit -qm seed
# The unrelated task work itself:
printf 'code v2\n' > "$p/app.txt"
# shellcheck disable=SC2016
cmd=$(sed -n 's/^If this task produced durable project-intrinsic knowledge, run `\([^`]*\)` in the worktree.*/\1/p' "$t")
echo "  command extracted from the brief: ${cmd//$WT/<FM_ROOT>}"
out=$(cd "$p" && eval "$cmd" 2>&1); rc=$?
echo "  [exit $rc]"; printf '%s\n' "$out" | sed "s#$SCR#<tmp>#g; s/^/    | /"
guide=$(printf '%s\n' "$out" | sed -n 's/^guide: //p')
printf '%s\n' '- Seed data lives in fixtures/seed.sql.' >> "$guide"
git -C "$p" add -A
echo "  staged change set after task work + recorded knowledge (git diff --cached --stat -M):"
git -C "$p" diff --cached --stat -M | sed 's/^/    /'
echo "  git diff --cached --name-status -M:"
git -C "$p" diff --cached --name-status -M | sed 's/^/    /'
echo "  AGENTS.md exists: $([ -e "$p/AGENTS.md" ] && echo yes || echo no)"

echo
echo "=== B3 same worker flow with the base brief + base helper (the reported failure) ==="
p="$SCR/proj-base"; mkdir -p "$p"; git -C "$p" init -q
git -C "$p" config user.email t@example.invalid; git -C "$p" config user.name tester
printf '# Project guide\n\nRun tests with make test.\n' > "$p/CLAUDE.md"
printf 'code\n' > "$p/app.txt"
git -C "$p" add -A; git -C "$p" commit -qm seed
printf 'code v2\n' > "$p/app.txt"
# shellcheck disable=SC2016
cmd=$(sed -n 's/^If `AGENTS.md` or `CLAUDE.md` already exists.*run `\([^`]*\)` in the worktree.*/\1/p' "$b")
echo "  command extracted from the base brief: ${cmd//$SCR\/base/<FM_ROOT>}"
out=$(cd "$p" && eval "$cmd" 2>&1); rc=$?
echo "  [exit $rc]"; printf '%s\n' "$out" | sed "s#$SCR#<tmp>#g; s/^/    | /"
git -C "$p" add -A
echo "  staged change set (git diff --cached --name-status -M):"
git -C "$p" diff --cached --name-status -M | sed 's/^/    /'

rm -rf "$SCR"
