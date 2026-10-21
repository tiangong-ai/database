-- Verify the current account/session inside the same database request as the
-- page/count. No business table policy, editor grant or write path changes.
create function private.kb_library_session_v1() returns uuid
language plpgsql stable security definer set search_path=pg_catalog as $$
declare v_actor uuid:=auth.uid(); v_session uuid;
begin
  if auth.role() is distinct from 'authenticated' or v_actor is null then
    raise sqlstate '42501' using message='LIBRARY_SESSION_REQUIRED';
  end if;
  begin
    v_session:=(auth.jwt()->>'session_id')::uuid;
  exception when invalid_text_representation then
    raise sqlstate '42501' using message='LIBRARY_SESSION_REQUIRED';
  end;
  if v_session is null or not exists (
    select from auth.users u join auth.sessions s on s.user_id=u.id
    where u.id=v_actor and s.id=v_session
      and (u.banned_until is null or u.banned_until<=statement_timestamp())
      and u.deleted_at is null
  ) then
    raise sqlstate '42501' using message='LIBRARY_SESSION_REQUIRED';
  end if;
  return v_actor;
end $$;

-- SQL-standard body binds the unexposed helper without granting private USAGE.
create function api.kb_library_session_v1() returns uuid
language sql stable security invoker set search_path=pg_catalog
return private.kb_library_session_v1();
revoke all on function private.kb_library_session_v1(),api.kb_library_session_v1() from public,anon,authenticated,service_role;
grant execute on function private.kb_library_session_v1(),api.kb_library_session_v1() to authenticated;

create or replace function api.kb_library_read_v1(p_resource text,p_query jsonb default '{}',p_count_only boolean default false) returns jsonb
language plpgsql stable security invoker set search_path=pg_catalog as $$
declare
 v_def jsonb; v_context jsonb; v_capabilities jsonb; v_table text;
 v_limit integer; v_page integer; v_offset bigint; v_sort text; v_dir text;
 v_search text; v_where text:='true'; v_columns text; v_order text;
 v_rows jsonb; v_total bigint;
begin
 perform api.kb_library_session_v1();
 if auth.uid() is null or auth.role() is distinct from 'authenticated' then
  raise sqlstate '42501' using message='METADATA_AUTH_REQUIRED';
 end if;
 v_def:=case p_resource
 when 'journals' then '{"table":"journals","sort":"id","columns":["id","title","journal","doi","date"],"search":[]}'
 when 'education' then '{"table":"edu_meta","sort":"upload_time","columns":["id","name","course","type","language","file_type","chapter_number","upload_time"],"search":["name","course","type","description"]}'
 when 'esg' then '{"table":"esg_meta","sort":"uploaded_time","columns":["id","report_title","company_name","country","language","publication_date","uploaded_time"],"search":["report_title","company_name","company_name_en","country"]}'
 when 'standards' then '{"table":"standards","sort":"uploaded_time","columns":["id","title","standard_number","issuing_organization","language","effective_date","uploaded_time"],"search":["title","standard_number"]}'
 when 'reports' then '{"table":"reports","sort":"uploaded_time","columns":["id","title","release_date","language","url","issuing_organization","uploaded_time"],"search":["title"]}'
 when 'internalUse' then '{"table":"internal_use","sort":"created_time","columns":["id","title","tag","language","file_type","uploaded_time","created_time"],"search":["title","tag","file_type"]}'
 when 'greenDeal' then '{"table":"green_deal_meta","sort":"upload_time","columns":["id","title","celex_number","form","issue_agency","publish_date","upload_time"],"search":["title","celex_number","issue_agency","authors"]}'
 else null end;
 if v_def is null then raise sqlstate 'PT400' using message='METADATA_INVALID_RESOURCE'; end if;
 if p_count_only is null or p_query is null or jsonb_typeof(p_query)<>'object' or octet_length(p_query::text)>4096
  or exists(select from jsonb_each(p_query) e where not e.key=any(array['page','pageSize','sort','dir','q'])
   or (e.key in ('page','pageSize') and (jsonb_typeof(e.value)<>'number' or e.value::text !~ '^[0-9]+$'))
   or (e.key in ('sort','dir','q') and jsonb_typeof(e.value)<>'string')) then raise sqlstate 'PT400' using message='METADATA_INVALID_REQUEST'; end if;
 v_limit:=coalesce((p_query->>'pageSize')::integer,10);v_page:=coalesce((p_query->>'page')::integer,1);
 v_sort:=coalesce(p_query->>'sort',v_def->>'sort');v_dir:=coalesce(p_query->>'dir','desc');v_search:=coalesce(p_query->>'q','');
 if v_limit not between 1 and 100 or v_page not between 1 and 1000000 or length(v_search)>512
  or v_dir not in ('asc','desc') or (p_resource='journals' and v_search<>'')
  or not (v_def->'columns' ? v_sort) then raise sqlstate 'PT400' using message='METADATA_INVALID_REQUEST'; end if;
 -- Reuse the existing definer identity/grant check, without a second HTTP call.
 -- Journals is read-only; a metadata context check also rejects nonexistent users.
 v_context:=api.kb_metadata_context_v1(case when p_resource='journals' then 'education' else p_resource end,'{}');
 v_capabilities:=jsonb_build_object('actorId',v_context->>'actorId','canWrite',p_resource<>'journals' and (v_context->>'canWrite')::boolean);
 if (v_capabilities->>'canWrite')::boolean then
  return api.kb_metadata_read_v1(p_resource,p_query||jsonb_build_object('sort',v_sort),p_count_only);
 end if;
 v_table:=v_def->>'table';v_offset:=(v_page::bigint-1)*v_limit;
 select string_agg(format('t.%I',value),',') into v_columns from jsonb_array_elements_text(v_def->'columns');
 -- Match the existing reader adapter's wildcard cleanup and ILIKE semantics.
 v_search:=btrim(regexp_replace(regexp_replace(v_search,'[%_,]',' ','g'),'\s+',' ','g'));
 if v_search<>'' then
  select string_agg(format('t.%I ilike $1',value),' or ') into v_where from jsonb_array_elements_text(v_def->'search');
 end if;
 if p_count_only then
  execute format('select count(t.id) from public.%I t where %s',v_table,v_where) into v_total using '%'||v_search||'%';
  return jsonb_build_object('total',v_total,'capabilities',v_capabilities);
 end if;
 select format('%I',attname)||case when atttypid in ('json'::regtype,'jsonb'::regtype) then '::text' else '' end
  into v_order from pg_attribute where attrelid=('public.'||v_table)::regclass and attname=v_sort and attnum>0 and not attisdropped;
 v_order:=v_order||' '||v_dir||case when v_sort='id' then '' else ' nulls last' end;
 if p_resource='journals' and v_sort='id' and v_offset>=1000 then
  -- Preserve the qualified deep-page sequential visibility scan; no count is
  -- attached to the page. Only ordinary pages use the direct indexed path.
  execute format('with visible_ids as materialized (select id from public.journals), page_ids as (select id from visible_ids order by %s limit $1 offset $2) select coalesce(jsonb_agg(to_jsonb(s) order by s.%s),''[]''::jsonb) from (select %s from page_ids p join public.journals t using(id)) s',v_order,v_order,v_columns)
   into v_rows using v_limit+1,v_offset;
 else
  execute format('select coalesce(jsonb_agg(to_jsonb(s) order by s.%s,s.id),''[]''::jsonb) from (select %s from public.%I t where %s order by t.%s,t.id limit $2 offset $3) s',v_order,v_columns,v_table,v_where,v_order)
   into v_rows using '%'||v_search||'%',v_limit+1,v_offset;
 end if;
 return jsonb_build_object('data',(select coalesce(jsonb_agg(value order by ordinal),'[]'::jsonb) from jsonb_array_elements(v_rows) with ordinality a(value,ordinal) where ordinal<=v_limit),'hasMore',jsonb_array_length(v_rows)>v_limit,'page',v_page,'pageSize',v_limit,'capabilities',v_capabilities);
exception when invalid_text_representation or numeric_value_out_of_range then raise sqlstate 'PT400' using message='METADATA_INVALID_REQUEST';
end $$;

notify pgrst,'reload schema';
