-- PREMORTEM v2 · 0003 · Catálogo inmutable: versiones de paquete de dominio, versiones de agente,
-- versiones de caso y sus payloads privados (fixture y oráculo).

-- ---------------------------------------------------------------------------
-- Paquetes de dominio: manifiestos confiables registrados por el servidor (código del repositorio).
-- manifest = { label, description, scenarios: { id: { label, mutations: [MutationSpec] } },
--              tools: [ToolDefinition], rules: [{ id, category, required }], mutations: [VersionRef],
--              schemas: { fixture, task, state, oracle, finalData, effects }, fixtures: { version: hash } }
-- ---------------------------------------------------------------------------
create table public.domain_pack_versions (
  id                  uuid primary key default gen_random_uuid(),
  pack_id             text not null check (pack_id ~ '^[a-z0-9][a-z0-9-]{1,63}$'),
  version             text not null check (version ~ '^[0-9]+\.[0-9]+\.[0-9]+$'),
  content_hash        bytea not null,
  engine_min_version  text not null default '0.1.0',
  manifest            jsonb not null,
  status              text not null default 'active' check (status in ('active','retired')),
  created_at          timestamptz not null default now(),
  constraint domain_pack_versions_unique unique (pack_id, version),
  constraint domain_pack_manifest_shape check (
        jsonb_typeof(manifest) = 'object'
    and jsonb_typeof(manifest->'scenarios') = 'object'
    and jsonb_typeof(manifest->'tools') = 'array'
    and jsonb_typeof(manifest->'rules') = 'array'
  )
);

-- Solo puede cambiar status (retirar). El contenido de una versión es inmutable.
create or replace function core.domain_pack_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (to_jsonb(new) - 'status') = (to_jsonb(old) - 'status') then
    return new;
  end if;
  raise exception 'IMMUTABLE_ROW' using errcode = 'PM409', detail = 'public.domain_pack_versions',
    hint = 'Publica una versión nueva del paquete.';
end $$;
create trigger domain_pack_versions_guard before update on public.domain_pack_versions
  for each row execute function core.domain_pack_guard();

-- ---------------------------------------------------------------------------
-- Versiones de agente. El prompt editable (driver con modelo) vive cifrado en core.payloads.
-- ---------------------------------------------------------------------------
create table public.agent_versions (
  id                 uuid primary key default gen_random_uuid(),
  workspace_id       uuid not null references public.workspaces(id) on delete cascade,
  created_by         uuid references auth.users(id) on delete set null,
  label              text not null check (length(label) between 1 and 120),
  driver             text not null check (driver in ('reference','anthropic')),
  driver_version     text not null,
  policy_id          text,                 -- driver = reference: política determinista del paquete
  model_id           text,                 -- driver = anthropic: identificador verificado
  config             jsonb not null default '{}'::jsonb,
  prompt_payload_id  uuid,                 -- core.payloads (confidencial, cifrado)
  prompt_hmac        bytea,                -- HMAC con clave separada por tenant: igualdad sin descifrar
  content_hash       bytea not null,
  created_at         timestamptz not null default now(),
  constraint agent_versions_id_ws_unique unique (id, workspace_id),
  constraint agent_versions_prompt_fk foreign key (prompt_payload_id, workspace_id)
    references core.payloads (id, workspace_id),
  constraint agent_versions_driver_shape check (
       (driver = 'reference' and policy_id is not null and prompt_payload_id is null)
    or (driver <> 'reference' and model_id is not null)
  )
);
create index agent_versions_ws_idx on public.agent_versions (workspace_id, created_at desc);
create trigger agent_versions_immutable before update on public.agent_versions
  for each row execute function core.forbid_update();

-- ---------------------------------------------------------------------------
-- Versiones de caso: metadata visible en public; fixture y oráculo en core.
-- ---------------------------------------------------------------------------
create table public.case_versions (
  id                      uuid primary key default gen_random_uuid(),
  workspace_id            uuid not null references public.workspaces(id) on delete cascade,
  project_id              uuid not null,
  created_by              uuid references auth.users(id) on delete set null,
  domain_pack_version_id  uuid not null references public.domain_pack_versions(id),
  label                   text not null check (length(label) between 1 and 160),
  fixture_version         text not null,
  task                    jsonb not null default '{}'::jsonb,           -- instrucción y parámetros visibles
  public_context          jsonb not null default '{}'::jsonb,           -- contexto verificable consultable
  content_hash            bytea not null,
  created_at              timestamptz not null default now(),
  constraint case_versions_id_ws_unique unique (id, workspace_id),
  constraint case_versions_project_fk foreign key (project_id, workspace_id)
    references public.projects (id, workspace_id) on delete cascade,
  constraint case_versions_task_size check (octet_length(task::text) <= 65536),
  constraint case_versions_context_size check (octet_length(public_context::text) <= 65536)
);
create index case_versions_project_idx on public.case_versions (project_id, created_at desc);
create trigger case_versions_immutable before update on public.case_versions
  for each row execute function core.forbid_update();

create table core.case_payloads (
  case_version_id  uuid primary key references public.case_versions(id) on delete cascade,
  workspace_id     uuid not null,
  fixture          jsonb not null,
  oracle           jsonb not null,
  classification   text not null default 'internal' check (classification in ('public','internal','confidential','restricted')),
  fixture_hash     bytea not null,
  oracle_hash      bytea not null,
  created_at       timestamptz not null default now(),
  constraint case_payloads_fixture_size check (octet_length(fixture::text) <= 262144),
  constraint case_payloads_oracle_size  check (octet_length(oracle::text) <= 65536)
);
create trigger case_payloads_immutable before update on core.case_payloads
  for each row execute function core.forbid_update();
