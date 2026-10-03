-- PREMORTEM · 0001 · Fundamentos: extensiones, esquema interno, rol del worker y cola.
-- Convenciones: todo en minúsculas, dinero en centavos bigint, tiempos timestamptz,
-- ids uuid generados en servidor. Nada de este archivo contiene secretos.

create extension if not exists pgcrypto with schema extensions;
create extension if not exists pgmq;

-- Esquema interno. No se expone a PostgREST (Settings → API → Exposed schemas: solo public).
create schema if not exists core;
comment on schema core is
  'PREMORTEM: oráculos, claves envueltas, auditoría y funciones del simulador. Solo rol premortem_worker.';

-- Rol de servidor para worker y API. Se crea sin login; la contraseña se asigna fuera de Git
-- (ver scripts/db-set-worker-password.sh). Nunca usar service_role ni postgres desde la app.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'premortem_worker') then
    create role premortem_worker nologin noinherit;
  end if;
end $$;

-- postgres (rol de migraciones y administración) puede asumir el rol del worker para pruebas y soporte.
grant premortem_worker to postgres with set true, inherit false;

revoke all on schema core from public;
grant usage on schema core       to premortem_worker;
grant usage on schema public     to premortem_worker;
grant usage on schema extensions to premortem_worker;
grant usage on schema pgmq       to premortem_worker;

-- Las funciones nuevas en core no deben ser ejecutables por cualquiera.
alter default privileges in schema core revoke execute on functions from public;

-- Cola de trabajos (un mensaje por run). Durable, transaccional, en el mismo Postgres.
select pgmq.create('premortem_jobs');
grant select, insert, update, delete on all tables in schema pgmq to premortem_worker;
grant usage, select on all sequences in schema pgmq to premortem_worker;
grant execute on all functions in schema pgmq to premortem_worker;
