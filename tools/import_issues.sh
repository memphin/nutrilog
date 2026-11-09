#!/usr/bin/env bash
# Import backlog/issues.json into the current GitHub repo as labels, milestones and issues.
# Requires: gh (authenticated), jq. Run from repo root. Idempotent for labels/milestones; issues are created once (checks title).
set -euo pipefail
FILE="${1:-backlog/issues.json}"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

# label:color pairs (plain list instead of an associative array so it runs on macOS bash 3.2)
LABELS="core:1d76db persistence:0e8a16 ui:fbca04 healthkit:d93f0b scanner:5319e7 food-sources:c2e0c6 intents:bfd4f2 ci:000000 phase-1:ededed phase-2:ededed phase-3:ededed nice-to-have:f9d0c4"
for pair in $LABELS; do gh label create "${pair%%:*}" --color "${pair##*:}" --force >/dev/null; done

jq -r '.[].m' "$FILE" | sort -u | while read -r m; do
  if ! gh api "repos/$REPO/milestones?state=all" -q '.[].title' | grep -Fxq "$m"; then
    gh api -X POST "repos/$REPO/milestones" -f title="$m" >/dev/null && echo "milestone: $m"
  fi
done

existing="$(gh issue list --state all --limit 500 --json title -q '.[].title')"
jq -c '.[]' "$FILE" | while read -r row; do
  title="$(jq -r .t <<<"$row")"
  if grep -Fxq "$title" <<<"$existing"; then echo "skip (exists): $title"; continue; fi
  labels="$(jq -r '.l | join(",")' <<<"$row")"
  milestone="$(jq -r .m <<<"$row")"
  body="$(jq -r .b <<<"$row")"
  gh issue create --title "$title" --body "$body" --label "$labels" --milestone "$milestone" >/dev/null
  echo "created: $title"
done
