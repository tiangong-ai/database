-- Prune legacy sources before projection; keep exact counts and one snapshot.
-- Forward-only correction: the original catalogue migration is immutable.
begin;

-- Detail lookup casts only validated canonical identifiers, without changing IDs.
create or replace function private.kb_catalogue_query_v1(p_query jsonb) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog as $$
begin
  perform private.kb_metadata_actor_v1();
  if p_query is null or jsonb_typeof(p_query)<>'object' or octet_length(p_query::text)>2048
    or exists(select from jsonb_each(p_query) x where x.key not in ('q','category','state','page','page_size','key','collection')
      or (x.key in ('page','page_size') and (jsonb_typeof(x.value)<>'number' or x.value::text !~ '^[0-9]+$'))
      or (x.key not in ('page','page_size') and jsonb_typeof(x.value)<>'string'))
    or coalesce((p_query->>'page')::integer,1) not between 1 and 10000
    or coalesce((p_query->>'page_size')::integer,20) not between 1 and 50
    or length(coalesce(p_query->>'q',''))>200
    or coalesce(p_query->>'category','all') not in ('all','journals','esg','standards','reports','education','policies','other')
    or coalesce(p_query->>'state','all') not in ('all','associated','missing','pending','review','failed','ready','unknown')
    or (p_query ? 'key' and (length(p_query->>'key')>100 or p_query->>'key' !~ '^[A-Za-z]+:[0-9a-f-]{36}$'))
    or (p_query ? 'collection' and p_query->>'collection' !~ '^[0-9a-f-]{36}$') then
    raise sqlstate '22023' using message='CATALOGUE_INVALID_QUERY';
  end if;
  if p_query ? 'key' and split_part(p_query->>'key',':',2)::uuid::text<>split_part(p_query->>'key',':',2) then
    raise sqlstate '22023' using message='CATALOGUE_INVALID_QUERY';
  end if;
  return jsonb_build_object('page',1,'page_size',20,'q','','category','all','state','all')||p_query;
exception when invalid_text_representation or numeric_value_out_of_range then
  raise sqlstate '22023' using message='CATALOGUE_INVALID_QUERY';
end $$;


-- SQL-standard body retains invoker RLS without granting private schema USAGE.
-- Candidate mode never builds metadata JSON unless a nonempty search needs it.
-- Hydration mode is called only for selected page keys (at most 50).
create or replace function private.kb_catalogue_legacy_v1(p_query jsonb,p_hydrate boolean)
returns table(kind text,id uuid,category text,updated_at timestamptz,legacy_key text,body jsonb)
language sql stable security invoker set search_path=pg_catalog
begin atomic;
 select 'journals'::text,t.id,'journals'::text,t.created_at,'journals:'||t.id::text,
   case when p_hydrate then private.kb_catalogue_row_v1('journals',t.id,'journals',t.title,jsonb_build_object('title',t.title,'doi',t.doi,'journal',t.journal,'authors',t.authors,'date',t.date,'abstract',t.abstract),t.created_at,jsonb_build_object('legacy_key','journals:'||t.id::text)) end
 from (select * from public.journals original where not p_query ? 'key' union all select * from public.journals original where p_query ? 'key' and original.id=split_part(p_query->>'key',':',2)::uuid) t
 where p_query->>'category' in ('all','journals')
   and not p_query ? 'collection' and p_query->>'state' in ('all','unknown')
   and (not p_query ? 'key' or (split_part(p_query->>'key',':',1)='journals' and t.id=split_part(p_query->>'key',':',2)::uuid))
   and (p_query->>'q'='' or strpos(lower(jsonb_build_object('title',t.title,'doi',t.doi,'journal',t.journal,'authors',t.authors,'date',t.date,'abstract',t.abstract)::text||' '||coalesce(t.title,'')),lower(p_query->>'q'))>0)
 union all
 select 'education'::text,t.id,'education'::text,t.upload_time,'edu_meta:'||t.id::text,
   case when p_hydrate then private.kb_catalogue_row_v1('education',t.id,'education',t.name,jsonb_build_object('name',t.name,'course',t.course,'chapter_number',t.chapter_number,'description',t.description,'language',t.language,'type',t.type),t.upload_time,jsonb_build_object('legacy_key','edu_meta:'||t.id::text)) end
 from (select * from public.edu_meta original where not p_query ? 'key' union all select * from public.edu_meta original where p_query ? 'key' and original.id=split_part(p_query->>'key',':',2)::uuid) t
 where p_query->>'category' in ('all','education')
   and not p_query ? 'collection' and p_query->>'state' in ('all','unknown')
   and (not p_query ? 'key' or (split_part(p_query->>'key',':',1)='education' and t.id=split_part(p_query->>'key',':',2)::uuid))
   and (p_query->>'q'='' or strpos(lower(jsonb_build_object('name',t.name,'course',t.course,'chapter_number',t.chapter_number,'description',t.description,'language',t.language,'type',t.type)::text||' '||coalesce(t.name,'')),lower(p_query->>'q'))>0)
 union all
 select 'esg'::text,t.id,'esg'::text,t.last_updated_time,'esg_meta:'||t.id::text,
   case when p_hydrate then private.kb_catalogue_row_v1('esg',t.id,'esg',t.report_title,jsonb_build_object('report_title',t.report_title,'company_name',t.company_name,'company_name_en',t.company_name_en,'country',t.country,'publication_date',t.publication_date,'language',t.language),t.last_updated_time,jsonb_build_object('legacy_key','esg_meta:'||t.id::text)) end
 from (select * from public.esg_meta original where not p_query ? 'key' union all select * from public.esg_meta original where p_query ? 'key' and original.id=split_part(p_query->>'key',':',2)::uuid) t
 where p_query->>'category' in ('all','esg')
   and not p_query ? 'collection' and p_query->>'state' in ('all','unknown')
   and (not p_query ? 'key' or (split_part(p_query->>'key',':',1)='esg' and t.id=split_part(p_query->>'key',':',2)::uuid))
   and (p_query->>'q'='' or strpos(lower(jsonb_build_object('report_title',t.report_title,'company_name',t.company_name,'company_name_en',t.company_name_en,'country',t.country,'publication_date',t.publication_date,'language',t.language)::text||' '||coalesce(t.report_title,'')),lower(p_query->>'q'))>0)
 union all
 select 'standards'::text,t.id,'standards'::text,t.last_updated_time,'standards:'||t.id::text,
   case when p_hydrate then private.kb_catalogue_row_v1('standards',t.id,'standards',t.title,jsonb_build_object('title',t.title,'standard_number',t.standard_number,'issuing_organization',t.issuing_organization,'language',t.language,'effective_date',t.effective_date,'expiration_date',t.expiration_date),t.last_updated_time,jsonb_build_object('legacy_key','standards:'||t.id::text)) end
 from (select * from public.standards original where not p_query ? 'key' union all select * from public.standards original where p_query ? 'key' and original.id=split_part(p_query->>'key',':',2)::uuid) t
 where p_query->>'category' in ('all','standards')
   and not p_query ? 'collection' and p_query->>'state' in ('all','unknown')
   and (not p_query ? 'key' or (split_part(p_query->>'key',':',1)='standards' and t.id=split_part(p_query->>'key',':',2)::uuid))
   and (p_query->>'q'='' or strpos(lower(jsonb_build_object('title',t.title,'standard_number',t.standard_number,'issuing_organization',t.issuing_organization,'language',t.language,'effective_date',t.effective_date,'expiration_date',t.expiration_date)::text||' '||coalesce(t.title,'')),lower(p_query->>'q'))>0)
 union all
 select 'reports'::text,t.id,'reports'::text,t.uploaded_time,'reports:'||t.id::text,
   case when p_hydrate then private.kb_catalogue_row_v1('reports',t.id,'reports',t.title,jsonb_build_object('title',t.title,'issuing_organization',t.issuing_organization,'release_date',t.release_date,'language',t.language),t.uploaded_time,jsonb_build_object('legacy_key','reports:'||t.id::text)) end
 from (select * from public.reports original where not p_query ? 'key' union all select * from public.reports original where p_query ? 'key' and original.id=split_part(p_query->>'key',':',2)::uuid) t
 where p_query->>'category' in ('all','reports')
   and not p_query ? 'collection' and p_query->>'state' in ('all','unknown')
   and (not p_query ? 'key' or (split_part(p_query->>'key',':',1)='reports' and t.id=split_part(p_query->>'key',':',2)::uuid))
   and (p_query->>'q'='' or strpos(lower(jsonb_build_object('title',t.title,'issuing_organization',t.issuing_organization,'release_date',t.release_date,'language',t.language)::text||' '||coalesce(t.title,'')),lower(p_query->>'q'))>0)
 union all
 select 'internalUse'::text,t.id,'other'::text,t.created_time,'internal_use:'||t.id::text,
   case when p_hydrate then private.kb_catalogue_row_v1('internalUse',t.id,'other',t.title,jsonb_build_object('title',t.title,'tag',t.tag,'language',t.language,'file_type',t.file_type),t.created_time,jsonb_build_object('legacy_key','internal_use:'||t.id::text)) end
 from (select * from public.internal_use original where not p_query ? 'key' union all select * from public.internal_use original where p_query ? 'key' and original.id=split_part(p_query->>'key',':',2)::uuid) t
 where p_query->>'category' in ('all','other')
   and not p_query ? 'collection' and p_query->>'state' in ('all','unknown')
   and (not p_query ? 'key' or (split_part(p_query->>'key',':',1)='internalUse' and t.id=split_part(p_query->>'key',':',2)::uuid))
   and (p_query->>'q'='' or strpos(lower(jsonb_build_object('title',t.title,'tag',t.tag,'language',t.language,'file_type',t.file_type)::text||' '||coalesce(t.title,'')),lower(p_query->>'q'))>0)
 union all
 select 'greenDeal'::text,t.id,'policies'::text,t.last_updated_time,'green_deal_meta:'||t.id::text,
   case when p_hydrate then private.kb_catalogue_row_v1('greenDeal',t.id,'policies',t.title,jsonb_build_object('title',t.title,'celex_number',t.celex_number,'issue_agency',t.issue_agency,'publish_date',t.publish_date),t.last_updated_time,jsonb_build_object('legacy_key','green_deal_meta:'||t.id::text)) end
 from (select * from (select * from public.green_deal_meta union select * from private.kb_catalogue_policy_editors_v1()) original where not p_query ? 'key' union all select * from (select * from public.green_deal_meta union select * from private.kb_catalogue_policy_editors_v1()) original where p_query ? 'key' and original.id=split_part(p_query->>'key',':',2)::uuid) t
 where p_query->>'category' in ('all','policies')
   and not p_query ? 'collection' and p_query->>'state' in ('all','unknown')
   and (not p_query ? 'key' or (split_part(p_query->>'key',':',1)='greenDeal' and t.id=split_part(p_query->>'key',':',2)::uuid))
   and (p_query->>'q'='' or strpos(lower(jsonb_build_object('title',t.title,'celex_number',t.celex_number,'issue_agency',t.issue_agency,'publish_date',t.publish_date)::text||' '||coalesce(t.title,'')),lower(p_query->>'q'))>0);
end;
revoke all on function private.kb_catalogue_legacy_v1(jsonb,boolean) from public,anon,authenticated,service_role;
grant execute on function private.kb_catalogue_legacy_v1(jsonb,boolean) to authenticated;

create or replace function api.kb_catalogue_v1(p_query jsonb default '{}') returns jsonb
language sql stable security invoker set search_path=pg_catalog
begin atomic;
 with q as materialized (select private.kb_catalogue_query_v1(p_query) as v),
 -- Deduplication uses ALL visible registered rows, before display filters.
 registered as materialized (select r.body from q cross join lateral private.kb_catalogue_registered_v1() r(body) where q.v is not null),
 filtered as materialized (
   select r.body->>'key' as key,r.body->>'kind' as kind,(r.body->>'id')::uuid as id,
     r.body->>'category' as category,(r.body->>'updated_at')::timestamptz as updated_at,
     r.body->>'file_state' as file_state,r.body->>'processing_state' as processing_state,r.body
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
   select l.kind||':'||l.id::text,l.kind,l.id,l.category,l.updated_at,'unknown','unknown',null::jsonb
   from q cross join lateral private.kb_catalogue_legacy_v1(q.v,false) l
   where not exists(select from registered r where r.body->>'legacy_key'=l.legacy_key)
 ), page_keys as materialized (
   select * from filtered order by updated_at desc nulls last,key
   limit (select (v->>'page_size')::int from q) offset (select ((v->>'page')::int-1)*(v->>'page_size')::int from q)
 ), page_rows as (
   select p.key,p.updated_at,coalesce(p.body,(select l.body from private.kb_catalogue_legacy_v1(
     jsonb_build_object('category',p.category,'state','all','q','','key',p.key),true) l)) as body
   from page_keys p
 ), groups as (
   select category,count(*) total,
     count(*) filter(where file_state in ('associated','registered')) associated,
     count(*) filter(where processing_state='ready') ready
   from filtered group by category
 ), metrics as (
   select count(*) total,count(*) filter(where file_state in ('associated','registered')) associated,
     count(*) filter(where processing_state='ready') ready,count(*) filter(where file_state='missing') missing,
     count(*) filter(where file_state='unknown') unknown from filtered
 )
 select jsonb_build_object('version',1,'page',(q.v->>'page')::int,'page_size',(q.v->>'page_size')::int,
   'total',metrics.total,'rows',coalesce((select jsonb_agg(body order by updated_at desc nulls last,key) from page_rows),'[]'),
   'groups',coalesce((select jsonb_agg(to_jsonb(groups) order by category) from groups),'[]'),
   'metrics',jsonb_build_object('associated',metrics.associated,'ready',metrics.ready,'missing',metrics.missing,'unknown',metrics.unknown),
   'observed_at',statement_timestamp()) from q cross join metrics;
end;

notify pgrst, 'reload schema';
commit;
