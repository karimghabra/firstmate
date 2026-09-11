#!/usr/bin/env bash
# Drive bin/fm-ensure-agents-md.sh (target) and the base-commit copy against
# real git project fixtures, printing a transcript of each layout scenario.
# Usage: drive-helper-scenarios.sh <target-helper> <base-helper> <workdir>
set -u
TARGET=$1
BASE=$2
W=$3

show_tree() {
  local d=$1 f
  for f in AGENTS.md CLAUDE.md agents.md; do
    if [ -L "$d/$f" ]; then
      echo "    $f -> symlink to $(readlink "$d/$f")"
    elif [ -e "$d/$f" ]; then
      echo "    $f (regular file, $(wc -l < "$d/$f") lines, first line: $(head -n 1 "$d/$f" | tr -d '\r'))"
    fi
  done
  echo "    git status --porcelain:"
  (cd "$d" && git status --porcelain --untracked-files=all | sed 's/^/      /')
}

new_project() {
  local d=$1
  rm -rf "$d"
  mkdir -p "$d"
  (cd "$d" && git init -q && git config user.email t@t && git config user.name t && echo code > main.c && git add -A && git commit -qm init)
}

commit_all() {
  (cd "$1" && git add -A && git commit -qm fixture)
}

run_case() {
  local name=$1 setup=$2 who helper d rc out
  for who in base target; do
    helper=$TARGET
    [ "$who" = base ] && helper=$BASE
    d="$W/$name-$who"
    new_project "$d"
    (cd "$d" && eval "$setup")
    commit_all "$d"
    echo "--- [$who] $name"
    echo "  before:"
    show_tree "$d"
    out=$(cd "$d" && "$helper" . 2>&1)
    rc=$?
    echo "  \$ fm-ensure-agents-md.sh .   (exit $rc)"
    printf '%s\n' "$out" | sed 's/^/    | /'
    echo "  after:"
    show_tree "$d"
  done
  echo
}

echo "=== Scenario: project whose only guide is a real CLAUDE.md"
run_case real-claude-only 'printf "# Project guide\n\nRun tests with make test.\n" > CLAUDE.md'

echo "=== Scenario: AGENTS.md plus a correct CLAUDE.md -> AGENTS.md symlink"
run_case agents-plus-symlink 'printf "# Agents\n\nBuild with make.\n" > AGENTS.md; ln -s AGENTS.md CLAUDE.md'

echo "=== Scenario: AGENTS.md only, no CLAUDE.md"
run_case agents-only 'printf "# Agents\n\nBuild with make.\n" > AGENTS.md'

echo "=== Scenario: project with no guide at all"
run_case no-guide ':'

echo "=== Scenario: CLAUDE.md is only the canonical pointer, AGENTS.md missing"
run_case pointer-only 'printf "%s\n" "<!-- Points Claude at AGENTS.md via import; edit AGENTS.md, not this file. -->" "@AGENTS.md" > CLAUDE.md'

echo "=== Scenario: dangling correct CLAUDE.md -> AGENTS.md symlink, AGENTS.md missing"
run_case dangling-symlink 'ln -s AGENTS.md CLAUDE.md'

echo "=== Adversarial: CRLF real CLAUDE.md with no trailing newline"
run_case crlf-claude 'printf "# Guide\r\n\r\nUse pnpm." > CLAUDE.md'

echo "=== Adversarial: real CLAUDE.md carrying the project-owned first-line mark"
run_case marked-claude 'printf "%s\n" "<!-- firstmate:maintained-by-project -->" "# Guide" "" "## Our upkeep rules" "Keep it short." > CLAUDE.md'

echo "=== Adversarial: both AGENTS.md and a distinct real CLAUDE.md"
run_case both-real 'printf "# Agents\n" > AGENTS.md; printf "# Claude guide\n" > CLAUDE.md'

echo "=== Adversarial: lowercase agents.md plus real CLAUDE.md"
run_case lowercase-agents 'printf "# lower\n" > agents.md; printf "# Claude guide\n" > CLAUDE.md'

echo "=== Adversarial: CLAUDE.md symlink pointing somewhere other than AGENTS.md"
run_case wrong-symlink 'printf "# docs guide\n" > GUIDE.md; ln -s GUIDE.md CLAUDE.md'

echo "=== Idempotence: run the target helper twice on a real-CLAUDE.md project"
d="$W/idempotent"
new_project "$d"
(cd "$d" && printf '# Project guide\n\nRun tests with make test.\n' > CLAUDE.md)
commit_all "$d"
(cd "$d" && "$TARGET" . 2>&1 | sed 's/^/  first  | /')
sum1=$(sha256sum "$d/CLAUDE.md" | cut -d' ' -f1)
(cd "$d" && "$TARGET" . 2>&1 | sed 's/^/  second | /')
sum2=$(sha256sum "$d/CLAUDE.md" | cut -d' ' -f1)
echo "  CLAUDE.md sha256 after first run:  $sum1"
echo "  CLAUDE.md sha256 after second run: $sum2"
show_tree "$d"
echo

echo "=== Removed flag: --migrate-layout is no longer accepted by the target helper"
d="$W/migrate-flag"
new_project "$d"
(cd "$d" && printf '# Project guide\n' > CLAUDE.md)
commit_all "$d"
(cd "$d" && "$TARGET" --migrate-layout . 2>&1; echo "  (exit $?)") | sed 's/^/  | /'
show_tree "$d"
echo

echo "=== Help text of the target helper"
"$TARGET" --help 2>&1 | sed 's/^/  | /'
