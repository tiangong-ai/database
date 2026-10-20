-- Owned disposable database only. Synthetic 1.5m x 1900-byte abstracts.
-- Ten percent use varied high-entropy text to avoid an all-identical TOAST fixture.
-- Exact counts, deep paging, routing and page hydration; never production data.
begin;
-- Earlier consumer gates retain synthetic rows. Isolate this fixture inside the
-- rollback, then restore every earlier fixture; the runner owns the whole DB.
truncate public.journals,public.edu_meta,public.esg_meta,public.standards,
 public.reports,public.internal_use,public.green_deal_meta,
 private.kb_resource_entries,public.kb_documents cascade;
insert into auth.users(id,role) values(md5('catalogue-capacity-actor')::uuid,'authenticated');
-- This is a read-capacity fixture, not a per-row ingestion benchmark. Bulk-load
-- the disposable projection with its canonical encoder, then build its index
-- and filter. The smoke/concurrency gates separately exercise real source writes.
-- All trigger/DDL changes are inside this rollback-only transaction.
alter table public.journals disable trigger kb_catalogue_journal_search_sync;
alter table private.kb_catalogue_journal_search disable trigger kb_catalogue_short_filter_sync;
drop index private.kb_catalogue_journal_search_trgm_idx;
with varied as materialized (
 select v,left(string_agg(md5(v::text||':'||part::text),'' order by part),1900) abstract
 from generate_series(0,999)v cross join generate_series(1,60)part group by v
)
insert into public.journals(id,doi,title,abstract)
select md5('catalogue-capacity-'||s)::uuid,'10.000/capacity-'||s,
 'Synthetic article '||s,case when s%10=0 then varied.abstract else repeat('synthetic abstract ',100) end
 from generate_series(1,1500000)s join varied on varied.v=s%1000;
insert into private.kb_catalogue_journal_search(id,search_text)
 -- Same encoder expression, avoiding the large statement's per-row SQL wrapper
 -- memory growth. Ordinary source-write tests still use the real trigger/helper.
 select id,lower(jsonb_build_object('title',title,'doi',doi,'journal',journal,'authors',authors,'date',date,'abstract',abstract)::text||' '||coalesce(title,'')) from public.journals;
do $$ begin
 assert not exists(
   select from (select * from public.journals order by id limit 1000) j
   join private.kb_catalogue_journal_search s using(id)
   where s.search_text<>private.kb_catalogue_journal_text_v1(j.title,j.doi,j.journal,j.authors,j.date,j.abstract)
 ),'Bulk fixture encoding matches the canonical source-write helper';
end $$;
create index kb_catalogue_journal_search_trgm_idx on private.kb_catalogue_journal_search
 using gin(search_text extensions.gin_trgm_ops);
set local max_parallel_workers_per_gather=2;
set local min_parallel_table_scan_size=0;
set local parallel_setup_cost=0;
set local parallel_tuple_cost=0;
create temporary table capacity_short_filter on commit drop as
 select id,private.kb_catalogue_short_signature_v1(search_text)::bit(1024) signature
 from private.kb_catalogue_journal_search;
insert into private.kb_catalogue_journal_short_filter select * from capacity_short_filter;
drop table capacity_short_filter;
alter table private.kb_catalogue_journal_search enable trigger kb_catalogue_short_filter_sync;
alter table public.journals enable trigger kb_catalogue_journal_search_sync;
-- Restore ordinary request planner settings before measuring query latency.
set local max_parallel_workers_per_gather to default;
set local min_parallel_table_scan_size to default;
set local parallel_setup_cost to default;
set local parallel_tuple_cost to default;
analyze public.journals;
analyze private.kb_catalogue_journal_search;
analyze private.kb_catalogue_journal_short_filter;
-- Mixed registered population: creator, collection, group/subtree, public and
-- direct-document reads, plus 9,900 denied rows. No production rows are copied.
insert into public.kb_groups(id,name,created_by)
 values(md5('capacity-group')::uuid,'capacity group',md5('catalogue-capacity-actor')::uuid);
insert into public.kb_group_members(group_id,user_id)
 values(md5('capacity-group')::uuid,md5('catalogue-capacity-actor')::uuid);
insert into public.kb_collections(id,name,path)
select md5('capacity-collection-'||s)::uuid,'capacity collection '||s,
 case when s=4 then '/capacity/3/4' else '/capacity/'||s end from generate_series(1,6)s;
insert into public.kb_grants(resource_type,resource_id,principal_type,principal_id,actions,created_by)
values
 ('collection',md5('capacity-collection-2')::uuid,'user',md5('catalogue-capacity-actor')::uuid,array['read']::public.kb_grant_action[],md5('catalogue-capacity-actor')::uuid),
 ('subtree',md5('capacity-collection-3')::uuid,'group',md5('capacity-group')::uuid,array['manage']::public.kb_grant_action[],md5('catalogue-capacity-actor')::uuid);
insert into public.kb_documents(id,primary_collection_id,dedupe_scope,original_filename,sha256,created_by,owner_user_id,visibility,metadata_json)
select md5('capacity-document-'||s)::uuid,md5('capacity-collection-'||((s-1)/10000+1))::uuid,
 'capacity', 'Synthetic document '||s||'.pdf',s::text,
 case when s<=10000 then md5('catalogue-capacity-actor')::uuid else md5('capacity-other')::uuid end,
 md5('capacity-other')::uuid,
 case when s between 40001 and 50000 then 'public' else 'private' end::public.kb_document_visibility,
 jsonb_build_object('description',repeat('synthetic document metadata ',70))
from generate_series(1,60000)s;
insert into public.kb_grants(resource_type,resource_id,principal_type,principal_id,actions,created_by)
select 'document',md5('capacity-document-'||s)::uuid,'user',md5('catalogue-capacity-actor')::uuid,
 array['read']::public.kb_grant_action[],md5('catalogue-capacity-actor')::uuid from generate_series(50001,50100)s;
-- Explicit links suppress both an accessible legacy source and its document,
-- even when later category/state/key/search filters hide the material row.
insert into private.kb_resource_entries(id,collection_id,primary_source_binding_id,external_key,profile_json,metadata_mode,legacy_ref,source_metadata)
select md5('capacity-entry-'||s)::uuid,md5('capacity-collection-2')::uuid,'capacity',s::text,
 '{"required_fields":["title"]}', 'legacy_ref',jsonb_build_object('table','journals','id',md5('catalogue-capacity-'||s)::uuid),
 jsonb_build_object('title','Synthetic material '||s) from generate_series(1,1000)s;
insert into private.kb_resource_document_links(entry_id,document_id,content_revision,active,publish_state,approved_revision,candidate_json,metadata_snapshot,effective_metadata_revision)
select md5('capacity-entry-'||s)::uuid,md5('capacity-document-'||(s+10000))::uuid,1,true,'published',1,'{}','{}',1 from generate_series(1,1000)s;
analyze private.kb_resource_entries;
analyze private.kb_resource_document_links;
analyze public.kb_documents;
analyze public.kb_collections;
analyze public.kb_grants;

select jsonb_build_object('projection_rows',(select count(*) from private.kb_catalogue_journal_search),'projection_table_bytes_including_toast',pg_table_size('private.kb_catalogue_journal_search'),'projection_index_bytes',pg_indexes_size('private.kb_catalogue_journal_search'),'projection_total_bytes',pg_total_relation_size('private.kb_catalogue_journal_search')) as capacity_storage;
select jsonb_build_object('short_filter_rows',(select count(*) from private.kb_catalogue_journal_short_filter),'short_filter_total_bytes',pg_total_relation_size('private.kb_catalogue_journal_short_filter')) as short_filter_storage;
set local statement_timeout='8s';
-- Exercise parameter-independent plans used by reused PostgREST statements.
set local plan_cache_mode=force_generic_plan;
set local role authenticated;
select set_config('request.jwt.claims',jsonb_build_object('sub',md5('catalogue-capacity-actor')::uuid,'role','authenticated')::text,true);
\timing on
-- Each statement is independently bounded, including the deepest allowed page.
do $$ declare result jsonb; begin
 result:=api.kb_catalogue_v1('{}');
 assert (result->>'total')::bigint=1549100, 'Exact visible count';
 assert result->'groups'='[{"category":"journals","total":1500000,"associated":1000,"ready":0},{"category":"other","total":49100,"associated":49100,"ready":0}]'::jsonb, 'Category counts';
 assert result->'metrics'='{"associated":50100,"ready":0,"missing":0,"unknown":1499000}'::jsonb, 'Unknown is not missing';
 assert jsonb_array_length(result->'rows')=20, 'Bounded hydrated page';
 assert result->'rows'->0->'metadata'->>'description'=repeat('synthetic document metadata ',70), 'Selected registered metadata hydrated';
end $$;
do $$ declare before_scan bigint; before_fetch bigint; before_index bigint; result jsonb; begin
 select seq_tup_read,idx_tup_fetch,idx_scan into before_scan,before_fetch,before_index from pg_stat_xact_user_tables where relid='public.journals'::regclass;
 result:=api.kb_catalogue_v1('{"category":"esg"}');
 assert (result->>'total')::int=0 and result->'rows'='[]'::jsonb, 'Empty unrelated category';
 assert (select seq_tup_read=before_scan and idx_tup_fetch=before_fetch and idx_scan=before_index from pg_stat_xact_user_tables where relid='public.journals'::regclass), 'Empty ESG must not read journals';
end $$;
do $$ declare before_scan bigint; before_fetch bigint; before_index bigint; result jsonb; begin
 select seq_tup_read,idx_tup_fetch,idx_scan into before_scan,before_fetch,before_index from pg_stat_xact_user_tables where relid='public.journals'::regclass;
 result:=api.kb_catalogue_v1(jsonb_build_object('key','journals:'||md5('catalogue-capacity-1001')::uuid));
 assert (result->>'total')::int=1 and result->'rows'->0->>'title'='Synthetic article 1001', 'Exact detail';
 assert (select seq_tup_read=before_scan and idx_tup_fetch>before_fetch and idx_tup_fetch-before_fetch<=2 and idx_scan>before_index and idx_scan-before_index<=2 from pg_stat_xact_user_tables where relid='public.journals'::regclass), 'Detail must use bounded primary key lookups';
end $$;
do $$ declare result jsonb; begin
 result:=api.kb_catalogue_v1('{"key":"journals:00000000-0000-4000-8000-000000000001"}');
 assert (result->>'total')::int=0 and result->'rows'='[]'::jsonb, 'Missing keyed detail';
end $$;
do $$ declare result jsonb; expected jsonb; begin
 result:=api.kb_catalogue_v1('{"category":"journals","state":"unknown","page":2,"page_size":50}');
 select jsonb_agg(id::text order by id) into expected from (select id from public.journals where id not in (select md5('catalogue-capacity-'||s)::uuid from generate_series(1,1000)s) order by id limit 50 offset 50) p;
 assert (result->>'total')::int=1499000 and jsonb_array_length(result->'rows')=50, 'next page count';
 assert (select jsonb_agg(r->>'id' order by ordinal) from jsonb_array_elements(result->'rows') with ordinality x(r,ordinal))=expected, 'next page identities and order';
end $$;
do $$ declare result jsonb; expected jsonb; begin
 result:=api.kb_catalogue_v1('{"category":"journals","state":"unknown","page":10000,"page_size":50}');
 select jsonb_agg(id::text order by id) into expected from (select id from public.journals where id not in (select md5('catalogue-capacity-'||s)::uuid from generate_series(1,1000)s) order by id limit 50 offset 499950) p;
 assert (result->>'total')::int=1499000 and jsonb_array_length(result->'rows')=50, 'deep page count';
 assert (select jsonb_agg(r->>'id' order by ordinal) from jsonb_array_elements(result->'rows') with ordinality x(r,ordinal))=expected, 'deep page identities and order';
end $$;
do $$ declare result jsonb; begin
 result:=api.kb_catalogue_v1('{"category":"journals","q":"Synthetic article 499999"}');
 assert (result->>'total')::int=1 and jsonb_array_length(result->'rows')=1, 'Nonempty legacy search count';
 assert result->'rows'->0->>'title'='Synthetic article 499999', 'Search hydrates the matching row';
 assert result->'groups'='[{"category":"journals","total":1,"associated":0,"ready":0}]'::jsonb, 'Search group count';
 assert result->'metrics'='{"associated":0,"ready":0,"missing":0,"unknown":1}'::jsonb, 'Search metric counts';
end $$;
do $$ declare result jsonb; begin
 result:=api.kb_catalogue_v1('{"category":"journals","q":"sy"}');
 assert (result->>'total')::bigint=1500000, 'Short/broad/literal search exact count: sy';
 assert jsonb_array_length(result->'rows')=least(1500000,20), 'Bounded broad-search page';
end $$;
do $$ declare result jsonb; begin
 result:=api.kb_catalogue_v1('{"category":"journals","q":"a"}');
 assert (result->>'total')::bigint=1500000, 'Short/broad/literal search exact count: a';
 assert jsonb_array_length(result->'rows')=least(1500000,20), 'Bounded broad-search page';
end $$;
do $$ declare result jsonb; begin
 result:=api.kb_catalogue_v1('{"category":"journals","q":"zz"}');
 assert (result->>'total')::bigint=0, 'Short/broad/literal search exact count: zz';
 assert jsonb_array_length(result->'rows')=least(0,20), 'Bounded broad-search page';
end $$;
do $$ declare result jsonb; begin
 result:=api.kb_catalogue_v1('{"category":"journals","q":"%"}');
 assert (result->>'total')::bigint=0, 'Short/broad/literal search exact count: %';
 assert jsonb_array_length(result->'rows')=least(0,20), 'Bounded broad-search page';
end $$;
do $$ declare result jsonb; begin
 result:=api.kb_catalogue_v1('{"category":"journals","q":"synthetic abstract"}');
 assert (result->>'total')::bigint=1349100, 'Short/broad/literal search exact count: synthetic abstract';
 assert jsonb_array_length(result->'rows')=least(1349100,20), 'Bounded broad-search page';
end $$;
do $$ declare result jsonb; begin
 result:=api.kb_catalogue_v1('{"q":"synthetic"}');
 assert (result->>'total')::bigint=1549100, 'Mixed-source search exact count';
 assert result->'groups'='[{"category":"journals","total":1500000,"associated":1000,"ready":0},{"category":"other","total":49100,"associated":49100,"ready":0}]'::jsonb, 'Mixed-source groups and explicit deduplication';
 assert result->'metrics'='{"associated":50100,"ready":0,"missing":0,"unknown":1499000}'::jsonb, 'Mixed-source search status counts';
end $$;
-- In addition to PL/pgSQL's implicit cached statements above, exercise one
-- explicit parameterized statement across different query shapes. Check the
-- server counters rather than inferring generic-plan use from elapsed time.
prepare catalogue_capacity(jsonb) as select api.kb_catalogue_v1($1)->>'total';
execute catalogue_capacity('{}');
execute catalogue_capacity('{}');
execute catalogue_capacity('{"category":"esg"}');
execute catalogue_capacity(jsonb_build_object('key','journals:'||md5('catalogue-capacity-1001')::uuid));
execute catalogue_capacity('{"key":"journals:00000000-0000-4000-8000-000000000001"}');
execute catalogue_capacity('{"category":"journals","state":"unknown","page":2,"page_size":50}');
execute catalogue_capacity('{"category":"journals","state":"unknown","page":10000,"page_size":50}');
execute catalogue_capacity('{"category":"journals","q":"Synthetic article 499999"}');
execute catalogue_capacity('{"category":"journals","q":"sy"}');
execute catalogue_capacity('{"category":"journals","q":"zz"}');
do $$ begin
 assert (select generic_plans=10 and custom_plans=0 from pg_prepared_statements where name='catalogue_capacity'), 'Actual reused generic plans';
end $$;
deallocate catalogue_capacity;
reset role;
savepoint capacity_truncate;
set local role service_role;
truncate public.journals;
reset role;
do $$ begin
 assert not exists(select from private.kb_catalogue_journal_search),'Large source truncate clears its projection';
 assert not exists(select from private.kb_catalogue_journal_short_filter),'Large source truncate clears short filters';
end $$;
rollback to capacity_truncate;
do $$ begin
 assert (select count(*) from private.kb_catalogue_journal_search)=1500000,'Truncate rollback restores all derived rows';
 assert (select count(*) from private.kb_catalogue_journal_short_filter)=1500000,'Truncate rollback restores all short filters';
end $$;
\timing off
rollback;
