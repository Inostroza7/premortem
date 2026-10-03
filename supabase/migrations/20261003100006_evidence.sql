-- PREMORTEM v2 · 0006 · Evidencia append-only con formato versionado (evidence_format_version = 1).
-- La aplicación serializa el envelope en JSON canónico (JCS) y calcula los hashes; SQL garantiza
-- unicidad, secuencia contigua y enlace prev_hash → event_hash. Sin excepciones por variable de sesión.

create table public.attempt_events (
  event_id             uuid primary key,                 -- preasignado por la aplicación (entra en el AAD)
  workspace_id         uuid not null,
  run_id               uuid not null,
  job_id               uuid not null,
  attempt_id           uuid not null,
  seq                  integer not null check (seq >= 1),
  format               smallint not null default 1 check (format = 1),
  type                 text not null check (length(type) between 1 and 80),
  audience             text not null check (audience in ('agent','inspector','system')),
  public_payload       jsonb not null default '{}'::jsonb,   -- allowlist: tipos, códigos acotados, conteos, versiones
  public_payload_hash  bytea not null,
  private_payload_id   uuid,                                  -- core.payloads (confidencial, opcionalmente cifrado)
  private_blob_hash    bytea,
  prev_hash            bytea,
  event_hash           bytea not null,
  created_at           timestamptz not null default now(),
  constraint attempt_events_seq_unique unique (attempt_id, seq),
  constraint attempt_events_id_attempt_unique unique (event_id, attempt_id),
  constraint attempt_events_attempt_fk foreign key (attempt_id, job_id, run_id, workspace_id)
    references public.world_attempts (id, job_id, run_id, workspace_id) on delete cascade,
  constraint attempt_events_private_fk foreign key (private_payload_id, workspace_id)
    references core.payloads (id, workspace_id),
  constraint attempt_events_payload_size check (octet_length(public_payload::text) <= 65536),
  constraint attempt_events_genesis_shape check ((seq = 1) = (prev_hash is null)),
  constraint attempt_events_private_shape check ((private_payload_id is null) = (private_blob_hash is null)),
  constraint attempt_events_hash_len check (octet_length(event_hash) = 32 and octet_length(public_payload_hash) = 32)
);
create index attempt_events_ws_idx  on public.attempt_events (workspace_id);
create index attempt_events_job_idx on public.attempt_events (job_id, seq);

create table public.effects (
  effect_id             uuid primary key,
  workspace_id          uuid not null,
  run_id                uuid not null,
  job_id                uuid not null,
  attempt_id            uuid not null,
  event_id              uuid not null,                   -- evento origen (tool.effect_committed)
  type                  text not null check (length(type) between 1 and 80),
  logical_operation_id  text not null check (length(logical_operation_id) between 1 and 200),
  resource_id           text not null check (length(resource_id) between 1 and 200),
  payload               jsonb not null default '{}'::jsonb,   -- tipado por el paquete (effectSchemas[type])
  created_at            timestamptz not null default now(),
  constraint effects_event_fk foreign key (event_id, attempt_id)
    references public.attempt_events (event_id, attempt_id) on delete cascade,
  constraint effects_attempt_fk foreign key (attempt_id, job_id, run_id, workspace_id)
    references public.world_attempts (id, job_id, run_id, workspace_id) on delete cascade,
  constraint effects_payload_size check (octet_length(payload::text) <= 65536)
);
create index effects_attempt_op_idx on public.effects (attempt_id, logical_operation_id);
create index effects_ws_idx on public.effects (workspace_id);

create table public.rule_results (
  id                  uuid primary key default gen_random_uuid(),
  attempt_id          uuid not null,
  workspace_id        uuid not null,
  rule_id             text not null check (length(rule_id) between 1 and 80),
  status              text not null check (status in ('pass','violation','not_applicable','not_evaluated')),
  category            text not null check (category in ('safety','completion','honesty')),
  expected            jsonb not null default '{}'::jsonb,
  observed            jsonb not null default '{}'::jsonb,
  evidence_event_ids  uuid[] not null default '{}',
  explanation         text not null default '',
  created_at          timestamptz not null default now(),
  constraint rule_results_unique unique (attempt_id, rule_id),
  constraint rule_results_attempt_fk foreign key (attempt_id, workspace_id)
    references public.world_attempts (id, workspace_id) on delete cascade,
  constraint rule_results_size check (octet_length(expected::text) <= 65536 and octet_length(observed::text) <= 65536)
);
create index rule_results_ws_idx on public.rule_results (workspace_id);

create trigger attempt_events_immutable before update or delete on public.attempt_events
  for each row execute function core.forbid_change();
create trigger effects_immutable before update or delete on public.effects
  for each row execute function core.forbid_change();
create trigger rule_results_immutable before update or delete on public.rule_results
  for each row execute function core.forbid_change();
