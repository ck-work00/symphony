#!/usr/bin/env bash
set -euo pipefail

# Releases a slot claimed by slot-claim-registry.sh: stops services, resets the
# working copy to origin/main, and removes the registry lease (only if symphony
# owns it — a lease taken over by an interactive session is left alone).
#
# Usage: slot-release-registry.sh <workspace>
#   Reads .symphony_slot from the workspace to find the slot to release.

WORKSPACE="${1:?Usage: slot-release-registry.sh <workspace>}"
SLOT_FILE="$WORKSPACE/.symphony_slot"

GEARFLOW_WORKSPACE="${GEARFLOW_WORKSPACE:-$HOME/Documents/Gearflow}"
REGISTRY="$GEARFLOW_WORKSPACE/local-dev/registry"

if [ ! -f "$SLOT_FILE" ]; then
  echo "No .symphony_slot file in $WORKSPACE — nothing to release"
  exit 0
fi

SLOT_NAME=$(grep '^SLOT_NAME=' "$SLOT_FILE" | cut -d= -f2)
DIR=$(grep '^DIRECTORY=' "$SLOT_FILE" | cut -d= -f2)

if [ -z "$SLOT_NAME" ] || [ -z "$DIR" ]; then
  echo "ERROR: could not parse slot info from $SLOT_FILE"
  exit 1
fi

echo "Releasing symphony slot $SLOT_NAME..."

if [ -d "$DIR" ]; then
  cd "$DIR"
  # Stop through devenv supervision; do NOT remove process-compose sockets —
  # that orphans still-running processes from supervision.
  direnv exec . devenv processes stop backend frontend 2>/dev/null || true

  BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
  git checkout -- . 2>/dev/null || true
  git clean -fd -e .env -e .envrc -e assets.env -e dev.secret.exs 2>/dev/null || true
  git checkout main 2>/dev/null || true
  git reset --hard origin/main 2>/dev/null || true
  echo "Git cleaned (was on branch: $BRANCH)"
fi

# Remove the registry lease — but only a symphony-owned one.
LEASE="$REGISTRY/${SLOT_NAME}.json"
if [ -f "$LEASE" ]; then
  OWNER=$(grep -o '"owner"[[:space:]]*:[[:space:]]*"[^"]*"' "$LEASE" 2>/dev/null \
    | head -1 | sed 's/.*:[[:space:]]*"\(.*\)"/\1/')
  if [ "$OWNER" = "symphony" ]; then
    rm -f "$LEASE"
    echo "Registry lease removed"
  else
    echo "WARNING: lease for $SLOT_NAME is owned by '$OWNER', not symphony — leaving it"
  fi
fi

rm -f "$SLOT_FILE"

echo "SLOT_RELEASED: $SLOT_NAME"
