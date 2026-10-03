#!/usr/bin/env bash
# Ejecuta la prueba de humo de la capa de datos. Termina en ROLLBACK: no deja datos.
#   scripts/db-smoke.sh            → contra el proyecto alojado (SUPABASE_DB_ADMIN_URL de .env.local)
#   scripts/db-smoke.sh --local    → contra la instancia local (LOCAL_DB_URL o el puerto 56322 por defecto)
set -euo pipefail
cd "$(dirname "$0")/.."

# --local usa .env.localdb (Supabase local); sin flag, .env.local (proyecto alojado).
ENV_FILE=".env.local"; [[ "${1:-}" == "--local" ]] && ENV_FILE=".env.localdb"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
fi

if [[ "${1:-}" == "--local" ]]; then
  DB_URL="${LOCAL_DB_URL:-postgresql://postgres:postgres@127.0.0.1:56322/postgres}"
else
  DB_URL="${SUPABASE_DB_ADMIN_URL:?Define SUPABASE_DB_ADMIN_URL en .env.local (session pooler, usuario postgres)}"
fi

# La URL no se imprime nunca: contiene la contraseña.
psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 -f tests/db/smoke.sql 2>&1 \
  | sed -E 's/^psql:tests\/db\/smoke\.sql:[0-9]+: //' \
  | grep -E '^(NOTICE|ERROR|CONTEXT|DETAIL|HINT|ROLLBACK)' || true
