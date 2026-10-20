-- Bounded short-query negative filter. Source text and final invoker RLS remain
-- authoritative; no source rows, identifiers, ACLs or historical SQL change.
begin;
set local lock_timeout='5s';
-- Freeze the derived source before creating its triggers/backfill. Source writes
-- wait when their existing synchronous trigger reaches this relation. Reads run.
lock table private.kb_catalogue_journal_search in share row exclusive mode;
-- MD5 is a stable byte digest here, not a password/security primitive. Two fixed
-- 10-bit slots avoid persisting PostgreSQL's version-dependent internal hash.
create function private.kb_catalogue_short_signature_v1(s text) returns bit(1024)
language sql immutable strict parallel safe set search_path=pg_catalog as $$
 with pairs as materialized (
 select m[1] collate "C" g from regexp_matches(s,'(..)','g') m
 union select m[1] collate "C" from regexp_matches(substr(s,2),'(..)','g') m
 ), grams as (
 select g from pairs union select left(g,1) collate "C" from pairs
 union select right(g,1) collate "C" from pairs union select s collate "C" where length(s)=1
 ), hashes as materialized(select md5(g) h from grams)
 select coalesce(bit_or(set_bit(set_bit(repeat('0',1024)::bit(1024),
 (('x'||substr(h,1,3))::bit(12)::int & 1023),1),
 (('x'||substr(h,4,3))::bit(12)::int & 1023),1)),repeat('0',1024)::bit(1024)) from hashes
$$;
revoke all on function private.kb_catalogue_short_signature_v1(text) from public,anon,authenticated,service_role;
-- CTAS permits a parallel read for this CPU-bound backfill. Settings are local;
-- this does not change server configuration or depend on workers being available.
set local max_parallel_workers_per_gather=2;
set local min_parallel_table_scan_size=0;
set local parallel_setup_cost=0;
set local parallel_tuple_cost=0;
create table private.kb_catalogue_journal_short_filter as
 select id,private.kb_catalogue_short_signature_v1(search_text)::bit(1024) signature
 from private.kb_catalogue_journal_search;
alter table private.kb_catalogue_journal_short_filter
 add primary key(id), alter column signature set not null;
alter table private.kb_catalogue_journal_short_filter enable row level security;
revoke all on private.kb_catalogue_journal_short_filter from public,anon,authenticated,service_role;
create function private.kb_catalogue_short_filter_sync_v1() returns trigger
language plpgsql security definer set search_path=pg_catalog as $$
begin
 if tg_op='TRUNCATE' then
   truncate private.kb_catalogue_journal_short_filter;
   return null;
 end if;
 if tg_op='DELETE' then
   delete from private.kb_catalogue_journal_short_filter where id=old.id;
   return old;
 end if;
 if tg_op='UPDATE' and old.id<>new.id then
   delete from private.kb_catalogue_journal_short_filter where id=old.id;
 end if;
 insert into private.kb_catalogue_journal_short_filter(id,signature)
 values(new.id,private.kb_catalogue_short_signature_v1(new.search_text))
 on conflict(id) do update set signature=excluded.signature;
 return new;
end $$;
revoke all on function private.kb_catalogue_short_filter_sync_v1() from public,anon,authenticated,service_role;
create trigger kb_catalogue_short_filter_sync
 after insert or delete or update of id,search_text on private.kb_catalogue_journal_search
 for each row execute function private.kb_catalogue_short_filter_sync_v1();
create trigger kb_catalogue_short_filter_truncate
 after truncate on private.kb_catalogue_journal_search
 for each statement execute function private.kb_catalogue_short_filter_sync_v1();
analyze private.kb_catalogue_journal_short_filter;
create or replace function private.kb_catalogue_journal_matches_v1(p_search text) returns setof uuid
language plpgsql stable rows 1000000 security definer set search_path=pg_catalog as $$
declare needle text:=lower(p_search); h text; slot_a integer; slot_b integer;
begin
 perform private.kb_metadata_actor_v1();
 if p_search is null or length(p_search)>200 then
   raise sqlstate '22023' using message='CATALOGUE_INVALID_QUERY';
 end if;
 if needle='' then
   return query select id from private.kb_catalogue_journal_search;
 elsif length(needle)<3 then
   h:=md5(needle);
   slot_a:=(('x'||substr(h,1,3))::bit(12)::int & 1023);
   slot_b:=(('x'||substr(h,4,3))::bit(12)::int & 1023);
   -- Missing derived rows fail open only to the exact source-text predicate.
   -- A hash collision can increase work, but can never grant visibility or
   -- produce a result without the unchanged literal substring check.
   return query select s.id from private.kb_catalogue_journal_search s
    left join private.kb_catalogue_journal_short_filter f on f.id=s.id
    -- CASE prevents the planner from evaluating/decompressing search_text for
    -- rows that the negative filter can already exclude.
    where case when f.id is null or (get_bit(f.signature,slot_a)>0 and get_bit(f.signature,slot_b)>0)
      then strpos(s.search_text,needle)>0 else false end;
 else
   return query select id from private.kb_catalogue_journal_search
    where search_text like ('%'||replace(replace(replace(needle,E'\\',E'\\\\'),'%',E'\\%'),'_',E'\\_')||'%');
 end if;
end $$;

-- Aggregate once per category, and sort only fields needed for page hydration.
create or replace function api.kb_catalogue_v1(p_query jsonb default '{}') returns jsonb
language sql stable security invoker set search_path=pg_catalog
begin atomic;
 with q as materialized (select private.kb_catalogue_query_v1(p_query) as v),
 -- Deduplication uses ALL visible registered rows, before display filters.
 registered as materialized (select r.body from q cross join lateral private.kb_catalogue_registered_v1() r(body) where q.v is not null),
 filtered as materialized (
   select r.body->>'kind' as kind,(r.body->>'id')::uuid as id,
     r.body->>'category' as category,(r.body->>'updated_at')::timestamptz as updated_at,
     r.body->>'file_state' as file_state,r.body->>'processing_state' as processing_state
   from registered r,q
   where (q.v->>'category'='all' or r.body->>'category'=q.v->>'category')
    and (not q.v ? 'collection' or r.body->>'collection_id'=q.v->>'collection')
    and (not q.v ? 'key' or r.body->>'key'=q.v->>'key')
    and (q.v->>'q'='' or strpos(lower((r.body->'metadata')::text||' '||(r.body->>'title')),lower(q.v->>'q'))>0)
    and case q.v->>'state' when 'associated' then r.body->>'file_state' in ('associated','registered') when 'missing' then r.body->>'file_state'='missing'
      when 'pending' then r.body->>'metadata_state'='pending'
      when 'review' then r.body->>'review_state'='pending'
      when 'failed' then r.body->>'processing_state'='failed'
      when 'ready' then r.body->>'processing_state'='ready'
      when 'unknown' then r.body->>'file_state'='unknown' else true end
   union all
   select l.kind,l.id,l.category,l.updated_at,'unknown','unknown'
   from q cross join lateral private.kb_catalogue_legacy_v1(q.v,false) l
   where not exists(select from registered r where r.body->>'legacy_key'=l.legacy_key)
 ), page_keys as materialized (
   select kind,id,category,updated_at from filtered order by updated_at desc nulls last,kind,id
   limit (select (v->>'page_size')::int from q) offset (select ((v->>'page')::int-1)*(v->>'page_size')::int from q)
 ), page_rows as (
   select p.kind,p.id,p.updated_at,r.body
   from page_keys p join registered r on r.body->>'kind'=p.kind and (r.body->>'id')::uuid=p.id
   where p.kind in ('material','document')
   union all
   select p.kind,p.id,p.updated_at,l.body
   from page_keys p cross join lateral private.kb_catalogue_legacy_v1(
     jsonb_build_object('category',p.category,'state','all','q','','key',p.kind||':'||p.id::text),true) l
   where p.kind not in ('material','document')
 ), groups as (
   select category,count(*) total,
     count(*) filter(where file_state in ('associated','registered')) associated,
     count(*) filter(where processing_state='ready') ready,
     count(*) filter(where file_state='missing') missing,count(*) filter(where file_state='unknown') unknown
   from filtered group by category
 ), metrics as (
   select coalesce(sum(total),0) total,coalesce(sum(associated),0) associated,
     coalesce(sum(ready),0) ready,coalesce(sum(missing),0) missing,coalesce(sum(unknown),0) unknown from groups
 )
 select jsonb_build_object('version',1,'page',(q.v->>'page')::int,'page_size',(q.v->>'page_size')::int,
   'total',metrics.total,'rows',coalesce((select jsonb_agg(body order by updated_at desc nulls last,kind,id) from page_rows),'[]'),
   'groups',coalesce((select jsonb_agg(jsonb_build_object('category',category,'total',total,'associated',associated,'ready',ready) order by category) from groups),'[]'),
   'metrics',jsonb_build_object('associated',metrics.associated,'ready',metrics.ready,'missing',metrics.missing,'unknown',metrics.unknown),
   'observed_at',statement_timestamp()) from q cross join metrics;
end;


notify pgrst, 'reload schema';
commit;
