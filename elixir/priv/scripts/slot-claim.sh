#!/usr/bin/env bash
set -euo pipefail

# Claims a dedicated Symphony pool slot (slots 5-8, separate from cc-* worker pool slots 1-4).
# Usage: slot-claim.sh <platform|procurement> <branch> <workspace>
#   workspace: the Symphony workspace path (written to .symphony_slot for release)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

POOL_PREFIX="${1:?Usage: slot-claim.sh <platform|procurement> <branch> <workspace>}"
BRANCH="${2:?Usage: slot-claim.sh <platform|procurement> <branch> <workspace>}"
WORKSPACE="${3:?Usage: slot-claim.sh <platform|procurement> <branch> <workspace>}"

if [[ "$POOL_PREFIX" != "platform" && "$POOL_PREFIX" != "procurement" ]]; then
  echo "ERROR: repo must be 'platform' or 'procurement', got '$POOL_PREFIX'"
  exit 1
fi

# Idempotent: if slot already claimed for this workspace, just output and exit
if [ -f "$WORKSPACE/.symphony_slot" ]; then
  EXISTING_DIR=$(grep '^DIRECTORY=' "$WORKSPACE/.symphony_slot" | cut -d= -f2)
  if [ -n "$EXISTING_DIR" ] && [ -f "$EXISTING_DIR/.git/symphony.lock" ]; then
    echo "Slot already claimed for this workspace"
    cat "$WORKSPACE/.symphony_slot"
    echo "STATUS=ready"
    exit 0
  fi
fi

# Release stale locks:
# 1. Locks matching this workspace or branch (re-claim for same issue)
# 2. Self-referential locks (workspace=<same-slot-dir>, always stale)
# 3. Locks whose workspace directory no longer exists
# 4. Locks older than STALE_LOCK_MAX_AGE_SECONDS with no Phoenix listening on the slot's port
STALE_LOCK_MAX_AGE_SECONDS="${STALE_LOCK_MAX_AGE_SECONDS:-14400}"  # 4 hours

for SLOT_NUM in 5 6 7 8; do
  SLOT_DIR="$HOME/Documents/Gearflow/${POOL_PREFIX}-${SLOT_NUM}"
  LOCKFILE="$SLOT_DIR/.git/symphony.lock"
  if [ -f "$LOCKFILE" ]; then
    LOCK_CONTENT=$(cat "$LOCKFILE")
    LOCK_WORKSPACE=$(echo "$LOCK_CONTENT" | grep -oE 'workspace=[^ ]+' | cut -d= -f2)

    STALE_REASON=""
    if echo "$LOCK_CONTENT" | grep -q "workspace=$WORKSPACE " || \
       echo "$LOCK_CONTENT" | grep -q "branch=$BRANCH "; then
      STALE_REASON="matches current workspace or branch"
    elif [ "$LOCK_WORKSPACE" = "$SLOT_DIR" ]; then
      STALE_REASON="self-referential (workspace=slot dir)"
    elif [ -n "$LOCK_WORKSPACE" ] && [ ! -d "$LOCK_WORKSPACE" ]; then
      STALE_REASON="workspace directory $LOCK_WORKSPACE no longer exists"
    else
      CLAIMED_AT=$(echo "$LOCK_CONTENT" | grep -oE 'claimed_at=[^ ]+' | cut -d= -f2)
      if [ -n "$CLAIMED_AT" ]; then
        # Parse ISO 8601 UTC — try macOS form (-u to treat input as UTC), then GNU
        LOCK_EPOCH=$(date -ju -f "%Y-%m-%dT%H:%M:%SZ" "$CLAIMED_AT" +%s 2>/dev/null \
                  || date -u -d "$CLAIMED_AT" +%s 2>/dev/null \
                  || echo "")
        if [ -n "$LOCK_EPOCH" ]; then
          AGE=$(( $(date +%s) - LOCK_EPOCH ))
          if [ "$AGE" -gt "$STALE_LOCK_MAX_AGE_SECONDS" ]; then
            if [ "$POOL_PREFIX" = "platform" ]; then
              SLOT_PORT=$((3004 + SLOT_NUM))
            else
              SLOT_PORT=$((3008 + SLOT_NUM))
            fi
            if ! lsof -i :"$SLOT_PORT" -sTCP:LISTEN > /dev/null 2>&1; then
              STALE_REASON="lock is $((AGE / 3600))h old and no Phoenix on port $SLOT_PORT"
            fi
          fi
        fi
      fi
    fi

    if [ -n "$STALE_REASON" ]; then
      echo "Releasing stale lock for ${POOL_PREFIX}-${SLOT_NUM}: $STALE_REASON"
      rm -f "$LOCKFILE"
      # Clear the workspace marker too so the abandoned workspace can be reclaimed cleanly
      if [ -n "$LOCK_WORKSPACE" ] && [ -f "$LOCK_WORKSPACE/.symphony_slot" ]; then
        rm -f "$LOCK_WORKSPACE/.symphony_slot"
      fi
    fi
  fi
done

# Symphony uses slots 5-8 to stay completely separate from cc-* worker pool (slots 1-4)
AVAILABLE_SLOT=""
for SLOT_NUM in 5 6 7 8; do
  SLOT_NAME="${POOL_PREFIX}-${SLOT_NUM}"
  LOCKFILE="$HOME/Documents/Gearflow/${SLOT_NAME}/.git/symphony.lock"
  # Also honor a lock in the legacy work-tree location during the transition, so a
  # new claim never steals a slot still held by an in-flight run under the old path.
  OLD_LOCKFILE="$HOME/Documents/Gearflow/${SLOT_NAME}/.symphony.lock"
  if [ ! -f "$LOCKFILE" ] && [ ! -f "$OLD_LOCKFILE" ]; then
    AVAILABLE_SLOT=$SLOT_NUM
    break
  fi
done

if [ -z "$AVAILABLE_SLOT" ]; then
  echo "ERROR: No symphony ${POOL_PREFIX} slots available (slots 5-8 all locked)."
  for S in 5 6 7 8; do
    LF="$HOME/Documents/Gearflow/${POOL_PREFIX}-${S}/.git/symphony.lock"
    if [ -f "$LF" ]; then
      echo "  ${POOL_PREFIX}-${S}: LOCKED ($(cat "$LF"))"
    fi
  done
  exit 1
fi

SLOT_NUM=$AVAILABLE_SLOT
SLOT_NAME="${POOL_PREFIX}-${SLOT_NUM}"
DIR="$HOME/Documents/Gearflow/${SLOT_NAME}"

# Derive ports — offset from cc-* pool to never collide
# cc-platform:      Phoenix 3001-3004, Frontend 5201-5204
# cc-procurement:   Phoenix 3005-3008, Frontend 5205-5208
# symphony-platform:    Phoenix 3009-3012, Frontend 5209-5212
# symphony-procurement: Phoenix 3013-3016, Frontend 5213-5216
if [ "$POOL_PREFIX" = "platform" ]; then
  PHOENIX_PORT=$((3004 + SLOT_NUM))     # 3009-3012
  FRONTEND_PORT=$((5204 + SLOT_NUM))    # 5209-5212
  POSTGRES_PORT=25432
  DATABASE_NAME="gf_platform_${SLOT_NUM}_dev"
  EXPECTED_REMOTE="git@github.com:GearFlowDev/gf_platform.git"
else
  PHOENIX_PORT=$((3008 + SLOT_NUM))     # 3013-3016
  FRONTEND_PORT=$((5208 + SLOT_NUM))    # 5213-5216
  POSTGRES_PORT=25433
  DATABASE_NAME="gf_procurement_${SLOT_NUM}_dev"
  EXPECTED_REMOTE="git@github.com:GearFlowDev/gf_procurement.git"
fi

# Create directory if it doesn't exist (first-time setup)
if [ ! -d "$DIR" ]; then
  echo "Creating new symphony slot at $DIR..."
  git clone "$EXPECTED_REMOTE" "$DIR"
  cd "$DIR"
  # Create the database
  direnv exec . mix ecto.create 2>/dev/null || true
  direnv exec . mix ecto.migrate 2>/dev/null || true
else
  cd "$DIR"
  # Verify remote
  ACTUAL_REMOTE=$(git remote get-url origin 2>/dev/null || echo "")
  if [ "$ACTUAL_REMOTE" != "$EXPECTED_REMOTE" ]; then
    echo "ERROR: Slot directory has wrong remote: $ACTUAL_REMOTE (expected $EXPECTED_REMOTE)"
    exit 1
  fi
fi

# Verify postgres is running
if ! lsof -i :"$POSTGRES_PORT" -sTCP:LISTEN > /dev/null 2>&1; then
  echo "ERROR: Postgres not running on port $POSTGRES_PORT (needed for $POOL_PREFIX)"
  echo "Start it from any $POOL_PREFIX slot: cd ~/Documents/Gearflow/${POOL_PREFIX}-1 && direnv exec . devenv up -d postgres"
  exit 1
fi

# Check if backend is already healthy on our port — skip heavy setup if so.
# gf_platform's main_proxy routes by Host, so the health check must send the
# gearflow host (mapped to 127.0.0.1 in /etc/hosts) or it gets "No backends
# matched". Procurement does not host-route, so it keeps localhost.
BACKEND_HEALTHY=false
HEALTH_HOST="localhost"
[ "$POOL_PREFIX" = "platform" ] && HEALTH_HOST="local.gearflow.com"
if curl -sf "http://localhost:$PHOENIX_PORT/gql" -H "Host: $HEALTH_HOST" -H "Content-Type: application/json" \
   -d '{"query":"{ __typename }"}' 2>/dev/null | grep -q data; then
  BACKEND_HEALTHY=true
fi

# Only stop/restart services if backend is NOT healthy
if [ "$BACKEND_HEALTHY" = "false" ]; then
  direnv exec . devenv processes stop backend frontend 2>/dev/null || true
fi

# Clean git state (safe even with services running)
git checkout -- . 2>/dev/null || true
git clean -fd 2>/dev/null || true

# Write lockfile inside .git/ — it lives outside the working tree, so the agent's
# `git add .` can never commit it and it never blocks a `git checkout`/`reset`
# (a committed/dirty .symphony.lock in the work tree aborts branch switches).
echo "workspace=$WORKSPACE branch=$BRANCH claimed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$DIR/.git/symphony.lock"

# Checkout branch
git fetch origin --quiet
git checkout main --quiet
git reset --hard origin/main --quiet
# Delete local branch if it exists (we always want a fresh start from origin or new)
git branch -D "$BRANCH" 2>/dev/null || true
if git ls-remote --heads origin "$BRANCH" 2>/dev/null | grep -q "$BRANCH"; then
  git checkout -b "$BRANCH" "origin/$BRANCH" --quiet
  # Rebase onto latest main to pick up merged changes
  git rebase origin/main --quiet 2>/dev/null || git rebase --abort 2>/dev/null
else
  git checkout -b "$BRANCH" --quiet
fi

# Deps and migrations (suppress noisy output)
direnv exec . mix deps.get --quiet 2>&1 | tail -5
direnv exec . mix ecto.migrate --quiet 2>&1 | tail -5 || true

# Write port overrides (both .env for devenv and .env.symphony for reference).
# gf_platform's devenv reads MAIN_PROXY_PORT / VITE_PORT; gf_procurement reads
# PHOENIX_PORT / FRONTEND_PORT. Emit both names on platform so the backend binds
# our slot's port instead of the default 4000.
cat > .env <<EOF
export PHOENIX_PORT=$PHOENIX_PORT
export FRONTEND_PORT=$FRONTEND_PORT
export DATABASE_NAME=$DATABASE_NAME
export POSTGRES_PORT=$POSTGRES_PORT
EOF
if [ "$POOL_PREFIX" = "platform" ]; then
  cat >> .env <<EOF
export MAIN_PROXY_PORT=$PHOENIX_PORT
export VITE_PORT=$FRONTEND_PORT
EOF
fi
cp .env .env.symphony

# Ensure .envrc exists so direnv exec . activates devenv and loads .env
if [ ! -f .envrc ]; then
  cat > .envrc <<'ENVRC'
#!/usr/bin/env bash

eval "$(devenv direnvrc)"
use devenv

# Load .env file
if [ -f .env ]; then
  set -a
  source .env
  set +a
fi
ENVRC
  direnv allow . 2>/dev/null || true
fi

# Write slot info to workspace
cat > "$WORKSPACE/.symphony_slot" <<EOF
SLOT_NAME=$SLOT_NAME
DIRECTORY=$DIR
BRANCH=$BRANCH
PHOENIX_PORT=$PHOENIX_PORT
FRONTEND_PORT=$FRONTEND_PORT
POSTGRES_PORT=$POSTGRES_PORT
DATABASE_NAME=$DATABASE_NAME
EOF

# Start backend + frontend only if not already healthy
if [ "$BACKEND_HEALTHY" = "false" ]; then
  "$SCRIPT_DIR/devenv-start.sh"
else
  echo "Backend already healthy on port $PHOENIX_PORT, skipping start"
fi

# Output
cat "$WORKSPACE/.symphony_slot"
echo "STATUS=ready"
