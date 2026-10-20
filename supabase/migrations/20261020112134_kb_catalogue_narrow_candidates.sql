-- #28: narrow registered candidates and page-only JSON hydration.
-- Forward-only function replacement: no data, indexes, UUIDs or grants rewritten.
begin;
set local lock_timeout='5s';
set local statement_timeout='1min';
create function private.kb_catalogue_registered_keys_v1(p_identifier_query jsonb default null)
returns table(kind text,id uuid,category text,updated_at timestamptz,collection_id uuid,
 legacy_key text,metadata_state text,file_state text,review_state text,document_id uuid,
 processing_state text,identifier_match boolean)
language plpgsql stable security definer set search_path=pg_catalog as $$
declare actor uuid:=private.kb_metadata_actor_v1();
begin
 return query
 with principals as materialized (
   select * from public.kb_actor_principals(actor)
 ), readable_collections as materialized (
   select c.id,c.metadata_schema_json from public.kb_collections c where public.can_collection_action(actor,c.id,'read')
 ), direct_documents as materialized (
   select distinct g.resource_id from public.kb_grants g join principals p
     on p.principal_type=g.principal_type and p.principal_id=g.principal_id
   where g.resource_type='document' and g.effect='allow' and g.revoked_at is null
     and (g.expires_at is null or g.expires_at>now())
     and g.actions && array['read','manage']::public.kb_grant_action[]
 ), entries as materialized (
   select e.id,e.collection_id,e.updated_at,
     private.kb_catalogue_category_v1(c.metadata_schema_json->>'catalogue_category',e.legacy_ref->>'table') category,
     case when e.legacy_ref is not null then (e.legacy_ref->>'table')||':'||lower(e.legacy_ref->>'id') end legacy_key,
     case when exists(select from jsonb_array_elements_text(e.profile_json->'required_fields') f
       where (e.source_metadata||e.manual_overrides)->f is null
         or (e.source_metadata||e.manual_overrides)->f='null'::jsonb
         or (e.source_metadata||e.manual_overrides)->>f='') then 'pending' else 'complete' end metadata_state,
     e.candidates<>'{}'::jsonb has_candidate,e.review_state,
     case when p_identifier_query is not null and private.kb_catalogue_category_v1(c.metadata_schema_json->>'catalogue_category',e.legacy_ref->>'table')=p_identifier_query->>'category' then
       case p_identifier_query->>'category' when 'journals' then
         lower(regexp_replace(btrim((e.source_metadata||e.manual_overrides)->>'doi'),'^(https?://(dx\.)?doi\.org/|doi:\s*)','','i'))=p_identifier_query->>'identifier'
       else lower(btrim((e.source_metadata||e.manual_overrides)->>'standard_number'))=p_identifier_query->>'identifier' end
     else false end identifier_match
   from private.kb_resource_entries e join readable_collections c on c.id=e.collection_id
 ), docs as materialized (
   -- No full row, filename or metadata value is carried through count/sort.
   -- Exact identifier matching extracts only the requested field, only in its category.
   select d.id,d.updated_at,rc.id collection_id,
     private.kb_catalogue_category_v1(rc.metadata_schema_json->>'catalogue_category',null) category,
     case when d.status='completed' and d.opensearch_indexed and d.pinecone_indexed then 'ready'
       when d.status in ('failed','s3_ready_check_failed') then 'failed' else 'processing' end processing_state,
     case when p_identifier_query is not null and private.kb_catalogue_category_v1(rc.metadata_schema_json->>'catalogue_category',null)=p_identifier_query->>'category' then
       case p_identifier_query->>'category' when 'journals' then
         lower(regexp_replace(btrim(d.metadata_json->>'doi'),'^(https?://(dx\.)?doi\.org/|doi:\s*)','','i'))=p_identifier_query->>'identifier'
       else lower(btrim(d.metadata_json->>'standard_number'))=p_identifier_query->>'identifier' end
     else false end identifier_match
   from public.kb_documents d join public.kb_collections c on c.id=d.primary_collection_id
   left join readable_collections rc on rc.id=c.id
   where d.deleted_at is null and d.status<>'deleted'
     and (rc.id is not null or d.created_by=actor or d.owner_user_id=actor or d.visibility='public'
       or d.id in (select resource_id from direct_documents))
 ), material_keys as materialized (
   select 'material'::text kind,e.id,e.category,e.updated_at,e.collection_id,e.legacy_key,e.metadata_state,
     case when e.has_candidate then 'associated' when d.id is not null then 'registered' else 'missing' end file_state,
     e.review_state::text,d.id document_id,case when d.id is null then 'unknown'
       when d.status='completed' and d.opensearch_indexed and d.pinecone_indexed then 'ready'
       when d.status in ('failed','s3_ready_check_failed') then 'failed' else 'processing' end processing_state,e.identifier_match
   from entries e left join private.kb_resource_document_links l on l.entry_id=e.id and l.active
     -- Probe the linked primary key instead of repeatedly scanning the full
     -- materialized docs CTE when cardinality statistics are stale.
     left join public.kb_documents d on d.id=l.document_id and d.deleted_at is null and d.status<>'deleted'
       and (d.primary_collection_id in (select c.id from readable_collections c)
         or d.created_by=actor or d.owner_user_id=actor or d.visibility='public'
         or d.id in (select resource_id from direct_documents))
 )
 select m.* from material_keys m
 union all
 select 'document',d.id,d.category,d.updated_at,d.collection_id,null::text,'unknown','registered','unknown',d.id,d.processing_state,d.identifier_match
 from docs d where d.id not in
   (select m.document_id from material_keys m where m.document_id is not null);
end $$;

create function private.kb_catalogue_registered_page_v1(p_kind text,p_id uuid) returns setof jsonb
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
   where p_kind='material' and e.id=p_id
 ), docs as materialized (
   select d.*,
     rc.id as visible_collection_id,
     rc.name as collection_name,
     coalesce(rc.metadata_schema_json,'{}'::jsonb) as metadata_schema_json
   from public.kb_documents d join public.kb_collections c on c.id=d.primary_collection_id
   left join readable_collections rc on rc.id=c.id
   where d.deleted_at is null and d.status<>'deleted'
     and d.id in (
       select p_id where p_kind='document'
       union all
       select l.document_id from private.kb_resource_document_links l
         where p_kind='material' and l.entry_id=p_id and l.active)
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
 from docs d where p_kind='document' and not exists(
   select from private.kb_resource_document_links l join private.kb_resource_entries e on e.id=l.entry_id
   join readable_collections c on c.id=e.collection_id where l.active and l.document_id=d.id);
end $$;


create or replace function api.kb_catalogue_v1(p_query jsonb default '{}') returns jsonb
language sql stable security invoker set search_path=pg_catalog
begin atomic;
 with q as materialized (select private.kb_catalogue_query_v1(p_query) as v),
 -- Deduplication uses ALL visible registered rows, before display filters.
 registered as materialized (select r.* from q cross join lateral private.kb_catalogue_registered_keys_v1() r where q.v is not null),
 filtered as materialized (
   select r.kind as kind,r.id as id,
     r.category as category,r.updated_at as updated_at,
     r.file_state as file_state,r.processing_state as processing_state
   from registered r,q
   where (q.v->>'category'='all' or r.category=q.v->>'category')
    and (not q.v ? 'collection' or r.collection_id::text=q.v->>'collection')
    and (not q.v ? 'key' or r.kind||':'||r.id::text=q.v->>'key')
    and case q.v->>'state' when 'associated' then r.file_state in ('associated','registered') when 'missing' then r.file_state='missing'
      when 'pending' then r.metadata_state='pending'
      when 'review' then r.review_state='pending'
      when 'failed' then r.processing_state='failed'
      when 'ready' then r.processing_state='ready'
      when 'unknown' then r.file_state='unknown' else true end
   union all
   select l.kind,l.id,l.category,l.updated_at,'unknown','unknown'
   from q cross join lateral private.kb_catalogue_legacy_v1(q.v,false) l
   where not exists(select from registered r where r.legacy_key=l.legacy_key)
 ), page_keys as materialized (
   select * from filtered order by updated_at desc nulls last,kind,id
   limit (select (v->>'page_size')::int from q) offset (select ((v->>'page')::int-1)*(v->>'page_size')::int from q)
 ), page_rows as (
   select p.kind,p.id,p.updated_at,r.body
   from page_keys p cross join lateral private.kb_catalogue_registered_page_v1(p.kind,p.id) r(body)
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


create or replace function api.kb_catalogue_identifier_v1(p_query jsonb) returns jsonb
language sql stable security invoker set search_path=pg_catalog
begin atomic;
 with q as materialized (select private.kb_catalogue_identifier_query_v1(p_query) v),
 registered as materialized (
   select r.* from q cross join lateral private.kb_catalogue_registered_keys_v1(q.v) r where q.v is not null
 ), source_matches as materialized (
   -- Invoker SELECT/RLS runs before identifiers contribute to counts or links.
   select 'journals'::text kind,t.id,t.created_at updated_at,'journals:'||t.id::text legacy_key
   from q join public.journals t on q.v->>'category'='journals'
     and lower(regexp_replace(btrim(t.doi),'^(https?://(dx\.)?doi\.org/|doi:\s*)','','i'))=q.v->>'identifier'
   union all
   select 'standards',t.id,t.last_updated_time,'standards:'||t.id::text
   from q join public.standards t on q.v->>'category'='standards'
     and lower(btrim(t.standard_number))=q.v->>'identifier'
 ), matched_registered as materialized (
   select r.* from registered r,q
   where r.category=q.v->>'category'
     and (not q.v ? 'collection' or r.collection_id::text=q.v->>'collection')
     and (
       r.identifier_match
       or exists(select from source_matches s where s.legacy_key=r.legacy_key)
     )
     and case q.v->>'state' when 'associated' then r.file_state in ('associated','registered')
       when 'missing' then r.file_state='missing' when 'pending' then r.metadata_state='pending'
       when 'review' then r.review_state='pending' when 'failed' then r.processing_state='failed'
       when 'ready' then r.processing_state='ready' when 'unknown' then r.file_state='unknown' else true end
 ), candidates as materialized (
   select kind,id,updated_at,file_state,processing_state from matched_registered
   union all
   select s.kind,s.id,s.updated_at,'unknown','unknown' from source_matches s,q
   where not q.v ? 'collection' and q.v->>'state' in ('all','unknown')
     and not exists(select from registered r where r.legacy_key=s.legacy_key)
 ), page_keys as materialized (
   select * from candidates order by updated_at desc nulls last,kind,id
   limit (select (v->>'page_size')::int from q) offset (select ((v->>'page')::int-1)*(v->>'page_size')::int from q)
 ), page_rows as (
   select p.kind,p.id,p.updated_at,r.body from page_keys p cross join lateral private.kb_catalogue_registered_page_v1(p.kind,p.id) r(body)
   where p.kind in ('material','document')
   union all
   select p.kind,p.id,p.updated_at,l.body from page_keys p
   cross join lateral private.kb_catalogue_legacy_v1(
     jsonb_build_object('category',p.kind,'state','all','q','','key',p.kind||':'||p.id::text),true) l
   where p.kind in ('journals','standards')
 ), metrics as (
   select count(*) total,count(*) filter(where file_state in ('associated','registered')) associated,
     count(*) filter(where processing_state='ready') ready,count(*) filter(where file_state='missing') missing,
     count(*) filter(where file_state='unknown') unknown from candidates
 )
 select jsonb_build_object('version',1,'page',(q.v->>'page')::int,'page_size',(q.v->>'page_size')::int,
   'total',m.total,'rows',coalesce((select jsonb_agg(body order by updated_at desc nulls last,kind,id) from page_rows),'[]'),
   'groups',case when m.total=0 then '[]'::jsonb else jsonb_build_array(jsonb_build_object('category',q.v->>'category','total',m.total,'associated',m.associated,'ready',m.ready)) end,
   'metrics',jsonb_build_object('associated',m.associated,'ready',m.ready,'missing',m.missing,'unknown',m.unknown),
   'observed_at',statement_timestamp()) from q cross join metrics m;
end;

revoke all on function private.kb_catalogue_registered_keys_v1(jsonb),private.kb_catalogue_registered_page_v1(text,uuid) from public,anon,authenticated,service_role;
grant execute on function private.kb_catalogue_registered_keys_v1(jsonb),private.kb_catalogue_registered_page_v1(text,uuid) to authenticated;
notify pgrst,'reload schema';
commit;
