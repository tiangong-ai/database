-- Short-query filtering is an optimization, never a new search/visibility rule.
begin;
-- Independent naive substring enumeration also covers raw newline and length
-- 0/1, which the public query normalizer may trim. It must never be rejected by
-- the regex-based signature builder, including high-diversity Unicode text.
do $$ declare source text; needle text; signature bit(1024); h text; begin
 for source in
  select unnest(array['','a',E'\n',E'a\nb',E'\001',lower(U&'\0130'),'e'||U&'\0301','😀‍😃'])
  union all
  select string_agg(chr(1024+get_byte(decode(md5(n::text||':'||i::text),'hex'),0)),'' order by i)
   from generate_series(1,40)n cross join generate_series(1,512)i group by n
 loop
  signature:=private.kb_catalogue_short_signature_v1(source);
  for needle in select distinct substr(source,i,k) from generate_series(1,length(source))i cross join generate_series(1,2)k loop
   h:=md5(needle);
   assert get_bit(signature,(('x'||substr(h,1,3))::bit(12)::int & 1023))=1
      and get_bit(signature,(('x'||substr(h,4,3))::bit(12)::int & 1023))=1,
      'Every literal one/two-codepoint substring must survive the negative filter';
  end loop;
 end loop;
end $$;
truncate public.journals,private.kb_resource_entries,public.kb_documents cascade;
insert into auth.users(id,role) values(md5('short-filter-actor')::uuid,'authenticated');
set local role service_role;
insert into public.journals(id,doi,title,abstract)
select md5('short-filter-'||n)::uuid,'10.000/short-'||n,
 string_agg((array['a','z','é','e',U&'\0301','文','Ａ','😀','😃',E'\001',E'\n','%', '_',E'\\',U&'\200D',U&'\FE0F'])[1+get_byte(decode(md5(n::text||':'||i::text),'hex'),0)%16],'' order by i),
 'ordinary metadata'
from generate_series(1,35)n cross join generate_series(1,20)i group by n;
reset role;
select set_config('request.jwt.claims',jsonb_build_object('sub',md5('short-filter-actor')::uuid,'role','authenticated')::text,true);
set local role authenticated;
do $$ declare needle text; expected uuid[]; actual uuid[]; result jsonb; begin
 for needle in
  select a||b from unnest(array['a','z','é','e',U&'\0301','文','Ａ','😀','😃',E'\001','%','_',E'\\',U&'\200D',U&'\FE0F',''])a
  cross join unnest(array['a','z','é','e',U&'\0301','文','Ａ','😀','😃',E'\001','%','_',E'\\',U&'\200D',U&'\FE0F',''])b
  where a||b<>''
 loop
  select coalesce(array_agg(id order by id),'{}'::uuid[]) into expected from public.journals j
   where strpos(lower(jsonb_build_object('title',j.title,'doi',j.doi,'journal',j.journal,'authors',j.authors,'date',j.date,'abstract',j.abstract)::text||' '||coalesce(j.title,'')),lower(needle))>0;
  result:=api.kb_catalogue_v1(jsonb_build_object('category','journals','q',needle,'page_size',50));
  select coalesce(array_agg((r->>'id')::uuid order by (r->>'id')::uuid),'{}'::uuid[]) into actual from jsonb_array_elements(result->'rows')r;
  assert actual=expected and (result->>'total')::int=cardinality(expected),'Short Unicode/literal result must equal raw source oracle';
 end loop;
 begin perform * from private.kb_catalogue_journal_short_filter; raise exception 'Private filter exposed';
 exception when insufficient_privilege then null; end;
 begin perform private.kb_catalogue_short_signature_v1('test'); raise exception 'Private signature helper exposed';
 exception when insufficient_privilege then null; end;
end $$;
reset role;
-- Force maximal false positives: the exact residual must still reject a miss.
update private.kb_catalogue_journal_short_filter set signature=repeat('1',1024)::bit(1024);
set local role authenticated;
do $$ begin assert (api.kb_catalogue_v1('{"category":"journals","q":"ΩΨ"}')->>'total')::int=0,'Saturated signatures never manufacture matches'; end $$;
reset role;
-- Missing acceleration state may increase work, but cannot hide source rows.
delete from private.kb_catalogue_journal_short_filter;
set local role authenticated;
do $$ begin assert (api.kb_catalogue_v1('{"category":"journals","q":"or"}')->>'total')::int=35,'Missing filters fall back to the exact text check'; end $$;
reset role;
update public.journals set abstract=abstract;
do $$ begin
 assert (select count(*)=35 from private.kb_catalogue_journal_short_filter),'Source writes restore derived filters';
 assert not exists(select from private.kb_catalogue_journal_search s join private.kb_catalogue_journal_short_filter f using(id) where f.signature<>private.kb_catalogue_short_signature_v1(s.search_text)),'Synchronous signature equality';
 assert private.kb_catalogue_short_signature_v1('')=repeat('0',1024)::bit(1024),'Empty input signature';
end $$;
-- Failure at the second derived layer must abort the complete source operation.
create function pg_temp.short_filter_abort() returns trigger language plpgsql as $$ begin raise check_violation; end $$;
create trigger short_filter_abort before insert or update or delete or truncate
 on private.kb_catalogue_journal_short_filter for each statement execute function pg_temp.short_filter_abort();
set local role service_role;
do $$ begin
 begin insert into public.journals(id,doi,title) values(md5('short-filter-rejected')::uuid,'10.000/short-rejected','reject');
  raise exception 'Expected filter insert failure'; exception when check_violation then null; end;
 begin update public.journals set abstract='reject' where id=md5('short-filter-1')::uuid;
  raise exception 'Expected filter update failure'; exception when check_violation then null; end;
 begin delete from public.journals where id=md5('short-filter-1')::uuid;
  raise exception 'Expected filter delete failure'; exception when check_violation then null; end;
 begin truncate public.journals;
  raise exception 'Expected filter truncate failure'; exception when check_violation then null; end;
 assert (select count(*)=35 from public.journals),'Failed writes preserve all source identities';
 assert (select abstract='ordinary metadata' from public.journals where id=md5('short-filter-1')::uuid),'Failed update preserves source content';
end $$;
reset role;
drop trigger short_filter_abort on private.kb_catalogue_journal_short_filter;
do $$ begin
 assert (select count(*)=35 from private.kb_catalogue_journal_search),'Failed writes preserve text projection';
 assert (select count(*)=35 from private.kb_catalogue_journal_short_filter),'Failed writes preserve filter projection';
end $$;
savepoint before_short_truncate;
truncate public.journals;
do $$ begin assert not exists(select from private.kb_catalogue_journal_short_filter),'Source truncate clears filters'; end $$;
rollback to before_short_truncate;
do $$ begin assert (select count(*)=35 from private.kb_catalogue_journal_short_filter),'Truncate rollback restores filters'; end $$;
rollback;
