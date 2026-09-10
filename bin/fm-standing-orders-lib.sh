# shellcheck shell=bash
# fm-standing-orders-lib.sh - the captain's standing-orders marker contract.
#
# The captain's standing orders live in data/captain-shared.md, strictly
# between the two literal marker lines below, each of which may carry trailing
# whitespace or a CRLF ending. The file must hold exactly one well-formed pair.
# Every other shape is malformed input rather than an opt-out, including a
# BEGIN with no matching END, a second BEGIN, a duplicated pair, and an END
# with no open BEGIN. An absent file, absent markers, or a blank body are not
# defects: they are the ordinary no-op for a home that keeps no standing
# orders.
# This file is the ONE owner of that shape, so bin/fm-brief.sh (which inlines
# the body into ship and scout briefs) and the propagation boundary in
# bin/fm-config-inherit-lib.sh and bin/fm-remote-inherit-push.sh (which refuse
# to copy a malformed file into a secondmate home) cannot drift apart.
# Neither entry point writes to stderr: each caller owns its own diagnostic
# channel and formats the returned defect into it.
# No side effects on source. set -u / set -e safe.

FM_STANDING_ORDERS_BEGIN_MARKER='<!-- FM_STANDING_ORDERS_BEGIN -->'
FM_STANDING_ORDERS_END_MARKER='<!-- FM_STANDING_ORDERS_END -->'

_fm_standing_orders_scan() {  # <file> <body|defect>
  awk -v want="$2" \
    -v begin_marker="$FM_STANDING_ORDERS_BEGIN_MARKER" \
    -v end_marker="$FM_STANDING_ORDERS_END_MARKER" '
    { marker = $0; sub(/\r$/, "", marker); sub(/[[:blank:]]+$/, "", marker) }
    marker == begin_marker {
      if (begins) problem = "a second " begin_marker " marker"
      begins++; in_block = 1; next
    }
    marker == end_marker {
      if (!in_block) problem = "a " end_marker " marker with no open " begin_marker
      in_block = 0; next
    }
    in_block { if (want == "body") { sub(/\r$/, ""); print } }
    END {
      if (in_block && !problem) problem = "an unterminated " begin_marker " marker with no matching " end_marker
      if (problem) {
        if (want == "defect") print problem
        exit 1
      }
    }
  ' "$1"
}

# Print the marked body with each line stripped of a trailing CR, so the
# result is pure LF whatever the source file's line endings are. Returns 1
# without printing a diagnostic when the file is malformed; an absent file or
# an absent marker pair yields empty output and success.
fm_standing_orders_body() {  # <file>
  [ -f "$1" ] || return 0
  _fm_standing_orders_scan "$1" body
}

# Print the file's specific marker defect and return 0 when one exists, so a
# caller reads it as "if this file has a defect". Returns 1 when the file is
# absent or its marker shape is sound.
fm_standing_orders_defect() {  # <file>
  local defect
  [ -f "$1" ] || return 1
  defect=$(_fm_standing_orders_scan "$1" defect) && return 1
  printf '%s\n' "$defect"
}
