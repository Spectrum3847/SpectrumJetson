#!/usr/bin/env bash
# shellcheck on every shell script and pyflakes on every Python file in the repo: real mistakes
# only (unquoted cd, unused imports, typos in variable names), not style. Run on the laptop, or by
# .github/workflows/lint.yml on every push. Needs shellcheck and pyflakes (apt install shellcheck
# python3-pyflakes). Exits 1 on any finding.
#
# Not flagged, on purpose:
#   SC2088  ~ inside quotes: our SSH commands mean the Jetson's home, expanded there
#   SC2034  "unused" variables read by eval'd checks (the tests' check "label" "condition")
#   SC1091  config.env and other sourced files aren't followed
#   SC2024  sudo with a redirect: the file is the user's own on purpose
set -uo pipefail
cd "$(dirname "$0")/../.."
rc=0
mapfile -t sh < <(git ls-files '*.sh')
mapfile -t py < <(git ls-files '*.py')
echo "shellcheck: ${#sh[@]} scripts"
shellcheck -S warning -e SC2088,SC2034,SC1091,SC2024 "${sh[@]}" || rc=1
echo "pyflakes: ${#py[@]} files"
pyflakes="pyflakes3"; command -v pyflakes3 >/dev/null || pyflakes="python3 -m pyflakes"
$pyflakes "${py[@]}" || rc=1
((rc == 0)) && echo "lint: clean" || echo "lint: findings above"
exit "$rc"
