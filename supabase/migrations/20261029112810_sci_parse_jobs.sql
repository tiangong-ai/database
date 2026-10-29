-- SCI workers have their own ledger and queue. Legacy KB workers/RPCs are unchanged.
create schema if not exists private;
create table private.sci_parse_jobs (
  id uuid primary key,
  document_id uuid not null references public.kb_documents(id),
  document_version integer not null check (document_version > 0),
  source_sha256 text not null check (source_sha256 ~ '^[0-9a-f]{64}$'),
  status text not null default 'queued' check (status in ('queued','running','succeeded','dead','cancelled')),
  phase text not null default 'submit' check (phase in ('submit','receive')),
  attempts integer not null default 0 check (attempts >= 0),
  max_attempts integer not null default 3 check (max_attempts > 0),
  locked_by text,
  locked_until timestamptz,
  next_retry_at timestamptz,
  pgmq_msg_id bigint,
  payload_json jsonb not null default '{}'::jsonb check (jsonb_typeof(payload_json)='object'),
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  finished_at timestamptz
);
create unique index sci_parse_jobs_one_active on private.sci_parse_jobs(document_id)
  where status in ('queued','running');
create index sci_parse_jobs_receivable on private.sci_parse_jobs(locked_until,updated_at)
  where status='running' and phase='receive';
alter table private.sci_parse_jobs enable row level security;
revoke all on private.sci_parse_jobs from public,anon,authenticated;
grant usage on schema private to service_role;
grant select,insert,update,delete on private.sci_parse_jobs to service_role;
select pgmq.create('kb_sci_parse_queue');
revoke all on pgmq.q_kb_sci_parse_queue,pgmq.a_kb_sci_parse_queue from public,anon,authenticated;
revoke all on sequence pgmq.q_kb_sci_parse_queue_msg_id_seq from public,anon,authenticated;
grant usage on schema pgmq to service_role;
grant select,insert,update,delete on pgmq.q_kb_sci_parse_queue,pgmq.a_kb_sci_parse_queue to service_role;
grant usage,select on sequence pgmq.q_kb_sci_parse_queue_msg_id_seq to service_role;
comment on table private.sci_parse_jobs is
  'Internal SCI parser jobs; independent of public.kb_jobs and legacy queue/retry RPCs.';
