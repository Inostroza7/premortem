-- PREMORTEM v2 · 0010 · Protocolo del worker.
-- 1. El worker preasigna el UUID del intento: el evento génesis incluye attempt_id en su envelope y se firma
--    antes de llamar a claim_job/recover_job.
-- 2. dequeue_jobs devuelve workspace_id (también parte del envelope).
-- 3. read_job_inputs devuelve workspace_id y project_id.

-- Las funciones del motor pertenecen a premortem_owner. Para reemplazarlas, el rol de migración hereda
-- temporalmente sus privilegios y los vuelve a soltar al final (sin SET ROLE: la CLI registra en esta sesión).
grant premortem_owner to postgres with inherit true;

drop function if exists core.dequeue_jobs(text, integer, integer);
create function core.dequeue_jobs(p_worker text, p_max integer default 1, p_visibility_seconds integer default 60)
returns table (msg_id bigint, job_id uuid, run_id uuid, workspace_id uuid, read_ct integer)
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
  returning q.msg_id, q.job_id, q.run_id, q.workspace_id, q.read_ct;
end $$;

drop function if exists core.claim_job(uuid, text, integer, jsonb, jsonb, jsonb);
create function core.claim_job(
  p_job_id uuid, p_attempt_id uuid, p_worker text, p_ttl_seconds integer, p_domain_state jsonb, p_injection_state jsonb, p_genesis_event jsonb
) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_ws_id uuid; v_run_id uuid; v_ws public.workspaces%rowtype; v_ctl core.run_controls%rowtype; v_job public.world_jobs%rowtype;
  v_running integer; v_att public.world_attempts%rowtype; v_epoch integer; v_until timestamptz; v_ev jsonb;
begin
  if p_worker is null or length(p_worker) = 0 then raise exception 'WORKER_ID_REQUIRED' using errcode = 'PM400'; end if;
  if p_attempt_id is null then raise exception 'ATTEMPT_ID_REQUIRED' using errcode = 'PM400'; end if;
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
  insert into public.world_attempts (id, job_id, run_id, workspace_id, attempt_number)
  values (p_attempt_id, p_job_id, v_run_id, v_ws_id, 1) returning * into v_att;
  insert into core.attempt_states (attempt_id, workspace_id, domain_state, injection_state)
  values (v_att.id, v_ws_id, p_domain_state, coalesce(p_injection_state, '{}'::jsonb));
  update public.world_jobs
     set status = 'running', lease_owner = p_worker, lease_epoch = v_epoch, lease_until = v_until,
         active_attempt_id = v_att.id, started_at = coalesce(started_at, now())
   where id = p_job_id;
  v_ev := core.append_events(v_att, jsonb_build_array(p_genesis_event));
  update public.runs set status = 'running', started_at = coalesce(started_at, now()) where id = v_run_id and status = 'queued';

  return jsonb_build_object('claimed', true, 'attempt_id', v_att.id, 'workspace_id', v_ws_id, 'run_id', v_run_id, 'attempt_number', 1, 'lease_epoch', v_epoch,
                            'lease_until', v_until, 'state_version', 0, 'next_seq', 2, 'last_hash', v_ev->>'last_hash');
end $$;

drop function if exists core.recover_job(uuid, text, integer, jsonb, jsonb, jsonb);
create function core.recover_job(
  p_job_id uuid, p_attempt_id uuid, p_worker text, p_ttl_seconds integer, p_domain_state jsonb, p_injection_state jsonb, p_genesis_event jsonb
) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_ws_id uuid; v_run_id uuid; v_ctl core.run_controls%rowtype; v_job public.world_jobs%rowtype;
  v_att public.world_attempts%rowtype; v_epoch integer; v_until timestamptz; v_ev jsonb; v_n integer;
begin
  if p_worker is null or length(p_worker) = 0 then raise exception 'WORKER_ID_REQUIRED' using errcode = 'PM400'; end if;
  if p_attempt_id is null then raise exception 'ATTEMPT_ID_REQUIRED' using errcode = 'PM400'; end if;
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
  insert into public.world_attempts (id, job_id, run_id, workspace_id, attempt_number)
  values (p_attempt_id, p_job_id, v_run_id, v_ws_id, v_n) returning * into v_att;
  insert into core.attempt_states (attempt_id, workspace_id, domain_state, injection_state)
  values (v_att.id, v_ws_id, p_domain_state, coalesce(p_injection_state, '{}'::jsonb));
  update public.world_jobs
     set lease_owner = p_worker, lease_epoch = v_epoch, lease_until = v_until,
         active_attempt_id = v_att.id, recovery_count = recovery_count + 1
   where id = p_job_id;
  v_ev := core.append_events(v_att, jsonb_build_array(p_genesis_event));

  return jsonb_build_object('recovered', true, 'attempt_id', v_att.id, 'workspace_id', v_ws_id, 'run_id', v_run_id, 'attempt_number', v_n, 'lease_epoch', v_epoch,
                            'lease_until', v_until, 'state_version', 0, 'next_seq', 2, 'last_hash', v_ev->>'last_hash');
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

alter function core.dequeue_jobs(text, integer, integer) owner to premortem_owner;
alter function core.claim_job(uuid, uuid, text, integer, jsonb, jsonb, jsonb) owner to premortem_owner;
alter function core.recover_job(uuid, uuid, text, integer, jsonb, jsonb, jsonb) owner to premortem_owner;
alter function core.read_job_inputs(uuid, uuid, text, integer) owner to premortem_owner;

revoke execute on function
  core.dequeue_jobs(text, integer, integer),
  core.claim_job(uuid, uuid, text, integer, jsonb, jsonb, jsonb),
  core.recover_job(uuid, uuid, text, integer, jsonb, jsonb, jsonb)
from public, anon, authenticated;
grant execute on function
  core.dequeue_jobs(text, integer, integer),
  core.claim_job(uuid, uuid, text, integer, jsonb, jsonb, jsonb),
  core.recover_job(uuid, uuid, text, integer, jsonb, jsonb, jsonb)
to premortem_worker;

grant premortem_owner to postgres with inherit false;
