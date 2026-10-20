-- Owned disposable database only. Synthetic 500k x 1900-byte abstracts.
-- Exact counts, deep paging, routing and page hydration; never production data.
begin;
-- Earlier consumer gates retain synthetic rows. Isolate this fixture inside the
-- rollback, then restore every earlier fixture; the runner owns the whole DB.
truncate public.journals,public.edu_meta,public.esg_meta,public.standards,
 public.reports,public.internal_use,public.green_deal_meta,
 private.kb_resource_entries,public.kb_documents cascade;
insert into auth.users(id,role) values(md5('catalogue-capacity-actor')::uuid,'authenticated');
insert into public.journals(id,doi,title,abstract)
select md5('catalogue-capacity-'||s)::uuid,'10.000/capacity-'||s,
 'Synthetic article '||s,repeat('synthetic abstract ',100) from generate_series(1,500000)s;
analyze public.journals;
set local statement_timeout='8s';
-- Exercise parameter-independent plans used by reused PostgREST statements.
set local plan_cache_mode=force_generic_plan;
set local role authenticated;
select set_config('request.jwt.claims',jsonb_build_object('sub',md5('catalogue-capacity-actor')::uuid,'role','authenticated')::text,true);
\timing on
-- Each statement is independently bounded, including the deepest allowed page.
do $$ declare result jsonb; begin
 result:=api.kb_catalogue_v1('{}');
 assert (result->>'total')::bigint=500000, 'Exact visible count';
 assert result->'groups'='[{"category":"journals","total":500000,"associated":0,"ready":0}]'::jsonb, 'Category counts';
 assert result->'metrics'='{"associated":0,"ready":0,"missing":0,"unknown":500000}'::jsonb, 'Unknown is not missing';
 assert jsonb_array_length(result->'rows')=20, 'Bounded hydrated page';
 assert length(result->'rows'->0->'metadata'->>'abstract')=1900, 'Full metadata only on selected rows';
end $$;
do $$ declare before_scan bigint; before_fetch bigint; before_index bigint; result jsonb; begin
 select seq_tup_read,idx_tup_fetch,idx_scan into before_scan,before_fetch,before_index from pg_stat_xact_user_tables where relid='public.journals'::regclass;
 result:=api.kb_catalogue_v1('{"category":"esg"}');
 assert (result->>'total')::int=0 and result->'rows'='[]'::jsonb, 'Empty unrelated category';
 assert (select seq_tup_read=before_scan and idx_tup_fetch=before_fetch and idx_scan=before_index from pg_stat_xact_user_tables where relid='public.journals'::regclass), 'Empty ESG must not read journals';
end $$;
do $$ declare before_scan bigint; before_fetch bigint; before_index bigint; result jsonb; begin
 select seq_tup_read,idx_tup_fetch,idx_scan into before_scan,before_fetch,before_index from pg_stat_xact_user_tables where relid='public.journals'::regclass;
 result:=api.kb_catalogue_v1(jsonb_build_object('key','journals:'||md5('catalogue-capacity-1')::uuid));
 assert (result->>'total')::int=1 and result->'rows'->0->>'title'='Synthetic article 1', 'Exact detail';
 assert (select seq_tup_read=before_scan and idx_tup_fetch>before_fetch and idx_tup_fetch-before_fetch<=2 and idx_scan>before_index and idx_scan-before_index<=2 from pg_stat_xact_user_tables where relid='public.journals'::regclass), 'Detail must use bounded primary key lookups';
end $$;
do $$ declare result jsonb; begin
 result:=api.kb_catalogue_v1('{"key":"journals:00000000-0000-4000-8000-000000000001"}');
 assert (result->>'total')::int=0 and result->'rows'='[]'::jsonb, 'Missing keyed detail';
end $$;
do $$ declare result jsonb; expected jsonb; begin
 result:=api.kb_catalogue_v1('{"category":"journals","page":2,"page_size":50}');
 select jsonb_agg(id::text order by id) into expected from (select id from public.journals order by id limit 50 offset 50) p;
 assert (result->>'total')::int=500000 and jsonb_array_length(result->'rows')=50, 'next page count';
 assert (select jsonb_agg(r->>'id' order by ordinal) from jsonb_array_elements(result->'rows') with ordinality x(r,ordinal))=expected, 'next page identities and order';
end $$;
do $$ declare result jsonb; expected jsonb; begin
 result:=api.kb_catalogue_v1('{"category":"journals","page":10000,"page_size":50}');
 select jsonb_agg(id::text order by id) into expected from (select id from public.journals order by id limit 50 offset 499950) p;
 assert (result->>'total')::int=500000 and jsonb_array_length(result->'rows')=50, 'deep page count';
 assert (select jsonb_agg(r->>'id' order by ordinal) from jsonb_array_elements(result->'rows') with ordinality x(r,ordinal))=expected, 'deep page identities and order';
end $$;
do $$ declare result jsonb; begin
 result:=api.kb_catalogue_v1('{"category":"journals","q":"Synthetic article 499999"}');
 assert (result->>'total')::int=1 and jsonb_array_length(result->'rows')=1, 'Nonempty legacy search count';
 assert result->'rows'->0->>'title'='Synthetic article 499999', 'Search hydrates the matching row';
 assert result->'groups'='[{"category":"journals","total":1,"associated":0,"ready":0}]'::jsonb, 'Search group count';
 assert result->'metrics'='{"associated":0,"ready":0,"missing":0,"unknown":1}'::jsonb, 'Search metric counts';
end $$;
-- In addition to PL/pgSQL's implicit cached statements above, exercise one
-- explicit parameterized statement across different query shapes. Check the
-- server counters rather than inferring generic-plan use from elapsed time.
prepare catalogue_capacity(jsonb) as select api.kb_catalogue_v1($1)->>'total';
execute catalogue_capacity('{}');
execute catalogue_capacity('{}');
execute catalogue_capacity('{"category":"esg"}');
execute catalogue_capacity(jsonb_build_object('key','journals:'||md5('catalogue-capacity-1')::uuid));
execute catalogue_capacity('{"key":"journals:00000000-0000-4000-8000-000000000001"}');
execute catalogue_capacity('{"category":"journals","page":2,"page_size":50}');
execute catalogue_capacity('{"category":"journals","page":10000,"page_size":50}');
execute catalogue_capacity('{"category":"journals","q":"Synthetic article 499999"}');
do $$ begin
 assert (select generic_plans=8 and custom_plans=0 from pg_prepared_statements where name='catalogue_capacity'), 'Actual reused generic plans';
end $$;
deallocate catalogue_capacity;
\timing off
rollback;
