begin;
truncate public.journals cascade;
insert into auth.users(id,role) values(md5('library-reader')::uuid,'authenticated'),(md5('library-editor')::uuid,'authenticated');
insert into public.journals(id,title,doi) select md5('library-'||n)::uuid,'Library '||n,'10.0/library-'||n from generate_series(1,1025) n;
insert into public.reports(id,title) values(md5('library-report')::uuid,'Restricted report');
create policy library_reports_restricted on public.reports as restrictive for select to authenticated using(false);
create policy library_journals_restricted on public.journals as restrictive for select to authenticated using(title<>'Library 1');
insert into private.kb_metadata_editors(actor_id,resource,granted_by) values(md5('library-editor')::uuid,'reports',md5('library-editor')::uuid);
select set_config('request.jwt.claims',jsonb_build_object('sub',md5('library-reader')::uuid,'role','authenticated')::text,true);
set local role authenticated;
set local plan_cache_mode=force_generic_plan;
do $$ declare r jsonb; expected jsonb; direction text; p integer; q jsonb; begin
 foreach direction in array array['asc','desc'] loop
  foreach p in array array[1,2,103,104] loop
   q:=jsonb_build_object('page',p,'pageSize',10,'dir',direction);
   r:=api.kb_library_read_v1('journals',q);
   assert not r ? 'total','Page must not couple rows to count';
   assert (r->>'hasMore')::boolean=(p<103),'Next-page availability independent of count';
   select coalesce(jsonb_agg(x.id order by case when direction='asc' then x.id end asc,case when direction='desc' then x.id end desc),'[]'::jsonb)
    into expected from (select id from public.journals order by case when direction='asc' then id end asc,case when direction='desc' then id end desc offset (p-1)*10 limit 10) x;
   assert (select coalesce(jsonb_agg(x->'id'),'[]'::jsonb) from jsonb_array_elements(r->'data') x)=expected,'RLS identity order, partial and empty/deep pages';
   assert not (r->'capabilities'->>'canWrite')::boolean;
  end loop;
 end loop;
 assert api.kb_library_read_v1('journals','{}',true)->>'total'='1024','Exact RLS count';
 assert api.kb_library_read_v1('reports')->'data'='[]'::jsonb,'Reader retains restrictive RLS';
 assert api.kb_library_read_v1('reports','{}',true)->>'total'='0';
 begin perform api.kb_metadata_read_v1('reports');raise exception 'reader elevated';exception when insufficient_privilege then null;end;
 foreach q in array array['{"page":0}'::jsonb,'{"pageSize":101}','{"dir":"bad"}','{"sort":"secret"}','{"actorId":"forged"}','{"q":"unsupported"}','{"page":1.5}','{"page":99999999999999999999}'] loop
  begin perform api.kb_library_read_v1('journals',q);raise exception 'invalid query accepted';exception when sqlstate 'PT400' then null;end;
 end loop;
 begin perform api.kb_library_read_v1('thuHumanities');raise exception 'resource accepted';exception when sqlstate 'PT400' then null;end;
end $$;
reset role;
select set_config('request.jwt.claims',jsonb_build_object('sub',md5('library-editor')::uuid,'role','authenticated')::text,true);
set local role authenticated;
do $$ declare r jsonb; old jsonb; begin
 r:=api.kb_library_read_v1('reports');old:=api.kb_metadata_list_v1('reports','{"sort":"uploaded_time"}');
 assert r->'records'=old->'records','Editor snapshot/version exactly retained';
 assert (r->'capabilities'->>'canWrite')::boolean;
 assert api.kb_library_read_v1('reports','{}',true)->>'total'=old->>'total';
end $$;
reset role;
update private.kb_metadata_editors set revoked_at=now() where resource='reports';
set local role authenticated;
do $$ begin
 assert api.kb_library_read_v1('reports')->'data'='[]'::jsonb,'Revoked editor returns to RLS immediately';
 assert not (api.kb_library_read_v1('reports')->'capabilities'->>'canWrite')::boolean;
 begin perform api.kb_metadata_read_v1('reports');raise exception 'revoked editor accepted';exception when insufficient_privilege then null;end;
end $$;
reset role;
do $$ begin
 assert not has_function_privilege('anon','api.kb_library_read_v1(text,jsonb,boolean)','execute');
 assert not has_function_privilege('service_role','api.kb_library_read_v1(text,jsonb,boolean)','execute');
 assert not has_schema_privilege('authenticated','private','usage');
 assert not (select prosecdef from pg_proc where oid='api.kb_library_read_v1(text,jsonb,boolean)'::regprocedure);
end $$;
rollback;
