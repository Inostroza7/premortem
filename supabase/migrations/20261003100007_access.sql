-- PREMORTEM v2 · 0007 · Privilegios y RLS.
--   authenticated     lee filas de sus workspaces (RLS por membresía). No escribe nada.
--   anon              nada.
--   premortem_owner   DML sobre todas las tablas; es el rol que ejecuta las funciones SECURITY DEFINER.
--   premortem_api / premortem_worker  sin privilegios de tabla; solo EXECUTE enumerado (0008).

-- ---------------------------------------------------------------------------
-- Workspaces del usuario autenticado, para las políticas RLS. security definer evita recursión
-- sobre workspace_members; stable hace que se evalúe una vez por sentencia.
-- ---------------------------------------------------------------------------
create or replace function core.current_workspace_ids()
returns setof uuid
language sql stable security definer
set search_path = ''
as $$
  select m.workspace_id
    from public.workspace_members m
   where m.user_id = (select auth.uid());
$$;
revoke execute on function core.current_workspace_ids() from public;
grant  execute on function core.current_workspace_ids() to authenticated, premortem_owner;

-- ---------------------------------------------------------------------------
-- Retirar privilegios por defecto de Supabase en public para anon/authenticated
-- ---------------------------------------------------------------------------
revoke all on all tables    in schema public from anon;
revoke all on all sequences in schema public from anon;
revoke insert, update, delete, truncate, references, trigger on all tables in schema public from authenticated;
alter default privileges for role postgres in schema public revoke all on tables from anon;
alter default privileges for role postgres in schema public revoke all on sequences from anon;
alter default privileges for role postgres in schema public
  revoke insert, update, delete, truncate, references, trigger on tables from authenticated;

-- Lecturas de billing permitidas al usuario (RLS): wallet, ledger y compras propias.
grant usage on schema billing to authenticated;
grant select on billing.wallets, billing.credit_entries, billing.purchases to authenticated;

-- ---------------------------------------------------------------------------
-- Rol propietario de funciones: único con DML
-- ---------------------------------------------------------------------------
grant select, insert, update, delete on all tables in schema public  to premortem_owner;
grant select, insert, update, delete on all tables in schema core    to premortem_owner;
grant select, insert, update, delete on all tables in schema billing to premortem_owner;
grant usage, select on all sequences in schema public  to premortem_owner;
grant usage, select on all sequences in schema core    to premortem_owner;
grant usage, select on all sequences in schema billing to premortem_owner;
grant select on auth.users to premortem_owner;

-- ---------------------------------------------------------------------------
-- RLS en todas las tablas de aplicación
-- ---------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in
    select n.nspname, c.relname
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where c.relkind = 'r' and n.nspname in ('public','core','billing')
  loop
    execute format('alter table %I.%I enable row level security', r.nspname, r.relname);
    -- El propietario de funciones no es dueño de las tablas: necesita política explícita.
    execute format('create policy %I on %I.%I for all to premortem_owner using (true) with check (true)',
                   r.relname || '_owner_all', r.nspname, r.relname);
  end loop;
end $$;

-- Lectura por membresía (public + billing). core no tiene políticas para authenticated: denegado.
create policy workspaces_member_select on public.workspaces
  for select to authenticated using (id in (select core.current_workspace_ids()));
create policy workspace_members_member_select on public.workspace_members
  for select to authenticated using (workspace_id in (select core.current_workspace_ids()));
create policy projects_member_select on public.projects
  for select to authenticated using (workspace_id in (select core.current_workspace_ids()));
create policy domain_pack_versions_public_select on public.domain_pack_versions
  for select to authenticated using (true);
create policy agent_versions_member_select on public.agent_versions
  for select to authenticated using (workspace_id in (select core.current_workspace_ids()));
create policy case_versions_member_select on public.case_versions
  for select to authenticated using (workspace_id in (select core.current_workspace_ids()));
create policy runs_member_select on public.runs
  for select to authenticated using (workspace_id in (select core.current_workspace_ids()));
create policy world_jobs_member_select on public.world_jobs
  for select to authenticated using (workspace_id in (select core.current_workspace_ids()));
create policy world_attempts_member_select on public.world_attempts
  for select to authenticated using (workspace_id in (select core.current_workspace_ids()));
create policy attempt_events_member_select on public.attempt_events
  for select to authenticated using (workspace_id in (select core.current_workspace_ids()));
create policy effects_member_select on public.effects
  for select to authenticated using (workspace_id in (select core.current_workspace_ids()));
create policy rule_results_member_select on public.rule_results
  for select to authenticated using (workspace_id in (select core.current_workspace_ids()));
create policy tool_commits_member_select on public.tool_commits
  for select to authenticated using (workspace_id in (select core.current_workspace_ids()));
create policy wallets_member_select on billing.wallets
  for select to authenticated using (workspace_id in (select core.current_workspace_ids()));
create policy credit_entries_member_select on billing.credit_entries
  for select to authenticated using (workspace_id in (select core.current_workspace_ids()));
create policy purchases_member_select on billing.purchases
  for select to authenticated using (workspace_id in (select core.current_workspace_ids()));
