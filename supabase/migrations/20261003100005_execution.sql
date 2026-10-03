-- PREMORTEM v2 · 0005 · Ejecución: runs (manifiesto congelado), fila de control de cancelación,
-- world_jobs (unidad de cola, lease y consumo), world_attempts, estado del intento y commits de herramienta.

create table public.runs (
  id                      uuid primary key default gen_random_uuid(),
  workspace_id            uuid not null references public.workspaces(id) on delete cascade,
  project_id              uuid not null,
  created_by              uuid references auth.users(id) on delete set null,
  kind                    text not null default 'evaluation' check (kind in ('evaluation','reduction')),
  case_version_id         uuid not null,
  agent_version_id        uuid not null,
  domain_pack_version_id  uuid not null references public.domain_pack_versions(id),
  manifest                jsonb not null,            -- refs/hashes de agente, paquete, motor, caso, fixture, oráculo, mutaciones, reglas
  manifest_hash           bytea not null,
  seed                    integer not null,
  repetitions             smallint not null check (repetitions between 1 and 16),
  limits                  jsonb not null,            -- { maxToolCalls, maxDurationMs, maxTokens, maxModelResponses }
  status                  text not null default 'queued' check (status in ('queued','running','completed','cancelled')),
  jobs_total              integer not null check (jobs_total >= 1),
  jobs_terminal           integer not null default 0,
  jobs_passed             integer not null default 0,
  jobs_safe_stop          integer not null default 0,
  jobs_failed             integer not null default 0,
  jobs_inconclusive       integer not null default 0,
  jobs_errored            integer not null default 0,
  jobs_cancelled          integer not null default 0,
  parent_run_id           uuid references public.runs(id),
  reduction_config        jsonb,
  idempotency_key         text,
  request_hash            bytea,
  created_at              timestamptz not null default now(),
  started_at              timestamptz,
  ended_at                timestamptz,
  constraint runs_id_ws_unique unique (id, workspace_id),
  constraint runs_idempotency_unique unique (workspace_id, idempotency_key),
  constraint runs_idempotency_shape check ((idempotency_key is null) = (request_hash is null)),
  constraint runs_project_fk foreign key (project_id, workspace_id) references public.projects (id, workspace_id),
  constraint runs_case_fk foreign key (case_version_id, workspace_id) references public.case_versions (id, workspace_id),
  constraint runs_agent_fk foreign key (agent_version_id, workspace_id) references public.agent_versions (id, workspace_id),
  constraint runs_manifest_size check (octet_length(manifest::text) <= 262144)
);
create index runs_ws_created_idx on public.runs (workspace_id, project_id, created_at desc);
create index runs_parent_idx on public.runs (parent_run_id) where parent_run_id is not null;

-- Fila de control: las transiciones la leen FOR SHARE; cancelar la actualiza (exclusivo) y espera
-- a los commits en curso. Nunca se bloquean todos los jobs para cancelar.
create table core.run_controls (
  run_id               uuid primary key references public.runs(id) on delete cascade,
  workspace_id         uuid not null,
  cancel_requested_at  timestamptz,
  cancel_requested_by  uuid,
  created_at           timestamptz not null default now()
);

create table public.world_jobs (
  id                 uuid primary key default gen_random_uuid(),
  run_id             uuid not null,
  workspace_id       uuid not null,
  ordinal            smallint not null check (ordinal >= 0),
  scenario_id        text not null,
  repetition         smallint not null check (repetition >= 1),
  mutations          jsonb not null default '[]'::jsonb,
  seed               integer not null,
  status             text not null default 'queued' check (status in ('queued','running','completed','errored','cancelled')),
  verdict            text check (verdict in ('passed','safe_stop','failed','inconclusive')),
  lease_owner        text,
  lease_epoch        integer not null default 0,
  lease_until        timestamptz,
  active_attempt_id  uuid,
  recovery_count     smallint not null default 0,
  terminal_reason    text,
  created_at         timestamptz not null default now(),
  started_at         timestamptz,
  ended_at           timestamptz,
  constraint world_jobs_ordinal_unique unique (run_id, ordinal),
  constraint world_jobs_id_run_ws_unique unique (id, run_id, workspace_id),
  constraint world_jobs_id_ws_unique unique (id, workspace_id),
  constraint world_jobs_run_fk foreign key (run_id, workspace_id) references public.runs (id, workspace_id) on delete cascade,
  constraint world_jobs_mutations_array check (jsonb_typeof(mutations) = 'array'),
  constraint world_jobs_lease_shape check (status <> 'running' or (lease_owner is not null and lease_until is not null))
);
create index world_jobs_claim_idx on public.world_jobs (status, lease_until) where status in ('queued','running');
create index world_jobs_ws_active_idx on public.world_jobs (workspace_id) where status = 'running';

create table public.world_attempts (
  id                uuid primary key default gen_random_uuid(),
  job_id            uuid not null,
  run_id            uuid not null,
  workspace_id      uuid not null,
  attempt_number    smallint not null check (attempt_number >= 1),
  status            text not null default 'running' check (status in ('running','completed','aborted')),
  verdict           text check (verdict in ('passed','safe_stop','failed','inconclusive')),
  termination       text check (termination in ('finished','limit','provider_error','cancelled','lease_lost','infra')),
  final_output      jsonb,                 -- AgentFinal sin texto libre confidencial
  final_payload_id  uuid,                  -- core.payloads con el texto libre protegido
  usage             jsonb,
  chain_length      integer,
  chain_head        bytea,
  started_at        timestamptz not null default now(),
  ended_at          timestamptz,
  constraint world_attempts_number_unique unique (job_id, attempt_number),
  constraint world_attempts_id_job_unique unique (id, job_id),
  constraint world_attempts_id_ws_unique unique (id, workspace_id),
  constraint world_attempts_chain_unique unique (id, job_id, run_id, workspace_id),
  constraint world_attempts_job_fk foreign key (job_id, run_id, workspace_id)
    references public.world_jobs (id, run_id, workspace_id) on delete cascade,
  constraint world_attempts_final_payload_fk foreign key (final_payload_id, workspace_id)
    references core.payloads (id, workspace_id)
);
create index world_attempts_job_idx on public.world_attempts (job_id, attempt_number desc);

-- El intento activo debe pertenecer a su job.
alter table public.world_jobs
  add constraint world_jobs_active_attempt_fk
  foreign key (active_attempt_id, id) references public.world_attempts (id, job_id)
  deferrable initially deferred;

-- Reserva de unidades por job (tabla creada en 0004)
alter table billing.job_reservations
  add constraint job_reservations_job_fk foreign key (job_id, run_id, workspace_id)
  references public.world_jobs (id, run_id, workspace_id) on delete cascade;

-- Cola de trabajos nativa: un mensaje por world_job. Entrega durable con visibilidad (visible_at), conteo de
-- lecturas y archivo. La autorización para escribir la decide el lease del job, no el mensaje.
create table core.job_queue (
  msg_id        bigint generated always as identity primary key,
  job_id        uuid not null,
  run_id        uuid not null,
  workspace_id  uuid not null,
  enqueued_at   timestamptz not null default now(),
  visible_at    timestamptz not null default now(),
  read_ct       integer not null default 0,
  last_worker   text,
  archived_at   timestamptz,
  constraint job_queue_job_fk foreign key (job_id, run_id, workspace_id)
    references public.world_jobs (id, run_id, workspace_id) on delete cascade
);
create index job_queue_visible_idx on core.job_queue (visible_at, msg_id) where archived_at is null;
create unique index job_queue_one_active_per_job on core.job_queue (job_id) where archived_at is null;

-- Estado vigente del intento: dominio (opaco para el core) e inyecciones del motor (p. ej. respuesta perdida
-- ya consumida). CAS por state_version; next_seq y last_event_hash encadenan la evidencia.
create table core.attempt_states (
  attempt_id       uuid primary key references public.world_attempts(id) on delete cascade,
  workspace_id     uuid not null,
  state_version    integer not null default 0,
  domain_state     jsonb not null,
  injection_state  jsonb not null default '{}'::jsonb,
  next_seq         integer not null default 1,
  last_event_hash  bytea,
  updated_at       timestamptz not null default now(),
  constraint attempt_states_size check (octet_length(domain_state::text) <= 262144),
  constraint attempt_states_injection_object check (jsonb_typeof(injection_state) = 'object')
);

-- Idempotencia técnica del motor: repetir el mismo commit_id devuelve la observación persistida.
create table public.tool_commits (
  id                    bigint generated always as identity primary key,
  attempt_id            uuid not null,
  workspace_id          uuid not null,
  commit_id             uuid not null,
  call_id               text,
  tool                  text not null,
  fingerprint           bytea not null,
  state_version_before  integer not null,
  state_version_after   integer not null,
  first_seq             integer not null,
  last_seq              integer not null,
  response              jsonb not null,     -- observación entregada al agente (ToolResult)
  created_at            timestamptz not null default now(),
  constraint tool_commits_unique unique (attempt_id, commit_id),
  constraint tool_commits_attempt_fk foreign key (attempt_id, workspace_id)
    references public.world_attempts (id, workspace_id) on delete cascade,
  constraint tool_commits_response_size check (octet_length(response::text) <= 65536)
);
create trigger tool_commits_immutable before update or delete on public.tool_commits
  for each row execute function core.forbid_change();
