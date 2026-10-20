-- Synthetic capacity fixture: 60,000 private documents, 180,000 jobs, 100
-- collections. Not a production snapshot/distribution claim. Rollback only.
-- Run with psql ON_ERROR_STOP against a disposable replay of this repository.
begin;
insert into kb_collections(id, name, path, content_type)
select md5('jobs-perf-c-' || n)::uuid, 'Jobs capacity fixture', '/jobs-capacity/' || n, 'papers'
from generate_series(1,100) n;
insert into kb_documents(id, primary_collection_id, dedupe_scope, original_filename,
                         sha256, created_by, owner_user_id)
select md5('jobs-perf-d-' || n)::uuid, md5('jobs-perf-c-' || (1 + n % 100))::uuid,
       'jobs-capacity', 'synthetic-' || n || '.pdf', md5(n::text),
       md5('jobs-perf-owner')::uuid, md5('jobs-perf-owner')::uuid
from generate_series(1,60000) n;
insert into kb_jobs(id, document_id, document_version, stage, status,
                    created_at, updated_at, locked_until, locked_by, payload_json)
select md5('jobs-perf-j-' || n || '-' || s)::uuid, md5('jobs-perf-d-' || n)::uuid,
       1, (array['parse','s3_ready','index']::kb_job_stage[])[s],
       (array['succeeded','failed','dead','running','queued']::kb_job_status[])[1+n%5],
       '2026-01-01'::timestamptz + (n%100)*interval '1 hour',
       '2026-01-01'::timestamptz + (n%100)*interval '1 hour',
       case when n%5=3 then now()-interval '1 hour' end, 'synthetic-worker',
       jsonb_build_object('synthetic',repeat(md5(n::text),32))
from generate_series(1,60000) n cross join generate_series(1,3) s;
insert into kb_grants(principal_type, principal_id, resource_type, resource_id, actions, created_by)
select 'user', md5('jobs-perf-admin')::uuid, 'collection', md5('jobs-perf-c-' || n)::uuid,
       array['manage']::kb_grant_action[], md5('jobs-perf-admin')::uuid from generate_series(1,100) n;
insert into kb_grants(principal_type, principal_id, resource_type, resource_id, actions, created_by)
values ('user',md5('jobs-perf-restricted')::uuid,'collection',md5('jobs-perf-c-1')::uuid,
        array['read']::kb_grant_action[], md5('jobs-perf-admin')::uuid);
analyze kb_documents;
analyze kb_jobs;
analyze kb_collections;
analyze kb_grants;
-- Fixed per-statement gate, never changes any server/role timeout. Original RPC
-- exceeds this on the fixture; exact timings and nested plans are in the report.
set local statement_timeout = '5s';
\timing on
select 'administrator' as actor, count(*), min(total_count) from list_kb_admin_jobs(md5('jobs-perf-admin')::uuid);
select 'restricted' as actor, count(*), min(total_count) from list_kb_admin_jobs(md5('jobs-perf-restricted')::uuid);
select 'unauthorized' as actor, count(*), min(total_count) from list_kb_admin_jobs(md5('jobs-perf-denied')::uuid);
select 'failed' as filter, count(*), min(total_count) from list_kb_admin_jobs(md5('jobs-perf-admin')::uuid,'{"failed_only":true}');
select 'stale' as filter, count(*), min(total_count) from list_kb_admin_jobs(md5('jobs-perf-admin')::uuid,'{"stale_running":true}');
select 'deep_page' as filter, count(*), min(total_count) from list_kb_admin_jobs(md5('jobs-perf-admin')::uuid,'{}',25,50000);
select 'empty_page' as filter, count(*) from list_kb_admin_jobs(md5('jobs-perf-admin')::uuid,'{}',25,180000);
set local plan_cache_mode=force_generic_plan;
select 'generic_default' as filter, count(*), min(total_count) from list_kb_admin_jobs(md5('jobs-perf-admin')::uuid);
select 'stage' as filter, count(*), min(total_count) from list_kb_admin_jobs(md5('jobs-perf-admin')::uuid,'{"stage":"parse"}');
select 'status' as filter, count(*), min(total_count) from list_kb_admin_jobs(md5('jobs-perf-admin')::uuid,'{"status":"dead"}');
select 'worker' as filter, count(*), min(total_count) from list_kb_admin_jobs(md5('jobs-perf-admin')::uuid,'{"locked_by":"synthetic-worker"}');
-- Three jobs for one document must not read the entire 60k-document fixture.
-- A buffer budget detects the regression even on a fast, fully cached machine.
do $$ declare plan jsonb; begin
 execute format('explain (analyze,buffers,timing off,format json) select * from public.list_kb_admin_jobs(%L::uuid,%L::jsonb)',
   md5('jobs-perf-admin')::uuid,
   jsonb_build_object('document_id',md5('jobs-perf-d-1')::uuid)::text) into plan;
 assert (plan->0->'Plan'->>'Actual Rows')::int=3,'single-document jobs preserved';
 assert (plan->0->'Plan'->>'Shared Hit Blocks')::bigint
      + (plan->0->'Plan'->>'Shared Read Blocks')::bigint < 1000,
   'single-document query exceeds 1000-buffer budget';
end $$;
\timing off
rollback;
