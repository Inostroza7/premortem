-- PREMORTEM · 0002 · Tenencia por workspace y catálogo inmutable (dominios, tareas, versiones de agente).
-- Genérico: ningún nombre de dominio concreto aparece en el esquema. Un dominio es un paquete
-- (fixture, herramientas, escenarios, invariantes) registrado en public.domains y ejecutado por el worker.

-- ---------------------------------------------------------------------------
-- Workspaces: unidad de tenencia. Cada usuario recibe uno personal al registrarse.
-- ---------------------------------------------------------------------------
create table public.workspaces (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(name) between 1 and 120),
  created_by  uuid references auth.users(id) on delete set null,
  created_at  timestamptz not null default now()
);

create table public.workspace_members (
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  user_id      uuid not null references auth.users(id) on delete cascade,
  role         text not null default 'member' check (role in ('owner','member')),
  created_at   timestamptz not null default now(),
  primary key (workspace_id, user_id)
);
create index workspace_members_user_idx on public.workspace_members (user_id);

-- Workspaces del usuario autenticado. security definer evita recursión de RLS y se evalúa
-- una vez por sentencia (stable) dentro de las políticas.
create or replace function core.current_workspace_ids()
returns setof uuid
language sql stable security definer
set search_path = ''
as $$
  select m.workspace_id
    from public.workspace_members m
   where m.user_id = (select auth.uid());
$$;
revoke execute on function core.current_workspace_ids() from public;
grant  execute on function core.current_workspace_ids() to authenticated, premortem_worker;

-- Alta automática de workspace personal al crear un usuario en Supabase Auth.
create or replace function core.handle_new_user()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare v_ws uuid;
begin
  insert into public.workspaces (name, created_by)
  values (coalesce(nullif(split_part(new.email, '@', 1), ''), 'workspace'), new.id)
  returning id into v_ws;
  insert into public.workspace_members (workspace_id, user_id, role) values (v_ws, new.id, 'owner');
  return new;
end $$;

drop trigger if exists on_auth_user_created_premortem on auth.users;
create trigger on_auth_user_created_premortem
  after insert on auth.users
  for each row execute function core.handle_new_user();

-- ---------------------------------------------------------------------------
-- Dominios: catálogo global de paquetes ejecutables. Lo registra el servidor (seed), lo lee todo
-- usuario autenticado. scenarios/tools/invariants son descriptores JSON; la lógica vive en el worker.
-- ---------------------------------------------------------------------------
create table public.domains (
  id            text primary key check (id ~ '^[a-z0-9][a-z0-9-]{1,63}$'),
  version       text not null,
  label         text not null,
  description   text not null default '',
  scenarios     jsonb not null default '{}'::jsonb,   -- { scenario_id: {label, description, mutations:[...]} }
  tools         jsonb not null default '[]'::jsonb,   -- [{name, description, input_schema, writes:boolean, capability}]
  invariants    jsonb not null default '[]'::jsonb,   -- [{id, label, severity}]
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint domains_scenarios_object check (jsonb_typeof(scenarios) = 'object'),
  constraint domains_tools_array      check (jsonb_typeof(tools) = 'array'),
  constraint domains_invariants_array check (jsonb_typeof(invariants) = 'array')
);

-- ---------------------------------------------------------------------------
-- Versiones de agente: inmutables. Editar = nueva fila.
-- ---------------------------------------------------------------------------
create table public.agent_versions (
  id                uuid primary key default gen_random_uuid(),
  workspace_id      uuid not null references public.workspaces(id) on delete cascade,
  created_by        uuid references auth.users(id) on delete set null,
  label             text not null check (length(label) between 1 and 120),
  mode              text not null check (mode in ('reference','live')),
  reference_policy  text,                 -- identificador de política determinista del dominio
  system_prompt_enc bytea,                -- cifrado de sobre (ver core.data_keys); solo mode = live
  prompt_hmac       bytea,                -- HMAC del prompt en claro: igualdad sin descifrar
  model_id          text,
  config            jsonb not null default '{}'::jsonb,
  content_hash      bytea not null,       -- sha256 del contenido lógico de la versión
  created_at        timestamptz not null default now(),
  constraint agent_versions_mode_shape check (
    (mode = 'reference' and reference_policy is not null and system_prompt_enc is null)
    or
    (mode = 'live' and system_prompt_enc is not null and model_id is not null)
  )
);
create index agent_versions_ws_idx on public.agent_versions (workspace_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Tareas: lo que el agente puede ver. El oráculo (lo que el evaluador sabe) va en core.
-- ---------------------------------------------------------------------------
create table public.tasks (
  id               uuid primary key default gen_random_uuid(),
  workspace_id     uuid not null references public.workspaces(id) on delete cascade,
  created_by       uuid references auth.users(id) on delete set null,
  domain_id        text not null references public.domains(id),
  fixture_version  text not null,
  label            text not null check (length(label) between 1 and 160),
  instruction      text not null,
  request_id       text not null,
  public_task      jsonb not null default '{}'::jsonb,   -- parámetros visibles de la tarea
  trusted_context  jsonb not null default '{}'::jsonb,   -- contexto verificable consultable por el agente
  content_hash     bytea not null,
  created_at       timestamptz not null default now()
);
create index tasks_ws_idx on public.tasks (workspace_id, created_at desc);

create table core.task_oracles (
  task_id    uuid primary key references public.tasks(id) on delete cascade,
  expected   jsonb not null,            -- resultado esperado según el dominio; nunca visible al agente
  created_at timestamptz not null default now()
);

-- Inmutabilidad del catálogo: no se actualiza. Borrar solo si ningún run lo referencia (FK sin cascade).
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

create trigger agent_versions_immutable before update on public.agent_versions
  for each row execute function core.forbid_update();
create trigger tasks_immutable before update on public.tasks
  for each row execute function core.forbid_update();
create trigger task_oracles_immutable before update on core.task_oracles
  for each row execute function core.forbid_update();
