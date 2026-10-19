do $$
declare actual jsonb;
begin
  if (select value from metadata_repair_test.business) is distinct from (select to_jsonb(t) from public.esg_meta t where id=(select (value->>'id')::uuid from metadata_repair_test.receipt)) then raise exception 'Repair changed business UUID/PDF/metadata'; end if;
  if (select value from metadata_repair_test.requests) is distinct from (select to_jsonb(t) from private.kb_metadata_requests t where actor_id='ada20000-0000-4000-8000-000000000001') then raise exception 'Repair changed receipt'; end if;
  if (select value from metadata_repair_test.grants) is distinct from (select to_jsonb(t) from private.kb_metadata_editors t where actor_id='ada20000-0000-4000-8000-000000000001') then raise exception 'Repair changed grant'; end if;
  if (select value from metadata_repair_test.audit) is distinct from (select to_jsonb(t) from public.kb_audit_events t where actor_id='ada20000-0000-4000-8000-000000000001') then raise exception 'Repair changed audit'; end if;
  if exists(select oid,proowner,proacl,prosecdef,proconfig from metadata_repair_test.signature except select oid,proowner,proacl,prosecdef,proconfig from pg_proc where oid='api.kb_metadata_command_v1(text,text,uuid,jsonb,uuid,text)'::regprocedure) then raise exception 'Repair changed function identity or privileges'; end if;
  perform set_config('request.jwt.claims','{"role":"authenticated","sub":"ada20000-0000-4000-8000-000000000001"}',true);
  actual:=api.kb_metadata_command_v1('esg','create','ada20000-0000-4000-8000-000000000002','{"report_title":"Preserved metadata repair"}');
  if actual is distinct from (select value||'{"replayed":true}'::jsonb from metadata_repair_test.receipt) then raise exception 'Repair lost original replay'; end if;
  begin
    perform api.kb_metadata_command_v1('esg','create','ada20000-0000-4000-8000-000000000003','{"report_title":"Invalid country","country":"ZZ"}');
    raise exception 'Country validation did not reject';
  exception when sqlstate 'PT400' then null;
  end;
end $$;
delete from public.esg_meta where id=(select (value->>'id')::uuid from metadata_repair_test.receipt);
delete from private.kb_metadata_requests where actor_id='ada20000-0000-4000-8000-000000000001';
delete from private.kb_metadata_editors where actor_id='ada20000-0000-4000-8000-000000000001';
delete from public.kb_audit_events where actor_id='ada20000-0000-4000-8000-000000000001';
delete from auth.users where id='ada20000-0000-4000-8000-000000000001';
drop schema metadata_repair_test cascade;
