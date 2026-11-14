begin;
set local lock_timeout = '4s';
set local statement_timeout = '40s';
alter table private.sci_ingest_tasks add column if not exists parquet_at timestamptz;
commit;
