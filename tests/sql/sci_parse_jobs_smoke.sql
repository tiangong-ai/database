begin;
do $$
begin
 if not exists(select from pg_class c join pg_namespace n on n.oid=c.relnamespace
   where n.nspname='private' and c.relname='sci_parse_jobs' and c.relrowsecurity) then
   raise exception 'SCI ledger must be private and RLS enabled';
 end if;
 if has_table_privilege('anon','private.sci_parse_jobs','SELECT')
   or has_table_privilege('authenticated','private.sci_parse_jobs','UPDATE') then
   raise exception 'SCI jobs leaked to client roles';
 end if;
 if not has_table_privilege('service_role','private.sci_parse_jobs','INSERT,SELECT,UPDATE') then
   raise exception 'backend role cannot run SCI jobs';
 end if;
 if to_regclass('pgmq.q_kb_sci_parse_queue') is null then raise exception 'SCI queue missing'; end if;
end $$;
set local role service_role;
select count(*) from private.sci_parse_jobs;
select pgmq.send('kb_sci_parse_queue','{"sci_smoke":true}'::jsonb);
do $$
declare m record;
begin
 select * into m from pgmq.read('kb_sci_parse_queue',30,1,'{"sci_smoke":true}'::jsonb);
 if m.msg_id is null or not pgmq.archive('kb_sci_parse_queue',m.msg_id) then
   raise exception 'SCI queue read/archive failed';
 end if;
end $$;
rollback;
