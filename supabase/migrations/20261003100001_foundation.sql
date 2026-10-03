-- PREMORTEM v2 · 0001 · Fundamentos: extensiones, esquemas, roles y cola.
--
-- Roles (spec v2 §12):
--   premortem_owner   sin login · propietario de las funciones SECURITY DEFINER · único con DML
--   premortem_api     login (contraseña fuera de Git) · EXECUTE sobre funciones de API enumeradas
--   premortem_worker  login (contraseña fuera de Git) · EXECUTE sobre funciones de worker enumeradas
-- Ningún rol de conexión escribe tablas directamente. PUBLIC no hereda EXECUTE en core/billing.

create extension if not exists pgcrypto with schema extensions;
-- Cola de trabajos: tabla nativa core.job_queue (0005) con SKIP LOCKED, visibilidad y archivo.
-- No se usa pgmq: en el proyecto alojado su esquema pertenece al superusuario y postgres no puede otorgar privilegios.

create schema if not exists core;
create schema if not exists billing;
comment on schema core    is 'PREMORTEM: payloads privados, oráculos, estado de intentos y funciones del motor. No exponer a PostgREST.';
comment on schema billing is 'PREMORTEM: wallet, reservas por job, compras y eventos Stripe. No exponer a PostgREST.';

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'premortem_owner')  then create role premortem_owner  nologin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname = 'premortem_api')    then create role premortem_api    nologin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname = 'premortem_worker') then create role premortem_worker nologin noinherit; end if;
end $$;

-- postgres (migraciones y soporte) puede asumir los tres roles para pruebas; no hereda sus privilegios.
grant premortem_owner, premortem_api, premortem_worker to postgres with set true, inherit false;

revoke all on schema core    from public;
revoke all on schema billing from public;

grant usage, create on schema core    to premortem_owner;
grant usage, create on schema billing to premortem_owner;
grant usage on schema public, extensions to premortem_owner;

grant usage on schema core    to premortem_api, premortem_worker;   -- necesario para invocar funciones
grant usage on schema public  to premortem_api, premortem_worker;

-- Funciones nuevas en core/billing creadas por el rol de migración: sin EXECUTE para PUBLIC.
-- Además, 0008 y 0009 revocan explícitamente. No se usa SET ROLE dentro de migraciones: la CLI registra
-- la migración en la misma sesión y un rol cambiado le impediría escribir en supabase_migrations.
alter default privileges for role postgres in schema core    revoke execute on functions from public;
alter default privileges for role postgres in schema billing revoke execute on functions from public;

