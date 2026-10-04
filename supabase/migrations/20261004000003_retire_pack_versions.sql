-- PREMORTEM v2 · 0012 · Retirar versiones de paquete que el despliegue ya no instala.
-- Una versión retirada deja de ofrecerse en el catálogo y en create_run (prepare_run exige status active),
-- pero su contenido, sus casos y sus runs históricos se conservan intactos.

grant premortem_owner to postgres with inherit true;

create or replace function core.retire_other_pack_versions(p_pack_id text, p_keep_version text)
returns integer
language plpgsql security definer
set search_path = ''
as $$
declare v_n integer;
begin
  if coalesce(p_pack_id, '') = '' or coalesce(p_keep_version, '') = '' then
    raise exception 'PACK_REF_REQUIRED' using errcode = 'PM400';
  end if;
  if not exists (select 1 from public.domain_pack_versions where pack_id = p_pack_id and version = p_keep_version and status = 'active') then
    raise exception 'PACK_VERSION_NOT_ACTIVE' using errcode = 'PM409';
  end if;
  update public.domain_pack_versions set status = 'retired'
   where pack_id = p_pack_id and version <> p_keep_version and status = 'active';
  get diagnostics v_n = row_count;
  return v_n;
end $$;

alter function core.retire_other_pack_versions(text, text) owner to premortem_owner;
revoke execute on function core.retire_other_pack_versions(text, text) from public, anon, authenticated;
grant execute on function core.retire_other_pack_versions(text, text) to premortem_api;

grant premortem_owner to postgres with inherit false;
