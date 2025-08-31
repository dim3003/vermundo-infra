#!/usr/bin/env bash
set -euo pipefail

# --- config ---
BACKEND_REPO="${BACKEND_REPO:-https://github.com/dim3003/vermundo-backend}"
FRONTEND_REPO="${FRONTEND_REPO:-https://github.com/dim3003/vermundo}"
BACKEND_REF="${BACKEND_REF:-}"   # optional: branch/tag/commit
FRONTEND_REF="${FRONTEND_REF:-}" # optional
BACKEND_DIR="vermundo-backend"
FRONTEND_DIR="vermundo"
API_WORKDIR="/src/src/Vermundo.Api"
SDK_IMAGE="mcr.microsoft.com/dotnet/sdk:9.0"
DB_CONTAINER="db"

die(){ echo "ERROR: $*" >&2; exit 1; }
get_env(){ local k="$1"; [[ -f .env ]] || die ".env missing";
  local v; v="$(grep -E "^\s*${k}\s*=" .env | tail -n1 | sed -E 's/^[^=]+=//')";
  v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"; printf '%s' "$v"; }

POSTGRES_USER="$(get_env POSTGRES_USER)"
POSTGRES_PASSWORD="$(get_env POSTGRES_PASSWORD)"
POSTGRES_DB="$(get_env POSTGRES_DB)"
[[ -n "$POSTGRES_USER" && -n "$POSTGRES_PASSWORD" && -n "$POSTGRES_DB" ]] || die "POSTGRES_* not complete"

echo ">> Stopping any existing stack..."
docker compose down || true

echo ">> Removing existing source folders..."
rm -rf "./${BACKEND_DIR}" "./${FRONTEND_DIR}"

echo ">> Cloning backend..."
git clone --depth 1 "$BACKEND_REPO" "$BACKEND_DIR"
[[ -n "$BACKEND_REF" ]] && (cd "$BACKEND_DIR" && git fetch --depth 1 origin "$BACKEND_REF" && git checkout "$BACKEND_REF")
[[ -d "${BACKEND_DIR}/src/Vermundo.Api" ]] || die "Expected ${BACKEND_DIR}/src/Vermundo.Api"

echo ">> Cloning frontend..."
git clone --depth 1 "$FRONTEND_REPO" "$FRONTEND_DIR"
[[ -n "$FRONTEND_REF" ]] && (cd "$FRONTEND_DIR" && git fetch --depth 1 origin "$FRONTEND_REF" && git checkout "$FRONTEND_REF")

# --- start only DB so migrations can run cleanly ---
echo ">> Starting database only..."
docker compose up -d --build db

echo ">> Waiting for Postgres..."
for i in {1..30}; do
  if docker exec "$DB_CONTAINER" pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" -h 127.0.0.1 -p 5432 >/dev/null 2>&1; then
    echo "   Postgres is ready."
    break
  fi
  sleep 2
  [[ $i -eq 30 ]] && die "Postgres not ready in time"
done

COMPOSE_NET="$(docker inspect "$DB_CONTAINER" --format '{{range $k,$v := .NetworkSettings.Networks}}{{printf "%s" $k}}{{end}}')"
[[ -n "$COMPOSE_NET" ]] || die "Could not detect compose network"

# --- run migrations from disposable SDK container ---
BACKEND_SRC="$(pwd)/${BACKEND_DIR}"
echo ">> Applying EF Core migrations..."
docker run --rm -i \
  --network "$COMPOSE_NET" \
  -v "$BACKEND_SRC:/src" \
  -w "$API_WORKDIR" \
  -e "ConnectionStrings__Database=Host=db;Port=5432;Database=${POSTGRES_DB};Username=${POSTGRES_USER};Password=${POSTGRES_PASSWORD}" \
  "$SDK_IMAGE" \
  bash -lc '
    set -e
    dotnet tool install --global dotnet-ef >/dev/null 2>&1 || true
    export PATH="$PATH:/root/.dotnet/tools"
    dotnet restore
    dotnet ef database update
  '
echo ">> Migrations applied."

# --- NOW start backend + frontend (and rebuild) ---
echo ">> Starting backend and frontend..."
docker compose up -d --build backend frontend

echo ">> Current status:"
docker compose ps

echo "Done. Backend and frontend should be running. To watch logs:"
echo "   docker compose logs -f backend"
echo "   docker compose logs -f frontend"
