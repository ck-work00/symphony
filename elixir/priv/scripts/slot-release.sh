#!/usr/bin/env bash
set -euo pipefail

# Releases a Symphony pool slot (slots 5-8).
# Usage: slot-release.sh <workspace>
#   Reads .symphony_slot from workspace to find the slot to release.

WORKSPACE="${1:?Usage: slot-release.sh <workspace>}"
SLOT_FILE="$WORKSPACE/.symphony_slot"

if [ ! -f "$SLOT_FILE" ]; then
  echo "No .symphony_slot file in $WORKSPACE — nothing to release"
  exit 0
fi

# Parse slot info
SLOT_NAME=$(grep '^SLOT_NAME=' "$SLOT_FILE" | cut -d= -f2)
DIR=$(grep '^DIRECTORY=' "$SLOT_FILE" | cut -d= -f2)

if [ -z "$SLOT_NAME" ] || [ -z "$DIR" ]; then
  echo "ERROR: Could not parse slot info from $SLOT_FILE"
  exit 1
fi

echo "Releasing symphony slot $SLOT_NAME..."

# Stop services and clean
if [ -d "$DIR" ]; then
  cd "$DIR"
  direnv exec . devenv processes stop backend frontend 2>/dev/null || true
  rm -f .devenv/processes.sock .devenv/run/pc.sock

  # Clean git state
  BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
  git checkout -- . 2>/dev/null || true
  git clean -fd 2>/dev/null || true
  git checkout main 2>/dev/null || true
  git reset --hard origin/main 2>/dev/null || true

  # Remove lockfile (new .git/ location + any leftover old work-tree copy) and env override
  rm -f "$DIR/.git/symphony.lock" "$DIR/.symphony.lock"
  rm -f "$DIR/.env.symphony"
  echo "Git cleaned (was on branch: $BRANCH)"
fi

# Clean workspace marker
rm -f "$SLOT_FILE"

echo "SLOT_RELEASED: $SLOT_NAME"
