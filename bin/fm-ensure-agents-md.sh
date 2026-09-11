#!/usr/bin/env bash
# Ensure a project worktree has an agent guide - the committed file holding
# project-intrinsic agent knowledge - without restructuring one it already has.
# The convention for a new guide is a real AGENTS.md plus a real regular
# CLAUDE.md whose canonical content is the two-line @AGENTS.md pointer that
# Claude Code inlines at load time.
# Default mode adds guide files only when the project has no working guide: it
# creates the AGENTS.md skeleton and the CLAUDE.md pointer when neither file
# exists, when CLAUDE.md is only the canonical pointer, or when CLAUDE.md is a
# correct symlink to a missing AGENTS.md. When a working guide exists - a real
# AGENTS.md, or a real CLAUDE.md that is not the pointer - it keeps every guide
# file at its existing path: it never adds, moves, renames, or replaces one,
# and only ensures the self-governance section below in that guide.
# Relocating or restructuring a working guide is a change of its own, never a
# side effect of unrelated work, so it runs only under the explicit
# --migrate-layout flag: that promotes a real CLAUDE.md to AGENTS.md and writes
# the pointer in its place, adds the pointer beside an AGENTS.md without one,
# and converts a correct CLAUDE.md -> AGENTS.md symlink into the pointer file.
# Every success ends with one "guide: <absolute path>" line naming the file to
# record durable project knowledge in. Both modes refuse to clobber distinct
# real files or wrong symlinks.
# Owns the canonical "## Maintaining this file" self-governance wording for
# project guides, injecting it idempotently into created skeletons, promoted
# CLAUDE.md files, and existing guides lacking both the exact heading and the
# project-owned mark below (exact first line, LF or CRLF):
# <!-- firstmate:maintained-by-project -->
# Projects may place this mark at the start of the file and retain equivalent
# maintenance guidance under their own heading. It declares guidance is present, not
# permission to remove governance. No prose equivalence is inferred.
# Owns the canonical CLAUDE.md pointer content (the exact two-line @AGENTS.md
# form). A real-file pointer cannot follow a write into AGENTS.md, which is why
# the installer never creates a CLAUDE.md symlink.
# Refuses a case-variant real memory file such as a lowercase agents.md, so the
# pointer's @AGENTS.md import resolves to a real AGENTS.md on a case-sensitive
# filesystem (issue #389). The real-file pointer also eliminates the old
# uppercase-literal-target dangling-symlink hazard that a CLAUDE.md -> AGENTS.md
# link would have carried for that same mismatch.
# This is a worktree utility for crewmates, not a supervision script, so it does
# not call fm-guard.sh.
# Usage: fm-ensure-agents-md.sh [--migrate-layout] [repo-or-worktree-dir]
set -eu

usage() {
  echo "usage: fm-ensure-agents-md.sh [--migrate-layout] [repo-or-worktree-dir]" >&2
  cat >&2 <<'EOF'

By default the helper creates AGENTS.md and a CLAUDE.md @AGENTS.md pointer only
when the project has no agent guide, and otherwise keeps the existing guide at
its path, only adding the self-governance section to it. The final
"guide: <path>" line names the file to record durable project knowledge in.

--migrate-layout  also relocate an existing guide to the AGENTS.md convention:
                  move a real CLAUDE.md to AGENTS.md, add a missing pointer, or
                  replace a CLAUDE.md symlink with the pointer. Use it only for
                  a change whose purpose is that relocation.

To retain equivalent project-owned maintenance guidance without adding the
canonical section, use this exact first line of the guide (LF or CRLF):
<!-- firstmate:maintained-by-project -->
The mark declares retained guidance, not permission to remove governance.
Without the first-line mark or exact canonical heading, the helper adds the section.
EOF
}

MIGRATE=0
DIR=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --migrate-layout)
      MIGRATE=1
      ;;
    -*)
      usage
      exit 1
      ;;
    *)
      [ -z "$DIR" ] || { usage; exit 1; }
      DIR=$1
      ;;
  esac
  shift
done

DIR=${DIR:-.}
[ -d "$DIR" ] || { echo "error: not a directory: $DIR" >&2; exit 1; }
DIR=$(cd "$DIR" && pwd -P)
cd "$DIR"

AGENTS=AGENTS.md
CLAUDE=CLAUDE.md

write_maintenance_section() {
  cat <<'EOF'
## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
EOF
}

write_maintenance_section_with_eol() {
  local eol=$1 line
  while IFS= read -r line; do
    printf '%s%s' "$line" "$eol"
  done < <(write_maintenance_section)
}

# Idempotently append the canonical self-governance section to the guide file
# passed as $1 when neither its heading nor the first-line project-owned mark is
# present. Sets MAINT_INJECTED=1 when it appends and 0 otherwise, for caller
# change reporting.
MAINT_INJECTED=0
ensure_maintenance_section() {
  local guide=$1
  MAINT_INJECTED=0
  if grep -Fqx -e '## Maintaining this file' -e $'## Maintaining this file\r' "$guide" ||
    head -n 1 "$guide" | grep -Fqx -e '<!-- firstmate:maintained-by-project -->' \
      -e $'<!-- firstmate:maintained-by-project -->\r'; then
    return 0
  fi
  local eol=$'\n' sep=''
  if LC_ALL=C grep -q $'\r$' "$guide"; then
    eol=$'\r\n'
  fi
  if [ -s "$guide" ]; then
    if [ -n "$(tail -c 1 "$guide")" ]; then
      sep="${eol}${eol}"
    else
      sep=$eol
    fi
  fi
  {
    printf '%s' "$sep"
    write_maintenance_section_with_eol "$eol"
  } >> "$guide"
  MAINT_INJECTED=1
}

# Report a kept guide's self-governance result, then name it and stop.
finish_kept_guide() {
  local guide=$1
  if [ "$MAINT_INJECTED" -eq 1 ]; then
    echo "updated: added ## Maintaining this file to $guide in $DIR"
  else
    echo "unchanged: $guide in $DIR"
  fi
  finish "$guide"
}

# Name the guide file to record durable project knowledge in, then stop.
finish() {
  echo "guide: $DIR/$1"
  exit 0
}

write_skeleton() {
  cat > "$AGENTS" <<'EOF'
# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.
EOF
  ensure_maintenance_section "$AGENTS"
}

# Canonical CLAUDE.md pointer: a real file, never a symlink. Byte-identical
# two-line form so a stray write clobbers only this recoverable pointer.
claude_pointer_content() {
  cat <<'EOF'
<!-- Points Claude at AGENTS.md via import; edit AGENTS.md, not this file. -->
@AGENTS.md
EOF
}

is_canonical_claude_pointer() {
  [ -f "$CLAUDE" ] && [ ! -L "$CLAUDE" ] || return 1
  claude_pointer_content | cmp -s - "$CLAUDE"
}

# Write the canonical pointer as a regular file. Unlink a symlink first so the
# write cannot follow it and destroy AGENTS.md. Never overwrite a distinct real
# file; callers classify that as a conflict before invoking this.
install_claude_pointer() {
  if is_canonical_claude_pointer; then
    return 0
  fi
  if [ -L "$CLAUDE" ]; then
    rm -- "$CLAUDE"
  elif [ -e "$CLAUDE" ]; then
    echo "error: internal: refuse to overwrite existing CLAUDE.md" >&2
    exit 1
  fi
  claude_pointer_content > "$CLAUDE"
}

is_correct_claude_symlink() {
  [ -L "$CLAUDE" ] || return 1
  target=$(readlink "$CLAUDE")
  case "$target" in
    "$AGENTS"|"./$AGENTS") return 0 ;;
  esac
  [ -e "$AGENTS" ] || return 1
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$CLAUDE" "$AGENTS" <<'PY'
import os
import sys
sys.exit(0 if os.path.realpath(sys.argv[1]) == os.path.realpath(sys.argv[2]) else 1)
PY
    return $?
  fi
  return 1
}

# Refuse a case-variant real memory file (issue #389). On a case-insensitive
# filesystem an existing lowercase agents.md satisfies every [ -e AGENTS.md ]
# test below, so the script would emit a CLAUDE.md pointer whose @AGENTS.md
# import dangles once the tree is checked out on a case-sensitive filesystem.
# Reading the real directory entries catches the mismatch on both filesystem
# kinds; surface it for manual reconciliation instead of writing the pointer
# against the wrong name.
for entry in *; do
  if [ ! -e "$entry" ] && [ ! -L "$entry" ]; then
    continue
  fi
  if [ "$entry" != "$AGENTS" ]; then
    case "$entry" in
      [Aa][Gg][Ee][Nn][Tt][Ss].[Mm][Dd])
        echo "conflict: memory file is named $entry in $DIR but the convention is AGENTS.md; record knowledge by hand in $entry where it is, and rename it to AGENTS.md only in a change of its own so CLAUDE.md's @AGENTS.md pointer resolves portably" >&2
        exit 1
        ;;
    esac
  fi
done

if [ -L "$AGENTS" ]; then
  echo "conflict: AGENTS.md is a symlink in $DIR; expected AGENTS.md to be the real file" >&2
  exit 1
fi
if [ -e "$AGENTS" ] && [ ! -f "$AGENTS" ]; then
  echo "conflict: AGENTS.md exists in $DIR but is not a regular file" >&2
  exit 1
fi

if [ -e "$AGENTS" ]; then
  if [ -L "$CLAUDE" ]; then
    if is_correct_claude_symlink; then
      ensure_maintenance_section "$AGENTS"
      [ "$MIGRATE" -eq 1 ] || finish_kept_guide "$AGENTS"
      install_claude_pointer
      if [ "$MAINT_INJECTED" -eq 1 ]; then
        echo "updated: added ## Maintaining this file to AGENTS.md and wrote CLAUDE.md @AGENTS.md pointer in $DIR"
      else
        echo "updated: replaced CLAUDE.md symlink with @AGENTS.md pointer in $DIR"
      fi
      finish "$AGENTS"
    fi
    echo "conflict: CLAUDE.md is a symlink in $DIR but does not point to AGENTS.md" >&2
    exit 1
  fi
  if [ ! -e "$CLAUDE" ]; then
    ensure_maintenance_section "$AGENTS"
    [ "$MIGRATE" -eq 1 ] || finish_kept_guide "$AGENTS"
    install_claude_pointer
    if [ "$MAINT_INJECTED" -eq 1 ]; then
      echo "updated: added ## Maintaining this file to AGENTS.md and wrote CLAUDE.md @AGENTS.md pointer in $DIR"
    else
      echo "wrote: CLAUDE.md @AGENTS.md pointer in $DIR"
    fi
    finish "$AGENTS"
  fi
  if [ -f "$CLAUDE" ]; then
    if is_canonical_claude_pointer; then
      ensure_maintenance_section "$AGENTS"
      if [ "$MAINT_INJECTED" -eq 1 ]; then
        echo "updated: added ## Maintaining this file to AGENTS.md in $DIR"
      else
        echo "unchanged: AGENTS.md with CLAUDE.md @AGENTS.md pointer in $DIR"
      fi
      finish "$AGENTS"
    fi
    echo "conflict: both AGENTS.md and CLAUDE.md are real guide files in $DIR; record knowledge by hand in the one the project uses for it, and merge them only in a change of its own" >&2
    exit 1
  fi
  echo "conflict: CLAUDE.md exists in $DIR but is not a regular file or symlink" >&2
  exit 1
fi

# From here AGENTS.md is absent. A CLAUDE.md that only points at the missing
# AGENTS.md, by symlink or canonical pointer, is not a working guide, so these
# are creation cases; a real CLAUDE.md with its own content is the project's
# working guide and stays where it is unless --migrate-layout asks otherwise.
if [ -L "$CLAUDE" ]; then
  if is_correct_claude_symlink; then
    write_skeleton
    install_claude_pointer
    echo "created: AGENTS.md and wrote CLAUDE.md @AGENTS.md pointer in $DIR"
    finish "$AGENTS"
  fi
  echo "conflict: CLAUDE.md is a symlink in $DIR but AGENTS.md is missing and the link does not point to AGENTS.md" >&2
  exit 1
fi

if [ -e "$CLAUDE" ]; then
  if [ -f "$CLAUDE" ]; then
    if is_canonical_claude_pointer; then
      write_skeleton
      echo "created: AGENTS.md and kept CLAUDE.md @AGENTS.md pointer in $DIR"
      finish "$AGENTS"
    fi
    if [ "$MIGRATE" -eq 0 ]; then
      ensure_maintenance_section "$CLAUDE"
      finish_kept_guide "$CLAUDE"
    fi
    mv "$CLAUDE" "$AGENTS"
    ensure_maintenance_section "$AGENTS"
    install_claude_pointer
    echo "promoted: moved CLAUDE.md to AGENTS.md and wrote CLAUDE.md @AGENTS.md pointer in $DIR"
    finish "$AGENTS"
  fi
  echo "conflict: CLAUDE.md exists in $DIR but is not a regular file or symlink" >&2
  exit 1
fi

write_skeleton
install_claude_pointer
echo "created: AGENTS.md and CLAUDE.md @AGENTS.md pointer in $DIR"
finish "$AGENTS"
