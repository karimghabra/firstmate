#!/usr/bin/env bash
# Live driver: runs bin/fm-ensure-agents-md.sh (target) and the base-commit
# helper against fresh git project fixtures and prints a transcript of the
# resulting file layout for each guide shape.
set -u
WT=/home/mars/.no-mistakes/worktrees/a8c0c72d0935/01M28052W3RM6R1YPGVSBKVPD8
NEW="$WT/bin/fm-ensure-agents-md.sh"
BASE="$1"
SCRATCH="$2"

layout() {
  local d=$1
  (cd "$d" && for f in AGENTS.md agents.md CLAUDE.md; do
    if [ -L "$f" ]; then echo "    $f -> symlink to $(readlink "$f")";
    elif [ -f "$f" ]; then echo "    $f (regular file, $(wc -l < "$f") lines, maint-sections=$(grep -c '^## Maintaining this file' "$f"))";
    fi
  done)
  echo "    git status: $(cd "$d" && git status --porcelain | tr '\n' ' ')"
}

mkproj() {
  local d=$1
  rm -rf "$d"; mkdir -p "$d"
  (cd "$d" && git init -q && git config user.email t@t && git config user.name t)
}

commit() { (cd "$1" && git add -A && git commit -qm seed); }

setup_case() {
  local name=$1 d=$2
  mkproj "$d"
  case "$name" in
    claude-only)
      printf '# Project guide\n\nRun tests with make test.\nDeploy with ./deploy.sh.\n' > "$d/CLAUDE.md" ;;
    claude-only-crlf)
      printf '# Project guide\r\n\r\nRun tests with make test.\r\n' > "$d/CLAUDE.md" ;;
    claude-only-marked)
      printf '<!-- firstmate:maintained-by-project -->\n# Guide\n\nOwn maintenance rules.\n' > "$d/CLAUDE.md" ;;
    claude-symlink)
      printf '# Agents guide\n\nUse pnpm.\n' > "$d/AGENTS.md"; ln -s AGENTS.md "$d/CLAUDE.md" ;;
    agents-only)
      printf '# Agents guide\n\nUse pnpm.\n' > "$d/AGENTS.md" ;;
    none)
      printf 'hello\n' > "$d/README.md" ;;
    pointer-only)
      printf '<!-- Points Claude at AGENTS.md via import; edit AGENTS.md, not this file. -->\n@AGENTS.md\n' > "$d/CLAUDE.md" ;;
    both-real)
      printf '# Agents\n' > "$d/AGENTS.md"; printf '# Claude\n' > "$d/CLAUDE.md" ;;
    lowercase-agents)
      printf '# agents lower\n' > "$d/agents.md"; printf '# Claude guide\n' > "$d/CLAUDE.md" ;;
    wrong-symlink)
      printf '# Other\n' > "$d/OTHER.md"; printf '# Agents\n' > "$d/AGENTS.md"; ln -s OTHER.md "$d/CLAUDE.md" ;;
  esac
  commit "$d"
}

run_case() {
  local name=$1 helper=$2 label=$3
  local d="$SCRATCH/$label-$name"
  setup_case "$name" "$d"
  echo "=== [$label] case: $name"
  echo "  before:"; layout "$d"
  local out rc
  out=$(cd "$d" && "$helper" . 2>&1); rc=$?
  echo "  \$ fm-ensure-agents-md.sh .   (exit $rc)"
  printf '%s\n' "$out" | sed 's/^/    | /'
  echo "  after:"; layout "$d"
}

for c in claude-only claude-only-crlf claude-only-marked claude-symlink agents-only none pointer-only both-real lowercase-agents wrong-symlink; do
  run_case "$c" "$BASE" base
  run_case "$c" "$NEW" target
  echo
done
