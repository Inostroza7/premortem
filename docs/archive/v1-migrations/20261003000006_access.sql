-- PREMORTEM · 0006 · Privilegios y RLS.
-- Regla única: el navegador (authenticated) solo lee filas de sus workspaces; anon no ve nada;
-- el worker (premortem_worker) escribe con políticas explícitas. core nunca se expone.

-- ---------------------------------------------------------------------------
-- Retirar los privilegios por defecto de Supabase sobre public para anon/authenticated
-- ---------------------------------------------------------------------------
revoke all on all tables    in schema public from anon;
revoke all on all sequences in schema public from anon;
revoke insert, update, delete, truncate, references, trigger on all tables in schema public from authenticated;

alter default privileges for role postgres in schema public revoke all on tables from anon;
alter default privileges for role postgres in schema public revoke all on sequences from anon;
alter default privileges for role postgres in schema public
  revoke insert, update, delete, truncate, references, trigger on tables from authenticated;

-- ---------------------------------------------------------------------------
-- Privilegios del rol de servidor
-- ---------------------------------------------------------------------------
grant select, insert, update          on public.workspaces, public.workspace_members, public.domains to premortem_worker;
grant select, insert                  on public.agent_versions, public.tasks to premortem_worker;
grant select, insert, update          on public.runs, public.worlds, public.world_attempts to premortem_worker;
grant select, insert, update          on public.events to premortem_worker;   -- update solo por retención (trigger)
grant select, insert                  on public.effects, public.findings to premortem_worker;
grant select, insert                  on core.task_oracles to premortem_worker;
grant select, insert, update          on core.data_keys to premortem_worker;
grant select, insert                  on core.access_log to premortem_worker;
grant usage, select on all sequences in schema public to premortem_worker;
grant usage, select on all sequences in schema core   to premortem_worker;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.workspaces         enable row level security;
alter table public.workspace_members  enable row level security;
alter table public.domains            enable row level security;
alter table public.agent_versions     enable row level security;
alter table public.tasks              enable row level security;
alter table public.runs               enable row level security;
alter table public.worlds             enable row level security;
alter table public.world_attempts     enable row level security;
alter table public.events             enable row level security;
alter table public.effects            enable row level security;
alter table public.findings           enable row level security;
alter table core.task_oracles         enable row level security;
alter table core.data_keys            enable row level security;
alter table core.access_log           enable row level security;

-- Lectura del usuario: pertenencia al workspace
create policy workspaces_member_select on public.workspaces
  for select to authenticated using (id in (select core.current_workspace_ids()));
create policy workspace_members_member_select on public.workspace_members
  for select to authenticated using (workspace_id in (select core.current_workspace_ids()));
create policy domains_public_select on public.domains
  for select to authenticated using (true);
create policy agent_versions_member_select on public.agent_versions
  for select to authenticated using (workspace_id in (select core.current_workspace_ids()));
create policy tasks_member_select on public.tasks
  for select to authenticated using (workspace_id in (select core.current_workspace_ids()));
create policy runs_member_select on public.runs
  for select to authenticated using (workspace_id in (select core.current_workspace_ids()));
create policy worlds_member_select on public.worlds
  for select to authenticated using (workspace_id in (select core.current_workspace_ids()));
create policy world_attempts_member_select on public.world_attempts
  for select to authenticated using (workspace_id in (select core.current_workspace_ids()));
create policy events_member_select on public.events
  for select to authenticated using (workspace_id in (select core.current_workspace_ids()));
create policy effects_member_select on public.effects
  for select to authenticated using (workspace_id in (select core.current_workspace_ids()));
create policy findings_member_select on public.findings
  for select to authenticated using (workspace_id in (select core.current_workspace_ids()));
-- core: ninguna política para authenticated → denegado.

-- Worker: acceso completo explícito (no es dueño de las tablas, así que RLS le aplica)
create policy workspaces_worker        on public.workspaces        for all to premortem_worker using (true) with check (true);
create policy workspace_members_worker on public.workspace_members for all to premortem_worker using (true) with check (true);
create policy domains_worker           on public.domains           for all to premortem_worker using (true) with check (true);
create policy agent_versions_worker    on public.agent_versions    for all to premortem_worker using (true) with check (true);
create policy tasks_worker             on public.tasks             for all to premortem_worker using (true) with check (true);
create policy runs_worker              on public.runs              for all to premortem_worker using (true) with check (true);
create policy worlds_worker            on public.worlds            for all to premortem_worker using (true) with check (true);
create policy world_attempts_worker    on public.world_attempts    for all to premortem_worker using (true) with check (true);
create policy events_worker            on public.events            for all to premortem_worker using (true) with check (true);
create policy effects_worker           on public.effects           for all to premortem_worker using (true) with check (true);
create policy findings_worker          on public.findings          for all to premortem_worker using (true) with check (true);
create policy task_oracles_worker      on core.task_oracles        for all to premortem_worker using (true) with check (true);
create policy data_keys_worker         on core.data_keys           for all to premortem_worker using (true) with check (true);
create policy access_log_worker        on core.access_log          for all to premortem_worker using (true) with check (true);
