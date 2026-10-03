-- PREMORTEM v2 · 0009 · Realtime: solo identificadores y secuencias por canal privado "run:{run_id}".
-- El cliente consulta después la API/tabla autorizada con after_seq. Sin payloads ni texto.

create or replace function core.notify_event()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  begin
    perform realtime.send(
      jsonb_build_object('kind', 'event', 'run_id', new.run_id, 'job_id', new.job_id,
                         'attempt_id', new.attempt_id, 'seq', new.seq, 'type', new.type, 'audience', new.audience),
      'premortem', 'run:' || new.run_id::text, true);
  exception when others then
    null;   -- Realtime es una señal; su ausencia no bloquea la evidencia
  end;
  return null;
end $$;
create trigger attempt_events_notify after insert on public.attempt_events
  for each row execute function core.notify_event();

create or replace function core.notify_job()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  begin
    perform realtime.send(
      jsonb_build_object('kind', 'job', 'run_id', new.run_id, 'job_id', new.id, 'status', new.status,
                         'verdict', new.verdict, 'attempt_id', new.active_attempt_id),
      'premortem', 'run:' || new.run_id::text, true);
  exception when others then
    null;
  end;
  return null;
end $$;
create trigger world_jobs_notify after update of status, verdict, active_attempt_id on public.world_jobs
  for each row execute function core.notify_job();

create or replace function core.notify_run()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  begin
    perform realtime.send(
      jsonb_build_object('kind', 'run', 'run_id', new.id, 'status', new.status,
                         'jobs_total', new.jobs_total, 'jobs_terminal', new.jobs_terminal),
      'premortem', 'run:' || new.id::text, true);
  exception when others then
    null;
  end;
  return null;
end $$;
create trigger runs_notify after update of status, jobs_terminal on public.runs
  for each row execute function core.notify_run();

-- Solo miembros del workspace del run pueden suscribirse a su canal privado.
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

-- ---------------------------------------------------------------------------
-- Endurecimiento final (spec v2 §12): ninguna función interna hereda EXECUTE de PUBLIC, incluidas las
-- de trigger y utilidades creadas por el rol de migración. Solo se devuelve a authenticated la función
-- que usan las políticas RLS.
-- ---------------------------------------------------------------------------
-- (Las funciones del motor ya lo hacen en 0008 bajo su propietario; aquí van las creadas por el rol de migración.
--  Toda función nueva de trigger o utilidad en core/billing debe añadirse a esta lista.)
revoke execute on function
  core.current_workspace_ids(), core.handle_new_user(), core.forbid_change(), core.forbid_update(),
  core.payloads_guard(), core.domain_pack_guard(), core.notify_event(), core.notify_job(), core.notify_run()
from public, anon, authenticated;
grant execute on function core.current_workspace_ids() to authenticated, premortem_owner;
