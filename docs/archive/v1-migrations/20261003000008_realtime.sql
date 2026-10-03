-- PREMORTEM · 0008 · Realtime como señal de refresco por canal privado "run:{run_id}".
-- Nunca viaja texto cifrado ni payload completo: solo identificadores y secuencia.
-- Si realtime.send no existiera (entorno sin Realtime), el trigger no bloquea la evidencia.

create or replace function core.notify_event()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare v_run uuid;
begin
  select run_id into v_run from public.worlds where id = new.world_id;
  begin
    perform realtime.send(
      jsonb_build_object('kind', 'event', 'attempt_id', new.attempt_id, 'world_id', new.world_id,
                         'seq', new.seq, 'type', new.type, 'visible_to_agent', new.visible_to_agent),
      'premortem', 'run:' || v_run::text, true);
  exception when others then
    null;
  end;
  return null;
end $$;

create trigger events_notify after insert on public.events
  for each row execute function core.notify_event();

create or replace function core.notify_attempt()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare v_run uuid;
begin
  select run_id into v_run from public.worlds where id = new.world_id;
  begin
    perform realtime.send(
      jsonb_build_object('kind', 'attempt', 'attempt_id', new.id, 'world_id', new.world_id,
                         'status', new.status, 'verdict', new.verdict, 'safety_violation', new.safety_violation),
      'premortem', 'run:' || v_run::text, true);
  exception when others then
    null;
  end;
  return null;
end $$;

create trigger world_attempts_notify after insert or update of status, verdict on public.world_attempts
  for each row execute function core.notify_attempt();

create or replace function core.notify_run()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  begin
    perform realtime.send(
      jsonb_build_object('kind', 'run', 'run_id', new.id, 'status', new.status),
      'premortem', 'run:' || new.id::text, true);
  exception when others then
    null;
  end;
  return null;
end $$;

create trigger runs_notify after update of status on public.runs
  for each row execute function core.notify_run();

-- Solo los miembros del workspace del run pueden suscribirse a su canal privado.
do $$
begin
  if to_regclass('realtime.messages') is not null then
    execute $p$
      create policy premortem_run_topic_members on realtime.messages
        for select to authenticated
        using (
          exists (
            select 1 from public.runs r
             where realtime.topic() = 'run:' || r.id::text
               and r.workspace_id in (select core.current_workspace_ids())
          )
        )
    $p$;
  end if;
end $$;
