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
with varied as materialized (
 select v,left(string_agg(md5(v::text||':'||part::text),'' order by part),1900) abstract
 from generate_series(0,999)v cross join generate_series(1,60)part group by v
)
insert into public.journals(id,doi,title,abstract)
select md5('catalogue-capacity-'||s)::uuid,'10.000/capacity-'||s,
 'Synthetic article '||s,case when s%10=0 then varied.abstract else repeat('synthetic abstract ',100) end
 from generate_series(1,1500000)s join varied on varied.v=s%1000;
analyze public.journals;
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
with wide as materialized (
 select v,string_agg(md5(v::text||':'||part::text),'' order by part) payload
 from generate_series(0,999)v cross join generate_series(1,256)part group by v
)
insert into public.kb_documents(id,primary_collection_id,dedupe_scope,original_filename,sha256,created_by,owner_user_id,visibility,metadata_json)
select md5('capacity-document-'||s)::uuid,md5('capacity-collection-'||((s-1)/10000+1))::uuid,
 'capacity', 'Synthetic document '||s||'.pdf',s::text,
 case when s<=10000 then md5('catalogue-capacity-actor')::uuid else md5('capacity-other')::uuid end,
 md5('capacity-other')::uuid,
 case when s between 40001 and 50000 then 'public' else 'private' end::public.kb_document_visibility,
 jsonb_build_object('description',repeat('synthetic document metadata ',70),'payload',wide.payload)
from generate_series(1,60000)s join wide on wide.v=s%1000;
insert into public.kb_grants(resource_type,resource_id,principal_type,principal_id,actions,created_by)
select 'document',md5('capacity-document-'||s)::uuid,'user',md5('catalogue-capacity-actor')::uuid,
 array['read']::public.kb_grant_action[],md5('catalogue-capacity-actor')::uuid from generate_series(50001,50100)s;
-- Production failure shape: wide documents with an empty material registry.
analyze public.kb_documents;
analyze public.kb_collections;
analyze public.kb_grants;
analyze private.kb_resource_entries;
analyze private.kb_resource_document_links;
set local statement_timeout='8s';
select set_config('request.jwt.claims',jsonb_build_object('sub',md5('catalogue-capacity-actor')::uuid,'role','authenticated')::text,true);
set local role authenticated;
\timing on
do $$ declare r jsonb; begin
 r:=api.kb_catalogue_v1('{"page_size":1}');
 assert (r->>'total')::bigint=1550100,'Empty registry exact count';
 assert jsonb_array_length(r->'rows')=1 and length(r->'rows'->0->'metadata'->>'payload')=8192,'Empty registry selected TOAST body intact';
end $$;
reset role;
set local statement_timeout=0;
-- END empty registry request
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

-- Measure the additional lookup index on populated data, with no row replica.
-- DDL and source rows roll back together; this is an owned synthetic database.
\timing on
drop index public.journals_catalogue_doi_exact_idx;
create index journals_catalogue_doi_exact_idx on public.journals
 (lower(regexp_replace(btrim(doi),'^(https?://(dx\.)?doi\.org/|doi:\s*)','','i')));
select pg_relation_size('public.journals_catalogue_doi_exact_idx') as identifier_index_bytes;
set local statement_timeout='8s';
-- Bounded body loading must survive repeated PL/pgSQL generic plans. This
-- tests document and linked-material paths separately from the count scan.
select set_config('request.jwt.claims',jsonb_build_object('sub',md5('catalogue-capacity-actor')::uuid,'role','authenticated')::text,true);
do $$ declare before_scan bigint; before_fetch bigint; payload bigint; begin
 select seq_tup_read,idx_tup_fetch into before_scan,before_fetch from pg_stat_xact_user_tables where relid='public.kb_documents'::regclass;
 for i in 1..50 loop
  select sum(length(body::text)) into payload from private.kb_catalogue_registered_page_v1('document',md5('capacity-document-'||i)::uuid) r(body);
  assert payload>8192,'Complete selected document body';
  select sum(length(body::text)) into payload from private.kb_catalogue_registered_page_v1('material',md5('capacity-entry-'||i)::uuid) r(body);
  assert payload>0,'Complete linked material body';
 end loop;
 assert (select seq_tup_read=before_scan and idx_tup_fetch-before_fetch between 100 and 200 from pg_stat_xact_user_tables where relid='public.kb_documents'::regclass),'Page hydration must use bounded document primary-key probes, never repeated full scans';
end $$;
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
-- Time each product request alone. The independent reference query below also
-- walks the large fixture; charging both scans to one 8s DO block made the
-- oracle consume the product latency budget on shared CI runners.
create temporary table catalogue_page_results(page integer primary key,body jsonb) on commit drop;
insert into catalogue_page_results values(2,api.kb_catalogue_v1('{"category":"journals","state":"unknown","page":2,"page_size":50}'));
insert into catalogue_page_results values(10000,api.kb_catalogue_v1('{"category":"journals","state":"unknown","page":10000,"page_size":50}'));
-- Only oracle/identity assertions receive this separate bounded budget. No RPC
-- call runs under it; the two calls above still have statement_timeout='8s'.
set local statement_timeout='30s';
do $$ declare result jsonb; expected jsonb; begin
 select body into strict result from catalogue_page_results where page=2;
 select jsonb_agg(id::text order by id) into expected from (select id from public.journals where id not in (select md5('catalogue-capacity-'||s)::uuid from generate_series(1,1000)s) order by id limit 50 offset 50) p;
 assert (result->>'total')::int=1499000 and jsonb_array_length(result->'rows')=50, 'next page count';
 assert (select jsonb_agg(r->>'id' order by ordinal) from jsonb_array_elements(result->'rows') with ordinality x(r,ordinal))=expected, 'next page identities and order';
end $$;
do $$ declare result jsonb; expected jsonb; begin
 select body into strict result from catalogue_page_results where page=10000;
 select jsonb_agg(id::text order by id) into expected from (select id from public.journals where id not in (select md5('catalogue-capacity-'||s)::uuid from generate_series(1,1000)s) order by id limit 50 offset 499950) p;
 assert (result->>'total')::int=1499000 and jsonb_array_length(result->'rows')=50, 'deep page count';
 assert (select jsonb_agg(r->>'id' order by ordinal) from jsonb_array_elements(result->'rows') with ordinality x(r,ordinal))=expected, 'deep page identities and order';
end $$;
drop table catalogue_page_results;
set local statement_timeout='8s';
reset role;
set local statement_timeout=0;
insert into public.standards(id,standard_number,title)
 select md5('identifier-capacity-'||i)::uuid,'GB/T '||i||'-2026','Synthetic standard '||i from generate_series(1,50000)i;
analyze public.standards;
set local statement_timeout='8s';
set local role authenticated;
do $$ declare r jsonb; before_scan bigint; begin
 select seq_tup_read into before_scan from pg_stat_xact_user_tables where relid='public.journals'::regclass;
 r:=api.kb_catalogue_identifier_v1('{"category":"journals","identifier":"https://doi.org/10.000/CAPACITY-499999"}');
 assert (r->>'total')::int=1 and r->'rows'->0->>'title'='Synthetic article 499999','Large exact DOI lookup';
 assert (api.kb_catalogue_identifier_v1('{"category":"journals","identifier":"10.000/missing"}')->>'total')::int=0,'Large absent DOI';
 assert (select seq_tup_read=before_scan from pg_stat_xact_user_tables where relid='public.journals'::regclass),'DOI lookup must not sequentially scan journals';
 r:=api.kb_catalogue_identifier_v1('{"category":"standards","identifier":" gb/t 49999-2026 "}');
 assert (r->>'total')::int=1 and r->'rows'->0->>'title'='Synthetic standard 49999','50k standards exact lookup without speculative index';
end $$;
prepare identifier_capacity(jsonb) as select (api.kb_catalogue_identifier_v1($1)->>'total')::int;
execute identifier_capacity('{"category":"journals","identifier":"10.000/capacity-1"}');
execute identifier_capacity('{"category":"journals","identifier":"10.000/not-found"}');
execute identifier_capacity('{"category":"standards","identifier":"GB/T 1-2026"}');
do $$ begin assert (select generic_plans=3 and custom_plans=0 from pg_prepared_statements where name='identifier_capacity'),'Reused identifier plan'; end $$;
deallocate identifier_capacity;
-- Unsupported free text is rejected before touching the large source.
do $$ declare term text; before_scan bigint; begin
 select seq_tup_read into before_scan from pg_stat_xact_user_tables where relid='public.journals'::regclass;
 foreach term in array array['a','sy','synthetic abstract','%','测试',' '] loop
  begin
   perform api.kb_catalogue_v1(jsonb_build_object('q',term));
   raise exception 'Unsupported free text accepted';
  exception when sqlstate '22023' then
   assert sqlerrm='CATALOGUE_SEARCH_UNSUPPORTED','Explicit unsupported-search error';
  end;
 end loop;
 assert (select seq_tup_read=before_scan from pg_stat_xact_user_tables where relid='public.journals'::regclass),'Rejected search must not scan journals';
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
execute catalogue_capacity('{"category":"journals","page_size":1}');
execute catalogue_capacity('{"state":"associated"}');
execute catalogue_capacity('{"state":"missing"}');
do $$ begin
 assert (select generic_plans=10 and custom_plans=0 from pg_prepared_statements where name='catalogue_capacity'), 'Actual reused generic plans';
end $$;
deallocate catalogue_capacity;
reset role;
\timing off
rollback;
