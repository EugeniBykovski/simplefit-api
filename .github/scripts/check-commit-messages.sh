#!/bin/sh
# Validates commit headers in a range against the SimpleFit convention
# (docs/engineering-standards.md §3):
#
#   <type>: SF-<ticket> - <description>
#
# Usage: .github/scripts/check-commit-messages.sh <base-sha> <head-sha>
# Merge commits and GitHub "Revert ..." commits are exempt. No dependencies.
set -eu

base="$1"
head="$2"
pattern='^(feat|fix|refactor|test|docs|chore|build|ci|perf): SF-[0-9]+ - [^ ].*$'
failed=0

# Resolve the range first so an invalid range fails instead of passing empty.
commits=$(git rev-list --no-merges "$base..$head")

for sha in $commits; do
  header=$(git log -1 --format=%s "$sha")
  case "$header" in
    Revert\ *) continue ;;
  esac
  if ! printf '%s\n' "$header" | grep -Eq "$pattern" || [ "${#header}" -gt 100 ]; then
    echo "✖ $(git rev-parse --short "$sha"): $header"
    failed=1
  fi
done

if [ "$failed" -ne 0 ]; then
  echo "Commit headers must match '<type>: SF-<ticket> - <description>' (max 100 chars)."
  echo "Types: feat, fix, refactor, test, docs, chore, build, ci, perf."
  exit 1
fi

echo "✔ All commit headers in $base..$head follow the SimpleFit convention."
