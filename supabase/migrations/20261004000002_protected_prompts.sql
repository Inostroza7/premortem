-- PREMORTEM v2 · 0011 · Prompts protegidos (spec v2 §13).
-- La aplicación cifra el prompt con una DEK por workspace (AES-256-GCM) envuelta con la KEK, que vive fuera
-- de la base. Aquí solo se guardan la DEK envuelta y el blob. Nuevas funciones:
--   core.ensure_data_key   (API)    devuelve la DEK activa del workspace o registra la propuesta
--   core.read_agent_prompt (API)    devuelve el blob y la DEK envuelta a un miembro, con auditoría
--   core.read_job_inputs   (worker) incluye la DEK envuelta del prompt del agente del job

grant premortem_owner to postgres with inherit true;

create or replace function core.ensure_data_key(p_workspace_id uuid, p_user_id uuid, p_kek_id text, p_wrapped_dek bytea)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare v_k core.data_keys%rowtype; v_created boolean := false;
begin
  perform core.assert_member(p_workspace_id, p_user_id);
  if coalesce(p_kek_id, '') = '' or p_wrapped_dek is null or octet_length(p_wrapped_dek) < 44 then
    raise exception 'DATA_KEY_INVALID' using errcode = 'PM400';
  end if;
  perform 1 from public.workspaces where id = p_workspace_id for update;   -- serializa la creación por workspace
  select * into v_k from core.data_keys where workspace_id = p_workspace_id and status = 'active';
  if not found then
    insert into core.data_keys (workspace_id, kek_id, wrapped_dek) values (p_workspace_id, p_kek_id, p_wrapped_dek) returning * into v_k;
    v_created := true;
    insert into core.access_log (workspace_id, actor_user_id, actor_kind, action, resource_type, resource_id)
    values (p_workspace_id, p_user_id, 'api', 'create_data_key', 'data_key', v_k.id);
  end if;
  return jsonb_build_object('key_id', v_k.id, 'kek_id', v_k.kek_id, 'wrapped_dek', encode(v_k.wrapped_dek, 'base64'), 'created', v_created);
end $$;

create or replace function core.read_agent_prompt(p_agent_version_id uuid, p_workspace_id uuid, p_user_id uuid, p_purpose text)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare v_a public.agent_versions%rowtype; v_pl core.payloads%rowtype; v_k core.data_keys%rowtype;
begin
  perform core.assert_member(p_workspace_id, p_user_id);
  select * into v_a from public.agent_versions where id = p_agent_version_id and workspace_id = p_workspace_id;
  if not found then raise exception 'AGENT_VERSION_NOT_FOUND' using errcode = 'PM404'; end if;
  if v_a.prompt_payload_id is null then return jsonb_build_object('agent_version_id', v_a.id, 'prompt', null); end if;
  select * into v_pl from core.payloads where id = v_a.prompt_payload_id and workspace_id = p_workspace_id;
  select * into v_k from core.data_keys where id = v_pl.key_id and workspace_id = p_workspace_id;
  insert into core.access_log (workspace_id, actor_user_id, actor_kind, action, resource_type, resource_id, detail)
  values (p_workspace_id, p_user_id, 'user', 'decrypt_prompt', 'agent_version', v_a.id, jsonb_build_object('purpose', coalesce(p_purpose, 'view')));
  return jsonb_build_object('agent_version_id', v_a.id, 'prompt', jsonb_build_object(
    'payload_id', v_pl.id, 'encrypted', v_pl.encrypted, 'content', v_pl.content,
    'blob_b64', case when v_pl.blob is null then null else encode(v_pl.blob, 'base64') end,
    'key_id', v_pl.key_id, 'kek_id', v_k.kek_id,
    'wrapped_dek', case when v_k.wrapped_dek is null then null else encode(v_k.wrapped_dek, 'base64') end,
    'purged', v_pl.purged_at is not null));
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
                                   'key_id', v_pl.key_id, 'digest', encode(v_pl.digest, 'hex'), 'purged', v_pl.purged_at is not null,
                                   'wrapped_dek', (select encode(k.wrapped_dek, 'base64') from core.data_keys k where k.id = v_pl.key_id and k.workspace_id = v_job.workspace_id),
                                   'kek_id', (select k.kek_id from core.data_keys k where k.id = v_pl.key_id and k.workspace_id = v_job.workspace_id));
    insert into core.access_log (workspace_id, actor_kind, action, resource_type, resource_id, detail)
    values (v_job.workspace_id, 'worker', 'read_prompt', 'agent_version', v_agent.id,
            jsonb_build_object('job_id', v_job.id, 'attempt_id', v_att.id, 'worker', p_worker));
  end if;
  return jsonb_build_object(
    'workspace_id', v_job.workspace_id, 'project_id', v_run.project_id,
    'run',   jsonb_build_object('id', v_run.id, 'kind', v_run.kind, 'manifest', v_run.manifest, 'limits', v_run.limits, 'seed', v_run.seed),
    'job',   jsonb_build_object('id', v_job.id, 'ordinal', v_job.ordinal, 'scenario_id', v_job.scenario_id, 'repetition', v_job.repetition,
                                'mutations', v_job.mutations, 'seed', v_job.seed, 'attempt_id', v_att.id, 'attempt_number', v_att.attempt_number),
    'case',  jsonb_build_object('id', v_case.id, 'fixture_version', v_case.fixture_version, 'task', v_case.task,
                                'public_context', v_case.public_context, 'fixture', v_cp.fixture, 'oracle', v_cp.oracle),
    'agent', jsonb_build_object('id', v_agent.id, 'driver', v_agent.driver, 'driver_version', v_agent.driver_version,
                                'policy_id', v_agent.policy_id, 'model_id', v_agent.model_id, 'config', v_agent.config, 'prompt', v_prompt),
    'cancel_requested', v_cancel);
end $$;

alter function core.ensure_data_key(uuid, uuid, text, bytea) owner to premortem_owner;
alter function core.read_agent_prompt(uuid, uuid, uuid, text) owner to premortem_owner;
alter function core.read_job_inputs(uuid, uuid, text, integer) owner to premortem_owner;
revoke execute on function core.ensure_data_key(uuid, uuid, text, bytea), core.read_agent_prompt(uuid, uuid, uuid, text)
  from public, anon, authenticated;
grant execute on function core.ensure_data_key(uuid, uuid, text, bytea), core.read_agent_prompt(uuid, uuid, uuid, text) to premortem_api;

grant premortem_owner to postgres with inherit false;
