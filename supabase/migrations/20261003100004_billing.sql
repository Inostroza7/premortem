-- PREMORTEM v2 · 0004 · Billing: wallet por workspace, ledger de créditos, reserva por job, compras y
-- eventos Stripe. Una unidad = un world_job. Reservar al crear el run; consumir o liberar una sola vez.

create table billing.wallets (
  workspace_id     uuid primary key references public.workspaces(id) on delete cascade,
  available_units  integer not null default 0 check (available_units >= 0),
  reserved_units   integer not null default 0 check (reserved_units >= 0),
  updated_at       timestamptz not null default now()
);

-- Ledger append-only. La clave única por (kind, referencia) hace idempotentes grants, settles y releases.
create table billing.credit_entries (
  id               bigint generated always as identity primary key,
  workspace_id     uuid not null references public.workspaces(id) on delete cascade,
  kind             text not null check (kind in ('trial_grant','purchase_grant','reserve','settle','release','adjustment')),
  delta_available  integer not null,
  delta_reserved   integer not null,
  reference_kind   text not null,          -- workspace · purchase · run · job · manual
  reference_id     text not null,
  note             text,
  created_at       timestamptz not null default now(),
  constraint credit_entries_once unique (workspace_id, kind, reference_kind, reference_id)
);
create index credit_entries_ws_idx on billing.credit_entries (workspace_id, created_at desc);
create trigger credit_entries_immutable before update or delete on billing.credit_entries
  for each row execute function core.forbid_change();

create table billing.job_reservations (
  job_id        uuid primary key,                 -- FK a world_jobs se añade en 0005
  run_id        uuid not null,
  workspace_id  uuid not null,
  units         integer not null default 1 check (units = 1),
  status        text not null default 'reserved' check (status in ('reserved','settled','released')),
  created_at    timestamptz not null default now(),
  resolved_at   timestamptz
);
create index job_reservations_run_idx on billing.job_reservations (run_id);

create table billing.purchases (
  id                          uuid primary key default gen_random_uuid(),
  workspace_id                uuid not null references public.workspaces(id) on delete cascade,
  created_by                  uuid references auth.users(id) on delete set null,
  status                      text not null default 'pending' check (status in ('pending','paid','fulfilled','expired','failed')),
  units                       integer not null check (units > 0),
  amount_cents                bigint not null check (amount_cents >= 0),
  currency                    char(3) not null,
  stripe_price_id             text,
  stripe_customer_id          text,
  stripe_checkout_session_id  text unique,
  stripe_payment_intent_id    text unique,
  idempotency_key             text,
  livemode                    boolean not null default false,
  created_at                  timestamptz not null default now(),
  fulfilled_at                timestamptz,
  constraint purchases_idem_unique unique (workspace_id, idempotency_key)
);
create index purchases_ws_idx on billing.purchases (workspace_id, created_at desc);

create table billing.stripe_events (
  event_id      text primary key,
  type          text not null,
  livemode      boolean not null default false,
  object_id     text,
  payload       jsonb not null default '{}'::jsonb,   -- mínimo necesario para reconciliar, sin datos de tarjeta
  status        text not null default 'received' check (status in ('received','processed','ignored','failed')),
  error         text,
  received_at   timestamptz not null default now(),
  processed_at  timestamptz
);

-- ---------------------------------------------------------------------------
-- Alta de usuario: workspace personal, membresía owner, proyecto por defecto, wallet y 8 unidades
-- de prueba, concedidas una sola vez por workspace (clave única del ledger).
-- ---------------------------------------------------------------------------
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
  insert into public.projects (workspace_id, name, created_by) values (v_ws, 'Default', new.id);
  insert into billing.wallets (workspace_id, available_units) values (v_ws, 8);
  insert into billing.credit_entries (workspace_id, kind, delta_available, delta_reserved, reference_kind, reference_id, note)
  values (v_ws, 'trial_grant', 8, 0, 'workspace', v_ws::text, 'unidades de prueba iniciales');
  return new;
end $$;

drop trigger if exists on_auth_user_created_premortem on auth.users;
create trigger on_auth_user_created_premortem
  after insert on auth.users
  for each row execute function core.handle_new_user();
