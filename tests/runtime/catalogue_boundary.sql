do $$
declare f record; r text;
begin
  if (select count(*) from pg_proc where pronamespace in ('api'::regnamespace,'private'::regnamespace) and proname like 'kb_catalogue_%')<>13 then raise exception 'Catalogue function count'; end if;
  for f in select p.*,n.nspname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('api','private') and p.proname like 'kb_catalogue_%' loop
    if f.proconfig is distinct from array['search_path=pg_catalog'] or pg_get_userbyid(f.proowner)<>'postgres' then raise exception 'Catalogue attributes drift'; end if;
    if f.prosecdef is distinct from (f.proname in ('kb_catalogue_query_v1','kb_catalogue_registered_v1','kb_catalogue_policy_editors_v1','kb_catalogue_journal_sync_v1','kb_catalogue_journal_matches_v1','kb_catalogue_short_filter_sync_v1')) then raise exception 'Catalogue definer drift'; end if;
    foreach r in array array['anon','authenticated','service_role'] loop
      if has_function_privilege(r,f.oid,'EXECUTE') is distinct from (r='authenticated' and f.proname not in ('kb_catalogue_journal_sync_v1','kb_catalogue_short_filter_sync_v1','kb_catalogue_short_signature_v1')) then raise exception 'Catalogue execution drift'; end if;
    end loop;
    if exists(select from aclexplode(f.proacl) where grantee=0 and privilege_type='EXECUTE') then raise exception 'Catalogue PUBLIC EXECUTE'; end if;
  end loop;
  foreach r in array array['anon','authenticated','service_role'] loop
    if has_table_privilege(r,'private.kb_catalogue_journal_search','SELECT,INSERT,UPDATE,DELETE,TRUNCATE') then raise exception 'Search projection ACL drift'; end if;
    if has_table_privilege(r,'private.kb_catalogue_journal_short_filter','SELECT,INSERT,UPDATE,DELETE,TRUNCATE') then raise exception 'Short filter ACL drift'; end if;
  end loop;
  if has_schema_privilege('authenticated','private','usage') then raise exception 'Private schema usage drift'; end if;
end $$;
