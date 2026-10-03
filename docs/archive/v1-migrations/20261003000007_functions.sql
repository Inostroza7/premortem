-- PREMORTEM · 0007 · Funciones genéricas del motor. Independientes del dominio.
-- El worker (TypeScript) conoce el dominio: construye el estado, valida argumentos, decide qué
-- efecto y qué parche aplicar. Postgres garantiza: lease, orden de eventos, idempotencia,
-- permiso atómico con la escritura, cadena de hashes y concurrencia optimista del estado.
--
-- Códigos de error (SQLSTATE propios): PM400 argumento inválido · PM403 sin permiso ·
-- PM404 no encontrado · PM409 conflicto/estado · PM423 lease inválido.

-- ---------------------------------------------------------------------------
-- Utilidades
-- ---------------------------------------------------------------------------
create or replace function core.sha256_json(p jsonb)
returns bytea
language sql immutable
set search_path = ''
as $$
  -- jsonb serializa con claves ordenadas: el hash es canónico aunque cambie el orden de entrada
  select extensions.digest(convert_to(coalesce(p, '{}'::jsonb)::text, 'utf8'), 'sha256');
$$;

create or replace function core.assert_member(p_workspace_id uuid, p_user_id uuid)
returns void
language plpgsql stable
set search_path = ''
as $$
begin
  if p_workspace_id is null or p_user_id is null then
    raise exception 'WORKSPACE_AND_USER_REQUIRED' using errcode = 'PM400';
  end if;
  if not exists (select 1 from public.workspace_members
                  where workspace_id = p_workspace_id and user_id = p_user_id) then
    raise exception 'NOT_A_MEMBER' using errcode = 'PM403';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Crear run: valida pertenencia y catálogo, congela snapshot, crea mundos y encola. Idempotente.
-- p_worlds: [{ "scenario_id": "...", "mutations": [...] }, ...] en orden de ejecución.
-- ---------------------------------------------------------------------------
create or replace function core.create_run(
  p_workspace_id      uuid,
  p_user_id           uuid,
  p_task_id           uuid,
  p_agent_version_id  uuid,
  p_worlds            jsonb,
  p_seed              integer,
  p_suite_version     text,
  p_simulator_version text,
  p_kind              text    default 'evaluation',
  p_idempotency_key   text    default null,
  p_request_body      jsonb   default null,
  p_parent_run_id     uuid    default null,
  p_reduction_config  jsonb   default null
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_task      public.tasks%rowtype;
  v_agent     public.agent_versions%rowtype;
  v_domain    public.domains%rowtype;
  v_existing  public.runs%rowtype;
  v_run_id    uuid;
  v_req_hash  bytea;
  v_snapshot  jsonb;
  v_world     jsonb;
  v_i         integer := 0;
begin
  perform core.assert_member(p_workspace_id, p_user_id);

  select * into v_task from public.tasks where id = p_task_id and workspace_id = p_workspace_id;
  if not found then raise exception 'TASK_NOT_FOUND' using errcode = 'PM404'; end if;

  select * into v_agent from public.agent_versions where id = p_agent_version_id and workspace_id = p_workspace_id;
  if not found then raise exception 'AGENT_VERSION_NOT_FOUND' using errcode = 'PM404'; end if;

  select * into v_domain from public.domains where id = v_task.domain_id;
  if not found then raise exception 'DOMAIN_NOT_FOUND' using errcode = 'PM404'; end if;

  if p_kind not in ('evaluation','reduction') then
    raise exception 'KIND_INVALID' using errcode = 'PM400';
  end if;
  if p_worlds is null or jsonb_typeof(p_worlds) <> 'array' or jsonb_array_length(p_worlds) = 0 then
    raise exception 'WORLDS_REQUIRED' using errcode = 'PM400';
  end if;
  if jsonb_array_length(p_worlds) > 32 then
    raise exception 'TOO_MANY_WORLDS' using errcode = 'PM400';
  end if;

  -- En evaluación, los escenarios deben existir en el catálogo del dominio.
  for v_world in select * from jsonb_array_elements(p_worlds) loop
    if coalesce(v_world->>'scenario_id', '') = '' then
      raise exception 'SCENARIO_ID_REQUIRED' using errcode = 'PM400';
    end if;
    if p_kind = 'evaluation' and not (v_domain.scenarios ? (v_world->>'scenario_id')) then
      raise exception 'SCENARIO_NOT_IN_DOMAIN' using errcode = 'PM400', detail = v_world->>'scenario_id';
    end if;
    if v_world ? 'mutations' and jsonb_typeof(v_world->'mutations') <> 'array' then
      raise exception 'MUTATIONS_MUST_BE_ARRAY' using errcode = 'PM400';
    end if;
  end loop;

  -- Idempotencia de la petición (misma clave + mismo cuerpo = mismo run; cuerpo distinto = conflicto)
  if p_idempotency_key is not null then
    v_req_hash := core.sha256_json(coalesce(p_request_body, '{}'::jsonb));
    select * into v_existing from public.runs
     where workspace_id = p_workspace_id and idempotency_key = p_idempotency_key;
    if found then
      if v_existing.request_hash = v_req_hash then
        return jsonb_build_object('run_id', v_existing.id, 'status', v_existing.status, 'reused', true);
      end if;
      raise exception 'IDEMPOTENCY_CONFLICT' using errcode = 'PM409';
    end if;
  end if;

  v_snapshot := jsonb_build_object(
    'domain',        jsonb_build_object('id', v_domain.id, 'version', v_domain.version),
    'task',          jsonb_build_object('id', v_task.id, 'content_hash', encode(v_task.content_hash, 'hex'),
                                        'fixture_version', v_task.fixture_version,
                                        'public_task', v_task.public_task, 'trusted_context', v_task.trusted_context),
    'agent_version', jsonb_build_object('id', v_agent.id, 'mode', v_agent.mode,
                                        'reference_policy', v_agent.reference_policy, 'model_id', v_agent.model_id,
                                        'config', v_agent.config, 'content_hash', encode(v_agent.content_hash, 'hex')),
    'worlds',        p_worlds,
    'seed',          p_seed,
    'suite_version', p_suite_version,
    'simulator_version', p_simulator_version
  );

  insert into public.runs (workspace_id, created_by, kind, domain_id, task_id, agent_version_id,
                           suite_version, simulator_version, seed, input_snapshot, input_hash,
                           parent_run_id, reduction_config, idempotency_key, request_hash)
  values (p_workspace_id, p_user_id, p_kind, v_domain.id, p_task_id, p_agent_version_id,
          p_suite_version, p_simulator_version, p_seed, v_snapshot, core.sha256_json(v_snapshot),
          p_parent_run_id, p_reduction_config, p_idempotency_key, v_req_hash)
  on conflict (workspace_id, idempotency_key) do nothing
  returning id into v_run_id;

  if v_run_id is null then
    -- Carrera: otra petición con la misma clave insertó primero.
    select * into v_existing from public.runs
     where workspace_id = p_workspace_id and idempotency_key = p_idempotency_key;
    if v_existing.request_hash = v_req_hash then
      return jsonb_build_object('run_id', v_existing.id, 'status', v_existing.status, 'reused', true);
    end if;
    raise exception 'IDEMPOTENCY_CONFLICT' using errcode = 'PM409';
  end if;

  for v_world in select * from jsonb_array_elements(p_worlds) loop
    insert into public.worlds (run_id, workspace_id, position, scenario_id, mutations, seed)
    values (v_run_id, p_workspace_id, v_i, v_world->>'scenario_id',
            coalesce(v_world->'mutations', '[]'::jsonb), p_seed + v_i);
    v_i := v_i + 1;
  end loop;

  perform pgmq.send('premortem_jobs', jsonb_build_object('run_id', v_run_id, 'kind', p_kind));

  return jsonb_build_object('run_id', v_run_id, 'status', 'queued', 'reused', false);
end $$;

-- ---------------------------------------------------------------------------
-- Lease del worker sobre un run
-- ---------------------------------------------------------------------------
create or replace function core.acquire_lease(p_run_id uuid, p_ttl_seconds integer default 60)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_run public.runs%rowtype; v_token uuid; v_until timestamptz;
begin
  select * into v_run from public.runs where id = p_run_id for update;
  if not found then raise exception 'RUN_NOT_FOUND' using errcode = 'PM404'; end if;
  if v_run.status in ('completed','errored','cancelled') then
    return jsonb_build_object('acquired', false, 'reason', 'terminal', 'status', v_run.status);
  end if;
  if v_run.status = 'running' and v_run.lease_until is not null and v_run.lease_until > now() then
    return jsonb_build_object('acquired', false, 'reason', 'held', 'lease_until', v_run.lease_until);
  end if;
  v_token := gen_random_uuid();
  v_until := now() + make_interval(secs => greatest(p_ttl_seconds, 5));
  update public.runs
     set status = 'running', lease_token = v_token, lease_until = v_until,
         started_at = coalesce(started_at, now())
   where id = p_run_id;
  return jsonb_build_object('acquired', true, 'lease_token', v_token, 'lease_until', v_until,
                            'recovered', v_run.status = 'running');
end $$;

create or replace function core.renew_lease(p_run_id uuid, p_lease_token uuid, p_ttl_seconds integer default 60)
returns boolean
language plpgsql
set search_path = ''
as $$
declare v_ok boolean;
begin
  update public.runs
     set lease_until = now() + make_interval(secs => greatest(p_ttl_seconds, 5))
   where id = p_run_id and status = 'running' and lease_token = p_lease_token
  returning true into v_ok;
  return coalesce(v_ok, false);
end $$;

-- Bloquea la fila del run y comprueba lease vigente. Toda escritura del worker empieza aquí.
create or replace function core.assert_lease(p_run_id uuid, p_lease_token uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare v_run public.runs%rowtype;
begin
  select * into v_run from public.runs where id = p_run_id for update;
  if not found then raise exception 'RUN_NOT_FOUND' using errcode = 'PM404'; end if;
  if v_run.status <> 'running' then
    raise exception 'RUN_NOT_RUNNING' using errcode = 'PM423', detail = v_run.status;
  end if;
  if v_run.lease_token is distinct from p_lease_token or v_run.lease_until is null or v_run.lease_until <= now() then
    raise exception 'LEASE_INVALID' using errcode = 'PM423';
  end if;
end $$;

-- Bloquea el intento y verifica que pertenece al run y está activo.
create or replace function core.lock_active_attempt(p_run_id uuid, p_attempt_id uuid)
returns public.world_attempts
language plpgsql
set search_path = ''
as $$
declare v_att public.world_attempts%rowtype;
begin
  select a.* into v_att
    from public.world_attempts a
    join public.worlds w on w.id = a.world_id
   where a.id = p_attempt_id and w.run_id = p_run_id
   for update of a;
  if not found then raise exception 'ATTEMPT_NOT_FOUND' using errcode = 'PM404'; end if;
  if v_att.status <> 'running' then raise exception 'ATTEMPT_NOT_ACTIVE' using errcode = 'PM409'; end if;
  return v_att;
end $$;

-- ---------------------------------------------------------------------------
-- Intentos
-- ---------------------------------------------------------------------------
create or replace function core.start_attempt(p_run_id uuid, p_lease_token uuid, p_world_id uuid, p_state jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_world public.worlds%rowtype; v_n integer; v_id uuid;
begin
  perform core.assert_lease(p_run_id, p_lease_token);
  select * into v_world from public.worlds where id = p_world_id and run_id = p_run_id for update;
  if not found then raise exception 'WORLD_NOT_FOUND' using errcode = 'PM404'; end if;
  if v_world.status in ('completed','cancelled') then
    raise exception 'WORLD_ALREADY_TERMINAL' using errcode = 'PM409', detail = v_world.status;
  end if;
  if p_state is null or jsonb_typeof(p_state) <> 'object' then
    raise exception 'STATE_MUST_BE_OBJECT' using errcode = 'PM400';
  end if;

  -- Un intento interrumpido queda como evidencia; nunca se reanuda.
  update public.world_attempts set status = 'aborted', ended_at = now()
   where world_id = p_world_id and status = 'running';

  select coalesce(max(attempt_number), 0) + 1 into v_n from public.world_attempts where world_id = p_world_id;
  insert into public.world_attempts (world_id, workspace_id, attempt_number, state)
  values (p_world_id, v_world.workspace_id, v_n, p_state)
  returning id into v_id;

  update public.worlds set active_attempt_id = v_id, status = 'running' where id = p_world_id;
  return jsonb_build_object('attempt_id', v_id, 'attempt_number', v_n, 'state_version', 0);
end $$;

-- Inserta un evento con secuencia y hash encadenado. Uso interno (el llamador ya validó lease).
create or replace function core.append_event(
  p_attempt_id uuid, p_type text, p_visible boolean,
  p_payload jsonb default '{}'::jsonb, p_payload_enc bytea default null
) returns integer
language plpgsql
set search_path = ''
as $$
declare v_att public.world_attempts%rowtype; v_seq integer; v_prev bytea; v_enc_hash bytea; v_hash bytea;
begin
  update public.world_attempts set next_seq = next_seq + 1
   where id = p_attempt_id and status = 'running'
  returning * into v_att;
  if not found then raise exception 'ATTEMPT_NOT_ACTIVE' using errcode = 'PM409'; end if;
  v_seq := v_att.next_seq;

  select event_hash into v_prev from public.events where attempt_id = p_attempt_id and seq = v_seq - 1;
  if p_payload_enc is not null then
    v_enc_hash := extensions.digest(p_payload_enc, 'sha256');
  end if;
  v_hash := extensions.digest(
      coalesce(v_prev, '\x'::bytea)
      || convert_to(p_attempt_id::text || ':' || v_seq::text || ':' || p_type || ':' || p_visible::text
                    || ':' || coalesce(p_payload, '{}'::jsonb)::text, 'utf8')
      || coalesce(v_enc_hash, '\x'::bytea),
      'sha256');

  insert into public.events (attempt_id, world_id, workspace_id, seq, type, visible_to_agent,
                             payload, payload_enc, payload_enc_hash, prev_hash, event_hash)
  values (p_attempt_id, v_att.world_id, v_att.workspace_id, v_seq, p_type, p_visible,
          coalesce(p_payload, '{}'::jsonb), p_payload_enc, v_enc_hash, v_prev, v_hash);
  return v_seq;
end $$;

-- Registro de eventos desde el worker (mensajes del modelo, llamadas de solo lectura, notas del gateway).
create or replace function core.log_event(
  p_run_id uuid, p_lease_token uuid, p_attempt_id uuid,
  p_type text, p_visible boolean, p_payload jsonb default '{}'::jsonb, p_payload_enc bytea default null
) returns integer
language plpgsql
set search_path = ''
as $$
begin
  perform core.assert_lease(p_run_id, p_lease_token);
  perform core.lock_active_attempt(p_run_id, p_attempt_id);
  return core.append_event(p_attempt_id, p_type, p_visible, p_payload, p_payload_enc);
end $$;

-- Aplica una lista de parches al estado: [{ "path": ["orders","ord_1","x"], "value": <jsonb> }, ...]
create or replace function core.apply_patch(p_state jsonb, p_patch jsonb)
returns jsonb
language plpgsql immutable
set search_path = ''
as $$
declare v_item jsonb; v_path text[]; v_state jsonb := p_state;
begin
  if p_patch is null then return v_state; end if;
  if jsonb_typeof(p_patch) <> 'array' then
    raise exception 'PATCH_MUST_BE_ARRAY' using errcode = 'PM400';
  end if;
  for v_item in select * from jsonb_array_elements(p_patch) loop
    select array_agg(x) into v_path from jsonb_array_elements_text(v_item->'path') as t(x);
    if v_path is null or cardinality(v_path) = 0 then
      raise exception 'PATCH_PATH_REQUIRED' using errcode = 'PM400';
    end if;
    v_state := jsonb_set(v_state, v_path, coalesce(v_item->'value', 'null'::jsonb), true);
  end loop;
  return v_state;
end $$;

-- Mutación de estado sin efecto económico (p. ej. una perturbación aplicada a mitad de ejecución).
create or replace function core.patch_state(
  p_run_id uuid, p_lease_token uuid, p_attempt_id uuid,
  p_patch jsonb, p_expected_version integer,
  p_event_type text default 'world.mutation_applied', p_event_payload jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_att public.world_attempts; v_state jsonb; v_seq integer;
begin
  perform core.assert_lease(p_run_id, p_lease_token);
  v_att := core.lock_active_attempt(p_run_id, p_attempt_id);
  if p_expected_version is not null and p_expected_version <> v_att.state_version then
    raise exception 'STATE_STALE' using errcode = 'PM409',
      detail = format('expected %s, actual %s', p_expected_version, v_att.state_version);
  end if;
  v_state := core.apply_patch(v_att.state, p_patch);
  update public.world_attempts set state = v_state, state_version = state_version + 1 where id = p_attempt_id;
  v_seq := core.append_event(p_attempt_id, p_event_type, false, coalesce(p_event_payload, '{}'::jsonb));
  return jsonb_build_object('state_version', v_att.state_version + 1, 'seq', v_seq, 'state', v_state);
end $$;

-- ---------------------------------------------------------------------------
-- Confirmar un efecto: la única escritura "con consecuencias". Atómica.
--   p_effect: { id?, kind, target_type?, target_id?, subject_id?, amount_cents?, currency?, data? }
--   p_state_patch: parches a aplicar si el efecto se confirma
--   p_result: lo que verá el agente si todo va bien (el id del efecto se añade como effect_id)
-- Convenciones de estado que el motor interpreta de forma genérica:
--   state.permissions.{capability} = boolean
--   state.pending.revoke_capabilities_before_write = [capability, ...]
--   state.pending.drop_response_on_first_commit = boolean · state.pending.response_dropped = boolean
-- ---------------------------------------------------------------------------
create or replace function core.commit_effect(
  p_run_id uuid, p_lease_token uuid, p_attempt_id uuid,
  p_tool text, p_args jsonb, p_capability text, p_operation_key text,
  p_effect jsonb, p_state_patch jsonb, p_expected_version integer, p_result jsonb
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_att      public.world_attempts;
  v_state    jsonb;
  v_version  integer;
  v_prev     public.effects%rowtype;
  v_fp       bytea;
  v_effect_id uuid;
  v_eff_seq  integer;
  v_result   jsonb;
  v_drop     boolean := false;
  v_pending  jsonb;
  v_error    jsonb;
begin
  perform core.assert_lease(p_run_id, p_lease_token);
  v_att := core.lock_active_attempt(p_run_id, p_attempt_id);
  v_state := v_att.state;
  v_version := v_att.state_version;

  perform core.append_event(p_attempt_id, 'tool.call', true,
            jsonb_build_object('tool', p_tool, 'args', coalesce(p_args, '{}'::jsonb)));

  if p_operation_key is null or length(p_operation_key) = 0 or length(p_operation_key) > 200 then
    v_error := jsonb_build_object('ok', false, 'error', jsonb_build_object(
                 'code', 'INVALID_ARGUMENT', 'message', 'operation_key requerido (1-200 caracteres)', 'effect_status', 'none'));
    perform core.append_event(p_attempt_id, 'tool.result', true, jsonb_build_object('tool', p_tool) || v_error);
    return v_error || jsonb_build_object('drop_response', false, 'state_version', v_version);
  end if;
  if p_capability is null or length(p_capability) = 0 then
    raise exception 'CAPABILITY_REQUIRED' using errcode = 'PM400';
  end if;
  if p_effect is null or jsonb_typeof(p_effect) <> 'object' or coalesce(p_effect->>'kind', '') = '' then
    raise exception 'EFFECT_KIND_REQUIRED' using errcode = 'PM400';
  end if;

  v_fp := core.sha256_json(coalesce(p_args, '{}'::jsonb));

  -- 1. Idempotencia: misma clave y mismos argumentos → mismo resultado, sin nuevo efecto
  select * into v_prev from public.effects where attempt_id = p_attempt_id and operation_key = p_operation_key;
  if found then
    if v_prev.fingerprint = v_fp then
      v_result := jsonb_build_object('ok', true, 'replayed', true, 'data', v_prev.result);
      perform core.append_event(p_attempt_id, 'tool.result', true, jsonb_build_object('tool', p_tool) || v_result);
      return v_result || jsonb_build_object('drop_response', false, 'state_version', v_version, 'effect_id', v_prev.id);
    end if;
    v_error := jsonb_build_object('ok', false, 'error', jsonb_build_object(
                 'code', 'IDEMPOTENCY_CONFLICT', 'message', 'misma operation_key con argumentos distintos', 'effect_status', 'none'));
    perform core.append_event(p_attempt_id, 'tool.result', true, jsonb_build_object('tool', p_tool) || v_error);
    return v_error || jsonb_build_object('drop_response', false, 'state_version', v_version);
  end if;

  -- 2. Concurrencia optimista: el dominio validó contra esta versión del estado
  if p_expected_version is not null and p_expected_version <> v_version then
    raise exception 'STATE_STALE' using errcode = 'PM409',
      detail = format('expected %s, actual %s', p_expected_version, v_version);
  end if;

  -- 3. Perturbación pendiente: revocar la capacidad justo antes de la primera escritura
  v_pending := coalesce(v_state #> '{pending,revoke_capabilities_before_write}', '[]'::jsonb);
  if jsonb_typeof(v_pending) = 'array' and v_pending ? p_capability then
    v_state := jsonb_set(v_state, array['permissions', p_capability], 'false'::jsonb, true);
    v_state := jsonb_set(v_state, '{pending,revoke_capabilities_before_write}', v_pending - p_capability, true);
    v_version := v_version + 1;
    update public.world_attempts set state = v_state, state_version = v_version where id = p_attempt_id;
    perform core.append_event(p_attempt_id, 'world.mutation_applied', false,
              jsonb_build_object('mutation', 'revoke_capability', 'capability', p_capability, 'trigger', 'before_first_write'));
  end if;

  -- 4. Permiso, comprobado en la misma transacción que la escritura
  if not coalesce((v_state #>> array['permissions', p_capability])::boolean, false) then
    perform core.append_event(p_attempt_id, 'sim.denied', false,
              jsonb_build_object('tool', p_tool, 'capability', p_capability, 'args', coalesce(p_args, '{}'::jsonb)));
    v_error := jsonb_build_object('ok', false, 'error', jsonb_build_object(
                 'code', 'FORBIDDEN', 'message', 'la credencial no tiene la capacidad ' || p_capability, 'effect_status', 'none'));
    perform core.append_event(p_attempt_id, 'tool.result', true, jsonb_build_object('tool', p_tool) || v_error);
    return v_error || jsonb_build_object('drop_response', false, 'state_version', v_version);
  end if;

  -- 5. Efecto: evento oculto + ledger + parche de estado, atómicos
  v_effect_id := coalesce((p_effect->>'id')::uuid, gen_random_uuid());
  v_eff_seq := core.append_event(p_attempt_id, 'sim.effect', false,
                 jsonb_build_object('effect_id', v_effect_id, 'tool', p_tool, 'operation_key', p_operation_key)
                 || (p_effect - 'id'));
  v_result := coalesce(p_result, '{}'::jsonb) || jsonb_build_object('effect_id', v_effect_id);

  insert into public.effects (id, attempt_id, world_id, workspace_id, request_id, tool, kind,
                              target_type, target_id, subject_id, amount_cents, currency,
                              operation_key, fingerprint, capability, permission_at_commit, data, result, event_seq)
  values (v_effect_id, p_attempt_id, v_att.world_id, v_att.workspace_id,
          coalesce(v_state->>'request_id', ''), p_tool, p_effect->>'kind',
          p_effect->>'target_type', p_effect->>'target_id', p_effect->>'subject_id',
          (p_effect->>'amount_cents')::bigint, upper(p_effect->>'currency'),
          p_operation_key, v_fp, p_capability, true,
          coalesce(p_effect->'data', '{}'::jsonb), v_result, v_eff_seq);

  v_state := core.apply_patch(v_state, p_state_patch);
  v_version := v_version + 1;

  -- 6. Pérdida de respuesta tras el commit: se decide aquí, el gateway la materializa
  if coalesce((v_state #>> '{pending,drop_response_on_first_commit}')::boolean, false)
     and not coalesce((v_state #>> '{pending,response_dropped}')::boolean, false) then
    v_drop := true;
    v_state := jsonb_set(v_state, '{pending,response_dropped}', 'true'::jsonb, true);
  end if;

  update public.world_attempts set state = v_state, state_version = v_version where id = p_attempt_id;

  if v_drop then
    perform core.append_event(p_attempt_id, 'gateway.response_dropped', false,
              jsonb_build_object('effect_id', v_effect_id, 'reason', 'commit_ack_lost'));
    perform core.append_event(p_attempt_id, 'tool.result', true, jsonb_build_object('tool', p_tool,
              'ok', false, 'error', jsonb_build_object('code', 'TIMEOUT_UNKNOWN',
              'message', 'sin respuesta del proveedor', 'effect_status', 'unknown')));
  else
    perform core.append_event(p_attempt_id, 'tool.result', true,
              jsonb_build_object('tool', p_tool, 'ok', true, 'data', v_result));
  end if;

  return jsonb_build_object('ok', true, 'replayed', false, 'data', v_result,
                            'drop_response', v_drop, 'state_version', v_version, 'effect_id', v_effect_id);
end $$;

-- ---------------------------------------------------------------------------
-- Cierre de intento y de run
-- ---------------------------------------------------------------------------
create or replace function core.finish_attempt(
  p_run_id uuid, p_lease_token uuid, p_attempt_id uuid,
  p_status text,                       -- completed | errored
  p_verdict text,                      -- passed | safe_stop | failed | inconclusive
  p_safety_violation boolean,
  p_final_output jsonb,                -- salida estructurada sin texto libre (puede ser null si no hubo finish)
  p_findings jsonb,                    -- [{invariant_id, verdict, safety_violation, expected, actual, evidence_event_seqs, explanation}]
  p_usage jsonb default null,
  p_final_message text default null,   -- texto libre en claro (modo referencia)
  p_final_message_enc bytea default null -- texto libre cifrado (modo live)
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_att public.world_attempts; v_f jsonb; v_seq integer; v_n integer := 0;
begin
  perform core.assert_lease(p_run_id, p_lease_token);
  v_att := core.lock_active_attempt(p_run_id, p_attempt_id);
  if p_status not in ('completed','errored') then raise exception 'STATUS_INVALID' using errcode = 'PM400'; end if;
  if p_verdict not in ('passed','safe_stop','failed','inconclusive') then raise exception 'VERDICT_INVALID' using errcode = 'PM400'; end if;

  v_seq := core.append_event(p_attempt_id, 'attempt.finished', false,
             jsonb_build_object('status', p_status, 'verdict', p_verdict, 'safety_violation', p_safety_violation,
                                'final_output', coalesce(p_final_output, 'null'::jsonb),
                                'final_message', p_final_message),
             p_final_message_enc);

  if p_findings is not null then
    for v_f in select * from jsonb_array_elements(p_findings) loop
      insert into public.findings (attempt_id, workspace_id, invariant_id, verdict, safety_violation,
                                   expected, actual, evidence_event_seqs, explanation)
      values (p_attempt_id, v_att.workspace_id, v_f->>'invariant_id', v_f->>'verdict',
              coalesce((v_f->>'safety_violation')::boolean, false),
              coalesce(v_f->'expected', '{}'::jsonb), coalesce(v_f->'actual', '{}'::jsonb),
              coalesce((select array_agg(x::int) from jsonb_array_elements_text(coalesce(v_f->'evidence_event_seqs','[]'::jsonb)) t(x)), '{}'::int[]),
              coalesce(v_f->>'explanation', ''));
      v_n := v_n + 1;
    end loop;
  end if;

  update public.world_attempts
     set status = p_status, verdict = p_verdict, safety_violation = coalesce(p_safety_violation, false),
         final_output = p_final_output, final_message_enc = p_final_message_enc,
         usage = p_usage, ended_at = now()
   where id = p_attempt_id;
  update public.worlds set status = p_status where id = v_att.world_id;

  return jsonb_build_object('attempt_id', p_attempt_id, 'verdict', p_verdict, 'findings', v_n, 'last_seq', v_seq);
end $$;

create or replace function core.complete_run(p_run_id uuid, p_lease_token uuid, p_status text, p_result_summary jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform core.assert_lease(p_run_id, p_lease_token);
  if p_status not in ('completed','errored') then raise exception 'STATUS_INVALID' using errcode = 'PM400'; end if;
  update public.runs
     set status = p_status, result_summary = p_result_summary, lease_token = null, lease_until = null, ended_at = now()
   where id = p_run_id;
  return jsonb_build_object('run_id', p_run_id, 'status', p_status);
end $$;

-- Cancelación desde la API (usuario). El worker lo observa en su siguiente assert_lease.
create or replace function core.cancel_run(p_run_id uuid, p_workspace_id uuid, p_user_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_run public.runs%rowtype;
begin
  perform core.assert_member(p_workspace_id, p_user_id);
  select * into v_run from public.runs where id = p_run_id and workspace_id = p_workspace_id for update;
  if not found then raise exception 'RUN_NOT_FOUND' using errcode = 'PM404'; end if;
  if v_run.status in ('completed','errored','cancelled') then
    return jsonb_build_object('run_id', p_run_id, 'status', v_run.status, 'changed', false);
  end if;
  update public.runs set status = 'cancelled', ended_at = now() where id = p_run_id;
  update public.worlds set status = 'cancelled' where run_id = p_run_id and status in ('queued','running');
  return jsonb_build_object('run_id', p_run_id, 'status', 'cancelled', 'changed', true);
end $$;

-- Error de infraestructura declarado por el worker (p. ej. segunda recuperación fallida). Sin lease.
create or replace function core.mark_run_errored(p_run_id uuid, p_reason text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_run public.runs%rowtype;
begin
  select * into v_run from public.runs where id = p_run_id for update;
  if not found then raise exception 'RUN_NOT_FOUND' using errcode = 'PM404'; end if;
  if v_run.status in ('completed','errored','cancelled') then
    return jsonb_build_object('run_id', p_run_id, 'status', v_run.status, 'changed', false);
  end if;
  update public.runs
     set status = 'errored', lease_token = null, lease_until = null, ended_at = now(),
         result_summary = coalesce(result_summary, '{}'::jsonb) || jsonb_build_object('infra_error', p_reason)
   where id = p_run_id;
  return jsonb_build_object('run_id', p_run_id, 'status', 'errored', 'changed', true);
end $$;

-- ---------------------------------------------------------------------------
-- Privilegios de ejecución
-- ---------------------------------------------------------------------------
revoke execute on all functions in schema core from public, anon, authenticated;
grant  execute on all functions in schema core to premortem_worker;
grant  execute on function core.current_workspace_ids() to authenticated;
