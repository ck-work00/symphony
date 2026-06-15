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

# Validate the target before any destructive git. The .symphony_slot contract
# can be stale or hand-edited, so don't trust DIRECTORY: re-derive the canonical
# slot path from SLOT_NAME and confirm the slot is one Symphony may touch. This
# is the PR's "only operate on designated slots" rule — without it a bad contract
# could git reset --hard the wrong working copy.
if ! printf '%s' "$SLOT_NAME" | grep -Eq '^gf_(platform|procurement)-slot[0-9]+$'; then
  echo "ERROR: SLOT_NAME '$SLOT_NAME' is not a gf_<repo>-slotN name — refusing to clean"
  exit 1
fi

REPO="${SLOT_NAME%%-slot*}"       # gf_platform | gf_procurement
SLOT_NUM="${SLOT_NAME##*-slot}"   # trailing slot number
EXPECTED_DIR="$GEARFLOW_WORKSPACE/local-dev/$SLOT_NAME"

if [ "$DIR" != "$EXPECTED_DIR" ]; then
  echo "ERROR: DIRECTORY '$DIR' is not this slot's canonical path '$EXPECTED_DIR' — refusing to clean"
  exit 1
fi
DIR="$EXPECTED_DIR"

case "$REPO" in
  gf_platform)    ELIGIBLE="${SYMPHONY_PLATFORM_SLOTS:-}" ;;
  gf_procurement) ELIGIBLE="${SYMPHONY_PROCUREMENT_SLOTS:-}" ;;
  *)              ELIGIBLE="" ;;
esac

if [ -n "$ELIGIBLE" ]; then
  slot_eligible=false
  for n in $ELIGIBLE; do
    [ "$n" = "$SLOT_NUM" ] && slot_eligible=true && break
  done
  if [ "$slot_eligible" != "true" ]; then
    echo "ERROR: slot $SLOT_NAME is not Symphony-eligible ($REPO: $ELIGIBLE) — refusing to clean"
    exit 1
  fi
else
  echo "WARNING: Symphony-eligible slot set for $REPO is unset; proceeding on the canonical-path check alone"
fi

echo "Releasing symphony slot $SLOT_NAME..."

if [ -d "$DIR" ]; then
  cd "$DIR"
  # Stop through devenv supervision; do NOT remove process-compose sockets —
  # that orphans still-running processes from supervision.
  direnv exec . devenv processes stop backend frontend 2>/dev/null || true

  BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
  git checkout -- . 2>/dev/null || true
  git clean -fd -e .env -e .envrc -e .direnv -e assets.env -e dev.secret.exs 2>/dev/null || true
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
