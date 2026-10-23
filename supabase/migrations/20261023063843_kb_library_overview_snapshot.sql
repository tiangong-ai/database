-- Daily exact statistics, separate from live list queries and authorization.
set lock_timeout = '5s';
set statement_timeout = '5min';

create table private.kb_library_overview_snapshot (
  resource text primary key check (resource in ('journals','education','esg','standards','reports','internalUse','greenDeal')),
  total bigint not null check (total >= 0),
  refreshed_at timestamptz not null
);
alter table private.kb_library_overview_snapshot enable row level security;
revoke all on private.kb_library_overview_snapshot from public,anon,authenticated,service_role;

-- Only the owner/scheduler may refresh. One SQL snapshot and atomic replacement:
-- a failed count or write leaves the complete previous generation intact.
create function private.kb_refresh_library_overview_v1() returns void
language plpgsql volatile security definer set search_path=pg_catalog as $$
begin
  if not pg_try_advisory_xact_lock(1684836901,122) then
    raise sqlstate '55P03' using message='OVERVIEW_REFRESH_BUSY';
  end if;
  insert into private.kb_library_overview_snapshot(resource,total,refreshed_at)
  select resource,total,statement_timestamp() from (
    select 'journals' resource,count(id) total from public.journals
    union all select 'education',count(id) from public.edu_meta
    union all select 'esg',count(id) from public.esg_meta
    union all select 'standards',count(id) from public.standards
    union all select 'reports',count(id) from public.reports
    union all select 'internalUse',count(id) from public.internal_use
    union all select 'greenDeal',count(id) from public.green_deal_meta
  ) counts
  on conflict(resource) do update set total=excluded.total,refreshed_at=excluded.refreshed_at;
end $$;
revoke all on function private.kb_refresh_library_overview_v1() from public,anon,authenticated,service_role;

create function private.kb_library_overview_v1() returns jsonb
language plpgsql stable security definer set search_path=pg_catalog as $$
declare
  v_actor uuid:=private.kb_library_session_v1(); v_rows jsonb:='[]';
  v_resource text; v_table regclass; v_editor boolean; v_visible boolean;
  v_total bigint; v_at timestamptz; v_refreshed timestamptz;
begin
  foreach v_resource in array array['journals','esg','standards','reports','education','greenDeal','internalUse'] loop
    v_table:=case v_resource when 'journals' then 'public.journals'::regclass
      when 'esg' then 'public.esg_meta'::regclass when 'standards' then 'public.standards'::regclass
      when 'reports' then 'public.reports'::regclass when 'education' then 'public.edu_meta'::regclass
      when 'greenDeal' then 'public.green_deal_meta'::regclass else 'public.internal_use'::regclass end;
    v_editor:=v_resource<>'journals' and exists(select from private.kb_metadata_editors
      where actor_id=v_actor and resource=v_resource and revoked_at is null
        and (expires_at is null or expires_at>statement_timestamp()));
    -- Readers may reuse a global total only when the CURRENT policy proves
    -- all rows readable. Unknown/partial predicates fail closed, with no scan.
    -- Editors already have explicit full-table read authority in metadata API.
    select v_editor or (v_resource<>'greenDeal'
      and has_table_privilege('authenticated',v_table,'SELECT')
      and (not c.relrowsecurity or (
        exists(select from pg_policy p where p.polrelid=v_table and p.polcmd in ('r','*') and p.polpermissive
          and pg_get_expr(p.polqual,p.polrelid)='true'
          and exists(select from unnest(p.polroles) r where r=0 or pg_has_role('authenticated',r,'USAGE')))
        and not exists(select from pg_policy p where p.polrelid=v_table and p.polcmd in ('r','*') and not p.polpermissive
          and pg_get_expr(p.polqual,p.polrelid) is distinct from 'true'
          and exists(select from unnest(p.polroles) r where r=0 or pg_has_role('authenticated',r,'USAGE')))
      ))) into v_visible from pg_class c where c.oid=v_table;
    select total,refreshed_at into v_total,v_at from private.kb_library_overview_snapshot where resource=v_resource;
    v_rows:=v_rows||jsonb_build_array(jsonb_build_object('resource',v_resource,'total',case when v_visible then v_total else null end));
    v_refreshed:=least(v_refreshed,v_at);
  end loop;
  return jsonb_build_object('actorId',v_actor,'counts',v_rows,'refreshedAt',v_refreshed,
    'stale',v_refreshed is null or v_refreshed<statement_timestamp()-interval '36 hours');
end $$;
create function api.kb_library_overview_v1() returns jsonb
language sql stable security invoker set search_path=pg_catalog
return private.kb_library_overview_v1();
revoke all on function private.kb_library_overview_v1(),api.kb_library_overview_v1() from public,anon,authenticated,service_role;
grant execute on function private.kb_library_overview_v1(),api.kb_library_overview_v1() to authenticated;

create extension if not exists pg_cron;
-- The schedule below is 03:00 Asia/Shanghai, using pg_cron's default GMT/UTC.
-- Refuse an unexpected scheduler timezone rather than changing global settings.
do $$ begin
  if coalesce(current_setting('cron.timezone',true),'GMT') not in ('GMT','UTC','Etc/UTC') then
    raise exception 'OVERVIEW_CRON_TIMEZONE_REQUIRES_UTC';
  end if;
end $$;
select cron.schedule('kb-library-overview-daily','0 19 * * *',
  $job$set statement_timeout='5min'; set lock_timeout='5s'; select private.kb_refresh_library_overview_v1();$job$);
select private.kb_refresh_library_overview_v1();
notify pgrst,'reload schema';
reset lock_timeout;
reset statement_timeout;
