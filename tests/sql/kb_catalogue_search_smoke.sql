-- Search is literal substring over the original serialized metadata + title.
-- Test actual transaction-synchronous source writes and final invoker RLS.
begin;
truncate public.journals,private.kb_resource_entries,public.kb_documents cascade;
insert into auth.users(id,role) values(md5('catalogue-search-actor')::uuid,'authenticated');
set local role service_role;
insert into public.journals(id,doi,title,journal,authors,date,abstract) values
 (md5('catalogue-search-one')::uuid,'10.000/search','Quoted "Title" 100%_ok','Journal Name','[{"given":"Alice","family":"测试"}]','2026-10',E'Alpha\nBeta \\ Path'),
 (md5('catalogue-search-two')::uuid,'10.000/second','Other publication','Second Journal','null',null,'LongAbstractOnly Needle');
reset role;
select set_config('request.jwt.claims',jsonb_build_object('sub',md5('catalogue-search-actor')::uuid,'role','authenticated')::text,true);
set local role authenticated;
do $$ declare needle text; expected uuid[]; actual uuid[]; result jsonb; begin
 foreach needle in array array['Quoted','quoted','100%_ok','100X_ok','100%Xok','\\ Path','ALICE','测试','%','_','\','"',E'\n','10.000','2026-10','abstract','"title":','null','a','zz','LongAbstractOnly Needle'] loop
  select coalesce(array_agg(id order by id),'{}'::uuid[]) into expected from public.journals t
   where strpos(lower(jsonb_build_object('title',t.title,'doi',t.doi,'journal',t.journal,'authors',t.authors,'date',t.date,'abstract',t.abstract)::text||' '||coalesce(t.title,'')),lower(needle))>0;
  result:=api.kb_catalogue_v1(jsonb_build_object('category','journals','q',needle,'page_size',50));
  select coalesce(array_agg((r->>'id')::uuid order by (r->>'id')::uuid),'{}'::uuid[]) into actual from jsonb_array_elements(result->'rows')r;
  assert actual=expected and (result->>'total')::int=cardinality(expected), 'Literal JSON substring parity including short/Unicode/escaped/wildcard/null searches';
 end loop;
 begin perform * from private.kb_catalogue_journal_matches_v1('Alice'); raise exception 'Private candidate helper exposed';
 exception when insufficient_privilege then null; end;
 begin perform * from private.kb_catalogue_journal_search; raise exception 'Private projection exposed';
 exception when insufficient_privilege then null; end;
end $$;
reset role;
-- A future restrictive source policy must also protect cached candidates.
create policy catalogue_test_deny on public.journals as restrictive for select to authenticated using(false);
set local role authenticated;
do $$ begin assert (api.kb_catalogue_v1('{"category":"journals","q":"Alice"}')->>'total')::int=0,'Final invoker RLS is authoritative'; end $$;
reset role;
drop policy catalogue_test_deny on public.journals;
set local role service_role;
update public.journals set abstract='ReplacementOnly',authors='[]' where id=md5('catalogue-search-one')::uuid;
delete from public.journals where id=md5('catalogue-search-two')::uuid;
reset role;
set local role authenticated;
do $$ begin
 assert (api.kb_catalogue_v1('{"category":"journals","q":"Alice"}')->>'total')::int=0,'Old indexed text removed immediately';
 assert (api.kb_catalogue_v1('{"category":"journals","q":"ReplacementOnly"}')->>'total')::int=1,'New indexed text visible in same transaction';
 assert (api.kb_catalogue_v1('{"category":"journals","q":"LongAbstractOnly"}')->>'total')::int=0,'Deleted projection removed';
end $$;
reset role;
-- Index errors roll back the source write, never leave a stale successful write.
alter table private.kb_catalogue_journal_search add constraint catalogue_failure_probe check(search_text not like '%fail-cache-write%');
set local role service_role;
do $$ begin
 begin update public.journals set abstract='fail-cache-write' where id=md5('catalogue-search-one')::uuid;
  raise exception 'Expected projection failure'; exception when check_violation then null; end;
 assert (select abstract='ReplacementOnly' from public.journals where id=md5('catalogue-search-one')::uuid),'Source update rolls back with projection';
 -- Existing privileged TRUNCATE usage remains supported without a new FK dependency.
 truncate public.journals;
end $$;
reset role;
do $$ begin assert not exists(select from private.kb_catalogue_journal_search),'Truncate removes the projection atomically'; end $$;
rollback;
