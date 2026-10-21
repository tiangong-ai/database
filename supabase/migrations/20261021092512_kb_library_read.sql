-- Additive page/count adapters; no source rows, RLS or existing RPCs change.
create function api.kb_metadata_read_v1(p_resource text,p_query jsonb default '{}',p_count_only boolean default false) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog as $$
declare v_actor uuid:=private.kb_metadata_actor_v1(); v_def jsonb:=private.kb_metadata_definition_v1(p_resource);
  v_limit integer; v_page integer; v_sort text; v_dir text; v_search text; v_where text; v_sort_expr text; v_rows jsonb; v_total bigint;
begin
  if not exists(select from private.kb_metadata_editors where actor_id=v_actor and resource=p_resource
    and revoked_at is null and (expires_at is null or expires_at>statement_timestamp())) then raise sqlstate '42501' using message='METADATA_FORBIDDEN'; end if;
  if p_count_only is null or p_query is null or jsonb_typeof(p_query)<>'object' or octet_length(p_query::text)>4096
    or exists(select from jsonb_each(p_query) e where not e.key=any(array['page','pageSize','sort','dir','q']) or (e.key in ('page','pageSize') and (jsonb_typeof(e.value)<>'number' or e.value::text !~ '^[0-9]+$')) or (e.key in ('sort','dir','q') and jsonb_typeof(e.value)<>'string')) then raise sqlstate 'PT400' using message='METADATA_INVALID_REQUEST'; end if;
  v_limit:=coalesce((p_query->>'pageSize')::integer,10); v_page:=coalesce((p_query->>'page')::integer,1);
  v_sort:=coalesce(p_query->>'sort',v_def->>'title');v_dir:=coalesce(p_query->>'dir','desc');v_search:=coalesce(p_query->>'q','');
  if v_limit not between 1 and 100 or v_page not between 1 and 1000000 or length(v_search)>512 or v_dir not in ('asc','desc')
    or not exists(select from pg_attribute where attrelid=('public.'||(v_def->>'table'))::regclass and attname=v_sort and attnum>0 and not attisdropped) then raise sqlstate 'PT400' using message='METADATA_INVALID_REQUEST'; end if;
  select format('%I',attname)||case when atttypid in ('json'::regtype,'jsonb'::regtype) then '::text' else '' end into v_sort_expr from pg_attribute where attrelid=('public.'||(v_def->>'table'))::regclass and attname=v_sort;
  select string_agg(format('strpos(lower(coalesce(t.%I::text,'''') ),lower($1))>0',k),' or ') into v_where from jsonb_object_keys(v_def->'fields') k;
  if v_search='' then v_where:='true'; end if;
  if p_count_only then
  execute format('select count(*) from public.%I t where %s',v_def->>'table',v_where) into v_total using v_search;
  return jsonb_build_object('total',v_total,'capabilities',jsonb_build_object('actorId',v_actor,'canWrite',true));
  end if;
  execute format('select coalesce(jsonb_agg(jsonb_build_object(''values'',to_jsonb(s),''version'',encode(sha256(convert_to(to_jsonb(s)::text,''UTF8'')),''hex'')) order by s.%s %s nulls last,s.id),''[]'') from (select t.* from public.%I t where %s order by t.%s %s nulls last,t.id limit $2 offset $3) s',v_sort_expr,v_dir,v_def->>'table',v_where,v_sort_expr,v_dir)
    into v_rows using v_search,v_limit+1,(v_page-1)*v_limit;
  return jsonb_build_object('records',(select coalesce(jsonb_agg(value order by ordinal),'[]'::jsonb) from jsonb_array_elements(v_rows) with ordinality a(value,ordinal) where ordinal<=v_limit),'hasMore',jsonb_array_length(v_rows)>v_limit,'page',v_page,'pageSize',v_limit,'capabilities',jsonb_build_object('actorId',v_actor,'canWrite',true));
exception when invalid_text_representation or numeric_value_out_of_range then raise sqlstate 'PT400' using message='METADATA_INVALID_REQUEST';
end $$;

-- One network call decides the live editor capability and reads the requested
-- page OR count. Ordinary readers execute the table query as the caller (RLS).
create function api.kb_library_read_v1(p_resource text,p_query jsonb default '{}',p_count_only boolean default false) returns jsonb
language plpgsql stable security invoker set search_path=pg_catalog as $$
declare
 v_def jsonb; v_context jsonb; v_capabilities jsonb; v_table text;
 v_limit integer; v_page integer; v_offset bigint; v_sort text; v_dir text;
 v_search text; v_where text:='true'; v_columns text; v_order text;
 v_rows jsonb; v_total bigint;
begin
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
  execute format('select count(*) from public.%I t where %s',v_table,v_where) into v_total using '%'||v_search||'%';
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

revoke all on function api.kb_metadata_read_v1(text,jsonb,boolean),api.kb_library_read_v1(text,jsonb,boolean) from public,anon,authenticated,service_role;
grant execute on function api.kb_metadata_read_v1(text,jsonb,boolean),api.kb_library_read_v1(text,jsonb,boolean) to authenticated;
notify pgrst,'reload schema';
