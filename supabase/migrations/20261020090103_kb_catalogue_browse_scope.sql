-- First-batch catalogue is browsing and typed-key detail only.
begin;
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
  if coalesce(p_query->>'q','')<>'' then
    raise sqlstate '22023' using message='CATALOGUE_SEARCH_UNSUPPORTED';
  end if;
  return jsonb_build_object('page',1,'page_size',20,'q','','category','all','state','all')||p_query;
exception when invalid_text_representation or numeric_value_out_of_range then
  raise sqlstate '22023' using message='CATALOGUE_INVALID_QUERY';
end $$;
notify pgrst, 'reload schema';
commit;
