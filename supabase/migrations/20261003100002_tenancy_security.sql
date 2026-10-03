-- PREMORTEM v2 · 0002 · Tenencia (workspaces, miembros, proyectos) y seguridad (payloads privados,
-- claves envueltas, auditoría). Las FKs compuestas con workspace_id impiden que un hijo discrepe del padre.

create table public.workspaces (
  id                uuid primary key default gen_random_uuid(),
  name              text not null check (length(name) between 1 and 120),
  created_by        uuid references auth.users(id) on delete set null,
  max_active_jobs   integer not null default 2  check (max_active_jobs between 1 and 64),
  max_jobs_per_run  integer not null default 12 check (max_jobs_per_run between 1 and 256),
  created_at        timestamptz not null default now()
);

create table public.workspace_members (
  workspace_id  uuid not null references public.workspaces(id) on delete cascade,
  user_id       uuid not null references auth.users(id) on delete cascade,
  role          text not null default 'member' check (role in ('owner','member')),
  created_at    timestamptz not null default now(),
  primary key (workspace_id, user_id)
);
create index workspace_members_user_idx on public.workspace_members (user_id);

create table public.projects (
  id            uuid primary key default gen_random_uuid(),
  workspace_id  uuid not null references public.workspaces(id) on delete cascade,
  name          text not null check (length(name) between 1 and 120),
  created_by    uuid references auth.users(id) on delete set null,
  created_at    timestamptz not null default now(),
  constraint projects_id_ws_unique unique (id, workspace_id)
);
create index projects_ws_idx on public.projects (workspace_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Claves de datos envueltas (cifrado de sobre en la aplicación; la KEK vive fuera de la base)
-- ---------------------------------------------------------------------------
create table core.data_keys (
  id            uuid primary key default gen_random_uuid(),
  workspace_id  uuid not null references public.workspaces(id) on delete cascade,
  kek_id        text not null,
  wrapped_dek   bytea not null,
  alg           text not null default 'A256GCM' check (alg in ('A256GCM')),
  status        text not null default 'active' check (status in ('active','retired')),
  created_at    timestamptz not null default now(),
  retired_at    timestamptz,
  constraint data_keys_id_ws_unique unique (id, workspace_id)
);
create unique index data_keys_one_active_idx on core.data_keys (workspace_id) where status = 'active';

-- ---------------------------------------------------------------------------
-- Payloads privados: separados del envelope de evento. El id lo preasigna la aplicación
-- (forma parte del AAD al cifrar). El digest sobrevive a la purga por retención.
-- ---------------------------------------------------------------------------
create table core.payloads (
  id              uuid primary key,
  workspace_id    uuid not null references public.workspaces(id) on delete cascade,
  owner_kind      text not null check (owner_kind in ('agent_prompt','event','attempt_final','rule_result','case')),
  owner_id        uuid,
  classification  text not null check (classification in ('public','internal','confidential','restricted')),
  encrypted       boolean not null default false,
  content         jsonb,                 -- en claro (no cifrado)
  blob            bytea,                 -- cifrado por la aplicación (formato versionado con key_id y nonce)
  digest          bytea not null,        -- sha256 del contenido canónico o del blob
  byte_size       integer not null check (byte_size between 0 and 262144),
  key_id          uuid,
  created_at      timestamptz not null default now(),
  purged_at       timestamptz,
  purge_reason    text,
  constraint payloads_id_ws_unique unique (id, workspace_id),
  constraint payloads_key_fk foreign key (key_id, workspace_id) references core.data_keys (id, workspace_id),
  constraint payloads_shape check (
       (purged_at is not null and content is null and blob is null)
    or (purged_at is null and encrypted and blob is not null and content is null and key_id is not null)
    or (purged_at is null and not encrypted and content is not null and blob is null and key_id is null)
  )
);
create index payloads_owner_idx on core.payloads (owner_kind, owner_id);

-- Solo se admite la transición "no purgado → purgado": content/blob a null, purged_at fijado, resto intacto.
create or replace function core.payloads_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'IMMUTABLE_ROW' using errcode = 'PM409', detail = 'core.payloads';
  end if;
  if old.purged_at is null and new.purged_at is not null
     and new.content is null and new.blob is null
     and new.id = old.id and new.workspace_id = old.workspace_id and new.owner_kind = old.owner_kind
     and new.owner_id is not distinct from old.owner_id and new.classification = old.classification
     and new.encrypted = old.encrypted and new.digest = old.digest and new.byte_size = old.byte_size
     and new.key_id is not distinct from old.key_id and new.created_at = old.created_at then
    return new;
  end if;
  -- se permite completar owner_id una sola vez (insertado antes que su dueño)
  if old.owner_id is null and new.owner_id is not null
     and (to_jsonb(new) - 'owner_id') = (to_jsonb(old) - 'owner_id') then
    return new;
  end if;
  raise exception 'IMMUTABLE_ROW' using errcode = 'PM409', detail = 'core.payloads',
    hint = 'Solo se permite purgar (content/blob a null con purged_at) o fijar owner_id una vez.';
end $$;
create trigger payloads_guard before update or delete on core.payloads
  for each row execute function core.payloads_guard();

-- ---------------------------------------------------------------------------
-- Auditoría de acceso a contenido protegido. Append-only.
-- ---------------------------------------------------------------------------
create table core.access_log (
  id             bigint generated always as identity primary key,
  workspace_id   uuid not null,
  actor_user_id  uuid,
  actor_kind     text not null check (actor_kind in ('user','api','worker','cron','admin')),
  action         text not null,
  resource_type  text not null,
  resource_id    uuid,
  detail         jsonb not null default '{}'::jsonb,
  created_at     timestamptz not null default now()
);
create index access_log_ws_idx on core.access_log (workspace_id, created_at desc);

create or replace function core.forbid_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'IMMUTABLE_ROW'
    using errcode = 'PM409', detail = tg_table_schema || '.' || tg_table_name,
          hint = 'Tabla append-only.';
end $$;

create or replace function core.forbid_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'IMMUTABLE_ROW'
    using errcode = 'PM409', detail = tg_table_schema || '.' || tg_table_name,
          hint = 'Crea una versión nueva en lugar de editar.';
end $$;

create trigger access_log_immutable before update or delete on core.access_log
  for each row execute function core.forbid_change();
