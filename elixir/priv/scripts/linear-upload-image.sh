#!/usr/bin/env bash
set -euo pipefail

# Uploads an image to Linear and prints the permanent asset URL.
# Usage: linear-upload-image.sh <file>
# Requires: LINEAR_API_KEY or LINEAR_API_KEY_AUTOMATION env var

FILE="${1:?Usage: linear-upload-image.sh <file>}"

if [ ! -f "$FILE" ]; then
  echo "ERROR: File not found: $FILE" >&2
  exit 1
fi

API_KEY="${LINEAR_API_KEY_AUTOMATION:-${LINEAR_API_KEY:-}}"
if [ -z "$API_KEY" ]; then
  echo "ERROR: Neither LINEAR_API_KEY_AUTOMATION nor LINEAR_API_KEY is set" >&2
  exit 1
fi

FILENAME=$(basename "$FILE")
FILE_SIZE=$(wc -c < "$FILE" | tr -d ' ')

# Detect content type
case "${FILE##*.}" in
  png)  CONTENT_TYPE="image/png" ;;
  jpg|jpeg) CONTENT_TYPE="image/jpeg" ;;
  gif)  CONTENT_TYPE="image/gif" ;;
  webp) CONTENT_TYPE="image/webp" ;;
  *)    CONTENT_TYPE="application/octet-stream" ;;
esac

# Step 1: Request upload URL from Linear
RESPONSE=$(curl -sf -X POST https://api.linear.app/graphql \
  -H "Authorization: $API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"query\": \"mutation { fileUpload(contentType: \\\"$CONTENT_TYPE\\\", filename: \\\"$FILENAME\\\", size: $FILE_SIZE) { success uploadFile { uploadUrl assetUrl headers { key value } } } }\"}")

# Parse response
UPLOAD_URL=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['fileUpload']['uploadFile']['uploadUrl'])")
ASSET_URL=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['fileUpload']['uploadFile']['assetUrl'])")

# Build header args from the required headers array
HEADER_ARGS=$(echo "$RESPONSE" | python3 -c "
import sys, json
headers = json.load(sys.stdin)['data']['fileUpload']['uploadFile']['headers']
for h in headers:
    print(f'-H')
    print(f'{h[\"key\"]}: {h[\"value\"]}')
")

# Step 2: Upload the file to GCS
UPLOAD_RESULT=$(curl -sf -X PUT "$UPLOAD_URL" \
  -H "Content-Type: $CONTENT_TYPE" \
  $(echo "$HEADER_ARGS" | xargs) \
  --data-binary "@$FILE" 2>&1) || {
  echo "ERROR: Upload failed: $UPLOAD_RESULT" >&2
  exit 1
}

# Step 3: Print ONLY the permanent asset URL (no signature, no expiry)
echo "$ASSET_URL"
