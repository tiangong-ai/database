begin;
insert into auth.users(id,role) values(md5('overview-reader')::uuid,'authenticated');
insert into auth.sessions(id,user_id) values(md5('overview-session')::uuid,md5('overview-reader')::uuid);
insert into public.reports(id,title) values(md5('overview-one')::uuid,'overview one');
select private.kb_refresh_library_overview_v1();
create temp table overview_before as select * from private.kb_library_overview_snapshot;
insert into public.reports(id,title) values(md5('overview-two')::uuid,'overview two');
select set_config('request.jwt.claims',jsonb_build_object('sub',md5('overview-reader')::uuid,'role','authenticated','session_id',md5('overview-session')::uuid)::text,true);
set local role authenticated;
do $$ declare v jsonb:=api.kb_library_overview_v1(); begin
 assert jsonb_array_length(v->'counts')=7;
 assert v->>'actorId'=md5('overview-reader')::uuid::text;
 assert v->>'refreshedAt' is not null and not (v->>'stale')::boolean;
 assert (select x->>'total' is null from jsonb_array_elements(v->'counts') x where x->>'resource'='greenDeal');
 assert (api.kb_library_read_v1('reports','{}',true)->>'total')::bigint =
   (select (x->>'total')::bigint+1 from jsonb_array_elements(v->'counts') x where x->>'resource'='reports');
 begin perform private.kb_refresh_library_overview_v1(); raise exception 'refresh exposed'; exception when insufficient_privilege then null; end;
 begin perform * from private.kb_library_overview_snapshot; raise exception 'snapshot exposed'; exception when insufficient_privilege then null; end;
end $$;
reset role;
-- Atomic failure keeps all seven previous rows, including their timestamp.
create function pg_temp.fail_overview_write() returns trigger language plpgsql as $$ begin
 if new.resource='reports' then raise exception 'synthetic refresh failure'; end if; return new;
end $$;
create trigger overview_failure before update on private.kb_library_overview_snapshot for each row execute function pg_temp.fail_overview_write();
do $$ begin
 begin perform private.kb_refresh_library_overview_v1(); raise exception 'refresh should fail';
 exception when raise_exception then assert sqlerrm='synthetic refresh failure'; end;
 assert not exists((select * from overview_before except select * from private.kb_library_overview_snapshot)
   union all (select * from private.kb_library_overview_snapshot except select * from overview_before));
end $$;
drop trigger overview_failure on private.kb_library_overview_snapshot;
select private.kb_refresh_library_overview_v1();
-- Runtime policy changes invalidate global-reader eligibility without a refresh.
create policy overview_restrict on public.reports as restrictive for select to authenticated using (title='overview one');
set local role authenticated;
do $$ declare v jsonb:=api.kb_library_overview_v1(); begin
 assert (select x->>'total' is null from jsonb_array_elements(v->'counts') x where x->>'resource'='reports');
 assert (api.kb_library_read_v1('reports','{}',true)->>'total')::bigint=1;
end $$;
reset role;
drop policy overview_restrict on public.reports;
insert into private.kb_metadata_editors(actor_id,resource,granted_by) values(md5('overview-reader')::uuid,'greenDeal',md5('overview-reader')::uuid);
set local role authenticated;
do $$ declare v jsonb:=api.kb_library_overview_v1(); begin
 assert (select x->>'total' is not null from jsonb_array_elements(v->'counts') x where x->>'resource'='greenDeal');
end $$;
reset role;
update private.kb_metadata_editors set revoked_at=now() where actor_id=md5('overview-reader')::uuid;
update private.kb_library_overview_snapshot set refreshed_at=now()-interval '2 days';
set local role authenticated;
do $$ declare v jsonb:=api.kb_library_overview_v1(); begin
 assert (v->>'stale')::boolean;
 assert (select x->>'total' is null from jsonb_array_elements(v->'counts') x where x->>'resource'='greenDeal');
end $$;
reset role;
delete from private.kb_library_overview_snapshot;
set local role authenticated;
do $$ declare v jsonb:=api.kb_library_overview_v1(); begin
 assert v->>'refreshedAt' is null and (v->>'stale')::boolean;
 assert not exists(select from jsonb_array_elements(v->'counts') x where x->>'total' is not null);
end $$;
reset role;
delete from auth.sessions where id=md5('overview-session')::uuid;
set local role authenticated;
do $$ begin
 begin perform api.kb_library_overview_v1(); raise exception 'revoked session accepted'; exception when insufficient_privilege then null; end;
end $$;
reset role;
do $$ begin
 assert not has_function_privilege('anon','api.kb_library_overview_v1()','execute');
 assert not has_function_privilege('service_role','api.kb_library_overview_v1()','execute');
 assert not has_table_privilege('authenticated','private.kb_library_overview_snapshot','select');
 assert not has_function_privilege('authenticated','private.kb_refresh_library_overview_v1()','execute');
 assert (select count(*)=1 from cron.job where jobname='kb-library-overview-daily' and schedule='0 19 * * *' and active and command like '%statement_timeout%5min%kb_refresh_library_overview_v1%');
end $$;
rollback;
