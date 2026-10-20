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
do $$ declare before_scan bigint; before_fetch bigint; result jsonb; begin
 select seq_tup_read,idx_tup_fetch into before_scan,before_fetch from pg_stat_xact_user_tables where relid='public.journals'::regclass;
 result:=api.kb_catalogue_v1('{"category":"esg"}');
 assert (result->>'total')::int=0 and result->'rows'='[]'::jsonb, 'Empty unrelated category';
 assert (select seq_tup_read=before_scan and idx_tup_fetch=before_fetch from pg_stat_xact_user_tables where relid='public.journals'::regclass), 'Empty ESG must not read journals';
end $$;
do $$ declare before_scan bigint; before_fetch bigint; result jsonb; begin
 select seq_tup_read,idx_tup_fetch into before_scan,before_fetch from pg_stat_xact_user_tables where relid='public.journals'::regclass;
 result:=api.kb_catalogue_v1(jsonb_build_object('key','journals:'||md5('catalogue-capacity-1')::uuid));
 assert (result->>'total')::int=1 and result->'rows'->0->>'title'='Synthetic article 1', 'Exact detail';
 assert (select seq_tup_read=before_scan and idx_tup_fetch>before_fetch and idx_tup_fetch-before_fetch<=2 from pg_stat_xact_user_tables where relid='public.journals'::regclass), 'Detail must use bounded primary key lookups';
end $$;
select api.kb_catalogue_v1('{"key":"journals:00000000-0000-4000-8000-000000000001"}')->>'total' as missing_detail;
select api.kb_catalogue_v1('{"category":"journals","page":2,"page_size":50}')->>'total' as next_page;
select api.kb_catalogue_v1('{"category":"journals","page":10000,"page_size":50}')->>'total' as deep_page;
select api.kb_catalogue_v1('{"category":"journals","q":"Synthetic article 499999"}')->>'total' as search;
\timing off
rollback;
