#!/usr/bin/env bash
set -euo pipefail

# Starts backend + frontend for a slot directory.
# Reads POSTGRES_PORT from .env to verify the correct postgres instance.
# Usage: devenv-start.sh

source .env 2>/dev/null || true

# Resolve the Phoenix port — platform uses MAIN_PROXY_PORT, procurement uses PHOENIX_PORT
# Fall back to direnv if .env doesn't have it
APP_PORT="${PHOENIX_PORT:-${MAIN_PROXY_PORT:-}}"
if [ -z "$APP_PORT" ]; then
  APP_PORT=$(direnv exec . bash -c 'echo "${PHOENIX_PORT:-${MAIN_PROXY_PORT:-4000}}"' 2>/dev/null | tail -1)
fi
APP_PORT="${APP_PORT:-4000}"

FRONT_PORT="${FRONTEND_PORT:-${VITE_PORT:-}}"
if [ -z "$FRONT_PORT" ]; then
  FRONT_PORT=$(direnv exec . bash -c 'echo "${FRONTEND_PORT:-${VITE_PORT:-5200}}"' 2>/dev/null | tail -1)
fi
FRONT_PORT="${FRONT_PORT:-5200}"

PG_PORT="${POSTGRES_PORT:-25432}"

# Verify postgres is running on the expected port
if ! lsof -i :"$PG_PORT" -sTCP:LISTEN > /dev/null 2>&1; then
  echo "ERROR: Postgres not running on port $PG_PORT"
  echo "Start it: direnv exec . devenv up -d postgres"
  exit 1
fi

# Clean up any stale state first — use devenv only, no kill commands
direnv exec . devenv processes stop backend frontend 2>/dev/null || true
rm -f .devenv/processes.sock .devenv/run/pc.sock

# If something is still on our port after devenv stop, warn but don't kill it
if lsof -ti :"$APP_PORT" -sTCP:LISTEN > /dev/null 2>&1; then
  echo "WARNING: Port $APP_PORT still in use after devenv stop. Waiting 5s..."
  sleep 5
fi

# Run migrations (fast if already up to date)
direnv exec . mix ecto.migrate --quiet 2>/dev/null || direnv exec . mix ecto.migrate

# Start backend + frontend
direnv exec . devenv up -d backend frontend

# Wait for backend to be ready (check every 3s, up to 90s)
echo "Waiting for backend on port $APP_PORT..."
for i in $(seq 1 30); do
  # 200 = live GraphQL; 410 = procurement's intentional /gql tombstone (backend up).
  CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://localhost:$APP_PORT/gql" \
    -H "Content-Type: application/json" -d '{"query":"{ __typename }"}' 2>/dev/null)
  if [ "$CODE" = "200" ] || [ "$CODE" = "410" ]; then
    echo "Backend ready after $((i * 3))s"
    echo "Phoenix: http://localhost:$APP_PORT"
    echo "Frontend: http://localhost:$FRONT_PORT"
    exit 0
  fi
  sleep 3
done

echo "WARNING: Backend not responding after 90s (may still be compiling)"
echo "Check logs: direnv exec . devenv processes logs backend"
exit 1
