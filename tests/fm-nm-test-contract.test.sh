#!/usr/bin/env bash
# Contract: the parsed, tracked .no-mistakes.yaml keeps firstmate's gate posture.
# - commands.test stays absent or empty, so local Test stays intent-targeted.
# - disable_project_settings stays true, so gate agents never adopt AGENTS.md.
# - auto_fix.ci stays 0 and ci.revalidate_repairs stays true, so no CI repair
#   agent edits this repository's shared tooling without supervision and review.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM="$ROOT/.no-mistakes.yaml"

# nm_value <key>... -> the Ruby inspect of the parsed value at that key path,
# or "absent" when any key on the path is missing. Inspect keeps types apart,
# so an integer 0 reads "0" while a quoted "0" reads "\"0\"".
nm_value() {
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .no-mistakes.yaml for this contract"
  ruby -ryaml -e '
node = YAML.load_file(ARGV.shift) || {}
ARGV.each do |key|
  unless node.is_a?(Hash) && node.key?(key)
    puts "absent"
    exit
  end
  node = node[key]
end
puts node.inspect
' "$NM" "$@" || fail "failed to parse .no-mistakes.yaml as YAML"
}

test_nm_has_no_deterministic_test_command() {
  local val
  val=$(nm_value commands test) || exit 1
  case "$val" in
    absent|nil|false|'""') ;;
    *) fail "commands.test must be absent or empty so Test stays intent-targeted; got: $val" ;;
  esac
  pass "no-mistakes does not configure commands.test"
}

test_nm_disables_project_settings() {
  local val
  val=$(nm_value disable_project_settings) || exit 1
  assert_equals true "$val" \
    "disable_project_settings must be boolean true so gate agents never adopt the fleet-captain identity"
  pass "no-mistakes gate agents run without project settings"
}

# An absent auto_fix.ci inherits the operator's global limit (default 3), and
# the legacy auto_fix.babysit alias applies only when ci is absent, so the
# contract requires an explicit integer 0.
test_nm_disables_automatic_ci_repair() {
  local val
  val=$(nm_value auto_fix ci) || exit 1
  assert_equals 0 "$val" \
    "auto_fix.ci must be the integer 0 so a red check parks for a decision instead of launching a CI repair agent"
  pass "no-mistakes never starts a CI repair round on its own"
}

test_nm_revalidates_every_ci_repair() {
  local val
  val=$(nm_value ci revalidate_repairs) || exit 1
  assert_equals true "$val" \
    "ci.revalidate_repairs must be boolean true so every CI repair re-passes Review before it is published"
  pass "no-mistakes revalidates every CI repair from Review"
}

test_nm_has_no_deterministic_test_command
test_nm_disables_project_settings
test_nm_disables_automatic_ci_repair
test_nm_revalidates_every_ci_repair
