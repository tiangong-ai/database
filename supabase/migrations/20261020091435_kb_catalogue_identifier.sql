-- Database #27 / Next #111: exact current-library identifiers, no search replica.
begin;
set local lock_timeout='5s';
set local statement_timeout='5min';
-- Same expression as the existing resource DOI normalizer. Built-ins keep index
-- maintenance independent of private-schema grants; regression checks parity.
create index journals_catalogue_doi_exact_idx on public.journals
 (lower(regexp_replace(btrim(doi),'^(https?://(dx\.)?doi\.org/|doi:\s*)','','i')));

create function private.kb_catalogue_identifier_query_v1(p_query jsonb) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog as $$
declare q jsonb; identifier text;
begin
 perform private.kb_metadata_actor_v1();
 if p_query is null or jsonb_typeof(p_query)<>'object'
   or jsonb_typeof(p_query->'identifier') is distinct from 'string'
   or length(p_query->>'identifier') not between 1 and 512
   or p_query->>'identifier' ~ '[[:cntrl:]]'
   or coalesce(p_query->>'category','') not in ('journals','standards') or p_query ? 'key' then
   raise sqlstate '22023' using message='CATALOGUE_INVALID_IDENTIFIER';
 end if;
 q:=private.kb_catalogue_query_v1(p_query-'identifier');
 identifier:=case q->>'category' when 'journals' then private.kb_resource_normalize_doi(p_query->>'identifier')
   else nullif(lower(btrim(p_query->>'identifier')),'') end;
 if identifier is null then raise sqlstate '22023' using message='CATALOGUE_INVALID_IDENTIFIER'; end if;
 return q||jsonb_build_object('identifier',identifier);
end $$;

create function api.kb_catalogue_identifier_v1(p_query jsonb) returns jsonb
language sql stable security invoker set search_path=pg_catalog
begin atomic;
 with q as materialized (select private.kb_catalogue_identifier_query_v1(p_query) v),
 registered as materialized (
   select r.body from q cross join lateral private.kb_catalogue_registered_v1() r(body) where q.v is not null
 ), source_matches as materialized (
   -- Invoker SELECT/RLS runs before identifiers contribute to counts or links.
   select 'journals'::text kind,t.id,t.created_at updated_at,'journals:'||t.id::text legacy_key
   from q join public.journals t on q.v->>'category'='journals'
     and lower(regexp_replace(btrim(t.doi),'^(https?://(dx\.)?doi\.org/|doi:\s*)','','i'))=q.v->>'identifier'
   union all
   select 'standards',t.id,t.last_updated_time,'standards:'||t.id::text
   from q join public.standards t on q.v->>'category'='standards'
     and lower(btrim(t.standard_number))=q.v->>'identifier'
 ), matched_registered as materialized (
   select r.body from registered r,q
   where r.body->>'category'=q.v->>'category'
     and (not q.v ? 'collection' or r.body->>'collection_id'=q.v->>'collection')
     and (
       case q.v->>'category' when 'journals' then
         lower(regexp_replace(btrim(r.body->'metadata'->>'doi'),'^(https?://(dx\.)?doi\.org/|doi:\s*)','','i'))=q.v->>'identifier'
       else lower(btrim(r.body->'metadata'->>'standard_number'))=q.v->>'identifier' end
       or exists(select from source_matches s where s.legacy_key=r.body->>'legacy_key')
     )
     and case q.v->>'state' when 'associated' then r.body->>'file_state' in ('associated','registered')
       when 'missing' then r.body->>'file_state'='missing' when 'pending' then r.body->>'metadata_state'='pending'
       when 'review' then r.body->>'review_state'='pending' when 'failed' then r.body->>'processing_state'='failed'
       when 'ready' then r.body->>'processing_state'='ready' when 'unknown' then r.body->>'file_state'='unknown' else true end
 ), candidates as materialized (
   select body->>'kind' kind,(body->>'id')::uuid id,(body->>'updated_at')::timestamptz updated_at,
     body->>'file_state' file_state,body->>'processing_state' processing_state from matched_registered
   union all
   select s.kind,s.id,s.updated_at,'unknown','unknown' from source_matches s,q
   where not q.v ? 'collection' and q.v->>'state' in ('all','unknown')
     and not exists(select from registered r where r.body->>'legacy_key'=s.legacy_key)
 ), page_keys as materialized (
   select * from candidates order by updated_at desc nulls last,kind,id
   limit (select (v->>'page_size')::int from q) offset (select ((v->>'page')::int-1)*(v->>'page_size')::int from q)
 ), page_rows as (
   select p.kind,p.id,p.updated_at,r.body from page_keys p join matched_registered r
     on r.body->>'kind'=p.kind and (r.body->>'id')::uuid=p.id
   union all
   select p.kind,p.id,p.updated_at,l.body from page_keys p
   cross join lateral private.kb_catalogue_legacy_v1(
     jsonb_build_object('category',p.kind,'state','all','q','','key',p.kind||':'||p.id::text),true) l
   where p.kind in ('journals','standards')
 ), metrics as (
   select count(*) total,count(*) filter(where file_state in ('associated','registered')) associated,
     count(*) filter(where processing_state='ready') ready,count(*) filter(where file_state='missing') missing,
     count(*) filter(where file_state='unknown') unknown from candidates
 )
 select jsonb_build_object('version',1,'page',(q.v->>'page')::int,'page_size',(q.v->>'page_size')::int,
   'total',m.total,'rows',coalesce((select jsonb_agg(body order by updated_at desc nulls last,kind,id) from page_rows),'[]'),
   'groups',case when m.total=0 then '[]'::jsonb else jsonb_build_array(jsonb_build_object('category',q.v->>'category','total',m.total,'associated',m.associated,'ready',m.ready)) end,
   'metrics',jsonb_build_object('associated',m.associated,'ready',m.ready,'missing',m.missing,'unknown',m.unknown),
   'observed_at',statement_timestamp()) from q cross join metrics m;
end;
revoke all on function private.kb_catalogue_identifier_query_v1(jsonb),api.kb_catalogue_identifier_v1(jsonb) from public,anon,authenticated,service_role;
grant execute on function private.kb_catalogue_identifier_query_v1(jsonb),api.kb_catalogue_identifier_v1(jsonb) to authenticated;
notify pgrst,'reload schema';
commit;
