#!/usr/bin/env bash
# Levanta el entorno local completo desde cero: Supabase local (puertos 56xxx), migraciones, roles,
# paquetes registrados y archivo .env.localdb. No toca ningún proyecto alojado.
#   scripts/local-up.sh            → arranca y aplica migraciones (conserva datos si ya existía)
#   scripts/local-up.sh --reset    → borra la base LOCAL y la recrea (solo local)
set -euo pipefail
cd "$(dirname "$0")/.."

command -v supabase >/dev/null || { echo "Instala la CLI de Supabase: brew install supabase/tap/supabase" >&2; exit 1; }
command -v docker >/dev/null && docker info >/dev/null 2>&1 || { echo "Docker debe estar corriendo" >&2; exit 1; }
command -v pnpm >/dev/null || { echo "Instala pnpm: corepack enable" >&2; exit 1; }

pnpm install --frozen-lockfile
supabase start -x studio,imgproxy,inbucket,edge-runtime,logflare,vector,supavisor >/dev/null
if [[ "${1:-}" == "--reset" ]]; then supabase db reset >/dev/null; else supabase migration up >/dev/null; fi

eval "$(supabase status -o env 2>/dev/null | grep -E '^(API_URL|PUBLISHABLE_KEY|ANON_KEY)=')"
if [[ ! -f .env.localdb ]]; then
  API_PW="$(openssl rand -hex 24)"; WK_PW="$(openssl rand -hex 24)"
  cat > .env.localdb <<ENV
# Supabase local (puertos 56xxx). Generado por scripts/local-up.sh; sin secretos de nube.
PREMORTEM_ENV=local
NEXT_PUBLIC_SUPABASE_URL=${API_URL}
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=${PUBLISHABLE_KEY:-$ANON_KEY}
SUPABASE_DB_ADMIN_URL=postgresql://postgres:postgres@127.0.0.1:56322/postgres
SUPABASE_DB_URL_API=postgresql://premortem_api:${API_PW}@127.0.0.1:56322/postgres
SUPABASE_DB_URL_WORKER=postgresql://premortem_worker:${WK_PW}@127.0.0.1:56322/postgres
PREMORTEM_API_PASSWORD=${API_PW}
PREMORTEM_WORKER_PASSWORD=${WK_PW}
CORS_ORIGINS=http://localhost:3000,http://localhost:5173
PREMORTEM_HEARTBEAT_SECONDS=5
ENV
  chmod 600 .env.localdb
fi
scripts/db-set-role-passwords.sh --local
PREMORTEM_ENV=local pnpm -s packs:register
echo
echo "Listo. En dos terminales:"
echo "  PREMORTEM_ENV=local pnpm dev       # API en http://localhost:3000"
echo "  PREMORTEM_ENV=local pnpm worker    # ejecutor de mundos"
echo "Prueba de punta a punta: PREMORTEM_ENV=local pnpm test:e2e"
