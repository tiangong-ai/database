begin;
truncate public.journals,public.edu_meta,public.esg_meta,public.standards,public.reports,public.internal_use,public.green_deal_meta,private.kb_resource_entries,public.kb_documents cascade;
insert into auth.users(id,role) values(md5('browse-actor')::uuid,'authenticated');
insert into public.journals(id,doi,title) values
(md5('browse-hidden')::uuid,'10.0/hidden','Hidden'),(md5('browse-visible')::uuid,'10.0/visible','Visible');
create policy catalogue_browse_rls on public.journals as restrictive for select to authenticated using(id=md5('browse-visible')::uuid);
select set_config('request.jwt.claims',jsonb_build_object('sub',md5('browse-actor')::uuid,'role','authenticated')::text,true);
set local role authenticated;
do $$ declare r jsonb; begin
 r:=api.kb_catalogue_v1('{"category":"journals","page_size":1}');
 assert (r->>'total')::int=1 and r->'rows'->0->>'title'='Visible','Source RLS before count and page';
 assert api.kb_catalogue_v1('{"category":"journals","page_size":1,"page":2}')->'rows'='[]','No hidden row consumes page';
 assert (api.kb_catalogue_v1(jsonb_build_object('key','journals:'||md5('browse-hidden')::uuid))->>'total')::int=0,'Hidden direct detail denied';
 begin perform api.kb_catalogue_v1('{"q":"Visible"}'); raise exception 'Wide search accepted';
 exception when sqlstate '22023' then assert sqlerrm='CATALOGUE_SEARCH_UNSUPPORTED'; end;
end $$;
reset role;
do $$ begin
 assert to_regclass('private.kb_catalogue_journal_search') is null,'No full metadata search replica';
 assert to_regclass('private.kb_catalogue_journal_short_filter') is null,'No short-word replica';
 assert not exists(select from pg_trigger where tgrelid='public.journals'::regclass and tgname like 'kb_catalogue_%'),'No catalogue journal write overhead';
end $$;
rollback;
