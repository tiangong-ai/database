-- Read-only catalogue. No table moves, identity changes, file IO or jobs.
begin;

-- Validate the actual ordinary Auth session, not a caller-supplied actor.
create function private.kb_catalogue_query_v1(p_query jsonb) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog as $$
begin
  perform private.kb_metadata_actor_v1();
  if p_query is null or jsonb_typeof(p_query)<>'object' or octet_length(p_query::text)>2048
    or exists(select from jsonb_each(p_query) x where x.key not in ('q','category','state','page','page_size','key','collection')
      or (x.key in ('page','page_size') and (jsonb_typeof(x.value)<>'number' or x.value::text !~ '^[0-9]+$'))
      or (x.key not in ('page','page_size') and jsonb_typeof(x.value)<>'string'))
    or coalesce((p_query->>'page')::integer,1) not between 1 and 10000
    or coalesce((p_query->>'page_size')::integer,20) not between 1 and 50
    or length(coalesce(p_query->>'q',''))>200
    or coalesce(p_query->>'category','all') not in ('all','journals','esg','standards','reports','education','policies','other')
    or coalesce(p_query->>'state','all') not in ('all','associated','missing','pending','review','failed','ready','unknown')
    or (p_query ? 'key' and (length(p_query->>'key')>100 or p_query->>'key' !~ '^[A-Za-z]+:[0-9a-f-]{36}$'))
    or (p_query ? 'collection' and p_query->>'collection' !~ '^[0-9a-f-]{36}$') then
    raise sqlstate '22023' using message='CATALOGUE_INVALID_QUERY';
  end if;
  return jsonb_build_object('page',1,'page_size',20,'q','','category','all','state','all')||p_query;
exception when invalid_text_representation or numeric_value_out_of_range then
  raise sqlstate '22023' using message='CATALOGUE_INVALID_QUERY';
end $$;

-- A display category is separate from collection identity and access policy.
create function private.kb_catalogue_category_v1(p_category text,p_table text) returns text
language sql immutable security invoker set search_path=pg_catalog
return case when p_category in ('journals','esg','standards','reports','education','policies','other') then p_category
  else case p_table when 'journals' then 'journals' when 'esg_meta' then 'esg'
    when 'standards' then 'standards' when 'reports' then 'reports' when 'edu_meta' then 'education'
    when 'green_deal_meta' then 'policies' else 'other' end end;

create function private.kb_catalogue_row_v1(p_kind text,p_id uuid,p_category text,p_title text,p_metadata jsonb,p_updated timestamptz,p_extra jsonb default '{}') returns jsonb
language sql immutable security invoker set search_path=pg_catalog
return jsonb_build_object('key',p_kind||':'||p_id::text,'kind',p_kind,'id',p_id,'category',p_category,
 'title',coalesce(p_title,''),'metadata',p_metadata,'updated_at',p_updated,'collection_id',null,'collection_name',null,
 'entry_id',null,'document_id',null,'legacy_key',null,'metadata_state','recorded','file_state','unknown','processing_state','unknown','review_state','unknown')||p_extra;

-- Only this projection reads private entries. It independently enforces identity
-- and row permissions; an editor role never substitutes for collection access.
create function private.kb_catalogue_registered_v1() returns setof jsonb
language plpgsql stable security definer set search_path=pg_catalog as $$
declare actor uuid:=private.kb_metadata_actor_v1();
begin
 return query
 with entries as materialized (
   select e.*,c.name as collection_name,c.metadata_schema_json,
     e.source_metadata||e.manual_overrides as effective
   from private.kb_resource_entries e join public.kb_collections c on c.id=e.collection_id
   where public.can_collection_action(actor,c.id,'read')
 ), docs as materialized (
   select d.*,
     case when public.can_collection_action(actor,c.id,'read') then c.id end as visible_collection_id,
     case when public.can_collection_action(actor,c.id,'read') then c.name end as collection_name,
     case when public.can_collection_action(actor,c.id,'read') then c.metadata_schema_json else '{}'::jsonb end as metadata_schema_json
   from public.kb_documents d join public.kb_collections c on c.id=d.primary_collection_id
   where d.deleted_at is null and d.status<>'deleted' and public.can_document_action(actor,d.id,'read')
 ), material_rows as (
   select private.kb_catalogue_row_v1('material',e.id,
    private.kb_catalogue_category_v1(e.metadata_schema_json->>'catalogue_category',e.legacy_ref->>'table'),
    coalesce(e.effective->>'title',e.effective->>'name',e.effective->>'report_title'),e.effective,e.updated_at,
    jsonb_build_object('collection_id',e.collection_id,'collection_name',e.collection_name,'entry_id',e.id,
      'legacy_key',case when e.legacy_ref is not null then (e.legacy_ref->>'table')||':'||lower(e.legacy_ref->>'id') end,
      'metadata_state',case when exists(select from jsonb_array_elements_text(e.profile_json->'required_fields') f
        where e.effective->f is null or e.effective->f='null'::jsonb or e.effective->>f='') then 'pending' else 'complete' end,
      'file_state',case when e.candidates<>'{}'::jsonb then 'associated' when d.id is not null then 'registered' else 'missing' end,'review_state',e.review_state,
      'document_id',d.id,'processing_state',case when d.id is null then 'unknown'
        when d.status='completed' and d.opensearch_indexed and d.pinecone_indexed then 'ready'
        when d.status in ('failed','s3_ready_check_failed') then 'failed' else 'processing' end)) as body
   from entries e left join private.kb_resource_document_links l on l.entry_id=e.id and l.active
    left join docs d on d.id=l.document_id
 )
 select body from material_rows
 union all
 select private.kb_catalogue_row_v1('document',d.id,private.kb_catalogue_category_v1(d.metadata_schema_json->>'catalogue_category',null),
   d.original_filename,coalesce(d.metadata_json,'{}'::jsonb),d.updated_at,
   jsonb_build_object('collection_id',d.visible_collection_id,'collection_name',d.collection_name,'document_id',d.id,
     'file_state','registered','metadata_state','unknown','processing_state',case
       when d.status='completed' and d.opensearch_indexed and d.pinecone_indexed then 'ready'
       when d.status in ('failed','s3_ready_check_failed') then 'failed' else 'processing' end))
 from docs d where not exists(select from material_rows m where m.body->>'document_id'=d.id::text);
end $$;

-- Retain the existing explicit Green Deal editor read capability. Ordinary
-- Green Deal rows below still use RLS; UNION removes exact overlap.
create function private.kb_catalogue_policy_editors_v1() returns setof public.green_deal_meta
language plpgsql stable security definer set search_path=pg_catalog as $$
declare actor uuid:=private.kb_metadata_actor_v1();
begin
 if exists(select from private.kb_metadata_editors where actor_id=actor and resource='greenDeal'
   and revoked_at is null and (expires_at is null or expires_at>statement_timestamp())) then
   return query select * from public.green_deal_meta;
 end if;
end $$;

-- SQL-standard bodies bind helper OIDs at creation. authenticated does NOT
-- receive private schema USAGE. Legacy reads execute as caller and retain RLS.
create function private.kb_catalogue_rows_v1() returns setof jsonb
language sql stable security invoker set search_path=pg_catalog
begin atomic;
 with registered as materialized (select body from private.kb_catalogue_registered_v1() as r(body)), legacy as (
select private.kb_catalogue_row_v1('journals',t.id,'journals',t.title,jsonb_build_object('title',t.title,'doi',t.doi,'journal',t.journal,'authors',t.authors,'date',t.date,'abstract',t.abstract),t.created_at,jsonb_build_object('legacy_key','journals:'||t.id::text)) as body from public.journals t
 union all
 select private.kb_catalogue_row_v1('education',t.id,'education',t.name,jsonb_build_object('name',t.name,'course',t.course,'chapter_number',t.chapter_number,'description',t.description,'language',t.language,'type',t.type),t.upload_time,jsonb_build_object('legacy_key','edu_meta:'||t.id::text)) as body from public.edu_meta t
 union all
 select private.kb_catalogue_row_v1('esg',t.id,'esg',t.report_title,jsonb_build_object('report_title',t.report_title,'company_name',t.company_name,'company_name_en',t.company_name_en,'country',t.country,'publication_date',t.publication_date,'language',t.language),t.last_updated_time,jsonb_build_object('legacy_key','esg_meta:'||t.id::text)) as body from public.esg_meta t
 union all
 select private.kb_catalogue_row_v1('standards',t.id,'standards',t.title,jsonb_build_object('title',t.title,'standard_number',t.standard_number,'issuing_organization',t.issuing_organization,'language',t.language,'effective_date',t.effective_date,'expiration_date',t.expiration_date),t.last_updated_time,jsonb_build_object('legacy_key','standards:'||t.id::text)) as body from public.standards t
 union all
 select private.kb_catalogue_row_v1('reports',t.id,'reports',t.title,jsonb_build_object('title',t.title,'issuing_organization',t.issuing_organization,'release_date',t.release_date,'language',t.language),t.uploaded_time,jsonb_build_object('legacy_key','reports:'||t.id::text)) as body from public.reports t
 union all
 select private.kb_catalogue_row_v1('internalUse',t.id,'other',t.title,jsonb_build_object('title',t.title,'tag',t.tag,'language',t.language,'file_type',t.file_type),t.created_time,jsonb_build_object('legacy_key','internal_use:'||t.id::text)) as body from public.internal_use t
 union all
 select private.kb_catalogue_row_v1('greenDeal',t.id,'policies',t.title,jsonb_build_object('title',t.title,'celex_number',t.celex_number,'issue_agency',t.issue_agency,'publish_date',t.publish_date),t.last_updated_time,jsonb_build_object('legacy_key','green_deal_meta:'||t.id::text)) from (select * from public.green_deal_meta union select * from private.kb_catalogue_policy_editors_v1()) t
 ) select * from registered
 union all
 select body from legacy l where not exists(select from registered r where r.body->>'legacy_key'=l.body->>'legacy_key');
end;

create function api.kb_catalogue_v1(p_query jsonb default '{}') returns jsonb
language sql stable security invoker set search_path=pg_catalog
begin atomic;
 with q as materialized (select private.kb_catalogue_query_v1(p_query) as v),
 all_rows as materialized (select r.body from q cross join lateral private.kb_catalogue_rows_v1() as r(body) where q.v is not null),
 filtered as materialized (
   select r.body as body from all_rows r,q
   where (q.v->>'category'='all' or r.body->>'category'=q.v->>'category')
    and (not q.v ? 'collection' or r.body->>'collection_id'=q.v->>'collection')
    and (not q.v ? 'key' or r.body->>'key'=q.v->>'key')
    and strpos(lower((r.body->'metadata')::text||' '||(r.body->>'title')),lower(q.v->>'q'))>0
    and case q.v->>'state' when 'associated' then r.body->>'file_state' in ('associated','registered') when 'missing' then r.body->>'file_state'='missing'
      when 'pending' then r.body->>'metadata_state'='pending'
      when 'review' then r.body->>'review_state'='pending'
      when 'failed' then r.body->>'processing_state'='failed'
      when 'ready' then r.body->>'processing_state'='ready'
      when 'unknown' then r.body->>'file_state'='unknown' else true end
 ), page_rows as (
   select body from filtered order by (body->>'updated_at')::timestamptz desc nulls last,body->>'key'
   limit (select (v->>'page_size')::int from q) offset (select ((v->>'page')::int-1)*(v->>'page_size')::int from q)
 ), groups as (
   select body->>'category' category,count(*) total,
     count(*) filter(where body->>'file_state' in ('associated','registered')) associated,
     count(*) filter(where body->>'processing_state'='ready') ready
   from filtered group by body->>'category'
 )
 select jsonb_build_object('version',1,'page',(q.v->>'page')::int,'page_size',(q.v->>'page_size')::int,
   'total',(select count(*) from filtered),'rows',coalesce((select jsonb_agg(body order by (body->>'updated_at')::timestamptz desc nulls last,body->>'key') from page_rows),'[]'),
   'groups',coalesce((select jsonb_agg(to_jsonb(groups) order by category) from groups),'[]'),
   'metrics',jsonb_build_object('associated',(select count(*) from filtered where body->>'file_state' in ('associated','registered')),
     'ready',(select count(*) from filtered where body->>'processing_state'='ready'),
     'missing',(select count(*) from filtered where body->>'file_state'='missing'),
     'unknown',(select count(*) from filtered where body->>'file_state'='unknown')),
   'observed_at',statement_timestamp()) from q;
end;

revoke all on function private.kb_catalogue_query_v1(jsonb) from public,anon,authenticated,service_role;
grant execute on function private.kb_catalogue_query_v1(jsonb) to authenticated;

revoke all on function private.kb_catalogue_category_v1(text,text) from public,anon,authenticated,service_role;
grant execute on function private.kb_catalogue_category_v1(text,text) to authenticated;

revoke all on function private.kb_catalogue_row_v1(text,uuid,text,text,jsonb,timestamptz,jsonb) from public,anon,authenticated,service_role;
grant execute on function private.kb_catalogue_row_v1(text,uuid,text,text,jsonb,timestamptz,jsonb) to authenticated;

revoke all on function private.kb_catalogue_registered_v1() from public,anon,authenticated,service_role;
grant execute on function private.kb_catalogue_registered_v1() to authenticated;

revoke all on function private.kb_catalogue_policy_editors_v1() from public,anon,authenticated,service_role;
grant execute on function private.kb_catalogue_policy_editors_v1() to authenticated;

revoke all on function private.kb_catalogue_rows_v1() from public,anon,authenticated,service_role;
grant execute on function private.kb_catalogue_rows_v1() to authenticated;

revoke all on function api.kb_catalogue_v1(jsonb) from public,anon,authenticated,service_role;
grant execute on function api.kb_catalogue_v1(jsonb) to authenticated;

notify pgrst, 'reload schema';
commit;
