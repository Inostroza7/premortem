#!/usr/bin/env bash
# Habilita login y asigna contraseña a los roles de conexión premortem_api y premortem_worker.
# Las contraseñas se leen de .env.local y viajan a psql como variables (:'var'): no pasan por Git,
# por argumentos visibles en `ps` ni por la salida de la terminal.
#   scripts/db-set-role-passwords.sh            → proyecto alojado (SUPABASE_DB_ADMIN_URL)
#   scripts/db-set-role-passwords.sh --local    → instancia local (LOCAL_DB_URL o puerto 56322)
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
: "${PREMORTEM_API_PASSWORD:?Define PREMORTEM_API_PASSWORD en .env.local (openssl rand -base64 32)}"
: "${PREMORTEM_WORKER_PASSWORD:?Define PREMORTEM_WORKER_PASSWORD en .env.local (openssl rand -base64 32)}"

for v in PREMORTEM_API_PASSWORD PREMORTEM_WORKER_PASSWORD; do
  val="${!v}"
  if (( ${#val} < 24 )); then
    echo "$v demasiado corta (mínimo 24 caracteres)" >&2
    exit 1
  fi
done
if [[ "$PREMORTEM_API_PASSWORD" == "$PREMORTEM_WORKER_PASSWORD" ]]; then
  echo "Las contraseñas de api y worker deben ser distintas" >&2
  exit 1
fi

psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 \
  -v api_pw="$PREMORTEM_API_PASSWORD" -v worker_pw="$PREMORTEM_WORKER_PASSWORD" \
  -f scripts/sql/set-role-passwords.sql
echo "premortem_api y premortem_worker: login habilitado y contraseñas aplicadas."
