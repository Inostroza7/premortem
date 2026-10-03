-- PREMORTEM · 0004 · Evidencia append-only: eventos (traza con cadena de hashes), efectos (ledger genérico)
-- y hallazgos. Ningún nombre de dominio aparece aquí: un efecto es cualquier cambio con consecuencias
-- (reembolso, transferencia, ticket asignado, correo enviado...).

create table public.events (
  id                bigint generated always as identity primary key,
  attempt_id        uuid not null,
  world_id          uuid not null,
  workspace_id      uuid not null,
  seq               integer not null check (seq >= 1),
  type              text not null,              -- tool.call · tool.result · sim.effect · model.response · world.mutation_applied ...
  visible_to_agent  boolean not null default false,
  payload           jsonb not null default '{}'::jsonb,  -- estructurado, en claro, canónico
  payload_enc       bytea,                               -- texto libre cifrado (modo live)
  payload_enc_hash  bytea,                               -- sha256 del blob cifrado; sobrevive a la retención
  prev_hash         bytea,
  event_hash        bytea not null,
  created_at        timestamptz not null default now(),
  constraint events_seq_unique unique (attempt_id, seq),
  constraint events_attempt_world_fk foreign key (attempt_id, world_id)
    references public.world_attempts (id, world_id) on delete cascade,
  constraint events_enc_hash_shape check (payload_enc is null or payload_enc_hash is not null)
);
create index events_ws_idx    on public.events (workspace_id);
create index events_world_idx on public.events (world_id);

create table public.effects (
  id                    uuid primary key default gen_random_uuid(),
  attempt_id            uuid not null,
  world_id              uuid not null,
  workspace_id          uuid not null,
  request_id            text not null,            -- solicitud lógica de la tarea
  tool                  text not null,            -- herramienta que lo produjo
  kind                  text not null,            -- refund · transfer · ticket_assign · email_send ...
  target_type           text,                     -- order · subscription · ticket · account ...
  target_id             text,
  subject_id            text,                     -- a quién afecta (cliente, usuario, cuenta conectada)
  amount_cents          bigint check (amount_cents is null or amount_cents > 0),
  currency              char(3),
  operation_key         text not null,            -- clave de idempotencia elegida por el agente
  fingerprint           bytea not null,           -- sha256 de los argumentos canónicos
  capability            text not null,            -- permiso exigido al confirmar
  permission_at_commit  boolean not null,
  data                  jsonb not null default '{}'::jsonb,  -- detalle específico del dominio
  result                jsonb not null default '{}'::jsonb,  -- lo que se devolvió; se reutiliza en replays
  event_seq             integer not null,
  created_at            timestamptz not null default now(),
  constraint effects_operation_unique unique (attempt_id, operation_key),
  constraint effects_attempt_world_fk foreign key (attempt_id, world_id)
    references public.world_attempts (id, world_id) on delete cascade,
  constraint effects_event_fk foreign key (attempt_id, event_seq)
    references public.events (attempt_id, seq),
  constraint effects_money_shape check ((amount_cents is null) = (currency is null))
);
create index effects_ws_idx      on public.effects (workspace_id);
create index effects_request_idx on public.effects (attempt_id, request_id);

create table public.findings (
  id                   uuid primary key default gen_random_uuid(),
  attempt_id           uuid not null references public.world_attempts(id) on delete cascade,
  workspace_id         uuid not null,
  invariant_id         text not null,
  verdict              text not null check (verdict in ('passed','failed','not_applicable')),
  safety_violation     boolean not null default false,
  expected             jsonb not null default '{}'::jsonb,
  actual               jsonb not null default '{}'::jsonb,
  evidence_event_seqs  integer[] not null default '{}',
  explanation          text not null default '',
  created_at           timestamptz not null default now(),
  constraint findings_invariant_unique unique (attempt_id, invariant_id)
);
create index findings_ws_idx on public.findings (workspace_id);

-- ---------------------------------------------------------------------------
-- Inmutabilidad. La única excepción es la retención (premortem.retention = 'on' en la sesión),
-- que puede anular payload_enc en events o borrar filas enteras de forma controlada.
-- ---------------------------------------------------------------------------
create or replace function core.forbid_change()
returns trigger
language plpgsql
set search_path = ''
as $$
declare v_flag text := current_setting('premortem.retention', true);
begin
  if v_flag = 'on' then
    if tg_op = 'DELETE' then
      return old;
    end if;
    if tg_op = 'UPDATE' and tg_table_name = 'events'
       and new.payload_enc is null
       and (to_jsonb(new) - 'payload_enc') = (to_jsonb(old) - 'payload_enc') then
      return new;
    end if;
  end if;
  raise exception 'IMMUTABLE_ROW'
    using errcode = 'PM409', detail = tg_table_schema || '.' || tg_table_name,
          hint = 'La evidencia es append-only.';
end $$;

create trigger events_immutable   before update or delete on public.events
  for each row execute function core.forbid_change();
create trigger effects_immutable  before update or delete on public.effects
  for each row execute function core.forbid_change();
create trigger findings_immutable before update or delete on public.findings
  for each row execute function core.forbid_change();
