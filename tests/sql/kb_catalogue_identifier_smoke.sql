-- Exact lookup, canonical links, ordinary RLS, literal punctuation and duplicates.
begin;
truncate public.journals,public.standards,private.kb_resource_entries,public.kb_documents cascade;
insert into auth.users(id,role) values(md5('identifier-actor')::uuid,'authenticated');
insert into public.journals(id,doi,title) values
 (md5('identifier-j1')::uuid,'10.1234/ABC','One'),
 (md5('identifier-j2')::uuid,'https://doi.org/10.1234/abc','Two'),
 (md5('identifier-hidden')::uuid,'DOI: 10.1234/ABC','Hidden');
insert into public.standards(id,standard_number,title) values
 (md5('identifier-s1')::uuid,'GB/T 123-2026','Standard one'),
 (md5('identifier-s2')::uuid,'gb/t 123-2026','Standard duplicate'),
 (md5('identifier-s3')::uuid,'GBT 1232026','Distinct punctuation');
create policy identifier_hidden on public.journals as restrictive for select to authenticated using(id<>md5('identifier-hidden')::uuid);
insert into public.kb_collections(id,name,path,metadata_schema_json) values
 (md5('identifier-c')::uuid,'Identifier','/identifier','{"catalogue_category":"journals"}'),
 (md5('identifier-denied-c')::uuid,'Denied','/denied','{"catalogue_category":"journals"}');
insert into public.kb_grants(resource_type,resource_id,principal_type,principal_id,actions,created_by)
 values('collection',md5('identifier-c')::uuid,'user',md5('identifier-actor')::uuid,array['read']::public.kb_grant_action[],md5('identifier-actor')::uuid);
insert into private.kb_resource_entries(id,collection_id,primary_source_binding_id,external_key,profile_json,metadata_mode,legacy_ref,source_metadata)
 values(md5('identifier-e')::uuid,md5('identifier-c')::uuid,'id','one','{}','legacy_ref',jsonb_build_object('table','journals','id',md5('identifier-j1')::uuid),'{"title":"Linked without DOI"}'),
 (md5('identifier-denied-e')::uuid,md5('identifier-denied-c')::uuid,'id','two','{}','legacy_ref',jsonb_build_object('table','journals','id',md5('identifier-j2')::uuid),'{"doi":"10.1234/abc"}');
-- Inline index and query expression remain byte-for-byte equivalent to the existing normalizer.
do $$ declare d text; begin
 foreach d in array array['10.1234/ABC',' DOI: 10.1234/abc ','https://dx.doi.org/10.1234/a','http://doi.org/10.1234/b','doi:',''] loop
  assert nullif(lower(regexp_replace(btrim(d),'^(https?://(dx\.)?doi\.org/|doi:\s*)','','i')),'') is not distinct from private.kb_resource_normalize_doi(d),'DOI normalizer parity';
 end loop;
end $$;
select set_config('request.jwt.claims',jsonb_build_object('sub',md5('identifier-actor')::uuid,'role','authenticated')::text,true);
set local role authenticated;
do $$ declare r jsonb; d text; invalid jsonb; keys jsonb; begin
 foreach d in array array['10.1234/ABC',' DOI: 10.1234/abc ','https://dx.doi.org/10.1234/AbC'] loop
  r:=api.kb_catalogue_identifier_v1(jsonb_build_object('category','journals','identifier',d));
  assert (r->>'total')::int=2 and jsonb_array_length(r->'rows')=2,'Duplicates preserved, hidden source excluded';
  assert exists(select from jsonb_array_elements(r->'rows') x where x->>'key'='material:'||md5('identifier-e')::uuid::text),'Explicit source link resolves to visible canonical material';
  assert exists(select from jsonb_array_elements(r->'rows') x where x->>'key'='journals:'||md5('identifier-j2')::uuid::text),'Hidden material must not suppress visible source';
  assert r->'metrics'='{"associated":0,"ready":0,"missing":1,"unknown":1}'::jsonb,'Counts reflect permitted candidates';
 end loop;
 r:=api.kb_catalogue_identifier_v1('{"category":"journals","identifier":"10.1234/abc","page_size":1}');
 assert r->'rows'->0->>'key'<>api.kb_catalogue_identifier_v1('{"category":"journals","identifier":"10.1234/abc","page_size":1,"page":2}')->'rows'->0->>'key','Stable nonoverlapping pages';
 assert api.kb_catalogue_identifier_v1('{"category":"journals","identifier":"10.1234/abc","page":3}')->'rows'='[]','Out of range';
 assert (api.kb_catalogue_identifier_v1('{"category":"journals","identifier":"10.1234/abc","state":"unknown"}')->>'total')::int=1,'Filtered material does not resurrect linked source';
 assert (api.kb_catalogue_identifier_v1('{"category":"standards","identifier":" gb/t 123-2026 "}')->>'total')::int=2,'Standard duplicate/case/trim';
 assert (api.kb_catalogue_identifier_v1('{"category":"standards","identifier":"GBT 1232026"}')->>'total')::int=1,'Punctuation preserved';
 foreach d in array array['GB/T 123','%','10.1234/abc'] loop
  assert (api.kb_catalogue_identifier_v1(jsonb_build_object('category','standards','identifier',d))->>'total')::int=0,'Exact current-library match only';
 end loop;
 foreach invalid in array array['{}'::jsonb,'null','[]','{"category":"all","identifier":"a"}','{"category":"journals","identifier":" "}','{"category":"journals","identifier":"doi:"}','{"category":"journals","identifier":42}','{"category":"journals","identifier":"a","actor_id":"b"}','{"category":"journals","identifier":"a","q":"b"}',jsonb_build_object('category','journals','identifier','a','key','journals:'||md5('identifier-j1')::uuid),jsonb_build_object('category','journals','identifier',repeat('a',513))] loop
  begin perform api.kb_catalogue_identifier_v1(invalid);raise exception 'Invalid lookup accepted';exception when sqlstate '22023' then null;end;
 end loop;
end $$;
reset role;
-- Library/category, state and collection are real result filters, not source aliases.
update public.kb_collections set metadata_schema_json='{"catalogue_category":"reports"}' where id=md5('identifier-c')::uuid;
set local role authenticated;
do $$ declare r jsonb; begin
 r:=api.kb_catalogue_identifier_v1('{"category":"journals","identifier":"10.1234/abc"}');
 assert (r->>'total')::int=1 and r->'rows'->0->>'key'='journals:'||md5('identifier-j2')::uuid::text,'Moved material and its suppressed source remain outside current library';
 assert (api.kb_catalogue_identifier_v1(jsonb_build_object('category','journals','identifier','10.1234/abc','collection',md5('identifier-c')::uuid))->>'total')::int=0,'Collection restriction never resurrects moved material';
 assert (api.kb_catalogue_v1(jsonb_build_object('category','reports','key','material:'||md5('identifier-e')::uuid))->>'total')::int=1,'Moved material remains in actual library and unified detail';
 assert (api.kb_catalogue_identifier_v1('{"category":"standards","identifier":"GB/T  123-2026"}')->>'total')::int=0,'Internal spaces are significant';
end $$;
reset role;
update public.kb_collections set metadata_schema_json='{"catalogue_category":"journals"}' where id=md5('identifier-c')::uuid;
savepoint multiple_materials;
insert into private.kb_resource_entries(id,collection_id,primary_source_binding_id,external_key,profile_json,metadata_mode,legacy_ref,source_metadata)
 values(md5('identifier-e2')::uuid,md5('identifier-c')::uuid,'id','two','{}','legacy_ref',jsonb_build_object('table','journals','id',md5('identifier-j1')::uuid),'{"title":"Second explicit link"}'),
 (md5('identifier-e3')::uuid,md5('identifier-c')::uuid,'id','three','{}','managed',null,'{"doi":"10.1234/abc"}');
set local role authenticated;
do $$ declare r jsonb; begin
 r:=api.kb_catalogue_identifier_v1('{"category":"journals","identifier":"10.1234/abc"}');
 assert (r->>'total')::int=4,'All explicit materials and unlinked DOI duplicates retained';
 assert (api.kb_catalogue_identifier_v1('{"category":"journals","identifier":"10.1234/abc","state":"ready"}')->>'total')::int=0,'Nonmatching state is an empty result, never source fallback';
end $$;
reset role;
rollback to multiple_materials;
-- No changes to source identifiers or file associations, and writes still maintain the index.
set local role service_role;
update public.journals set doi='10.1234/CHANGED' where id=md5('identifier-j2')::uuid;
reset role;
set local role authenticated;
do $$ begin
 assert (api.kb_catalogue_identifier_v1('{"category":"journals","identifier":"10.1234/abc"}')->>'total')::int=1,'Source update reflected immediately';
 assert (api.kb_catalogue_identifier_v1('{"category":"journals","identifier":"10.1234/changed"}')->>'total')::int=1,'Index maintenance by existing service writer';
end $$;
reset role;
rollback;
