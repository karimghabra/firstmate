#!/usr/bin/env bash
# Live driver: run the real bin/fm-ensure-agents-md.sh (target commit) and the
# base-commit helper against isolated git repositories, showing git status and
# file layout after each run.
set -u
WT=/home/mars/.no-mistakes/worktrees/a8c0c72d0935/01M27J3PJGC4TE9T9N1M2YHTKC
NEW="$WT/bin/fm-ensure-agents-md.sh"
SCR=$(mktemp -d /tmp/fm-ensure-live.XXXXXX)
OLD="$SCR/base-fm-ensure-agents-md.sh"
git -C "$WT" show 8facd7c:bin/fm-ensure-agents-md.sh > "$OLD"
chmod +x "$OLD"

newrepo() {
  local d="$SCR/$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email t@example.invalid
  git -C "$d" config user.name tester
  printf 'app\n' > "$d/main.txt"
  echo "$d"
}
commit_all() { git -C "$1" add -A && git -C "$1" commit -qm seed; }
layout() {
  local d=$1
  echo "  layout:"
  for f in AGENTS.md CLAUDE.md; do
    if [ -L "$d/$f" ]; then echo "    $f -> $(readlink "$d/$f") (symlink)"
    elif [ -f "$d/$f" ]; then echo "    $f (regular file, $(wc -l < "$d/$f") lines)"
    else echo "    $f (absent)"; fi
  done
  echo "  git status --short:"
  git -C "$d" status --short | sed 's/^/    /'
}
run() {
  local label=$1 helper=$2 d=$3 out rc
  out=$(cd "$d" && "$helper" . 2>&1); rc=$?
  echo "  \$ ($label) fm-ensure-agents-md.sh .   [exit $rc]"
  printf '%s\n' "$out" | sed "s#$SCR#<tmp>#g; s/^/    | /"
}
hr() { echo; echo "=== $* ==="; }

hr "S1 regression: project whose only guide is a real CLAUDE.md"
for which in base target; do
  d=$(newrepo "s1-$which")
  printf '# Project guide\n\nRun tests with make test.\n' > "$d/CLAUDE.md"
  commit_all "$d"
  if [ "$which" = base ]; then h=$OLD; else h=$NEW; fi
  echo "-- $which helper ($([ $which = base ] && echo 8facd7c || echo 50c8a38)) --"
  run "$which" "$h" "$d"
  layout "$d"
  if [ "$which" = target ]; then
    echo "  CLAUDE.md content after run:"; sed 's/^/    > /' "$d/CLAUDE.md"
    echo "  second run (idempotence):"
    run "$which" "$h" "$d"
    layout "$d"
  fi
done

hr "S2 AGENTS.md with a working CLAUDE.md -> AGENTS.md symlink"
for which in base target; do
  d=$(newrepo "s2-$which")
  printf '# Agents\n\n- note\n' > "$d/AGENTS.md"
  ln -s AGENTS.md "$d/CLAUDE.md"
  commit_all "$d"
  if [ "$which" = base ]; then h=$OLD; else h=$NEW; fi
  echo "-- $which helper --"
  run "$which" "$h" "$d"
  layout "$d"
done

hr "S3 AGENTS.md only: pointer is added, nothing moves"
d=$(newrepo s3)
printf '# Agents\n\n- note\n' > "$d/AGENTS.md"
commit_all "$d"
run target "$NEW" "$d"
layout "$d"
echo "  CLAUDE.md content:"; sed 's/^/    > /' "$d/CLAUDE.md"
echo "  git diff AGENTS.md (only the self-governance section appended):"
git -C "$d" diff AGENTS.md | sed 's/^/    /'

hr "S4 project with no guide: AGENTS.md skeleton + CLAUDE.md pointer created"
d=$(newrepo s4); commit_all "$d"
run target "$NEW" "$d"
layout "$d"

hr "S5 canonical CLAUDE.md pointer but no AGENTS.md: skeleton created, pointer kept"
d=$(newrepo s5)
printf '%s\n' '<!-- Points Claude at AGENTS.md via import; edit AGENTS.md, not this file. -->' '@AGENTS.md' > "$d/CLAUDE.md"
commit_all "$d"
run target "$NEW" "$d"
layout "$d"

hr "S6 adversarial: refusals leave the tree untouched"
d=$(newrepo s6a)
printf '# A\n' > "$d/AGENTS.md"; printf '# C\n' > "$d/CLAUDE.md"; commit_all "$d"
echo "-- distinct real AGENTS.md and CLAUDE.md --"
run target "$NEW" "$d"; layout "$d"
d=$(newrepo s6b)
printf '# A\n' > "$d/AGENTS.md"; printf '# other\n' > "$d/OTHER.md"; ln -s OTHER.md "$d/CLAUDE.md"; commit_all "$d"
echo "-- CLAUDE.md symlink to a different file --"
run target "$NEW" "$d"; layout "$d"
d=$(newrepo s6c)
printf '# lower\n' > "$d/agents.md"; commit_all "$d"
echo "-- lowercase agents.md --"
run target "$NEW" "$d"; layout "$d"

hr "S7 project-owned mark on a real CLAUDE.md: byte-for-byte unchanged, stays in place"
d=$(newrepo s7)
printf '<!-- firstmate:maintained-by-project -->\r\n# Guide\r\n\r\nOur own upkeep rules.\r\n' > "$d/CLAUDE.md"
commit_all "$d"
run target "$NEW" "$d"
layout "$d"

hr "S8 CRLF real CLAUDE.md without the section: section appended with CRLF, stays in place"
d=$(newrepo s8)
printf '# Guide\r\n\r\nBuild with make.\r\n' > "$d/CLAUDE.md"
commit_all "$d"
run target "$NEW" "$d"
layout "$d"
echo "  lines lacking CRLF: $(grep -vc $'\r$' "$d/CLAUDE.md")"

hr "S9 removed --migrate-layout flag is not a relocation path"
d=$(newrepo s9)
printf '# Project guide\n\nRun tests with make test.\n' > "$d/CLAUDE.md"
commit_all "$d"
out=$(cd "$d" && "$NEW" --migrate-layout 2>&1); echo "  \$ fm-ensure-agents-md.sh --migrate-layout   [exit $?]"; printf '%s\n' "$out" | sed 's/^/    | /'
out=$(cd "$d" && "$NEW" --migrate-layout . 2>&1); echo "  \$ fm-ensure-agents-md.sh --migrate-layout .   [exit $?]"; printf '%s\n' "$out" | sed 's/^/    | /'
layout "$d"
echo "  --help mentions migrate: $("$NEW" --help 2>&1 | grep -ci migrat)"
echo "  --help text:"; "$NEW" --help 2>&1 | sed 's/^/    | /'

rm -rf "$SCR"
