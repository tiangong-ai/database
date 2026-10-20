-- Batch catalogue authorization without changing the canonical single-row helpers.
begin;
create or replace function private.kb_catalogue_registered_v1() returns setof jsonb
language plpgsql stable security definer set search_path=pg_catalog as $$
declare actor uuid:=private.kb_metadata_actor_v1();
begin
 return query
 with principals as materialized (
   select * from public.kb_actor_principals(actor)
 ), readable_collections as materialized (
   select c.* from public.kb_collections c where public.can_collection_action(actor,c.id,'read')
 ), direct_documents as materialized (
   select distinct g.resource_id from public.kb_grants g join principals p
     on p.principal_type=g.principal_type and p.principal_id=g.principal_id
   where g.resource_type='document' and g.effect='allow' and g.revoked_at is null
     and (g.expires_at is null or g.expires_at>now())
     and g.actions && array['read','manage']::public.kb_grant_action[]
 ), entries as materialized (
   select e.*,c.name as collection_name,c.metadata_schema_json,
     e.source_metadata||e.manual_overrides as effective
   from private.kb_resource_entries e join readable_collections c on c.id=e.collection_id
 ), docs as materialized (
   select d.*,
     rc.id as visible_collection_id,
     rc.name as collection_name,
     coalesce(rc.metadata_schema_json,'{}'::jsonb) as metadata_schema_json
   from public.kb_documents d join public.kb_collections c on c.id=d.primary_collection_id
   left join readable_collections rc on rc.id=c.id
   where d.deleted_at is null and d.status<>'deleted'
     and (rc.id is not null or d.created_by=actor or d.owner_user_id=actor or d.visibility='public'
       or d.id in (select resource_id from direct_documents))
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

-- Keep sort/count intermediates narrow: UUID keys, no full JSON per candidate.
create or replace function api.kb_catalogue_v1(p_query jsonb default '{}') returns jsonb
language sql stable security invoker set search_path=pg_catalog
begin atomic;
 with q as materialized (select private.kb_catalogue_query_v1(p_query) as v),
 -- Deduplication uses ALL visible registered rows, before display filters.
 registered as materialized (select r.body from q cross join lateral private.kb_catalogue_registered_v1() r(body) where q.v is not null),
 filtered as materialized (
   select r.body->>'kind' as kind,(r.body->>'id')::uuid as id,
     r.body->>'category' as category,(r.body->>'updated_at')::timestamptz as updated_at,
     r.body->>'file_state' as file_state,r.body->>'processing_state' as processing_state
   from registered r,q
   where (q.v->>'category'='all' or r.body->>'category'=q.v->>'category')
    and (not q.v ? 'collection' or r.body->>'collection_id'=q.v->>'collection')
    and (not q.v ? 'key' or r.body->>'key'=q.v->>'key')
    and (q.v->>'q'='' or strpos(lower((r.body->'metadata')::text||' '||(r.body->>'title')),lower(q.v->>'q'))>0)
    and case q.v->>'state' when 'associated' then r.body->>'file_state' in ('associated','registered') when 'missing' then r.body->>'file_state'='missing'
      when 'pending' then r.body->>'metadata_state'='pending'
      when 'review' then r.body->>'review_state'='pending'
      when 'failed' then r.body->>'processing_state'='failed'
      when 'ready' then r.body->>'processing_state'='ready'
      when 'unknown' then r.body->>'file_state'='unknown' else true end
   union all
   select l.kind,l.id,l.category,l.updated_at,'unknown','unknown'
   from q cross join lateral private.kb_catalogue_legacy_v1(q.v,false) l
   where not exists(select from registered r where r.body->>'legacy_key'=l.legacy_key)
 ), page_keys as materialized (
   select * from filtered order by updated_at desc nulls last,kind,id
   limit (select (v->>'page_size')::int from q) offset (select ((v->>'page')::int-1)*(v->>'page_size')::int from q)
 ), page_rows as (
   select p.kind,p.id,p.updated_at,r.body
   from page_keys p join registered r on r.body->>'kind'=p.kind and (r.body->>'id')::uuid=p.id
   where p.kind in ('material','document')
   union all
   select p.kind,p.id,p.updated_at,l.body
   from page_keys p cross join lateral private.kb_catalogue_legacy_v1(
     jsonb_build_object('category',p.category,'state','all','q','','key',p.kind||':'||p.id::text),true) l
   where p.kind not in ('material','document')
 ), groups as (
   select category,count(*) total,
     count(*) filter(where file_state in ('associated','registered')) associated,
     count(*) filter(where processing_state='ready') ready
   from filtered group by category
 ), metrics as (
   select count(*) total,count(*) filter(where file_state in ('associated','registered')) associated,
     count(*) filter(where processing_state='ready') ready,count(*) filter(where file_state='missing') missing,
     count(*) filter(where file_state='unknown') unknown from filtered
 )
 select jsonb_build_object('version',1,'page',(q.v->>'page')::int,'page_size',(q.v->>'page_size')::int,
   'total',metrics.total,'rows',coalesce((select jsonb_agg(body order by updated_at desc nulls last,kind,id) from page_rows),'[]'),
   'groups',coalesce((select jsonb_agg(to_jsonb(groups) order by category) from groups),'[]'),
   'metrics',jsonb_build_object('associated',metrics.associated,'ready',metrics.ready,'missing',metrics.missing,'unknown',metrics.unknown),
   'observed_at',statement_timestamp()) from q cross join metrics;
end;

notify pgrst, 'reload schema';
commit;
