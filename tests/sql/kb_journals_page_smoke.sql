begin;
truncate public.journals cascade;
insert into auth.users(id,role) values(md5('journal-page-user')::uuid,'authenticated');
insert into public.journals(id,title,doi)
select md5('journal-page-'||n)::uuid,'Synthetic '||n,'10.0/page-'||n
from generate_series(1,25) n;
create policy journal_page_restricted on public.journals as restrictive
for select to authenticated using(title <> 'Synthetic 1');
select set_config('request.jwt.claims',jsonb_build_object(
 'sub',md5('journal-page-user')::uuid,'role','authenticated')::text,true);
set local role authenticated;
set local plan_cache_mode=force_generic_plan;
do $$ declare r jsonb; expected jsonb; direction text; p integer; begin
 foreach direction in array array['asc','desc'] loop
  for p in 1..4 loop
   r:=api.kb_journals_page_v1(p,10,direction);
   select coalesce(jsonb_agg(x.id order by
    case when direction='asc' then x.id end asc,
    case when direction='desc' then x.id end desc),'[]'::jsonb)
    into expected from (select id from public.journals order by
     case when direction='asc' then id end asc,
     case when direction='desc' then id end desc offset (p-1)*10 limit 10) x;
   assert (r->>'total')::int=24,'RLS applies before exact count, including empty page';
   assert (r->>'page')::int=p and (r->>'pageSize')::int=10;
   assert (select coalesce(jsonb_agg(x->'id'),'[]'::jsonb) from jsonb_array_elements(r->'data') x)=expected,
    'Both directions, page boundaries and partial/empty pages match source RLS';
   assert not exists(select from jsonb_array_elements(r->'data') x
    where x ? 'abstract' or x ? 'authors'),'Only list fields';
  end loop;
 end loop;
 begin perform api.kb_journals_page_v1(0,10,'desc'); raise exception 'accepted page 0';
 exception when invalid_parameter_value then null; end;
 begin perform api.kb_journals_page_v1(1,101,'desc'); raise exception 'accepted size';
 exception when invalid_parameter_value then null; end;
 begin perform api.kb_journals_page_v1(1,10,'bad'); raise exception 'accepted direction';
 exception when invalid_parameter_value then null; end;
 begin perform api.kb_journals_page_v1(null,10,'desc'); raise exception 'accepted null';
 exception when invalid_parameter_value then null; end;
end $$;
reset role;
do $$ begin
 assert not has_function_privilege('anon','api.kb_journals_page_v1(integer,integer,text)','execute');
 assert not has_function_privilege('service_role','api.kb_journals_page_v1(integer,integer,text)','execute');
 assert not (select prosecdef from pg_proc where oid='api.kb_journals_page_v1(integer,integer,text)'::regprocedure);
end $$;
rollback;
