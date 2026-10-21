do $$
declare f record; r text; t text;
begin
  if (select count(*) from pg_proc where pronamespace='api'::regnamespace and proname like 'kb_metadata_%')<>4 then raise exception 'Metadata API count'; end if;
  for f in select p.*,n.nspname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('api','private') and p.proname like 'kb_metadata_%' loop
    if f.proconfig is distinct from array['search_path=pg_catalog'] or f.prosecdef is distinct from (f.nspname='api') or pg_get_userbyid(f.proowner)<>'postgres' then raise exception 'Metadata attributes drift'; end if;
    foreach r in array array['anon','authenticated','service_role'] loop
      if has_function_privilege(r,f.oid,'EXECUTE') is distinct from (r='authenticated' and f.nspname='api') then raise exception 'Metadata execution drift'; end if;
    end loop;
    if exists(select from aclexplode(f.proacl) where grantee=0 and privilege_type='EXECUTE') then raise exception 'Metadata PUBLIC EXECUTE'; end if;
  end loop;
  foreach t in array array['kb_metadata_editors','kb_metadata_requests'] loop
    if not (select relrowsecurity from pg_class where oid=('private.'||t)::regclass) or exists(select from pg_policy where polrelid=('private.'||t)::regclass) then raise exception 'Metadata RLS drift'; end if;
    foreach r in array array['anon','authenticated','service_role'] loop
      if has_table_privilege(r,('private.'||t)::regclass,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') then raise exception 'Metadata table grant'; end if;
    end loop;
  end loop;
end $$;
