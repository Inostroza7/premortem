-- PREMORTEM · 0005 · Seguridad: claves de datos envueltas (cifrado de sobre) y registro de accesos.
-- El cifrado ocurre en la aplicación (AES-256-GCM). La base solo guarda la DEK envuelta con la KEK,
-- que vive fuera de la base (variable de entorno, Supabase Vault o KMS).

create table core.data_keys (
  id            uuid primary key default gen_random_uuid(),   -- key_id que viaja dentro de cada blob
  workspace_id  uuid not null references public.workspaces(id) on delete cascade,
  kek_id        text not null,                                 -- identificador de la clave maestra usada
  wrapped_dek   bytea not null,                                -- DEK cifrada con la KEK
  alg           text not null default 'A256GCM' check (alg in ('A256GCM')),
  status        text not null default 'active' check (status in ('active','retired')),
  created_at    timestamptz not null default now(),
  retired_at    timestamptz
);
create unique index data_keys_one_active_idx on core.data_keys (workspace_id) where status = 'active';

create table core.access_log (
  id             bigint generated always as identity primary key,
  workspace_id   uuid not null,
  actor_user_id  uuid,                                         -- null cuando actúa el worker o un cron
  actor_kind     text not null check (actor_kind in ('user','api','worker','cron')),
  action         text not null,                                -- decrypt_prompt · read_events · export_run · rotate_key ...
  resource_type  text not null,
  resource_id    uuid,
  detail         jsonb not null default '{}'::jsonb,
  created_at     timestamptz not null default now()
);
create index access_log_ws_idx on core.access_log (workspace_id, created_at desc);

create trigger access_log_immutable before update or delete on core.access_log
  for each row execute function core.forbid_change();
