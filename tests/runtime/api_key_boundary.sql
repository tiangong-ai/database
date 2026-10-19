-- S2 exact exposure, ownership, execution and search-path contract.
do $$
declare f record; r text; names text[]:=array['kb_api_key_list_v1','kb_api_key_create_v1','kb_api_key_revoke_v1','kb_api_key_rotate_v1'];
begin
  if to_regclass('public.kb_api_keys') is null or to_regclass('private.kb_api_keys') is not null then
    raise exception 'S2 must not relocate kb_api_keys';
  end if;
  if exists(select from pg_proc where pronamespace='api'::regnamespace and not proname=any(names||array['kb_resource_command','kb_resource_get','kb_metadata_context_v1','kb_metadata_list_v1','kb_metadata_command_v1','kb_catalogue_v1']))
    or (select count(*) from pg_proc where pronamespace='api'::regnamespace and proname=any(names))<>4 then
    raise exception 'Unexpected api surface';
  end if;
  for f in select p.*,n.nspname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname in ('api','private') and p.proname like 'kb_api_key_%' loop
    if f.proconfig is distinct from array['search_path=pg_catalog']
      or f.prosecdef is distinct from (f.nspname='api')
      or pg_get_userbyid(f.proowner)<>'postgres' then raise exception 'Unsafe S2 function attributes: %',f.proname; end if;
    foreach r in array array['anon','authenticated','service_role'] loop
      if has_function_privilege(r,f.oid,'EXECUTE') is distinct from (r='authenticated' and f.nspname='api') then
        raise exception 'S2 function ACL drift: % %',r,f.proname;
      end if;
    end loop;
    if exists(select from aclexplode(f.proacl) where grantee=0 and privilege_type='EXECUTE') then raise exception 'PUBLIC EXECUTE'; end if;
  end loop;
  foreach r in array array['anon','authenticated','service_role'] loop
    if has_table_privilege(r,'private.kb_api_key_requests','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') then
      raise exception 'Direct request ledger permission: %',r;
    end if;
  end loop;
  if not (select relrowsecurity from pg_class where oid='private.kb_api_key_requests'::regclass)
    or exists(select from pg_policy where polrelid='private.kb_api_key_requests'::regclass) then
    raise exception 'Request ledger RLS drift';
  end if;
end $$;
