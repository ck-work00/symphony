#!/usr/bin/env bash
set -uo pipefail

# linear-embed-images.sh — upload one or more images to Linear and print a
# ready-to-paste markdown image block (one `![name](assetUrl)` per line).
#
# Usage: linear-embed-images.sh <file-or-glob>...
#   e.g. linear-embed-images.sh /tmp/profile-*.png /tmp/walk-*.png
#
# Why this exists: the Test / Share Evidence agents save screenshots under their
# own ad-hoc names, then have to upload each and embed the returned URL. Hand-
# rolling that loop (with a hardcoded glob) kept producing empty `![]()` tags —
# either the glob matched nothing or the per-file URL wasn't captured. This does
# the whole thing in one call and, crucially, NEVER emits an empty image tag: a
# file that fails to upload is reported on stderr and skipped, and the script
# exits non-zero if nothing was embedded, so the agent notices instead of
# posting broken screenshots.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UPLOADER="$SCRIPT_DIR/linear-upload-image.sh"

if [ "$#" -eq 0 ]; then
  echo "Usage: linear-embed-images.sh <file-or-glob>..." >&2
  exit 2
fi
if [ ! -x "$UPLOADER" ]; then
  echo "ERROR: uploader not found at $UPLOADER" >&2
  exit 2
fi

embedded=0
for f in "$@"; do
  if [ ! -f "$f" ]; then
    echo "WARN: not a file, skipping: $f" >&2
    continue
  fi
  url="$("$UPLOADER" "$f" 2>/dev/null || true)"
  if [ -z "$url" ]; then
    echo "WARN: upload failed (no asset URL), skipping: $f" >&2
    continue
  fi
  printf '![%s](%s)\n' "$(basename "$f")" "$url"
  embedded=$((embedded + 1))
done

if [ "$embedded" -eq 0 ]; then
  echo "ERROR: embedded 0 images — do NOT post empty ![]() tags; fix the file paths and retry." >&2
  exit 1
fi

echo "Embedded $embedded image(s)." >&2
