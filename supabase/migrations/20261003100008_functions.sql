-- PREMORTEM v2 · 0008 · Funciones del motor. Todas SECURITY DEFINER, search_path vacío y nombres cualificados.
-- Se crean con el rol de migración, se fijan sus privilegios y al final se transfiere su propiedad a
-- premortem_owner (sin SET ROLE: la CLI registra la migración en la misma sesión).
--
-- SQL garantiza: pertenencia (workspace → proyecto → run → job → intento activo), lease y epoch,
-- secuencia y enlace de la evidencia, idempotencia técnica (commit_id) y CAS de estado.
-- La semántica de cada dominio vive en el worker (DomainPack); aquí es opaca.
--
-- SQLSTATE propios: PM400 argumento · PM402 créditos · PM403 pertenencia · PM404 no encontrado ·
-- PM409 conflicto/estado · PM423 lease/cancelación.

-- ===========================================================================
-- Utilidades
-- ===========================================================================
create or replace function core.sha256_json(p jsonb)
returns bytea
language sql immutable
set search_path = ''
as $$
  -- Solo para deduplicar peticiones y congelar manifiestos dentro de esta base.
  -- La evidencia exportable se hashea en la aplicación con JSON canónico (JCS).
  select extensions.digest(convert_to(coalesce(p, '{}'::jsonb)::text, 'utf8'), 'sha256');
$$;

create or replace function core.hex32(p text, p_name text)
returns bytea
language plpgsql immutable
set search_path = ''
as $$
begin
  if p is null or p !~ '^[0-9a-f]{64}$' then
    raise exception 'INVALID_HASH' using errcode = 'PM400', detail = p_name;
  end if;
  return decode(p, 'hex');
end $$;

create or replace function core.assert_member(p_workspace_id uuid, p_user_id uuid)
returns void
language plpgsql stable security definer
set search_path = ''
as $$
begin
  if p_workspace_id is null or p_user_id is null then
    raise exception 'WORKSPACE_AND_USER_REQUIRED' using errcode = 'PM400';
  end if;
  if not exists (select 1 from public.workspace_members where workspace_id = p_workspace_id and user_id = p_user_id) then
    raise exception 'NOT_A_MEMBER' using errcode = 'PM403';
  end if;
end $$;

-- Payload privado: { payload_id?, classification?, encrypted, content? | blob_b64?, digest (hex), key_id? }
create or replace function core.store_payload(p_workspace_id uuid, p_spec jsonb, p_owner_kind text, p_owner_id uuid)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid; v_enc boolean; v_blob bytea; v_content jsonb; v_digest bytea; v_key uuid; v_class text; v_size integer; v_max integer;
begin
  if p_spec is null or jsonb_typeof(p_spec) <> 'object' then
    raise exception 'PAYLOAD_SPEC_INVALID' using errcode = 'PM400';
  end if;
  v_id    := coalesce((p_spec->>'payload_id')::uuid, gen_random_uuid());
  v_class := coalesce(p_spec->>'classification', 'confidential');
  v_enc   := coalesce((p_spec->>'encrypted')::boolean, false);
  v_digest := core.hex32(p_spec->>'digest', 'payload.digest');
  v_max := case when p_owner_kind in ('event','rule_result') then 65536 else 262144 end;

  if v_enc then
    v_blob := decode(coalesce(p_spec->>'blob_b64', ''), 'base64');
    if v_blob is null or octet_length(v_blob) < 45 then           -- versión(1) + key_id(16) + nonce(12) + tag(16)
      raise exception 'BLOB_INVALID' using errcode = 'PM400';
    end if;
    v_key := (p_spec->>'key_id')::uuid;
    if v_key is null then raise exception 'KEY_ID_REQUIRED' using errcode = 'PM400'; end if;
    if not exists (select 1 from core.data_keys where id = v_key and workspace_id = p_workspace_id and status = 'active') then
      raise exception 'KEY_NOT_FOUND_FOR_WORKSPACE' using errcode = 'PM403';
    end if;
    if extensions.digest(v_blob, 'sha256') <> v_digest then
      raise exception 'PAYLOAD_DIGEST_MISMATCH' using errcode = 'PM400';
    end if;
    v_size := octet_length(v_blob);
  else
    v_content := p_spec->'content';
    if v_content is null then raise exception 'CONTENT_REQUIRED' using errcode = 'PM400'; end if;
    v_size := octet_length(v_content::text);
  end if;
  if v_size > v_max then
    raise exception 'PAYLOAD_TOO_LARGE' using errcode = 'PM400', detail = format('%s > %s bytes', v_size, v_max);
  end if;

  insert into core.payloads (id, workspace_id, owner_kind, owner_id, classification, encrypted, content, blob, digest, byte_size, key_id)
  values (v_id, p_workspace_id, p_owner_kind, p_owner_id, v_class, v_enc, v_content, v_blob, v_digest, v_size, v_key);
  return v_id;
end $$;

-- ===========================================================================
-- Catálogo
-- ===========================================================================
create or replace function core.register_domain_pack(
  p_pack_id text, p_version text, p_content_hash bytea, p_manifest jsonb, p_engine_min_version text default '0.1.0'
) returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare v_existing public.domain_pack_versions%rowtype; v_id uuid;
begin
  select * into v_existing from public.domain_pack_versions where pack_id = p_pack_id and version = p_version;
  if found then
    if v_existing.content_hash = p_content_hash then return v_existing.id; end if;
    raise exception 'PACK_VERSION_CONFLICT' using errcode = 'PM409',
      hint = 'La misma versión con otro contenido: publica una versión nueva.';
  end if;
  insert into public.domain_pack_versions (pack_id, version, content_hash, manifest, engine_min_version)
  values (p_pack_id, p_version, p_content_hash, p_manifest, p_engine_min_version)
  returning id into v_id;
  return v_id;
end $$;

create or replace function core.create_project(p_workspace_id uuid, p_user_id uuid, p_name text)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare v_id uuid;
begin
  perform core.assert_member(p_workspace_id, p_user_id);
  insert into public.projects (workspace_id, name, created_by) values (p_workspace_id, p_name, p_user_id) returning id into v_id;
  return v_id;
end $$;

create or replace function core.create_agent_version(
  p_workspace_id uuid, p_user_id uuid, p_label text, p_driver text, p_driver_version text,
  p_policy_id text, p_model_id text, p_config jsonb, p_content_hash bytea,
  p_prompt_hmac bytea default null, p_prompt_payload jsonb default null
) returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare v_id uuid := gen_random_uuid(); v_pid uuid;
begin
  perform core.assert_member(p_workspace_id, p_user_id);
  if p_prompt_payload is not null then
    v_pid := core.store_payload(p_workspace_id, p_prompt_payload, 'agent_prompt', v_id);
  end if;
  insert into public.agent_versions (id, workspace_id, created_by, label, driver, driver_version, policy_id, model_id,
                                     config, prompt_payload_id, prompt_hmac, content_hash)
  values (v_id, p_workspace_id, p_user_id, p_label, p_driver, p_driver_version, p_policy_id, p_model_id,
          coalesce(p_config, '{}'::jsonb), v_pid, p_prompt_hmac, p_content_hash);
  return v_id;
end $$;

create or replace function core.create_case_version(
  p_workspace_id uuid, p_user_id uuid, p_project_id uuid, p_domain_pack_version_id uuid,
  p_label text, p_fixture_version text, p_task jsonb, p_public_context jsonb,
  p_fixture jsonb, p_oracle jsonb, p_content_hash bytea, p_classification text default 'internal'
) returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare v_id uuid;
begin
  perform core.assert_member(p_workspace_id, p_user_id);
  if not exists (select 1 from public.projects where id = p_project_id and workspace_id = p_workspace_id) then
    raise exception 'PROJECT_NOT_FOUND' using errcode = 'PM404';
  end if;
  if not exists (select 1 from public.domain_pack_versions where id = p_domain_pack_version_id and status = 'active') then
    raise exception 'PACK_UNAVAILABLE' using errcode = 'PM409';
  end if;
  if p_fixture is null or jsonb_typeof(p_fixture) <> 'object' or p_oracle is null or jsonb_typeof(p_oracle) <> 'object' then
    raise exception 'FIXTURE_AND_ORACLE_REQUIRED' using errcode = 'PM400';
  end if;
  insert into public.case_versions (workspace_id, project_id, created_by, domain_pack_version_id, label, fixture_version,
                                    task, public_context, content_hash)
  values (p_workspace_id, p_project_id, p_user_id, p_domain_pack_version_id, p_label, p_fixture_version,
          coalesce(p_task, '{}'::jsonb), coalesce(p_public_context, '{}'::jsonb), p_content_hash)
  returning id into v_id;
  insert into core.case_payloads (case_version_id, workspace_id, fixture, oracle, classification, fixture_hash, oracle_hash)
  values (v_id, p_workspace_id, p_fixture, p_oracle, p_classification, core.sha256_json(p_fixture), core.sha256_json(p_oracle));
  return v_id;
end $$;

-- ===========================================================================
-- Planificación de un run: valida referencias, escenarios, mutaciones soportadas y límites.
-- ===========================================================================
create or replace function core.prepare_run(
  p_workspace_id uuid, p_user_id uuid, p_project_id uuid, p_case_version_id uuid, p_agent_version_id uuid,
  p_scenario_ids text[], p_repetitions integer, p_limits jsonb, p_kind text, p_jobs_override jsonb
) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_ws public.workspaces%rowtype; v_case public.case_versions%rowtype; v_agent public.agent_versions%rowtype;
  v_pack public.domain_pack_versions%rowtype; v_payload core.case_payloads%rowtype;
  v_supported text[]; v_sid text; v_scen jsonb; v_m jsonb; v_jobs jsonb := '[]'::jsonb; v_limits jsonb;
  v_n integer := 0; v_i integer; v_max_reps constant integer := 3;
begin
  perform core.assert_member(p_workspace_id, p_user_id);
  select * into v_ws from public.workspaces where id = p_workspace_id;
  if not exists (select 1 from public.projects where id = p_project_id and workspace_id = p_workspace_id) then
    raise exception 'PROJECT_NOT_FOUND' using errcode = 'PM404';
  end if;
  select * into v_case from public.case_versions
   where id = p_case_version_id and workspace_id = p_workspace_id and project_id = p_project_id;
  if not found then raise exception 'CASE_NOT_FOUND' using errcode = 'PM404'; end if;
  select * into v_agent from public.agent_versions where id = p_agent_version_id and workspace_id = p_workspace_id;
  if not found then raise exception 'AGENT_VERSION_NOT_FOUND' using errcode = 'PM404'; end if;
  select * into v_pack from public.domain_pack_versions where id = v_case.domain_pack_version_id;
  if not found or v_pack.status <> 'active' then raise exception 'PACK_UNAVAILABLE' using errcode = 'PM409'; end if;
  select * into v_payload from core.case_payloads where case_version_id = v_case.id;
  if not found then raise exception 'CASE_PAYLOAD_MISSING' using errcode = 'PM409'; end if;
  if p_kind not in ('evaluation','reduction') then raise exception 'KIND_INVALID' using errcode = 'PM400'; end if;
  if p_repetitions is null or p_repetitions < 1 or p_repetitions > v_max_reps then
    raise exception 'REPETITIONS_OUT_OF_RANGE' using errcode = 'PM400', detail = format('1..%s', v_max_reps);
  end if;

  select coalesce(array_agg(x->>'id'), '{}'::text[]) into v_supported
    from jsonb_array_elements(coalesce(v_pack.manifest->'mutations', '[]'::jsonb)) x;

  v_limits := jsonb_build_object(
    'maxToolCalls',      least(greatest(coalesce((p_limits->>'maxToolCalls')::integer, 20), 1), 20),
    'maxDurationMs',     least(greatest(coalesce((p_limits->>'maxDurationMs')::integer, 180000), 1000), 180000),
    'maxTokens',         least(greatest(coalesce((p_limits->>'maxTokens')::integer, 25000), 256), 25000),
    'maxModelResponses', least(greatest(coalesce((p_limits->>'maxModelResponses')::integer, 12), 1), 12));

  if p_kind = 'reduction' then
    if p_jobs_override is null or jsonb_typeof(p_jobs_override) <> 'array' or jsonb_array_length(p_jobs_override) = 0 then
      raise exception 'JOBS_REQUIRED' using errcode = 'PM400';
    end if;
    for v_scen in select * from jsonb_array_elements(p_jobs_override) loop
      if coalesce(v_scen->>'scenario_id', '') = '' or jsonb_typeof(coalesce(v_scen->'mutations', '[]'::jsonb)) <> 'array' then
        raise exception 'JOB_SPEC_INVALID' using errcode = 'PM400';
      end if;
      for v_m in select * from jsonb_array_elements(coalesce(v_scen->'mutations', '[]'::jsonb)) loop
        if not ((v_m #>> '{ref,id}') = any (v_supported)) then
          raise exception 'MUTATION_NOT_SUPPORTED' using errcode = 'PM400', detail = coalesce(v_m #>> '{ref,id}', '?');
        end if;
      end loop;
      v_jobs := v_jobs || jsonb_build_array(jsonb_build_object('ordinal', v_n, 'scenario_id', v_scen->>'scenario_id',
                                            'repetition', 1, 'mutations', coalesce(v_scen->'mutations', '[]'::jsonb)));
      v_n := v_n + 1;
    end loop;
  else
    if p_scenario_ids is null or cardinality(p_scenario_ids) = 0 then
      raise exception 'SCENARIOS_REQUIRED' using errcode = 'PM400';
    end if;
    if (select count(distinct s) from unnest(p_scenario_ids) s) <> cardinality(p_scenario_ids) then
      raise exception 'SCENARIOS_DUPLICATED' using errcode = 'PM400';
    end if;
    foreach v_sid in array p_scenario_ids loop
      v_scen := v_pack.manifest->'scenarios'->v_sid;
      if v_scen is null then raise exception 'SCENARIO_NOT_IN_PACK' using errcode = 'PM400', detail = v_sid; end if;
      for v_m in select * from jsonb_array_elements(coalesce(v_scen->'mutations', '[]'::jsonb)) loop
        if not ((v_m #>> '{ref,id}') = any (v_supported)) then
          raise exception 'MUTATION_NOT_SUPPORTED' using errcode = 'PM400', detail = coalesce(v_m #>> '{ref,id}', '?');
        end if;
      end loop;
      for v_i in 1..p_repetitions loop
        v_jobs := v_jobs || jsonb_build_array(jsonb_build_object('ordinal', v_n, 'scenario_id', v_sid,
                                              'repetition', v_i, 'mutations', coalesce(v_scen->'mutations', '[]'::jsonb)));
        v_n := v_n + 1;
      end loop;
    end loop;
  end if;

  if v_n > v_ws.max_jobs_per_run then
    raise exception 'TOO_MANY_JOBS' using errcode = 'PM400', detail = format('%s > %s', v_n, v_ws.max_jobs_per_run);
  end if;

  return jsonb_build_object(
    'workspace', jsonb_build_object('id', v_ws.id, 'max_active_jobs', v_ws.max_active_jobs, 'max_jobs_per_run', v_ws.max_jobs_per_run),
    'pack',  jsonb_build_object('id', v_pack.id, 'pack_id', v_pack.pack_id, 'version', v_pack.version,
                                'content_hash', encode(v_pack.content_hash, 'hex'), 'rules', v_pack.manifest->'rules'),
    'case',  jsonb_build_object('id', v_case.id, 'content_hash', encode(v_case.content_hash, 'hex'),
                                'fixture_version', v_case.fixture_version, 'fixture_hash', encode(v_payload.fixture_hash, 'hex'),
                                'oracle_hash', encode(v_payload.oracle_hash, 'hex'), 'classification', v_payload.classification),
    'agent', jsonb_build_object('id', v_agent.id, 'driver', v_agent.driver, 'driver_version', v_agent.driver_version,
                                'policy_id', v_agent.policy_id, 'model_id', v_agent.model_id, 'config', v_agent.config,
                                'content_hash', encode(v_agent.content_hash, 'hex')),
    'jobs', v_jobs, 'jobs_total', v_n, 'limits', v_limits, 'repetitions', p_repetitions);
end $$;

create or replace function core.quote_run(
  p_workspace_id uuid, p_user_id uuid, p_project_id uuid, p_case_version_id uuid, p_agent_version_id uuid,
  p_scenario_ids text[], p_repetitions integer, p_limits jsonb
) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare v_plan jsonb; v_avail integer;
begin
  v_plan := core.prepare_run(p_workspace_id, p_user_id, p_project_id, p_case_version_id, p_agent_version_id,
                             p_scenario_ids, p_repetitions, p_limits, 'evaluation', null);
  select available_units into v_avail from billing.wallets where workspace_id = p_workspace_id;
  return v_plan || jsonb_build_object('units_required', (v_plan->>'jobs_total')::integer,
                                      'units_available', coalesce(v_avail, 0),
                                      'affordable', coalesce(v_avail, 0) >= (v_plan->>'jobs_total')::integer);
end $$;

-- ===========================================================================
-- Crear run: reserva unidades, congela manifiesto, crea control, jobs, reservas y mensajes. Idempotente.
-- ===========================================================================
create or replace function core.create_run(
  p_workspace_id uuid, p_user_id uuid, p_project_id uuid, p_case_version_id uuid, p_agent_version_id uuid,
  p_scenario_ids text[], p_repetitions integer, p_seed integer, p_limits jsonb,
  p_kind text default 'evaluation', p_idempotency_key text default null, p_request_body jsonb default null,
  p_parent_run_id uuid default null, p_reduction_config jsonb default null, p_jobs_override jsonb default null,
  p_engine_version text default '0.1.0'
) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_plan jsonb; v_existing public.runs%rowtype; v_req_hash bytea; v_manifest jsonb; v_run_id uuid;
  v_wallet billing.wallets%rowtype; v_jobs integer; v_j jsonb; v_job_id uuid; v_scen jsonb := '{}'::jsonb;
begin
  v_plan := core.prepare_run(p_workspace_id, p_user_id, p_project_id, p_case_version_id, p_agent_version_id,
                             p_scenario_ids, p_repetitions, p_limits, p_kind, p_jobs_override);
  v_jobs := (v_plan->>'jobs_total')::integer;
  if p_kind = 'reduction' and p_parent_run_id is null then
    raise exception 'PARENT_RUN_REQUIRED' using errcode = 'PM400';
  end if;
  if p_parent_run_id is not null and not exists (select 1 from public.runs where id = p_parent_run_id and workspace_id = p_workspace_id) then
    raise exception 'PARENT_RUN_NOT_FOUND' using errcode = 'PM404';
  end if;

  if p_idempotency_key is not null then
    v_req_hash := core.sha256_json(coalesce(p_request_body, '{}'::jsonb));
    select * into v_existing from public.runs where workspace_id = p_workspace_id and idempotency_key = p_idempotency_key;
    if found then
      if v_existing.request_hash = v_req_hash then
        return jsonb_build_object('run_id', v_existing.id, 'status', v_existing.status, 'jobs_total', v_existing.jobs_total, 'reused', true);
      end if;
      raise exception 'IDEMPOTENCY_CONFLICT' using errcode = 'PM409';
    end if;
  end if;

  -- Wallet: reservar antes de crear trabajos. Sin saldo no quedan trabajos huérfanos.
  select * into v_wallet from billing.wallets where workspace_id = p_workspace_id for update;
  if not found then raise exception 'WALLET_MISSING' using errcode = 'PM409'; end if;
  if v_wallet.available_units < v_jobs then
    raise exception 'CREDITS_REQUIRED' using errcode = 'PM402',
      detail = format('required %s, available %s', v_jobs, v_wallet.available_units);
  end if;

  for v_j in select * from jsonb_array_elements(v_plan->'jobs') loop
    v_scen := v_scen || jsonb_build_object(v_j->>'scenario_id', jsonb_build_object('mutations', v_j->'mutations'));
  end loop;
  v_manifest := jsonb_build_object(
    'engine_version', p_engine_version, 'kind', p_kind, 'data_profile', 'synthetic',
    'pack', v_plan->'pack', 'case', v_plan->'case', 'agent', v_plan->'agent',
    'rules', v_plan->'pack'->'rules', 'scenarios', v_scen,
    'seed', p_seed, 'repetitions', p_repetitions, 'limits', v_plan->'limits', 'jobs_total', v_jobs,
    'parent_run_id', p_parent_run_id, 'reduction_config', p_reduction_config);

  insert into public.runs (workspace_id, project_id, created_by, kind, case_version_id, agent_version_id, domain_pack_version_id,
                           manifest, manifest_hash, seed, repetitions, limits, jobs_total, parent_run_id, reduction_config,
                           idempotency_key, request_hash)
  values (p_workspace_id, p_project_id, p_user_id, p_kind, p_case_version_id, p_agent_version_id, (v_plan->'pack'->>'id')::uuid,
          v_manifest, core.sha256_json(v_manifest), p_seed, p_repetitions, v_plan->'limits', v_jobs, p_parent_run_id, p_reduction_config,
          p_idempotency_key, v_req_hash)
  on conflict (workspace_id, idempotency_key) do nothing
  returning id into v_run_id;

  if v_run_id is null then
    select * into v_existing from public.runs where workspace_id = p_workspace_id and idempotency_key = p_idempotency_key;
    if v_existing.request_hash = v_req_hash then
      return jsonb_build_object('run_id', v_existing.id, 'status', v_existing.status, 'jobs_total', v_existing.jobs_total, 'reused', true);
    end if;
    raise exception 'IDEMPOTENCY_CONFLICT' using errcode = 'PM409';
  end if;

  insert into core.run_controls (run_id, workspace_id) values (v_run_id, p_workspace_id);

  update billing.wallets set available_units = available_units - v_jobs, reserved_units = reserved_units + v_jobs, updated_at = now()
   where workspace_id = p_workspace_id;
  insert into billing.credit_entries (workspace_id, kind, delta_available, delta_reserved, reference_kind, reference_id, note)
  values (p_workspace_id, 'reserve', -v_jobs, v_jobs, 'run', v_run_id::text, format('%s jobs', v_jobs));

  for v_j in select * from jsonb_array_elements(v_plan->'jobs') loop
    insert into public.world_jobs (run_id, workspace_id, ordinal, scenario_id, repetition, mutations, seed)
    values (v_run_id, p_workspace_id, (v_j->>'ordinal')::smallint, v_j->>'scenario_id', (v_j->>'repetition')::smallint,
            v_j->'mutations', p_seed + (v_j->>'ordinal')::integer)
    returning id into v_job_id;
    insert into billing.job_reservations (job_id, run_id, workspace_id) values (v_job_id, v_run_id, p_workspace_id);
    insert into core.job_queue (job_id, run_id, workspace_id) values (v_job_id, v_run_id, p_workspace_id);
  end loop;

  return jsonb_build_object('run_id', v_run_id, 'status', 'queued', 'jobs_total', v_jobs, 'units_reserved', v_jobs, 'reused', false);
end $$;

-- ===========================================================================
-- Billing: reservas, liquidación y progreso del run (internas)
-- ===========================================================================
create or replace function core.resolve_reservation(p_job_id uuid, p_action text)
returns boolean
language plpgsql security definer
set search_path = ''
as $$
declare v_res billing.job_reservations%rowtype;
begin
  if p_action not in ('settle','release') then raise exception 'RESERVATION_ACTION_INVALID' using errcode = 'PM400'; end if;
  select * into v_res from billing.job_reservations where job_id = p_job_id for update;
  if not found or v_res.status <> 'reserved' then
    return false;                                   -- ya resuelta o inexistente: idempotente
  end if;
  perform 1 from billing.wallets where workspace_id = v_res.workspace_id for update;
  if p_action = 'settle' then
    update billing.wallets set reserved_units = reserved_units - v_res.units, updated_at = now() where workspace_id = v_res.workspace_id;
    insert into billing.credit_entries (workspace_id, kind, delta_available, delta_reserved, reference_kind, reference_id)
    values (v_res.workspace_id, 'settle', 0, -v_res.units, 'job', p_job_id::text);
  else
    update billing.wallets set reserved_units = reserved_units - v_res.units, available_units = available_units + v_res.units, updated_at = now()
     where workspace_id = v_res.workspace_id;
    insert into billing.credit_entries (workspace_id, kind, delta_available, delta_reserved, reference_kind, reference_id)
    values (v_res.workspace_id, 'release', v_res.units, -v_res.units, 'job', p_job_id::text);
  end if;
  update billing.job_reservations set status = case when p_action = 'settle' then 'settled' else 'released' end, resolved_at = now()
   where job_id = p_job_id;
  return true;
end $$;

create or replace function core.bump_run_progress(p_run_id uuid, p_job_status text, p_verdict text)
returns text
language plpgsql security definer
set search_path = ''
as $$
declare v_status text;
begin
  update public.runs set
    jobs_terminal     = jobs_terminal + 1,
    jobs_passed       = jobs_passed       + (p_verdict is not distinct from 'passed')::integer,
    jobs_safe_stop    = jobs_safe_stop    + (p_verdict is not distinct from 'safe_stop')::integer,
    jobs_failed       = jobs_failed       + (p_verdict is not distinct from 'failed')::integer,
    jobs_inconclusive = jobs_inconclusive + (p_verdict is not distinct from 'inconclusive')::integer,
    jobs_errored      = jobs_errored      + (p_job_status is not distinct from 'errored')::integer,
    jobs_cancelled    = jobs_cancelled    + (p_job_status is not distinct from 'cancelled')::integer,
    status   = case when status = 'cancelled' then 'cancelled'
                    when jobs_terminal + 1 >= jobs_total then 'completed' else status end,
    ended_at = case when jobs_terminal + 1 >= jobs_total and ended_at is null then now() else ended_at end
  where id = p_run_id
  returning status into v_status;
  return v_status;
end $$;

-- ===========================================================================
-- Cadena de pertenencia y lease. Orden de bloqueo: run_controls FOR SHARE → job FOR UPDATE → attempt FOR UPDATE.
-- ===========================================================================
create or replace function core.lock_job_context(
  p_job_id uuid, p_attempt_id uuid, p_worker text, p_epoch integer, p_allow_cancelled boolean,
  out o_job public.world_jobs, out o_attempt public.world_attempts, out o_cancel_requested boolean
)
language plpgsql security definer
set search_path = ''
as $$
declare v_run uuid; v_ctl core.run_controls%rowtype;
begin
  if p_job_id is null or p_attempt_id is null or p_worker is null or length(p_worker) = 0 or p_epoch is null then
    raise exception 'CONTEXT_REQUIRED' using errcode = 'PM400';
  end if;
  select run_id into v_run from public.world_jobs where id = p_job_id;
  if v_run is null then raise exception 'JOB_NOT_FOUND' using errcode = 'PM404'; end if;
  select * into v_ctl from core.run_controls where run_id = v_run for share;
  if not found then raise exception 'RUN_CONTROL_MISSING' using errcode = 'PM409'; end if;
  o_cancel_requested := v_ctl.cancel_requested_at is not null;
  if o_cancel_requested and not p_allow_cancelled then
    raise exception 'RUN_CANCELLED' using errcode = 'PM423';
  end if;
  select * into o_job from public.world_jobs where id = p_job_id for update;
  if o_job.status <> 'running' then raise exception 'JOB_NOT_RUNNING' using errcode = 'PM423', detail = o_job.status; end if;
  if o_job.lease_owner is null or o_job.lease_owner <> p_worker or o_job.lease_epoch <> p_epoch then
    raise exception 'LEASE_MISMATCH' using errcode = 'PM423';
  end if;
  if o_job.lease_until is null or o_job.lease_until <= now() then
    raise exception 'LEASE_EXPIRED' using errcode = 'PM423';
  end if;
  select * into o_attempt from public.world_attempts where id = p_attempt_id for update;
  if not found then raise exception 'ATTEMPT_NOT_FOUND' using errcode = 'PM404'; end if;
  if o_attempt.job_id <> o_job.id or o_attempt.run_id <> o_job.run_id or o_attempt.workspace_id <> o_job.workspace_id then
    raise exception 'ATTEMPT_CHAIN_MISMATCH' using errcode = 'PM403';
  end if;
  if o_job.active_attempt_id is null or o_job.active_attempt_id <> o_attempt.id then
    raise exception 'ATTEMPT_NOT_ACTIVE' using errcode = 'PM409';
  end if;
  if o_attempt.status <> 'running' then raise exception 'ATTEMPT_NOT_RUNNING' using errcode = 'PM409'; end if;
end $$;

-- ===========================================================================
-- Evidencia: valida y anexa eventos con secuencia contigua y enlace de hashes. Interna.
-- Evento: { event_id, seq, type, audience, format?, public_payload, public_payload_hash,
--           private_payload?, private_blob_hash?, prev_hash, event_hash }   (hashes en hex)
-- ===========================================================================
create or replace function core.append_events(p_attempt public.world_attempts, p_events jsonb)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_state core.attempt_states%rowtype; v_e jsonb; v_seq integer; v_first integer; v_prev bytea; v_hash bytea; v_pub bytea;
  v_eid uuid; v_priv jsonb; v_pid uuid; v_priv_hash bytea; v_n integer; v_type text; v_aud text;
begin
  if p_events is null or jsonb_typeof(p_events) <> 'array' then
    raise exception 'EVENTS_MUST_BE_ARRAY' using errcode = 'PM400';
  end if;
  v_n := jsonb_array_length(p_events);
  if v_n = 0 then return jsonb_build_object('count', 0); end if;

  select * into v_state from core.attempt_states where attempt_id = p_attempt.id for update;
  if not found then raise exception 'ATTEMPT_STATE_MISSING' using errcode = 'PM409'; end if;
  v_seq := v_state.next_seq; v_first := v_seq; v_prev := v_state.last_event_hash;

  for v_e in select * from jsonb_array_elements(p_events) loop
    if jsonb_typeof(v_e) <> 'object' then raise exception 'EVENT_MUST_BE_OBJECT' using errcode = 'PM400'; end if;
    if coalesce((v_e->>'format')::integer, 1) <> 1 then raise exception 'EVIDENCE_FORMAT_UNSUPPORTED' using errcode = 'PM400'; end if;
    v_eid := (v_e->>'event_id')::uuid;
    if v_eid is null then raise exception 'EVENT_ID_REQUIRED' using errcode = 'PM400'; end if;
    if (v_e->>'seq')::integer is distinct from v_seq then
      raise exception 'EVENT_SEQ_MISMATCH' using errcode = 'PM409', detail = format('expected %s, got %s', v_seq, v_e->>'seq');
    end if;
    v_type := v_e->>'type'; v_aud := v_e->>'audience';
    if coalesce(v_type, '') = '' or v_aud is null or v_aud not in ('agent','inspector','system') then
      raise exception 'EVENT_TYPE_OR_AUDIENCE_INVALID' using errcode = 'PM400';
    end if;
    if jsonb_typeof(coalesce(v_e->'public_payload', '{}'::jsonb)) <> 'object' then
      raise exception 'PUBLIC_PAYLOAD_MUST_BE_OBJECT' using errcode = 'PM400';
    end if;
    v_pub  := core.hex32(v_e->>'public_payload_hash', 'public_payload_hash');
    v_hash := core.hex32(v_e->>'event_hash', 'event_hash');
    if v_seq = 1 then
      if v_e->>'prev_hash' is not null then raise exception 'GENESIS_PREV_HASH_MUST_BE_NULL' using errcode = 'PM400'; end if;
    else
      if v_prev is null or core.hex32(v_e->>'prev_hash', 'prev_hash') <> v_prev then
        raise exception 'EVENT_CHAIN_BROKEN' using errcode = 'PM409', detail = format('seq %s', v_seq);
      end if;
    end if;

    v_pid := null; v_priv_hash := null; v_priv := v_e->'private_payload';
    if v_priv is not null and jsonb_typeof(v_priv) = 'object' then
      v_pid := core.store_payload(p_attempt.workspace_id, v_priv, 'event', v_eid);
      v_priv_hash := core.hex32(v_e->>'private_blob_hash', 'private_blob_hash');
      if v_priv_hash <> (select digest from core.payloads where id = v_pid) then
        raise exception 'PRIVATE_HASH_MISMATCH' using errcode = 'PM400';
      end if;
    elsif v_e->>'private_blob_hash' is not null then
      raise exception 'PRIVATE_HASH_WITHOUT_PAYLOAD' using errcode = 'PM400';
    end if;

    insert into public.attempt_events (event_id, workspace_id, run_id, job_id, attempt_id, seq, format, type, audience,
                                       public_payload, public_payload_hash, private_payload_id, private_blob_hash, prev_hash, event_hash)
    values (v_eid, p_attempt.workspace_id, p_attempt.run_id, p_attempt.job_id, p_attempt.id, v_seq, 1, v_type, v_aud,
            coalesce(v_e->'public_payload', '{}'::jsonb), v_pub, v_pid, v_priv_hash,
            case when v_seq = 1 then null else v_prev end, v_hash);
    v_prev := v_hash; v_seq := v_seq + 1;
  end loop;

  update core.attempt_states set next_seq = v_seq, last_event_hash = v_prev, updated_at = now() where attempt_id = p_attempt.id;
  return jsonb_build_object('count', v_n, 'first_seq', v_first, 'last_seq', v_seq - 1, 'last_hash', encode(v_prev, 'hex'));
end $$;

-- ===========================================================================
-- Cola nativa: tomar mensajes visibles con SKIP LOCKED, extender visibilidad y archivar.
-- Un mensaje redelivered de un job terminal se archiva al reclamar (claim_job devuelve 'terminal').
-- ===========================================================================
create or replace function core.dequeue_jobs(p_worker text, p_max integer default 1, p_visibility_seconds integer default 60)
returns table (msg_id bigint, job_id uuid, run_id uuid, read_ct integer)
language plpgsql security definer
set search_path = ''
as $$
#variable_conflict use_column
begin
  if p_worker is null or length(p_worker) = 0 then raise exception 'WORKER_ID_REQUIRED' using errcode = 'PM400'; end if;
  return query
  with picked as (
    select q.msg_id
      from core.job_queue q
     where q.archived_at is null and q.visible_at <= now()
     order by q.msg_id
     for update skip locked
     limit greatest(least(coalesce(p_max, 1), 50), 1)
  )
  update core.job_queue q
     set visible_at = now() + make_interval(secs => greatest(coalesce(p_visibility_seconds, 60), 5)),
         read_ct = q.read_ct + 1, last_worker = p_worker
    from picked
   where q.msg_id = picked.msg_id
  returning q.msg_id, q.job_id, q.run_id, q.read_ct;
end $$;

create or replace function core.extend_visibility(p_msg_id bigint, p_worker text, p_seconds integer default 60)
returns boolean
language plpgsql security definer
set search_path = ''
as $$
declare v_ok boolean;
begin
  update core.job_queue
     set visible_at = now() + make_interval(secs => greatest(coalesce(p_seconds, 60), 5)), last_worker = p_worker
   where msg_id = p_msg_id and archived_at is null
  returning true into v_ok;
  return coalesce(v_ok, false);
end $$;

create or replace function core.archive_message(p_msg_id bigint, p_worker text)
returns boolean
language plpgsql security definer
set search_path = ''
as $$
declare v_ok boolean;
begin
  update core.job_queue set archived_at = now(), last_worker = coalesce(p_worker, last_worker)
   where msg_id = p_msg_id and archived_at is null
  returning true into v_ok;
  return coalesce(v_ok, false);
end $$;

-- ===========================================================================
-- Worker: reclamar, recuperar, latido, leer contexto, confirmar transición, terminar
-- ===========================================================================
create or replace function core.claim_job(
  p_job_id uuid, p_worker text, p_ttl_seconds integer, p_domain_state jsonb, p_injection_state jsonb, p_genesis_event jsonb
) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_ws_id uuid; v_run_id uuid; v_ws public.workspaces%rowtype; v_ctl core.run_controls%rowtype; v_job public.world_jobs%rowtype;
  v_running integer; v_att public.world_attempts%rowtype; v_epoch integer; v_until timestamptz; v_ev jsonb;
begin
  if p_worker is null or length(p_worker) = 0 then raise exception 'WORKER_ID_REQUIRED' using errcode = 'PM400'; end if;
  select workspace_id, run_id into v_ws_id, v_run_id from public.world_jobs where id = p_job_id;
  if v_run_id is null then raise exception 'JOB_NOT_FOUND' using errcode = 'PM404'; end if;

  select * into v_ws  from public.workspaces where id = v_ws_id for update;          -- serializa el límite por workspace
  select * into v_ctl from core.run_controls where run_id = v_run_id for share;
  select * into v_job from public.world_jobs where id = p_job_id for update;

  if v_job.status in ('completed','errored','cancelled') then
    return jsonb_build_object('claimed', false, 'reason', 'terminal', 'status', v_job.status);
  end if;
  if v_ctl.cancel_requested_at is not null then
    if v_job.status = 'queued' then
      update public.world_jobs set status = 'cancelled', terminal_reason = 'cancelled_before_start', ended_at = now() where id = p_job_id;
      perform core.bump_run_progress(v_run_id, 'cancelled', null);
      perform core.resolve_reservation(p_job_id, 'release');
    end if;
    return jsonb_build_object('claimed', false, 'reason', 'cancelled');
  end if;
  if v_job.status = 'running' then
    if v_job.lease_until is not null and v_job.lease_until > now() then
      return jsonb_build_object('claimed', false, 'reason', 'held', 'lease_until', v_job.lease_until);
    end if;
    return jsonb_build_object('claimed', false, 'reason', 'lease_expired', 'recovery_count', v_job.recovery_count);
  end if;

  select count(*) into v_running from public.world_jobs where workspace_id = v_ws_id and status = 'running';
  if v_running >= v_ws.max_active_jobs then
    return jsonb_build_object('claimed', false, 'reason', 'workspace_limit', 'retry_after_seconds', 5);
  end if;
  if p_domain_state is null or jsonb_typeof(p_domain_state) <> 'object' then
    raise exception 'STATE_MUST_BE_OBJECT' using errcode = 'PM400';
  end if;

  v_epoch := v_job.lease_epoch + 1;
  v_until := now() + make_interval(secs => greatest(coalesce(p_ttl_seconds, 60), 5));
  insert into public.world_attempts (job_id, run_id, workspace_id, attempt_number)
  values (p_job_id, v_run_id, v_ws_id, 1) returning * into v_att;
  insert into core.attempt_states (attempt_id, workspace_id, domain_state, injection_state)
  values (v_att.id, v_ws_id, p_domain_state, coalesce(p_injection_state, '{}'::jsonb));
  update public.world_jobs
     set status = 'running', lease_owner = p_worker, lease_epoch = v_epoch, lease_until = v_until,
         active_attempt_id = v_att.id, started_at = coalesce(started_at, now())
   where id = p_job_id;
  v_ev := core.append_events(v_att, jsonb_build_array(p_genesis_event));
  update public.runs set status = 'running', started_at = coalesce(started_at, now()) where id = v_run_id and status = 'queued';

  return jsonb_build_object('claimed', true, 'attempt_id', v_att.id, 'attempt_number', 1, 'lease_epoch', v_epoch,
                            'lease_until', v_until, 'state_version', 0, 'next_seq', 2, 'last_hash', v_ev->>'last_hash');
end $$;

create or replace function core.recover_job(
  p_job_id uuid, p_worker text, p_ttl_seconds integer, p_domain_state jsonb, p_injection_state jsonb, p_genesis_event jsonb
) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_ws_id uuid; v_run_id uuid; v_ctl core.run_controls%rowtype; v_job public.world_jobs%rowtype;
  v_att public.world_attempts%rowtype; v_epoch integer; v_until timestamptz; v_ev jsonb; v_n integer;
begin
  if p_worker is null or length(p_worker) = 0 then raise exception 'WORKER_ID_REQUIRED' using errcode = 'PM400'; end if;
  select workspace_id, run_id into v_ws_id, v_run_id from public.world_jobs where id = p_job_id;
  if v_run_id is null then raise exception 'JOB_NOT_FOUND' using errcode = 'PM404'; end if;
  perform 1 from public.workspaces where id = v_ws_id for update;
  select * into v_ctl from core.run_controls where run_id = v_run_id for share;
  select * into v_job from public.world_jobs where id = p_job_id for update;

  if v_job.status <> 'running' then
    return jsonb_build_object('recovered', false, 'reason', 'not_running', 'status', v_job.status);
  end if;
  if v_job.lease_until is not null and v_job.lease_until > now() then
    return jsonb_build_object('recovered', false, 'reason', 'held', 'lease_until', v_job.lease_until);
  end if;

  -- El intento interrumpido queda como evidencia; nunca se reanuda.
  update public.world_attempts set status = 'aborted', termination = 'lease_lost', ended_at = now()
   where id = v_job.active_attempt_id and status = 'running';

  if v_ctl.cancel_requested_at is not null then
    update public.world_jobs set status = 'cancelled', terminal_reason = 'cancelled_after_lease_loss',
           lease_owner = null, lease_until = null, ended_at = now() where id = p_job_id;
    perform core.bump_run_progress(v_run_id, 'cancelled', null);
    perform core.resolve_reservation(p_job_id, 'release');
    return jsonb_build_object('recovered', false, 'reason', 'cancelled');
  end if;
  if v_job.recovery_count >= 1 then
    update public.world_jobs set status = 'errored', terminal_reason = 'lease_lost_twice',
           lease_owner = null, lease_until = null, ended_at = now() where id = p_job_id;
    perform core.bump_run_progress(v_run_id, 'errored', null);
    perform core.resolve_reservation(p_job_id, 'release');
    return jsonb_build_object('recovered', false, 'reason', 'recovery_exhausted');
  end if;
  if p_domain_state is null or jsonb_typeof(p_domain_state) <> 'object' then
    raise exception 'STATE_MUST_BE_OBJECT' using errcode = 'PM400';
  end if;

  select coalesce(max(attempt_number), 0) + 1 into v_n from public.world_attempts where job_id = p_job_id;
  v_epoch := v_job.lease_epoch + 1;
  v_until := now() + make_interval(secs => greatest(coalesce(p_ttl_seconds, 60), 5));
  insert into public.world_attempts (job_id, run_id, workspace_id, attempt_number)
  values (p_job_id, v_run_id, v_ws_id, v_n) returning * into v_att;
  insert into core.attempt_states (attempt_id, workspace_id, domain_state, injection_state)
  values (v_att.id, v_ws_id, p_domain_state, coalesce(p_injection_state, '{}'::jsonb));
  update public.world_jobs
     set lease_owner = p_worker, lease_epoch = v_epoch, lease_until = v_until,
         active_attempt_id = v_att.id, recovery_count = recovery_count + 1
   where id = p_job_id;
  v_ev := core.append_events(v_att, jsonb_build_array(p_genesis_event));

  return jsonb_build_object('recovered', true, 'attempt_id', v_att.id, 'attempt_number', v_n, 'lease_epoch', v_epoch,
                            'lease_until', v_until, 'state_version', 0, 'next_seq', 2, 'last_hash', v_ev->>'last_hash');
end $$;

create or replace function core.heartbeat_job(p_job_id uuid, p_worker text, p_epoch integer, p_ttl_seconds integer, p_msg_id bigint default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare v_run uuid; v_ctl core.run_controls%rowtype; v_job public.world_jobs%rowtype; v_until timestamptz;
begin
  select run_id into v_run from public.world_jobs where id = p_job_id;
  if v_run is null then raise exception 'JOB_NOT_FOUND' using errcode = 'PM404'; end if;
  select * into v_ctl from core.run_controls where run_id = v_run for share;
  select * into v_job from public.world_jobs where id = p_job_id for update;
  if v_job.status <> 'running' or v_job.lease_owner is distinct from p_worker or v_job.lease_epoch <> p_epoch
     or v_job.lease_until is null or v_job.lease_until <= now() then
    return jsonb_build_object('ok', false, 'reason', 'lease_invalid', 'status', v_job.status);
  end if;
  v_until := now() + make_interval(secs => greatest(coalesce(p_ttl_seconds, 60), 5));
  update public.world_jobs set lease_until = v_until where id = p_job_id;
  if p_msg_id is not null then
    update core.job_queue set visible_at = v_until where msg_id = p_msg_id and job_id = p_job_id and archived_at is null;
  end if;
  return jsonb_build_object('ok', true, 'lease_until', v_until, 'cancel_requested', v_ctl.cancel_requested_at is not null);
end $$;

create or replace function core.read_job_inputs(p_job_id uuid, p_attempt_id uuid, p_worker text, p_epoch integer)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_job public.world_jobs; v_att public.world_attempts; v_cancel boolean; v_ctx record;
  v_run public.runs%rowtype; v_case public.case_versions%rowtype; v_cp core.case_payloads%rowtype;
  v_agent public.agent_versions%rowtype; v_pl core.payloads%rowtype; v_prompt jsonb := null;
begin
  select * into v_ctx from core.lock_job_context(p_job_id, p_attempt_id, p_worker, p_epoch, false);
  v_job := v_ctx.o_job; v_att := v_ctx.o_attempt; v_cancel := v_ctx.o_cancel_requested;
  select * into v_run   from public.runs where id = v_job.run_id;
  select * into v_case  from public.case_versions where id = v_run.case_version_id;
  select * into v_cp    from core.case_payloads where case_version_id = v_case.id;
  select * into v_agent from public.agent_versions where id = v_run.agent_version_id;
  if v_agent.prompt_payload_id is not null then
    select * into v_pl from core.payloads where id = v_agent.prompt_payload_id;
    v_prompt := jsonb_build_object('payload_id', v_pl.id, 'encrypted', v_pl.encrypted, 'classification', v_pl.classification,
                                   'content', v_pl.content, 'blob_b64', case when v_pl.blob is null then null else encode(v_pl.blob, 'base64') end,
                                   'key_id', v_pl.key_id, 'digest', encode(v_pl.digest, 'hex'), 'purged', v_pl.purged_at is not null);
    insert into core.access_log (workspace_id, actor_kind, action, resource_type, resource_id, detail)
    values (v_job.workspace_id, 'worker', 'read_prompt', 'agent_version', v_agent.id,
            jsonb_build_object('job_id', v_job.id, 'attempt_id', v_att.id, 'worker', p_worker));
  end if;
  return jsonb_build_object(
    'run',   jsonb_build_object('id', v_run.id, 'kind', v_run.kind, 'manifest', v_run.manifest, 'limits', v_run.limits, 'seed', v_run.seed),
    'job',   jsonb_build_object('id', v_job.id, 'ordinal', v_job.ordinal, 'scenario_id', v_job.scenario_id, 'repetition', v_job.repetition,
                                'mutations', v_job.mutations, 'seed', v_job.seed, 'attempt_id', v_att.id, 'attempt_number', v_att.attempt_number),
    'case',  jsonb_build_object('id', v_case.id, 'fixture_version', v_case.fixture_version, 'task', v_case.task,
                                'public_context', v_case.public_context, 'fixture', v_cp.fixture, 'oracle', v_cp.oracle),
    'agent', jsonb_build_object('id', v_agent.id, 'driver', v_agent.driver, 'driver_version', v_agent.driver_version,
                                'policy_id', v_agent.policy_id, 'model_id', v_agent.model_id, 'config', v_agent.config, 'prompt', v_prompt),
    'cancel_requested', v_cancel);
end $$;

create or replace function core.read_attempt_context(p_job_id uuid, p_attempt_id uuid, p_worker text, p_epoch integer)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare v_job public.world_jobs; v_att public.world_attempts; v_cancel boolean; v_ctx record; v_state core.attempt_states%rowtype;
begin
  select * into v_ctx from core.lock_job_context(p_job_id, p_attempt_id, p_worker, p_epoch, true);
  v_job := v_ctx.o_job; v_att := v_ctx.o_attempt; v_cancel := v_ctx.o_cancel_requested;
  select * into v_state from core.attempt_states where attempt_id = p_attempt_id;
  return jsonb_build_object('attempt_id', v_att.id, 'state_version', v_state.state_version, 'domain_state', v_state.domain_state,
                            'injection_state', v_state.injection_state, 'next_seq', v_state.next_seq,
                            'last_hash', encode(v_state.last_event_hash, 'hex'), 'cancel_requested', v_cancel);
end $$;

create or replace function core.commit_transition(
  p_job_id uuid, p_attempt_id uuid, p_worker text, p_epoch integer,
  p_commit_id uuid, p_call_id text, p_tool text, p_fingerprint bytea, p_expected_version integer,
  p_next_state jsonb, p_injection_state jsonb, p_events jsonb, p_effects jsonb, p_observation jsonb
) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_job public.world_jobs; v_att public.world_attempts; v_cancel boolean; v_ctx record; v_state core.attempt_states%rowtype;
  v_prev public.tool_commits%rowtype; v_ev jsonb; v_f jsonb; v_eid uuid; v_batch uuid[];
begin
  select * into v_ctx from core.lock_job_context(p_job_id, p_attempt_id, p_worker, p_epoch, false);
  v_job := v_ctx.o_job; v_att := v_ctx.o_attempt; v_cancel := v_ctx.o_cancel_requested;
  if p_commit_id is null or p_fingerprint is null or coalesce(p_tool, '') = '' then
    raise exception 'COMMIT_FIELDS_REQUIRED' using errcode = 'PM400';
  end if;
  select * into v_state from core.attempt_states where attempt_id = p_attempt_id for update;
  if not found then raise exception 'ATTEMPT_STATE_MISSING' using errcode = 'PM409'; end if;

  -- Idempotencia técnica: repetir el mismo commit devuelve la observación persistida.
  select * into v_prev from public.tool_commits where attempt_id = p_attempt_id and commit_id = p_commit_id;
  if found then
    if v_prev.fingerprint = p_fingerprint then
      return jsonb_build_object('ok', true, 'replayed', true, 'observation', v_prev.response,
                                'state_version', v_prev.state_version_after, 'first_seq', v_prev.first_seq, 'last_seq', v_prev.last_seq);
    end if;
    raise exception 'COMMIT_CONFLICT' using errcode = 'PM409';
  end if;

  if p_expected_version is null or p_expected_version <> v_state.state_version then
    raise exception 'STATE_STALE' using errcode = 'PM409', detail = format('expected %s, actual %s', p_expected_version, v_state.state_version);
  end if;
  if p_next_state is null or jsonb_typeof(p_next_state) <> 'object' then raise exception 'STATE_MUST_BE_OBJECT' using errcode = 'PM400'; end if;
  if octet_length(p_next_state::text) > 262144 then raise exception 'STATE_TOO_LARGE' using errcode = 'PM400'; end if;
  if p_injection_state is not null and jsonb_typeof(p_injection_state) <> 'object' then
    raise exception 'INJECTION_STATE_MUST_BE_OBJECT' using errcode = 'PM400';
  end if;
  if p_observation is null or jsonb_typeof(p_observation) <> 'object' then raise exception 'OBSERVATION_REQUIRED' using errcode = 'PM400'; end if;
  if p_events is null or jsonb_typeof(p_events) <> 'array' or jsonb_array_length(p_events) = 0 then
    raise exception 'EVENTS_REQUIRED' using errcode = 'PM400', hint = 'Toda llamada deja evidencia, incluidos errores y replays.';
  end if;

  v_ev := core.append_events(v_att, p_events);
  select coalesce(array_agg((e->>'event_id')::uuid), '{}'::uuid[]) into v_batch from jsonb_array_elements(p_events) e;

  if p_effects is not null then
    if jsonb_typeof(p_effects) <> 'array' then raise exception 'EFFECTS_MUST_BE_ARRAY' using errcode = 'PM400'; end if;
    for v_f in select * from jsonb_array_elements(p_effects) loop
      v_eid := (v_f->>'event_id')::uuid;
      if v_eid is null or not (v_eid = any (v_batch)) then
        raise exception 'EFFECT_EVENT_NOT_IN_TRANSITION' using errcode = 'PM400';
      end if;
      insert into public.effects (effect_id, workspace_id, run_id, job_id, attempt_id, event_id, type, logical_operation_id, resource_id, payload)
      values (coalesce((v_f->>'effect_id')::uuid, gen_random_uuid()), v_att.workspace_id, v_att.run_id, v_att.job_id, p_attempt_id, v_eid,
              v_f->>'type', v_f->>'logical_operation_id', v_f->>'resource_id', coalesce(v_f->'payload', '{}'::jsonb));
    end loop;
  end if;

  update core.attempt_states
     set domain_state = p_next_state, injection_state = coalesce(p_injection_state, injection_state),
         state_version = state_version + 1, updated_at = now()
   where attempt_id = p_attempt_id;

  insert into public.tool_commits (attempt_id, workspace_id, commit_id, call_id, tool, fingerprint,
                                   state_version_before, state_version_after, first_seq, last_seq, response)
  values (p_attempt_id, v_att.workspace_id, p_commit_id, p_call_id, p_tool, p_fingerprint,
          v_state.state_version, v_state.state_version + 1, (v_ev->>'first_seq')::integer, (v_ev->>'last_seq')::integer, p_observation);

  return jsonb_build_object('ok', true, 'replayed', false, 'observation', p_observation, 'state_version', v_state.state_version + 1,
                            'first_seq', (v_ev->>'first_seq')::integer, 'last_seq', (v_ev->>'last_seq')::integer, 'last_hash', v_ev->>'last_hash');
end $$;

create or replace function core.finish_attempt(
  p_job_id uuid, p_attempt_id uuid, p_worker text, p_epoch integer,
  p_termination text, p_verdict text, p_final_output jsonb, p_final_private jsonb,
  p_rule_results jsonb, p_usage jsonb, p_events jsonb
) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_job public.world_jobs; v_att public.world_attempts; v_cancel boolean; v_ctx record; v_state core.attempt_states%rowtype;
  v_term text := p_termination; v_verdict text := p_verdict; v_r jsonb; v_n integer := 0; v_manifest jsonb;
  v_required text[]; v_present text[]; v_missing text[]; v_final_pid uuid; v_job_status text; v_run_status text; v_ev jsonb;
begin
  select * into v_ctx from core.lock_job_context(p_job_id, p_attempt_id, p_worker, p_epoch, true);
  v_job := v_ctx.o_job; v_att := v_ctx.o_attempt; v_cancel := v_ctx.o_cancel_requested;
  if v_term not in ('finished','limit','provider_error','cancelled') then raise exception 'TERMINATION_INVALID' using errcode = 'PM400'; end if;
  if v_verdict not in ('passed','safe_stop','failed','inconclusive') then raise exception 'VERDICT_INVALID' using errcode = 'PM400'; end if;
  if v_cancel then v_term := 'cancelled'; end if;
  if v_term <> 'finished' and v_verdict in ('passed','safe_stop') then
    raise exception 'VERDICT_INCOMPATIBLE' using errcode = 'PM409', detail = format('%s with %s', v_verdict, v_term);
  end if;

  if p_events is not null and jsonb_typeof(p_events) = 'array' and jsonb_array_length(p_events) > 0 then
    v_ev := core.append_events(v_att, p_events);
  end if;
  select * into v_state from core.attempt_states where attempt_id = p_attempt_id;

  -- Cada regla requerida del manifiesto debe tener un resultado, aunque sea not_evaluated.
  select manifest into v_manifest from public.runs where id = v_job.run_id;
  select coalesce(array_agg(r->>'id'), '{}'::text[]) into v_required
    from jsonb_array_elements(coalesce(v_manifest->'rules', '[]'::jsonb)) r where coalesce((r->>'required')::boolean, true);
  if p_rule_results is null or jsonb_typeof(p_rule_results) <> 'array' then
    raise exception 'RULE_RESULTS_REQUIRED' using errcode = 'PM400';
  end if;
  for v_r in select * from jsonb_array_elements(p_rule_results) loop
    insert into public.rule_results (attempt_id, workspace_id, rule_id, status, category, expected, observed, evidence_event_ids, explanation)
    values (p_attempt_id, v_att.workspace_id, v_r->>'rule_id', v_r->>'status', v_r->>'category',
            coalesce(v_r->'expected', '{}'::jsonb), coalesce(v_r->'observed', '{}'::jsonb),
            coalesce((select array_agg(x::uuid) from jsonb_array_elements_text(coalesce(v_r->'evidence_event_ids', '[]'::jsonb)) t(x)), '{}'::uuid[]),
            coalesce(v_r->>'explanation', ''));
    v_n := v_n + 1;
  end loop;
  select coalesce(array_agg(rule_id), '{}'::text[]) into v_present from public.rule_results where attempt_id = p_attempt_id;
  select coalesce(array_agg(x), '{}'::text[]) into v_missing from unnest(v_required) x where not (x = any (v_present));
  if cardinality(v_missing) > 0 then
    raise exception 'RULE_COVERAGE_INCOMPLETE' using errcode = 'PM400', detail = array_to_string(v_missing, ',');
  end if;
  if v_verdict = 'passed' and exists (select 1 from public.rule_results where attempt_id = p_attempt_id and status in ('violation','not_evaluated')) then
    raise exception 'VERDICT_PASSED_WITH_OPEN_RULES' using errcode = 'PM409';
  end if;

  if p_final_private is not null then
    v_final_pid := core.store_payload(v_att.workspace_id, p_final_private, 'attempt_final', p_attempt_id);
  end if;

  update public.world_attempts
     set status = 'completed', verdict = v_verdict, termination = v_term, final_output = p_final_output,
         final_payload_id = v_final_pid, usage = p_usage, chain_length = v_state.next_seq - 1,
         chain_head = v_state.last_event_hash, ended_at = now()
   where id = p_attempt_id;

  v_job_status := case when v_term = 'cancelled' then 'cancelled' else 'completed' end;
  update public.world_jobs
     set status = v_job_status, verdict = v_verdict, lease_owner = null, lease_until = null,
         terminal_reason = v_term, ended_at = now()
   where id = p_job_id;

  -- Orden de bloqueo: runs antes que wallet (igual que cancel_run).
  v_run_status := core.bump_run_progress(v_job.run_id, v_job_status, v_verdict);
  perform core.resolve_reservation(p_job_id,
            case when v_term = 'finished' and v_verdict in ('passed','safe_stop','failed') then 'settle' else 'release' end);

  return jsonb_build_object('ok', true, 'verdict', v_verdict, 'termination', v_term, 'job_status', v_job_status,
                            'run_status', v_run_status, 'rules', v_n, 'chain_length', v_state.next_seq - 1,
                            'chain_head', encode(v_state.last_event_hash, 'hex'));
end $$;

-- ===========================================================================
-- Cancelación: solo la fila de control (exclusivo, espera commits en curso) y los jobs en cola.
-- ===========================================================================
create or replace function core.cancel_run(p_run_id uuid, p_workspace_id uuid, p_user_id uuid)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare v_run public.runs%rowtype; v_j record; v_n integer := 0; v_running integer;
begin
  perform core.assert_member(p_workspace_id, p_user_id);
  select * into v_run from public.runs where id = p_run_id and workspace_id = p_workspace_id;
  if not found then raise exception 'RUN_NOT_FOUND' using errcode = 'PM404'; end if;
  if v_run.status in ('completed','cancelled') then
    return jsonb_build_object('run_id', p_run_id, 'status', v_run.status, 'changed', false);
  end if;
  update core.run_controls set cancel_requested_at = now(), cancel_requested_by = p_user_id
   where run_id = p_run_id and cancel_requested_at is null;
  update public.runs set status = 'cancelled', ended_at = coalesce(ended_at, now()) where id = p_run_id;
  for v_j in select id from public.world_jobs where run_id = p_run_id and status = 'queued' order by ordinal for update loop
    update public.world_jobs set status = 'cancelled', terminal_reason = 'cancelled_before_start', ended_at = now() where id = v_j.id;
    update core.job_queue set archived_at = now() where job_id = v_j.id and archived_at is null;
    perform core.bump_run_progress(p_run_id, 'cancelled', null);
    perform core.resolve_reservation(v_j.id, 'release');
    v_n := v_n + 1;
  end loop;
  select count(*) into v_running from public.world_jobs where run_id = p_run_id and status = 'running';
  return jsonb_build_object('run_id', p_run_id, 'status', 'cancelled', 'changed', true,
                            'jobs_cancelled_now', v_n, 'jobs_still_running', v_running);
end $$;

-- ===========================================================================
-- Billing: compras Stripe (sandbox) y wallet
-- ===========================================================================
create or replace function core.create_purchase(
  p_workspace_id uuid, p_user_id uuid, p_units integer, p_amount_cents bigint, p_currency text, p_price_id text, p_idempotency_key text
) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare v_p billing.purchases%rowtype;
begin
  perform core.assert_member(p_workspace_id, p_user_id);
  if p_units is null or p_units <= 0 or p_amount_cents is null or p_amount_cents < 0 or coalesce(p_currency, '') = '' then
    raise exception 'PURCHASE_INVALID' using errcode = 'PM400';
  end if;
  if p_idempotency_key is not null then
    select * into v_p from billing.purchases where workspace_id = p_workspace_id and idempotency_key = p_idempotency_key;
    if found then
      return jsonb_build_object('purchase_id', v_p.id, 'status', v_p.status, 'units', v_p.units, 'reused', true,
                                'checkout_session_id', v_p.stripe_checkout_session_id);
    end if;
  end if;
  insert into billing.purchases (workspace_id, created_by, units, amount_cents, currency, stripe_price_id, idempotency_key)
  values (p_workspace_id, p_user_id, p_units, p_amount_cents, upper(p_currency), p_price_id, p_idempotency_key)
  returning * into v_p;
  return jsonb_build_object('purchase_id', v_p.id, 'status', v_p.status, 'units', v_p.units, 'reused', false, 'checkout_session_id', null);
end $$;

create or replace function core.attach_checkout_session(
  p_purchase_id uuid, p_workspace_id uuid, p_session_id text, p_customer_id text, p_livemode boolean
) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare v_p billing.purchases%rowtype;
begin
  select * into v_p from billing.purchases where id = p_purchase_id and workspace_id = p_workspace_id for update;
  if not found then raise exception 'PURCHASE_NOT_FOUND' using errcode = 'PM404'; end if;
  if v_p.stripe_checkout_session_id is not null then
    if v_p.stripe_checkout_session_id = p_session_id then return jsonb_build_object('ok', true, 'reused', true); end if;
    raise exception 'PURCHASE_SESSION_CONFLICT' using errcode = 'PM409';
  end if;
  if v_p.status <> 'pending' then raise exception 'PURCHASE_NOT_PENDING' using errcode = 'PM409', detail = v_p.status; end if;
  update billing.purchases set stripe_checkout_session_id = p_session_id, stripe_customer_id = p_customer_id, livemode = coalesce(p_livemode, false)
   where id = p_purchase_id;
  return jsonb_build_object('ok', true, 'reused', false);
end $$;

create or replace function core.record_stripe_event(p_event_id text, p_type text, p_livemode boolean, p_object_id text, p_payload jsonb)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare v_inserted boolean := false;
begin
  if coalesce(p_event_id, '') = '' or coalesce(p_type, '') = '' then raise exception 'STRIPE_EVENT_INVALID' using errcode = 'PM400'; end if;
  insert into billing.stripe_events (event_id, type, livemode, object_id, payload)
  values (p_event_id, p_type, coalesce(p_livemode, false), p_object_id, coalesce(p_payload, '{}'::jsonb))
  on conflict (event_id) do nothing;
  get diagnostics v_inserted = row_count;
  return jsonb_build_object('event_id', p_event_id, 'new', v_inserted);
end $$;

create or replace function core.mark_stripe_event(p_event_id text, p_status text, p_error text default null)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  if p_status not in ('processed','ignored','failed') then raise exception 'STRIPE_EVENT_STATUS_INVALID' using errcode = 'PM400'; end if;
  update billing.stripe_events set status = p_status, error = p_error, processed_at = now() where event_id = p_event_id;
end $$;

-- El backend ya validó contra Stripe cuenta/modo, sesión, Customer, precio, cantidad, moneda, total y pago.
-- Aquí se exige coincidencia con la compra registrada y se concede el crédito una sola vez.
create or replace function core.fulfill_purchase(
  p_purchase_id uuid, p_session_id text, p_payment_intent_id text, p_amount_cents bigint, p_currency text, p_units integer, p_livemode boolean
) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare v_p billing.purchases%rowtype; v_granted boolean := false;
begin
  select * into v_p from billing.purchases where id = p_purchase_id for update;
  if not found then raise exception 'PURCHASE_NOT_FOUND' using errcode = 'PM404'; end if;
  if v_p.stripe_checkout_session_id is null or v_p.stripe_checkout_session_id <> p_session_id then
    raise exception 'PURCHASE_SESSION_MISMATCH' using errcode = 'PM409';
  end if;
  if v_p.amount_cents <> p_amount_cents or v_p.currency <> upper(p_currency) or v_p.units <> p_units or v_p.livemode <> coalesce(p_livemode, false) then
    raise exception 'PURCHASE_TERMS_MISMATCH' using errcode = 'PM409',
      detail = format('stored %s %s x%s livemode=%s', v_p.amount_cents, v_p.currency, v_p.units, v_p.livemode);
  end if;
  if v_p.status = 'fulfilled' then
    return jsonb_build_object('purchase_id', v_p.id, 'granted', false, 'reason', 'already_fulfilled', 'units', v_p.units);
  end if;
  if v_p.status in ('expired','failed') then raise exception 'PURCHASE_NOT_PAYABLE' using errcode = 'PM409', detail = v_p.status; end if;

  perform 1 from billing.wallets where workspace_id = v_p.workspace_id for update;
  insert into billing.credit_entries (workspace_id, kind, delta_available, delta_reserved, reference_kind, reference_id, note)
  values (v_p.workspace_id, 'purchase_grant', v_p.units, 0, 'purchase', v_p.id::text, p_payment_intent_id)
  on conflict (workspace_id, kind, reference_kind, reference_id) do nothing;
  get diagnostics v_granted = row_count;
  if v_granted then
    update billing.wallets set available_units = available_units + v_p.units, updated_at = now() where workspace_id = v_p.workspace_id;
  end if;
  update billing.purchases set status = 'fulfilled', stripe_payment_intent_id = coalesce(stripe_payment_intent_id, p_payment_intent_id), fulfilled_at = now()
   where id = p_purchase_id;
  return jsonb_build_object('purchase_id', v_p.id, 'granted', v_granted, 'units', v_p.units);
end $$;

create or replace function core.read_wallet(p_workspace_id uuid, p_user_id uuid)
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare v_w billing.wallets%rowtype; v_entries jsonb;
begin
  perform core.assert_member(p_workspace_id, p_user_id);
  select * into v_w from billing.wallets where workspace_id = p_workspace_id;
  select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'delta_available', delta_available, 'delta_reserved', delta_reserved,
                                               'reference_kind', reference_kind, 'reference_id', reference_id, 'created_at', created_at)
                            order by created_at desc), '[]'::jsonb)
    into v_entries
    from (select * from billing.credit_entries where workspace_id = p_workspace_id order by created_at desc limit 50) e;
  return jsonb_build_object('available_units', coalesce(v_w.available_units, 0), 'reserved_units', coalesce(v_w.reserved_units, 0), 'entries', v_entries);
end $$;

-- ===========================================================================
-- Retención: purga de un payload privado por una función específica con auditoría. Sin grant a roles de
-- conexión en P0: solo administración (postgres). El digest y el marcador de purga se conservan.
-- ===========================================================================
create or replace function core.purge_payload(p_payload_id uuid, p_reason text, p_actor_user_id uuid default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare v_p core.payloads%rowtype;
begin
  select * into v_p from core.payloads where id = p_payload_id for update;
  if not found then raise exception 'PAYLOAD_NOT_FOUND' using errcode = 'PM404'; end if;
  if v_p.purged_at is not null then return jsonb_build_object('payload_id', v_p.id, 'purged', false, 'reason', 'already_purged'); end if;
  update core.payloads set content = null, blob = null, purged_at = now(), purge_reason = coalesce(p_reason, 'retention') where id = p_payload_id;
  insert into core.access_log (workspace_id, actor_user_id, actor_kind, action, resource_type, resource_id, detail)
  values (v_p.workspace_id, p_actor_user_id, case when p_actor_user_id is null then 'cron' else 'admin' end, 'purge_payload', 'payload', v_p.id,
          jsonb_build_object('owner_kind', v_p.owner_kind, 'owner_id', v_p.owner_id, 'reason', coalesce(p_reason, 'retention')));
  return jsonb_build_object('payload_id', v_p.id, 'purged', true, 'digest', encode(v_p.digest, 'hex'));
end $$;

-- ===========================================================================
-- Allowlist de ejecución
-- ===========================================================================
revoke execute on all functions in schema core from public, anon, authenticated;

grant execute on function
  core.register_domain_pack, core.create_project, core.create_agent_version, core.create_case_version,
  core.quote_run, core.create_run, core.cancel_run,
  core.create_purchase, core.attach_checkout_session, core.record_stripe_event, core.mark_stripe_event,
  core.fulfill_purchase, core.read_wallet
to premortem_api;

grant execute on function
  core.dequeue_jobs, core.extend_visibility, core.archive_message,
  core.claim_job, core.recover_job, core.heartbeat_job, core.read_job_inputs, core.read_attempt_context,
  core.commit_transition, core.finish_attempt
to premortem_worker;

-- Retención: solo administración. Ningún rol de conexión de la aplicación puede purgar.
grant execute on function core.purge_payload to postgres;

-- ===========================================================================
-- Propiedad: las funciones del motor pasan a premortem_owner. SECURITY DEFINER se ejecuta con sus privilegios
-- (DML concedido en 0007); los grants anteriores se conservan. El rol de migración mantiene SET sobre
-- premortem_owner (0001) para poder transferir.
-- ===========================================================================
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'core'
       and p.proname in ('sha256_json','hex32','assert_member','store_payload','register_domain_pack','create_project',
                         'create_agent_version','create_case_version','prepare_run','quote_run','create_run',
                         'resolve_reservation','bump_run_progress','lock_job_context','append_events',
                         'dequeue_jobs','extend_visibility','archive_message','claim_job','recover_job','heartbeat_job',
                         'read_job_inputs','read_attempt_context','commit_transition','finish_attempt','cancel_run',
                         'create_purchase','attach_checkout_session','record_stripe_event','mark_stripe_event',
                         'fulfill_purchase','read_wallet')   -- purge_payload queda en el rol de administración
  loop
    execute format('alter function %s owner to premortem_owner', r.sig);
  end loop;
end $$;
