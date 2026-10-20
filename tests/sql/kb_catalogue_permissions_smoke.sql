-- Equivalence oracle is the unchanged canonical single-document authorization,
-- not a second copy of the new batch predicate. Disposable synthetic records.
begin;
insert into auth.users(id,role) values(md5('catalogue-oracle-actor')::uuid,'authenticated');
insert into public.kb_groups(id,name,created_by) values(md5('catalogue-oracle-group')::uuid,'catalogue oracle',md5('catalogue-oracle-actor')::uuid);
insert into public.kb_group_members(group_id,user_id) values(md5('catalogue-oracle-group')::uuid,md5('catalogue-oracle-actor')::uuid);
insert into public.kb_collections(id,name,path)
select md5('catalogue-oracle-collection-'||s)::uuid,'oracle '||s,
 case s when 3 then '/catalogue-oracle/2/child' when 4 then '/catalogue-oracle/20' else '/catalogue-oracle/'||s end
from generate_series(1,8)s;
insert into public.kb_documents(id,primary_collection_id,dedupe_scope,original_filename,sha256,created_by,owner_user_id,visibility,deleted_at,status)
select md5('catalogue-oracle-doc-'||s)::uuid,md5('catalogue-oracle-collection-'||(s%8+1))::uuid,
 'catalogue-oracle',s||'.pdf',s::text,
 case when s%11=0 then md5('catalogue-oracle-actor') else md5('oracle-other') end::uuid,
 case when s%13=0 then md5('catalogue-oracle-actor') else md5('oracle-other') end::uuid,
 case when s%17=0 then 'public' else 'private' end::public.kb_document_visibility,
 case when s%19=0 then now() end,
 case when s%23=0 then 'deleted' else 'received' end::public.kb_document_status
from generate_series(1,240)s;
insert into public.kb_grants(resource_type,resource_id,principal_type,principal_id,actions,created_by,expires_at,revoked_at)
values
 ('collection',md5('catalogue-oracle-collection-1')::uuid,'user',md5('catalogue-oracle-actor')::uuid,array['read']::public.kb_grant_action[],md5('catalogue-oracle-actor')::uuid,null,null),
 ('subtree',md5('catalogue-oracle-collection-2')::uuid,'group',md5('catalogue-oracle-group')::uuid,array['manage']::public.kb_grant_action[],md5('catalogue-oracle-actor')::uuid,null,null),
 ('collection',md5('catalogue-oracle-collection-5')::uuid,'user',md5('catalogue-oracle-actor')::uuid,array['read']::public.kb_grant_action[],md5('catalogue-oracle-actor')::uuid,now()-interval '1 second',null),
 ('collection',md5('catalogue-oracle-collection-6')::uuid,'user',md5('catalogue-oracle-actor')::uuid,array['read']::public.kb_grant_action[],md5('catalogue-oracle-actor')::uuid,null,now()),
 ('collection',md5('catalogue-oracle-collection-7')::uuid,'user',md5('catalogue-oracle-actor')::uuid,array['delete']::public.kb_grant_action[],md5('catalogue-oracle-actor')::uuid,null,null),
 ('document',md5('catalogue-oracle-doc-7')::uuid,'group',md5('catalogue-oracle-group')::uuid,array['read']::public.kb_grant_action[],md5('catalogue-oracle-actor')::uuid,null,null);
select set_config('request.jwt.claims',jsonb_build_object('sub',md5('catalogue-oracle-actor')::uuid,'role','authenticated')::text,true);
-- Owner context permits accessing the oracle helpers, but both projections
-- independently derive/check the same ordinary Auth identity from claims.
do $$ declare expected jsonb; actual jsonb; begin
 select jsonb_agg(jsonb_build_object('id',d.id,'collection',case when public.can_collection_action(md5('catalogue-oracle-actor')::uuid,d.primary_collection_id,'read') then d.primary_collection_id end) order by d.id)
 into expected from public.kb_documents d where d.dedupe_scope='catalogue-oracle'
 and d.deleted_at is null and d.status<>'deleted'
 and public.can_document_action(md5('catalogue-oracle-actor')::uuid,d.id,'read');
 select jsonb_agg(jsonb_build_object('id',r->>'id','collection',r->'collection_id') order by r->>'id') into actual
 from private.kb_catalogue_registered_v1() r
 where r->>'kind'='document' and (r->>'id')::uuid in (select id from public.kb_documents where dedupe_scope='catalogue-oracle');
 assert actual=expected, 'Batch rights/masking must match canonical oracle for creator, owner, public, user/group, collection/subtree/direct, expiry/revocation/deleted';
end $$;
-- Permission changes must be visible on the next statement, with no cache TTL.
delete from public.kb_group_members where group_id=md5('catalogue-oracle-group')::uuid;
do $$ declare expected uuid[]; actual uuid[]; begin
 select array_agg(d.id order by d.id) into expected from public.kb_documents d
 where d.dedupe_scope='catalogue-oracle' and d.deleted_at is null and d.status<>'deleted'
 and public.can_document_action(md5('catalogue-oracle-actor')::uuid,d.id,'read');
 select array_agg((r->>'id')::uuid order by (r->>'id')::uuid) into actual from private.kb_catalogue_registered_v1() r
 where r->>'kind'='document' and (r->>'id')::uuid in (select id from public.kb_documents where dedupe_scope='catalogue-oracle');
 assert actual=expected,'Group removal immediately agrees with oracle';
end $$;
rollback;
