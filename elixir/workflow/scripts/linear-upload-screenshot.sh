#!/usr/bin/env bash
# Upload a screenshot to Linear and return the asset URL.
# Usage: linear-upload-screenshot.sh <file-path>
# Requires: $LINEAR_API_KEY_AUTOMATION, $ISSUE_ID
# Returns: asset URL on stdout

set -euo pipefail

FILE="${1:?Usage: linear-upload-screenshot.sh <file-path>}"

if [[ -z "${LINEAR_API_KEY_AUTOMATION:-}" ]]; then
  echo "ERROR: LINEAR_API_KEY_AUTOMATION not set" >&2
  exit 1
fi

if [[ -z "${ISSUE_ID:-}" ]]; then
  echo "ERROR: ISSUE_ID not set" >&2
  exit 1
fi

if [[ ! -f "$FILE" ]]; then
  echo "ERROR: File not found: $FILE" >&2
  exit 1
fi

FILENAME=$(basename "$FILE")
CONTENT_TYPE="image/png"
FILE_SIZE=$(wc -c < "$FILE" | tr -d ' ')

# Step 1: Request upload URL from Linear
UPLOAD_RESPONSE=$(curl -s -X POST https://api.linear.app/graphql \
  -H "Content-Type: application/json" \
  -H "Authorization: ${LINEAR_API_KEY_AUTOMATION}" \
  -d "{\"query\":\"mutation { fileUpload(contentType: \\\"${CONTENT_TYPE}\\\", filename: \\\"${FILENAME}\\\", size: ${FILE_SIZE}) { success uploadFile { uploadUrl assetUrl } } }\"}")

UPLOAD_URL=$(echo "$UPLOAD_RESPONSE" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['data']['fileUpload']['uploadFile']['uploadUrl'])" 2>/dev/null)
ASSET_URL=$(echo "$UPLOAD_RESPONSE" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['data']['fileUpload']['uploadFile']['assetUrl'])" 2>/dev/null)

if [[ -z "$UPLOAD_URL" || -z "$ASSET_URL" ]]; then
  echo "ERROR: Failed to get upload URL from Linear" >&2
  echo "$UPLOAD_RESPONSE" >&2
  exit 1
fi

# Step 2: Upload the file
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$UPLOAD_URL" \
  -H "Content-Type: ${CONTENT_TYPE}" \
  -H "Cache-Control: public, max-age=31536000" \
  --data-binary "@${FILE}")

if [[ "$HTTP_STATUS" != "200" && "$HTTP_STATUS" != "201" ]]; then
  echo "ERROR: Upload failed with HTTP status $HTTP_STATUS" >&2
  exit 1
fi

# Step 3: Return the asset URL
echo "$ASSET_URL"
