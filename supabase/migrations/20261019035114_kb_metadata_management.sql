-- Additive six-resource gateway. No legacy table, grant or production user changes.
create table private.kb_metadata_editors (
  actor_id uuid not null references auth.users(id) on delete cascade,
  resource text not null check(resource in ('education','esg','standards','reports','internalUse','greenDeal')),
  granted_by uuid not null,
  granted_at timestamptz not null default now(),
  expires_at timestamptz,
  revoked_at timestamptz,
  primary key(actor_id,resource)
);
create table private.kb_metadata_requests (
  actor_id uuid not null,
  request_id uuid not null,
  payload_hash text not null check(payload_hash ~ '^[0-9a-f]{64}$'),
  receipt jsonb not null check(jsonb_typeof(receipt)='object'),
  created_at timestamptz not null default now(),
  primary key(actor_id,request_id)
);
alter table private.kb_metadata_editors enable row level security;
alter table private.kb_metadata_requests enable row level security;
revoke all on private.kb_metadata_editors,private.kb_metadata_requests from public,anon,authenticated,service_role;

create function private.kb_metadata_definition_v1(p_resource text) returns jsonb
language plpgsql immutable security invoker set search_path=pg_catalog as $$
declare v_definition jsonb;
begin
  v_definition := case p_resource
    when 'education' then '{"table":"edu_meta","title":"name","fields":{"name":"short","course":"short","type":"short","language":"lang","file_type":"short","chapter_number":"int","description":"text"}}'
    when 'esg' then '{"table":"esg_meta","title":"report_title","fields":{"report_title":"text","company_name":"text","company_name_en":"text","country":"short","language":"lang","publication_date":"date","report_url":"text"}}'
    when 'standards' then '{"table":"standards","title":"title","fields":{"title":"text","standard_number":"text","issuing_organization":"json","language":"lang","effective_date":"date","expiration_date":"date","url":"text"}}'
    when 'reports' then '{"table":"reports","title":"title","fields":{"title":"text","release_date":"date","language":"lang","url":"text","issuing_organization":"json"}}'
    when 'internalUse' then '{"table":"internal_use","title":"title","fields":{"title":"text","tag":"text","language":"lang","file_type":"text"}}'
    when 'greenDeal' then '{"table":"green_deal_meta","title":"title","fields":{"title":"text","celex_number":"short","form":"short","issue_agency":"short","publish_date":"date","authors":"short"}}'
    else null end;
  if v_definition is null then raise sqlstate 'PT400' using message='METADATA_INVALID_RESOURCE'; end if;
  return v_definition;
end $$;

create function private.kb_metadata_actor_v1() returns uuid
language plpgsql stable security invoker set search_path=pg_catalog as $$
declare v_actor uuid:=auth.uid();
begin
  if auth.role() is distinct from 'authenticated' or v_actor is null
     or not exists(select from auth.users where id=v_actor) then
    raise sqlstate '42501' using message='METADATA_AUTH_REQUIRED';
  end if;
  return v_actor;
end $$;

-- Metadata and its concurrency token MUST come from the same row snapshot.
-- Readers retain existing RLS; only explicitly authorized editors receive these snapshots.
create function api.kb_metadata_context_v1(p_resource text,p_ids uuid[] default '{}') returns jsonb
language plpgsql stable security definer set search_path=pg_catalog as $$
declare v_actor uuid:=private.kb_metadata_actor_v1();
  v_def jsonb:=private.kb_metadata_definition_v1(p_resource); v_manage boolean; v_rows jsonb:='{}';
begin
  if p_ids is null or cardinality(p_ids)>100 or array_position(p_ids,null) is not null then
    raise sqlstate 'PT400' using message='METADATA_INVALID_REQUEST';
  end if;
  select exists(select from private.kb_metadata_editors where actor_id=v_actor and resource=p_resource
    and revoked_at is null and (expires_at is null or expires_at>statement_timestamp())) into v_manage;
  if v_manage then
    execute format('select coalesce(jsonb_object_agg(t.id,jsonb_build_object(''values'',to_jsonb(t),''version'',encode(sha256(convert_to(to_jsonb(t)::text,''UTF8'')),''hex''))),''{}''::jsonb) from public.%I t where id=any($1)',v_def->>'table')
      into v_rows using p_ids;
  end if;
  return jsonb_build_object('version',1,'actorId',v_actor,'canWrite',v_manage,'records',v_rows);
end $$;

-- Explicit editor read capability; Green Deal has no ordinary-user read policy.
create function api.kb_metadata_list_v1(p_resource text,p_query jsonb default '{}') returns jsonb
language plpgsql stable security definer set search_path=pg_catalog as $$
declare v_actor uuid:=private.kb_metadata_actor_v1(); v_def jsonb:=private.kb_metadata_definition_v1(p_resource);
  v_limit integer; v_page integer; v_sort text; v_dir text; v_search text; v_where text; v_sort_expr text; v_rows jsonb; v_total bigint;
begin
  if not exists(select from private.kb_metadata_editors where actor_id=v_actor and resource=p_resource
    and revoked_at is null and (expires_at is null or expires_at>statement_timestamp())) then raise sqlstate '42501' using message='METADATA_FORBIDDEN'; end if;
  if p_query is null or jsonb_typeof(p_query)<>'object' or octet_length(p_query::text)>4096
    or exists(select from jsonb_each(p_query) e where not e.key=any(array['page','pageSize','sort','dir','q']) or (e.key in ('page','pageSize') and (jsonb_typeof(e.value)<>'number' or e.value::text !~ '^[0-9]+$')) or (e.key in ('sort','dir','q') and jsonb_typeof(e.value)<>'string')) then raise sqlstate 'PT400' using message='METADATA_INVALID_REQUEST'; end if;
  v_limit:=coalesce((p_query->>'pageSize')::integer,10); v_page:=coalesce((p_query->>'page')::integer,1);
  v_sort:=coalesce(p_query->>'sort',v_def->>'title');v_dir:=coalesce(p_query->>'dir','desc');v_search:=coalesce(p_query->>'q','');
  if v_limit not between 1 and 100 or v_page not between 1 and 1000000 or length(v_search)>512 or v_dir not in ('asc','desc')
    or not exists(select from pg_attribute where attrelid=('public.'||(v_def->>'table'))::regclass and attname=v_sort and attnum>0 and not attisdropped) then raise sqlstate 'PT400' using message='METADATA_INVALID_REQUEST'; end if;
  select format('%I',attname)||case when atttypid in ('json'::regtype,'jsonb'::regtype) then '::text' else '' end into v_sort_expr from pg_attribute where attrelid=('public.'||(v_def->>'table'))::regclass and attname=v_sort;
  select string_agg(format('strpos(lower(coalesce(t.%I::text,'''') ),lower($1))>0',k),' or ') into v_where from jsonb_object_keys(v_def->'fields') k;
  execute format('select count(*) from public.%I t where %s',v_def->>'table',v_where) into v_total using v_search;
  execute format('select coalesce(jsonb_agg(jsonb_build_object(''values'',to_jsonb(s),''version'',encode(sha256(convert_to(to_jsonb(s)::text,''UTF8'')),''hex'')) order by s.%s %s nulls last,s.id),''[]'') from (select t.* from public.%I t where %s order by t.%s %s nulls last,t.id limit $2 offset $3) s',v_sort_expr,v_dir,v_def->>'table',v_where,v_sort_expr,v_dir)
    into v_rows using v_search,v_limit,(v_page-1)*v_limit;
  return jsonb_build_object('version',1,'records',v_rows,'total',v_total,'page',v_page,'pageSize',v_limit);
exception when invalid_text_representation or numeric_value_out_of_range then raise sqlstate 'PT400' using message='METADATA_INVALID_REQUEST';
end $$;

create function api.kb_metadata_command_v1(
  p_resource text,p_operation text,p_request_id uuid,p_payload jsonb default '{}',
  p_record_id uuid default null,p_expected_version text default null
) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v_actor uuid:=private.kb_metadata_actor_v1();
  v_def jsonb:=private.kb_metadata_definition_v1(p_resource);
  v_table text:=v_def->>'table'; v_title text:=v_def->>'title';
  v_hash text; v_old private.kb_metadata_requests; v_row jsonb; v_before text; v_after text;
  v_key text; v_value jsonb; v_type text; v_columns text; v_values text; v_set text; v_id uuid;
  v_receipt jsonb;
begin
  -- Lock an actual grant so a committed revocation cannot race a successful write.
  perform 1 from private.kb_metadata_editors where actor_id=v_actor and resource=p_resource
    and revoked_at is null and (expires_at is null or expires_at>statement_timestamp()) for share;
  if not found then raise sqlstate '42501' using message='METADATA_FORBIDDEN'; end if;
  if p_request_id is null or p_operation is null or p_operation not in ('create','update','delete')
    or p_payload is null or jsonb_typeof(p_payload)<>'object' or octet_length(p_payload::text)>65536
    or (p_operation='create' and (p_record_id is not null or p_expected_version is not null))
    or (p_operation<>'create' and (p_record_id is null or p_expected_version is null or p_expected_version !~ '^[0-9a-f]{64}$'))
    or (p_operation='delete' and p_payload<>'{}') then
    raise sqlstate 'PT400' using message='METADATA_INVALID_REQUEST';
  end if;
  for v_key,v_value in select * from jsonb_each(p_payload) loop
    v_type:=v_def->'fields'->>v_key;
    if v_type is null then raise sqlstate 'PT400' using message='METADATA_INVALID_FIELDS'; end if;
    if v_value='null'::jsonb then continue; end if;
    if v_type='json' then
      if jsonb_typeof(v_value) not in ('object','array') then raise sqlstate 'PT400' using message='METADATA_INVALID_FIELDS'; end if;
    elsif v_type='int' then
      if jsonb_typeof(v_value)<>'number' or v_value::text !~ '^[0-9]+$' or (v_value::text)::numeric>2147483647 then
        raise sqlstate 'PT400' using message='METADATA_INVALID_FIELDS'; end if;
    else
      if jsonb_typeof(v_value)<>'string' or length(p_payload->>v_key)>(case when v_type='short' then 255 else 10000 end) then
        raise sqlstate 'PT400' using message='METADATA_INVALID_FIELDS'; end if;
      if v_type='lang' and p_payload->>v_key not in ('eng','chi_sim','chi_tra','fra','spa','jpn','kor') then
        raise sqlstate 'PT400' using message='METADATA_INVALID_FIELDS'; end if;
      if v_type='date' and (p_payload->>v_key !~ '^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2}))?$'
        or not isfinite((p_payload->>v_key)::timestamptz)) then raise sqlstate 'PT400' using message='METADATA_INVALID_FIELDS'; end if;
    end if;
  end loop;
  if (p_operation='create' or p_payload ? v_title) and coalesce(length(btrim(p_payload->>v_title)),0)=0 then
    raise sqlstate 'PT400' using message='METADATA_TITLE_REQUIRED'; end if;
  if p_operation in ('create','update') and p_payload='{}' then raise sqlstate 'PT400' using message='METADATA_INVALID_FIELDS'; end if;
  v_hash:=encode(sha256(convert_to(jsonb_build_array(p_resource,p_operation,p_payload,p_record_id,p_expected_version)::text,'UTF8')),'hex');
  perform pg_advisory_xact_lock(hashtextextended('metadata:'||v_actor::text||':'||p_request_id::text,0));
  select * into v_old from private.kb_metadata_requests where actor_id=v_actor and request_id=p_request_id;
  if found then
    if v_old.payload_hash<>v_hash then raise sqlstate 'PT409' using message='METADATA_REQUEST_CONFLICT'; end if;
    return v_old.receipt||jsonb_build_object('replayed',true);
  end if;
  if p_operation<>'create' then
    -- M1 writers already acquire ROW EXCLUSIVE here. NOWAIT prevents lock-order deadlocks.
    -- Keep this guard until a jointly implemented lifecycle replaces legacy mutations.
    lock table private.kb_resource_entries in share mode nowait;
    execute format('select to_jsonb(t) from public.%I t where id=$1 for update',v_table) into v_row using p_record_id;
    if v_row is null then raise sqlstate 'PT404' using message='METADATA_NOT_FOUND'; end if;
    v_before:=encode(sha256(convert_to(v_row::text,'UTF8')),'hex');
    if v_before<>p_expected_version then raise sqlstate 'PT409' using message='METADATA_VERSION_CONFLICT'; end if;
    if exists(select from private.kb_resource_entries where legacy_ref->>'table'=v_table and lower(legacy_ref->>'id')=p_record_id::text)
      or exists(select from jsonb_each(v_row) e where e.key in ('nas_path','pdf_name','upload_time','uploaded_time','embedding_time','embedded_time','fulltext_time','unstructure_time')
        and e.value<>'null'::jsonb and e.value<>'""'::jsonb) then
      raise sqlstate 'PT409' using message='METADATA_LIFECYCLE_REQUIRED';
    end if;
  end if;
  select string_agg(format('%I',k),',' order by k),string_agg(format('x.%I',k),',' order by k),
    string_agg(format('%I=x.%I',k,k),',' order by k) into v_columns,v_values,v_set from jsonb_object_keys(p_payload) k;
  if p_operation='create' then
    execute format('insert into public.%I(%s) select %s from jsonb_populate_record(null::public.%I,$1) x returning to_jsonb(%I.*)',v_table,v_columns,v_values,v_table,v_table)
      into v_row using p_payload;
  elsif p_operation='update' then
    execute format('update public.%I t set %s from jsonb_populate_record(null::public.%I,$1) x where t.id=$2 returning to_jsonb(t)',v_table,v_set,v_table)
      into v_row using p_payload,p_record_id;
  else
    execute format('delete from public.%I where id=$1',v_table) using p_record_id;
  end if;
  v_id:=(v_row->>'id')::uuid;
  if p_operation<>'delete' then v_after:=encode(sha256(convert_to(v_row::text,'UTF8')),'hex'); end if;
  v_receipt:=jsonb_build_object('version',1,'id',v_id,'recordVersion',v_after,'replayed',false);
  perform public.write_kb_audit_event(v_actor,'kb.metadata_'||p_operation||'_v1',null,null,
    jsonb_build_object('resource',p_resource),p_request_id::text,
    jsonb_build_object('record_id',v_id,'fields',array(select jsonb_object_keys(p_payload)),'before_version',v_before,'after_version',v_after));
  insert into private.kb_metadata_requests(actor_id,request_id,payload_hash,receipt) values(v_actor,p_request_id,v_hash,v_receipt);
  return v_receipt;
exception
  when invalid_text_representation or invalid_datetime_format or datetime_field_overflow or string_data_right_truncation or numeric_value_out_of_range then
    raise sqlstate 'PT400' using message='METADATA_INVALID_FIELDS';
  when lock_not_available or deadlock_detected then raise sqlstate 'PT409' using message='METADATA_BUSY';
  when sqlstate '42501' or sqlstate 'PT400' or sqlstate 'PT404' or sqlstate 'PT409' then raise;
  when others then raise sqlstate 'PT500' using message='METADATA_OPERATION_FAILED';
end $$;

revoke all on function private.kb_metadata_definition_v1(text),private.kb_metadata_actor_v1() from public,anon,authenticated,service_role;
revoke all on function api.kb_metadata_context_v1(text,uuid[]),api.kb_metadata_list_v1(text,jsonb),api.kb_metadata_command_v1(text,text,uuid,jsonb,uuid,text) from public,anon,authenticated,service_role;
grant execute on function api.kb_metadata_context_v1(text,uuid[]),api.kb_metadata_list_v1(text,jsonb),api.kb_metadata_command_v1(text,text,uuid,jsonb,uuid,text) to authenticated;
notify pgrst,'reload schema';
