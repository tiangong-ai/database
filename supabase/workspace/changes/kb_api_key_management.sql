-- S2 additive gateway. Legacy public table, grants and verifier bodies stay intact.
create table private.kb_api_key_requests (
  actor_id uuid not null,
  request_id uuid not null,
  operation text not null check (operation in ('create','revoke','rotate')),
  payload_hash text not null check (payload_hash ~ '^[0-9a-f]{64}$'),
  key_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (actor_id, request_id)
);
alter table private.kb_api_key_requests enable row level security;
revoke all on table private.kb_api_key_requests from public, anon, authenticated, service_role;

create function private.kb_api_key_actor_v1() returns uuid
language plpgsql stable security invoker set search_path = pg_catalog as $$
declare v_actor uuid := auth.uid();
begin
  if auth.role() is distinct from 'authenticated' or v_actor is null
     or not exists (select from auth.users where id = v_actor) then
    raise sqlstate '42501' using message = 'API_KEY_AUTH_REQUIRED';
  end if;
  return v_actor;
end;
$$;

create function private.kb_api_key_metadata_v1(p_key public.kb_api_keys) returns jsonb
language sql stable security invoker set search_path = pg_catalog as $$
  select jsonb_build_object(
    'id',p_key.id,'name',p_key.name,'clientId',p_key.client_id,
    'actorUserId',p_key.actor_user_id,'tokenPrefix',p_key.token_prefix,
    'scopes',p_key.scopes,'collectionScope',p_key.collection_scope,
    'expiresAt',p_key.expires_at,'revokedAt',p_key.revoked_at,
    'lastUsedAt',p_key.last_used_at,'createdBy',p_key.created_by,
    'createdAt',p_key.created_at,'updatedAt',p_key.updated_at);
$$;

-- Ownership grants revocation even after collection grants have expired.
-- Delegated management requires manage on EVERY explicitly bounded collection.
create function private.kb_api_key_manage_v1(p_actor uuid, p_key public.kb_api_keys)
returns boolean language sql stable security invoker set search_path = pg_catalog as $$
  select coalesce(p_key.actor_user_id = p_actor, false) or
    (cardinality(p_key.collection_scope) > 0 and not exists (
      select from unnest(p_key.collection_scope) s
      left join public.kb_collections c on c.path = public.kb_normalize_collection_path(s)
      where c.id is null or not public.can_collection_action(p_actor,c.id,'manage')));
$$;

create function private.kb_api_key_scope_v1(
  p_actor uuid, p_target uuid, p_scopes text[], p_collections text[]
) returns void language plpgsql stable security invoker set search_path = pg_catalog as $$
declare v_path text; v_id uuid; v_scope text; v_action public.kb_grant_action;
begin
  if p_target is null or not exists(select from auth.users where id=p_target) then
    raise sqlstate 'PT400' using message='API_KEY_INVALID_TARGET';
  end if;
  if p_scopes is null or cardinality(p_scopes) not between 1 and 5
     or array_position(p_scopes,null) is not null
     or not p_scopes <@ array['kb:read','kb:upload','kb:delete','kb:reindex','kb:admin']::text[] then
    raise sqlstate 'PT400' using message='API_KEY_INVALID_SCOPES';
  end if;
  if p_collections is null or cardinality(p_collections) not between 1 and 100
     or array_position(p_collections,null) is not null then
    raise sqlstate 'PT400' using message='API_KEY_BOUNDED_COLLECTIONS_REQUIRED';
  end if;
  foreach v_path in array p_collections loop
    if length(v_path)>512 or public.kb_normalize_collection_path(v_path) is null then
      raise sqlstate 'PT400' using message='API_KEY_INVALID_COLLECTION';
    end if;
    select id into v_id from public.kb_collections where path=public.kb_normalize_collection_path(v_path);
    -- Do not reveal whether an inaccessible collection exists.
    if v_id is null or (p_actor<>p_target and not public.can_collection_action(p_actor,v_id,'manage')) then
      raise sqlstate '42501' using message='API_KEY_FORBIDDEN';
    end if;
    foreach v_scope in array p_scopes loop
      v_action := case v_scope when 'kb:admin' then 'manage' else substr(v_scope,4) end;
      if not public.can_collection_action(p_target,v_id,v_action) then
        raise sqlstate '42501' using message='API_KEY_FORBIDDEN';
      end if;
    end loop;
  end loop;
end;
$$;

create function private.kb_api_key_command_v1(p_operation text, p_request_id uuid, p_payload jsonb)
returns jsonb language plpgsql security invoker set search_path = pg_catalog as $$
declare
  v_actor uuid := private.kb_api_key_actor_v1();
  v_target uuid; v_id uuid; v_old public.kb_api_keys; v_key public.kb_api_keys;
  v_request private.kb_api_key_requests; v_hash text; v_token text;
  v_scopes text[]; v_collections text[]; v_name text; v_client text;
  v_expires timestamptz; v_reason text; v_allowed text[]; v_changed boolean := true;
begin
  if p_request_id is null or p_payload is null or jsonb_typeof(p_payload)<>'object'
     or octet_length(p_payload::text)>65536 then
    raise sqlstate 'PT400' using message='API_KEY_INVALID_REQUEST';
  end if;
  v_allowed := case p_operation
    when 'create' then array['name','client_id','actor_user_id','scopes','collection_scope','expires_at']
    when 'revoke' then array['key_id','reason']
    when 'rotate' then array['key_id','reason'] else null end;
  if v_allowed is null or exists(select from jsonb_object_keys(p_payload) k where not k=any(v_allowed)) then
    raise sqlstate 'PT400' using message='API_KEY_INVALID_FIELDS';
  end if;
  v_hash := encode(sha256(convert_to(p_payload::text,'UTF8')),'hex');
  -- Serialize identical request IDs before any row mutation. Hash collisions only serialize.
  perform pg_advisory_xact_lock(hashtextextended(v_actor::text||':'||p_request_id::text,0));
  select * into v_request from private.kb_api_key_requests where actor_id=v_actor and request_id=p_request_id;
  if found and (v_request.operation<>p_operation or v_request.payload_hash<>v_hash) then
    raise sqlstate 'PT409' using message='API_KEY_REQUEST_CONFLICT';
  end if;
  if p_operation='create' then
    if jsonb_typeof(p_payload->'name') is distinct from 'string'
       or jsonb_typeof(p_payload->'client_id') is distinct from 'string'
       or jsonb_typeof(p_payload->'scopes') is distinct from 'array'
       or jsonb_typeof(p_payload->'collection_scope') is distinct from 'array'
       or exists(select from jsonb_array_elements(p_payload->'scopes') s where jsonb_typeof(s)<>'string')
       or exists(select from jsonb_array_elements(p_payload->'collection_scope') s where jsonb_typeof(s)<>'string')
       or (p_payload ? 'actor_user_id' and jsonb_typeof(p_payload->'actor_user_id') not in ('string','null'))
       or (p_payload ? 'expires_at' and jsonb_typeof(p_payload->'expires_at') not in ('string','null')) then
      raise sqlstate 'PT400' using message='API_KEY_INVALID_FIELDS';
    end if;
    v_name := btrim(p_payload->>'name'); v_client := btrim(p_payload->>'client_id');
    if length(v_name) not between 1 and 120 or length(v_client) not between 1 and 120 then
      raise sqlstate 'PT400' using message='API_KEY_INVALID_FIELDS';
    end if;
    v_target := coalesce((p_payload->>'actor_user_id')::uuid,v_actor);
    v_scopes := array(select jsonb_array_elements_text(p_payload->'scopes'));
    v_collections := array(select jsonb_array_elements_text(p_payload->'collection_scope'));
    perform private.kb_api_key_scope_v1(v_actor,v_target,v_scopes,v_collections);
    v_scopes := array(select distinct s from unnest(v_scopes) s order by s);
    v_collections := array(select distinct public.kb_normalize_collection_path(s) from unnest(v_collections) s order by 1);
    v_expires := (p_payload->>'expires_at')::timestamptz;
    if v_request.request_id is null and v_expires is not null
       and (not isfinite(v_expires) or v_expires<=statement_timestamp()) then
      raise sqlstate 'PT400' using message='API_KEY_INVALID_EXPIRY';
    end if;
  else
    if jsonb_typeof(p_payload->'key_id') is distinct from 'string'
       or (p_payload ? 'reason' and jsonb_typeof(p_payload->'reason') not in ('string','null')) then
      raise sqlstate 'PT400' using message='API_KEY_INVALID_FIELDS';
    end if;
    v_id := (p_payload->>'key_id')::uuid;
    v_reason := nullif(btrim(p_payload->>'reason'),'');
    if length(v_reason)>1000 then raise sqlstate 'PT400' using message='API_KEY_INVALID_FIELDS'; end if;
    select * into v_old from public.kb_api_keys where id=v_id for update;
    if not found or not private.kb_api_key_manage_v1(v_actor,v_old) then
      raise sqlstate 'PT404' using message='API_KEY_NOT_FOUND';
    end if;
    if p_operation='rotate' then
      perform private.kb_api_key_scope_v1(v_actor,v_old.actor_user_id,v_old.scopes,v_old.collection_scope);
    end if;
  end if;
  -- Recheck current rights BEFORE reading a previous receipt. Never store/replay a secret.
  if v_request.request_id is not null then
    select * into v_key from public.kb_api_keys where id=v_request.key_id;
    if not found or not private.kb_api_key_manage_v1(v_actor,v_key) then
      raise sqlstate 'PT409' using message='API_KEY_RECEIPT_UNAVAILABLE';
    end if;
    return jsonb_build_object('version',1,'apiKey',private.kb_api_key_metadata_v1(v_key),'token',null,'replayed',true);
  end if;
  if p_operation='rotate' then
    if v_old.revoked_at is not null then raise sqlstate 'PT409' using message='API_KEY_ALREADY_REVOKED'; end if;
    if v_old.expires_at is not null and v_old.expires_at<=statement_timestamp() then
      raise sqlstate 'PT409' using message='API_KEY_EXPIRED';
    end if;
    v_target:=v_old.actor_user_id; v_name:=v_old.name; v_client:=v_old.client_id;
    v_scopes:=v_old.scopes; v_collections:=v_old.collection_scope; v_expires:=v_old.expires_at;
  end if;
  if p_operation in ('revoke','rotate') then
    v_changed := v_old.revoked_at is null;
    if v_changed then
      update public.kb_api_keys set revoked_at=statement_timestamp(),revoked_by=v_actor,
        revoke_reason=coalesce(v_reason,case when p_operation='rotate' then 'rotated' end)
      where id=v_old.id returning * into v_key;
    else v_key:=v_old; end if;
  end if;
  if p_operation in ('create','rotate') then
    v_token := 'tgkb_live_'||translate(rtrim(encode(extensions.gen_random_bytes(32),'base64'),'='),'+/','-_');
    insert into public.kb_api_keys(name,client_id,actor_user_id,token_prefix,token_hash,scopes,
      collection_scope,expires_at,created_by,rotated_from_key_id)
    values(v_name,v_client,v_target,left(v_token,18),encode(sha256(convert_to(v_token,'UTF8')),'hex'),
      v_scopes,v_collections,v_expires,v_actor,case when p_operation='rotate' then v_old.id end)
    returning * into v_key;
  end if;
  if v_changed then
    perform public.write_kb_audit_event(v_actor,'kb.api_key_'||p_operation||'_v1',null,null,
      '{}'::jsonb,p_request_id::text,jsonb_build_object('key_id',v_key.id,
      'previous_key_id',case when p_operation='rotate' then v_old.id end,'target_actor_id',v_key.actor_user_id));
  end if;
  insert into private.kb_api_key_requests(actor_id,request_id,operation,payload_hash,key_id)
  values(v_actor,p_request_id,p_operation,v_hash,v_key.id);
  return jsonb_build_object('version',1,'apiKey',private.kb_api_key_metadata_v1(v_key),
    'token',v_token,'replayed',false,'changed',v_changed);
exception
  when invalid_text_representation or invalid_datetime_format or datetime_field_overflow then
    raise sqlstate 'PT400' using message='API_KEY_INVALID_FIELDS';
  when sqlstate '42501' or sqlstate 'PT400' or sqlstate 'PT404' or sqlstate 'PT409' then raise;
  when others then raise sqlstate 'PT500' using message='API_KEY_OPERATION_FAILED';
end;
$$;

create function api.kb_api_key_list_v1(p_limit integer default 100, p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = pg_catalog as $$
declare v_actor uuid := private.kb_api_key_actor_v1(); v_rows jsonb;
begin
  if p_limit is null or p_limit not between 1 and 100 or p_offset is null or p_offset not between 0 and 10000 then
    raise sqlstate 'PT400' using message='API_KEY_INVALID_PAGE';
  end if;
  select coalesce(jsonb_agg(private.kb_api_key_metadata_v1(k) order by k.created_at desc,k.id desc),'[]'::jsonb)
  into v_rows from (
    select k.* from public.kb_api_keys k where private.kb_api_key_manage_v1(v_actor,k)
    order by created_at desc,id desc limit p_limit offset p_offset
  ) k;
  return jsonb_build_object('version',1,'data',v_rows,'limit',p_limit,'offset',p_offset);
end;
$$;

create function api.kb_api_key_create_v1(p_request_id uuid,p_payload jsonb)
returns jsonb language sql security definer set search_path = pg_catalog as $$
  select private.kb_api_key_command_v1('create',p_request_id,p_payload);
$$;
create function api.kb_api_key_revoke_v1(p_key_id uuid,p_request_id uuid,p_reason text default null)
returns jsonb language sql security definer set search_path = pg_catalog as $$
  select private.kb_api_key_command_v1('revoke',p_request_id,jsonb_build_object('key_id',p_key_id,'reason',p_reason));
$$;
create function api.kb_api_key_rotate_v1(p_key_id uuid,p_request_id uuid,p_reason text default null)
returns jsonb language sql security definer set search_path = pg_catalog as $$
  select private.kb_api_key_command_v1('rotate',p_request_id,jsonb_build_object('key_id',p_key_id,'reason',p_reason));
$$;

revoke all on function private.kb_api_key_actor_v1() from public,anon,authenticated,service_role;
revoke all on function private.kb_api_key_metadata_v1(public.kb_api_keys) from public,anon,authenticated,service_role;
revoke all on function private.kb_api_key_manage_v1(uuid,public.kb_api_keys) from public,anon,authenticated,service_role;
revoke all on function private.kb_api_key_scope_v1(uuid,uuid,text[],text[]) from public,anon,authenticated,service_role;
revoke all on function private.kb_api_key_command_v1(text,uuid,jsonb) from public,anon,authenticated,service_role;
revoke all on function api.kb_api_key_list_v1(integer,integer) from public,anon,authenticated,service_role;
revoke all on function api.kb_api_key_create_v1(uuid,jsonb) from public,anon,authenticated,service_role;
revoke all on function api.kb_api_key_revoke_v1(uuid,uuid,text) from public,anon,authenticated,service_role;
revoke all on function api.kb_api_key_rotate_v1(uuid,uuid,text) from public,anon,authenticated,service_role;
grant usage on schema api to authenticated;
grant execute on function api.kb_api_key_list_v1(integer,integer) to authenticated;
grant execute on function api.kb_api_key_create_v1(uuid,jsonb) to authenticated;
grant execute on function api.kb_api_key_revoke_v1(uuid,uuid,text) to authenticated;
grant execute on function api.kb_api_key_rotate_v1(uuid,uuid,text) to authenticated;
notify pgrst, 'reload schema';
