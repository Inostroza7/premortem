# PREMORTEM v2 · Runbook: publicar la base de datos en Supabase

Versión 2.0 · 03/10/2026 · Clasificación: Información Organizacional — Ocular Solution

Proyecto destino: `fyybyttemawstuuxcmjh` (`https://fyybyttemawstuuxcmjh.supabase.co`).
Contrato de referencia: `docs/PREMORTEM_SPEC_V2.md`. Las migraciones v1 quedaron archivadas en `docs/archive/v1-migrations/`.

## 0. Estado actual

Hecho y probado en local (Postgres 17.6, imagen oficial de Supabase, puertos 56xxx):

- Nueve migraciones en `supabase/migrations/` (`20261003100001` a `…100009`): fundamentos y roles, tenencia y seguridad, catálogo, billing, ejecución, evidencia, permisos y RLS, funciones del motor, Realtime.
- Esquema genérico según V2: `public` con metadatos y proyecciones legibles por RLS; `core` con payloads privados, oráculos, estado de intentos, cola nativa de trabajos y 42 funciones (motor, utilidades y triggers); `billing` con wallet, ledger, reservas por job, compras y eventos Stripe. Ningún nombre de dominio aparece en el SQL.
- Cola de trabajos nativa en `core.job_queue` (SKIP LOCKED, visibilidad, archivo). Se descartó pgmq porque en el proyecto alojado su esquema pertenece al superusuario de Supabase y `postgres` no puede otorgar privilegios sobre él.
- Tres roles: `premortem_owner` (sin login, dueño de las funciones, único con DML), `premortem_api` y `premortem_worker` (login, solo EXECUTE enumerado, sin acceso a tablas).
- Prueba de humo `tests/db/smoke.sql` con catorce bloques, todos superados: alta de usuario con 8 unidades, catálogo, cotización y reserva idempotente, dos jobs en paralelo y límite por workspace, el caso 25 + 25 con replay técnico, payload cifrado con clave del workspace, cierre con cobertura de reglas y liquidación, lease por job con recuperación única, cancelación durable, cadena de evidencia y purga auditada, fronteras de los tres roles, RLS entre usuarios, compra Stripe sandbox idempotente y un segundo paquete (calendario) sobre el mismo motor.

**Publicado el 03/10/2026 en `fyybyttemawstuuxcmjh`.** Migraciones aplicadas (nueve iniciales más `20261004000001_worker_protocol`, que permite al worker preasignar el ID del intento) y registradas (`supabase db push`, dry-run posterior "Remote database is up to date"), contraseñas de `premortem_api` y `premortem_worker` aplicadas, prueba de humo de catorce bloques superada contra el proyecto, y verificación posterior en verde: RLS en las 25 tablas, 42 funciones en `core` (32 propiedad de `premortem_owner`), 13 ejecutables por la API, 10 por el worker, 0 por `anon`, solo `current_workspace_ids` para `authenticated`, cero privilegios de tabla para los roles de conexión, cola vacía y política de Realtime presente. Ambos roles conectan por el pooler (worker en sesión 5432, API en transacción 6543) y el worker no puede leer tablas.

Nota de red: la cadena de **conexión directa** (`db.<ref>.supabase.co`) solo resuelve por IPv6. Usa siempre las cadenas del **pooler** (`aws-0-us-east-2.pooler.supabase.com`), que es lo que `scripts/env-init.sh` construye.

Confirmado en el Dashboard el 03/10/2026: Settings → Data API → Exposed schemas contiene solo `public` y `graphql_public`; `core` y `billing` no están expuestos.

Comprobaciones de punta a punta del 03/10/2026:

- **Realtime:** `realtime.send` existe y, tras la primera conexión de un cliente websocket, el servicio creó las particiones diarias de `realtime.messages` y el sondeo insertó el mensaje. En un proyecto recién creado los avisos se descartan (con WARNING) hasta esa primera conexión; la UI debe sondear como respaldo, que es lo previsto.
- **Deriva de esquema:** `supabase db diff --linked --schema public,core,billing` solo reporta `public.rls_auto_enable`, función de la plataforma ligada al event trigger `ensure_rls` que Supabase incluye en proyectos nuevos. Ningún objeto nuestro difiere.
- **Alta de usuario:** el trigger `on_auth_user_created_premortem` se ejecutó en el proyecto con un insert directo en `auth.users` (bloque 1 de la prueba de humo). El alta por la API de Auth no se pudo probar con un correo sintético porque el proyecto valida que el dominio tenga registros MX; se verificará con el primer registro real o con el seed por la Admin API.

## 1. Lo que haces tú (una vez, desde esta sesión con el prefijo `!`)

```
! supabase login
! supabase link --project-ref fyybyttemawstuuxcmjh
```

`login` abre el navegador y guarda el token en tu llavero. `link` pide la contraseña de la base (Dashboard → Settings → Database). La CLI la guarda cifrada en tu equipo.

Crea `.env.local` desde `.env.example` (está en `.gitignore`) y rellena:

```
SUPABASE_DB_ADMIN_URL=        # Dashboard → Connect → Session pooler, usuario postgres.fyybyttemawstuuxcmjh
PREMORTEM_API_PASSWORD=       # openssl rand -base64 32
PREMORTEM_WORKER_PASSWORD=    # openssl rand -base64 32
PREMORTEM_KEK=                # openssl rand -base64 32
```

En el Dashboard, comprueba:

1. Settings → API → Exposed schemas: solo `public` y `graphql_public`. Nunca `core` ni `billing`.
2. Authentication → Providers → Email activado.

## 2. Lo que hago yo después

```
supabase db push --dry-run       # lista las 9 migraciones, no cambia nada
supabase db push                 # las aplica en orden
scripts/db-set-role-passwords.sh # login y contraseña para premortem_api y premortem_worker (lee .env.local)
scripts/db-smoke.sh              # prueba de humo contra el proyecto alojado; termina en ROLLBACK
```

## 3. Verificación posterior

| Comprobación | Consulta | Esperado |
|---|---|---|
| RLS en todas las tablas | `select n.nspname||'.'||c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname in ('public','core','billing') and c.relkind='r' and not c.relrowsecurity` | 0 filas |
| Cola nativa | `select count(*) from core.job_queue` | 0 en una base recién publicada |
| Roles | `select rolname, rolcanlogin from pg_roles where rolname like 'premortem_%'` | owner `f`, api `t`, worker `t` |
| Funciones en core | `select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='core'` | 42 |
| Allowlist API | `select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='core' and has_function_privilege('premortem_api', p.oid, 'execute')` | 13 |
| Allowlist worker | igual con `premortem_worker` | 10 |
| PUBLIC sin acceso interno | igual con `anon` sobre `core` y `billing` | 0 |
| Navegador | igual con `authenticated` | solo `current_workspace_ids` |
| Sin DML para roles de conexión | `select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname in ('public','core','billing') and c.relkind='r' and (has_table_privilege('premortem_worker', c.oid, 'select, insert, update, delete') or has_table_privilege('premortem_api', c.oid, 'select, insert, update, delete'))` | 0 |
| Política Realtime | `select policyname from pg_policies where schemaname='realtime'` | `premortem_run_topic_members` |

Todos estos valores se verificaron en local y en el proyecto alojado el 03/10/2026.

Y la prueba de humo completa contra el proyecto alojado.

## 4. Cadenas de conexión por proceso (formato, sin secretos)

Host del pooler: Dashboard → Connect (`aws-0-<region>.pooler.supabase.com`).

| Proceso | Modo | Usuario | Puerto | Variable |
|---|---|---|---|---|
| Worker (persistente) | Session | `premortem_worker.fyybyttemawstuuxcmjh` | 5432 | `SUPABASE_DB_URL_WORKER` |
| API en Vercel (serverless) | Transaction, `prepare: false` | `premortem_api.fyybyttemawstuuxcmjh` | 6543 | `SUPABASE_DB_URL_API` |
| Migraciones y scripts | Session | `postgres.fyybyttemawstuuxcmjh` | 5432 | `SUPABASE_DB_ADMIN_URL` |
| Navegador | Supabase JS, clave publicable | sesión del usuario | — | `NEXT_PUBLIC_*` |

El navegador lee con RLS a través de Supabase. La API valida la sesión con Supabase Auth y llama a las funciones `core.*` con su propia conexión, pasando el `user_id` validado. El worker solo llama a sus diez funciones (tres de cola y siete del motor) con el lease del job.

## 5. Qué garantiza la base y qué queda en la aplicación

| En Postgres | En la aplicación (TypeScript) |
|---|---|
| Pertenencia workspace → proyecto → run → job → intento activo | Semántica de cada dominio (`DomainPack`) |
| Lease por job con epoch, heartbeat y recuperación única | Cálculo puro de transiciones y mutaciones |
| Idempotencia técnica por `commit_id` y CAS de `state_version` | `operation_key` del agente y su estrategia |
| Secuencia contigua y enlace `prev_hash → event_hash` | Hashes con JSON canónico (JCS) y verificación del export |
| Reserva, consumo y liberación de unidades una sola vez | Cotización mostrada al usuario y flujo de Checkout |
| Payloads privados con digest, clave del workspace y purga auditada | Cifrado AES-256-GCM con AAD que incluye el UUID del evento |
| RLS por membresía y allowlists de funciones por rol | Validación de la sesión y derivación del workspace |

## 6. Operación

- **Nueva migración:** `supabase migration new <nombre>`, `supabase db reset` en local, `scripts/db-smoke.sh --local`, luego `supabase db push`.
- **Rotar contraseñas de roles:** cambiar las variables en `.env.local`, ejecutar `scripts/db-set-role-passwords.sh`, redesplegar API y worker.
- **Rotar la KEK:** nueva `PREMORTEM_KEK` con otro `PREMORTEM_KEK_ID`; re-envolver `core.data_keys` desde la aplicación.
- **Retención:** `core.purge_payload` solo lo ejecuta administración; conserva digest y deja fila en `core.access_log`. El plazo se define con el responsable del SGSI.
- **Copias:** Point in Time Recovery si el plan lo permite; si no, respaldo diario. El export de evidencia es la segunda copia.
- **Incidente:** una credencial pegada en chat, repositorio o canal se rota de inmediato y se avisa a security@ocularsolution.com.

## 7. Lista de comprobación antes de la primera demo

- [x] `supabase db push` sin errores y base remota al día (03/10/2026).
- [x] Prueba de humo superada en el proyecto alojado (03/10/2026).
- [x] Exposed schemas sin `core` ni `billing` (confirmado 03/10/2026).
- [x] Roles `premortem_api` y `premortem_worker` con login y conectando por el pooler (03/10/2026).
- [ ] Dos usuarios de prueba creados por la API de Auth: uno no ve los runs del otro (pendiente de la app; a nivel SQL ya probado).
- [ ] Paquetes `refunds` y `calendar` registrados desde la aplicación.
- [ ] Producto y precio de prueba de Stripe creados; webhook apuntando a la API.
- [x] `.env.local` fuera de Git con permisos 600; `.env.example` sin valores.

## 8. Fuera de este runbook

- Seed de la demo (paquetes, casos, agentes de referencia, usuario demo): desde la aplicación con `pnpm seed:demo`.
- Biblioteca de evidencia (JCS, hashes, export, verificación) y de cifrado: paquetes `evidence` y `persistence` del monorepo.
- Reducción de contraejemplos: usa `create_run` con `kind = 'reduction'` y `p_jobs_override`; el coordinador vive en el worker.
