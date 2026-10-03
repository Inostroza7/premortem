#!/usr/bin/env bash
# Completa .env.local sin pasar secretos por el chat ni por Git.
#   - Genera PREMORTEM_API_PASSWORD, PREMORTEM_WORKER_PASSWORD, PREMORTEM_KEK y PREMORTEM_PROMPT_HMAC_KEY si están vacíos.
#   - Pide la contraseña de la base (usuario postgres) en la terminal, sin eco, y construye las cadenas de
#     conexión a partir de la plantilla del pooler que guardó `supabase link`.
#   - Comprueba la conexión de administración. Nunca imprime valores.
# Uso: scripts/env-init.sh   (desde la terminal; en la sesión de Claude Code: ! scripts/env-init.sh)
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -f .env.local ]] || cp .env.example .env.local
chmod 600 .env.local

template_file="supabase/.temp/pooler-url"
if [[ ! -f "$template_file" ]]; then
  echo "No existe $template_file. Ejecuta antes: supabase link --project-ref fyybyttemawstuuxcmjh" >&2
  exit 1
fi
template="$(tr -d '\n' < "$template_file")"          # postgresql://postgres.<ref>@<host>:5432/postgres

# Valor actual de una variable en .env.local (vacío si no está o solo tiene comentario)
getvar() { bash -c "set -a; source .env.local 2>/dev/null; set +a; printf '%s' \"\${$1:-}\""; }

gen() { openssl rand -base64 32 | tr -d '\n'; }
API_PW="$(getvar PREMORTEM_API_PASSWORD)";       [[ -n "$API_PW" ]]    || API_PW="$(gen)"
WORKER_PW="$(getvar PREMORTEM_WORKER_PASSWORD)"; [[ -n "$WORKER_PW" ]] || WORKER_PW="$(gen)"
KEK="$(getvar PREMORTEM_KEK)";                   [[ -n "$KEK" ]]       || KEK="$(gen)"
HMAC="$(getvar PREMORTEM_PROMPT_HMAC_KEY)";      [[ -n "$HMAC" ]]      || HMAC="$(gen)"
if [[ "$API_PW" == "$WORKER_PW" ]]; then WORKER_PW="$(gen)"; fi

ADMIN_URL="$(getvar SUPABASE_DB_ADMIN_URL)"
if [[ -z "$ADMIN_URL" ]]; then
  echo "Contraseña de la base de datos del proyecto (Dashboard → Settings → Database). No se mostrará:"
  read -rs -p "> " DB_PW; echo
  [[ -n "$DB_PW" ]] || { echo "Contraseña vacía." >&2; exit 1; }
else
  DB_PW=""
fi

# Construye las URLs con contraseñas URL-encoded y reescribe .env.local
TEMPLATE="$template" DB_PW="$DB_PW" API_PW="$API_PW" WORKER_PW="$WORKER_PW" KEK="$KEK" HMAC="$HMAC" ADMIN_URL="$ADMIN_URL" \
python3 - <<'EOF'
import os, re, pathlib
from urllib.parse import quote
t = os.environ['TEMPLATE']
m = re.match(r'^(postgres(?:ql)?://)([^@:/]+)@([^:/]+):(\d+)/(.*)$', t)
if not m:
    raise SystemExit('plantilla del pooler no reconocida')
scheme, user, host, port, db = m.groups()
ref = user.split('.', 1)[1] if '.' in user else ''
q = lambda s: quote(s, safe='')
vals = {}
if os.environ['ADMIN_URL']:
    vals['SUPABASE_DB_ADMIN_URL'] = os.environ['ADMIN_URL']
else:
    vals['SUPABASE_DB_ADMIN_URL'] = f"{scheme}{user}:{q(os.environ['DB_PW'])}@{host}:5432/{db}"
vals['SUPABASE_DB_URL_API']    = f"{scheme}premortem_api.{ref}:{q(os.environ['API_PW'])}@{host}:6543/{db}"
vals['SUPABASE_DB_URL_WORKER'] = f"{scheme}premortem_worker.{ref}:{q(os.environ['WORKER_PW'])}@{host}:5432/{db}"
vals['PREMORTEM_API_PASSWORD'] = os.environ['API_PW']
vals['PREMORTEM_WORKER_PASSWORD'] = os.environ['WORKER_PW']
vals['PREMORTEM_KEK'] = os.environ['KEK']
vals['PREMORTEM_PROMPT_HMAC_KEY'] = os.environ['HMAC']
p = pathlib.Path('.env.local')
lines = p.read_text().splitlines()
seen = set()
out = []
for line in lines:
    k = line.split('=', 1)[0].strip() if '=' in line and not line.lstrip().startswith('#') else None
    if k in vals:
        out.append(f"{k}={vals[k]}"); seen.add(k)
    else:
        out.append(line)
for k, v in vals.items():
    if k not in seen:
        out.append(f"{k}={v}")
p.write_text("\n".join(out) + "\n")
print("variables escritas:", ", ".join(vals.keys()))
EOF
chmod 600 .env.local

# Comprobación de la conexión de administración (sin imprimir la URL)
ADMIN_URL="$(getvar SUPABASE_DB_ADMIN_URL)"
if psql "$ADMIN_URL" -X -At -c "select 1" >/dev/null 2>&1; then
  echo "Conexión de administración: OK"
else
  echo "Conexión de administración: FALLÓ. Revisa la contraseña (puedes borrar SUPABASE_DB_ADMIN_URL= en .env.local y volver a ejecutar)." >&2
  exit 1
fi
echo "Listo. Siguiente: scripts/db-set-role-passwords.sh && scripts/db-smoke.sh"
