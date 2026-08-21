#!/usr/bin/env bash
# Re-syncs the usage rules vendored from dependencies and fails if the result
# differs from what is committed. Keeps .rules/ honest as deps are upgraded.
set -euo pipefail

mix usage_rules.sync .rules/usage-rules.md --all --link-to-folder .rules --yes >/dev/null

if ! git diff --quiet --exit-code -- .rules || [ -n "$(git ls-files --others --exclude-standard .rules)" ]; then
  echo "Vendored usage rules are out of date."
  echo
  git --no-pager diff --stat -- .rules
  git ls-files --others --exclude-standard .rules | sed 's/^/  new file: /'
  echo
  echo "Run: mix usage_rules.sync .rules/usage-rules.md --all --link-to-folder .rules --yes"
  exit 1
fi

echo "Vendored usage rules are up to date."
