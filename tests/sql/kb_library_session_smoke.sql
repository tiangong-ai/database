begin;
insert into auth.users(id,role) values(md5('session-actor')::uuid,'authenticated'),(md5('session-other')::uuid,'authenticated');
insert into auth.sessions(id,user_id) values(md5('session-valid')::uuid,md5('session-actor')::uuid),(md5('session-other')::uuid,md5('session-other')::uuid);
select set_config('request.jwt.claims',jsonb_build_object('sub',md5('session-actor')::uuid,'role','authenticated')::text,true);
set local role authenticated;
-- Red on the previous chain: merely having a user is insufficient.
do $$ begin
 begin perform api.kb_library_read_v1('journals'); raise exception 'missing session accepted'; exception when insufficient_privilege then null; end;
end $$;
reset role;
select set_config('request.jwt.claims',jsonb_build_object('sub',md5('session-actor')::uuid,'role','authenticated','session_id',md5('session-valid')::uuid)::text,true);
set local role authenticated;
select api.kb_library_read_v1('journals','{}',true);
reset role;
update auth.users set banned_until=now()+interval '1 hour' where id=md5('session-actor')::uuid;
set local role authenticated;
do $$ begin
 begin perform api.kb_library_read_v1('journals'); raise exception 'banned page accepted'; exception when insufficient_privilege then null; end;
 begin perform api.kb_library_read_v1('journals','{}',true); raise exception 'banned count accepted'; exception when insufficient_privilege then null; end;
end $$;
reset role;
update auth.users set banned_until=now()-interval '1 hour' where id=md5('session-actor')::uuid;
set local role authenticated;
select api.kb_library_read_v1('journals','{}',true);
do $$ declare sid text; begin
 foreach sid in array array['invalid',md5('session-missing')::uuid::text,md5('session-other')::uuid::text] loop
  perform set_config('request.jwt.claims',jsonb_build_object('sub',md5('session-actor')::uuid,'role','authenticated','session_id',sid)::text,true);
  begin perform api.kb_library_read_v1('journals'); raise exception 'invalid session accepted'; exception when insufficient_privilege then null; end;
 end loop;
end $$;
reset role;
select set_config('request.jwt.claims',jsonb_build_object('sub',md5('session-actor')::uuid,'role','authenticated','session_id',md5('session-valid')::uuid)::text,true);
delete from auth.sessions where id=md5('session-valid')::uuid;
set local role authenticated;
do $$ begin
 begin perform api.kb_library_read_v1('journals'); raise exception 'revoked page accepted'; exception when insufficient_privilege then null; end;
 begin perform api.kb_library_read_v1('journals','{}',true); raise exception 'revoked count accepted'; exception when insufficient_privilege then null; end;
end $$;
reset role;
do $$ begin
 assert not has_schema_privilege('authenticated','private','usage');
 assert not has_table_privilege('authenticated','auth.sessions','select');
 assert not has_function_privilege('anon','api.kb_library_session_v1()','execute');
 assert not has_function_privilege('service_role','api.kb_library_session_v1()','execute');
 assert not (select prosecdef from pg_proc where oid='api.kb_library_read_v1(text,jsonb,boolean)'::regprocedure);
end $$;
rollback;
