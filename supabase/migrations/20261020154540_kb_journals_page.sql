-- One RLS-filtered identity scan supplies exact count and UUID pagination.
-- No cache, replica, source write, role/timeout change or privileged fallback.
create function api.kb_journals_page_v1(
  p_page integer default 1,
  p_page_size integer default 10,
  p_dir text default 'desc'
) returns jsonb
language plpgsql stable security invoker
set search_path = pg_catalog
as $$
declare result jsonb;
begin
  if auth.uid() is null or auth.role() is distinct from 'authenticated' then
    raise insufficient_privilege using message = 'JOURNALS_AUTH_REQUIRED';
  end if;
  if p_page is null or p_page < 1 or p_page_size is null
     or p_page_size not between 1 and 100
     or p_dir is null or p_dir not in ('asc','desc') then
    raise invalid_parameter_value using message = 'JOURNALS_INVALID_PAGE';
  end if;
  with visible_ids as materialized (
    select id from public.journals
  ), page_ids as materialized (
    select id from visible_ids
    order by case when p_dir='asc' then id end asc,
             case when p_dir='desc' then id end desc
    offset (p_page::bigint-1)*p_page_size limit p_page_size
  )
  select jsonb_build_object(
    'total', (select count(*) from visible_ids),
    'page', p_page, 'pageSize', p_page_size,
    'data', coalesce((
      select jsonb_agg(to_jsonb(row_data)
        order by case when p_dir='asc' then row_data.id end asc,
                 case when p_dir='desc' then row_data.id end desc)
      from (
        select j.id,j.title,j.journal,j.doi,j.date
        from page_ids p join public.journals j on j.id=p.id
      ) row_data
    ),'[]'::jsonb)
  ) into result;
  return result;
end;
$$;
revoke all on function api.kb_journals_page_v1(integer,integer,text) from public,anon,service_role;
grant execute on function api.kb_journals_page_v1(integer,integer,text) to authenticated;
