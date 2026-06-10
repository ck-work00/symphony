#!/usr/bin/env bash
set -euo pipefail

# Claims a working-copy slot through the gf_engineering local-dev registry.
#
# This is the registry-aware sibling of slot-claim.sh for machines that run the
# gf_engineering workspace layout (GEA-3346): repos live at
#   $GEARFLOW_WORKSPACE/local-dev/gf_<repo>-slot<N>
# and slot ownership is a single atomic lease file at
#   $GEARFLOW_WORKSPACE/local-dev/registry/gf_<repo>-slot<N>.json
# shared with every interactive Claude session on the machine. Writing the
# lease is what makes a Symphony run visible to (and safe from) peer sessions.
#
# Differences from slot-claim.sh:
#   * Slot dirs + lease protocol come from the gf_engineering layout above.
#   * Eligible slots are explicit (SYMPHONY_PLATFORM_SLOTS / SYMPHONY_PROCUREMENT_SLOTS,
#     space-separated slot numbers). Symphony only ever touches designated slots.
#   * Ports / DB come from the slot's own devenv config via `direnv exec .` —
#     slots carry their own port assignments and secrets.
#   * The slot's .env / .envrc are NEVER written. They hold per-slot ports and
#     real secrets that must be preserved.
#   * Stale-lease cleanup only ever removes leases owned by "symphony".
#     A lease held by an interactive session is never touched.
#   * No auto-clone — designate slots that already exist (provision via the
#     gf_engineering provision-slot flow).
#
# Same as slot-claim.sh:
#   * git reset/clean between runs — designated slots are ephemeral; anything
#     worth keeping must be committed and pushed by the agent.
#   * Writes $WORKSPACE/.symphony_slot with the slot contract for the agent.
#
# Usage: slot-claim-registry.sh <platform|procurement> <branch> <workspace>

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

POOL="${1:?Usage: slot-claim-registry.sh <platform|procurement> <branch> <workspace>}"
BRANCH="${2:?Usage: slot-claim-registry.sh <platform|procurement> <branch> <workspace>}"
WORKSPACE="${3:?Usage: slot-claim-registry.sh <platform|procurement> <branch> <workspace>}"

if [[ "$POOL" != "platform" && "$POOL" != "procurement" ]]; then
  echo "ERROR: repo must be 'platform' or 'procurement', got '$POOL'"
  exit 1
fi

GEARFLOW_WORKSPACE="${GEARFLOW_WORKSPACE:-$HOME/Documents/Gearflow}"
REGISTRY="$GEARFLOW_WORKSPACE/local-dev/registry"
REPO_PREFIX="gf_${POOL}"
STALE_LEASE_MAX_AGE_SECONDS="${STALE_LEASE_MAX_AGE_SECONDS:-14400}" # 4 hours

if [ ! -d "$REGISTRY" ]; then
  echo "ERROR: registry not found at $REGISTRY — is this a gf_engineering machine?"
  exit 1
fi

if [ "$POOL" = "platform" ]; then
  ELIGIBLE_SLOTS="${SYMPHONY_PLATFORM_SLOTS:-}"
else
  ELIGIBLE_SLOTS="${SYMPHONY_PROCUREMENT_SLOTS:-}"
fi

if [ -z "$ELIGIBLE_SLOTS" ]; then
  echo "ERROR: no Symphony-eligible $POOL slots configured."
  echo "Set SYMPHONY_$(echo "$POOL" | tr '[:lower:]' '[:upper:]')_SLOTS (space-separated slot numbers) in Symphony's environment or the before_run hook."
  exit 1
fi

slot_dir()   { echo "$GEARFLOW_WORKSPACE/local-dev/${REPO_PREFIX}-slot${1}"; }
lease_file() { echo "$REGISTRY/${REPO_PREFIX}-slot${1}.json"; }

json_field() { # json_field <file> <key> — extracts a string field, empty if absent
  grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$1" 2>/dev/null \
    | head -1 | sed 's/.*:[[:space:]]*"\(.*\)"/\1/'
}

slot_phoenix_port() { # best-effort, for staleness probes only
  (cd "$(slot_dir "$1")" 2>/dev/null && \
   direnv exec . bash -c 'echo "${PHOENIX_PORT:-${MAIN_PROXY_PORT:-}}"' 2>/dev/null | tail -1)
}

# Idempotent re-entry: this workspace already holds a slot with a live symphony lease.
if [ -f "$WORKSPACE/.symphony_slot" ]; then
  EXISTING_DIR=$(grep '^DIRECTORY=' "$WORKSPACE/.symphony_slot" | cut -d= -f2)
  EXISTING_NAME=$(grep '^SLOT_NAME=' "$WORKSPACE/.symphony_slot" | cut -d= -f2)
  EXISTING_LEASE="$REGISTRY/${EXISTING_NAME}.json"
  if [ -n "$EXISTING_DIR" ] && [ -f "$EXISTING_LEASE" ] && \
     [ "$(json_field "$EXISTING_LEASE" owner)" = "symphony" ] && \
     [ "$(json_field "$EXISTING_LEASE" workspace)" = "$WORKSPACE" ]; then
    echo "Slot already claimed for this workspace"
    cat "$WORKSPACE/.symphony_slot"
    echo "STATUS=ready"
    exit 0
  fi
fi

# Stale-lease sweep — SYMPHONY-OWNED leases only. Never touch a lease held by
# an interactive session (any owner other than "symphony").
for SLOT_NUM in $ELIGIBLE_SLOTS; do
  LEASE="$(lease_file "$SLOT_NUM")"
  [ -f "$LEASE" ] || continue
  [ "$(json_field "$LEASE" owner)" = "symphony" ] || continue

  LEASE_WORKSPACE="$(json_field "$LEASE" workspace)"
  LEASE_BRANCH="$(json_field "$LEASE" branch)"
  LEASE_CLAIMED="$(json_field "$LEASE" claimed)"
  STALE_REASON=""

  if [ "$LEASE_WORKSPACE" = "$WORKSPACE" ] || [ "$LEASE_BRANCH" = "$BRANCH" ]; then
    STALE_REASON="matches current workspace or branch (re-claim for same issue)"
  elif [ -n "$LEASE_WORKSPACE" ] && [ ! -d "$LEASE_WORKSPACE" ]; then
    STALE_REASON="workspace $LEASE_WORKSPACE no longer exists"
  elif [ -n "$LEASE_CLAIMED" ]; then
    LEASE_EPOCH=$(date -ju -f "%Y-%m-%dT%H:%M:%SZ" "$LEASE_CLAIMED" +%s 2>/dev/null \
               || date -u -d "$LEASE_CLAIMED" +%s 2>/dev/null \
               || echo "")
    if [ -n "$LEASE_EPOCH" ]; then
      AGE=$(( $(date +%s) - LEASE_EPOCH ))
      if [ "$AGE" -gt "$STALE_LEASE_MAX_AGE_SECONDS" ]; then
        PORT="$(slot_phoenix_port "$SLOT_NUM")"
        if [ -n "$PORT" ] && ! lsof -i :"$PORT" -sTCP:LISTEN > /dev/null 2>&1; then
          STALE_REASON="lease is $((AGE / 3600))h old and no Phoenix on port $PORT"
        fi
      fi
    fi
  fi

  if [ -n "$STALE_REASON" ]; then
    echo "Releasing stale symphony lease for ${REPO_PREFIX}-slot${SLOT_NUM}: $STALE_REASON"
    rm -f "$LEASE"
    if [ -n "$LEASE_WORKSPACE" ] && [ -f "$LEASE_WORKSPACE/.symphony_slot" ]; then
      rm -f "$LEASE_WORKSPACE/.symphony_slot"
    fi
  fi
done

# Claim the first eligible slot whose lease we can create atomically.
# noclobber makes the create itself the lock — two claimants can't both win.
CLAIMED_SLOT=""
for SLOT_NUM in $ELIGIBLE_SLOTS; do
  DIR="$(slot_dir "$SLOT_NUM")"
  if [ ! -d "$DIR" ]; then
    echo "WARN: designated slot ${REPO_PREFIX}-slot${SLOT_NUM} does not exist at $DIR, skipping"
    continue
  fi
  LEASE="$(lease_file "$SLOT_NUM")"
  if ( set -o noclobber; cat > "$LEASE" <<EOF
{
  "owner": "symphony",
  "conversation_id": null,
  "linear_issue": "${SYMPHONY_ISSUE_IDENTIFIER:-unknown}",
  "task": "Symphony autonomous run",
  "branch": "$BRANCH",
  "workspace": "$WORKSPACE",
  "claimed": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
  ) 2>/dev/null; then
    CLAIMED_SLOT="$SLOT_NUM"
    break
  fi
done

if [ -z "$CLAIMED_SLOT" ]; then
  echo "ERROR: no available $POOL slots among designated set: $ELIGIBLE_SLOTS"
  for S in $ELIGIBLE_SLOTS; do
    LF="$(lease_file "$S")"
    if [ -f "$LF" ]; then
      echo "  ${REPO_PREFIX}-slot${S}: LEASED (owner=$(json_field "$LF" owner) issue=$(json_field "$LF" linear_issue) branch=$(json_field "$LF" branch))"
    fi
  done
  exit 1
fi

SLOT_NUM="$CLAIMED_SLOT"
SLOT_NAME="${REPO_PREFIX}-slot${SLOT_NUM}"
DIR="$(slot_dir "$SLOT_NUM")"
LEASE="$(lease_file "$SLOT_NUM")"
cd "$DIR"

release_lease_and_fail() {
  rm -f "$LEASE"
  exit 1
}

# Discover ports / DB from the slot's own devenv config. Never computed, never
# written back — the slot's .env is the source of truth.
PHOENIX_PORT=$(direnv exec . bash -c 'echo "${PHOENIX_PORT:-${MAIN_PROXY_PORT:-}}"' 2>/dev/null | tail -1)
FRONTEND_PORT=$(direnv exec . bash -c 'echo "${FRONTEND_PORT:-${VITE_PORT:-}}"' 2>/dev/null | tail -1)
POSTGRES_PORT=$(direnv exec . bash -c 'echo "${POSTGRES_PORT:-}"' 2>/dev/null | tail -1)
DATABASE_NAME=$(direnv exec . bash -c 'echo "${DATABASE_NAME:-}"' 2>/dev/null | tail -1)
DATABASE_NAME="${DATABASE_NAME:-${REPO_PREFIX}_dev}"

if [ -z "$PHOENIX_PORT" ] || [ -z "$FRONTEND_PORT" ] || [ -z "$POSTGRES_PORT" ]; then
  echo "ERROR: could not discover ports for $DIR via direnv."
  echo "  PHOENIX_PORT=$PHOENIX_PORT FRONTEND_PORT=$FRONTEND_PORT POSTGRES_PORT=$POSTGRES_PORT"
  release_lease_and_fail
fi

# Each slot runs its own postgres. Start it if it isn't up.
if ! lsof -i :"$POSTGRES_PORT" -sTCP:LISTEN > /dev/null 2>&1; then
  echo "Postgres not listening on $POSTGRES_PORT — starting it..."
  direnv exec . devenv up -d postgres 2>&1 | tail -2 || true
  for _ in $(seq 1 20); do
    lsof -i :"$POSTGRES_PORT" -sTCP:LISTEN > /dev/null 2>&1 && break
    sleep 3
  done
  if ! lsof -i :"$POSTGRES_PORT" -sTCP:LISTEN > /dev/null 2>&1; then
    echo "ERROR: postgres failed to come up on $POSTGRES_PORT for $SLOT_NAME"
    release_lease_and_fail
  fi
fi

# Skip the heavy stop/start cycle when the backend is already healthy.
# gf_platform's main_proxy routes by Host; procurement answers on localhost.
BACKEND_HEALTHY=false
HEALTH_HOST="localhost"
[ "$POOL" = "platform" ] && HEALTH_HOST="local.gearflow.com"
if curl -sf "http://localhost:$PHOENIX_PORT/gql" -H "Host: $HEALTH_HOST" -H "Content-Type: application/json" \
   -d '{"query":"{ __typename }"}' 2>/dev/null | grep -q data; then
  BACKEND_HEALTHY=true
fi

if [ "$BACKEND_HEALTHY" = "false" ]; then
  direnv exec . devenv processes stop backend frontend 2>/dev/null || true
fi

# Reset to a clean state. Designated slots are ephemeral; .env/.envrc are
# untracked-but-not-cleaned because git clean -fd respects neither — so be
# explicit: -e protects them.
git checkout -- . 2>/dev/null || true
git clean -fd -e .env -e .envrc -e assets.env -e dev.secret.exs 2>/dev/null || true

# Fresh branch from origin
git fetch origin --quiet
git checkout main --quiet
git reset --hard origin/main --quiet
git branch -D "$BRANCH" 2>/dev/null || true
if git ls-remote --heads origin "$BRANCH" 2>/dev/null | grep -q "$BRANCH"; then
  git checkout -b "$BRANCH" "origin/$BRANCH" --quiet
  git rebase origin/main --quiet 2>/dev/null || git rebase --abort 2>/dev/null
else
  git checkout -b "$BRANCH" --quiet
fi

direnv exec . mix deps.get --quiet 2>&1 | tail -5 || true

# Migrations and DB recovery are the agent's job — not slot-claim's. A failing
# migration here would block the run entirely; the agent can diagnose DB state.

# Slot contract for the agent.
cat > "$WORKSPACE/.symphony_slot" <<EOF
SLOT_NAME=$SLOT_NAME
DIRECTORY=$DIR
BRANCH=$BRANCH
PHOENIX_PORT=$PHOENIX_PORT
FRONTEND_PORT=$FRONTEND_PORT
POSTGRES_PORT=$POSTGRES_PORT
DATABASE_NAME=$DATABASE_NAME
EOF

# Start services if needed. Non-fatal — if it fails (pending migrations, stale
# DB state) the agent receives the slot with services down and recovers.
if [ "$BACKEND_HEALTHY" = "false" ]; then
  if ! "$SCRIPT_DIR/devenv-start.sh"; then
    echo "WARNING: devenv-start.sh failed; slot is claimed but services may be down."
    echo "The agent will need to recover — see the repo's CLAUDE.md for tooling."
  fi
else
  echo "Backend already healthy on port $PHOENIX_PORT, skipping start"
fi

cat "$WORKSPACE/.symphony_slot"
echo "STATUS=ready"
