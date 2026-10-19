-- Populate the original metadata gateway before its forward correction.
create schema metadata_repair_test;
insert into auth.users(id,role,email) values('ada20000-0000-4000-8000-000000000001','authenticated','metadata-repair@example.test');
insert into private.kb_metadata_editors(actor_id,resource,granted_by) values('ada20000-0000-4000-8000-000000000001','esg','ada20000-0000-4000-8000-000000000001');
select set_config('request.jwt.claims','{"role":"authenticated","sub":"ada20000-0000-4000-8000-000000000001"}',false);
create table metadata_repair_test.receipt as select api.kb_metadata_command_v1('esg','create','ada20000-0000-4000-8000-000000000002','{"report_title":"Preserved metadata repair"}') as value;
update public.esg_meta set pdf_name=id::text||'.pdf' where id=(select (value->>'id')::uuid from metadata_repair_test.receipt);
create table metadata_repair_test.business as select to_jsonb(t) as value from public.esg_meta t where id=(select (value->>'id')::uuid from metadata_repair_test.receipt);
create table metadata_repair_test.requests as select to_jsonb(t) as value from private.kb_metadata_requests t where actor_id='ada20000-0000-4000-8000-000000000001';
create table metadata_repair_test.grants as select to_jsonb(t) as value from private.kb_metadata_editors t where actor_id='ada20000-0000-4000-8000-000000000001';
create table metadata_repair_test.audit as select to_jsonb(t) as value from public.kb_audit_events t where actor_id='ada20000-0000-4000-8000-000000000001';
create table metadata_repair_test.signature as select oid,proowner,proacl,prosecdef,proconfig from pg_proc where oid='api.kb_metadata_command_v1(text,text,uuid,jsonb,uuid,text)'::regprocedure;
