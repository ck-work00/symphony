#!/usr/bin/env bash
# Post a comment to a Linear issue.
# Usage: linear-comment.sh <body>
# Requires: $LINEAR_API_KEY, $ISSUE_ID

set -euo pipefail

BODY="${1:?Usage: linear-comment.sh <body>}"

if [[ -z "${LINEAR_API_KEY:-}" ]]; then
  echo "ERROR: LINEAR_API_KEY not set" >&2
  exit 1
fi

if [[ -z "${ISSUE_ID:-}" ]]; then
  echo "ERROR: ISSUE_ID not set" >&2
  exit 1
fi

# Escape the body for JSON
ESCAPED_BODY=$(echo "$BODY" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')

curl -s -X POST https://api.linear.app/graphql \
  -H "Content-Type: application/json" \
  -H "Authorization: ${LINEAR_API_KEY}" \
  -d "{\"query\":\"mutation { commentCreate(input: { issueId: \\\"${ISSUE_ID}\\\", body: ${ESCAPED_BODY} }) { success } }\"}"
