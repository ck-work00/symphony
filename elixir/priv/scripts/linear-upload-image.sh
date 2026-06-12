#!/usr/bin/env bash
set -euo pipefail

# Uploads an image to Linear and prints the permanent asset URL — but ONLY after
# verifying the bytes actually landed (an authenticated GET of the asset returns
# 200). Linear's fileUpload mutation hands back an assetUrl immediately, before
# any bytes exist; if the GCS PUT silently fails or is skipped, that assetUrl is
# a dangling reference that renders as "failed to load image" in Linear. This
# script refuses to print such a URL: it PUTs, verifies, retries, and exits
# non-zero if it cannot confirm the asset — so callers never embed a broken image.
#
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

case "${FILE##*.}" in
  png)  CONTENT_TYPE="image/png" ;;
  jpg|jpeg) CONTENT_TYPE="image/jpeg" ;;
  gif)  CONTENT_TYPE="image/gif" ;;
  webp) CONTENT_TYPE="image/webp" ;;
  *)    CONTENT_TYPE="application/octet-stream" ;;
esac

# One full upload attempt: fresh fileUpload (recompute size each time so it
# always matches the bytes we PUT), PUT to GCS, then verify the asset is
# fetchable. Prints the asset URL and returns 0 only on verified success.
attempt_upload() {
  local file_size response upload_url asset_url verify_code
  file_size=$(wc -c < "$FILE" | tr -d ' ')

  response=$(curl -sf -X POST https://api.linear.app/graphql \
    -H "Authorization: $API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"query\": \"mutation { fileUpload(contentType: \\\"$CONTENT_TYPE\\\", filename: \\\"$FILENAME\\\", size: $file_size) { success uploadFile { uploadUrl assetUrl headers { key value } } } }\"}") || {
    echo "  fileUpload mutation failed" >&2
    return 1
  }

  upload_url=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['fileUpload']['uploadFile']['uploadUrl'])" 2>/dev/null || true)
  asset_url=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['fileUpload']['uploadFile']['assetUrl'])" 2>/dev/null || true)
  if [ -z "$upload_url" ] || [ -z "$asset_url" ]; then
    echo "  fileUpload returned no upload/asset URL" >&2
    return 1
  fi

  # Required upload headers from Linear, passed verbatim — the values contain
  # spaces and are part of the GCS signed-URL signature, so they must NOT be
  # word-split (an earlier `xargs` version corrupted the signature and the PUT
  # stored nothing, leaving a 404 asset).
  local header_flags=()
  local _hdr
  while IFS= read -r _hdr; do
    [ -n "$_hdr" ] && header_flags+=(-H "$_hdr")
  done < <(echo "$response" | python3 -c "
import sys, json
for h in json.load(sys.stdin)['data']['fileUpload']['uploadFile']['headers']:
    print(f\"{h['key']}: {h['value']}\")
")

  if ! curl -sf -X PUT "$upload_url" \
    -H "Content-Type: $CONTENT_TYPE" \
    ${header_flags[@]+"${header_flags[@]}"} \
    --data-binary "@$FILE" > /dev/null 2>&1; then
    echo "  GCS PUT failed" >&2
    return 1
  fi

  # Verify the bytes actually landed — a successful PUT alone is not proof, and
  # this is exactly what catches the dangling-asset "failed to load image" case.
  verify_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 20 \
    -H "Authorization: $API_KEY" "$asset_url" 2>/dev/null || echo "000")
  if [ "$verify_code" != "200" ]; then
    echo "  asset not retrievable after upload (HTTP $verify_code)" >&2
    return 1
  fi

  echo "$asset_url"
  return 0
}

for attempt in 1 2 3; do
  if url=$(attempt_upload); then
    echo "$url"
    exit 0
  fi
  echo "Upload attempt $attempt failed for $FILENAME; retrying..." >&2
  sleep 2
done

echo "ERROR: could not upload and verify $FILE after 3 attempts" >&2
exit 1
