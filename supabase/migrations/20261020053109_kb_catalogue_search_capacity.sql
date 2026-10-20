-- Exact journals search text: all arguments have deterministic JSON encoding.
-- No timestamps/enums/session-dependent casts occur in this immutable helper.
begin;
set local lock_timeout='5s';
create extension if not exists pg_trgm with schema extensions;
create function private.kb_catalogue_journal_text_v1(p_title text,p_doi text,p_journal text,p_authors jsonb,p_date text,p_abstract text)
returns text language sql immutable security invoker set search_path=pg_catalog
return lower(jsonb_build_object('title',p_title,'doi',p_doi,'journal',p_journal,'authors',p_authors,'date',p_date,'abstract',p_abstract)::text||' '||coalesce(p_title,''));
revoke all on function private.kb_catalogue_journal_text_v1(text,text,text,jsonb,text,text) from public,anon,authenticated,service_role;
grant execute on function private.kb_catalogue_journal_text_v1(text,text,text,jsonb,text,text) to authenticated;
-- A rebuildable search projection only; public.journals remains authoritative.
-- Creating the trigger before backfill holds writes for this transaction, so
-- concurrent inserts/updates cannot race the initial snapshot. Reads continue.
create table private.kb_catalogue_journal_search (
 id uuid primary key,
 search_text text not null
);
alter table private.kb_catalogue_journal_search enable row level security;
revoke all on private.kb_catalogue_journal_search from public,anon,authenticated,service_role;
create function private.kb_catalogue_journal_sync_v1() returns trigger
language plpgsql security definer set search_path=pg_catalog as $$
begin
 if tg_op='TRUNCATE' then
   delete from private.kb_catalogue_journal_search;
   return null;
 end if;
 if tg_op='DELETE' then
   delete from private.kb_catalogue_journal_search where id=old.id;
   return old;
 end if;
 if tg_op='UPDATE' and old.id<>new.id then
   delete from private.kb_catalogue_journal_search where id=old.id;
 end if;
 insert into private.kb_catalogue_journal_search(id,search_text)
 values(new.id,private.kb_catalogue_journal_text_v1(new.title,new.doi,new.journal,new.authors,new.date,new.abstract))
 on conflict(id) do update set search_text=excluded.search_text;
 return new;
end $$;
revoke all on function private.kb_catalogue_journal_sync_v1() from public,anon,authenticated,service_role;
create trigger kb_catalogue_journal_search_sync
 after insert or delete or update of id,title,doi,journal,authors,date,abstract on public.journals
 for each row execute function private.kb_catalogue_journal_sync_v1();
create trigger kb_catalogue_journal_search_truncate
 after truncate on public.journals for each statement execute function private.kb_catalogue_journal_sync_v1();
insert into private.kb_catalogue_journal_search(id,search_text)
 select id,private.kb_catalogue_journal_text_v1(title,doi,journal,authors,date,abstract) from public.journals;
create index kb_catalogue_journal_search_trgm_idx on private.kb_catalogue_journal_search
 using gin(search_text extensions.gin_trgm_ops);
analyze private.kb_catalogue_journal_search;
-- Internal candidate IDs only, never a user-facing endpoint. No private schema
-- USAGE/table SELECT is granted. The invoker legacy query MUST join journals
-- after this helper so its original RLS applies before counts/paging/hydration.
-- Never add LIMIT here: invisible candidates must not consume visible pages.
create function private.kb_catalogue_journal_matches_v1(p_search text) returns setof uuid
language plpgsql stable rows 1000000 security definer set search_path=pg_catalog as $$
declare needle text:=lower(p_search);
begin
 perform private.kb_metadata_actor_v1();
 if p_search is null or length(p_search)>200 then
   raise sqlstate '22023' using message='CATALOGUE_INVALID_QUERY';
 end if;
 if length(needle)<3 then
   return query select id from private.kb_catalogue_journal_search where strpos(search_text,needle)>0;
 else
   return query select id from private.kb_catalogue_journal_search
    where search_text like ('%'||replace(replace(replace(needle,E'\\',E'\\\\'),'%',E'\\%'),'_',E'\\_')||'%');
 end if;
end $$;
revoke all on function private.kb_catalogue_journal_matches_v1(text) from public,anon,authenticated,service_role;
grant execute on function private.kb_catalogue_journal_matches_v1(text) to authenticated;
create or replace function private.kb_catalogue_legacy_v1(p_query jsonb,p_hydrate boolean)
returns table(kind text,id uuid,category text,updated_at timestamptz,legacy_key text,body jsonb)
language sql stable security invoker set search_path=pg_catalog
begin atomic;
 select 'journals'::text,t.id,'journals'::text,t.created_at,'journals:'||t.id::text,
   null::jsonb
 from (
   select * from public.journals original where not p_query ? 'key' and p_query->>'q'=''
   union all
   select original.* from private.kb_catalogue_journal_matches_v1(p_query->>'q') matched(id)
     join public.journals original on original.id=matched.id
   where not p_query ? 'key' and p_query->>'q'<>''
   union all
   select * from public.journals original where p_query ? 'key' and original.id=split_part(p_query->>'key',':',2)::uuid
     and (p_query->>'q'='' or strpos(private.kb_catalogue_journal_text_v1(original.title,original.doi,original.journal,original.authors,original.date,original.abstract),lower(p_query->>'q'))>0)
 ) t
 where not p_hydrate and p_query->>'category' in ('all','journals')
   and not p_query ? 'collection' and p_query->>'state' in ('all','unknown')
   and (not p_query ? 'key' or (split_part(p_query->>'key',':',1)='journals' and t.id=split_part(p_query->>'key',':',2)::uuid))

 union all
 select 'journals'::text,t.id,'journals'::text,t.created_at,'journals:'||t.id::text,
   private.kb_catalogue_row_v1('journals',t.id,'journals',t.title,jsonb_build_object('title',t.title,'doi',t.doi,'journal',t.journal,'authors',t.authors,'date',t.date,'abstract',t.abstract),t.created_at,jsonb_build_object('legacy_key','journals:'||t.id::text))
 from (
   select * from public.journals original where not p_query ? 'key' and p_query->>'q'=''
   union all
   select original.* from private.kb_catalogue_journal_matches_v1(p_query->>'q') matched(id)
     join public.journals original on original.id=matched.id
   where not p_query ? 'key' and p_query->>'q'<>''
   union all
   select * from public.journals original where p_query ? 'key' and original.id=split_part(p_query->>'key',':',2)::uuid
     and (p_query->>'q'='' or strpos(private.kb_catalogue_journal_text_v1(original.title,original.doi,original.journal,original.authors,original.date,original.abstract),lower(p_query->>'q'))>0)
 ) t
 where p_hydrate and p_query->>'category' in ('all','journals')
   and not p_query ? 'collection' and p_query->>'state' in ('all','unknown')
   and (not p_query ? 'key' or (split_part(p_query->>'key',':',1)='journals' and t.id=split_part(p_query->>'key',':',2)::uuid))

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
notify pgrst, 'reload schema';
commit;
