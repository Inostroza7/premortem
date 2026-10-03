# PREMORTEM

> Test your agent against the world that breaks it.

PREMORTEM ejecuta una versión de agente en mundos simulados, perturba sus condiciones y devuelve fallos respaldados por evidencia. El motor es genérico: cada dominio es un paquete versionado. Hoy hay dos: reembolsos y calendario.

Especificación vigente: [`docs/PREMORTEM_SPEC_V2.md`](docs/PREMORTEM_SPEC_V2.md). API para el front: [`docs/API.md`](docs/API.md). Base de datos: [`docs/DB_RUNBOOK.md`](docs/DB_RUNBOOK.md).

## Arranque local

Requisitos: Node 24, pnpm 10, Docker y la CLI de Supabase.

```bash
pnpm local:up            # Supabase local (puertos 56xxx), migraciones, roles, paquetes y .env.localdb
pnpm dev:local           # API en http://localhost:3000
pnpm worker:local        # ejecutor de mundos (puedes abrir varios)
pnpm test:e2e:local      # prueba de punta a punta por HTTP
```

`pnpm local:up --reset` borra y recrea solo la base local.

## Estructura

```text
apps/web/                    API (Next.js App Router, rutas /api) y futura UI
apps/worker/                 Ejecutor: cola, lease por job, heartbeat, recuperación
packages/contracts/          Tipos y esquemas Zod compartidos
packages/engine/             Motor genérico: gateway, mutaciones, límites, veredicto
packages/evidence/           JSON canónico (RFC 8785), hashes, verificación de cadena
packages/db/                 Llamadas a las funciones core.* (sin acceso directo a tablas)
packages/domains/refunds/    Paquete de reembolsos: herramientas, mutaciones, reglas, políticas, caso
packages/domains/calendar/   Paquete de calendario: mismo contrato, otro dominio
packages/domain-registry/    Único lugar que importa paquetes concretos
supabase/migrations/         Esquema publicado
tests/conformance/           Matriz 2 dominios × 2 políticas × 4 escenarios, en memoria
tests/db/smoke.sql           Prueba de la capa de datos; termina en ROLLBACK
tests/e2e/run.ts             Prueba HTTP completa contra API y worker
```

## Comandos

| Comando | Qué hace |
|---|---|
| `pnpm test` | Conformidad de paquetes y evidencia (sin base de datos) |
| `pnpm domain:check refunds` | Comprueba un paquete contra el contrato |
| `pnpm typecheck` | TypeScript en todo el monorepo |
| `pnpm build` | Build de producción de la API |
| `pnpm packs:register` | Registra los paquetes en el entorno de `.env.local` (idempotente) |
| `pnpm db:smoke:local` / `pnpm db:smoke` | Prueba de la base local o alojada |

## Entornos

| Variable | Archivo | Uso |
|---|---|---|
| `PREMORTEM_ENV=local` | `.env.localdb` | Supabase local; lo genera `pnpm local:up` |
| sin variable | `.env.local` | Proyecto alojado; lo genera `scripts/env-init.sh` |

Ambos archivos están fuera de Git. Nunca se suben credenciales al repositorio ni al chat. Si una credencial se expone, se rota y se avisa a security@ocularsolution.com.

## Añadir un dominio

1. Crear `packages/domains/<nombre>/` implementando `DomainPack` de `@premortem/contracts`: herramientas, `initialize`, `applyTool`, `mutate`, `evaluate`, escenarios, políticas de referencia y caso de demo.
2. Añadirlo a `packages/domain-registry`.
3. `pnpm domain:check <nombre>` y `pnpm packs:register`.

No hace falta tocar el motor, el worker, la API, el SQL ni el billing.

## Estado

Hecho: base de datos publicada, motor, dos paquetes, worker con lease y recuperación, API con 17 rutas, Realtime privado, export verificable. Pendiente: Stripe Checkout, driver con modelo real (Anthropic), MCP, reducción de contraejemplos y UI.
