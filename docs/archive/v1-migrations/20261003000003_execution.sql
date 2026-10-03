-- PREMORTEM · 0003 · Ejecución: runs, mundos e intentos. Estado mutable solo bajo bloqueo (ver 0007).

create table public.runs (
  id                 uuid primary key default gen_random_uuid(),
  workspace_id       uuid not null references public.workspaces(id) on delete cascade,
  created_by         uuid references auth.users(id) on delete set null,
  kind               text not null default 'evaluation' check (kind in ('evaluation','reduction')),
  domain_id          text not null references public.domains(id),
  task_id            uuid not null references public.tasks(id),
  agent_version_id   uuid not null references public.agent_versions(id),
  suite_version      text not null,
  simulator_version  text not null,
  seed               integer not null,
  input_snapshot     jsonb not null,          -- tarea, versión, mundos y mutaciones efectivas, congelados
  input_hash         bytea not null,
  status             text not null default 'queued'
                     check (status in ('queued','running','completed','errored','cancelled')),
  parent_run_id      uuid references public.runs(id),
  reduction_config   jsonb,
  result_summary     jsonb,
  idempotency_key    text,
  request_hash       bytea,
  lease_token        uuid,
  lease_until        timestamptz,
  created_at         timestamptz not null default now(),
  started_at         timestamptz,
  ended_at           timestamptz,
  constraint runs_idempotency_unique unique (workspace_id, idempotency_key),
  constraint runs_idempotency_shape  check ((idempotency_key is null) = (request_hash is null))
);
create index runs_ws_created_idx on public.runs (workspace_id, created_at desc);
create index runs_active_idx     on public.runs (status, lease_until) where status in ('queued','running');
create index runs_parent_idx     on public.runs (parent_run_id) where parent_run_id is not null;

create table public.worlds (
  id                 uuid primary key default gen_random_uuid(),
  run_id             uuid not null references public.runs(id) on delete cascade,
  workspace_id       uuid not null references public.workspaces(id) on delete cascade,
  position           smallint not null check (position >= 0),
  scenario_id        text not null,
  mutations          jsonb not null default '[]'::jsonb,   -- lista de mutaciones efectivas (puede ser vacía)
  seed               integer not null,
  status             text not null default 'queued'
                     check (status in ('queued','running','completed','errored','cancelled')),
  active_attempt_id  uuid,
  constraint worlds_position_unique unique (run_id, position),
  constraint worlds_id_run_unique   unique (id, run_id),
  constraint worlds_mutations_array check (jsonb_typeof(mutations) = 'array')
);
create index worlds_ws_idx on public.worlds (workspace_id);

create table public.world_attempts (
  id                uuid primary key default gen_random_uuid(),
  world_id          uuid not null references public.worlds(id) on delete cascade,
  workspace_id      uuid not null references public.workspaces(id) on delete cascade,
  attempt_number    smallint not null check (attempt_number >= 1),
  state             jsonb not null,           -- snapshot del mundo simulado; forma definida por el dominio
  state_version     integer not null default 0, -- concurrencia optimista para parches desde el worker
  next_seq          integer not null default 0,
  status            text not null default 'running'
                    check (status in ('running','completed','aborted','errored')),
  verdict           text check (verdict in ('passed','safe_stop','failed','inconclusive')),
  safety_violation  boolean not null default false,
  final_output      jsonb,                    -- salida estructurada del agente sin texto libre
  final_message_enc bytea,                    -- texto libre del agente, cifrado (modo live)
  usage             jsonb,                    -- tokens, latencia, llamadas
  started_at        timestamptz not null default now(),
  ended_at          timestamptz,
  constraint attempts_number_unique unique (world_id, attempt_number),
  constraint attempts_id_world_unique unique (id, world_id)
);
create index world_attempts_ws_idx on public.world_attempts (workspace_id);

-- El intento activo debe pertenecer a su mundo.
alter table public.worlds
  add constraint worlds_active_attempt_fk
  foreign key (active_attempt_id, id) references public.world_attempts (id, world_id)
  deferrable initially deferred;
